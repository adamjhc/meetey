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

import { green, yellow, red, step } from "../utils.js";
import { MEETEY_DIR, HOME, BINARY_PATH } from "../paths.js";
// The same code the MCP server runs, so `meetey watch enable` and `/meetey watch
// on` cannot drift into behaving differently.
import {
  watchStatus, enableWatch, disableWatch, watchLog,
} from "../../mcp-server/watch-agent.js";

const ctx = { meeteyDir: MEETEY_DIR, home: HOME };

export function watch(sub) {
  switch (sub) {
    case "enable":  return enable();
    case "disable": return disable();
    case "status":  return status();
    case "logs":
    case "log":     return logs();
    default:
      console.log(`
Usage: npx adamjhc/meetey watch <enable|disable|status|log>

  enable    Put Meetey's icon in the menu bar, starting at login
  disable   Remove it
  status    Is it running?
  log       Show recent activity (alias: logs)

The icon turns orange while Chrome, Zoom or Teams is in a call. Click it to
record audio and screen. Nothing records unless you click.

You can also drive this from Claude Code with /meetey watch.
`);
  }
}

function enable() {
  step("Starting the watch agent");
  const result = enableWatch({ ...ctx, nodePath: process.execPath, captureBinary: BINARY_PATH });

  if (result.error) {
    red(result.error);
    if (result.detail) console.log(`  ${result.detail}`);
    if (result.fix) console.log(`\n  ${result.fix}\n`);
    console.log("  (Meetey's menu bar icon was not enabled)\n");
    process.exit(1);
  }

  green("Meetey is in the menu bar");
  console.log(`
Its icon turns orange while Chrome, Zoom or Teams is in a call. Click it then to
record audio and screen; right-click for the menu. Nothing records unless you
click. Tell your menu bar manager to keep it visible — it's the one icon Meetey
uses, for recordings too.

  npx adamjhc/meetey watch status    Check it
  npx adamjhc/meetey watch log       See what it has done
  npx adamjhc/meetey watch disable   Turn it off
`);
}

function disable() {
  step("Stopping the watch agent");
  const result = disableWatch(ctx);
  if (result.error) {
    red(result.error);
    process.exit(1);
  }
  green(result.message);
}

function status() {
  const state = watchStatus(ctx);
  const healthy = state.enabled && state.canSeeWindows !== false;
  (healthy ? green : yellow)(state.message);
  if (state.enabled) {
    const sight = state.canSeeWindows === null
      ? "not reported yet"
      : state.canSeeWindows ? "yes" : "NO — recordings it starts can't capture anything";
    console.log(`  Screen Recording: ${sight}`);
    if (state.lastCheck) console.log(`  last checked:     ${state.lastCheck}`);
  }
  console.log(`  plist: ${state.plistPath}`);
  console.log(`  log:   ${state.logPath}`);
}

function logs() {
  const result = watchLog({ ...ctx, lines: 40 });
  if (result.message && result.lines.length === 0) {
    yellow(result.message);
    return;
  }
  console.log(result.lines.join("\n"));
}
