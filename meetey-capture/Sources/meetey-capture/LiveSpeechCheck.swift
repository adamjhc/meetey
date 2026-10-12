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
import Foundation
import Speech

/// `meetey-capture --preflight-speech`: can this Mac transcribe live?
///
/// Live mode depends on Apple's SpeechTranscriber (macOS 26+), whose model is a
/// system asset downloaded on demand — and a managed laptop may block that, or
/// not support the user's language. This finds out before any live code relies
/// on it: it checks the locale, installs the model if needed, then transcribes
/// a sentence synthesised on the spot and times it. No microphone, no files.
///
/// Prints ✓/✗ lines like `--verify`. Exits 0 when transcription worked.
func preflightSpeech() async -> Never {
    guard #available(macOS 26.0, *) else {
        print("  ✗ Live transcription  needs macOS 26 or later")
        exit(1)
    }
    exit(await runSpeechPreflight() ? 0 : 1)
}

@available(macOS 26.0, *)
private func runSpeechPreflight() async -> Bool {
    let phrase = "The checkout service started returning errors after the nine thirty deploy."

    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        print("  ✗ Language  \(Locale.current.identifier) is not supported by SpeechTranscriber "
            + "(supported: \(supported.joined(separator: ", ")))")
        return false
    }
    print("  ✓ Language  \(locale.identifier)")

    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [.audioTimeRange])

    // The model is a system asset. Installing it is the step a managed Mac is
    // most likely to refuse, so it gets its own line.
    let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    if installed {
        print("  ✓ Speech model  installed")
    } else {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let started = Date()
                print("  … Speech model  downloading")
                try await request.downloadAndInstall()
                print(String(format: "  ✓ Speech model  downloaded in %.0fs", Date().timeIntervalSince(started)))
            } else {
                print("  ✓ Speech model  installed")
            }
        } catch {
            print("  ✗ Speech model  could not be installed (\(error.localizedDescription)) — "
                + "a managed Mac may block system asset downloads")
            return false
        }
    }

    // Synthesise the test sentence. It arrives in chunks, as live audio would.
    let chunks = await synthesise(phrase, locale: locale)
    guard let first = chunks.first else {
        print("  ✗ Live transcription  could not synthesise test audio")
        return false
    }
    let audioSeconds = Double(chunks.reduce(0) { $0 + $1.frameLength }) / first.format.sampleRate

    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
          let converter = AudioChunkConverter(from: first.format, to: format) else {
        print("  ✗ Live transcription  no audio format the transcriber accepts")
        return false
    }
    let inputs = chunks.compactMap { converter.convert($0) }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()

    // Collect results concurrently; time from the end of audio to the final text,
    // which is the delay a live line would have.
    let collector = Task { () -> (text: String, firstVolatile: Date?, final: Date?) in
        var finalText = ""
        var firstVolatile: Date?
        var finalAt: Date?
        do {
            for try await result in transcriber.results {
                if result.isFinal {
                    finalText += String(result.text.characters)
                    finalAt = Date()
                } else if firstVolatile == nil {
                    firstVolatile = Date()
                }
            }
        } catch {}
        return (finalText, firstVolatile, finalAt)
    }

    let started = Date()
    do {
        try await analyzer.start(inputSequence: stream)
        for input in inputs { builder.yield(AnalyzerInput(buffer: input)) }
        builder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        print("  ✗ Live transcription  failed (\(error.localizedDescription))")
        return false
    }
    let result = await collector.value
    let elapsed = Date().timeIntervalSince(started)

    let heard = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = Set(phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    let got = Set(heard.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    let matched = expected.intersection(got).count

    guard !heard.isEmpty else {
        print("  ✗ Live transcription  produced no text")
        return false
    }
    let firstText = result.firstVolatile.map { String(format: ", first words after %.1fs", $0.timeIntervalSince(started)) } ?? ""
    print(String(format: "  ✓ Live transcription  %.1fs of speech transcribed in %.1fs%@ (%d/%d words)",
                 audioSeconds, elapsed, firstText, matched, expected.count))
    print("      heard: \"\(heard)\"")
    return matched * 2 >= expected.count
}

/// Renders `text` with the system voice for `locale`, as the synthesiser's chunks.
@available(macOS 26.0, *)
private func synthesise(_ text: String, locale: Locale) async -> [AVAudioPCMBuffer] {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier(.bcp47))
        ?? AVSpeechSynthesisVoice(language: "en-US")

    return await withCheckedContinuation { continuation in
        var chunks: [AVAudioPCMBuffer] = []
        var resumed = false
        synthesizer.write(utterance) { buffer in
            guard !resumed, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                chunks.append(pcm)
                return
            }
            // A zero-length buffer marks the end.
            resumed = true
            continuation.resume(returning: chunks)
            _ = synthesizer // keep it alive until the end
        }
    }
}

/// Converts a stream of buffers to the analyzer's format with one converter, so
/// resampling state carries across chunk boundaries.
final class AudioChunkConverter {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let ratio: Double

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.format = target
        self.ratio = target.sampleRate / source.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
