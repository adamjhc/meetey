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

import { existsSync, cpSync } from "fs";
import { join } from "path";
import { green, yellow, red, step, run } from "../utils.js";
import { PKG_DIR, APP_BUNDLE, BINARY_PATH, BUILT_BINARY, SERVER_DIR, DAEMON_DIR, SKILL_PATH, MEETEY_DIR, HOME } from "../paths.js";
import { installCaptureApp, registerMcpServer, installSkill, registerKeybindings } from "./install.js";

export async function update() {
  // --- Verify installed ---
  // Any earlier layout counts as installed: before 2.1.2 the binary ran from the
  // build directory, and before 2.5.4 the one in Meetey.app was `meetey-capture`.
  if (!existsSync(APP_BUNDLE) && !existsSync(BUILT_BINARY)) {
    red("meetey-capture binary not found. Run: npx adamjhc/meetey install");
    process.exit(1);
  }

  // --- Meetey.app (signed release, or rebuilt from source) ---
  await installCaptureApp();

  // --- Update MCP server ---
  step("Updating MCP server");
  cpSync(join(PKG_DIR, "mcp-server"), SERVER_DIR, { recursive: true, force: true });
  run("npm install --silent", { cwd: SERVER_DIR });
  green("MCP server updated");

  // The watch agent: Meetey's menu bar icon. Started further down.
  //
  // Guarded because a half-applied update is worse than a missing optional
  // component: this runs after the MCP server has already been replaced, so
  // throwing here would leave the install broken rather than merely incomplete.
  step("Installing the watch agent");
  if (existsSync(join(PKG_DIR, "daemon"))) {
    cpSync(join(PKG_DIR, "daemon"), DAEMON_DIR, { recursive: true, force: true });
    green(`Watch agent installed to ${DAEMON_DIR}`);
  } else {
    yellow("Watch agent not present in this package — skipping (the watcher will be unavailable)");
  }

  // --- Re-register (command/paths may have changed) ---
  step("Re-registering MCP server");
  registerMcpServer();
  green("MCP server registration refreshed");

  // --- Update skill ---
  step("Updating /meetey skill");
  installSkill();
  green(`Skill updated at ${SKILL_PATH}`);

  // --- Update keybindings ---
  step("Updating Claude Code shortcuts");
  registerKeybindings();
  green("Shortcuts updated (they work while Claude Code is focused)");

  // Turn the agent on, or restart it on the code just installed.
  //
  // On by default since 2.7.1: it never records without a click, so there is
  // nothing to opt into — unless the user turned it off with `watch disable`.
  //
  // Restarting matters too: launchd keeps running whatever it loaded, so
  // replacing the files on disk changes nothing until the agent restarts. An
  // update that fixes the agent otherwise fixes nothing, while the user
  // reasonably believes they are on the new version. This is how a
  // recording-killing bug survived being fixed.
  const { watchTurnedOff, enableWatch, removeLegacyWatch } = await import("../../mcp-server/watch-agent.js");
  const watchCtx = { meeteyDir: MEETEY_DIR, home: HOME };
  removeLegacyWatch(watchCtx);
  if (existsSync(join(DAEMON_DIR, "watch.js"))) {
    if (watchTurnedOff(watchCtx)) {
      console.log("  Menu bar icon left off (you turned it off). On again: npx adamjhc/meetey watch enable");
    } else {
      step("Starting Meetey in the menu bar");
      const result = enableWatch({ ...watchCtx, nodePath: process.execPath, captureBinary: BINARY_PATH, strict: false });
      if (result.error) {
        yellow(`Could not start the menu bar icon: ${result.error}`);
        if (result.fix) console.log(`  ${result.fix}`);
      } else if (result.warning) {
        yellow(result.warning);
        console.log(`  ${result.fix}`);
      } else {
        green("Meetey is in the menu bar — click its icon in a call to record");
      }
    }
  }

  // Prove it works rather than assuming. A rebuilt binary is re-signed, so macOS
  // treats it as new and the permission it had may not carry over — which is
  // exactly how a watcher ends up installed, running, and unable to record.
  step("Checking this machine can record");
  const { verify } = await import("./verify.js");
  const ready = verify();

  if (ready) {
    green("\nMeetey updated. Restart Claude Code to pick up changes.");
  } else {
    yellow("\nMeetey updated, but this machine cannot record yet — fix the above first.");
  }
}
