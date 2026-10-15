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

import AppKit
import CoreGraphics

// MARK: - Meeting detection

/// A call Meetey could record: a supported meeting app that is taking audio
/// input, and its meeting window when one can be identified.
struct MeetingCandidate: Equatable {
    let bundleID: String
    let appName: String
    let pid: pid_t
    let windowID: UInt32?
    let title: String?
}

/// Which supported apps are in a call. Core Audio process state for the mic and
/// window-server metadata for the window — never ScreenCaptureKit, so this is
/// safe to run every second, including while a recording is live (see "Nothing
/// queries the capture subsystem" in CLAUDE.md).
enum MeetingDetector {
    /// Teams' own screens. The main window's title starts with the section it
    /// shows ("Calendar", "Chat | Priya Shah | Microsoft Teams"); a meeting
    /// window is named after the meeting, so anything else is the meeting.
    static let teamsSections: Set<String> = [
        "activity", "chat", "teams", "calendar", "calls", "files", "apps", "onedrive", "copilot",
        "communities", "settings", "notifications", "people", "assignments", "approvals", "shifts",
        "planner", "viva", "help", "search", "microsoft teams",
    ]

    static func isTeams(_ bundleID: String) -> Bool { bundleID.hasPrefix("com.microsoft.teams") }

    /// Supported apps that are running.
    static func runningApps() -> [NSRunningApplication] {
        supportedBundleIDs.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
    }

    /// Apps in a call right now, with their meeting windows.
    static func candidates() -> [MeetingCandidate] {
        guard let inputs = Microphone.processesUsingInput() else { return [] }
        let inCall = runningApps().filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return Microphone.appUsesInput(bundleID: bundleID, pid: app.processIdentifier, using: inputs) == true
        }
        guard !inCall.isEmpty else { return [] }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return inCall.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            let window = meetingWindow(of: app.processIdentifier, bundleID: bundleID, in: windows)
            return MeetingCandidate(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                    pid: app.processIdentifier, windowID: window?.id, title: window?.title)
        }
    }

    /// The app's largest ordinary on-screen window that isn't one of Teams' own
    /// screens. Titles need Screen Recording permission; without it there is
    /// no title, and the app's name is used instead.
    static func meetingWindow(of pid: pid_t, bundleID: String, in windows: [[String: Any]]) -> (id: UInt32, title: String?)? {
        var best: (id: UInt32, title: String?, area: Double)?
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = (window[kCGWindowNumber as String] as? Int).map(UInt32.init),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 300, height >= 200 else { continue }
            let title = (window[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if isTeams(bundleID), let title,
               teamsSections.contains(title.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "") {
                continue
            }
            if best == nil || width * height > best!.area { best = (number, title, width * height) }
        }
        return best.map { ($0.id, $0.title) }
    }
}

// MARK: - The menu bar agent

