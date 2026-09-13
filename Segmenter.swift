import Foundation

/// Splits a live 16 kHz mono stream into Parakeet-sized chunks at pauses
/// (or a 15 s cap) so decode can run while the user is still talking.
final class Segmenter {
    static let sampleRate = Capture.sampleRate
    static let windowMs = 32.0
    static let silenceCloseMs = 2_000.0
    static let minVoicedMs = 550.0
    static let capMs = 15_000.0
    static let minTailMs = 250.0
    static let rmsFloor: Float = 0.0025
    static let rmsCeil: Float = 0.006
    static let peakRatio: Float = 0.15

    struct Chunk {
        let samples: [Float]
        let voiced: Bool
    }

    private var open: [Float] = []
    private var carry: [Float] = []
    private var voicedMs = 0.0
    private var silenceRunMs = 0.0
    private var peakRms: Float = 0
    /// Samples pushed this take (closed + still open). Used to catch the last
    /// tap that stop() may have dropped from onChunk.
    private(set) var consumed = 0

    private var gate: Float {
        min(Self.rmsCeil, max(Self.rmsFloor, peakRms * Self.peakRatio))
    }

    private var windowSamples: Int {
        max(1, Int((Self.windowMs / 1000) * Self.sampleRate))
    }

    private var capSamples: Int {
        Int((Self.capMs / 1000) * Self.sampleRate)
    }

    func reset() {
        open.removeAll(keepingCapacity: true)
        carry.removeAll(keepingCapacity: true)
        voicedMs = 0
        silenceRunMs = 0
        peakRms = 0
        consumed = 0
    }

    func push(_ samples: [Float]) -> [Chunk] {
        guard !samples.isEmpty else { return [] }
        consumed += samples.count
        open.append(contentsOf: samples)
        runWindows(samples)
        var out: [Chunk] = []
        while true {
            let openMs = Double(open.count) / Self.sampleRate * 1000
            let pause = silenceRunMs >= Self.silenceCloseMs && voicedMs >= Self.minVoicedMs
            let capped = openMs >= Self.capMs
            guard pause || capped else { break }
            if let chunk = closeOpen(limit: pause ? nil : capSamples, trimSilence: pause) {
                out.append(chunk)
            } else {
                break
            }
        }
        return out
    }

    /// Remaining audio at stop. Drops a trailing unvoiced tail under ~250 ms.
    func finalize() -> Chunk? {
        let openMs = Double(open.count) / Self.sampleRate * 1000
        if voicedMs <= 0 {
            if openMs < Self.minTailMs || open.isEmpty {
                reset()
                return nil
            }
            reset()
            return nil
        }
        let chunk = Chunk(samples: open, voiced: true)
        reset()
        return chunk
    }

    private func runWindows(_ incoming: [Float]) {
        var data = carry
        data.append(contentsOf: incoming)
        let win = windowSamples
        let full = data.count / win
        for w in 0..<full {
            let base = w * win
            var sum: Float = 0
            for i in 0..<win {
                let v = data[base + i]
                sum += v * v
            }
            let rms = sqrt(sum / Float(win))
            if rms > peakRms { peakRms = rms }
            if rms >= gate {
                voicedMs += Self.windowMs
                silenceRunMs = 0
            } else {
                silenceRunMs += Self.windowMs
            }
        }
        carry = Array(data[(full * win)...])
    }

    private func closeOpen(limit: Int?, trimSilence: Bool) -> Chunk? {
        let n = min(limit ?? open.count, open.count)
        guard n > 0 else { return nil }
        var slice = Array(open[0..<n])
        if trimSilence {
            let sil = min(slice.count, Int((silenceRunMs / 1000) * Self.sampleRate))
            if sil > 0 { slice.removeLast(sil) }
        }
        let voiced = voicedMs >= Self.minVoicedMs
        let rest = Array(open[n...])
        open = rest
        carry.removeAll(keepingCapacity: true)
        silenceRunMs = 0
        voicedMs = rest.isEmpty ? 0 : Self.minVoicedMs
        guard !slice.isEmpty else { return nil }
        return Chunk(samples: slice, voiced: voiced)
    }
}
