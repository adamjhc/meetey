//
// Copyright 2026 John Joseph
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
//

import AppKit
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import CoreImage
import Vision

// MARK: - Argument parsing

struct Args {
    let bundleID: String
    let outputPath: String
    let stopAfter: TimeInterval?
    let listApps: Bool
    let listDisplays: Bool
    let listWindows: Bool
    let displayID: UInt32?
    let windowID: UInt32?
    let selfTest: Bool
    let verifyMode: Bool
    let video: Bool
    let fps: Int
    let framesDir: String?
    let ocr: Bool
    let sceneThreshold: Int
    let maxFrames: Int
    let maxUnsettled: TimeInterval
    let volatilityMask: Bool
    let autoStop: Bool
    let autoStopGrace: TimeInterval
    let stopWhenCallEnds: Bool
    let callEndGrace: TimeInterval
    let menuBar: Bool
    let label: String
    let watchIndicator: Bool
    let stateFile: String
    let plistPath: String
    /// Also record the default microphone to this path (see MicCapture.swift).
    let micPath: String?
    /// Internal: run as the microphone helper.
    let recordMic: Bool
    let epochMs: Double?
    /// Internal: write "<pid> <responsible pid>" to this path and exit.
    let responsibleCheck: String?
    let verifyMic: Bool
    let preflightSpeech: Bool
    /// Write live transcript and keyframe files here as the recording runs.
    let liveDir: String?
    let replayPath: String?
    let replayMicPath: String?
    let replayFramesDir: String?
    let replaySpeed: Double
    /// Open the in-call assistant (Panel/) when this recording starts.
    let assistant: Bool
    /// Internal: run as the assistant panel for `liveDir`.
    let panel: Bool
    let title: String
    let startedAtMs: Double?
    let capturePid: pid_t?
    let claudePath: String?
    let panelAsk: [String]
    let model: String
    /// The meeting's window, so its closing can confirm the call is over.
    let meetingWindow: UInt32?
    let meetingTitle: String
    let quickEndGrace: TimeInterval
    let fallbackEndGrace: TimeInterval

    static func parse() -> Args {
        var bundleID = ""
        var outputPath = ""
        var stopAfter: TimeInterval? = nil
        var listApps = false
        var listDisplays = false
        var listWindows = false
        var displayID: UInt32? = nil
        var windowID: UInt32? = nil
        var selfTest = false
        var verifyMode = false
        var video = false
        var fps = 1
        var framesDir: String? = nil
        var ocr = true
        var sceneThreshold = 12
        var maxFrames = 200
        var maxUnsettled: TimeInterval = 60
        var volatilityMask = true
        var autoStop = false
        var autoStopGrace: TimeInterval = 30
        var stopWhenCallEnds = false
        var callEndGrace: TimeInterval = 60
        var menuBar = false
        var label = ""
        var watchIndicator = false
        var stateFile = ""
        var plistPath = ""
        var micPath: String? = nil
        var recordMic = false
        var epochMs: Double? = nil
        var responsibleCheck: String? = nil
        var verifyMic = false
        var preflightSpeech = false
        var liveDir: String? = nil
        var replayPath: String? = nil
        var replayMicPath: String? = nil
        var replayFramesDir: String? = nil
        var replaySpeed = 1.0
        var assistant = false
        var panel = false
        var title = ""
        var startedAtMs: Double? = nil
        var capturePid: pid_t? = nil
        var claudePath: String? = nil
        var panelAsk: [String] = []
        var model = "sonnet"
        var meetingWindow: UInt32? = nil
        var meetingTitle = ""
        var quickEndGrace: TimeInterval = 15
        var fallbackEndGrace: TimeInterval = 600
        let args = CommandLine.arguments.dropFirst()
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--app":             bundleID = it.next() ?? ""
            case "--output":          outputPath = it.next() ?? ""
            case "--stop-after":      stopAfter = TimeInterval(it.next() ?? "")
            case "--list-apps":       listApps = true
            case "--list-displays":   listDisplays = true
            case "--list-windows":    listWindows = true
            case "--display":         displayID = UInt32(it.next() ?? "")
            case "--window":          windowID = UInt32(it.next() ?? "")
            case "--selftest":        selfTest = true
            case "--verify":          verifyMode = true
            case "--video":           video = true
            case "--fps":             fps = max(1, Int(it.next() ?? "") ?? 1)
            case "--frames-dir":      framesDir = it.next()
            case "--no-ocr":          ocr = false
            case "--scene-threshold": sceneThreshold = Int(it.next() ?? "") ?? 12
            case "--max-frames":      maxFrames = Int(it.next() ?? "") ?? 200
            case "--max-unsettled":  maxUnsettled = TimeInterval(it.next() ?? "") ?? 60
            case "--no-volatility-mask": volatilityMask = false
            case "--auto-stop":       autoStop = true
            case "--auto-stop-grace": autoStopGrace = TimeInterval(it.next() ?? "") ?? 30
            case "--stop-when-call-ends": stopWhenCallEnds = true
            case "--call-end-grace":  callEndGrace = TimeInterval(it.next() ?? "") ?? 60
            case "--menu-bar":        menuBar = true
            case "--label":           label = it.next() ?? ""
            case "--watch-indicator": watchIndicator = true
            case "--state-file":      stateFile = it.next() ?? ""
            case "--plist":           plistPath = it.next() ?? ""
            case "--mic":             micPath = it.next()
            case "--record-mic":      recordMic = true
            case "--epoch-ms":        epochMs = Double(it.next() ?? "")
            case "--responsible-check": responsibleCheck = it.next()
            case "--verify-mic":      verifyMic = true
            case "--preflight-speech": preflightSpeech = true
            case "--live":            liveDir = it.next()
            case "--replay":          replayPath = it.next()
            case "--replay-mic":      replayMicPath = it.next()
            case "--replay-frames":   replayFramesDir = it.next()
            case "--replay-speed":    replaySpeed = Double(it.next() ?? "") ?? 1
            case "--assistant":       assistant = true
            case "--panel":           panel = true
            case "--title":           title = it.next() ?? ""
            case "--started-at":      startedAtMs = Double(it.next() ?? "")
            case "--capture-pid":     capturePid = pid_t(it.next() ?? "")
            case "--claude":          claudePath = it.next()
            case "--panel-ask":       if let q = it.next() { panelAsk.append(q) }
            case "--model":           model = it.next() ?? "sonnet"
            case "--meeting-window":  meetingWindow = UInt32(it.next() ?? "")
            case "--meeting-title":   meetingTitle = it.next() ?? ""
            case "--quick-end-grace": quickEndGrace = TimeInterval(it.next() ?? "") ?? 15
            case "--fallback-end-grace": fallbackEndGrace = TimeInterval(it.next() ?? "") ?? 600
            default: break
            }
        }
        return Args(bundleID: bundleID, outputPath: outputPath, stopAfter: stopAfter,
                    listApps: listApps, listDisplays: listDisplays, listWindows: listWindows,
                    displayID: displayID, windowID: windowID,
                    selfTest: selfTest, verifyMode: verifyMode, video: video, fps: fps,
                    framesDir: framesDir, ocr: ocr, sceneThreshold: sceneThreshold,
                    maxFrames: maxFrames, maxUnsettled: maxUnsettled,
                    volatilityMask: volatilityMask, autoStop: autoStop,
                    autoStopGrace: autoStopGrace, stopWhenCallEnds: stopWhenCallEnds,
                    callEndGrace: callEndGrace, menuBar: menuBar, label: label,
                    watchIndicator: watchIndicator, stateFile: stateFile, plistPath: plistPath,
                    micPath: micPath, recordMic: recordMic, epochMs: epochMs,
                    responsibleCheck: responsibleCheck, verifyMic: verifyMic,
                    preflightSpeech: preflightSpeech, liveDir: liveDir, replayPath: replayPath,
                    replayMicPath: replayMicPath, replayFramesDir: replayFramesDir,
                    replaySpeed: replaySpeed, assistant: assistant, panel: panel, title: title,
                    startedAtMs: startedAtMs, capturePid: capturePid, claudePath: claudePath,
                    panelAsk: panelAsk, model: model, meetingWindow: meetingWindow,
                    meetingTitle: meetingTitle, quickEndGrace: quickEndGrace,
                    fallbackEndGrace: fallbackEndGrace)
    }
}

// MARK: - WAV writer

final class WAVWriter {
    private let fileHandle: FileHandle
    private var dataByteCount: UInt32 = 0
    private let sampleRate: UInt32 = 16000
    private let channels: UInt16 = 1
    private let bitsPerSample: UInt16 = 16
    /// `dataByteCount` is written on the audio queue and read by the call-end
    /// poll on another thread.
    private let counterLock = NSLock()

    static let headerBytes: UInt32 = 44

    /// How far the recording has got, as a byte offset into the data chunk.
    /// Safe to call from any thread.
    var bytesWritten: UInt32 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return dataByteCount
    }

    /// Seconds of audio in a given number of data bytes.
    func seconds(forDataBytes bytes: UInt32) -> Double {
        Double(bytes) / (Double(sampleRate) * Double(channels) * Double(bitsPerSample) / 8)
    }

    /// Data-chunk offset at which audible sound was last written.
    ///
    /// A second opinion on whether a call has really ended: the microphone being
    /// released says the app thinks it is over, this says nobody is still
    /// talking. Both must agree before a recording is cut back.
    private var lastAudibleByteCount: UInt32 = 0
    var lastAudibleOffset: UInt32 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return lastAudibleByteCount
    }

    /// Deliberately low. Being wrong in the quiet direction means trimming a
    /// live meeting; being wrong in the loud direction just means recording a
    /// little longer, so anything above near-digital-silence counts as speech.
    private let audibleAmplitude: Int16 = 300

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writePlaceholderHeader()
    }

    private func writePlaceholderHeader() {
        var header = Data(count: 44)
        header.replaceSubrange(0..<4,   with: "RIFF".utf8)
        header.replaceSubrange(8..<12,  with: "WAVE".utf8)
        header.replaceSubrange(12..<16, with: "fmt ".utf8)
        let fmtSize: UInt32  = 16
        let pcm: UInt16      = 1
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = channels * bitsPerSample / 8
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        header.replaceSubrange(16..<20, with: le(fmtSize))
        header.replaceSubrange(20..<22, with: le(pcm))
        header.replaceSubrange(22..<24, with: le(channels))
        header.replaceSubrange(24..<28, with: le(sampleRate))
        header.replaceSubrange(28..<32, with: le(byteRate))
        header.replaceSubrange(32..<34, with: le(blockAlign))
        header.replaceSubrange(34..<36, with: le(bitsPerSample))
        header.replaceSubrange(36..<40, with: "data".utf8)
        fileHandle.write(header)
    }

    func append(samples: [Int16]) {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let le = s.littleEndian
            data.append(contentsOf: withUnsafeBytes(of: le) { Data($0) })
        }
        fileHandle.write(data)

        var audible = false
        for sample in samples where abs(Int(sample)) > Int(audibleAmplitude) {
            audible = true
            break
        }

        counterLock.lock()
        dataByteCount += UInt32(data.count)
        if audible { lastAudibleByteCount = dataByteCount }
        bytesSinceHeaderRefresh += UInt32(data.count)
        let needsRefresh = bytesSinceHeaderRefresh >= Self.headerRefreshInterval
        if needsRefresh { bytesSinceHeaderRefresh = 0 }
        let sizeNow = dataByteCount
        counterLock.unlock()

        if needsRefresh { writeSizes(dataBytes: sizeNow) }
    }

    /// How much audio may accumulate before the header is brought up to date.
    /// 64 KB is two seconds at 16 kHz mono 16-bit — small enough that a file is
    /// never meaningfully stale, cheap enough to be invisible (two seeks and
    /// eight bytes).
    static let headerRefreshBudget: UInt32 = 64_000
    private static let headerRefreshInterval: UInt32 = headerRefreshBudget
    private var bytesSinceHeaderRefresh: UInt32 = 0

    /// Brings the two size fields up to date, then returns to appending.
    ///
    /// **This is what makes the file valid while it is being written.** Writing
    /// the sizes only at `finalize()` meant a recording was an unreadable stub
    /// for its entire duration and became a real file at the last instant — so
    /// any interruption, at any point in an hour, destroyed all of it. A closed
    /// window, a killed process, a hang: every one of those produced a file that
    /// looked empty despite containing the whole meeting.
    private func writeSizes(dataBytes: UInt32) {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        fileHandle.seek(toFileOffset: 4)
        fileHandle.write(le(36 + dataBytes))
        fileHandle.seek(toFileOffset: 40)
        fileHandle.write(le(dataBytes))
        fileHandle.seekToEndOfFile()
    }

    /// Closes the file. `trimmingToDataBytes` cuts the recording back to an
    /// earlier point — used when the call turned out to have ended before we
    /// stopped recording, so the trailing silence never reaches the transcript.
    /// The audio is uncompressed, so this is a truncation and a header rewrite,
    /// not a re-encode.
    @discardableResult
    func finalize(trimmingToDataBytes trim: UInt32? = nil) -> UInt32 {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var finalBytes = bytesWritten
        if var trim, trim < finalBytes {
            // Never cut mid-sample: a 16-bit frame is two bytes and half of one
            // is noise at the end of the file.
            let frameBytes = UInt32(channels * bitsPerSample / 8)
            trim -= trim % frameBytes
            try? fileHandle.truncate(atOffset: UInt64(Self.headerBytes + trim))
            finalBytes = trim
        }

        let riffSize = 36 + finalBytes
        fileHandle.seek(toFileOffset: 4)
        fileHandle.write(le(riffSize))
        fileHandle.seek(toFileOffset: 40)
        fileHandle.write(le(finalBytes))
        fileHandle.closeFile()
        return finalBytes
    }
}

