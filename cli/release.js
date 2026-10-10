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
 * Makes `install` and `update` install a tagged release, never whatever is on
 * the default branch.
 *
 * `npx adamjhc/meetey update` fetches the default branch, which can be ahead of
 * the last release — a half-finished change would then land on a machine that
 * records real meetings. So before doing anything, the CLI looks up the latest
 * release tag and, if it is not that version, re-runs itself from the tag:
 * `npx -y github:adamjhc/meetey#v<tag> <command>`. That includes running a
 * version *newer* than the release, which is a downgrade to what was released.
 *
 * Skipped, running the code at hand, when:
 * - this is a git checkout (`node cli/index.js install` while developing),
 * - `MEETEY_NO_UPDATE_CHECK=1`, which already means "do not look anything up",
 * - the lookup fails (offline, rate-limited, no release yet) — said out loud,
 *   because the user asked for a release and is getting something else.
 */

import { spawnSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { checkForUpdate, compareVersions, isDisabled, REPO } from "../mcp-server/update-check.js";
import { PKG_DIR, MEETEY_DIR } from "./paths.js";
import { yellow, step } from "./utils.js";

/** Set on the re-run so it cannot redirect again. */
const PINNED_ENV = "MEETEY_PINNED_RELEASE";

export function packageVersion() {
  return JSON.parse(readFileSync(join(PKG_DIR, "package.json"), "utf8")).version;
}

/**
 * Re-runs `command` from the latest release when this isn't it. Returns only
 * when the current code should carry on; otherwise exits with the re-run's
 * status.
 */
export async function runFromLatestRelease(command, args) {
  if (process.env[PINNED_ENV]) return;
  if (existsSync(join(PKG_DIR, ".git"))) return;
  if (isDisabled()) return;

  const current = packageVersion();
  const result = await checkForUpdate({ meeteyDir: MEETEY_DIR, currentVersion: current, force: true, timeoutMs: 5000 });
  if (!result?.latest) {
    yellow(`Could not find the latest Meetey release (${result?.error ?? "unknown error"}) — continuing with ${current}.`);
    return;
  }
  if (compareVersions(result.latest, current) === 0) return;

  step(`Switching to the latest release, v${result.latest} (this package is ${current})`);
  const rerun = spawnSync("npx", ["-y", `github:${REPO}#v${result.latest}`, command, ...args], {
    stdio: "inherit",
    env: { ...process.env, [PINNED_ENV]: result.latest },
  });
  if (rerun.error) {
    yellow(`Could not run v${result.latest}: ${rerun.error.message}`);
    process.exit(1);
  }
  process.exit(rerun.status ?? 1);
}
