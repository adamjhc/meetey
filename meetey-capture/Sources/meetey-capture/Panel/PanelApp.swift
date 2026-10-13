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
import SwiftUI

// MARK: - Model

struct ChatMessage: Identifiable {
    enum Role { case user, assistant, note, status }
    let id = UUID()
    let role: Role
    var text: String
    var detail: String? = nil
    var streaming = false
}

struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
    var attachScreen = false

    static let all = [
        QuickAction(title: "Extract logs",
                    prompt: "Extract the logs, errors and stack traces shown on screen, verbatim, in a code block, with the [mm:ss] of each screen. If the OCR looks garbled, read the image.",
                    attachScreen: true),
        QuickAction(title: "Last 5 min",
                    prompt: "Summarise the last five minutes in 3–5 bullets: what was discussed, what was decided, who owes what."),
        QuickAction(title: "Draft ticket",
                    prompt: "Draft a ticket for the issue being discussed: title, context, evidence (quote any logs or errors), and acceptance criteria. Paste-ready."),
        QuickAction(title: "Decisions",
                    prompt: "List the decisions and action items so far, each with [mm:ss] and an owner (Me, Them, or a name if one was said)."),
    ]
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var pinned = ""
    @Published var attachScreen = false
    @Published var model = "sonnet" { didSet { session?.switchModel(to: model) } }
    @Published var busy = false
    @Published var liveText = "Waiting for the meeting…"
    @Published var recording = true

    let title: String
    private let context: MeetingContext
    private let startedAt: Date
    private let capturePid: pid_t?
    private let chatLog: URL
    private var session: ClaudeSession?
    private var timer: Timer?
    private var answerIndex: Int?

    init(title: String, liveDir: URL, framesDir: String?, startedAt: Date, capturePid: pid_t?, claudePath: String?) {
        self.title = title
        self.context = MeetingContext(liveDir: liveDir)
        self.startedAt = startedAt
        self.capturePid = capturePid
        self.chatLog = liveDir.appendingPathComponent("chat.md")

        if let claudePath {
            let config = AssistantConfig.load()
            session = ClaudeSession(claudePath: claudePath, workingDirectory: config.workingDirectory,
                                    readableDirectories: [liveDir.path, framesDir].compactMap { $0 } + config.additionalDirectories,
                                    tools: config.tools, model: model) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        } else {
            messages.append(ChatMessage(role: .status, text: "Claude Code wasn't found, so questions can't be answered. Install it and log in, then reopen the assistant."))
        }

        refreshLive()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var nowMs: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

    /// The line under the title: what is being said right now, or the last thing said.
    private func refreshLive() {
        if let capturePid, kill(capturePid, 0) != 0, errno == ESRCH, recording {
            recording = false
        }
        let partials = LiveReader.partials(in: context.liveDir)
        if !partials.isEmpty {
            liveText = partials.map { "\($0.speaker): \($0.text)" }.joined(separator: "   ")
        } else if let last = LiveReader.lines(in: context.liveDir).last {
            liveText = "\(meetingTimestamp(last.startMs)) \(last.speaker): \(last.text)"
        } else if !recording {
            liveText = "Recording ended."
        }
    }

    func send(_ request: String? = nil, attach: Bool? = nil) {
        let text = (request ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, let session else { return }
        let built = context.build(request: text, pinned: pinned, attachScreen: attach ?? attachScreen, nowMs: nowMs)

        var detail = [String]()
        if built.newLines > 0 { detail.append("\(built.newLines) new line\(built.newLines == 1 ? "" : "s")") }
        if built.newFrames > 0 { detail.append("\(built.newFrames) screen\(built.newFrames == 1 ? "" : "s")") }
        if attach ?? attachScreen { detail.append("current screen") }
        messages.append(ChatMessage(role: .user, text: text, detail: detail.isEmpty ? nil : "+ " + detail.joined(separator: ", ")))
        messages.append(ChatMessage(role: .assistant, text: "", streaming: true))
        answerIndex = messages.count - 1
        busy = true
        if request == nil { input = "" }
        attachScreen = false
        appendLog("**\(meetingTimestamp(nowMs)) You:** \(text)\n\n")
        session.send(built.message)
    }

    /// Tells Claude something with the next question, without asking anything now.
    func note() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.addNote(text, atMs: nowMs)
        messages.append(ChatMessage(role: .note, text: text, detail: "\(meetingTimestamp(nowMs)) note — sent with your next question"))
        appendLog("*\(meetingTimestamp(nowMs)) Note:* \(text)\n\n")
        input = ""
    }

    private func handle(_ event: ClaudeSession.Event) {
        switch event {
        case .ready:
            break
        case .delta(let text):
            guard let i = answerIndex else { return }
            messages[i].detail = nil
            messages[i].text += text
        case .reading(let tool):
            guard let i = answerIndex else { return }
            messages[i].detail = Self.describe(tool)
            if !messages[i].text.isEmpty { messages[i].text += "\n\n" }
        case .finished(let isError, let text):
            if let i = answerIndex {
                if messages[i].text.isEmpty { messages[i].text = text }
                if isError { messages[i].detail = "Claude reported an error" }
                messages[i].streaming = false
                appendLog("\(messages[i].text)\n\n---\n\n")
            }
            answerIndex = nil
            busy = false
        case .failed(let why):
            if let i = answerIndex {
                messages[i].streaming = false
                if messages[i].text.isEmpty { messages.remove(at: i) }
            }
            answerIndex = nil
            busy = false
            messages.append(ChatMessage(role: .status, text: "Claude stopped: \(why). Your next question starts it again."))
        }
    }

    /// What the panel says while Claude uses a tool.
    static func describe(_ tool: String) -> String {
        switch tool {
        case "Read": return "Reading…"
        case "Grep", "Glob": return "Searching the code…"
        case "Bash": return "Running a command…"
        default:
            // mcp__<server>__<tool>
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return "Using \(parts[1].replacingOccurrences(of: "_", with: " "))…" }
            return "Using \(tool)…"
        }
    }

    /// Every exchange, in the live directory beside the transcript, so the
    /// write-up after the meeting can include it.
    private func appendLog(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: chatLog) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? (Data("# Assistant — \(title)\n\n".utf8) + data).write(to: chatLog)
        }
    }

    func shutdown() {
        timer?.invalidate()
        session?.stop()
    }
}