// MARK: - Keyframe writer

struct FrameRecord: Codable {
    let file: String
    let offsetMs: Int
    let fingerprint: String
    let ocrText: String?
    /// Later offsets at which this same screen came back — a deck navigated
    /// backwards, a tab switched away from and returned to. Recorded instead of
    /// writing a second copy of an image already on disk, so the timeline stays
    /// complete while the file count does not grow. Omitted when empty.
    var revisitsMs: [Int]? = nil
}

struct FrameIndex: Codable {
    let sessionId: String
    let startedAt: String
    let frameCount: Int
    let truncated: Bool
    let frames: [FrameRecord]
}

/// Persists a JPEG only when the screen changes materially, so an hour of
/// mostly-static meeting produces tens of frames rather than thousands.
///
/// Two stages, deliberately split across queues: perceptual hashing is cheap
/// enough to run on the capture callback, while JPEG encoding and OCR are not —
/// blocking the callback makes ScreenCaptureKit drop frames.
final class KeyframeWriter {
    private let framesDir: URL
    private let sessionId: String
    private let sceneThreshold: Int
    private let maxFrames: Int
    private let ocrEnabled: Bool
    private let startedAt: Date

    private let workQueue = DispatchQueue(label: "com.adamjhcox.meetey.keyframes", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Touched only from the capture queue.
    private var lastAcceptedGrid: [UInt8]?
    private var lastAcceptedAt: Date?
    private var accepted = 0
    /// Every keyframe's grid, so a screen that comes back is recognised as one we
    /// already hold. 200 frames x 1024 bytes, so retaining all of them is free.
    private var acceptedGrids: [(grid: [UInt8], file: String)] = []

    /// A scene change that has been seen but not yet written. Keyframes are
    /// persisted when the screen *stops* moving rather than when it starts, so a
    /// slide transition or scroll animation collapses to the single frame worth
    /// keeping — and that frame is the settled one, which also OCRs better than
    /// anything caught mid-fade.
    private var pendingGrid: [UInt8]?
    private var pendingBuffer: CVPixelBuffer?
    private var pendingSince: Date?
    private var pendingLastSeen: Date?

    /// Rolling record of which cells moved between *consecutive* samples, used to
    /// mask out regions that are always in motion: a camera tile, a progress bar,
    /// a clock. Without it the standard slide-plus-speaker-tile layout exceeds the
    /// threshold on every sample for the whole meeting, which is what exhausts the
    /// frame budget in the first few minutes.
    private var previousSampleGrid: [UInt8]?
    private var volatilityRing: [[Bool]] = []
    private var volatilityCounts = [Int](repeating: 0, count: gridSide * gridSide)
    private var volatileCells = [Bool](repeating: false, count: gridSide * gridSide)
    /// `volatileCells` grown by one cell — this is what comparisons actually use.
    private var maskedCells = [Bool](repeating: false, count: gridSide * gridSide)

    // Touched only from workQueue.
    private var frames: [FrameRecord] = []
    private var truncated = false
    /// When set, each keyframe is also announced here the moment it is written,
    /// for readers that need the screen before the meeting ends.
    var liveLog: LiveLog?

    /// Long edge of the persisted JPEG. Matches Claude's high-resolution image
    /// tier — anything larger costs storage without buying legibility.
    private let maxJPEGEdge: CGFloat = 2576
    /// Floor between two keyframes. Largely redundant now that settling gates the
    /// write, but it still bounds a screen that alternates between two states
    /// faster than anyone could read either.
    private let debounce: TimeInterval = 2.0
    /// How far the screen must have stopped moving to count as settled. Stricter
    /// than `sceneThreshold` on purpose — "has come to rest" is a stronger claim
    /// than "has changed".
    private var settleThreshold: Int { max(1, sceneThreshold / 2) }
    /// Samples in the volatility window, and the fraction of them a cell must move
    /// in to be treated as permanently in motion.
    private let volatilityWindow = 15
    private let volatilityFraction = 0.6
    /// A screen that never comes to rest — a video demo, a continuously scrolling
    /// log — would otherwise emit nothing at all. Force a capture this often.
    private let maxUnsettled: TimeInterval
    private let volatilityMaskEnabled: Bool

    init(framesDir: URL, sessionId: String, sceneThreshold: Int, maxFrames: Int,
         ocrEnabled: Bool, startedAt: Date, maxUnsettled: TimeInterval = 60,
         volatilityMaskEnabled: Bool = true) throws {
        self.framesDir = framesDir
        self.sessionId = sessionId
        self.sceneThreshold = sceneThreshold
        self.maxFrames = maxFrames
        self.ocrEnabled = ocrEnabled
        self.startedAt = startedAt
        self.maxUnsettled = maxUnsettled
        self.volatilityMaskEnabled = volatilityMaskEnabled
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    }

    /// Called on the capture queue. Returns immediately for frames that don't
    /// differ enough from the last keyframe, which is the overwhelming majority.
    func consider(pixelBuffer: CVPixelBuffer, at now: Date) {
        guard let grid = lumaGrid(pixelBuffer) else { return }

        recordVolatility(of: grid)

        if Self.debugEnabled {
            let masked = lastAcceptedGrid.map { changedCells($0, grid) } ?? -1
            let raw = lastAcceptedGrid.map { changedCells($0, grid, masked: false) } ?? -1
            let settle = pendingGrid.map { changedCells($0, grid) } ?? -1
            fputs("  [dbg] t=\(Int(now.timeIntervalSince(startedAt)))s vol=\(volatileCells.filter { $0 }.count) ring=\(volatilityRing.count) dAcc=\(masked) dAccRaw=\(raw) dPend=\(settle) pending=\(pendingGrid != nil) accepted=\(accepted)\n", stderr)
        }

        // The first frame establishes the reference scene, so it is always kept.
        guard let reference = lastAcceptedGrid else {
            accept(pixelBuffer: pixelBuffer, grid: grid, at: now)
            return
        }

        // Indistinguishable from what we already have. Anything that was mid-change
        // has evidently reverted, so drop it.
        if changedCells(reference, grid) < sceneThreshold {
            // ...unless the only reason it looks unchanged is that the mask is
            // ignoring the parts that moved. A full-screen video makes every cell
            // volatile, and silently recording nothing for an hour is worse than
            // recording a frame a minute.
            if let last = lastAcceptedAt,
               now.timeIntervalSince(last) >= maxUnsettled,
               changedCells(reference, grid, masked: false) >= sceneThreshold {
                clearPending()
                accept(pixelBuffer: pixelBuffer, grid: grid, at: now)
                return
            }
            clearPending()
            return
        }

        guard let pending = pendingGrid else {
            setPending(grid: grid, pixelBuffer: pixelBuffer, since: now, at: now)
            return
        }

        // The screen has come to rest since the last sample — this is the frame
        // that was worth waiting for.
        if changedCells(pending, grid) < settleThreshold {
            if let last = lastAcceptedAt, now.timeIntervalSince(last) < debounce { return }
            clearPending()
            accept(pixelBuffer: pixelBuffer, grid: grid, at: now)
            return
        }

        // Still moving. Track the newest state, but don't let a screen that never
        // settles produce nothing at all.
        let since = pendingSince ?? now
        if now.timeIntervalSince(since) >= maxUnsettled {
            clearPending()
            accept(pixelBuffer: pixelBuffer, grid: grid, at: now)
        } else {
            setPending(grid: grid, pixelBuffer: pixelBuffer, since: since, at: now)
        }
    }

    private func setPending(grid: [UInt8], pixelBuffer: CVPixelBuffer, since: Date, at now: Date) {
        pendingGrid = grid
        pendingSince = since
        pendingLastSeen = now
        // Held so a change still in progress when the meeting ends can be flushed
        // by `finalize()` rather than lost.
        pendingBuffer = copyPixelBuffer(pixelBuffer)
    }

    private func clearPending() {
        pendingGrid = nil
        pendingBuffer = nil
        pendingSince = nil
        pendingLastSeen = nil
    }

    /// Commits a frame. Callers have already decided the screen changed and came
    /// to rest; this decides whether that resting state is one we already hold.
    private func accept(pixelBuffer: CVPixelBuffer, grid: [UInt8], at now: Date) {
        let offsetMs = Int(now.timeIntervalSince(startedAt) * 1000)

        // Compared against every keyframe so far, not just the previous one.
        // Otherwise navigating a deck 4 -> 5 -> 4 writes slide 4 twice.
        //
        // The comparison is masked, so the same slide matches itself regardless of
        // what the speaker tile beside it was doing. That only holds while enough
        // of the grid is unmasked to tell two screens apart: on a full-screen video
        // every cell is volatile, and a fully-masked comparison would report every
        // frame as a revisit of the first one.
        let comparable = maskedCells.lazy.filter { !$0 }.count
        if comparable >= maskedCells.count / 4,
           let seen = acceptedGrids.first(where: { changedCells($0.grid, grid) < sceneThreshold }) {
            lastAcceptedGrid = grid
            lastAcceptedAt = now
            workQueue.async { [weak self] in
                self?.recordRevisit(file: seen.file, offsetMs: offsetMs)
            }
            return
        }

        guard accepted < maxFrames else {
            if lastAcceptedGrid != nil { workQueue.async { self.truncated = true } }
            return
        }

        lastAcceptedGrid = grid
        lastAcceptedAt = now
        accepted += 1
        let seq = accepted
        let fingerprint = self.fingerprint(of: grid)
        acceptedGrids.append((grid: grid, file: Self.frameName(seq: seq, offsetMs: offsetMs)))

        // The sample buffer is recycled the moment this returns, so hand the
        // slow stage its own copy.
        guard let copy = copyPixelBuffer(pixelBuffer) else { return }

        workQueue.async { [weak self] in
            self?.persist(pixelBuffer: copy, seq: seq, offsetMs: offsetMs, fingerprint: fingerprint)
        }
    }

    /// The manifest key for a frame. Derived rather than stored so the capture
    /// queue can name a frame before the work queue has written it.
    fileprivate static func frameName(seq: Int, offsetMs: Int) -> String {
        String(format: "%04d-%06d.jpg", seq, offsetMs)
    }

    /// Runs on workQueue, where `frames` lives. The originating `persist` was
    /// dispatched on an earlier sample, so it has already run.
    private func recordRevisit(file: String, offsetMs: Int) {
        guard let index = frames.firstIndex(where: { $0.file == file }) else { return }
        frames[index].revisitsMs = (frames[index].revisitsMs ?? []) + [offsetMs]
        liveLog?.append(["offsetMs": offsetMs, "file": framesDir.appendingPathComponent(file).path, "revisit": true])
    }

    private func persist(pixelBuffer: CVPixelBuffer, seq: Int, offsetMs: Int, fingerprint: String) {
        let name = Self.frameName(seq: seq, offsetMs: offsetMs)
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        // OCR runs on the native-resolution buffer — downscaling first is the
        // difference between legible text and noise on a Retina display.
        var ocrText: String? = nil
        if ocrEnabled {
            ocrText = recognizeText(in: pixelBuffer)
        }

        let scale = min(1.0, maxJPEGEdge / max(image.extent.width, image.extent.height))
        let scaled = scale < 1.0
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        let options: [CIImageRepresentationOption: Any] =
            [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]
        guard let jpeg = ciContext.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: options) else {
            fputs("meetey-capture: failed to encode keyframe \(name)\n", stderr)
            return
        }

        do {
            try jpeg.write(to: framesDir.appendingPathComponent(name))
        } catch {
            fputs("meetey-capture: failed to write keyframe \(name): \(error.localizedDescription)\n", stderr)
            return
        }

        let text = (ocrText?.isEmpty ?? true) ? nil : ocrText
        frames.append(FrameRecord(
            file: name,
            offsetMs: offsetMs,
            fingerprint: fingerprint,
            ocrText: text
        ))
        var line: [String: Any] = ["offsetMs": offsetMs, "file": framesDir.appendingPathComponent(name).path]
        if let text { line["ocrText"] = text }
        liveLog?.append(line)
    }

