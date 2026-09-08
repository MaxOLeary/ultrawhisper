import AppKit
import AVFoundation

/// One mic tap: 16 kHz mono float into RAM, plus RMS for the waveform card.
final class Capture {
    static let sampleRate: Double = 16_000

    var onLevel: ((CGFloat) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    func start() -> Bool {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Capture.sampleRate * 30))
        lock.unlock()

        let e = AVAudioEngine()
        let input = e.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.channelCount > 0, hw.sampleRate > 0,
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Capture.sampleRate,
                                      channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: hw, to: dst) else { return false }
        converter = conv
        let ratio = Capture.sampleRate / hw.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buf, _ in
            guard let self else { return }
            if let ch = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                let db = 20 * log10(max(rms, 1e-6))
                let level = min(1, max(0, (db + 50) / 40))   // -50 dB..-10 dB -> 0..1
                DispatchQueue.main.async { self.onLevel?(CGFloat(level)) }
            }
            guard let conv = self.converter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return }
            var err: NSError?
            var got = false
            conv.convert(to: out, error: &err) { _, status in
                if got { status.pointee = .noDataNow; return nil }
                got = true
                status.pointee = .haveData
                return buf
            }
            if err != nil { return }
            guard let dstCh = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let n = Int(out.frameLength)
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: dstCh, count: n))
            self.lock.unlock()
        }
        do { try e.start(); engine = e; return true } catch {
            NSLog("UltraWhisper capture: \(error)")
            input.removeTap(onBus: 0)
            converter = nil
            return false
        }
    }

    @discardableResult
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        lock.lock()
        let s = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return s
    }
}
