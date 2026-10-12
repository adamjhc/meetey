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
 * `npx adamjhc/meetey live [<live-dir>]`: the meeting's transcript and screen
 * text, as it happens, in a terminal.
 *
 * Follows the running recording until it ends. With no recording running it
 * prints the most recent session's live transcript and exits; a live directory
 * can also be named directly (which is how `--replay` output is checked).
 *
 * Reads files only — it never touches the capture subsystem, so it is safe to
 * run during a recording.
 */

import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { formatFrame, formatLine, livePathFor, readLive } from "../../mcp-server/live.js";
import { readActive } from "../../mcp-server/session-state.js";
import { MEETEY_DIR, RECORDINGS_DIR } from "../paths.js";

const POLL_MS = 500;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const bold = (s) => `\x1b[1m${s}\x1b[0m`;

export async function live(target) {
  const active = readActive(MEETEY_DIR);
  let liveDir;
  let wavPath = null;
  let following = false;

  if (target) {
    liveDir = target;
  } else if (active?.outputPath) {
    liveDir = active.liveDir ?? livePathFor(active.outputPath);
    wavPath = active.outputPath;
    following = true;
  } else {
    liveDir = latestLiveDir();
  }

  if (!liveDir || !existsSync(liveDir)) {
    console.log(target
      ? `No live directory at ${target}.`
      : "No recording is running and no live transcript has been written yet. " +
        "Live transcripts need macOS 26 or later, and start with the next recording.");
    return false;
  }

  const title = active?.windowTitle || active?.sessionId || liveDir.split("/").pop();
  console.log(bold(following ? `Live — ${title}` : `Live transcript — ${title}`) +
    dim(following ? "  (follows the recording; Ctrl+C to stop watching)" : ""));

  const seen = new Set();
  const tty = process.stdout.isTTY;
  let partialShown = false;

  const clearPartial = () => {
    if (tty && partialShown) process.stdout.write("\r\x1b[2K");
    partialShown = false;
  };

  const tick = () => {
    const { lines, partials, frames } = readLive(liveDir, { wavPath });
    const fresh = [
      ...lines.map((l) => ({ key: `l:${l.speaker}:${l.fromMs}:${l.text}`, at: l.fromMs ?? 0, text: formatLine(l) })),
      ...frames.map((f) => ({ key: `f:${f.offsetMs}:${f.file}`, at: f.offsetMs ?? 0, text: dim(formatFrame(f)) })),
    ].filter((item) => !seen.has(item.key)).sort((a, b) => a.at - b.at);

    if (fresh.length) clearPartial();
    for (const item of fresh) {
      seen.add(item.key);
      console.log(item.text);
    }

    // The line still being spoken, rewritten in place on a terminal.
    if (tty && following) {
      const partial = partials.map((p) => `${p.speaker}: ${p.text}`).join("   ");
      clearPartial();
      if (partial) {
        const width = Math.max(20, (process.stdout.columns ?? 100) - 4);
        process.stdout.write(dim(`… ${partial.length > width ? `…${partial.slice(-width)}` : partial}`));
        partialShown = true;
      }
    }
  };

  tick();
  if (!following) return true;

  await new Promise((resolve) => {
    const timer = setInterval(() => {
      tick();
      const still = readActive(MEETEY_DIR);
      if (!still || still.sessionId !== active.sessionId) {
        clearInterval(timer);
        // The last lines are written as the capture finalises.
        setTimeout(() => {
          tick();
          clearPartial();
          console.log(dim("Recording ended."));
          resolve();
        }, 1500);
      }
    }, POLL_MS);
    process.on("SIGINT", () => {
      clearInterval(timer);
      clearPartial();
      resolve();
    });
  });
  return true;
}

function latestLiveDir() {
  if (!existsSync(RECORDINGS_DIR)) return null;
  const dirs = readdirSync(RECORDINGS_DIR)
    .filter((name) => /^meetey-\d+-live$/.test(name))
    .map((name) => join(RECORDINGS_DIR, name))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return dirs[0] ?? null;
}