// MARK: - Views

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState var inputFocused: Bool
    @State private var showPinned = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            controls
        }
        .frame(minWidth: 340, minHeight: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: model.recording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(model.recording ? .red : .secondary)
                    .accessibilityLabel(model.recording ? "Recording" : "Recording ended")
                Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("Model", selection: $model.model) {
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Sonnet answers faster; Opus thinks harder. Switching keeps the conversation.")
            }
            Text(model.liveText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        Text("Ask about anything said or shown in the meeting. Each question includes what's happened since the last one. \(HotKey.label) shows or hides this panel; it's hidden from your screen shares.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: model.messages.last?.text) { _ in
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(QuickAction.all) { action in
                        Button(action.title) { model.send(action.prompt, attach: action.attachScreen) }
                            .disabled(model.busy)
                    }
                    Button(showPinned ? "Hide pinned" : "Pinned notes") { showPinned.toggle() }
                }
                .controlSize(.small)
            }
            if showPinned {
                TextEditor(text: $model.pinned)
                    .font(.callout)
                    .frame(height: 54)
                    .overlay(alignment: .topLeading) {
                        if model.pinned.isEmpty {
                            Text("Sent with every question — e.g. \"Triaging INC-4821; payments deployed 09:30\"")
                                .font(.callout).foregroundStyle(.tertiary).padding(4).allowsHitTesting(false)
                        }
                    }
                    .border(Color.secondary.opacity(0.3))
            }
            HStack(alignment: .bottom, spacing: 6) {
                Toggle(isOn: $model.attachScreen) { Image(systemName: "rectangle.on.rectangle") }
                    .toggleStyle(.button)
                    .help("Include the current screen as an image")
                    .accessibilityLabel("Include the current screen")
                TextField(model.busy ? "Answering…" : "Ask about the meeting", text: $model.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { model.send() }
                Button("Note") { model.note() }
                    .help("Tell Claude something with your next question, without asking anything now")
                    .disabled(model.input.isEmpty)
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.input.isEmpty)
                    .accessibilityLabel("Ask")
            }
        }
        .padding(10)
        .onAppear { inputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .meeteyFocusInput)) { _ in inputFocused = true }
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 2) {
                Text(message.text)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
                if let detail = message.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if let detail = message.detail {
                    Label(detail, systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                } else if message.text.isEmpty && message.streaming {
                    ProgressView().controlSize(.small)
                }
                ForEach(Array(Self.blocks(message.text).enumerated()), id: \.offset) { _, block in
                    if block.code {
                        CodeBlock(text: block.text)
                    } else {
                        Text(Self.markdown(block.text)).textSelection(.enabled)
                    }
                }
                if !message.streaming && !message.text.isEmpty {
                    Button { copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            VStack(alignment: .leading, spacing: 2) {
                Label(message.text, systemImage: "pin").font(.callout)
                if let detail = message.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
        case .status:
            Label(message.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        }
    }

    /// Splits on ``` fences so code (logs, above all) renders monospaced with
    /// its own copy button. An unclosed fence while streaming is still code.
    static func blocks(_ text: String) -> [(code: Bool, text: String)] {
        var result: [(Bool, String)] = []
        for (i, part) in text.components(separatedBy: "```").enumerated() {
            if i % 2 == 1 {
                let body = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let code = body.count == 2 && !body[0].contains(" ") ? String(body[1]) : part
                result.append((true, code.trimmingCharacters(in: .newlines)))
            } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((false, part.trimmingCharacters(in: .newlines)))
            }
        }
        return result
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).font(.caption).padding(4)
                .help("Copy").accessibilityLabel("Copy code")
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension Notification.Name {
    static let meeteyFocusInput = Notification.Name("com.adamjhcox.meetey.panel.focus")
}

// MARK: - Window

/// A panel that floats over the call, takes typing without pulling Meetey to
/// the front, follows you across Spaces and full-screen meetings — and is
/// **excluded from screen capture**, so it never appears in your own screen
/// share.
final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Meetey"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        sharingType = .none
        contentView = content
        if !setFrameUsingName("MeeteyAssistant"), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 20, y: screen.maxY - frame.height - 20))
        }
        setFrameAutosaveName("MeeteyAssistant")
    }
}

