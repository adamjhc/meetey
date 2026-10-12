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
 * Turning whisper's output into the transcript file.
 *
 * Lives here so the watch agent and the MCP server produce byte-identical
 * transcripts. The agent writes one the moment a recording ends — the meeting is
 * then legible without Claude, without authentication, and without anyone
 * remembering to run anything. Notes still need Claude; a transcript does not,
 * and making it wait for one is how a recording ends up sitting unread.
 */

import { closeSync, existsSync, openSync, readFileSync, readSync, writeFileSync } from "fs";
import { fileURLToPath } from "url";

/** `[mm:ss]`, or `[h:mm:ss]` once past the hour. Matches the notes format. */
export function formatTimestamp(ms) {
  if (ms === null || ms === undefined) return "[--:--]";
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `[${h}:${pad(m)}:${pad(s)}]` : `[${pad(m)}:${pad(s)}]`;
}

/**
 * Reads whisper's JSON into `{ text, fromMs, toMs }` segments.
 *
 * whisper.cpp has used both `transcription` and `segments` as the top-level key
 * and both `text` and `sentence` per segment, so accept either rather than break
 * on a version change.
 */
export function readWhisperSegments(jsonPath) {
  if (!existsSync(jsonPath)) return null;
  try {
    const raw = JSON.parse(readFileSync(jsonPath, "utf8"));
    const segments = raw.transcription ?? raw.segments ?? [];
    return segments
      .map((s) => ({
        text: (s.text ?? s.sentence ?? "").trim(),
        fromMs: s.offsets?.from ?? null,
        toMs: s.offsets?.to ?? null,
      }))
      .filter((s) => s.text.length > 0);
  } catch {
    return null;
  }
}

/**
 * Your microphone, recorded beside the call audio as `<session>-mic.wav`.
 *
 * The call recording is what the meeting app *plays*, and it never plays your
 * own voice back to you — so without this file your side of the meeting is
 * missing from the transcript entirely. Both files share a clock (the capture
 * binary pads the mic file to keep it aligned), so their segments interleave by
 * timestamp.
 */
export function micPathFor(wavPath) {
  return wavPath.replace(/\.wav$/, "-mic.wav");
}

/** Matches the capture binary's audible threshold: near-digital-silence is not speech. */
const AUDIBLE_AMPLITUDE = 300;
const WAV_HEADER_BYTES = 44;
const BYTES_PER_MS = 32; // 16 kHz × 16-bit mono

