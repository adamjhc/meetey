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

import AVFoundation
import Darwin
import Foundation

// MARK: - Responsibility

/// Who macOS asks for microphone permission.
///
/// TCC attributes a process's access to its *responsible* process: whatever app
/// launched it. For meetey-capture that is the terminal or editor hosting Claude
/// Code, or `node` for the watcher — and whether any of those can be granted the
/// microphone depends on its own Info.plist and entitlements. Some cannot, and
/// then the request is denied silently with no prompt.
///
/// So the mic is recorded by a helper that **disclaims** responsibility and
/// becomes responsible for itself. It runs from Meetey.app, so the prompt names
/// Meetey, uses Meetey's usage string, and is checked against Meetey's
/// entitlement — the same however the recording was started. Screen capture
/// stays in the parent and keeps its existing attribution.
///
/// `responsibility_spawnattrs_setdisclaim` is private API, looked up at run time;
/// without it the helper still runs, attributed to the launching app as before.
enum Responsibility {
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
    /// RTLD_DEFAULT, which Swift does not import.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    /// Runs this executable again with `args`, responsible for itself.
    static func spawnDisclaimed(_ args: [String]) -> pid_t? {
        guard let path = Bundle.main.executablePath else { return nil }

        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }

        if let symbol = dlsym(defaultHandle, "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attr, 1)
        } else {
            fputs("meetey-capture: cannot disclaim responsibility here — the microphone will be asked of the app that started Meetey\n", stderr)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, nil, &attr, argv, environ) == 0 ? pid : nil
    }

    /// The process TCC would ask on `pid`'s behalf, or nil when unknowable.
    static func responsiblePid(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let responsible = unsafeBitCast(symbol, to: ResponsibleFor.self)(pid)
        return responsible > 0 ? responsible : nil
    }
}

// MARK: - Timeline

/// Keeps the mic file on the same clock as the call audio.
///
/// The two files are merged by timestamp, so sample N of the mic file has to be
/// the same moment as sample N of the call file. The helper starts a beat after
/// the call capture, can sit behind a permission prompt for as long as the user
/// takes to answer, and loses buffers while a headset is swapped. Each of those
/// is a gap the wall clock knows about and the sample count does not, so
/// silence is inserted to close it.
enum MicTimeline {
    static let sampleRate = 16_000.0

    /// Silent samples to write before `incoming` so the file ends where the wall
    /// clock says it should. Under half a second is buffer jitter, not a gap.
    static func paddingBefore(elapsed: TimeInterval, written: Int, incoming: Int) -> Int {
        let gap = Int(elapsed * sampleRate) - (written + incoming)
        return gap > Int(sampleRate / 2) ? gap : 0
    }
}

// MARK: - Recorder

enum MicError: Error, LocalizedError {
    case noInput
    var errorDescription: String? { "no microphone input is available" }
}

/// Records the default input device as 16 kHz mono, the same format as the call
/// audio. Every write happens on `queue`, so the WAV is only ever touched from
/// one thread.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private let writer: WAVWriter
    private let epoch: Date
    private let queue = DispatchQueue(label: "com.adamjhcox.meetey.mic")
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MicTimeline.sampleRate,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    // Owned by `queue`.
    private var paused = false
    private var written = 0
    /// Sees every sample written to the file, silence included, so a live
    /// transcriber stays on the file's clock.
    var onSamples: (([Int16]) -> Void)?

    init(path: String, epoch: Date) throws {
        writer = try WAVWriter(path: path)
        self.epoch = epoch
    }

    func start() throws {
        // Plugging in or removing a headset reconfigures the engine and stops it.
        // Without a restart the rest of the meeting would be silence on this side.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restart() }
        }
        try installTapAndStart()
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInput }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = self.convert(buffer) else { return }
            let now = Date()
            self.queue.async { self.write(samples, at: now) }
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTapAndStart()
            fputs("meetey-capture: microphone changed — recording from the new input\n", stderr)
        } catch {
            fputs("meetey-capture: microphone changed and could not restart (\(error.localizedDescription)) — your side is silent from here\n", stderr)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    private func write(_ samples: [Int16], at now: Date) {
        let pad = MicTimeline.paddingBefore(elapsed: now.timeIntervalSince(epoch),
                                            written: written, incoming: samples.count)
        if pad > 0 { appendSilence(pad) }
        // Paused writes silence rather than nothing, so the file stays continuous
        // and its length still matches the call audio.
        if paused {
            appendSilence(samples.count)
        } else {
            writer.append(samples: samples)
            written += samples.count
            onSamples?(samples)
        }
    }

    private func appendSilence(_ count: Int) {
        var remaining = count
        let chunk = [Int16](repeating: 0, count: Int(MicTimeline.sampleRate))
        while remaining > 0 {
            let n = min(remaining, chunk.count)
            let silence = n == chunk.count ? chunk : Array(chunk.prefix(n))
            writer.append(samples: silence)
            onSamples?(silence)
            remaining -= n
        }
        written += count
    }

    func setPaused(_ value: Bool) {
        queue.async { self.paused = value }
    }

    /// Stops the engine, pads to now so the file covers the whole recording, and
    /// finalises it. Buffers already queued are written first.
    func finish() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync {
            let pad = MicTimeline.paddingBefore(elapsed: Date().timeIntervalSince(epoch),
                                                written: written, incoming: 0)
            if pad > 0 { appendSilence(pad) }
            writer.finalize()
        }
    }
}

