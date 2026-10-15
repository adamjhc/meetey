/*
 * Copyright 2026 John Joseph
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
 * Turning the watch agent on and off.
 *
 * Lives here rather than in `cli/` because both the `meetey watch` command and
 * the MCP server need it, and only `mcp-server/` and `daemon/` are copied into
 * `~/.meetey` at install time — the CLI runs from the npx package and is not on
 * the user's machine afterwards.
 *
 * Every path is derived from arguments rather than read from the environment, so
 * the CLI's notion of where meetey lives and the server's cannot drift apart.
 */

import { execFileSync } from "child_process";
import { existsSync, mkdirSync, writeFileSync, unlinkSync, readFileSync } from "fs";
import { dirname, join } from "path";

export const WATCH_LABEL = "com.adamjhcox.meetey.watch";

/**
 * Labels earlier versions installed the agent under. Removed whenever the
 * watcher is enabled or disabled: launchd would happily run an old-label agent
 * next to the new one, and two watchers means two prompts for every meeting.
 */
const LEGACY_WATCH_LABELS = ["com.meetey.watch"];

export function watchPaths({ meeteyDir, home }) {
  return {
    label: WATCH_LABEL,
    plistPath: join(home, "Library", "LaunchAgents", `${WATCH_LABEL}.plist`),
    scriptPath: join(meeteyDir, "daemon", "watch.js"),
    logPath: join(meeteyDir, "logs", "watch.log"),
    logsDir: join(meeteyDir, "logs"),
    healthPath: join(meeteyDir, "state", "watch-health.json"),
    offPath: join(meeteyDir, "state", "watch-off"),
  };
}

/**
 * Whether the user turned the agent off with `watch disable`. Since 2.7.1 it is
 * on by default — install and update enable it, because it never records
 * without a click — so turning it off has to be remembered, or the next update
 * would switch it straight back on. Quitting from the menu is not this: that
 * lasts until the next login, like any menu bar app.
 */
export function watchTurnedOff({ meeteyDir, home }) {
  return existsSync(watchPaths({ meeteyDir, home }).offPath);
}

/**
 * What the agent can currently see.
 *
 * Written by the agent itself, every poll — and it has to be the agent, not a
 * check run from the CLI. Screen Recording permission is granted per responsible
 * process: a `--list-windows` run from a terminal is attributed to the terminal,
 * while the same binary run from a LaunchAgent is attributed to the agent's node.
 * They differ, so a check performed by the installer can pass while the thing it
 * just installed is blind.
 */
export function writeHealth({ meeteyDir, home }, health) {
  const { healthPath } = watchPaths({ meeteyDir, home });
  try {
    mkdirSync(dirname(healthPath), { recursive: true });
    writeFileSync(healthPath, JSON.stringify(health, null, 2) + "\n");
  } catch {
    // Health reporting must never take the agent down.
  }
}

export function readHealth({ meeteyDir, home }) {
  const { healthPath } = watchPaths({ meeteyDir, home });
  if (!existsSync(healthPath)) return null;
  try {
    return JSON.parse(readFileSync(healthPath, "utf8"));
  } catch {
    return null;
  }
}

function clearHealth({ meeteyDir, home }) {
  const { healthPath } = watchPaths({ meeteyDir, home });
  try {
    unlinkSync(healthPath);
  } catch {
    // Already gone.
  }
}

/**
 * Blocking sleep-poll, matching the technique the MCP server already uses.
 *
 * `onTick` runs each iteration so a caller can show progress. The wait blocks
 * the event loop, so a timer-driven spinner would simply never fire — the loop
 * itself has to drive the frames. The quantum is short enough to animate at a
 * readable rate and still costs nothing across a 25s wait.
 */
function waitFor(ms, done, onTick) {
  const deadline = Date.now() + ms;
  let frame = 0;
  while (Date.now() < deadline && !done()) {
    onTick?.(frame++);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 80);
  }
  return done();
}

/** Braille dots: the one spinner that reads as motion rather than as characters. */
const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

/**
 * A spinner, when there is a terminal to draw it in.
 *
 * Piped or redirected output gets one plain line instead — carriage returns and
 * braille frames in a log file are noise, and a CI transcript should read as
 * text. This is the terminal's equivalent of honouring reduced motion.
 */
export function progress(label, { stream = process.stdout } = {}) {
  const animated = Boolean(stream.isTTY);
  if (!animated) stream.write(`${label}\n`);
  return {
    tick(frame) {
      if (!animated) return;
      stream.write(`\r  ${SPINNER[frame % SPINNER.length]} ${label}`);
    },
    done() {
      if (animated) stream.write(`\r${" ".repeat(label.length + 6)}\r`);
    },
  };
}

const escapeXml = (s) =>
  s.replace(/[<>&'"]/g, (c) =>
    ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[c]));

