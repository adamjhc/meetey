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
 * `npx adamjhc/meetey assistant [<live-dir>]`: opens the in-call assistant.
 *
 * Recordings open it themselves; this is for reopening it after closing, for a
 * meeting that has already ended, or for a `--replay` directory. A panel already
 * open for that meeting is brought forward instead of starting a second.
 */

import { spawn } from "child_process";
import { existsSync, openSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { livePathFor } from "../../mcp-server/live.js";
import { readActive } from "../../mcp-server/session-state.js";
import { BINARY_PATH, MEETEY_DIR, RECORDINGS_DIR } from "../paths.js";
import { which } from "../utils.js";

export async function assistant(target) {
  if (!existsSync(BINARY_PATH)) {
    console.log("Meetey isn't installed. Run: npx adamjhc/meetey install");
    return false;
  }

  const active = readActive(MEETEY_DIR);
  const liveDir = target ?? (active?.outputPath ? (active.liveDir ?? livePathFor(active.outputPath)) : latestLiveDir());
  if (!liveDir || !existsSync(liveDir)) {
    console.log("No meeting to open the assistant for. It opens by itself when a recording starts (macOS 26 or later).");
    return false;
  }

  const args = ["--panel", "--live", liveDir, "--title", active?.windowTitle || liveDir.split("/").pop()];
  if (active?.framesDir) args.push("--frames-dir", active.framesDir);
  else if (existsSync(liveDir.replace(/-live$/, "-frames"))) args.push("--frames-dir", liveDir.replace(/-live$/, "-frames"));
  if (active?.pid) args.push("--capture-pid", String(active.pid));
  const claude = which("claude");
  if (claude) args.push("--claude", claude);

  const log = openSync(join(liveDir, "panel.log"), "a");
  spawn(BINARY_PATH, args, { detached: true, stdio: ["ignore", log, log] }).unref();
  console.log(`Assistant opened for ${liveDir.split("/").pop()} — ⌃⌥M shows or hides it.`);
  return true;
}

function latestLiveDir() {
  if (!existsSync(RECORDINGS_DIR)) return null;
  return readdirSync(RECORDINGS_DIR)
    .filter((name) => /^meetey-\d+-live$/.test(name))
    .map((name) => join(RECORDINGS_DIR, name))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0] ?? null;
}
