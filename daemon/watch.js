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
 * The watch agent: keeps Meetey's menu bar icon running, and records when it is
 * told to from there.
 *
 * Since 2.7.0 nothing is detected and offered automatically. The icon
 * (`meetey-capture --watch-indicator`, MenuBarAgent.swift) turns orange when a
 * meeting app is in a call, and a recording starts only when someone picks
 * "Record" in its menu. The choice is made on purpose, on the spot, for one
 * call — the same consent the old dialog asked for, without the dialog
 * interrupting every call to ask.
 *
 * The icon asks this process to start the capture, rather than starting it
 * itself, so the capture keeps the Screen Recording attribution it has always
 * had: launchd's job, this node. It writes a JSON line on stdout:
 *
 *     {"cmd": "record", "mode": "audio" | "screen", "bundleID": "…",
 *      "windowID": 123, "title": "…"}
 *
 * Run by launchd as a LaunchAgent (see `meetey watch enable`), a user session
 * agent rather than a system daemon — a menu bar icon needs a GUI session, and
 * this must never run for a user who is not logged in.
 */

import { spawn } from "child_process";
import { existsSync, mkdirSync } from "fs";
import { homedir } from "os";
import { basename, join, resolve } from "path";
import { createInterface } from "readline";
import { readActive, writeActive, clearActive, writePending, captureStatusPath } from "../mcp-server/session-state.js";
import { writeHealth, watchPaths } from "../mcp-server/watch-agent.js";
import { resolveWhisper } from "../mcp-server/whisper.js";
import { micPathFor, writeSessionTranscript } from "../mcp-server/transcript.js";
import { livePathFor } from "../mcp-server/live.js";

const HOME = homedir();
const MEETEY_DIR = process.env.MEETEY_HOME ?? join(HOME, ".meetey");
const RECORDINGS_DIR = process.env.MEETEY_OUTPUT_DIR ?? join(MEETEY_DIR, "recordings");
const MODEL_PATH = process.env.MEETEY_MODEL ?? join(MEETEY_DIR, "models", "ggml-base.en.bin");

const scriptDir = new URL(".", import.meta.url).pathname;
const CAPTURE_BINARY = process.env.MEETEY_BINARY ??
  // Keep in step with APP_EXECUTABLE in cli/app-bundle.js, which this
  // installed copy can't import.
  resolve(scriptDir, "../Meetey.app/Contents/MacOS/Meetey");

const SUPPORTED_APPS = new Set(["com.google.Chrome", "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2"]);

const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);
const healthCtx = { meeteyDir: MEETEY_DIR, home: HOME };

/** The capture this agent started, if any. Held so shutdown can end it properly. */
let activeCapture = null;

/**
 * A command from the menu bar icon, validated: a line that isn't one is
 * ignored, never guessed at. Returns null for anything else.
 */
export function parseCommand(line) {
  let o;
  try { o = JSON.parse(line); } catch { return null; }
  if (o?.cmd !== "record") return null;
  if (o.mode !== "audio" && o.mode !== "screen") return null;
  if (!SUPPORTED_APPS.has(o.bundleID)) return null;
  const windowID = Number.isInteger(o.windowID) && o.windowID > 0 ? o.windowID : null;
  const title = typeof o.title === "string" && o.title.trim() ? o.title.trim() : null;
  return { mode: o.mode, bundleID: o.bundleID, windowID, title };
}

const APP_NAMES = {
  "com.google.Chrome": "Chrome",
  "us.zoom.xos": "Zoom",
  "com.microsoft.teams": "Teams",
  "com.microsoft.teams2": "Teams",
};

/**
 * meetey-capture's arguments for a recording. Pure, so the selftest can check
 * what a menu choice turns into.
 */
export function captureArgs({ mode, bundleID, windowID, title }, paths, env = process.env) {
  const args = [
    "--app", bundleID,
    "--output", paths.outputPath,
    "--auto-stop",
    // Nobody is watching a recording started from the menu bar, so without this
    // it runs until the app quits — which for Chrome could be days.
    "--stop-when-call-ends",
    // No --menu-bar: the agent's own icon shows the recording, from this file.
    "--status-file", paths.statusFile,
    "--label", (title ?? APP_NAMES[bundleID] ?? "Meeting").slice(0, 60),
  ];
  // Which window is the meeting, so its closing tells the capture the call is
  // over — the difference between stopping in seconds and waiting a minute.
  if (windowID) args.push("--meeting-window", String(windowID), "--meeting-title", title ?? "");
  if (mode === "screen") {
    args.push("--video", "--frames-dir", paths.framesDir);
    if (windowID) args.push("--window", String(windowID));
  }
  if (paths.micPath) args.push("--mic", paths.micPath);
  if (paths.liveDir) args.push("--live", paths.liveDir);
  if (paths.liveDir && env.MEETEY_NO_ASSISTANT !== "1") args.push("--assistant");
  return args;
}

