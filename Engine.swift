import FluidAudio
import Foundation
import os

/// In-process NVIDIA Parakeet TDT via FluidAudio CoreML on the Neural Engine.
/// Replaces the sherpa-onnx websocket server.
final class ParakeetEngine: @unchecked Sendable {
    private let asr = AsrManager(config: .default)
    private let ready = OSAllocatedUnfairLock(initialState: false)
    private let loading = OSAllocatedUnfairLock(initialState: false)

    var isReady: Bool { ready.withLock { $0 } }

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
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await asr.loadModels(models)
            ready.withLock { $0 = true }
            NSLog("Whisper: FluidAudio ready")
        } catch {
            ready.withLock { $0 = false }
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
        Task.detached(priority: .userInitiated) {
            defer { sem.signal() }
            do {
                var state = TdtDecoderState.make(decoderLayers: await self.asr.decoderLayerCount)
                let result = try await self.asr.transcribe(samples, decoderState: &state)
                box.text = result.text
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