    private func recognizeText(in pixelBuffer: CVPixelBuffer) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            fputs("meetey-capture: OCR failed: \(error.localizedDescription)\n", stderr)
            return nil
        }
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Side of the square luma grid used for scene detection.
    ///
    /// A perceptual hash (dHash) was the obvious choice here and is wrong for
    /// this content: downsampling a slide to 8x8 averages a headline change into
    /// nothing, so "Agenda" -> "Budget" reads as an unchanged screen. Screen
    /// content changes in *localized regions* rather than globally, so we keep a
    /// coarse luma grid and count how many cells moved.
    /// Per-sample decision trace, for tuning the thresholds against a real
    /// recording. Resolved once — reading the environment per sample would put a
    /// dictionary build on the capture callback.
    fileprivate static let debugEnabled =
        ProcessInfo.processInfo.environment["MEETEY_DEBUG_KEYFRAMES"] != nil

    fileprivate static let gridSide = 32
    /// Per-cell luma delta (0-255) that counts as "this cell changed".
    fileprivate static let cellDelta: Int = 24
    private var gridSide: Int { Self.gridSide }
    private var cellDelta: Int { Self.cellDelta }

    private func lumaGrid(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }

        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(gridSide) / image.extent.width,
            y: CGFloat(gridSide) / image.extent.height
        ))

        var bytes = [UInt8](repeating: 0, count: gridSide * gridSide * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ciContext.render(scaled,
                             toBitmap: base,
                             rowBytes: gridSide * 4,
                             bounds: CGRect(x: 0, y: 0, width: gridSide, height: gridSide),
                             format: .RGBA8,
                             colorSpace: colorSpace)
        }

        var grid = [UInt8](repeating: 0, count: gridSide * gridSide)
        for i in 0..<(gridSide * gridSide) {
            let p = i * 4
            let luma = 0.299 * Double(bytes[p]) + 0.587 * Double(bytes[p + 1]) + 0.114 * Double(bytes[p + 2])
            grid[i] = UInt8(max(0, min(255, luma)))
        }
        return grid
    }

    /// Folds this sample into the rolling volatility window. Runs on every sample,
    /// independent of the accept decision — it is measuring how often each region
    /// of the screen is in motion, not whether this particular frame is a keyframe.
    private func recordVolatility(of grid: [UInt8]) {
        guard volatilityMaskEnabled else { return }
        defer { previousSampleGrid = grid }
        guard let previous = previousSampleGrid, previous.count == grid.count else { return }

        var moved = [Bool](repeating: false, count: grid.count)
        for i in 0..<grid.count where abs(Int(previous[i]) - Int(grid[i])) > cellDelta {
            moved[i] = true
            volatilityCounts[i] += 1
        }

        volatilityRing.append(moved)
        if volatilityRing.count > volatilityWindow {
            let evicted = volatilityRing.removeFirst()
            for i in 0..<evicted.count where evicted[i] {
                volatilityCounts[i] -= 1
            }
        }

        // Until the window is full there isn't enough evidence to call anything
        // permanently volatile, and masking early could hide a real scene change.
        guard volatilityRing.count == volatilityWindow else { return }

        // Hysteresis. A cell on the boundary of a moving region averages partial
        // motion, so a single cutoff makes it flicker in and out of the mask and
        // leak a handful of cells through on every sample — which is enough to
        // clear the scene threshold on its own.
        let enter = Int((Double(volatilityWindow) * volatilityFraction).rounded(.up))
        let exit = Int((Double(volatilityWindow) * volatilityFraction / 2).rounded(.up))
        for i in 0..<volatileCells.count {
            volatileCells[i] = volatilityCounts[i] >= enter
                || (volatileCells[i] && volatilityCounts[i] >= exit)
        }

        // Dilate by one cell. The grid averages 40x22 pixels per cell, so the edge
        // of a speaker tile lands mid-cell and moves less than the cells inside it.
        // Growing the mask by its border is what makes it cover the whole region.
        let side = gridSide
        for y in 0..<side {
            for x in 0..<side {
                guard !volatileCells[y * side + x] else { maskedCells[y * side + x] = true; continue }
                var neighbouring = false
                for dy in -1...1 where !neighbouring {
                    for dx in -1...1 {
                        let ny = y + dy, nx = x + dx
                        guard ny >= 0, ny < side, nx >= 0, nx < side else { continue }
                        if volatileCells[ny * side + nx] { neighbouring = true; break }
                    }
                }
                maskedCells[y * side + x] = neighbouring
            }
        }
    }

    /// Counts cells that moved, ignoring those the volatility window has shown to
    /// be in constant motion. A slide headline that changes once is counted; the
    /// speaker tile next to it is not.
    private func changedCells(_ a: [UInt8], _ b: [UInt8], masked: Bool = true) -> Int {
        guard a.count == b.count else { return Int.max }
        let masking = masked && volatilityMaskEnabled && volatilityRing.count == volatilityWindow
        var count = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > cellDelta {
            if masking && maskedCells[i] { continue }
            count += 1
        }
        return count
    }

    /// Identity fingerprint for the manifest — useful when tuning the threshold
    /// against a real recording. Not a perceptual hash; equal fingerprints mean
    /// identical grids, nothing more.
    private func fingerprint(of grid: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in grid {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]

        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attributes as CFDictionary, &destination) == kCVReturnSuccess,
              let output = destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(output) else { return nil }

        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(output)
        if srcStride == dstStride {
            memcpy(dst, src, srcStride * height)
        } else {
            let row = min(srcStride, dstStride)
            for y in 0..<height {
                memcpy(dst + y * dstStride, src + y * srcStride, row)
            }
        }
        return output
    }

    /// Drains the work queue and writes the manifest. Blocks until done.
    func finalize() -> (count: Int, truncated: Bool) {
        // A meeting that ends mid-change leaves a candidate that never got the
        // chance to settle. It is the last thing that was on screen, so keep it —
        // stamped with when it was last seen, not with the time of the stop.
        if let grid = pendingGrid, let buffer = pendingBuffer, let seen = pendingLastSeen {
            clearPending()
            accept(pixelBuffer: buffer, grid: grid, at: seen)
        }

        var result = (count: 0, truncated: false)
        workQueue.sync {
            let sorted = frames.sorted { $0.offsetMs < $1.offsetMs }
            let formatter = ISO8601DateFormatter()
            let index = FrameIndex(
                sessionId: sessionId,
                startedAt: formatter.string(from: startedAt),
                frameCount: sorted.count,
                truncated: truncated,
                frames: sorted
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(index)
                try data.write(to: framesDir.appendingPathComponent("index.json"))
            } catch {
                fputs("meetey-capture: failed to write frame index: \(error.localizedDescription)\n", stderr)
            }
            result = (count: sorted.count, truncated: truncated)
        }
        return result
    }
}

// MARK: - Menu bar indicator

/// A menu bar item showing that a recording is running, with a way to stop it.
///
/// Two jobs, and the second is the more important one. It gives the user a way to
/// stop a recording without switching to Claude Code — but it is also the only
/// continuously visible sign that recording is happening at all. Everything else
/// about Meetey's consent story is a moment in time (a prompt, a command); this is
/// the part that stays true for the whole meeting.
///
/// Works from an unbundled binary: a status item needs `.accessory` activation
/// policy and a running main run loop, not an app bundle. (Notification *action
/// buttons* are the thing that would need bundling.)
@MainActor
final class RecordingIndicator: NSObject {
    /// What the recording is doing. Each case has to be distinguishable at a
    /// glance, without opening the menu and without relying on colour.
    enum State {
        case recording
        /// The call looks over and the recording will trim and stop unless the
        /// user says otherwise.
        case endingSoon(remaining: TimeInterval)
        case stopping
    }

    private let item: NSStatusItem
    private let startedAt: Date
    private let label: String
    private let capturingVideo: Bool
    private let onStop: () -> Void
    private let onKeepRecording: () -> Void
    /// Nil when the mic is not being recorded, which hides the item.
    private let onMicPaused: ((Bool) -> Void)?
    /// Nil when there is no assistant for this recording.
    private let onShowAssistant: (() -> Void)?
    private var micPaused = false
    private var timer: Timer?
    private var state: State = .recording

    private let titleItem = NSMenuItem()
    private let statusItem = NSMenuItem()
    private let keepItem = NSMenuItem()
    private let micItem = NSMenuItem()
    private let assistantItem = NSMenuItem()
    private let stopItem = NSMenuItem()

    /// Returns nil when there is no GUI session to draw into — an ssh shell, say.
    /// A missing indicator must never take the recording down with it.
    init?(label: String, startedAt: Date, capturingVideo: Bool,
          onStop: @escaping () -> Void, onKeepRecording: @escaping () -> Void,
          onMicPaused: ((Bool) -> Void)? = nil, onShowAssistant: (() -> Void)? = nil) {
        guard !NSScreen.screens.isEmpty else { return nil }

        self.startedAt = startedAt
        self.label = Self.truncateMiddle(label.isEmpty ? "Meeting" : label, to: 40)
        self.capturingVideo = capturingVideo
        self.onStop = onStop
        self.onKeepRecording = onKeepRecording
        self.onMicPaused = onMicPaused
        self.onShowAssistant = onShowAssistant
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // A stable name lets macOS and menu bar managers tell this item apart
        // from the watcher's — both belong to com.adamjhcox.meetey — and remember
        // where the user put it. Named items also persist their visibility, so
        // it is asserted rather than inherited from a previous run.
        item.autosaveName = "com.adamjhcox.meetey.recording"
        item.isVisible = true

        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        titleItem.title = self.label
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        // Only shown while a stop is pending. Surfacing that the recording is
        // about to end obliges us to let the user say no — and that veto is what
        // makes the automatic stop something done *with* them rather than *to*
        // them.
        keepItem.title = "Keep Recording"
        keepItem.action = #selector(keepClicked)
        keepItem.target = self
        keepItem.isHidden = true
        menu.addItem(keepItem)

        // Being muted in the meeting app does not mute this: the mic is recorded
        // directly, so a side conversation while "muted" would still be captured.
        // This is the control for that, one click from the indicator.
        micItem.action = #selector(micClicked)
        micItem.target = self
        micItem.isHidden = onMicPaused == nil
        menu.addItem(micItem)

        assistantItem.title = "Show Assistant (\(HotKey.label))"
        assistantItem.action = #selector(assistantClicked)
        assistantItem.target = self
        assistantItem.isHidden = onShowAssistant == nil
        menu.addItem(assistantItem)

        stopItem.title = "Stop Recording"
        stopItem.action = #selector(stopClicked)
        stopItem.target = self
        menu.addItem(stopItem)
        item.menu = menu

        render()
        // .common so the timer keeps running while the menu is open, which is
        // exactly when someone is reading it.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setState(_ newState: State) {
        state = newState
        render()
    }

    // MARK: Rendering

    private func render() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let mode: String
        switch (capturingVideo, onMicPaused != nil) {
        case (true, true):   mode = micPaused ? "Audio + screen, mic paused" : "Audio, mic + screen"
        case (false, true):  mode = micPaused ? "Audio, mic paused" : "Audio + mic"
        case (true, false):  mode = "Audio + screen"
        case (false, false): mode = "Audio only"
        }
        micItem.title = micPaused ? "Resume My Microphone" : "Pause My Microphone"

        switch state {
        case .recording:
            // Filled and red. A template image renders monochrome and reads as
            // just another menu bar icon, which is the one thing an indicator
            // that exists to be noticed must not do.
            item.button?.image = Self.symbol(capturingVideo ? "rectangle.inset.filled.badge.record"
                                                            : "record.circle.fill",
                                             color: .systemRed)
            // Paused is shown on the bar itself, not only in the menu: forgetting
            // to resume would silently drop your side of the rest of the call.
            item.button?.title = " \(Self.clock(elapsed))\(micPaused ? " · mic off" : "")"
            statusItem.title = "\(mode) · \(Self.clock(elapsed))"
            keepItem.isHidden = true
            stopItem.isEnabled = true
            setAccessibility("Meetey recording, \(mode.lowercased()), \(Self.spoken(elapsed))")

        case .endingSoon(let remaining):
            // Hollow, not merely dimmed: the shape carries the state so it still
            // reads under menu bar tinting and without colour vision.
            item.button?.image = Self.symbol("record.circle", color: .secondaryLabelColor)
            item.button?.title = " ending soon"
            statusItem.title = "Call may have ended · \(Self.clock(Int(remaining))) left"
            keepItem.isHidden = false
            stopItem.isEnabled = true
            setAccessibility("Meetey may stop recording in \(Self.spoken(Int(remaining))). \(mode).")

        case .stopping:
            item.button?.image = Self.symbol("record.circle", color: .tertiaryLabelColor)
            item.button?.title = " …"
            statusItem.title = "Stopping…"
            keepItem.isHidden = true
            stopItem.isEnabled = false
            setAccessibility("Meetey is stopping the recording")
        }
    }

    private func setAccessibility(_ text: String) {
        item.button?.setAccessibilityLabel(text)
        // Without this VoiceOver reads the elapsed-time title as the control's
        // name, which says nothing about what is happening.
        item.button?.setAccessibilityTitle(text)
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return base.withSymbolConfiguration(.init(paletteColors: [color]))
    }

    nonisolated static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Durations read aloud as digits are unintelligible; VoiceOver gets words.
    nonisolated static func spoken(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 1 { return "less than a minute" }
        if m == 1 { return "1 minute" }
        if m < 60 { return "\(m) minutes" }
        let h = m / 60, rem = m % 60
        return rem == 0 ? "\(h) hour\(h == 1 ? "" : "s")"
                        : "\(h) hour\(h == 1 ? "" : "s") \(rem) minutes"
    }

    /// Window titles run long ("Weekly Sync — Google Meet — Google Chrome"). The
    /// end carries as much meaning as the start, so drop the middle.
    nonisolated static func truncateMiddle(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let side = (limit - 1) / 2
        return "\(text.prefix(side))…\(text.suffix(side))"
    }

    @objc private func stopClicked() {
        setState(.stopping)
        onStop()
    }

    @objc private func keepClicked() {
        setState(.recording)
        onKeepRecording()
    }

    @objc private func assistantClicked() {
        onShowAssistant?()
    }

    @objc private func micClicked() {
        micPaused.toggle()
        onMicPaused?(micPaused)
        render()
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}

/// Posts a user notification without an app bundle.
///
/// `UNUserNotificationCenter` needs bundling; `display notification` does not,
/// which is the same reason the watch agent drives its prompt through osascript.
func postNotification(title: String, subtitle: String, body: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title)) subtitle \(quoted(subtitle))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
    process.waitUntilExit()
}

// MARK: - Watcher indicator

/// The menu bar presence of the watch agent, for as long as it is running.
///
/// Deliberately the quiet counterpart to `RecordingIndicator`: a monochrome
/// dotted outline against that one's solid red. Watching and recording are
/// different things to be told, and the difference has to be legible at a glance
/// — if this competed with the recording dot it would weaken the only
/// continuously-visible signal that a recording is happening.
///
/// **It is still while idle.** Motion happens at the seams — settling in when the
/// agent starts, standing aside when a recording begins, returning when it ends.
/// A menu bar icon that moves for hours is the animation-fatigue failure; there
/// is nothing to communicate between state changes, so nothing moves.
@MainActor
final class WatcherIndicator: NSObject {
    private let item: NSStatusItem
    private let plistPath: String?
    private let statusLine = NSMenuItem()
    private var recordingActive = false
    private var poll: Timer?