/** Mic recording follows the same default as /meetey start. */
const MIC_ENABLED = process.env.MEETEY_NO_MIC !== "1";

function transcribeInBackground(wavPath) {
  if (!existsSync(MODEL_PATH)) {
    log("whisper model missing — leaving the WAV untranscribed");
    return;
  }
  const whisper = resolveWhisper();
  if (!whisper) {
    // Was ENOENT every time before this: launchd gives a job a minimal PATH with
    // no Homebrew in it, so a bare `whisper-cli` never resolved here even though
    // the identical call worked from Claude Code.
    log("whisper-cli not found — leaving the WAV for /meetey stop to transcribe");
    return;
  }
  // The call first, then your mic if it was recorded; the transcript is written
  // once both are done so it comes out merged as Me / Them. A mic that fails to
  // transcribe still leaves the call's transcript.
  const micPath = micPathFor(wavPath);
  const files = existsSync(micPath) ? [wavPath, micPath] : [wavPath];

  const next = (index) => {
    if (index === files.length) {
      // Turn it into something readable straight away. Notes need Claude; a
      // transcript does not, and leaving the meeting as a JSON blob until someone
      // opens an editor is how a recording ends up never being read at all.
      const result = writeSessionTranscript({
        recordingsDir: RECORDINGS_DIR,
        sessionId: basename(wavPath, ".wav"),
        jsonPath: `${wavPath}.json`,
      });
      log(result.written
        ? `transcript ready: ${result.path} (${result.segments} segments)`
        : `transcription ready but no transcript written: ${result.reason}`);
      return;
    }
    const file = files[index];
    log(`transcribing ${file}`);

    // spawn, not execFileSync. Whisper on an hour of audio runs for minutes, and a
    // synchronous call blocks Node's event loop for all of it — the poll never
    // fires, so a meeting starting right after one ends is missed entirely. Two
    // calls back to back is the ordinary case, not an edge case.
    const child = spawn(whisper, [
      "-f", file,
      "-m", MODEL_PATH,
      "-l", "en",
      "--output-json",
      "--no-prints",
    ], { stdio: ["ignore", "ignore", "pipe"] });

    child.on("exit", (code) => {
      if (code !== 0) {
        log(`transcription failed for ${file} (exit ${code})`);
        if (index === 0) return;
      }
      next(index + 1);
    });
    child.on("error", (e) => {
      log(`transcription failed for ${file}: ${e.message.split("\n")[0]}`);
      if (index > 0) next(index + 1);
    });
  };
  next(0);
}

