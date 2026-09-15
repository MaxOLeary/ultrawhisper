import FluidAudio
import Foundation
import os

/// In-process NVIDIA Parakeet TDT via FluidAudio CoreML on the Neural Engine.
/// Replaces the sherpa-onnx websocket server.
final class ParakeetEngine: @unchecked Sendable {
    private let asr = AsrManager(config: .default)
    private let ready = OSAllocatedUnfairLock(initialState: false)
    private let loading = OSAllocatedUnfairLock(initialState: false)
    /// What the first run is doing ("Downloading speech model (first run)…"),
    /// or the load error. Empty once ready. Shown in the menu and card footer.
    private let statusText = OSAllocatedUnfairLock(initialState: "")

    var isReady: Bool { ready.withLock { $0 } }
    var status: String { statusText.withLock { $0 } }

    /// Parakeet v3 auto-detects among 25 languages and on a short take can
    /// flip script ("yo" came back as "Яу"). When the configured language is
    /// written in the Latin alphabet, words with no Latin letters are dropped.
    var latinOnly = true

    static func usesLatinScript(_ language: String) -> Bool {
        !["ru", "uk", "bg", "be", "sr", "mk", "el"].contains(language.lowercased())
    }

    static func dropNonLatin(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let kept = words.filter { w in
            let letters = w.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            if letters.isEmpty { return true }   // numbers, punctuation
            return letters.contains { $0.isASCII || (0x00C0...0x024F).contains($0.value) }
        }
        return kept.joined(separator: " ")
    }

    func start() {
        let skip = loading.withLock { flag -> Bool in
            if flag || ready.withLock({ $0 }) { return true }
            flag = true
            return false
        }
        if skip { return }
        Task.detached(priority: .userInitiated) { await self.load() }
    }

    private func load() async {
        do {
            NSLog("Whisper: loading FluidAudio Parakeet TDT v3")
            statusText.withLock { $0 = "Downloading speech model (first run)…" }
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            statusText.withLock { $0 = "Loading speech model…" }
            try await asr.loadModels(models)
            ready.withLock { $0 = true }
            statusText.withLock { $0 = "" }
            NSLog("Whisper: FluidAudio ready")
        } catch {
            ready.withLock { $0 = false }
            statusText.withLock { $0 = "Speech model failed to load: \(error.localizedDescription)" }
            NSLog("Whisper: FluidAudio load failed: \(error)")
        }
        loading.withLock { $0 = false }
    }

    /// Empty string on not-ready, too-short audio, or a thrown decode.
    func transcribe(_ samples: [Float], timeout: TimeInterval = 30) -> String {
        guard isReady else { return "" }
        // FluidAudio rejects takes under ~300 ms.
        guard samples.count >= Int(0.3 * Capture.sampleRate) else { return "" }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let latin = latinOnly
        Task.detached(priority: .userInitiated) {
            defer { sem.signal() }
            do {
                var state = TdtDecoderState.make(decoderLayers: await self.asr.decoderLayerCount)
                let result = try await self.asr.transcribe(samples, decoderState: &state)
                box.text = latin ? ParakeetEngine.dropNonLatin(result.text) : result.text
            } catch {
                NSLog("Whisper: FluidAudio \(error)")
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return box.text
    }

    private final class Box: @unchecked Sendable {
        var text = ""
    }
}
