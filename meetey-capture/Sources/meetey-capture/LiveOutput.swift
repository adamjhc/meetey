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
import CoreMedia
import Foundation
import Speech

// MARK: - Live directory

/// What a recording writes *while it runs*, for anything that needs the meeting
/// before it is over — the live transcript in a terminal, and the in-call
/// assistant. `<session>-live/`:
///
///     transcript-them.jsonl   finished lines from the call audio
///     transcript-me.jsonl     finished lines from your microphone
///     partial-them.json       the line still being spoken, replaced as it changes
///     partial-me.json
///     frames.jsonl            each keyframe and its OCR text, as it is captured
///
/// Call and mic come from different processes, so each has its own files and no
/// file ever has two writers. Times are milliseconds from the start of the
/// recording, counted in audio samples, so they line up with the WAVs and with
/// the post-meeting transcript. Everything here stays on the machine.
enum LiveFiles {
    static func transcript(_ dir: URL, speaker: String) -> URL { dir.appendingPathComponent("transcript-\(speaker).jsonl") }
    static func partial(_ dir: URL, speaker: String) -> URL { dir.appendingPathComponent("partial-\(speaker).json") }
    static func frames(_ dir: URL) -> URL { dir.appendingPathComponent("frames.jsonl") }
}

/// Appends one JSON object per line. Each line is a single write, so a reader
/// polling the file sees whole lines or nothing new — never half a line, as long
/// as it ignores a final line without its newline.
final class LiveLog {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.adamjhcox.meetey.livelog")

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func append(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        queue.async { self.handle.write(data) }
    }

    func close() {
        queue.sync { try? handle.close() }
    }
}

/// Replaces a small JSON file atomically, so a reader never sees it half-written.
func writeJSONAtomically(_ object: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    try? data.write(to: url, options: .atomic)
}

// MARK: - Live transcriber

/// Transcribes one speaker's audio as it arrives, with Apple's SpeechTranscriber.
///
/// Fed the same 16 kHz mono samples that go to the WAV, in order. Each buffer is
/// stamped with its position in the stream, so result times are sample-accurate
/// against the recording. Finished lines go to `transcript-<speaker>.jsonl`; the
/// line still being spoken goes to `partial-<speaker>.json` and is cleared when
/// it finishes.
///
/// Live transcription is a convenience on top of the recording. If the model is
/// missing or anything here fails, it says so once and the recording carries on.
@available(macOS 26.0, *)
final class LiveTranscriber {
    private let speaker: String
    private let log: LiveLog
    private let partialURL: URL
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var converter: AudioChunkConverter?
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    /// Serialises feeding. Audio that arrives while the model is still loading
    /// is held in `pending` rather than dropped, so the first sample fed is the
    /// first sample recorded and times stay aligned with the WAV.
    private let feedLock = NSLock()
    private var samplesFed: Int64 = 0
    private var ready = false
    private var failed = false
    private var pending: [[Int16]] = []
    private var pendingCount = 0
    /// Five minutes of audio; beyond that a stalled start is not worth the memory.
    private static let pendingLimit = 16_000 * 300

    init(directory: URL, speaker: String) throws {
        self.speaker = speaker
        log = try LiveLog(url: LiveFiles.transcript(directory, speaker: speaker))
        partialURL = LiveFiles.partial(directory, speaker: speaker)
        writeJSONAtomically(["speaker": speaker, "text": ""], to: partialURL)
    }

    /// Prepares the model and starts the analyzer, then feeds anything that
    /// arrived meanwhile. Returns false (having said why) when live
    /// transcription is not possible; the recording is unaffected.
    func start() async -> Bool {
        let started = await prepare()
        feedLock.withLock {
            if started {
                ready = true
                for samples in pending { feedLocked(samples) }
            } else {
                failed = true
            }
            pending = []
            pendingCount = 0
        }
        return started
    }

    private func prepare() async -> Bool {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            fputs("meetey-capture: live transcription unavailable — \(Locale.current.identifier) is not supported\n", stderr)
            return false
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                fputs("meetey-capture: downloading the speech model for live transcription\n", stderr)
                try await request.downloadAndInstall()
            }
        } catch {
            fputs("meetey-capture: live transcription unavailable — the speech model could not be installed (\(error.localizedDescription))\n", stderr)
            return false
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AudioChunkConverter(from: inputFormat, to: format) else {
            fputs("meetey-capture: live transcription unavailable — no compatible audio format\n", stderr)
            return false
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            fputs("meetey-capture: live transcription failed to start (\(error.localizedDescription))\n", stderr)
            return false
        }

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.converter = converter
        self.continuation = continuation
        let speaker = speaker, log = log, partialURL = partialURL
        results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let startMs = Int(result.range.start.seconds * 1000)
                    let endMs = Int(CMTimeRangeGetEnd(result.range).seconds * 1000)
                    if result.isFinal {
                        if !text.isEmpty {
                            log.append(["speaker": speaker, "startMs": startMs, "endMs": endMs, "text": text])
                        }
                        writeJSONAtomically(["speaker": speaker, "text": ""], to: partialURL)
                    } else {
                        writeJSONAtomically(["speaker": speaker, "startMs": startMs, "text": text], to: partialURL)
                    }
                }
            } catch {
                fputs("meetey-capture: live transcription stopped (\(error.localizedDescription)) — the recording continues\n", stderr)
            }
        }
        fputs("meetey-capture: live transcription started (\(speaker), \(locale.identifier))\n", stderr)
        return true
    }

    /// Feeds samples in recording order.
    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        feedLock.withLock {
            if failed { return }
            if !ready {
                if pendingCount < Self.pendingLimit {
                    pending.append(samples)
                    pendingCount += samples.count
                }
                return
            }
            feedLocked(samples)
        }
    }

    private func feedLocked(_ samples: [Int16]) {
        let start = samplesFed
        samplesFed += Int64(samples.count)
        guard let continuation, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        guard let converted = converter.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: CMTime(value: start, timescale: 16_000)))
    }

    /// Ends the input and waits for the last lines to be written.
    func finish() async {
        guard feedLock.withLock({ ready }) else { log.close(); return }
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        writeJSONAtomically(["speaker": speaker, "text": ""], to: partialURL)
        log.close()
    }
}