function startRecording(request) {
  // One recording at a time, whoever started it. The icon only offers Record
  // when nothing is recording, but a recording started from Claude Code in the
  // same second could still race it.
  const already = readActive(MEETEY_DIR);
  if (already) {
    log(`not recording — ${already.sessionId} is already in progress`);
    return;
  }

  const { mode, bundleID, title } = request;
  const sessionId = `meetey-${Date.now()}`;
  const outputPath = join(RECORDINGS_DIR, `${sessionId}.wav`);
  const paths = {
    outputPath,
    framesDir: mode === "screen" ? join(RECORDINGS_DIR, `${sessionId}-frames`) : null,
    micPath: MIC_ENABLED ? micPathFor(outputPath) : null,
    liveDir: process.env.MEETEY_NO_LIVE === "1" ? null : livePathFor(outputPath),
    statusFile: captureStatusPath(MEETEY_DIR),
  };
  const { framesDir, micPath, liveDir } = paths;
  mkdirSync(RECORDINGS_DIR, { recursive: true });

  const child = spawn(CAPTURE_BINARY, captureArgs(request, paths), { stdio: ["ignore", "ignore", "pipe"] });
  activeCapture = child;
  const windowTitle = title ?? APP_NAMES[bundleID] ?? "";
  let autoStopReason = null;
  let confirmedStart = false;
  let micDenied = false;
  child.stderr.on("data", (d) => {
    const text = d.toString();
    process.stderr.write(text);
    if (/recording started/.test(text)) confirmedStart = true;
    const reason = text.match(/auto-stop — (.+)/);
    if (reason) autoStopReason = reason[1].trim();
    if (/call ended — trimming/.test(text)) autoStopReason = "the call ended";
    if (/microphone access denied/.test(text)) {
      micDenied = true;
      log("microphone access denied — recording call audio only. Allow Meetey in System Settings → Privacy & Security → Microphone.");
    }
  });

  // A spawn failure emits `error`, never `exit`. Without a listener that is an
  // unhandled error event, which would take the whole agent down.
  child.on("error", (e) => {
    activeCapture = null;
    clearActive(MEETEY_DIR);
    log(`capture failed to start: ${e.message.split("\n")[0]}`);
  });

  // Capture opens the stream and only then writes anything. If it never gets
  // that far it can sit holding the active-recording lock indefinitely, and the
  // log looks identical to a healthy recording — which is exactly how a silent
  // 35-minute non-recording goes unnoticed.
  setTimeout(() => {
    if (!confirmedStart && activeCapture === child) {
      log(`WARNING: ${sessionId} has not started capturing after 30s — it may be stuck in setup`);
    }
  }, 30_000).unref?.();

  const startedAt = new Date().toISOString();
  writeActive(MEETEY_DIR, {
    pid: child.pid,
    sessionId,
    outputPath,
    // Must be the real path, not null: stop_recording reads this to find the
    // keyframe manifest, so a wrong value here loses the screen content.
    framesDir,
    micPath,
    liveDir,
    startedAt,
    startedBy: "watch",
    windowTitle,
    bundleID,
  });
  log(`recording ${sessionId} (${mode === "screen" ? "audio + screen" : "audio"}${micPath ? " + mic" : ""}) — ${windowTitle}`);

  child.on("exit", (code, signal) => {
    activeCapture = null;
    clearActive(MEETEY_DIR);
    // Say how it ended. "ended" alone reads the same whether it recorded an hour
    // or died during setup, which makes a failure indistinguishable from success.
    const how = signal ? `killed by ${signal}` : code === 0 ? "cleanly" : `exit ${code}`;
    log(`recording ${sessionId} ended (${how}${confirmedStart ? "" : ", never started capturing"})`);

    if (!existsSync(outputPath)) {
      log(`no audio file at ${outputPath} — nothing to transcribe`);
      return;
    }

    // Leave a record for /meetey stop to collect. Clearing the active state is
    // right — nothing is recording any more — but this recording ended in a
    // different process from the MCP server, so without this there is nothing
    // for the user to pick up, and the notification we just showed them told
    // them to go pick it up.
    writePending(MEETEY_DIR, {
      sessionId,
      outputPath,
      framesDir,
      micPath,
      micDenied,
      startedAt,
      stoppedAt: new Date().toISOString(),
      startedBy: "watch",
      windowTitle,
      autoStopReason,
    });

    transcribeInBackground(outputPath);
  });
}

/**
 * The parts that decide what gets recorded are exercisable without a meeting.
 * `node watch.js --selftest`.
 */
function selfTest() {
  const failures = [];
  const cmd = (o) => JSON.stringify({ cmd: "record", ...o });

  const good = parseCommand(cmd({ mode: "screen", bundleID: "com.microsoft.teams2", windowID: 42, title: " TAM Onyx Stand-up | Microsoft Teams " }));
  if (good?.mode !== "screen" || good.windowID !== 42 || good.title !== "TAM Onyx Stand-up | Microsoft Teams") {
    failures.push(`valid command misread: ${JSON.stringify(good)}`);
  }
  // No window: recording "anyway" from the menu, or no Screen Recording permission.
  const bare = parseCommand(cmd({ mode: "audio", bundleID: "us.zoom.xos" }));
  if (bare?.windowID !== null || bare.title !== null) failures.push(`command without a window misread: ${JSON.stringify(bare)}`);

  const rejected = [
    "",
    "not json",
    "meetey-capture: some stray log line",
    JSON.stringify({ cmd: "stop" }),
    cmd({ mode: "video", bundleID: "us.zoom.xos" }),
    cmd({ mode: "audio", bundleID: "com.apple.Safari" }),
    cmd({ mode: "audio" }),
  ];
  for (const line of rejected) {
    if (parseCommand(line)) failures.push(`accepted a bad command: ${line}`);
  }

  const paths = {
    outputPath: "/r/s.wav", framesDir: "/r/s-frames", micPath: "/r/s-mic.wav",
    liveDir: "/r/s-live", statusFile: "/st/capture-status.json",
  };
  const has = (args, ...seq) => args.some((_, i) => seq.every((v, j) => args[i + j] === v));

  const screen = captureArgs(good, paths, {});
  for (const seq of [
    ["--app", "com.microsoft.teams2"], ["--stop-when-call-ends"], ["--auto-stop"],
    ["--status-file", "/st/capture-status.json"], ["--meeting-window", "42"],
    ["--video", "--frames-dir", "/r/s-frames"], ["--window", "42"],
    ["--mic", "/r/s-mic.wav"], ["--live", "/r/s-live"], ["--assistant"],
  ]) {
    if (!has(screen, ...seq)) failures.push(`screen recording is missing ${seq.join(" ")}`);
  }
  // One icon: the capture must not add its own.
  if (screen.includes("--menu-bar")) failures.push("capture would add a second menu bar icon");

  // Audio only means no screen, whatever else is known.
  const audio = captureArgs({ ...good, mode: "audio" }, { ...paths, framesDir: null }, {});
  if (audio.includes("--video") || audio.includes("--window")) failures.push("audio-only recording would capture the screen");

  const noWindow = captureArgs(bare, { ...paths, framesDir: null }, {});
  if (noWindow.includes("--meeting-window")) failures.push("passed a meeting window that was never found");
  if (!has(noWindow, "--label", "Zoom")) failures.push("recording without a window is not labelled with the app");

  if (captureArgs(good, paths, { MEETEY_NO_ASSISTANT: "1" }).includes("--assistant")) {
    failures.push("MEETEY_NO_ASSISTANT=1 did not turn the assistant off");
  }

  if (failures.length === 0) {
    console.log(`selftest: PASS (${2 + rejected.length} commands parsed, capture arguments checked)`);
    process.exit(0);
  }
  for (const f of failures) console.error(`selftest: FAIL — ${f}`);
  process.exit(1);
}