    /// Entrance timing. Exits run at 75% — leaving should be quicker than arriving.
    private static let enterDuration: TimeInterval = 0.5
    private static let exitDuration: TimeInterval = 0.375
    /// Natural deceleration; no bounce, which would draw attention to the motion
    /// rather than to what changed.
    private static let easeOutQuart = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)

    /// macOS's own reduce-motion switch. Not optional to honour: someone who has
    /// asked the system to stop animating things has asked us too.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init?(stateFile: String, plistPath: String?) {
        guard !NSScreen.screens.isEmpty else { return nil }
        self.plistPath = plistPath
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // See RecordingIndicator. Asserting visibility matters more here: this
        // item hides itself while a recording runs, and a named item would
        // otherwise come back hidden if the process ended mid-recording.
        item.autosaveName = "com.adamjhcox.meetey.watching"
        item.isVisible = true

        item.button?.image = NSImage(systemSymbolName: "circle.dotted",
                                     accessibilityDescription: "Meetey is watching for meetings")
        item.button?.setAccessibilityLabel("Meetey is watching for meetings")

        let menu = NSMenu()
        statusLine.title = "Watching for meetings"
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop Watching", action: #selector(stopWatching), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.menu = menu

        settleIn()
        // Cheap: reading one small file. The alternative, watching the file, adds
        // failure modes for a two-second delay nobody perceives.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.exitIfOrphaned()
                self?.syncWithRecordingState(stateFile: stateFile)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// The indicator says "the watcher is running", so it must not outlive it.
    ///
    /// A clean stop signals us, but a crash or SIGKILL does not — and launchd
    /// then restarts the agent, which starts a second indicator. Two icons
    /// claiming the same thing, one of them lying. Reparenting to pid 1 is the
    /// signal that the parent is gone.
    private func exitIfOrphaned() {
        guard getppid() == 1 else { return }
        NSStatusBar.system.removeStatusItem(item)
        exit(0)
    }

    /// Arriving: fade up rather than appearing abruptly in a bar the user is
    /// probably already looking at.
    private func settleIn() {
        guard let button = item.button else { return }
        guard !Self.reduceMotion else { button.alphaValue = 1; return }
        button.alphaValue = 0
        animate(button, to: 1, duration: Self.enterDuration)
    }

    private func animate(_ button: NSStatusBarButton, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Self.easeOutQuart
            button.animator().alphaValue = alpha
        }
    }

    /// A recording has its own, louder indicator. Two dots in the menu bar saying
    /// overlapping things is worse than one saying the important thing, so this
    /// steps aside for the duration and comes back afterwards.
    private func syncWithRecordingState(stateFile: String) {
        let active = FileManager.default.fileExists(atPath: stateFile)
        guard active != recordingActive else { return }
        recordingActive = active
        statusLine.title = active ? "Recording — see the red indicator" : "Watching for meetings"

        guard let button = item.button else { return }

        // Fading to zero alpha hides the icon but keeps its slot in the menu bar,
        // so the recording indicator arrives into a bar that is one item fuller
        // than it looks. On a crowded bar macOS silently drops what does not fit,
        // and the newest item — the red dot — is what gets dropped. Only
        // `isVisible` actually gives the space back.
        guard !Self.reduceMotion else {
            button.alphaValue = active ? 0 : 1
            item.isVisible = !active
            return
        }

        if active {
            // Fade out, then release the slot, so the red dot has room.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.exitDuration
                context.timingFunction = Self.easeOutQuart
                button.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.recordingActive else { return }
                    self.item.isVisible = false
                }
            })
        } else {
            // Take a slot again before fading back in, or there is nothing to fade.
            item.isVisible = true
            button.alphaValue = 0
            animate(button, to: 1, duration: Self.enterDuration)
        }
    }

    @objc private func stopWatching() {
        // Same two steps as `disableWatch`: unload the agent, then remove the
        // plist so it does not return at next login.
        // The label is the plist's name, so it can't drift from the one the
        // agent was installed under.
        let uid = String(getuid())
        let label = plistPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? "com.adamjhcox.meetey.watch"
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        if let plistPath { try? FileManager.default.removeItem(atPath: plistPath) }
        NSStatusBar.system.removeStatusItem(item)
        exit(0)
    }

    private func run(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Call-end detection

/// Whether any process currently holds the default input device.
///
/// This is a device *property*, not audio content, so it needs no microphone
/// permission — verified against a build with none granted. Meeting apps take the
/// input device when you join a call and release it when you leave; muting
/// yourself is a software flag and does not release it, which is what makes this
/// a usable proxy for "a call is in progress".
enum Microphone {
    static func inUse() -> Bool? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &deviceAddress, 0, nil, &size, &device) == noErr else { return nil }

        var running = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &runningAddress, 0, nil,
                                         &runningSize, &running) == noErr else { return nil }
        return running != 0
    }

    /// Processes taking audio input right now: their pids and bundle IDs, or nil
    /// when that can't be read (macOS 13, or a Core Audio error). Like the
    /// device property above, this is process metadata, not audio, so it needs
    /// no microphone permission.
    static func processesUsingInput() -> (pids: Set<pid_t>, bundles: Set<String>)? {
        guard #available(macOS 14.0, *) else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &objects) == noErr else { return nil }

        var pids = Set<pid_t>(), bundles = Set<String>()
        for object in objects {
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }

            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr { pids.insert(pid) }

            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
               let id = bundle?.takeRetainedValue() as String?, !id.isEmpty {
                bundles.insert(id)
            }
        }
        return (pids, bundles)
    }

    /// Whether the app `bundleID` (process `pid`) is taking audio input — itself,
    /// a helper sharing its bundle prefix, or any process it launched. Meeting
    /// apps built on web views often do their audio in a child process, which
    /// is why the app's own pid is not enough. Nil when unknowable.
    static func appUsesInput(bundleID: String, pid: pid_t,
                             using inputs: (pids: Set<pid_t>, bundles: Set<String>)?) -> Bool? {
        guard let inputs else { return nil }
        if inputs.pids.contains(pid) { return true }
        if inputs.bundles.contains(where: { $0 == bundleID || $0.hasPrefix(bundleID + ".") }) { return true }
        return inputs.pids.contains { Responsibility.responsiblePid(for: $0) == pid }
    }

    /// Whether any process *other than* `excluded` is taking audio input.
    ///
    /// Needed once Meetey records the mic itself: the device is then always
    /// running, so `inUse()` would never see the call end. Asking each process
    /// instead, and ignoring our own, keeps the original meaning — the meeting
    /// app still holds the mic. Process objects need macOS 14.
    @available(macOS 14.0, *)
    static func inUse(excluding excluded: Set<pid_t>) -> Bool? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &objects) == noErr else { return nil }

        for object in objects {
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  !excluded.contains(pid) else { continue }

            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil,
                                             &runningSize, &running) == noErr else { continue }
            if running != 0 { return true }
        }
        return false
    }
}

/// Decides that a *call* has ended, as opposed to the app closing.
///
/// The naive version of this — stop as soon as the mic is released — truncates a
/// live meeting whenever the signal is wrong, and the user does not find out
/// until afterwards. So this never stops anything early. It notes where the
/// recording stood when the mic went quiet and keeps recording; if the mic comes
/// back, the note is thrown away and nothing was lost. Only once the signal has
/// held for the full grace period does it commit, and the recording is then cut
/// back to the noted point so the waiting never reaches the transcript.
///
/// Because waiting costs nothing, the grace can be long enough to be sure.
struct MeetingEndMonitor {
    /// The wait when the caller doesn't say. The caller picks it per poll by how
    /// good its evidence is (see the call-end poll in `record`).
    let grace: TimeInterval
    private var activeGrace: TimeInterval
    /// Set once the mic has been seen in use. Until then this stays silent: a
    /// recording where no app ever took the mic is not a call whose end we can
    /// detect, and firing on that would kill legitimate recordings that simply
    /// never involved a microphone.
    private var armed = false
    private var candidate: (since: Date, mark: UInt32)?

    init(grace: TimeInterval) {
        self.grace = grace
        self.activeGrace = grace
    }

    var isArmed: Bool { armed }
    var hasCandidate: Bool { candidate != nil }

    /// How long until this candidate would commit, or nil when nothing is pending.
    /// Drives the "ending soon" readout in the menu bar.
    func remaining(at now: Date) -> TimeInterval? {
        guard let candidate else { return nil }
        return max(0, activeGrace - now.timeIntervalSince(candidate.since))
    }

    /// Drops the pending candidate and restarts the clock, without disarming.
    ///
    /// Replacing the whole monitor instead would clear `armed` too — and since
    /// `armed` only returns when the mic is *in use*, while a released mic is the
    /// precondition for ever getting here, that silently disables call-end
    /// detection for the rest of the recording after a single veto.
    mutating func resetCandidate() {
        candidate = nil
    }

    /// `mark` is how far the recording had got at this poll — the point to cut
    /// back to if the call really did end here. Returns that point once the call
    /// is confirmed over, nil otherwise.
    /// `wait` is how long the mic must stay released before committing, chosen
    /// by the caller from how strong its evidence is; nil uses `grace`.
    mutating func update(micInUse: Bool, mark: UInt32, at now: Date, wait: TimeInterval? = nil) -> UInt32? {
        if micInUse {
            armed = true
            candidate = nil
            return nil
        }
        guard armed else { return nil }

        let current = candidate ?? (since: now, mark: mark)
        candidate = current
        activeGrace = wait ?? grace
        guard now.timeIntervalSince(current.since) >= activeGrace else { return nil }
        return current.mark
    }
}

// MARK: - Meeting window

/// Whether the meeting's window is still open.
///
/// CoreGraphics window *metadata* from the window server — not ScreenCaptureKit,
/// so it opens no capture connection and is safe while recording (see "Nothing
/// queries the capture subsystem" in CLAUDE.md). The window counts as open if
/// its number still exists, or another window of the app carries the meeting's
/// title, since Teams can replace the window it started in. Titles need Screen
/// Recording permission, which the capture process has. Nil when unknowable.
enum MeetingWindow {
    static func isOpen(windowID: UInt32?, title: String, pid: pid_t) -> Bool? {
        guard windowID != nil || !title.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list where (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid {
            if let windowID, (window[kCGWindowNumber as String] as? Int).map(UInt32.init) == windowID { return true }
            if !title.isEmpty, (window[kCGWindowName as String] as? String) == title { return true }
        }
        return false
    }
}

// MARK: - Auto-stop

/// Decides when a recording should end without being told to.
///
/// Deliberately conservative: it ends a recording only on signals that cannot
/// mean anything else — the app is gone, or the window that was explicitly chosen
/// for capture is gone. It does not try to infer that a *call* ended while the app
/// keeps running, because the cost of being wrong is asymmetric. Stopping late
/// wastes disk; stopping early loses the rest of a meeting that cannot be
/// re-recorded.
///
/// Pure state machine, so `--selftest` can exercise the grace-period behaviour
/// without a live meeting.
struct AutoStopMonitor {
    let grace: TimeInterval
    private var goneSince: Date? = nil

    init(grace: TimeInterval) { self.grace = grace }

    /// Returns a human-readable reason once the condition has held continuously
    /// for the grace period, nil until then.
    ///
    /// Deliberately does **not** consider whether the captured window still
    /// exists. Audio is app-scoped and survives a window closing, so a closed
    /// window costs screen content and nothing else — ending the recording for it
    /// destroys a meeting that is still going. Google Meet recreates its window
    /// on joining a call, which made that a loop: capture starts, the window is
    /// replaced, auto-stop kills the recording, the watcher offers the meeting
    /// again, repeat every minute.
    mutating func update(appRunning: Bool, at now: Date) -> String? {
        let reason: String? = appRunning ? nil : "the app is no longer running"

        // Recovered. Windows are legitimately destroyed and recreated — Zoom does
        // it entering full screen — so a blip must not end the meeting.
        guard let reason else {
            goneSince = nil
            return nil
        }

        let since = goneSince ?? now
        goneSince = since
        guard now.timeIntervalSince(since) >= grace else { return nil }
        return reason
    }
}

// MARK: - Stream delegate

// SCKit is configured to output Float32 at 16 kHz mono — convert directly to Int16, no resampling needed.
final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: WAVWriter
    private let keyframes: KeyframeWriter?

    weak var captureStream: SCStream?
    /// Called when the stream stops, so the recording is finalised rather than
    /// left running against a dead one.
    var onStreamLost: (() -> Void)?
    /// The call audio's live transcriber, fed the same samples as the WAV.
    var live: AnyObject?

    init(writer: WAVWriter, keyframes: KeyframeWriter?) {
        self.writer = writer
        self.keyframes = keyframes
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:  handleAudio(sampleBuffer)
        case .screen: handleScreen(sampleBuffer)
        // Meetey never requests microphone capture — it records app output only.
        case .microphone: return
        @unknown default: return
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        var audioBufferList = AudioBufferList()
        var blockBufferRef: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBufferRef
        )

        let ablPtr = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        guard let audioBuffer = ablPtr.first, let dataPtr = audioBuffer.mData else { return }

