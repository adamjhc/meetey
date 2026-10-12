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

/// Finding `claude`. The panel can be started by the watcher, which runs under
/// launchd with a bare PATH — the same trap whisper fell into — so known install
/// locations are tried before asking a login shell.
enum ClaudeLocator {
    static func find(explicit: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [explicit, ProcessInfo.processInfo.environment["MEETEY_CLAUDE"],
                          "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

/// One meeting's conversation with Claude, through a long-lived Claude Code
/// process speaking stream-json — the shape `preflight` checks.
///
/// - **Read is the only tool,** and `--strict-mcp-config` with no config means no
///   MCP servers: meeting content is untrusted, so the session can look at
///   keyframes and nothing else. Anything else it tries is denied, since a
///   non-interactive session cannot be granted more.
/// - **Partial messages** stream the answer as it is written.
/// - **Switching model** restarts the process with `--resume`, so the
///   conversation carries over.
/// - **If the process dies**, the next message starts it again, resuming.
///
/// Uses whichever account Claude Code is logged in to on this machine.
final class ClaudeSession {
    enum Event {
        case ready(model: String)
        case delta(String)
        case reading(String)
        case finished(isError: Bool, text: String)
        case failed(String)
    }

    private let claudePath: String
    private let workingDirectory: URL
    private let readableDirectories: [String]
    private let onEvent: (Event) -> Void

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private(set) var sessionId: String?
    private(set) var model: String
    private var expectingExit = false

    init(claudePath: String, workingDirectory: URL, readableDirectories: [String], model: String,
         onEvent: @escaping (Event) -> Void) {
        self.claudePath = claudePath
        self.workingDirectory = workingDirectory
        self.readableDirectories = readableDirectories
        self.model = model
        self.onEvent = onEvent
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func send(_ text: String) {
        if !isRunning { start() }
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        stdin?.write(data)
    }

    func switchModel(to newModel: String) {
        guard newModel != model else { return }
        model = newModel
        if isRunning { stop() }
        // Started lazily by the next send, resuming the same conversation.
    }

    func stop() {
        expectingExit = true
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
    }

    private func start() {
        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--include-partial-messages",
                    "--model", model,
                    "--tools", "Read",
                    "--allowedTools", "Read",
                    "--strict-mcp-config",
                    "--append-system-prompt", meetingSystemPrompt]
        for dir in readableDirectories { args += ["--add-dir", dir] }
        if let sessionId { args += ["--resume", sessionId] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                       "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        var stderrTail = ""
        errors.fileHandleForReading.readabilityHandler = { handle in
            stderrTail = String((stderrTail + String(decoding: handle.availableData, as: UTF8.self)).suffix(400))
        }
        process.terminationHandler = { [weak self] proc in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === proc || self.process == nil else { return }
                if !self.expectingExit {
                    let why = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.onEvent(.failed(why.isEmpty ? "Claude Code exited (status \(proc.terminationStatus))" : why))
                }
                self.process = nil
                self.stdin = nil
            }
        }

        do {
            try process.run()
        } catch {
            onEvent(.failed("Could not start Claude Code at \(claudePath): \(error.localizedDescription)"))
            return
        }
        expectingExit = false
        self.process = process
        stdin = input.fileHandleForWriting
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system" where event["subtype"] as? String == "init":
            sessionId = event["session_id"] as? String ?? sessionId
            onEvent(.ready(model: event["model"] as? String ?? model))
        case "stream_event":
            guard let inner = event["event"] as? [String: Any] else { return }
            if inner["type"] as? String == "content_block_delta",
               let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                onEvent(.delta(text))
            } else if inner["type"] as? String == "content_block_start",
                      let block = inner["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                onEvent(.reading(block["name"] as? String ?? "a tool"))
            }
        case "result":
            sessionId = event["session_id"] as? String ?? sessionId
            onEvent(.finished(isError: event["is_error"] as? Bool ?? false, text: event["result"] as? String ?? ""))
        default:
            break
        }
    }
}
