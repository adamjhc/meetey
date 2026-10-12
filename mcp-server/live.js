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
 * Reading a meeting while it is still happening.
 *
 * The capture binary writes `<session>-live/` as it records (LiveOutput.swift):
 * finished transcript lines per speaker, the line still being spoken, and each
 * keyframe with its OCR text. This turns that directory into one timeline. The
 * live terminal view (`npx adamjhc/meetey live`) reads it, and so will the
 * in-call assistant. Same speaker labels and echo filter as the post-meeting
 * transcript, so the two read alike.
 */

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { fileURLToPath } from "url";
import { formatTimestamp, mergeSpeakers, micPathFor } from "./transcript.js";

/** `<session>.wav` → `<session>-live`. */
export function livePathFor(wavPath) {
  return wavPath.replace(/\.wav$/, "-live");
}

/**
 * Parses a JSONL file that may be mid-write. Only newline-terminated lines
 * count: a reader can catch the writer between bytes, and half a line is not
 * a line.
 */
export function readJsonLines(path) {
  if (!existsSync(path)) return [];
  const text = readFileSync(path, "utf8");
  const complete = text.slice(0, text.lastIndexOf("\n") + 1);
  return complete.split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
}

function readPartial(path) {
  try {
    const partial = JSON.parse(readFileSync(path, "utf8"));
    return partial.text ? partial : null;
  } catch {
    return null;
  }
}

const toSegment = (line) => ({ text: line.text, fromMs: line.startMs, toMs: line.endMs });

/**
 * The meeting so far: `lines` (merged, labelled Them / Me, echoes dropped),
 * the `partials` still being spoken, and `frames`. `sinceMs` keeps only what
 * started at or after that offset, for callers that already have the rest.
 * `wavPath`, when given, lets the mic's silent stretches be filtered the same
 * way the post-meeting transcript does.
 */
export function readLive(liveDir, { sinceMs = 0, wavPath = null } = {}) {
  const them = readJsonLines(join(liveDir, "transcript-them.jsonl")).map(toSegment);
  const me = readJsonLines(join(liveDir, "transcript-me.jsonl")).map(toSegment);
  const micWavPath = wavPath && existsSync(micPathFor(wavPath)) ? micPathFor(wavPath) : null;

  const lines = (me.length ? mergeSpeakers({ them, me, micWavPath }) : them.map((s) => ({ ...s, speaker: "Them" })))
    .filter((s) => (s.fromMs ?? 0) >= sinceMs);

  const partials = ["them", "me"]
    .map((speaker) => readPartial(join(liveDir, `partial-${speaker}.json`)))
    .filter(Boolean)
    .map((p) => ({ speaker: p.speaker === "me" ? "Me" : "Them", fromMs: p.startMs ?? null, text: p.text }));

  const frames = readJsonLines(join(liveDir, "frames.jsonl"))
    .filter((f) => (f.offsetMs ?? 0) >= sinceMs);

  return { lines, partials, frames };
}

/** One transcript line as the live view prints it. */
export function formatLine(line) {
  return `${formatTimestamp(line.fromMs)} ${line.speaker}: ${line.text}`;
}

/** One keyframe as the live view prints it. */
export function formatFrame(frame) {
  const text = (frame.ocrText ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
  const preview = text.slice(0, 3).join(" · ");
  const more = text.length > 3 ? ` (+${text.length - 3} lines)` : "";
  return `${formatTimestamp(frame.offsetMs)} ▣ ${frame.revisit ? "screen returned" : "screen"}${preview ? `: ${preview}${more}` : ""}`;
}

// `node live.js --selftest`
if (process.argv[1] === fileURLToPath(import.meta.url) && process.argv.includes("--selftest")) {
  const { mkdtempSync, writeFileSync, rmSync } = await import("fs");
  const { tmpdir } = await import("os");
  const dir = mkdtempSync(join(tmpdir(), "meetey-live-selftest-"));
  const failures = [];
  try {
    writeFileSync(join(dir, "transcript-them.jsonl"),
      '{"speaker":"them","startMs":360,"endMs":4740,"text":"The checkout service is throwing 500s."}\n' +
      '{"speaker":"them","startMs":9240,"endMs":9900,"text":"Great."}\n' +
      '{"speaker":"them","startMs":99');                       // mid-write
    writeFileSync(join(dir, "transcript-me.jsonl"),
      '{"speaker":"me","startMs":5340,"endMs":8460,"text":"I will roll back the release."}\n' +
      '{"speaker":"me","startMs":700,"endMs":4500,"text":"the checkout service is throwing 500s"}\n'); // echo
    writeFileSync(join(dir, "partial-them.json"), '{"speaker":"them","startMs":12000,"text":"Let us regroup"}');
    writeFileSync(join(dir, "partial-me.json"), '{"speaker":"me","text":""}');
    writeFileSync(join(dir, "frames.jsonl"), '{"offsetMs":1000,"file":"/f/0001.jpg","ocrText":"ERROR 500\\nPOST /checkout"}\n');

    const live = readLive(dir);
    const shown = live.lines.map(formatLine);
    if (shown.join("|") !== "[00:00] Them: The checkout service is throwing 500s.|[00:05] Me: I will roll back the release.|[00:09] Them: Great.") {
      failures.push(`lines: ${JSON.stringify(shown)}`);
    }
    if (live.partials.length !== 1 || live.partials[0].speaker !== "Them") failures.push(`partials: ${JSON.stringify(live.partials)}`);
    if (formatFrame(live.frames[0]) !== "[00:01] ▣ screen: ERROR 500 · POST /checkout") failures.push(`frame: ${formatFrame(live.frames[0])}`);
    if (readLive(dir, { sinceMs: 5000 }).lines.length !== 2) failures.push("sinceMs");
    if (livePathFor("/r/meetey-1.wav") !== "/r/meetey-1-live") failures.push("livePathFor");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  if (failures.length) {
    for (const f of failures) console.error(`selftest: FAIL — ${f}`);
    process.exit(1);
  }
  console.log("selftest: PASS (partial-line safety, speaker merge and echo filter, partials, frames, sinceMs)");
}