        let floatCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float32>.size
        let floats = UnsafeBufferPointer(
            start: dataPtr.bindMemory(to: Float32.self, capacity: floatCount),
            count: floatCount
        )
        let samples = floats.map { Int16(max(-32768.0, min(32767.0, $0 * 32767.0))) }
        writer.append(samples: samples)
        liveAppend(live, samples)
    }

    private func handleScreen(_ sampleBuffer: CMSampleBuffer) {
        guard let keyframes else { return }

        // ScreenCaptureKit delivers idle/blank/suspended frames alongside real
        // ones. Hashing those produces spurious keyframes on an unchanged screen.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        keyframes.consider(pixelBuffer: pixelBuffer, at: Date())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Logging this and carrying on is how a 32-minute meeting became six
        // seconds of audio: the stream was dead within seconds, nothing was
        // written after, and nothing said so until the file was opened.
        fputs("meetey-capture: capture stopped (\(error.localizedDescription)) — "
            + "saving what was recorded\n", stderr)
        onStreamLost?()
    }
}

// MARK: - Self test

/// Drives the real KeyframeWriter with synthetic frames so the dedup, encode,
/// OCR, and manifest paths can be verified without Screen Recording permission
/// or a live meeting. Exits non-zero on failure.
func selfTest() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("meetey-selftest-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: root) }
    var failures: [String] = []

    /// Synthesizes a slide. `textShade` fades the headline toward the background
    /// (0 = solid black, 1 = invisible) so a cross-fade can be scripted; `tile`
    /// paints a corner rectangle standing in for a speaker thumbnail; `scramble`
    /// repaints the whole frame so every grid cell moves at once.
    func makeFrame(text: String, background: CGFloat, textShade: CGFloat = 0,
                   tile: CGFloat? = nil, scramble: Int? = nil) -> CVPixelBuffer? {
        let width = 1280, height = 720
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        ctx.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if let seed = scramble {
            // Deterministic LCG — every 64x64 block gets its own shade, so the
            // whole grid moves between any two seeds.
            var state = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1)
            for y in stride(from: 0, to: height, by: 64) {
                for x in stride(from: 0, to: width, by: 64) {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let shade = CGFloat((state >> 33) % 256) / 255.0
                    ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: 64, height: 64))
                }
            }
            return pixelBuffer
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil),
            .foregroundColor: CGColor(red: textShade, green: textShade, blue: textShade, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: 80, y: 320)
        CTLineDraw(line, ctx)

        if let tile {
            ctx.setFillColor(CGColor(red: tile, green: tile, blue: tile, alpha: 1))
            ctx.fill(CGRect(x: 940, y: 40, width: 300, height: 200))
        }
        return pixelBuffer
    }

    /// Drives a scripted sequence through a real KeyframeWriter and returns the
    /// manifest it produced.
    func drive(_ name: String, count: Int, sceneThreshold: Int = 12, maxUnsettled: TimeInterval = 60,
               mask: Bool = true, ocr: Bool = false,
               sample: (Int) -> (CVPixelBuffer?, TimeInterval)) throws -> FrameIndex {
        let dir = root.appendingPathComponent(name)
        let writer = try KeyframeWriter(framesDir: dir, sessionId: name, sceneThreshold: sceneThreshold,
                                        maxFrames: 200, ocrEnabled: ocr,
                                        startedAt: Date(timeIntervalSince1970: 0),
                                        maxUnsettled: maxUnsettled, volatilityMaskEnabled: mask)
        for i in 0..<count {
            let (frame, at) = sample(i)
            guard let frame else {
                fputs("selftest: failed to synthesize frame \(i) of \(name)\n", stderr); exit(1)
            }
            writer.consider(pixelBuffer: frame, at: Date(timeIntervalSince1970: at))
        }
        _ = writer.finalize()
        let data = try Data(contentsOf: dir.appendingPathComponent("index.json"))
        return try JSONDecoder().decode(FrameIndex.self, from: data)
    }

    // --- Baseline: duplicate suppression, OCR, manifest shape. -----------------
    // The original regression guard. Spaced 5s apart so the 2s debounce never
    // masks a genuine scene change.
    let basicScript: [(String, CGFloat)] = [
        ("AGENDA", 1.0),   // 1st keyframe — first frame is always kept
        ("AGENDA", 1.0),   // duplicate — suppressed
        ("AGENDA", 1.0),   // duplicate — suppressed
        ("BUDGET", 1.0),   // change begins; held until it settles
        ("BUDGET", 1.0),   // 2nd keyframe — settled
        ("BUDGET", 0.2),   // change begins; flushed by finalize as 3rd keyframe
    ]
    let basic = try drive("basic", count: basicScript.count, ocr: true) { i in
        (makeFrame(text: basicScript[i].0, background: basicScript[i].1), Double(i) * 5)
    }
    if basic.frames.count != 3 { failures.append("basic: expected 3 keyframes, got \(basic.frames.count)") }
    if basic.truncated { failures.append("basic: unexpectedly truncated") }

    let recognized = basic.frames.compactMap { $0.ocrText?.uppercased() }
    if !recognized.contains(where: { $0.contains("AGENDA") }) { failures.append("basic: OCR did not recover 'AGENDA'") }
    if !recognized.contains(where: { $0.contains("BUDGET") }) { failures.append("basic: OCR did not recover 'BUDGET'") }

    for frame in basic.frames {
        let path = root.appendingPathComponent("basic").appendingPathComponent(frame.file)
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int ?? 0
        if size < 1024 { failures.append("basic: \(frame.file) is \(size) bytes — encode likely failed") }
    }
    if Set(basic.frames.map(\.fingerprint)).count != basic.frames.count {
        failures.append("basic: duplicate fingerprints among accepted keyframes")
    }
    if basic.frames.map(\.offsetMs) != basic.frames.map(\.offsetMs).sorted() {
        failures.append("basic: frames not ordered by offset")
    }
    for frame in basic.frames {
        print("  basic/\(frame.file)  offset=\(frame.offsetMs)ms  ocr=\(frame.ocrText?.replacingOccurrences(of: "\n", with: " ") ?? "-")")
    }

    // --- Settling: a cross-fade must collapse to one keyframe. -----------------
    // Under the old accept-on-change rule this scripted fade produced a file per
    // intermediate. Only the settled frame is worth keeping, and it is the only
    // one that OCRs cleanly.
    // Sampled at 1s, the rate the binary actually runs at, so the transition
    // occupies the one or two samples a real slide change would.
    let fadeScript: [(String, CGFloat)] = [
        ("AGENDA", 0.0),   // 1st keyframe
        ("AGENDA", 0.0),
        ("AGENDA", 0.0),
        ("AGENDA", 0.5),   // caught mid-fade — must not be persisted
        ("BUDGET", 0.25),  // still mid-fade
        ("BUDGET", 0.0),   // arrived, not yet known to have settled
        ("BUDGET", 0.0),   // 2nd keyframe — settled
        ("BUDGET", 0.0),
        ("BUDGET", 0.0),
    ]
    let fade = try drive("fade", count: fadeScript.count, ocr: true) { i in
        (makeFrame(text: fadeScript[i].0, background: 1.0, textShade: fadeScript[i].1), Double(i))
    }
    if fade.frames.count != 2 {
        failures.append("fade: expected 2 keyframes (start + settled), got \(fade.frames.count)")
    }
    if let last = fade.frames.last, !(last.ocrText?.uppercased().contains("BUDGET") ?? false) {
        failures.append("fade: final keyframe is mid-transition, not the settled slide")
    }
    print("  fade: \(fade.frames.count) keyframe(s) from \(fadeScript.count) samples")

    // --- Volatility mask: a moving tile must not emit a keyframe per sample. ---
    // This is the standard slide-plus-speaker-tile layout, and the case that used
    // to exhaust the whole frame budget in the first few minutes of a call.
    let tileCount = 40
    let tiled = try drive("tile", count: tileCount) { i in
        let text = i < tileCount / 2 ? "AGENDA" : "BUDGET"
        // Tile shade changes every sample — a face moving in a thumbnail.
        let tile = CGFloat(i % 7) / 7.0
        return (makeFrame(text: text, background: 1.0, tile: tile), Double(i))
    }
    if tiled.frames.count != 2 {
        failures.append("tile: expected 2 keyframes (one per slide), got \(tiled.frames.count) from \(tileCount) samples")
    }
    print("  tile: \(tiled.frames.count) keyframe(s) from \(tileCount) samples with a tile moving every sample")

    // --- The mask must not suppress genuine slide advances. -------------------
    // Distinct headlines, not "SLIDE 1"/"SLIDE 2" — a single changed digit moves
    // about four cells, which is legitimately below the scene threshold and would
    // be testing the fixture rather than the mask.
    let cadenceSlides = ["AGENDA", "BUDGET", "ROADMAP", "HIRING"]
    let cadenceCount = 60
    let cadence = try drive("cadence", count: cadenceCount) { i in
        (makeFrame(text: cadenceSlides[i / 15], background: 1.0), Double(i))
    }
    if cadence.frames.count != 4 {
        failures.append("cadence: expected 4 keyframes (one per slide), got \(cadence.frames.count)")
    }
    print("  cadence: \(cadence.frames.count) keyframe(s) from \(cadenceCount) samples, slide changing every 15")

    // --- Revisiting a slide must not write a second copy of it. ---------------
    let revisitScript = ["AGENDA", "AGENDA", "AGENDA", "BUDGET", "BUDGET", "BUDGET",
                         "AGENDA", "AGENDA", "AGENDA"]
    let revisit = try drive("revisit", count: revisitScript.count) { i in
        (makeFrame(text: revisitScript[i], background: 1.0), Double(i))
    }
    if revisit.frames.count != 2 {
        failures.append("revisit: expected 2 keyframes for an A-B-A sequence, got \(revisit.frames.count)")
    }
    let revisited = revisit.frames.first?.revisitsMs ?? []
    if revisited.isEmpty {
        failures.append("revisit: returning to the first slide was not recorded as a revisit")
    }
    print("  revisit: \(revisit.frames.count) keyframe(s) from A-B-A, first frame revisited at \(revisited)")

    // --- A screen that never settles must still produce something. ------------
    // Everything is volatile here, so the mask alone would record nothing at all
    // for the entire meeting. The maxUnsettled valve is what prevents that.
    let videoCount = 130
    let video = try drive("video", count: videoCount, maxUnsettled: 60) { i in
        (makeFrame(text: "", background: 1.0, scramble: i), Double(i))
    }
    if video.frames.count < 2 {
        failures.append("video: a continuously-changing screen produced \(video.frames.count) keyframe(s) — the maxUnsettled valve did not fire")
    }
    if video.frames.count > 6 {
        failures.append("video: \(video.frames.count) keyframes from a video-like screen — expected roughly one per maxUnsettled interval")
    }
    print("  video: \(video.frames.count) keyframe(s) from \(videoCount) samples of constant motion")

    // --- Auto-stop: conservative, and never on a blip. ------------------------
    let t0 = Date(timeIntervalSince1970: 0)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    var healthy = AutoStopMonitor(grace: 30)
    for s in stride(from: 0.0, through: 3600, by: 5) {
        if healthy.update(appRunning: true, at: at(s)) != nil {
            failures.append("autostop: ended a healthy recording at \(Int(s))s")
            break
        }
    }

    var quit = AutoStopMonitor(grace: 30)
    if quit.update(appRunning: false, at: at(0)) != nil {
        failures.append("autostop: fired immediately instead of waiting out the grace period")
    }
    if quit.update(appRunning: false, at: at(25)) != nil {
        failures.append("autostop: fired at 25s with a 30s grace period")
    }
    if quit.update(appRunning: false, at: at(30)) == nil {
        failures.append("autostop: did not fire once the grace period elapsed")
    }

    // An app that vanishes briefly and comes back — a relaunch, a hiccup in the
    // lookup — must reset the clock rather than accumulate toward a stop.
    var blip = AutoStopMonitor(grace: 30)
    _ = blip.update(appRunning: false, at: at(0))
    _ = blip.update(appRunning: false, at: at(20))
    if blip.update(appRunning: true, at: at(25)) != nil {
        failures.append("autostop: fired on an app that came back")
    }
    if blip.update(appRunning: false, at: at(40)) != nil {
        failures.append("autostop: did not reset the grace clock after the app returned")
    }
    if blip.update(appRunning: false, at: at(75)) == nil {
        failures.append("autostop: did not fire after the app was gone for a full grace period")
    }
    print("  autostop: only the app quitting ends a recording; a closed window never does")

    // --- Call end: never cut a live meeting, never keep the silence. ----------
    // A recording where no app ever took the microphone is not a call, and must
    // never be ended by this. Otherwise every non-call recording dies.
    var unarmed = MeetingEndMonitor(grace: 600)
    for s in stride(from: 0.0, through: 3600, by: 5) {
        if unarmed.update(micInUse: false, mark: 1000, at: at(s)) != nil {
            failures.append("callend: ended a recording where the mic was never in use")
            break
        }
    }

    // The ordinary case: mic goes quiet, stays quiet, recording cuts back to the
    // moment it went quiet — not to the moment we became confident.
    var ended = MeetingEndMonitor(grace: 600)
    _ = ended.update(micInUse: true, mark: 100, at: at(0))
    if ended.update(micInUse: false, mark: 320_000, at: at(100)) != nil {
        failures.append("callend: committed immediately instead of waiting out the grace period")
    }
    if ended.update(micInUse: false, mark: 640_000, at: at(400)) != nil {
        failures.append("callend: committed before the grace period elapsed")
    }
    let cut = ended.update(micInUse: false, mark: 999_999, at: at(700))
    if cut != 320_000 {
        failures.append("callend: cut back to \(cut.map(String.init) ?? "nil"), expected the mark from when the mic went quiet (320000)")
    }

    // The app let go of the mic *and* the meeting window closed: a minute, not
    // ten, so the next call isn't joined on — still cut back to the release.
    // A short wait, chosen by the caller when its evidence is strong, still
    // cuts back to the moment the mic was released.
    var quick = MeetingEndMonitor(grace: 600)
    _ = quick.update(micInUse: true, mark: 100, at: at(0))
    _ = quick.update(micInUse: false, mark: 320_000, at: at(100), wait: 15)
    if quick.update(micInUse: false, mark: 400_000, at: at(110), wait: 15) != nil {
        failures.append("callend: committed before a 15s wait")
    }
    if quick.update(micInUse: false, mark: 480_000, at: at(116), wait: 15) != 320_000 {
        failures.append("callend: a 15s wait did not commit, cut back to the release point")
    }
    if quick.remaining(at: at(116)) != 0 {
        failures.append("callend: 'ending soon' countdown doesn't follow the chosen wait")
    }

    // The dangerous case. The mic drops briefly while the meeting is still
    // going; nothing may be lost, and the clock must start over afterwards.
    var blipped = MeetingEndMonitor(grace: 600)
    _ = blipped.update(micInUse: true, mark: 0, at: at(0))
    _ = blipped.update(micInUse: false, mark: 100_000, at: at(60))
    _ = blipped.update(micInUse: false, mark: 200_000, at: at(120))
    if blipped.update(micInUse: true, mark: 300_000, at: at(180)) != nil {
        failures.append("callend: ended a meeting that was still going")
    }
    if blipped.update(micInUse: false, mark: 400_000, at: at(240)) != nil {
        failures.append("callend: did not discard the candidate when the mic came back")
    }
    // 240 + 600 = 840. The new candidate, not the abandoned one at 60s.
    if blipped.update(micInUse: false, mark: 900_000, at: at(830)) != nil {
        failures.append("callend: reused the abandoned candidate's clock")
    }
    let second = blipped.update(micInUse: false, mark: 950_000, at: at(841))
    if second != 400_000 {
        failures.append("callend: cut back to \(second.map(String.init) ?? "nil"), expected the second candidate (400000)")
    }
    print("  callend: unarmed stays silent, grace enforced, blip recovers, cut lands where the mic went quiet")

    // --- Trimming actually truncates the WAV and fixes its header. ------------
    let wavPath = root.appendingPathComponent("trim.wav").path
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let trimWriter = try WAVWriter(path: wavPath)
    // 10s of audio at 16 kHz mono 16-bit.
    trimWriter.append(samples: [Int16](repeating: 0, count: 16000 * 10))
    let keptBytes = trimWriter.finalize(trimmingToDataBytes: 16000 * 2 * 4 + 1) // 4s, odd byte
    let onDisk = (try? FileManager.default.attributesOfItem(atPath: wavPath))?[.size] as? Int ?? 0
    let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: wavPath))
    header.seek(toFileOffset: 40)
    let declared = header.readData(ofLength: 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    try? header.close()

    if keptBytes != 16000 * 2 * 4 {
        failures.append("trim: kept \(keptBytes) bytes, expected 128000 (odd byte should round down to a whole sample)")
    }
    if onDisk != Int(WAVWriter.headerBytes) + 128_000 {
        failures.append("trim: file is \(onDisk) bytes on disk, expected \(Int(WAVWriter.headerBytes) + 128_000)")
    }
    if declared != 128_000 {
        failures.append("trim: header declares \(declared) data bytes, expected 128000 — a reader would run past the end")
    }
    print("  trim: 10s recording cut to 4s, file truncated and header rewritten to match")

    // --- Audible-audio veto: silence and speech must be told apart. ----------
    let vetoPath = root.appendingPathComponent("veto.wav").path
    let vetoWriter = try WAVWriter(path: vetoPath)
    vetoWriter.append(samples: [Int16](repeating: 0, count: 16000))          // 1s silence
    let afterSilence = vetoWriter.lastAudibleOffset
    vetoWriter.append(samples: (0..<16000).map { _ in Int16.random(in: 4000...8000) }) // 1s speech
    let afterSpeech = vetoWriter.lastAudibleOffset
    vetoWriter.append(samples: [Int16](repeating: 0, count: 16000))          // 1s silence
    let afterTrailing = vetoWriter.lastAudibleOffset
    vetoWriter.finalize()

    if afterSilence != 0 {
        failures.append("veto: silence registered as audible (offset \(afterSilence)) — would refuse to ever trim")
    }
    if afterSpeech != 16000 * 2 * 2 {
        failures.append("veto: speech left the audible mark at \(afterSpeech), expected 64000")
    }
    if afterTrailing != afterSpeech {
        failures.append("veto: trailing silence moved the audible mark — trimming would never fire")
    }
    print("  veto: silence and speech distinguished, so a call that is still talking is never cut")

    // --- Menu bar readout: window titles are user data and run long. ----------
    let longTitle = "Weekly Sync — Q3 Roadmap and API Cutover — Google Meet — Google Chrome"
    let truncated = RecordingIndicator.truncateMiddle(longTitle, to: 40)
    if truncated.count > 40 {
        failures.append("menubar: truncated title is \(truncated.count) chars, over the 40 limit")
    }
    if !truncated.contains("…") {
        failures.append("menubar: long title was not truncated")
    }
    // The tail identifies the meeting as much as the head does; dropping it
    // leaves several calls looking identical in the menu.
    if !truncated.hasPrefix("Weekly") || !truncated.hasSuffix("Chrome") {
        failures.append("menubar: truncation lost the start or end of the title: \(truncated)")
    }
    if RecordingIndicator.truncateMiddle("Zoom Meeting", to: 40) != "Zoom Meeting" {
        failures.append("menubar: a short title was altered")
    }
    // Em dashes are ordinary in window titles; splitting a grapheme would corrupt them.
    if RecordingIndicator.truncateMiddle("A — B", to: 40) != "A — B" {
        failures.append("menubar: em dash mangled")
    }

    if RecordingIndicator.clock(59) != "0:59" || RecordingIndicator.clock(600) != "10:00" {
        failures.append("menubar: sub-hour clock formatting wrong")
    }
    if RecordingIndicator.clock(3661) != "1:01:01" {
        failures.append("menubar: hour-long clock formatting wrong, got \(RecordingIndicator.clock(3661))")
    }
    // VoiceOver reads the label aloud; "12:04" spoken as digits is not a duration.
    if RecordingIndicator.spoken(30) != "less than a minute" {
        failures.append("menubar: sub-minute duration not spoken as words")
    }
    if RecordingIndicator.spoken(60) != "1 minute" || RecordingIndicator.spoken(1500) != "25 minutes" {
        failures.append("menubar: minute durations not spoken correctly")
    }
    if RecordingIndicator.spoken(3600) != "1 hour" || RecordingIndicator.spoken(5400) != "1 hour 30 minutes" {
        failures.append("menubar: hour durations not spoken correctly, got \(RecordingIndicator.spoken(5400))")
    }
    print("  menubar: titles truncate from the middle, clock and spoken durations format correctly")

    // --- The file has to be readable *during* the recording, not only after. --
    // Everything lost so far was lost this way: a recording is a stub until
    // finalize, so any interruption in an hour destroyed all of it.
    let livePath = root.appendingPathComponent("live.wav").path
    let live = try WAVWriter(path: livePath)
    // Ten seconds, appended the way capture does — well past the refresh interval.
    for _ in 0..<10 { live.append(samples: [Int16](repeating: 0, count: 16000)) }

    // Read the header without finalizing, exactly as an interrupted file would be.
    let midHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: livePath))
    midHandle.seek(toFileOffset: 4)
    let midRiff = midHandle.readData(ofLength: 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    midHandle.seek(toFileOffset: 40)
    let midData = midHandle.readData(ofLength: 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    try? midHandle.close()

    let expected: UInt32 = 16000 * 2 * 10
    // The header trails by at most one refresh interval, never by the whole file.
    if midData == 0 {
        failures.append("live: header still declares 0 mid-recording — an interrupted file would be unreadable")
    }
    if midData + WAVWriter.headerRefreshBudget < expected {
        failures.append("live: header is \(expected - midData) bytes behind, more than one refresh interval")
    }
    if midRiff != midData + 36 {
        failures.append("live: RIFF size does not match the data size mid-recording")
    }
    let finalBytes2 = live.finalize()
    if finalBytes2 != expected {
        failures.append("live: finalize reported \(finalBytes2), expected \(expected)")
    }
    print("  live: header stays current while recording (\(midData)/\(expected) bytes visible mid-write)")

    // The mic helper has to be responsible for itself, or macOS asks whatever
    // launched Meetey for the microphone — and some launchers can never say yes.
    let checkPath = NSTemporaryDirectory() + "meetey-responsible-\(getpid())"
    if let helper = Responsibility.spawnDisclaimed(["--responsible-check", checkPath]) {
        var status: Int32 = 0
        waitpid(helper, &status, 0)
        let fields = ((try? String(contentsOfFile: checkPath, encoding: .utf8)) ?? "").split(separator: " ")
        try? FileManager.default.removeItem(atPath: checkPath)
        if fields.count == 2, fields[1] == "unknown" {
            print("  mic: responsibility not readable here — disclaim not verified")
        } else if fields.count == 2, fields[0] == fields[1] {
            print("  mic: helper is responsible for itself")
        } else {
            failures.append("mic: helper is not responsible for itself (\(fields.joined(separator: " ")))")
        }
    } else {
        failures.append("mic: could not spawn the helper")
    }

    // Timeline: jitter is ignored, real gaps are closed exactly.
    if MicTimeline.paddingBefore(elapsed: 1.0, written: 15_000, incoming: 800) != 0 {
        failures.append("mic: padded over buffer jitter")
    }
    if MicTimeline.paddingBefore(elapsed: 5.0, written: 0, incoming: 1_600) != 78_400 {
        failures.append("mic: late start not padded to the call's clock")
    }

    // A mic file longer than the trimmed call recording is cut to match.
    let micTest = NSTemporaryDirectory() + "meetey-mic-trim-\(getpid()).wav"
    let micWriter = try WAVWriter(path: micTest)
    micWriter.append(samples: [Int16](repeating: 1000, count: 32_000))
    micWriter.finalize()
    truncateWAV(atPath: micTest, toDataBytes: 20_001)
    let trimmedSize = (try? FileManager.default.attributesOfItem(atPath: micTest)[.size] as? Int) ?? 0
    try? FileManager.default.removeItem(atPath: micTest)
    if trimmedSize != Int(WAVWriter.headerBytes) + 20_000 {
        failures.append("mic: trim left \(trimmedSize) bytes, expected \(Int(WAVWriter.headerBytes) + 20_000)")
    }
    print("  mic: timeline padding and trim-to-call OK")

    // The meeting-window check reads window-server metadata, never
    // ScreenCaptureKit. A real window is found by number; a made-up one isn't.
    if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
       let any = list.first(where: { $0[kCGWindowOwnerPID as String] != nil && $0[kCGWindowNumber as String] != nil }),
       let pid = (any[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
       let number = (any[kCGWindowNumber as String] as? Int).map(UInt32.init) {
        if MeetingWindow.isOpen(windowID: number, title: "", pid: pid) != true {
            failures.append("window: an existing window was reported closed")
        }
        if MeetingWindow.isOpen(windowID: UInt32.max - 1, title: "", pid: pid) != false {
            failures.append("window: a window that doesn't exist was reported open")
        }
        print("  window: meeting-window check finds open windows and misses closed ones")
    } else {
        print("  window: no windows to check against here — skipped")
    }

    // Call-end detection depends on reading other processes' input state once
    // the mic is recorded. Informational: a machine with no audio devices (CI)
    // has nothing to report, which is not a failure of this code.
    if #available(macOS 14.0, *) {
        if let inUse = Microphone.inUse(excluding: [getpid()]) {
            print("  mic: per-process input state readable (another app using the mic: \(inUse))")
            if let inputs = Microphone.processesUsingInput() {
                print("  mic: \(inputs.pids.count) process(es) taking input now\(inputs.bundles.isEmpty ? "" : ": " + inputs.bundles.sorted().joined(separator: ", "))")
            }
        } else {
            print("  mic: WARNING — per-process input state unreadable; call-end detection will not fire while the mic is recorded")
        }
    }

    if failures.isEmpty {
        print("selftest: PASS (settling, volatility mask, cadence, revisit dedup, unsettled valve, auto-stop, call-end trim, OCR + manifest, mic helper OK)")
        exit(0)
    }
    for failure in failures { fputs("selftest: FAIL — \(failure)\n", stderr) }
    exit(1)
}

// MARK: - Main

enum CaptureError: Error, LocalizedError {
    case shareableContentTimedOut

    var errorDescription: String? {
        switch self {
        case .shareableContentTimedOut:
            return "Timed out asking macOS what is on screen. This usually means Screen Recording "
                 + "permission has not been granted to this binary — after an update it is re-signed "
                 + "and macOS treats it as new. Grant it in System Settings > Privacy & Security > "
                 + "Screen Recording."
        }
    }
}

/// `SCShareableContent.current` with a deadline.
///
/// It does not reliably throw when Screen Recording permission is unresolved — it
/// can simply never return. A capture launched by the watch agent then sits
/// forever: no output, no exit, holding the active-recording lock, looking
/// identical in the log to a healthy recording. That is exactly how a 35-minute
/// meeting was silently not recorded.
func shareableContent(timeout: TimeInterval = 15) async throws -> SCShareableContent {
    try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
        group.addTask { try await SCShareableContent.current }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw CaptureError.shareableContentTimedOut
        }
        guard let first = try await group.next() else { throw CaptureError.shareableContentTimedOut }
        group.cancelAll()
        return first
    }
}