/** Loudest sample between two offsets of a 16 kHz mono 16-bit WAV, or null if unreadable. */
export function peakAmplitude(wavPath, fromMs, toMs) {
  let fd;
  try {
    fd = openSync(wavPath, "r");
    const start = WAV_HEADER_BYTES + Math.max(0, Math.floor(fromMs)) * BYTES_PER_MS;
    const length = Math.max(0, Math.ceil(toMs - fromMs)) * BYTES_PER_MS;
    const buffer = Buffer.alloc(length);
    const read = readSync(fd, buffer, 0, length, start);
    let peak = 0;
    for (let i = 0; i + 1 < read; i += 2) peak = Math.max(peak, Math.abs(buffer.readInt16LE(i)));
    return peak;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

const words = (text) => new Set(text.toLowerCase().match(/[a-z0-9']+/g) ?? []);

/** Share of words two segments have in common (Jaccard). */
function similarity(a, b) {
  const x = words(a);
  const y = words(b);
  if (x.size === 0 || y.size === 0) return 0;
  let shared = 0;
  for (const w of x) if (y.has(w)) shared += 1;
  return shared / (x.size + y.size - shared);
}

/** How far apart two segments may start and still be the same speech arriving twice. */
const ECHO_WINDOW_MS = 2000;
const ECHO_SIMILARITY = 0.6;

/**
 * Interleaves the call and mic transcripts as `Them` and `Me`.
 *
 * Two kinds of mic segment are dropped, both things whisper produces from audio
 * that is not you speaking:
 *
 * - **Silence.** The mic file is padded with silence (late start, pauses, a
 *   headset swap), and whisper invents text on silence — "Thank you." is the
 *   classic. A segment whose audio never rises above the audible threshold is
 *   discarded. `micWavPath` is needed for this; without it nothing is dropped.
 * - **Echo.** On speakers rather than headphones the mic hears everyone else
 *   too, so their words arrive twice. A mic segment that starts within two
 *   seconds of a call segment and shares most of its words is the call heard
 *   through the room, not you.
 */
export function mergeSpeakers({ them, me, micWavPath = null }) {
  const kept = me.filter((segment) => {
    if (micWavPath && segment.fromMs !== null && segment.toMs !== null) {
      const peak = peakAmplitude(micWavPath, segment.fromMs, segment.toMs);
      if (peak !== null && peak < AUDIBLE_AMPLITUDE) return false;
    }
    return !them.some((other) =>
      other.fromMs !== null && segment.fromMs !== null &&
      Math.abs(other.fromMs - segment.fromMs) <= ECHO_WINDOW_MS &&
      similarity(other.text, segment.text) >= ECHO_SIMILARITY);
  });

  return [
    ...them.map((segment) => ({ ...segment, speaker: "Them" })),
    ...kept.map((segment) => ({ ...segment, speaker: "Me" })),
  ].sort((a, b) => (a.fromMs ?? 0) - (b.fromMs ?? 0) || (a.speaker === "Them" ? -1 : 1));
}

/**
 * Every segment of a session: the call alone, or call and mic merged when the
 * mic was recorded and transcribed. `jsonPath` is the call's `<wav>.json`.
 */
export function readSessionSegments(jsonPath) {
  const them = readWhisperSegments(jsonPath);
  if (!them) return null;
  const micWavPath = micPathFor(jsonPath.replace(/\.json$/, ""));
  const me = readWhisperSegments(`${micWavPath}.json`);
  return me ? mergeSpeakers({ them, me, micWavPath }) : them;
}

/**
 * The transcript document. `notes` is omitted when none exist yet — which is the
 * normal case for one written the moment a recording ends.
 */
export function renderTranscript({ sessionId, segments, notes }) {
  const front = ["---", `session: ${sessionId}`];
  if (notes) front.push(`notes: ${notes}`);
  front.push("---", "");

  const body = segments.length
    ? segments.map((s) => s.speaker
      ? `**${formatTimestamp(s.fromMs)} ${s.speaker}:** ${s.text}`
      : `**${formatTimestamp(s.fromMs)}** ${s.text}`)
    : ["*No speech was recognised in this recording.*"];

  return front.concat(body).join("\n") + "\n";
}

/**
 * Writes the transcript for a session that has no notes yet.
 *
 * Named for the session rather than a meeting title, because the title is
 * inferred by Claude and does not exist at this point. The library matches this
 * name back to its recording, and the skill renames it when notes are written so
 * there is never a second copy.
 */
export function writeSessionTranscript({ recordingsDir, sessionId, jsonPath }) {
  const segments = readSessionSegments(jsonPath);
  if (!segments) return { written: false, reason: "no whisper output to read" };

  const path = `${recordingsDir}/${sessionId}-transcript.md`;
  writeFileSync(path, renderTranscript({ sessionId, segments }));
  return { written: true, path, segments: segments.length };
}

// `node transcript.js --selftest` — the merge rules, without whisper or a meeting.
if (process.argv[1] === fileURLToPath(import.meta.url) && process.argv.includes("--selftest")) {
  const failures = [];
  const seg = (text, fromMs) => ({ text, fromMs, toMs: fromMs + 1500 });
  const them = [seg("Can you check the payments service logs?", 1000), seg("Great, thanks.", 9000)];
  const me = [
    seg("Sure, I'll look now.", 3000),                        // you
    seg("can you check the payments service logs", 1400),     // the call, heard through speakers
    seg("Great thanks", 30_000),                              // same words, far apart in time: you
  ];
  const merged = mergeSpeakers({ them, me });
  const mine = merged.filter((s) => s.speaker === "Me").map((s) => s.text);
  if (mine.length !== 2 || mine.includes("can you check the payments service logs")) {
    failures.push(`echo: kept ${JSON.stringify(mine)}`);
  }
  if (merged.map((s) => s.fromMs).join() !== "1000,3000,9000,30000") {
    failures.push(`order: ${merged.map((s) => s.fromMs).join()}`);
  }
  const rendered = renderTranscript({ sessionId: "meetey-1", segments: merged });
  if (!rendered.includes("**[00:03] Me:** Sure, I'll look now.") || !rendered.includes("**[00:01] Them:**")) {
    failures.push("render: speaker labels missing");
  }
  if (!renderTranscript({ sessionId: "meetey-1", segments: them.map(({ text, fromMs, toMs }) => ({ text, fromMs, toMs })) })
    .includes("**[00:01]** Can you")) {
    failures.push("render: unlabelled transcript changed shape");
  }
  if (micPathFor("/r/meetey-1.wav") !== "/r/meetey-1-mic.wav") failures.push("micPathFor");

  // Silence: 2s of padding, then 1s of speech-level audio. Whisper's "Thank you."
  // over the padding goes; what was actually said stays.
  const { tmpdir } = await import("os");
  const { join } = await import("path");
  const { unlinkSync } = await import("fs");
  const wav = join(tmpdir(), `meetey-transcript-selftest-${process.pid}.wav`);
  const audio = Buffer.alloc(WAV_HEADER_BYTES + 3000 * BYTES_PER_MS);
  for (let i = WAV_HEADER_BYTES + 2000 * BYTES_PER_MS; i < audio.length; i += 2) audio.writeInt16LE(4000, i);
  writeFileSync(wav, audio);
  const heard = mergeSpeakers({
    them: [],
    me: [{ text: "Thank you.", fromMs: 200, toMs: 1800 }, { text: "Deploy went out at nine.", fromMs: 2000, toMs: 3000 }],
    micWavPath: wav,
  });
  unlinkSync(wav);
  if (heard.length !== 1 || heard[0].text !== "Deploy went out at nine.") {
    failures.push(`silence: kept ${JSON.stringify(heard.map((s) => s.text))}`);
  }

  if (failures.length) {
    for (const f of failures) console.error(`selftest: FAIL — ${f}`);
    process.exit(1);
  }
  console.log("selftest: PASS (speaker merge, echo and silence filters, ordering, labelled and unlabelled rendering)");
}