/// Shown/hidden by the hotkey and by the menu bar's "Show Assistant", which
/// reaches an already-running panel through a distributed notification.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static var shared: PanelController?

    let panel: AssistantPanel
    let model: PanelModel
    let liveDir: URL
    private var hotKey: HotKey?

    init(model: PanelModel, liveDir: URL) {
        self.model = model
        self.liveDir = liveDir
        panel = AssistantPanel(content: NSHostingView(rootView: PanelView(model: model)))
        super.init()
        panel.delegate = self
        hotKey = HotKey { [weak self] in Task { @MainActor in self?.toggle() } }
        if hotKey == nil {
            fputs("meetey-capture: \(HotKey.label) is taken by another app — open the assistant from the menu bar instead\n", stderr)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: PanelController.showNotification, object: liveDir.path, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.show() } }
    }

    nonisolated static let showNotification = Notification.Name("com.adamjhcox.meetey.panel.show")

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
        NotificationCenter.default.post(name: .meeteyFocusInput, object: nil)
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { panel.orderOut(nil) } else { show() }
    }

    func windowWillClose(_ notification: Notification) {
        model.shutdown()
        try? FileManager.default.removeItem(at: PanelProcess.pidFile(liveDir))
        NSApp.terminate(nil)
    }
}

// MARK: - Process

/// The panel runs as its own process (`meetey-capture --panel …`), started by
/// the recording, so nothing it does — a UI crash, a hung Claude — can touch a
/// capture. One per live directory, tracked by `panel.pid` there.
enum PanelProcess {
    static func pidFile(_ liveDir: URL) -> URL { liveDir.appendingPathComponent("panel.pid") }

