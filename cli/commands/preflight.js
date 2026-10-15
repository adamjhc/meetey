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
 * `npx adamjhc/meetey preflight`: can this machine run the live assistant?
 *
 * Live mode stacks three things on top of recording, each of which a managed
 * work laptop can quietly break: Apple's live transcriber and its downloadable
 * model, the microphone grant, and Claude Code running headless on whatever
 * account it is logged in to, under whatever policy the organisation set. This
 * exercises each one for real — a transcription, a mic recording, two Claude
 * round trips — so the answer comes from the machine rather than from guessing.
 *
 * It sends one short test prompt per model to Claude. No meeting content.
 */

import { spawn, spawnSync } from "child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { randomBytes } from "crypto";
import { green, yellow, red, step, which } from "../utils.js";
import { APP_BUNDLE, BINARY_PATH } from "../paths.js";
import { signatureInfo } from "../app-bundle.js";
import { assistantConfig } from "./assistant.js";

const MANAGED_DIR = "/Library/Application Support/ClaudeCode";

export async function preflight() {
  const problems = [];

  step("Meetey");
  if (!existsSync(BINARY_PATH)) {
    red("  ✗ Meetey.app  not installed — run: npx adamjhc/meetey install");
    return false;
  }
  const signature = signatureInfo(APP_BUNDLE);
  if (signature?.teamId) {
    green(`  ✓ Meetey.app  signed by team ${signature.teamId}`);
  } else {
    yellow("  ! Meetey.app  signed ad hoc — the microphone will be asked for again after updates");
  }

  step("Microphone");
  if (process.env.MEETEY_NO_MIC === "1") {
    console.log("  – Microphone  skipped (MEETEY_NO_MIC=1)");
  } else {
    const mic = spawnSync(BINARY_PATH, ["--verify-mic"], { stdio: ["ignore", "inherit", "ignore"], timeout: 120_000 });
    if (mic.status !== 0) problems.push("Meetey cannot record your microphone, so your side would be missing");
  }

  step("Live transcription");
  const speech = spawnSync(BINARY_PATH, ["--preflight-speech"], { stdio: ["ignore", "inherit", "ignore"], timeout: 600_000 });
  if (speech.status !== 0) problems.push("live transcription is not available on this Mac");

  step("Claude Code");
  const claude = which("claude");
  if (!claude) {
    red("  ✗ Claude Code  not found on PATH");
    problems.push("Claude Code is not installed");
  } else {
    const version = spawnSync(claude, ["--version"], { encoding: "utf8" }).stdout.trim();
    green(`  ✓ Claude Code  ${version}`);
    reportManagedSettings();

    // The panel's configuration: Sonnet, run in the assistant's code folder
    // with its tools and the user's MCP servers. Reading a file in an added
    // directory, as the panel reads keyframes, proves tools aren't blocked by
    // policy; the token proves the answer came from the file, not a guess.
    const config = assistantConfig();
    green(`  ✓ Assistant folder  ${config.workingDirectory}`);
    const dir = mkdtempSync(join(tmpdir(), "meetey-preflight-"));
    const token = randomBytes(6).toString("hex");
    const file = join(dir, "token.txt");
    writeFileSync(file, token);
    try {
      // The model the panel will use; there is no in-panel switch to test.
      const run = await roundTrip(claude, {
        model: config.model,
        tools: config.tools.join(","),
        allowedTools: "Read Grep Glob",
        addDirs: [dir],
        prompt: `Use the Read tool to read ${file} and reply with only its contents.`,
        cwd: config.workingDirectory,
      });
      report(`${config.model} + tools`, run, (text) => text.includes(token), problems, true);
      reportMcpServers(run);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  console.log("");
  if (problems.length === 0) {
    green("This machine is ready for the live assistant.");
    return true;
  }
  yellow("Not ready for the live assistant:");
  for (const problem of problems) console.log(`  - ${problem}`);
  return false;
}

/**
 * What the organisation's managed Claude Code policy says, if there is one.
 * Policy, not secrets — and the thing most likely to block a headless session.
 */
function reportManagedSettings() {
  const settingsPath = join(MANAGED_DIR, "managed-settings.json");
  if (!existsSync(settingsPath)) {
    green("  ✓ Managed settings  none");
  } else {
    try {
      const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      const keys = Object.keys(settings).join(", ") || "(empty)";
      yellow(`  ! Managed settings  present (${keys})`);
      const deny = settings.permissions?.deny ?? [];
      if (deny.length) console.log(`      denied: ${deny.slice(0, 12).join(", ")}${deny.length > 12 ? ", …" : ""}`);
      if (settings.model) console.log(`      model: ${settings.model}`);
      if (settings.availableModels) console.log(`      available models: ${[].concat(settings.availableModels).join(", ")}`);
    } catch (e) {
      yellow(`  ! Managed settings  present but unreadable (${e.message})`);
    }
  }
  if (existsSync(join(MANAGED_DIR, "managed-mcp.json"))) {
    yellow("  ! Managed MCP servers  present — organisation-provided MCP servers are configured");
  }
}

/**
 * One headless stream-json exchange, the way the live panel will talk to
 * Claude. Resolves with timings, the init event's account/model details, and
 * the result.
 */
function roundTrip(claude, { model, tools, prompt, cwd, allowedTools = tools, addDirs = [] }) {
  return new Promise((resolve) => {
    const started = Date.now();
    const args = [
      "-p",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
      "--model", model,
      "--tools", tools,
      ...(allowedTools ? ["--allowedTools", allowedTools] : []),
      ...addDirs.flatMap((d) => ["--add-dir", d]),
    ];
    const child = spawn(claude, args, { cwd, stdio: ["pipe", "pipe", "pipe"] });
    const out = { initMs: null, totalMs: null, init: null, result: null, error: null };
    let buffer = "";
    let stderr = "";

    const timer = setTimeout(() => {
      out.error = "timed out after 120s";
      child.kill("SIGTERM");
    }, 120_000);

    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let event;
        try { event = JSON.parse(line); } catch { continue; }
        if (event.type === "system" && event.subtype === "init") {
          out.initMs = Date.now() - started;
          out.init = event;
        } else if (event.type === "result") {
          out.totalMs = Date.now() - started;
          out.result = event;
          child.stdin.end();
        }
      }
    });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (e) => { out.error = e.message; });
    child.on("close", () => {
      clearTimeout(timer);
      if (!out.result && !out.error) out.error = stderr.trim().split("\n").pop() || "exited without a result";
      resolve(out);
    });

    child.stdin.write(JSON.stringify({ type: "user", message: { role: "user", content: prompt } }) + "\n");
  });
}