let supportedBundleIDs = ["com.google.Chrome", "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2"]

func listApps() async throws {
    let content = try await shareableContent()
    let found = content.applications.filter { supportedBundleIDs.contains($0.bundleIdentifier) }
    if found.isEmpty {
        print("[]")
    } else {
        let json = found.map { "{\"bundleID\":\"\($0.bundleIdentifier)\",\"name\":\"\($0.applicationName)\"}" }
            .joined(separator: ",")
        print("[\(json)]")
    }
}

struct DisplayRecord: Codable {
    let displayID: UInt32
    let width: Int          // pixels, not points
    let height: Int
    let isMain: Bool
}

func listDisplays() async throws {
    let content = try await shareableContent()
    let main = CGMainDisplayID()
    let displays = content.displays.map { display -> DisplayRecord in
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        return DisplayRecord(
            displayID: display.displayID,
            width: mode?.pixelWidth ?? display.width * 2,
            height: mode?.pixelHeight ?? display.height * 2,
            isMain: display.displayID == main
        )
    }
    try printJSON(displays)
}

struct WindowRecord: Codable {
    let windowID: UInt32
    let title: String
    let bundleID: String
    let appName: String
    let width: Int
    let height: Int
    let isOnScreen: Bool
    let displayID: UInt32?
    /// Whether this window's app is taking audio input — the strongest sign a
    /// call is actually in progress. Nil when it can't be read.
    let appUsingMic: Bool?
}