/**
 * The menu bar icon. A separate process because a status item needs AppKit,
 * which Node has no access to. It is the agent's whole interface, so if it
 * dies it is started again — with a growing delay, so a machine with no GUI
 * session doesn't spin.
 */
let indicator = null;
let shuttingDown = false;
let restartDelay = 2_000;

function startIndicator() {
  if (!existsSync(CAPTURE_BINARY)) {
    writeHealth(healthCtx, { at: new Date().toISOString(), canSeeWindows: false, error: `Meetey not found at ${CAPTURE_BINARY}` });
    log(`Meetey not found at ${CAPTURE_BINARY} — no menu bar icon`);
    return;
  }
  const { plistPath, healthPath } = watchPaths(healthCtx);
  const started = Date.now();
  const child = spawn(CAPTURE_BINARY, [
    "--watch-indicator",
    "--status-file", captureStatusPath(MEETEY_DIR),
    "--health-file", healthPath,
    "--plist", plistPath,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  indicator = child;

  createInterface({ input: child.stdout }).on("line", (line) => {
    const request = parseCommand(line);
    if (!request) {
      if (line.trim()) log(`ignored from the menu bar icon: ${line.slice(0, 200)}`);
      return;
    }
    log(`record requested from the menu bar (${request.mode === "screen" ? "audio + screen" : "audio"}) — ${request.title ?? request.bundleID}`);
    startRecording(request);
  });
  child.stderr.on("data", (d) => process.stderr.write(d));
  child.on("error", (e) => log(`menu bar icon failed to start: ${e.message.split("\n")[0]}`));
  child.on("exit", (code, signal) => {
    if (indicator === child) indicator = null;
    if (shuttingDown) return;
    // Ran for a while: a one-off crash, so come back quickly.
    if (Date.now() - started > 60_000) restartDelay = 2_000;
    log(`menu bar icon exited (${signal ?? `exit ${code}`}) — restarting in ${restartDelay / 1000}s`);
    setTimeout(startIndicator, restartDelay).unref?.();
    restartDelay = Math.min(restartDelay * 2, 300_000);
  });
}

if (process.argv.includes("--selftest")) {
  selfTest();
} else {
  log("meetey watch started");
  startIndicator();
  // Keeps the process alive between recordings; everything else is events.
  setInterval(() => {}, 1 << 30);

  // A recording is stopped by the meeting ending, never by the agent exiting.
  process.on("SIGTERM", () => {
    log("meetey watch stopping");
    shuttingDown = true;
    // The icon means "Meetey is running", so it must not outlive it.
    try { indicator?.kill("SIGTERM"); } catch { /* already gone */ }

    // A recording in flight has to be ended properly, not abandoned.
    //
    // `launchctl bootout` tears down the whole job, and the capture process is in
    // this process group, so it dies with us — mid-write, with no pending record
    // and nothing queued to transcribe. The audio is the one irreplaceable thing
    // here, so shutdown waits for the capture to finalize its WAV before exiting.
    if (activeCapture) {
      log("stopping the recording in progress before exiting");
      try { activeCapture.kill("SIGTERM"); } catch { /* already gone */ }
      activeCapture.once("exit", () => {
        log("recording finalized; exiting");
        process.exit(0);
      });
      // launchd escalates to SIGKILL after its own grace period; leaving early
      // would defeat the point, but hanging forever would too.
      setTimeout(() => {
        log("capture did not exit in time; exiting anyway");
        process.exit(0);
      }, 15_000);
      return;
    }

    process.exit(0);
  });
}