/// A live transcriber for `speaker` in `directory`, already starting in the
/// background, or nil — with the reason printed — when this Mac cannot
/// transcribe live. Audio can be appended immediately. The recording never
/// waits on this: a model download happens while it records.
func makeLiveTranscriber(directory: String?, speaker: String) -> AnyObject? {
    guard let directory else { return nil }
    guard #available(macOS 26.0, *) else {
        fputs("meetey-capture: live transcription needs macOS 26 — recording without it\n", stderr)
        return nil
    }
    do {
        let live = try LiveTranscriber(directory: URL(fileURLWithPath: directory), speaker: speaker)
        Task { _ = await live.start() }
        return live
    } catch {
        fputs("meetey-capture: live transcription unavailable (\(error.localizedDescription))\n", stderr)
        return nil
    }
}

/// For replay, which needs to know transcription works before it starts.
func startLiveTranscriber(directory: String?, speaker: String) async -> AnyObject? {
    guard let directory, #available(macOS 26.0, *) else { return nil }
    guard let live = try? LiveTranscriber(directory: URL(fileURLWithPath: directory), speaker: speaker) else { return nil }
    return await live.start() ? live : nil
}

/// `AnyObject` so callers on older SDK checks don't need `@available` themselves.
func liveAppend(_ live: AnyObject?, _ samples: [Int16]) {
    guard #available(macOS 26.0, *), let live = live as? LiveTranscriber else { return }
    live.append(samples)
}

func liveFinish(_ live: AnyObject?) async {
    guard #available(macOS 26.0, *), let live = live as? LiveTranscriber else { return }
    await live.finish()
}

// MARK: - Replay

/// `meetey-capture --replay <call.wav> [--replay-mic <mic.wav>] [--replay-frames <dir>]
///  --live <dir> [--replay-speed N]`
///
/// Plays a finished recording through the live pipeline at real time (or N×),
/// writing the same live files a meeting would. It is how the live path is
/// developed and tested without a call — and the files it writes are
/// indistinguishable from a live session's, so anything reading them can be
/// tested the same way.
func replay(callPath: String, micPath: String?, framesDir: String?, liveDir: String, speed: Double) async -> Never {
    let started = Date()
    let pace = max(0.1, speed)

    let call = await startLiveTranscriber(directory: liveDir, speaker: "them")
    let mic = micPath == nil ? nil : await startLiveTranscriber(directory: liveDir, speaker: "me")
    if call == nil {
        fputs("meetey-capture: replay needs live transcription, which is unavailable here\n", stderr)
        exit(1)
    }

    // Keyframes replay at their recorded offsets, from the session's manifest.
    let frameTask: Task<Void, Never>? = framesDir.map { dir in
        Task {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("index.json")),
                  let index = try? JSONDecoder().decode(FrameIndex.self, from: data),
                  let log = try? LiveLog(url: LiveFiles.frames(URL(fileURLWithPath: liveDir))) else {
                fputs("meetey-capture: no readable index.json in \(dir) — replaying audio only\n", stderr)
                return
            }
            for frame in index.frames.sorted(by: { $0.offsetMs < $1.offsetMs }) {
                let due = started.addingTimeInterval(Double(frame.offsetMs) / 1000 / pace)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                var line: [String: Any] = ["offsetMs": frame.offsetMs, "file": URL(fileURLWithPath: dir).appendingPathComponent(frame.file).path]
                if let text = frame.ocrText { line["ocrText"] = text }
                log.append(line)
            }
            log.close()
        }
    }

    // 100 ms chunks, paced against the wall clock so a slow machine catches up
    // rather than drifting.
    let chunk = 1_600
    func samples(_ path: String) -> [Int16] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        // Meetey's WAVs have a 44-byte header, but files from other tools carry
        // extra chunks, so find `data` rather than assume where it starts.
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if id == "data" {
                let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
                return body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            }
            offset += 8 + size + (size & 1)
        }
        return []
    }
    let callSamples = samples(callPath)
    let micSamples = micPath.map(samples) ?? []
    let total = max(callSamples.count, micSamples.count)
    fputs(String(format: "meetey-capture: replaying %.0fs of audio at %.1f× into %@\n",
                 Double(total) / 16_000, pace, liveDir), stderr)

    var offset = 0
    while offset < total {
        let end = min(offset + chunk, total)
        if offset < callSamples.count { liveAppend(call, Array(callSamples[offset..<min(end, callSamples.count)])) }
        if offset < micSamples.count { liveAppend(mic, Array(micSamples[offset..<min(end, micSamples.count)])) }
        offset = end
        let due = started.addingTimeInterval(Double(offset) / 16_000 / pace)
        let wait = due.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    await liveFinish(call)
    await liveFinish(mic)
    await frameTask?.value
    fputs(String(format: "meetey-capture: replay finished in %.0fs\n", Date().timeIntervalSince(started)), stderr)
    exit(0)
}