/**
 * The MCP servers the assistant will have — the user's own Claude Code setup.
 * claude.ai connectors connect in the background and often show as pending on a
 * first message; in the panel's long-lived session they're ready by the next.
 */
function reportMcpServers(run) {
  const servers = run.init?.mcp_servers ?? [];
  if (!run.init) return;
  if (servers.length === 0) {
    console.log("  – MCP servers  none configured in Claude Code");
    return;
  }
  const failed = servers.filter((s) => s.status === "failed");
  const line = servers.map((s) => `${s.name} (${s.status})`).join(", ");
  (failed.length ? yellow : green)(`  ${failed.length ? "!" : "✓"} MCP servers  ${line}`);
}

function report(label, run, ok, problems, required) {
  const account = run.init?.apiKeySource === "none" ? "logged-in account" : run.init?.apiKeySource;
  const detail = run.init ? `${run.init.model} via ${account}` : "";
  const failed = run.error || !run.result || run.result.is_error || !ok(String(run.result.result ?? ""));

  if (failed) {
    const why = run.error ?? (run.result?.is_error ? String(run.result.result ?? run.result.subtype) : `unexpected reply: ${String(run.result?.result ?? "").slice(0, 80)}`);
    (required ? red : yellow)(`  ${required ? "✗" : "!"} ${label}  ${detail ? `${detail} — ` : ""}${why}`);
    if (required) problems.push(`Claude (${label}) did not work headless: ${why}`);
    return;
  }
  const timing = `session ready in ${(run.initMs / 1000).toFixed(1)}s, answered in ${(run.totalMs / 1000).toFixed(1)}s`;
  green(`  ✓ ${label}  ${detail} — ${timing}`);
}