/// Lists the capturable windows of the supported meeting apps. For Chrome the
/// title is the active tab's, which is what makes a window choosable by a human —
/// ScreenCaptureKit has no concept of a tab, so picking the window holding the
/// meeting is as close as the platform gets.
func listWindows(bundleID: String) async throws {
    let content = try await shareableContent()
    let wanted = bundleID.isEmpty ? supportedBundleIDs : [bundleID]
    let inputs = Microphone.processesUsingInput()
    let windows = content.windows
        .filter { window in
            guard let app = window.owningApplication, wanted.contains(app.bundleIdentifier) else { return false }
            // Sub-100px windows are toolbars, popups, and off-screen scratch
            // surfaces — never the thing someone means by "the meeting window".
            return window.frame.width >= 100 && window.frame.height >= 100
        }
        // On-screen first, then largest — the meeting is almost always both.
        .sorted { a, b in
            if a.isOnScreen != b.isOnScreen { return a.isOnScreen }
            return a.frame.width * a.frame.height > b.frame.width * b.frame.height
        }
        .map { window in
            WindowRecord(
                windowID: window.windowID,
                title: window.title ?? "",
                bundleID: window.owningApplication?.bundleIdentifier ?? "",
                appName: window.owningApplication?.applicationName ?? "",
                width: Int(window.frame.width),
                height: Int(window.frame.height),
                isOnScreen: window.isOnScreen,
                displayID: displayContaining(window, in: content)?.displayID,
                appUsingMic: window.owningApplication.flatMap { app in
                    Microphone.appUsesInput(bundleID: app.bundleIdentifier, pid: app.processID, using: inputs)
                }
            )
        }
    try printJSON(windows)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(data: try encoder.encode(value), encoding: .utf8) ?? "[]")
}

/// The display holding most of a window, by centre point.
func displayContaining(_ window: SCWindow, in content: SCShareableContent) -> SCDisplay? {
    let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
    return content.displays.first { $0.frame.contains(centre) }
}

/// An end-to-end check of the capture path, run against the real system.
///
/// The selftest covers logic and passes reliably; every failure that has actually
/// cost a recording lived one layer down, in the environment — Screen Recording
/// permission, a PATH without Homebrew, a stream that never delivered. None of
/// that is reachable from a unit test, and all of it is reachable in ten seconds
/// here.
///
/// Exits non-zero if the machine cannot record, so install and update can refuse
/// to claim success.
func verify(seconds: TimeInterval = 6) async throws {
    var problems: [String] = []
    func ok(_ label: String, _ detail: String = "") {
        print("  ✓ \(label)\(detail.isEmpty ? "" : "  \(detail)")")
    }
    func bad(_ label: String, _ detail: String) {
        print("  ✗ \(label)  \(detail)")
        problems.append("\(label): \(detail)")
    }

    print("Checking that this machine can actually record.\n")

    // 1. Screen Recording permission. The call that hangs rather than failing
    //    when this is unresolved, which is why it is bounded.
    var content: SCShareableContent
    do {
        content = try await shareableContent(timeout: 15)
        ok("Screen Recording permission", "\(content.applications.count) apps visible")
    } catch {
        bad("Screen Recording permission", error.localizedDescription)
        print("\nCannot record without this. Grant it in System Settings > Privacy & Security > Screen Recording.")
        exit(1)
    }

    // 2. Something to capture. Any running app proves the pipeline; a meeting app
    //    is not required to test it.
    guard let target = content.applications.first(where: { supportedBundleIDs.contains($0.bundleIdentifier) })
        ?? content.applications.first(where: { !$0.applicationName.isEmpty }) else {
        bad("An app to capture", "no applications visible")
        exit(1)
    }
    ok("An app to capture", target.applicationName)

    guard let display = content.displays.first else {
        bad("A display to capture", "none found")
        exit(1)
    }
    ok("A display to capture", "\(display.width)x\(display.height)")

    // 3. A real capture, written to a real file.
    let path = NSTemporaryDirectory() + "meetey-verify-\(ProcessInfo.processInfo.processIdentifier).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 16000
    config.channelCount = 1
    config.width = 2
    config.height = 2

    let writer = try WAVWriter(path: path)
    let delegate = CaptureDelegate(writer: writer, keyframes: nil)
    let filter = SCContentFilter(display: display, including: [target], exceptingWindows: [])
    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)

    do {
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        ok("Audio capture starts")
    } catch {
        bad("Audio capture starts", error.localizedDescription)
        exit(1)
    }

    print("  … capturing for \(Int(seconds))s")
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

    // 4. Did the header stay current while writing? This is the property that
    //    makes an interrupted recording survivable, so check it mid-flight.
    let midHeader = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    midHeader?.seek(toFileOffset: 40)
    let declaredMidway = midHeader?.readData(ofLength: 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian } ?? 0
    try? midHeader?.close()

    try? await stream.stopCapture()
    let captured = writer.finalize()

    let capturedSeconds = writer.seconds(forDataBytes: captured)
    if captured == 0 {
        bad("Audio reaches the file", "no audio was captured — the stream started but delivered nothing")
    } else if capturedSeconds < seconds * 0.5 {
        // A capture that stops early is the failure this check exists to find.
        // Reporting "0.3s written" as a tick let an interrupted stream pass as
        // healthy, which is exactly the fault being hunted.
        bad("Capture runs to completion",
            String(format: "only %.1fs of %.0fs — the stream was interrupted. Something else is talking to "
                 + "the capture service; a running watch agent is the usual cause.", capturedSeconds, seconds))
    } else {
        ok("Audio reaches the file", String(format: "%.1fs of %.0fs", capturedSeconds, seconds))
    }

    if declaredMidway == 0 && captured > WAVWriter.headerRefreshBudget {
        bad("File stays readable while recording", "header was still empty mid-capture")
    } else {
        ok("File stays readable while recording")
    }

    print("")
    if problems.isEmpty {
        print("Ready to record.")
        exit(0)
    }
    print("Not ready to record:")
    for problem in problems { print("  - \(problem)") }
    exit(1)
}