function plistBody({ nodePath, scriptPath, logPath, captureBinary }) {
  // A LaunchAgent, not a LaunchDaemon: `display dialog` needs the user's GUI
  // session, and this must never run for a user who is not logged in.
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${escapeXml(WATCH_LABEL)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escapeXml(nodePath)}</string>
    <string>${escapeXml(scriptPath)}</string>
  </array>${captureBinary ? `
  <!-- Which meetey-capture to run. Without it the agent falls back to a path
       derived from its own location, which once pointed at the bare build
       output instead of Meetey.app. -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>MEETEY_BINARY</key><string>${escapeXml(captureBinary)}</string>
  </dict>` : ""}
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- Without this a crash-looping agent restarts every 10s and fills the log. -->
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${escapeXml(logPath)}</string>
  <key>StandardErrorPath</key><string>${escapeXml(logPath)}</string>
</dict>
</plist>
`;
}

/** Whether the agent — and so Meetey's menu bar icon — is running. */
export function watchAgentRunning() {
  return isLoaded();
}

function isLoaded(label = WATCH_LABEL) {
  try {
    execFileSync("launchctl", ["print", `gui/${process.getuid()}/${label}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/**
 * How long to wait for an unloaded agent to actually go.
 *
 * `launchctl bootout` returns as soon as it has signalled the job, but launchd
 * keeps the label registered until the process exits — and the watcher's
 * SIGTERM handler deliberately waits up to 15s to finish a running capture.
 * Bootstrapping the same label before then fails with "Bootstrap failed: 5:
 * Input/output error", which is how `update` came to report it could not
 * restart the watcher and leave it off.
 */
const UNLOAD_TIMEOUT_MS = 20_000;

function bootout(label = WATCH_LABEL) {
  try {
    execFileSync("launchctl", ["bootout", `gui/${process.getuid()}/${label}`], { stdio: "ignore" });
  } catch {
    // Not loaded, which is the state we were aiming for anyway.
  }
  waitFor(UNLOAD_TIMEOUT_MS, () => !isLoaded(label));
}

/**
 * Loads the agent, retrying briefly: even after the label is gone launchd can
 * refuse for a moment. Throws with launchctl's own reason, which the bare
 * "Command failed" message used to hide.
 */
function bootstrap(plistPath) {
  let reason = "";
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) waitFor(1000, () => false);
    try {
      execFileSync("launchctl", ["bootstrap", `gui/${process.getuid()}`, plistPath], {
        stdio: ["ignore", "ignore", "pipe"],
        encoding: "utf8",
      });
      return;
    } catch (e) {
      reason = String(e.stderr || e.message).split("\n").map((l) => l.trim()).filter(Boolean)[0] ?? "";
    }
  }
  throw new Error(`launchctl bootstrap failed — ${reason}`);
}

/**
 * Unloads and deletes any agent installed under a legacy label. Returns whether
 * one was there, so `update` can carry an enabled watcher across the rename
 * instead of silently leaving it off.
 */
export function removeLegacyWatch({ home }) {
  let found = false;
  for (const label of LEGACY_WATCH_LABELS) {
    const plistPath = join(home, "Library", "LaunchAgents", `${label}.plist`);
    if (!existsSync(plistPath) && !isLoaded(label)) continue;
    found = true;
    bootout(label);
    try { unlinkSync(plistPath); } catch { /* already gone */ }
  }
  return found;
}

export function watchStatus({ meeteyDir, home }) {
  const paths = watchPaths({ meeteyDir, home });
  const installed = existsSync(paths.plistPath);
  const running = isLoaded();
  const available = existsSync(paths.scriptPath);

  const health = readHealth({ meeteyDir, home });

  return {
    enabled: installed && running,
    available,
    plistInstalled: installed,
    agentRunning: running,
    // "Loaded" is what launchctl knows. Whether it can see anything is a
    // different question, and the one that actually goes wrong.
    canSeeWindows: health?.canSeeWindows ?? null,
    lastCheck: health?.at ?? null,
    plistPath: paths.plistPath,
    logPath: paths.logPath,
    message: watchMessage({
      available,
      installed,
      running,
      canSeeWindows: health?.canSeeWindows ?? null,
    }),
  };
}

/**
 * The one-line verdict. Pure, so every combination can be exercised — including
 * running-but-blind, which is the state that matters most and the one hardest to
 * reproduce, since it needs a real LaunchAgent and a revoked permission.
 */
export function watchMessage({ available, installed, running, canSeeWindows }) {
  if (!available) return "The watch agent is not installed. Run: npx adamjhc/meetey update";
  if (installed && running && canSeeWindows === false) {
    return "Meetey's menu bar icon is running but has no Screen Recording permission — recordings " +
      "it starts can't capture anything. Allow node in System Settings → Privacy & Security → Screen Recording.";
  }
  if (installed && running) return "Meetey's menu bar icon is running. It records only when you click it.";
  if (installed) return "Meetey's menu bar icon was quit — it comes back at login, or now with: npx adamjhc/meetey watch enable";
  return "Meetey's menu bar icon is off.";
}

/**
 * `progressStream` is where the "checking" line goes. The CLI shows it on
 * stdout; the MCP server must pass stderr, because its stdout *is* the
 * protocol and a stray line there corrupts the reply.
 */
