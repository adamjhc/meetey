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
import { existsSync, mkdirSync, openSync, readFileSync, readdirSync, statSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join, resolve } from "path";
import { livePathFor } from "../../mcp-server/live.js";
import { readActive } from "../../mcp-server/session-state.js";
import { BINARY_PATH, MEETEY_DIR, RECORDINGS_DIR } from "../paths.js";
import { which } from "../utils.js";

const CONFIG_PATH = join(MEETEY_DIR, "config.json");
const DEFAULT_TOOLS = ["Read", "Grep", "Glob", "Bash"];
const DEFAULT_MODEL = "sonnet";
const expand = (p) => (p.startsWith("~") ? join(homedir(), p.slice(1)) : p);

/**
 * The assistant's settings, as the panel reads them (AssistantConfig.swift):
 * the code folder Claude runs in, extra readable folders, built-in tools, and
 * the model.
 * Local to this machine and never committed.
 */
export function assistantConfig() {
  let raw = {};
  try { raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8")).assistant ?? {}; } catch {}
  const projects = join(homedir(), "projects");
  const configured = raw.workingDirectory ? expand(raw.workingDirectory) : null;
  const workingDirectory = [configured, projects].find((d) => d && existsSync(d) && statSync(d).isDirectory()) ?? homedir();
  return {
    workingDirectory,
    configuredDirectory: configured,
    additionalDirectories: (raw.additionalDirectories ?? []).map(expand),
    tools: raw.tools?.length ? raw.tools : DEFAULT_TOOLS,
    model: typeof raw.model === "string" && raw.model.trim() ? raw.model.trim() : DEFAULT_MODEL,
  };
}

function setAssistantSetting(key, value) {
  let config = {};
  try { config = JSON.parse(readFileSync(CONFIG_PATH, "utf8")); } catch {}
  config.assistant = { ...(config.assistant ?? {}), [key]: value };
  mkdirSync(MEETEY_DIR, { recursive: true });
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2) + "\n");
}

function setFolder(folder) {
  const path = resolve(expand(folder));
  if (!existsSync(path) || !statSync(path).isDirectory()) {
    console.log(`${path} isn't a folder.`);
    return false;
  }
  setAssistantSetting("workingDirectory", path);
  console.log(`The assistant now works in ${path}. Panels opened from now on use it.`);
  return true;
}

/**
 * Any name `claude --model` takes — `sonnet`, `opus`, or a full model ID. Not
 * checked here: `preflight` runs a real question on it.
 */
function setModel(model) {
  setAssistantSetting("model", model);
  console.log(`The assistant now uses ${model}. Panels opened from now on use it; run \`npx adamjhc/meetey preflight\` to check it answers.`);
  return true;
}

export async function assistant(target, rest = []) {
  // `assistant --folder <path>` sets where Claude runs, `--model <name>` what
  // it runs; `assistant --config` shows both.
  if (target === "--folder") {
    if (!rest[0]) { console.log("Usage: npx adamjhc/meetey assistant --folder <path>"); return false; }
    return setFolder(rest[0]);
  }
  if (target === "--model") {
    if (!rest[0]?.trim()) { console.log("Usage: npx adamjhc/meetey assistant --model <sonnet|opus|model-id>"); return false; }
    return setModel(rest[0].trim());
  }
  if (target === "--config") {
    const c = assistantConfig();
    console.log(`Model: ${c.model}`);
    console.log(`Folder: ${c.workingDirectory}${c.configuredDirectory && c.configuredDirectory !== c.workingDirectory ? `  (configured ${c.configuredDirectory} doesn't exist)` : ""}`);
    if (c.additionalDirectories.length) console.log(`Also readable: ${c.additionalDirectories.join(", ")}`);
    console.log(`Built-in tools: ${c.tools.join(", ")}, plus your Claude Code MCP servers. Your permission settings decide what may run.`);
    return true;
  }

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