/// Meetey's one menu bar icon, for as long as the agent runs.
///
/// One item that never goes away, so a menu bar manager (Thaw, Tuck, Ice) can be
/// told once to keep it visible. Before 2.7.0 there were two: a watching icon
/// that removed itself during recordings and a red one created per recording,
/// and a manager files every newly added item as hidden.
///
/// It is also the only way a recording starts from outside Claude Code: nothing
/// is detected and offered automatically any more. The icon turns orange when a
/// meeting app is in a call, and **clicking it then starts recording** audio and
/// screen. In every other state, and on a right-click, it opens the menu.
///
/// | State     | Symbol                                         | Colour    | Bar          |
/// |-----------|------------------------------------------------|-----------|--------------|
/// | Idle      | `circle.dotted`                                | monochrome|              |
/// | Ready     | `smallcircle.filled.circle` — click to record  | orange    |              |
/// | Starting  | `record.circle` (hollow)                       | red       | "…"          |
/// | Recording | `record.circle.fill` / `…badge.record` (screen)| red       | elapsed      |
/// | Ending    | `record.circle` (hollow)                       | secondary | "ending soon"|
/// | Stopping  | `record.circle`                                | tertiary  | "…"          |
///
/// Recording is started by the agent process that spawned this one (the watch
/// daemon), so the capture keeps that process's Screen Recording attribution:
/// "record" is a JSON line on stdout. Stop, mic pause and Keep Recording are
/// signals to the capture, read from `capture-status.json`, so they work for any
/// recording — including one started from Claude Code.
@MainActor
final class MenuBarAgent: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let statusFile: String
    private let healthFile: String?
    private let plistPath: String?
    private var poll: Timer?
    private var lastHealth = Date.distantPast

    private enum State: Equatable {
        case idle
        case ready(MeetingCandidate)
        /// Asked for, not yet publishing: the capture is opening its stream.
        case starting
        case recording(Recording)
    }

    struct Recording: Equatable {
        let pid: pid_t
        let label: String
        let startedAt: Date
        let video: Bool
        let mic: Bool
        let micPaused: Bool
        let state: String
        let remaining: Double?
        let liveDir: String?
        let framesDir: String?
    }

    private var state: State = .idle
    private let menu = NSMenu()
    private var starting: Date?

    init?(statusFile: String, healthFile: String?, plistPath: String?) {
        guard !NSScreen.screens.isEmpty else { return nil }
        self.statusFile = statusFile
        self.healthFile = healthFile
        self.plistPath = plistPath
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Named so it is told apart from a capture's own icon (only shown when
        // this agent isn't running) and its place is remembered; visible always.
        item.autosaveName = "com.adamjhcox.meetey.status"
        item.isVisible = true
        menu.delegate = self
        // No `item.menu`: an attached menu takes every click, and a click on the
        // ready icon has to record instead. The menu is opened by hand.
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    // MARK: State

    private func refresh() {
        exitIfOrphaned()
        writeHealthIfDue()
        let next: State
        if let since = starting, Date().timeIntervalSince(since) >= 20 { starting = nil }
        if let recording = readRecording() {
            starting = nil
            next = .recording(recording)
        } else if let since = starting, Date().timeIntervalSince(since) < 20 {
            next = .starting
        } else if let candidate = MeetingDetector.candidates().first {
            next = .ready(candidate)
        } else {
            next = .idle
        }
        state = next
        render()
    }

    /// The recording in progress, from the capture's status file — only while
    /// its process is alive, so a crash can't leave the icon red.
    private func readRecording() -> Recording? {
        guard let data = FileManager.default.contents(atPath: statusFile),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (o["pid"] as? Int).map(pid_t.init), kill(pid, 0) == 0 else { return nil }
        return Recording(
            pid: pid,
            label: o["label"] as? String ?? "Meeting",
            startedAt: (o["startedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
            video: o["video"] as? Bool ?? false,
            mic: o["mic"] as? Bool ?? false,
            micPaused: o["micPaused"] as? Bool ?? false,
            state: o["state"] as? String ?? "recording",
            remaining: o["remaining"] as? Double,
            liveDir: o["liveDir"] as? String,
            framesDir: o["framesDir"] as? String)
    }

    /// Whether this agent can see window titles, for `watch enable` to verify.
    /// CGPreflightScreenCaptureAccess asks TCC about this process's responsible
    /// process — the watch daemon's node — without opening a capture connection.
    private func writeHealthIfDue() {
        guard let healthFile, Date().timeIntervalSince(lastHealth) > 30 else { return }
        lastHealth = Date()
        writeJSONAtomically(["at": ISO8601DateFormatter().string(from: Date()),
                             "canSeeWindows": CGPreflightScreenCaptureAccess()],
                            to: URL(fileURLWithPath: healthFile))
    }

    // MARK: Rendering

    private func render() {
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        switch state {
        case .idle:
            let image = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.title = ""
            setAccessibility("Meetey, no call in progress")
        case .ready(let call):
            button.image = RecordingIndicator.symbol("smallcircle.filled.circle", color: .systemOrange)
            button.title = ""
            setAccessibility("Meetey, \(call.appName) call in progress. Click to record audio and screen")
        case .starting:
            button.image = RecordingIndicator.symbol("record.circle", color: .systemRed)
            button.title = " …"
            setAccessibility("Meetey is starting to record")
        case .recording(let r):
            let elapsed = Int(Date().timeIntervalSince(r.startedAt))
            switch r.state {
            case "endingSoon":
                button.image = RecordingIndicator.symbol("record.circle", color: .secondaryLabelColor)
                button.title = " ending soon"
                setAccessibility("Meetey may stop recording in \(RecordingIndicator.spoken(Int(r.remaining ?? 0)))")
            case "stopping":
                button.image = RecordingIndicator.symbol("record.circle", color: .tertiaryLabelColor)
                button.title = " …"
                setAccessibility("Meetey is stopping the recording")
            default:
                button.image = RecordingIndicator.symbol(r.video ? "rectangle.inset.filled.badge.record" : "record.circle.fill",
                                                         color: .systemRed)
                button.title = " \(RecordingIndicator.clock(elapsed))\(r.micPaused ? " · mic off" : "")"
                setAccessibility("Meetey recording, \(r.video ? "audio and screen" : "audio only"), \(RecordingIndicator.spoken(elapsed))")
            }
        }
    }

    private func setAccessibility(_ text: String) {
        item.button?.setAccessibilityLabel(text)
        item.button?.setAccessibilityTitle(text)
    }

    // MARK: Menu

    /// Built fresh each time it opens, so it always matches what is happening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, _ payload: Any? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = payload
            menu.addItem(item)
        }

        switch state {
        case .recording(let r):
            header(RecordingIndicator.truncateMiddle(r.label, to: 40))
            header("\(r.video ? "Audio + screen" : "Audio only")\(r.mic ? (r.micPaused ? ", mic paused" : " + mic") : "") · \(RecordingIndicator.clock(Int(Date().timeIntervalSince(r.startedAt))))")
            menu.addItem(.separator())
            if r.state == "endingSoon" { action("Keep Recording", #selector(keepRecording)) }
            if r.mic { action(r.micPaused ? "Resume My Microphone" : "Pause My Microphone", #selector(toggleMic)) }
            if r.liveDir != nil { action("Show Assistant (\(HotKey.label))", #selector(showAssistant)) }
            action("Stop Recording", #selector(stopRecording))
        case .ready(let call):
            header("\(call.appName) call\(call.title.map { ": " + RecordingIndicator.truncateMiddle($0, to: 40) } ?? "")")
            menu.addItem(.separator())
            action("Record", #selector(recordFromMenu(_:)), call)
        case .starting:
            header("Starting to record…")
        case .idle:
            header("No call in progress")
            // Recording without a detected call stays possible — a call whose
            // app isn't using the mic yet, say — but it's tucked into a submenu.
            let apps = MeetingDetector.runningApps()
            if !apps.isEmpty {
                let submenu = NSMenu()
                for app in apps {
                    guard let bundleID = app.bundleIdentifier else { continue }
                    let call = MeetingCandidate(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                                pid: app.processIdentifier, windowID: nil, title: nil)
                    let entry = NSMenuItem(title: call.appName, action: #selector(recordFromMenu(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = call
                    submenu.addItem(entry)
                }
                let parent = NSMenuItem(title: "Record Anyway", action: nil, keyEquivalent: "")
                parent.submenu = submenu
                menu.addItem(.separator())
                menu.addItem(parent)
            }
        }
        menu.addItem(.separator())
        action("Turn Off Meetey", #selector(turnOff))
    }

    // MARK: Actions

    /// A left click on the ready icon records; anything else opens the menu.
    @objc private func clicked() {
        let rightClick = NSApp.currentEvent.map { $0.type == .rightMouseUp || $0.modifierFlags.contains(.control) } ?? false
        if case .ready(let call) = state, !rightClick {
            record(call)
            return
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func recordFromMenu(_ sender: NSMenuItem) {
        guard let call = sender.representedObject as? MeetingCandidate else { return }
        record(call)
    }

    /// Asks the watch daemon to start the capture: a JSON line on stdout.
    /// Always audio and screen; the icon shows which while it records.
    private func record(_ call: MeetingCandidate) {
        var command: [String: Any] = ["cmd": "record", "mode": "screen", "bundleID": call.bundleID]
        if let id = call.windowID { command["windowID"] = Int(id) }
        if let title = call.title { command["title"] = title }
        guard var line = try? JSONSerialization.data(withJSONObject: command) else { return }
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
        // Show "starting" straight away rather than leaving the icon orange
        // until the capture publishes its status, which invites a second click.
        starting = Date()
        state = .starting
        render()
    }

    private var recording: Recording? {
        if case .recording(let r) = state { return r }
        return nil
    }

    @objc private func stopRecording() {
        guard let r = recording else { return }
        kill(r.pid, SIGTERM)
    }

    @objc private func toggleMic() {
        guard let r = recording else { return }
        kill(r.pid, r.micPaused ? SIGUSR2 : SIGUSR1)
    }

    @objc private func keepRecording() {
        guard let r = recording else { return }
        kill(r.pid, SIGHUP)
    }

    @objc private func showAssistant() {
        guard let r = recording, let liveDir = r.liveDir else { return }
        PanelProcess.showOrLaunch(liveDir: liveDir, title: r.label, framesDir: r.framesDir,
                                  startedAt: r.startedAt, capturePid: r.pid)
    }

    /// Unloads the agent and removes its plist, so it doesn't return at login.
    /// The label is the plist's name, so it can't drift from the installed one.
    @objc private func turnOff() {
        let uid = String(getuid())
        let label = plistPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? "com.adamjhcox.meetey.watch"
        if let plistPath { try? FileManager.default.removeItem(atPath: plistPath) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)/\(label)"]
        try? process.run()
        NSStatusBar.system.removeStatusItem(item)
        exit(0)
    }

    /// The icon says the agent is running, so it must not outlive it. A crash
    /// doesn't signal us, and launchd would then start a second icon.
    private func exitIfOrphaned() {
        if getppid() == 1 {
            NSStatusBar.system.removeStatusItem(item)
            exit(0)
        }
    }
}