func record(args: Args) async throws {
    // Setup runs before anything is written to disk, so without these a stall
    // here is indistinguishable from a recording that is working.
    fputs("meetey-capture: resolving what is on screen\n", stderr)
    let content = try await shareableContent()
    fputs("meetey-capture: preparing capture\n", stderr)

    guard let app = content.applications.first(where: { $0.bundleIdentifier == args.bundleID }) else {
        fputs("meetey-capture: app not found: \(args.bundleID)\n", stderr)
        exit(1)
    }

    // `--window` no longer scopes the capture; it only says where the meeting is,
    // so the right display is chosen on a multi-monitor setup. A window that has
    // since been replaced is therefore harmless — Google Meet replaces its window
    // on joining, and that must not be able to stop a recording from starting.
    var window: SCWindow? = nil
    if let requested = args.windowID {
        window = content.windows.first { $0.windowID == requested }
        if window == nil {
            fputs("meetey-capture: window \(requested) is gone — picking the display by app instead\n", stderr)
        }
    }

    // Pick the display holding the meeting rather than whichever one happens to
    // be first: on a multi-monitor setup those are frequently not the same, and
    // capturing the wrong one yields a session of entirely irrelevant keyframes.
    let display: SCDisplay
    if let requested = args.displayID {
        guard let match = content.displays.first(where: { $0.displayID == requested }) else {
            fputs("meetey-capture: display not found: \(requested). Run --list-displays for current IDs.\n", stderr)
            exit(1)
        }
        display = match
    } else if let window, let holding = displayContaining(window, in: content) {
        display = holding
    } else if let frontmost = content.windows
        .filter({ $0.owningApplication?.bundleIdentifier == args.bundleID && $0.isOnScreen })
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
        let holding = displayContaining(frontmost, in: content) {
        display = holding
    } else if let first = content.displays.first {
        display = first
    } else {
        fputs("meetey-capture: no display found\n", stderr)
        exit(1)
    }

    // App-scoped, always. Capture is never scoped to a single window.
    //
    // Window scoping was added to keep an app's other windows and its
    // notification banners out of frame. It cost four recordings and is gone.
    //
    // Google Meet replaces its window when you join a call. A stream targeting
    // the old window dies — and ScreenCaptureKit's connection is per *process*,
    // not per stream, so it takes every other stream in the process down with it.
    // Splitting audio and video into two streams did not help: both died together
    // with "application connection being interrupted", the app-scoped audio
    // included.
    //
    // The framing was worth something. It was not worth the recording.
    let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 16000
    config.channelCount = 1

    let startedAt = Date()
    var keyframes: KeyframeWriter? = nil

    if args.video {
        // SCDisplay reports points; CGDisplayMode reports pixels. Capturing at
        // point dimensions on a Retina display halves the resolution and makes
        // OCR unusable.
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            config.width = mode.pixelWidth
            config.height = mode.pixelHeight
        } else {
            config.width = display.width * 2
            config.height = display.height * 2
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(args.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        // A moving cursor changes the frame hash and would emit keyframes on an
        // otherwise-static screen.
        config.showsCursor = false

        let sessionId = URL(fileURLWithPath: args.outputPath)
            .deletingPathExtension().lastPathComponent
        let dir = args.framesDir.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: args.outputPath)
                .deletingLastPathComponent()
                .appendingPathComponent("\(sessionId)-frames")

        keyframes = try KeyframeWriter(
            framesDir: dir,
            sessionId: sessionId,
            sceneThreshold: args.sceneThreshold,
            maxFrames: args.maxFrames,
            ocrEnabled: args.ocr,
            startedAt: startedAt,
            maxUnsettled: args.maxUnsettled,
            volatilityMaskEnabled: args.volatilityMask
        )
        fputs("meetey-capture: video capture enabled (\(config.width)x\(config.height) @ \(args.fps)fps) -> \(dir.path)\n", stderr)
    } else {
        // SCStream requires video dimensions even for audio-only capture.
        config.width = 2
        config.height = 2
    }

    let writer = try WAVWriter(path: args.outputPath)
    let delegate = CaptureDelegate(writer: writer, keyframes: keyframes)

    // Live output: the call's transcript and each keyframe, written as they
    // happen (LiveOutput.swift). Started before capture so the transcript's
    // clock begins at the recording's first sample; a model that still has to
    // load or download never delays the recording.
    if let liveDir = args.liveDir {
        try? FileManager.default.createDirectory(atPath: liveDir, withIntermediateDirectories: true)
        delegate.live = makeLiveTranscriber(directory: liveDir, speaker: "them")
        keyframes?.liveLog = try? LiveLog(url: LiveFiles.frames(URL(fileURLWithPath: liveDir)))
    }

    // One stream. Two streams bought nothing — the connection they share is
    // per-process, so they fail together — and cost an entire class of bug.
    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
    try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
    if args.video {
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
    }
    delegate.captureStream = stream

    try await stream.startCapture()
    fputs("meetey-capture: recording started\n", stderr)

    // Your own voice never reaches the app's audio output, so the call recording
    // never contains it. A helper records the mic to a sibling file on the same
    // clock; see MicCapture.swift for why it is a separate, disclaimed process.
    let micPid: pid_t? = {
        guard let micPath = args.micPath else { return nil }
        guard #available(macOS 14.0, *) else {
            // Without per-process mic state, recording the mic would blind
            // call-end detection, so the call is recorded without it.
            fputs("meetey-capture: recording the microphone needs macOS 14 — call audio only\n", stderr)
            return nil
        }
        let epochMs = String(Int(Date().timeIntervalSince1970 * 1000))
        let live = args.liveDir.map { ["--live", $0] } ?? []
        guard let pid = Responsibility.spawnDisclaimed(["--record-mic", "--output", micPath,
                                                        "--epoch-ms", epochMs] + live) else {
            fputs("meetey-capture: could not start microphone recording — call audio only\n", stderr)
            return nil
        }
        fputs("meetey-capture: recording your microphone to \(micPath)\n", stderr)
        return pid
    }()
    let ownPids: Set<pid_t> = micPid.map { [getpid(), $0] } ?? [getpid()]

    // The in-call assistant: a separate process reading this recording's live
    // files, so nothing it does can affect the capture.
    let showAssistant: (() -> Void)? = {
        guard args.assistant, let liveDir = args.liveDir else { return nil }
        let title = args.label.isEmpty ? "Meeting" : args.label
        let framesDir = keyframes == nil ? nil : (args.framesDir ?? URL(fileURLWithPath: args.outputPath)
            .deletingPathExtension().path + "-frames")
        return { PanelProcess.showOrLaunch(liveDir: liveDir, title: title, framesDir: framesDir, startedAt: startedAt) }
    }()
    showAssistant?()

    // Use AsyncStream to bridge DispatchSource signal handlers into async context
    let (stopStream, stopContinuation) = AsyncStream<Void>.makeStream()

    let box = NSLock()
    var fired = false
    let fireOnce = {
        box.lock()
        defer { box.unlock() }
        guard !fired else { return }
        fired = true
        stopContinuation.yield(())
        stopContinuation.finish()
    }

    // DispatchSource signal handlers can capture context, unlike raw signal()
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT,  SIG_IGN)
    let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let sigintSrc  = DispatchSource.makeSignalSource(signal: SIGINT,  queue: .global())
    sigtermSrc.setEventHandler { fireOnce() }
    sigintSrc.setEventHandler  { fireOnce() }
    sigtermSrc.resume()
    sigintSrc.resume()

    // A dead audio stream ends the recording the same way a signal does, so what
    // was captured is finalised instead of the process running on writing nothing.
    delegate.onStreamLost = { fireOnce() }

    if let timeout = args.stopAfter {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            fireOnce()
        }
    }

    // Carries the user's "Keep Recording" from the menu (main thread) to the
    // call-end poll (its own Task).
    let vetoLock = NSLock()
    var userVetoedEnd = false
    let keepRecording = { vetoLock.withLock { userVetoedEnd = true } }
    let takeVeto = { () -> Bool in
        vetoLock.withLock { let v = userVetoedEnd; userVetoedEnd = false; return v }
    }

    // Bound as a `let` before the polling Tasks capture it: a captured `var`
    // crossing into concurrent code is a data race, and an error under Swift 6.
    let indicator: RecordingIndicator? = await {
        guard args.menuBar else { return nil }
        let menuLabel = args.label
        let capturingVideo = args.video
        let onMicPaused: ((Bool) -> Void)? = micPid.map { pid in
            { paused in
                kill(pid, paused ? SIGUSR1 : SIGUSR2)
                fputs("meetey-capture: microphone \(paused ? "paused" : "resumed")\n", stderr)
            }
        }
        let made = await MainActor.run {
            RecordingIndicator(label: menuLabel, startedAt: startedAt,
                               capturingVideo: capturingVideo,
                               onStop: fireOnce, onKeepRecording: keepRecording,
                               onMicPaused: onMicPaused, onShowAssistant: showAssistant)
        }
        if made == nil {
            fputs("meetey-capture: no GUI session — recording without a menu bar indicator\n", stderr)
        }
        return made
    }()

    // Where to cut the recording back to, if the call turns out to have ended
    // before we stopped. Written by the poll below, read by finalize.
    let trimLock = NSLock()
    var trimToBytes: UInt32? = nil

    if args.stopWhenCallEnds {
        Task {
            var monitor = MeetingEndMonitor(grace: args.fallbackEndGrace)
            var everArmed = false
            var announced = false
            let appName = NSRunningApplication.runningApplications(withBundleIdentifier: args.bundleID)
                .first?.localizedName ?? "The meeting app"
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                // Whether the *meeting app* still holds the mic — itself or a
                // helper it launched. Asking "is anyone but Meetey using it"
                // let any other app with the mic (dictation, a browser tab,
                // system voice features) keep a finished call recording.
                // Unable to read it is not the same as free: that would end a
                // live meeting.
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: args.bundleID).first
                let reading: Bool?
                var appSpecific = false
                if let app, let inputs = Microphone.processesUsingInput() {
                    reading = Microphone.appUsesInput(bundleID: args.bundleID, pid: app.processIdentifier, using: inputs)
                    appSpecific = reading != nil
                } else if micPid != nil, #available(macOS 14.0, *) {
                    reading = Microphone.inUse(excluding: ownPids)
                } else {
                    reading = Microphone.inUse()
                }
                guard let inUse = reading else { continue }
                let windowOpen = app.flatMap {
                    MeetingWindow.isOpen(windowID: args.meetingWindow, title: args.meetingTitle, pid: $0.processIdentifier)
                }

                // The user saw "ending soon" and said no. Restart the clock —
                // resetCandidate rather than a fresh monitor, so it stays armed.
                if takeVeto() {
                    monitor.resetCandidate()
                    announced = false
                    fputs("meetey-capture: keeping the recording — call-end clock restarted\n", stderr)
                    await MainActor.run { indicator?.setState(.recording) }
                    continue
                }

                let mark = writer.bytesWritten
                // How long to wait depends on how good the evidence is. The
                // meeting app letting go of the mic is strong; with its window
                // gone too, stronger still. Only the generic "is any mic in
                // use" signal gets the old long wait, since that one is wrong
                // often enough to cost a meeting. The silence check and the trim
                // below apply whichever wait is used.
                let wait = windowOpen == false && appSpecific ? args.quickEndGrace
                    : appSpecific ? args.callEndGrace
                    : args.fallbackEndGrace
                let cut = monitor.update(micInUse: inUse, mark: mark, at: Date(), wait: wait)
                if monitor.hasCandidate && !announced {
                    announced = true
                    let wait = Int(monitor.remaining(at: Date()) ?? 0)
                    fputs("meetey-capture: \(appName) released the microphone\(windowOpen == false ? " and the meeting window closed" : "") — the call may have ended; stopping in \(wait)s unless it comes back\n", stderr)
                } else if !monitor.hasCandidate && announced {
                    announced = false
                    fputs("meetey-capture: \(appName) has the microphone again — still recording\n", stderr)
                }
                if let cutTo = cut {
                    // The mic says the call is over. Before acting on that, check
                    // the audio we have actually been recording — if anyone has
                    // spoken since, the meeting plainly did not end there and the
                    // signal was wrong. Keep recording and start over.
                    if writer.lastAudibleOffset > cutTo {
                        fputs("meetey-capture: microphone released but audio continued — still recording\n", stderr)
                        monitor.resetCandidate()
                        announced = false
                        await MainActor.run { indicator?.setState(.recording) }
                        continue
                    }
                    await MainActor.run { indicator?.setState(.stopping) }
                    trimLock.withLock { trimToBytes = cutTo }
                    let trimmed = writer.seconds(forDataBytes: mark - cutTo)
                    fputs(String(format: "meetey-capture: call ended — trimming back %.0fs of silence\n", trimmed), stderr)
                    fireOnce()
                    return
                }
                // Surface a pending stop while it is still reversible, rather
                // than letting the recording end out of nowhere.
                let pending = monitor.remaining(at: Date())
                await MainActor.run {
                    indicator?.setState(pending.map { .endingSoon(remaining: $0) } ?? .recording)
                }

                if monitor.isArmed && !everArmed {
                    everArmed = true
                    fputs("meetey-capture: microphone in use — call-end detection armed\n", stderr)
                }
            }
        }
    }

    if args.autoStop {
        let targetBundleID = args.bundleID
        Task {
            var monitor = AutoStopMonitor(grace: args.autoStopGrace)
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                // NSRunningApplication, not SCShareableContent.applications: an
                // app whose windows are all minimised can drop out of shareable
                // content while the meeting is still running and still producing
                // audio. Process liveness is the question being asked here.
                let appRunning = !NSRunningApplication
                    .runningApplications(withBundleIdentifier: targetBundleID).isEmpty

                if let reason = monitor.update(appRunning: appRunning, at: Date()) {
                    fputs("meetey-capture: auto-stop — \(reason)\n", stderr)
                    fireOnce()
                    return
                }
            }
        }
    }

    for await _ in stopStream { break }

    // The mic helper finishes its own file; give it a moment to do so.
    if let micPid {
        kill(micPid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<50 where waitpid(micPid, &status, WNOHANG) == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    try? await stream.stopCapture()
    await liveFinish(delegate.live)
    if let indicator {
        await MainActor.run { indicator.remove() }
    }
    let cutTo = trimLock.withLock { trimToBytes }
    let finalBytes = writer.finalize(trimmingToDataBytes: cutTo)
    if let micPath = args.micPath, micPid != nil {
        truncateWAV(atPath: micPath, toDataBytes: finalBytes)
    }
    if cutTo != nil {
        fputs(String(format: "meetey-capture: recording trimmed to %.0fs\n",
                     writer.seconds(forDataBytes: finalBytes)), stderr)
    }

    // Stopping saves audio; it does not write notes. Without saying so the user
    // is left with a file, no summary, and no reason to think anything is
    // outstanding — the indicator simply vanishes.
    if indicator != nil {
        let minutes = max(1, Int((writer.seconds(forDataBytes: finalBytes) / 60).rounded()))
        postNotification(
            title: "Meetey",
            subtitle: "Recording saved · \(minutes) min",
            body: "Run /meetey stop in Claude Code to write up the notes"
        )
    }
    if let keyframes {
        let result = keyframes.finalize()
        fputs("meetey-capture: wrote \(result.count) keyframe(s)\(result.truncated ? " (truncated at limit)" : "")\n", stderr)
    }
    fputs("meetey-capture: recording saved to \(args.outputPath)\n", stderr)
}

// Entry point
let args = Args.parse()

/// Owns the watcher indicator for the process's lifetime. A main-actor singleton
/// rather than a global var, so the reference is created and held on the actor
/// that AppKit requires.
@MainActor
final class IndicatorHost {
    static let shared = IndicatorHost()
    private var indicator: WatcherIndicator?

    func start(stateFile: String, plistPath: String?) -> Bool {
        indicator = WatcherIndicator(stateFile: stateFile, plistPath: plistPath)
        return indicator != nil
    }
}

Task {
    do {
        if !args.panelAsk.isEmpty, let liveDir = args.liveDir {
            await panelAsk(questions: args.panelAsk, liveDir: liveDir, framesDir: args.framesDir,
                           model: args.model, claude: args.claudePath)
        } else if args.panel, let liveDir = args.liveDir {
            let started = args.startedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            await MainActor.run {
                runPanel(liveDir: liveDir, title: args.title, framesDir: args.framesDir,
                         startedAt: started, capturePid: args.capturePid, claude: args.claudePath)
            }
        } else if let replayPath = args.replayPath {
            guard let liveDir = args.liveDir else {
                fputs("meetey-capture: --replay needs --live <dir>\n", stderr)
                exit(2)
            }
            await replay(callPath: replayPath, micPath: args.replayMicPath, framesDir: args.replayFramesDir,
                         liveDir: liveDir, speed: args.replaySpeed)
        } else if args.preflightSpeech {
            await preflightSpeech()
        } else if args.verifyMic {
            await verifyMic()
        } else if args.recordMic {
            await recordMic(outputPath: args.outputPath,
                            epoch: args.epochMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                            liveDir: args.liveDir)
        } else if let path = args.responsibleCheck {
            let me = getpid()
            let responsible = Responsibility.responsiblePid(for: me).map(String.init) ?? "unknown"
            try "\(me) \(responsible)".write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        } else if args.watchIndicator {
            let ok = await MainActor.run {
                IndicatorHost.shared.start(stateFile: args.stateFile,
                                           plistPath: args.plistPath.isEmpty ? nil : args.plistPath)
            }
            if !ok {
                fputs("meetey-capture: no GUI session — no watcher indicator\n", stderr)
                exit(0)
            }
            // Held by IndicatorHost for the life of the process; AppKit drives it.
        } else if args.verifyMode {
            try await verify()
        } else if args.selfTest {
            try selfTest()
        } else if args.listApps {
            try await listApps()
        } else if args.listDisplays {
            try await listDisplays()
        } else if args.listWindows {
            try await listWindows(bundleID: args.bundleID)
        } else {
            guard !args.bundleID.isEmpty, !args.outputPath.isEmpty else {
                fputs("""
                Usage: meetey-capture --app <bundle-id> --output <path.wav> [options]
                       meetey-capture --verify
                       meetey-capture --list-apps
                       meetey-capture --list-displays
                       meetey-capture --list-windows [--app <bundle-id>]

                Options:
                  --stop-after <seconds>    Stop automatically after this long
                  --auto-stop               Stop when the app quits, or when the
                                            window given to --window closes
                  --auto-stop-grace <secs>  How long that must hold before
                                            stopping (default 30)
                  --stop-when-call-ends     Also stop when the meeting app releases
                                            the microphone, trimming the recording
                                            back to when that happened
                  --call-end-grace <secs>   How long the mic must stay released
                                            before believing it (default 600)
                  --menu-bar                Show a menu bar indicator with a Stop
                                            Recording item while recording
                  --watch-indicator         Run only a menu bar item for the watch
                                            agent (used by the agent itself)
                  --state-file <path>       Active-recording state the indicator
                                            watches, to stand aside while recording
                  --label <text>            What to call this recording in the menu
                  --display <id>            Display to capture (default: the one
                                            showing the target app)
                  --window <id>             Where the meeting is, used only to pick
                                            the display. Does not scope the capture
                  --video                   Also capture screen keyframes (off by default)
                  --fps <n>                 Frames sampled per second (default 1)
                  --frames-dir <path>       Keyframe output directory
                  --no-ocr                  Skip on-device text recognition
                  --scene-threshold <n>     Grid cells (of 1024) that must change (default 12)
                  --max-frames <n>          Cap keyframes per session (default 200)
                  --max-unsettled <secs>    Force a keyframe if the screen never
                                            stops moving for this long (default 60)
                  --no-volatility-mask      Stop ignoring regions that move constantly
                                            (camera tiles, clocks, progress bars)

                """, stderr)
                exit(1)
            }
            try await record(args: args)
        }
        if !args.watchIndicator && !args.panel { exit(0) }
    } catch {
        fputs("meetey-capture: error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if args.menuBar || args.watchIndicator || args.panel {
    // A status item needs AppKit's run loop and an activation policy that keeps
    // the process out of the Dock and the app switcher. `.accessory` is what
    // makes an unbundled binary able to own a menu bar item at all.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
} else {
    RunLoop.main.run()
}
