// Copyright 2026 Adam Cox
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// The assistant's local settings, from `~/.meetey/config.json`:
///
///     { "assistant": { "workingDirectory": "~/projects",
///                      "additionalDirectories": ["~/other-code"],
///                      "tools": ["Read", "Grep", "Glob", "Bash"],
///                      "model": "sonnet" } }
///
/// Written by `npx adamjhc/meetey assistant --folder <path> --model <name>`. Local only, never
/// committed: the fork is public and these are paths on a work machine.
struct AssistantConfig {
    /// Where Claude runs, so it can investigate code the meeting is about. Its
    /// CLAUDE.md and project MCP servers load from here, as in a normal session.
    let workingDirectory: URL
    let additionalDirectories: [String]
    /// Built-in tools the session gets. No Edit or Write by default: the
    /// assistant investigates during a meeting, it doesn't change code.
    let tools: [String]
    /// Any name `claude --model` takes: an alias (`sonnet`, `opus`) or a full
    /// model ID, for an organisation that restricts which models it offers.
    /// Set here rather than in the panel, so the panel has nothing to fiddle with mid-call.
    let model: String

    static let defaultModel = "sonnet"
    static let defaultTools = ["Read", "Grep", "Glob", "Bash"]

    static func load() -> AssistantConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let meeteyDir = ProcessInfo.processInfo.environment["MEETEY_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".meetey")
        let raw = (try? Data(contentsOf: meeteyDir.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["assistant"] as? [String: Any] ?? [:]

        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        var isDir: ObjCBool = false
        let configured = (raw["workingDirectory"] as? String).map(expand)
        let projects = home.appendingPathComponent("projects").path
        let working = [configured, projects].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        } ?? home.path
        if let configured, configured != working {
            fputs("meetey-capture: assistant folder \(configured) doesn't exist — using \(working)\n", stderr)
        }

        return AssistantConfig(
            workingDirectory: URL(fileURLWithPath: working),
            additionalDirectories: (raw["additionalDirectories"] as? [String] ?? []).map(expand),
            tools: (raw["tools"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? defaultTools,
            model: (raw["model"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? defaultModel)
    }
}