    static func runningPid(_ liveDir: URL) -> pid_t? {
        guard let text = try? String(contentsOf: pidFile(liveDir), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    /// Brings the panel for `liveDir` forward, starting it if it isn't running.
    static func showOrLaunch(liveDir: String, title: String, framesDir: String?, startedAt: Date) {
        let dir = URL(fileURLWithPath: liveDir)
        if runningPid(dir) != nil {
            DistributedNotificationCenter.default().postNotificationName(
                PanelController.showNotification, object: liveDir, userInfo: nil, deliverImmediately: true)
            return
        }
        guard let executable = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var args = ["--panel", "--live", liveDir, "--title", title,
                    "--started-at", String(Int(startedAt.timeIntervalSince1970 * 1000)),
                    "--capture-pid", String(getpid())]
        if let framesDir { args += ["--frames-dir", framesDir] }
        process.arguments = args
        let log = dir.appendingPathComponent("panel.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            fputs("meetey-capture: could not open the assistant (\(error.localizedDescription))\n", stderr)
        }
    }
}

/// Entry point for `--panel`. Runs AppKit until the panel is closed.
@MainActor
func runPanel(liveDir: String, title: String, framesDir: String?, startedAt: Date?, capturePid: pid_t?, claude: String?) {
    let dir = URL(fileURLWithPath: liveDir)
    if PanelProcess.runningPid(dir) != nil {
        DistributedNotificationCenter.default().postNotificationName(
            PanelController.showNotification, object: liveDir, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    try? String(getpid()).write(to: PanelProcess.pidFile(dir), atomically: true, encoding: .utf8)

    let started = startedAt
        ?? ((try? FileManager.default.attributesOfItem(atPath: liveDir)[.creationDate]) as? Date)
        ?? Date()
    let claudePath = ClaudeLocator.find(explicit: claude)
    if claudePath == nil { fputs("meetey-capture: Claude Code not found — the assistant can't answer\n", stderr) }

    NSApplication.shared.setActivationPolicy(.accessory)
    let model = PanelModel(title: title.isEmpty ? "Meeting" : title, liveDir: dir, framesDir: framesDir,
                           startedAt: started, capturePid: capturePid, claudePath: claudePath)
    let controller = PanelController(model: model, liveDir: dir)
    PanelController.shared = controller
    controller.show()
    fputs("meetey-capture: assistant open for \(liveDir)\n", stderr)
}

// MARK: - Headless

/// `meetey-capture --panel-ask "<question>" [--panel-ask …] --live <dir>`: the
/// panel's whole question path — context building, the Claude session, streamed
/// answer — without a window, printing what the panel would show. Each question
/// carries only what the previous one didn't, exactly as in the panel. For
/// testing against `--replay` output.
@MainActor
func panelAsk(questions: [String], liveDir: String, framesDir: String?, model: String, claude: String?) async -> Never {
    guard let claudePath = ClaudeLocator.find(explicit: claude) else {
        fputs("meetey-capture: Claude Code not found\n", stderr)
        exit(1)
    }
    let dir = URL(fileURLWithPath: liveDir)
    let context = MeetingContext(liveDir: dir)
    let started = ((try? FileManager.default.attributesOfItem(atPath: liveDir)[.creationDate]) as? Date) ?? Date()

    var finished: CheckedContinuation<Bool, Never>?
    let config = AssistantConfig.load()
    print("[working in \(config.workingDirectory.path) with \(config.tools.joined(separator: ", "))]")
    let session = ClaudeSession(claudePath: claudePath, workingDirectory: config.workingDirectory,
                                readableDirectories: [dir.path, framesDir].compactMap { $0 } + config.additionalDirectories,
                                tools: config.tools, model: model) { event in
        switch event {
        case .ready(let model): print("[\(model)]")
        case .delta(let text): print(text, terminator: ""); fflush(stdout)
        case .reading(let tool): print("\n(\(tool)…)")
        case .finished(let isError, _): print(isError ? "\n[error]\n" : "\n"); finished?.resume(returning: !isError); finished = nil
        case .failed(let why): print("\n[failed: \(why)]\n"); finished?.resume(returning: false); finished = nil
        }
    }

    var ok = true
    for question in questions {
        let built = context.build(request: question, pinned: "", attachScreen: false,
                                  nowMs: Int(Date().timeIntervalSince(started) * 1000))
        print("── You: \(question)  (+\(built.newLines) lines, \(built.newFrames) screens)")
        if ProcessInfo.processInfo.environment["MEETEY_SHOW_PROMPT"] == "1" { print(built.message) }
        let answered = await withCheckedContinuation { continuation in
            finished = continuation
            session.send(built.message)
        }
        ok = ok && answered
    }
    session.stop()
    exit(ok ? 0 : 1)
}
