/*
 * Copyright 2026 Adam Cox
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Meetey.app: assembling it, signing it, and installing the signed release.
 *
 * Why a signed release matters: macOS remembers a permission grant (the
 * microphone) against the app's *designated requirement*. An ad-hoc signature
 * can only be described by its exact hash, so every rebuild was a new app and
 * asked again. A Developer ID signature is described by bundle ID and Team ID,
 * which survive rebuilds and certificate renewals — so the grant sticks.
 *
 * Releases therefore ship a Meetey.app built, signed and notarized in CI
 * (`.github/workflows/ci.yml`), and install/update download it. Building from
 * source remains the fallback — a release without the app, a git checkout, or
 * `MEETEY_BUILD_FROM_SOURCE=1` — signed ad hoc as before.
 */

import { execFileSync, spawnSync } from "child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { REPO } from "../mcp-server/update-check.js";
import { downloadFile } from "./utils.js";

export const APP_ID = "com.adamjhcox.meetey";

/**
 * The executable inside Meetey.app. Named like the app, as normal apps are:
 * macOS also identifies menu bar items by process name, and while it was
 * `meetey-capture` the icons matched a stale, identity-less registration left
 * by the bare binary, so System Settings listed "meetey-capture" and menu bar
 * managers couldn't keep the icon visible. The Swift target is still
 * `meetey-capture`; only the copy in the bundle is renamed.
 */
export const APP_EXECUTABLE = "Meetey";

/**
 * The Apple Developer Team whose signature a downloaded Meetey.app must carry
 * (Adam Cox). Checked before anything downloaded replaces the installed app;
 * null would mean no signed release is trusted, so install builds from source.
 */
export const TEAM_ID = "86CB3GP2UH";

const LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

/**
 * Makes LaunchServices re-read the bundle at `appBundle`.
 *
 * LaunchServices caches each bundle's Info.plist — executable name included —
 * and doesn't refresh it when the bundle is replaced in place. Meetey is never
 * opened through Finder, so after 2.5.4 renamed the executable the record still
 * said `meetey-capture`, and macOS couldn't tie the running `Meetey` to the app:
 * its menu bar icon became a blank slot that did nothing when clicked. Every
 * install of the bundle therefore re-registers it. A failure here is reported,
 * never fatal.
 */
export function registerWithLaunchServices(appBundle) {
  try {
    execFileSync(LSREGISTER, ["-f", appBundle], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/** Release asset name for a version. */
export const appAssetName = (version) => `Meetey-${version}.zip`;

/** Puts a built meetey-capture binary into a fresh Meetey.app at `appBundle`. */
export function assembleApp({ builtBinary, appBundle, plistTemplate, version }) {
  rmSync(appBundle, { recursive: true, force: true });
  const binary = join(appBundle, "Contents", "MacOS", APP_EXECUTABLE);
  mkdirSync(dirname(binary), { recursive: true });
  cpSync(builtBinary, binary);
  const plist = readFileSync(plistTemplate, "utf8").replaceAll("__VERSION__", version);
  writeFileSync(join(appBundle, "Contents", "Info.plist"), plist);
  return binary;
}

/**
 * Signs the bundle. `identity` "-" is ad hoc; anything else is looked up in
 * `keychain` (or the default search list). Notarization needs `timestamp`.
 */
export function signApp({ appBundle, entitlements, identity = "-", keychain = null, timestamp = false }) {
  try {
    execFileSync("codesign", [
      "--force",
      "--sign", identity,
      ...(keychain ? ["--keychain", keychain] : []),
      "--options", "runtime",
      ...(timestamp ? ["--timestamp"] : []),
      "--entitlements", entitlements,
      appBundle,
    ], { stdio: ["ignore", "ignore", "pipe"], encoding: "utf8" });
  } catch (e) {
    throw new Error(`codesign failed: ${String(e.stderr || e.message).trim()}`);
  }
}

/** Identifier, Team ID and version of a signed bundle, or null if it doesn't verify. */
export function signatureInfo(appBundle) {
  try {
    execFileSync("codesign", ["--verify", "--strict", "--deep", appBundle], { stdio: "ignore" });
  } catch {
    return null;
  }
  // codesign -d prints its details on stderr.
  const details = spawnSync("codesign", ["-dv", appBundle], { encoding: "utf8" });
  return details.status === 0 ? parseSignature(details.stderr) : null;
}

function parseSignature(text) {
  const field = (name) => text.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim() ?? null;
  const teamId = field("TeamIdentifier");
  return {
    identifier: field("Identifier"),
    teamId: teamId && teamId !== "not set" ? teamId : null,
    adhoc: /Signature=adhoc/.test(text),
  };
}

function bundleVersion(appBundle) {
  try {
    return execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString",
      join(appBundle, "Contents", "Info.plist")], { encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

/**
 * Downloads the signed Meetey.app for `version` and installs it at `appBundle`.
 *
 * Nothing replaces the installed app until the download has verified: a valid
 * signature, Meetey's bundle ID, `TEAM_ID`'s team, and the version asked for.
 * The swap is a rename, so a running recording keeps its own (now unlinked)
 * binary instead of having it rewritten underneath it.
 *
 * Returns `{ installed: true }` or `{ installed: false, reason }`. `teamId` and
 * `fetch` exist for testing; callers leave them alone.
 */
export async function installSignedApp({ version, appBundle, workDir, teamId = TEAM_ID, fetch = downloadFile }) {
  if (!teamId) return { installed: false, reason: "no signing team is configured" };

  const url = `https://github.com/${REPO}/releases/download/v${version}/${appAssetName(version)}`;
  const staging = join(workDir, `app-download-${process.pid}`);
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });

  try {
    const zip = join(staging, appAssetName(version));
    try {
      await fetch(url, zip);
    } catch (e) {
      return { installed: false, reason: /HTTP 404/.test(e.message)
        ? `release v${version} has no signed app`
        : `download failed (${e.message})` };
    }

    execFileSync("ditto", ["-x", "-k", zip, staging], { stdio: "ignore" });
    const downloaded = join(staging, "Meetey.app");
    const signature = existsSync(downloaded) ? signatureInfo(downloaded) : null;
    if (!signature) return { installed: false, reason: "the downloaded app's signature does not verify" };
    if (signature.identifier !== APP_ID || signature.teamId !== teamId) {
      return { installed: false, reason: `the downloaded app is signed as ${signature.identifier} by team ${signature.teamId ?? "none"}, not ${APP_ID} by ${teamId}` };
    }
    if (bundleVersion(downloaded) !== version) {
      return { installed: false, reason: `the downloaded app is version ${bundleVersion(downloaded)}, not ${version}` };
    }

    rmSync(appBundle, { recursive: true, force: true });
    mkdirSync(dirname(appBundle), { recursive: true });
    renameSync(downloaded, appBundle);
    return { installed: true, teamId: signature.teamId };
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}
