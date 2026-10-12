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

import { homedir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
// One definition, shared with the MCP server, so the CLI and the server can
// never disagree about the agent's label.
import { WATCH_LABEL } from "../mcp-server/watch-agent.js";

export const HOME      = homedir();
export const PKG_DIR   = join(dirname(fileURLToPath(import.meta.url)), "..");

export const MEETEY_DIR     = join(HOME, ".meetey");
export const MODELS_DIR     = join(MEETEY_DIR, "models");
export const RECORDINGS_DIR = join(MEETEY_DIR, "recordings");
export const SERVER_DIR     = join(MEETEY_DIR, "mcp-server");
export const DAEMON_DIR     = join(MEETEY_DIR, "daemon");
export const CAPTURE_DIR    = join(MEETEY_DIR, "meetey-capture");
export const LOGS_DIR       = join(MEETEY_DIR, "logs");
/** What `swift build` produces. Never run directly — it is copied into the app. */
export const BUILT_BINARY   = join(CAPTURE_DIR, ".build", "release", "meetey-capture");
/** The binary lives inside an app bundle so its menu bar items have an app
 *  identity; without one, macOS and menu bar managers will not keep them shown. */
export const APP_BUNDLE     = join(MEETEY_DIR, "Meetey.app");
export const BINARY_PATH    = join(APP_BUNDLE, "Contents", "MacOS", "meetey-capture");
export const MODEL_PATH     = join(MODELS_DIR, "ggml-base.en.bin");
export const SKILL_PATH     = join(HOME, ".claude", "skills", "meetey", "SKILL.md");
export const CLAUDE_JSON    = join(HOME, ".claude.json");
export const KEYBINDINGS    = join(HOME, ".claude", "keybindings.json");

export { WATCH_LABEL };
export const WATCH_PLIST    = join(HOME, "Library", "LaunchAgents", `${WATCH_LABEL}.plist`);
export const WATCH_SCRIPT   = join(DAEMON_DIR, "watch.js");

export const MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