/// The helper process: `meetey-capture --record-mic --output <path> --epoch-ms <ms>`.
///
/// Started by a recording with `--mic`, never by hand. SIGTERM/SIGINT finish the
/// file, SIGUSR1 pauses and SIGUSR2 resumes. It also finishes if its parent
/// disappears, since nothing else would ever stop it.
func recordMic(outputPath: String, epoch: Date, liveDir: String? = nil) async -> Never {
    // Until the file exists there is nothing to save, so a stop just ends the
    // process — and the parent is watched from the start. Waiting on the
    // permission prompt used to happen before either: a check that gave up left
    // this helper behind, parentless, holding its parent's output open (which
    // hung `install`) until the prompt was answered.
    let parent = getppid()
    signal(SIGTERM, SIG_DFL)
    signal(SIGINT, SIG_DFL)
    Task.detached {
        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if getppid() != parent { exit(0) }
        }
    }

    let granted: Bool
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: granted = true
    case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
    default: granted = false
    }
    guard granted else {
        fputs("meetey-capture: microphone access denied — your side of the call is not being recorded. "
            + "Allow Meetey in System Settings → Privacy & Security → Microphone.\n", stderr)
        exit(2)
    }

    let recorder: MicRecorder
    let live = makeLiveTranscriber(directory: liveDir, speaker: "me")
    do {
        recorder = try MicRecorder(path: outputPath, epoch: epoch)
        recorder.onSamples = { liveAppend(live, $0) }
        try recorder.start()
    } catch {
        fputs("meetey-capture: microphone recording failed to start (\(error.localizedDescription))\n", stderr)
        exit(1)
    }
    fputs("meetey-capture: microphone recording started\n", stderr)

    // A signal and the orphan check can both ask; the file is finished once.
    let finishing = NSLock()
    var finished = false
    let finish = {
        guard finishing.withLock({ () -> Bool in
            defer { finished = true }
            return !finished
        }) else { return }
        recorder.finish()
        fputs("meetey-capture: microphone recording saved to \(outputPath)\n", stderr)
        Task {
            await liveFinish(live)
            exit(0)
        }
    }

    var sources: [DispatchSourceSignal] = []
    for (sig, action) in [(SIGTERM, finish), (SIGINT, finish),
                          (SIGUSR1, { recorder.setPaused(true) }),
                          (SIGUSR2, { recorder.setPaused(false) })] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: action)
        source.resume()
        sources.append(source)
    }

    while true {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if getppid() != parent {
            fputs("meetey-capture: recording process went away — saving the microphone file\n", stderr)
            finish()
        }
    }
}

/// Cuts a finished WAV back to `target` data bytes, if it is longer. The call
/// recording is trimmed when the call ends earlier than the stop, and the mic
/// file has to end at the same moment or it would carry the waiting on alone.
func truncateWAV(atPath path: String, toDataBytes target: UInt32) {
    guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    guard size > UInt64(WAVWriter.headerBytes) else { return }
    let dataBytes = UInt32(size - UInt64(WAVWriter.headerBytes))
    guard dataBytes > target else { return }

    let trimmed = target - target % 2
    func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    try? handle.truncate(atOffset: UInt64(WAVWriter.headerBytes + trimmed))
    handle.seek(toFileOffset: 4)
    handle.write(le(36 + trimmed))
    handle.seek(toFileOffset: 40)
    handle.write(le(trimmed))
}

// MARK: - Verify

/// `meetey-capture --verify-mic`: records two seconds through the same helper a
/// meeting uses. `verify` runs it, and so do install and update, so the
/// permission prompt arrives then rather than a minute into a call — and an
/// update whose re-signing reset the grant is caught before it costs a meeting.
///
/// Exits 0 when the mic recorded, 2 when access was denied, 1 otherwise.
func verifyMic() async -> Never {
    let path = NSTemporaryDirectory() + "meetey-verify-mic-\(getpid()).wav"
    let finish = { (code: Int32, line: String) -> Never in
        try? FileManager.default.removeItem(atPath: path)
        print(line)
        exit(code)
    }

    let epochMs = String(Int(Date().timeIntervalSince1970 * 1000))
    guard let pid = Responsibility.spawnDisclaimed(["--record-mic", "--output", path, "--epoch-ms", epochMs]) else {
        finish(1, "  ✗ Microphone  could not start the recording helper")
    }
    print("  … Microphone  recording 2s — if macOS asks, allow Meetey")

    // Long enough to read and answer a permission prompt.
    let deadline = Date().addingTimeInterval(90)
    var recordingSince: Date? = nil
    var status: Int32 = 0
    while Date() < deadline {
        if waitpid(pid, &status, WNOHANG) == pid {
            let code = (status >> 8) & 0xff
            if (status & 0x7f) == 0, code == 2 {
                finish(2, "  ✗ Microphone  access denied — your side of meetings won't be recorded. "
                    + "Allow Meetey in System Settings → Privacy & Security → Microphone.")
            }
            finish(1, "  ✗ Microphone  the recording helper stopped unexpectedly")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > Int(WAVWriter.headerBytes) {
            recordingSince = recordingSince ?? Date()
            if Date().timeIntervalSince(recordingSince!) >= 2 { break }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // Never leave the helper behind: if it doesn't finish promptly (it may still
    // be waiting on the permission prompt), stop it outright.
    kill(pid, SIGTERM)
    var ended = false
    for _ in 0..<30 where !ended {
        ended = waitpid(pid, &status, WNOHANG) == pid
        if !ended { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    if !ended {
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
    }
    guard recordingSince != nil else {
        finish(1, "  ✗ Microphone  nothing was recorded within 90s")
    }
    finish(0, "  ✓ Microphone  recorded, as Meetey")
}