/**
 * `strict`: tear the agent back down when it lacks Screen Recording. Install
 * and update pass false — the icon is useful without it (it still shows calls
 * and recordings), and the user only has to grant the permission rather than
 * enable it again afterwards.
 */
export function enableWatch({ meeteyDir, home, nodePath, captureBinary, progressStream = process.stdout, strict = true }) {
  const paths = watchPaths({ meeteyDir, home });

  if (!existsSync(paths.scriptPath)) {
    return { error: `Watch agent not found at ${paths.scriptPath}. Run: npx adamjhc/meetey update` };
  }
  if (captureBinary && !existsSync(captureBinary)) {
    return { error: `meetey-capture binary not found at ${captureBinary}. Run: npx adamjhc/meetey install` };
  }

  try {
    // Stale health from a previous run would be mistaken for this one's verdict.
    clearHealth({ meeteyDir, home });
    try { unlinkSync(paths.offPath); } catch { /* wasn't turned off */ }
    mkdirSync(paths.logsDir, { recursive: true });
    mkdirSync(dirname(paths.plistPath), { recursive: true });
    writeFileSync(paths.plistPath, plistBody({
      nodePath,
      scriptPath: paths.scriptPath,
      logPath: paths.logPath,
      captureBinary,
    }));

    // Replace any previous version rather than stacking two agents.
    removeLegacyWatch({ home });
    bootout();
    bootstrap(paths.plistPath);
  } catch (e) {
    return {
      error: `Could not start the watcher: ${e.message.split("\n")[0]}`,
      fix: "Run `npx adamjhc/meetey watch enable` again in a minute. If it keeps failing, " +
        `\`launchctl print gui/${process.getuid()}/${WATCH_LABEL}\` shows what launchd thinks of it.`,
    };
  }

  // Wait for the agent's icon to report whether it may record the screen.
  // Declaring success without this is how an agent ends up installed, running,
  // and unable to record anything — which nobody finds out until a meeting is lost.
  const spinner = progress("Checking it can record", { stream: progressStream });
  const reported = waitFor(
    25_000,
    () => readHealth({ meeteyDir, home }) !== null,
    (frame) => spinner.tick(frame),
  );
  spinner.done();
  const health = readHealth({ meeteyDir, home });

  if (reported && !health?.canSeeWindows && !strict) {
    return {
      enabled: true,
      permissionNeeded: true,
      plistPath: paths.plistPath,
      logPath: paths.logPath,
      warning: "Meetey is in the menu bar, but node has no Screen Recording permission, so recording from it won't capture anything yet.",
      fix: "System Settings → Privacy & Security → Screen Recording → enable node. Then quit Meetey from its menu and run `npx adamjhc/meetey watch enable`.",
    };
  }

  if (!reported || !health?.canSeeWindows) {
    // Leave nothing behind that looks enabled but cannot work.
    bootout();
    try { unlinkSync(paths.plistPath); } catch { /* nothing to remove */ }

    return {
      error: !reported
        ? "Meetey's menu bar icon started but never reported in. Check the log: " + paths.logPath
        : "Meetey's menu bar icon has no Screen Recording permission, so it couldn't record a meeting.",
      permissionNeeded: !reported ? undefined : true,
      detail: health?.error ?? undefined,
      fix:
        "Node needs Screen Recording permission, separately from Meetey: the agent runs under it. " +
        "System Settings → Privacy & Security → Screen Recording → enable node, " +
        "then run this again.",
      enabled: false,
    };
  }

  return {
    enabled: true,
    plistPath: paths.plistPath,
    logPath: paths.logPath,
    message:
      "Meetey is in the menu bar. Its icon turns orange while Chrome, Zoom or Teams is in a " +
      "call; clicking it then records audio and screen. Nothing records unless the user clicks.",
  };
}

export function disableWatch({ meeteyDir, home }) {
  const paths = watchPaths({ meeteyDir, home });
  try {
    removeLegacyWatch({ home });
    bootout();
    if (existsSync(paths.plistPath)) unlinkSync(paths.plistPath);
    mkdirSync(dirname(paths.offPath), { recursive: true });
    writeFileSync(paths.offPath, `turned off ${new Date().toISOString()}\n`);
  } catch (e) {
    return { error: `Could not stop the watcher: ${e.message.split("\n")[0]}` };
  }
  return {
    enabled: false,
    // Stopping the watcher is not stopping a recording. Conflating the two would
    // have someone turn this off mid-meeting and assume their capture ended.
    message: "Meetey's menu bar icon is off, and stays off through updates until `npx adamjhc/meetey watch enable`. A recording it started is stopped and saved first — turning it off tears down everything it started, so it is finished properly rather than abandoned.",
  };
}

export function watchLog({ meeteyDir, home, lines = 40 }) {
  const paths = watchPaths({ meeteyDir, home });
  if (!existsSync(paths.logPath)) return { lines: [], message: "The watcher has no log yet." };
  const all = readFileSync(paths.logPath, "utf8").trimEnd().split("\n");
  return { lines: all.slice(-lines), logPath: paths.logPath };
}
