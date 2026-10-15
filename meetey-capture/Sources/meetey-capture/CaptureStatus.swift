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

/// What a running capture is doing, published for the menu bar agent
/// (`MenuBarAgent.swift`), which shows every recording in its one icon however
/// the recording was started.
///
/// A small JSON file (`--status-file`, normally `~/.meetey/state/capture-status.json`)
/// replaced atomically on every change, and removed when the capture ends:
///
///     { "pid": 123, "startedAtMs": …, "label": "…", "video": true, "mic": true,
///       "liveDir": "…", "framesDir": "…",
///       "state": "recording" | "endingSoon" | "stopping",
///       "remaining": 4.0, "micPaused": false }
///
/// The agent controls the capture with signals rather than through the file:
/// SIGTERM stops, SIGUSR1 pauses the mic, SIGUSR2 resumes it, SIGHUP is "Keep
/// Recording". Everything stays in the capture process, which already does all of
/// it for its own menu, so there's one implementation of each.
/// Where captures publish their state unless told otherwise.
let defaultStatusFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".meetey/state/capture-status.json").path

final class CaptureStatus {
    private let url: URL?
    private let lock = NSLock()
    private var fields: [String: Any]

    init(path: String?, base: [String: Any]) {
        url = path.map { URL(fileURLWithPath: $0) }
        fields = base.merging(["state": "recording", "micPaused": false]) { $1 }
        write()
    }

    func update(_ changes: [String: Any]) {
        lock.withLock { fields.merge(changes) { $1 } }
        write()
    }

    func update(_ state: RecordingIndicator.State) {
        switch state {
        case .recording: update(["state": "recording", "remaining": NSNull()])
        case .endingSoon(let remaining): update(["state": "endingSoon", "remaining": remaining])
        case .stopping: update(["state": "stopping", "remaining": NSNull()])
        }
    }

    func remove() {
        guard let url else { return }
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }

    private func write() {
        guard let url else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writeJSONAtomically(fields, to: url)
        }
    }
}
