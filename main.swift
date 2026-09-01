// UltraWhisper - local push-to-talk dictation for macOS.
//
// Hold a hotkey, talk, let go. The audio goes ffmpeg -> Parakeet TDT v3 via
// sherpa-onnx (whisper.cpp as fallback) -> your
// clipboard -> Cmd+V into whatever has focus, then the old clipboard comes
// back. Everything runs on this Mac; nothing leaves it unless you opt into
// cleanup mode in ~/.config/ultrawhisper/.env (local Ollama, or xAI Grok —
// never OpenAI/Google/Anthropic endpoints).
//
// Build: ./build.sh   (see README.md)

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation

// MARK: - Config

struct Config: Codable {
    var modelPath: String
    var ffmpegPath: String
    var whisperPath: String
    var audioDevice: String      // avfoundation device index ("0") or name substring
    var threads: Int
    var serverPort: Int          // whisper-server keeps the model warm in RAM
    var language: String
    var recordHotkey: String     // e.g. "cmd+alt+space", or "ralt" for right Option alone
    var cleanupHotkey: String    // e.g. "cmd+alt+shift+space"
    var sounds: Bool
    var minSeconds: Double       // ignore taps shorter than this
    var cleanupPrompt: String
    // Optional so an older config.json still decodes; nil means the default.
    var engine: String?          // "parakeet" (default) or "whisper"

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ultrawhisper", isDirectory: true)
    static let file = dir.appendingPathComponent("config.json")
    static let envFile = dir.appendingPathComponent(".env")
    static let modelsDir = dir.appendingPathComponent("models", isDirectory: true)

    var engineName: String { engine ?? "parakeet" }

    // The one place the sherpa-onnx layout is spelled out.
    static let sherpaRoot = dir.appendingPathComponent("sherpa-onnx").path
    static let parakeetServerBin = sherpaRoot + "/bin/sherpa-onnx-offline-websocket-server"
    static let parakeetDir = modelsDir.appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8").path
    static let parakeetEncoder = parakeetDir + "/encoder.int8.onnx"
    static let parakeetDecoder = parakeetDir + "/decoder.int8.onnx"
    static let parakeetJoiner = parakeetDir + "/joiner.int8.onnx"
    static let parakeetTokens = parakeetDir + "/tokens.txt"

    static var defaults: Config {
        Config(
            modelPath: modelsDir.appendingPathComponent("ggml-base.en.bin").path,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            whisperPath: "/opt/homebrew/bin/whisper-cli",
            audioDevice: "0",
            threads: 4,
            serverPort: 8765,
            language: "en",
            recordHotkey: "cmd+alt+space",
            cleanupHotkey: "cmd+alt+shift+space",
            sounds: true,
            minSeconds: 0.35,
            cleanupPrompt: "You clean up voice dictation. Fix punctuation and capitalization, "
                + "remove filler words (um, uh, like, you know), fix obvious transcription "
                + "slips, keep the speaker's wording and meaning otherwise. Return only the "
                + "cleaned text, no commentary, no quotes.",
            engine: "parakeet"
        )
    }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = defaults
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { try? data.write(to: file) }
        return cfg
    }

    /// Reads KEY=VALUE lines from ~/.config/ultrawhisper/.env (no accounts, no telemetry).
    static func env() -> [String: String] {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }
}

// MARK: - Hotkey parsing

/// A chord: some modifiers plus (optionally) one key. With no key it's a
/// modifier-only chord like "ralt" (hold right Option).
struct Hotkey {
    var flags: CGEventFlags = []          // generic modifiers (cmd/alt/shift/ctrl)
    var deviceBits: UInt64 = 0            // left/right-specific bits (e.g. right Option)
    var keyCode: Int64? = nil

    static let keyCodes: [String: Int64] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51, "grave": 50, "`": 50, "minus": 27, "equal": 24,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // NX_DEVICE*KEYMASK bits, the left/right-specific modifier flags.
    static let lcmd: UInt64 = 0x08, rcmd: UInt64 = 0x10
    static let lalt: UInt64 = 0x20, ralt: UInt64 = 0x40
    static let lshift: UInt64 = 0x02, rshift: UInt64 = 0x04
    static let lctrl: UInt64 = 0x01, rctrl: UInt64 = 0x2000

    static func parse(_ s: String) -> Hotkey? {
        var hk = Hotkey()
        for tok in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch tok {
            case "cmd", "command", "meta": hk.flags.insert(.maskCommand)
            case "alt", "opt", "option": hk.flags.insert(.maskAlternate)
            case "shift": hk.flags.insert(.maskShift)
            case "ctrl", "control": hk.flags.insert(.maskControl)
            case "lcmd": hk.flags.insert(.maskCommand); hk.deviceBits |= lcmd
            case "rcmd": hk.flags.insert(.maskCommand); hk.deviceBits |= rcmd
            case "lalt", "lopt", "loption": hk.flags.insert(.maskAlternate); hk.deviceBits |= lalt
            case "ralt", "ropt", "roption": hk.flags.insert(.maskAlternate); hk.deviceBits |= ralt
            case "lshift": hk.flags.insert(.maskShift); hk.deviceBits |= lshift
            case "rshift": hk.flags.insert(.maskShift); hk.deviceBits |= rshift
            case "lctrl": hk.flags.insert(.maskControl); hk.deviceBits |= lctrl
            case "rctrl": hk.flags.insert(.maskControl); hk.deviceBits |= rctrl
            default:
                guard let code = keyCodes[tok] else { return nil }
                hk.keyCode = code
            }
        }
        return (hk.flags.isEmpty && hk.keyCode == nil) ? nil : hk
    }

    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]

    /// True when exactly these modifiers (and the right-side bits, if any) are held.
    func modifiersHeld(_ f: CGEventFlags) -> Bool {
        guard f.intersection(Hotkey.modifierMask) == flags else { return false }
        return f.rawValue & deviceBits == deviceBits
    }
}

// MARK: - State

enum Mode { case plain, cleanup }
enum State { case idle, recording(Mode), transcribing }

struct Transcript {
    let date: Date
    let text: String
}

// MARK: - Floating waveform panel

/// What the card is currently showing.
enum PanelState { case wave, discard, busy, result }

final class WaveView: NSView {
    var state: PanelState = .wave
    var currentLevel: CGFloat = 0   // latest mic level from the tap
    private var smoothLevel: CGFloat = 0    // eased mic level; the bars follow this, not the raw tap
    private var bars: [CGFloat] = []        // scrolled history, oldest first
    private var ticks = 0
    private var phase = 0.0                 // transcribing-spindle clock
    var resultText = ""
    var footerLeft = "Ultra"
    var footerDim = false                   // transcribing dims the whole footer
    var footerRight: [(String, String?)] = []   // (label, keycap)

    // Card geometry: 428x120, thin bars on a 3pt pitch.
    static let inset: CGFloat = 24
    static let pitch: CGFloat = 3
    static let barW: CGFloat = 1.5
    static let footerH: CGFloat = 40
    static let radius: CGFloat = 18

    var waveArea: NSRect {
        NSRect(x: Self.inset, y: Self.footerH + 4,
               width: bounds.width - 2 * Self.inset, height: bounds.height - Self.footerH - 18)
    }
    private var slots: Int { max(2, Int(waveArea.width / Self.pitch)) }

    private static var iconCache: [String: NSImage] = [:]
    private func symbol(_ name: String, size: CGFloat = 12) -> NSImage? {
        let key = "\(name)-\(size)"
        if let img = Self.iconCache[key] { return img }
        guard let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let img = icon.withSymbolConfiguration(cfg) ?? icon
        img.isTemplate = true
        Self.iconCache[key] = img
        return img
    }

    override var isFlipped: Bool { false }

    func reset() {
        state = .wave
        bars = []
        smoothLevel = 0
        currentLevel = 0
        ticks = 0
        phase = 0
    }

    /// One animation frame. Recording: the wave is a ticker of the last few
    /// seconds - a new bar lands at the right edge every ~80ms and the rest
    /// slide left, so words read as spindle-shaped blobs.
    /// Transcribing: the bars form a soft breathing spindle in the center.
    func tick() {
        switch state {
        case .wave:
            smoothLevel += (currentLevel - smoothLevel) * (currentLevel > smoothLevel ? 0.35 : 0.12)
            ticks += 1
            if ticks % 5 == 0 {
                bars.append(min(1, pow(smoothLevel * 1.35, 0.9)))
                if bars.count > slots { bars.removeFirst(bars.count - slots) }
            }
        case .busy:
            phase += 1.0 / 30
        case .discard, .result:
            return   // static cards, nothing to animate
        }
        // Only the bars move frame to frame; leave the card and footer alone.
        setNeedsDisplay(waveArea.insetBy(dx: 0, dy: -4))
    }

    override func draw(_ rect: NSRect) {
        let b = bounds
        // Near-opaque dark wash over the blur, plus a hairline border.
        // (The soft edge translucency comes from the NSVisualEffectView behind us.)
        let card = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        NSColor(calibratedWhite: 0.07, alpha: 0.55).setFill(); card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke(); card.lineWidth = 1; card.stroke()

        drawFooter(rect)

        switch state {
        case .wave, .busy: drawBars()
        case .discard: drawDiscard()
        case .result: drawResult()
        }
    }

    /// Footer row: no band, no divider - just a dim
    /// icon + mode name on the left and labels + keycaps on the right.
    /// The 60fps tick only dirties the wave area, so this text layout runs
    /// just on full redraws (state changes/resize), not every frame.
    private func drawFooter(_ rect: NSRect) {
        guard rect.minY < Self.footerH else { return }
        let footer = NSRect(x: 10, y: 2, width: bounds.width - 20, height: Self.footerH - 4)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let dimA: CGFloat = footerDim ? 0.28 : 0.45
        let dim = NSColor(calibratedWhite: 1, alpha: dimA)
        let bright = NSColor(calibratedWhite: 1, alpha: footerDim ? 0.55 : 0.9)

        if let img = symbol("mic.fill", size: 12) {
            let r = NSRect(x: footer.minX + 14, y: footer.midY - 7, width: 15, height: 14)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: dimA, respectFlipped: true, hints: nil)
        }
        (footerLeft as NSString).draw(at: NSPoint(x: footer.minX + 38, y: footer.midY - 8),
                                      withAttributes: [.font: font, .foregroundColor: dim])

        // Right side, e.g. "Stop [⌘][⌥][Space]  Cancel [esc]", laid out right-to-left.
        var x = footer.maxX - 14
        for (label, cap) in footerRight.reversed() {
            if let cap = cap {
                let capFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let w = (cap as NSString).size(withAttributes: [.font: capFont]).width + 14
                let capRect = NSRect(x: x - w, y: footer.midY - 10, width: w, height: 20)
                NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
                NSBezierPath(roundedRect: capRect, xRadius: 5, yRadius: 5).fill()
                (cap as NSString).draw(at: NSPoint(x: capRect.minX + 7, y: capRect.midY - 7.5),
                                       withAttributes: [.font: capFont, .foregroundColor: bright])
                x = capRect.minX - 5
            }
            if !label.isEmpty {
                let w = (label as NSString).size(withAttributes: [.font: font]).width
                (label as NSString).draw(at: NSPoint(x: x - w, y: footer.midY - 8),
                                         withAttributes: [.font: font, .foregroundColor: dim])
                x -= w + 18
            }
        }
    }

    /// Thin bars mirrored around the centerline; quiet bars collapse to dots,
    /// so silence reads as a dotted line edge to edge.
    private func drawBars() {
        let area = waveArea
        let n = slots
        var levels = [CGFloat](repeating: 0, count: n)
        switch state {
        case .wave:
            // Right-aligned history plus a live bar hugging the right edge.
            let recent = bars.suffix(n - 1)
            let start = n - 1 - recent.count
            for (i, v) in recent.enumerated() { levels[start + i] = v }
            levels[n - 1] = min(1, pow(smoothLevel * 1.35, 0.9))
        case .busy:
            // Breathing spindle: a soft hump that drifts and swells in place.
            let c = 0.5 + 0.10 * sin(phase * 1.9)
            let w = 0.20 + 0.05 * sin(phase * 2.7 + 1)
            for i in 0..<n {
                let d = (Double(i) / Double(n - 1) - c) / w
                levels[i] = CGFloat(0.62 * exp(-d * d))
            }
        default: return
        }
        let mid = area.midY
        let maxH = area.height
        let totalW = CGFloat(n) * Self.pitch - (Self.pitch - Self.barW)
        let x0 = area.midX - totalW / 2
        for i in 0..<n {
            let lv = levels[i]
            let h = max(1.6, lv * maxH)
            let alpha: CGFloat = h <= 1.6 ? 0.30
                : state == .busy ? 0.65
                : 0.40 + 0.60 * min(1, lv * 1.5)
            NSColor(calibratedWhite: 1, alpha: alpha).setFill()
            let r = NSRect(x: x0 + CGFloat(i) * Self.pitch, y: mid - h / 2, width: Self.barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: Self.barW / 2, yRadius: Self.barW / 2).fill()
        }
    }

    /// Esc during a take: "Discard recording? [↩]" (Return discards, Esc resumes).
    private func drawDiscard() {
        let area = waveArea
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.9)]
        let text = "Discard recording?" as NSString
        let tw = text.size(withAttributes: attrs).width
        let capFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let cap = "↩" as NSString
        let capW = cap.size(withAttributes: [.font: capFont]).width + 14
        let x = area.midX - (tw + 8 + capW) / 2
        text.draw(at: NSPoint(x: x, y: area.midY - 9), withAttributes: attrs)
        let capRect = NSRect(x: x + tw + 8, y: area.midY - 10, width: capW, height: 20)
        NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
        NSBezierPath(roundedRect: capRect, xRadius: 5, yRadius: 5).fill()
        cap.draw(at: NSPoint(x: capRect.minX + 7, y: capRect.midY - 7.5),
                 withAttributes: [.font: capFont, .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.9)])
    }

    /// The finished transcript, centered on the card, with a little
    /// expand glyph in the top-right corner.
    private func drawResult() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
            .paragraphStyle: style]
        let area = waveArea.insetBy(dx: 12, dy: 0)
        let text = resultText as NSString
        let bound = text.boundingRect(with: NSSize(width: area.width, height: 38),
                                      options: [.usesLineFragmentOrigin], attributes: attrs)
        let h = min(38, bound.height)
        text.draw(in: NSRect(x: area.minX, y: area.midY - h / 2, width: area.width, height: h),
                  withAttributes: attrs)
        for name in ["arrow.down.forward.and.arrow.up.backward", "arrow.up.left.and.arrow.down.right"] {
            guard let img = symbol(name, size: 9) else { continue }
            let r = NSRect(x: bounds.maxX - 30, y: bounds.maxY - 28, width: 14, height: 12)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
            break
        }
    }
}

final class WavePanel: NSPanel {
    let wave = WaveView()
    private var timer: Timer?
    private var closeTimer: Timer?   // auto-fades the result card

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 428, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = false
        isMovableByWindowBackground = true   // grab anywhere on the card and drag
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Frosted-glass card: system blur of whatever is behind the panel,
        // clipped to the rounded shape. WaveView draws on top of it.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = WaveView.radius
        effect.layer?.masksToBounds = true
        contentView = effect
        wave.frame = effect.bounds
        wave.autoresizingMask = [.width, .height]
        effect.addSubview(wave)

        // If the display layout shifts while the panel is up (wake, monitor
        // plug/unplug, resolution change), put it back somewhere visible.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.place()
        }
    }

    private func keycaps(_ hotkey: String) -> [(String, String?)] {
        hotkey.split(separator: "+").map { ("", keycap(String($0))) }
    }

    func show(mode: Mode, hotkey: String) {
        closeTimer?.invalidate(); closeTimer = nil
        wave.reset()
        wave.footerDim = false
        wave.footerLeft = mode == .cleanup ? "Cleanup" : "Ultra"
        wave.footerRight = [("Stop", nil)] + keycaps(hotkey) + [("Cancel", "esc")]
        place()
        wave.needsDisplay = true
        // The card fades in quickly rather than popping.
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }
        schedule(fps: 60)
        // Right after a wake the window server can drop the panel somewhere
        // stale; one more place() after things settle brings it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isVisible else { return }
            self.place()
        }
    }

    /// Esc during a take: ask before throwing the recording away.
    func discardPrompt(hotkey: String) {
        wave.state = .discard
        wave.footerRight = [("Stop", nil)] + keycaps(hotkey) + [("Continue", "esc")]
        wave.needsDisplay = true
    }

    /// Esc again on the prompt: back to the live waveform.
    func resumeWave(hotkey: String) {
        wave.state = .wave
        wave.footerRight = [("Stop", nil)] + keycaps(hotkey) + [("Cancel", "esc")]
        wave.needsDisplay = true
    }

    func transcribing() {
        wave.state = .busy
        wave.footerDim = true
        wave.footerRight = [("Close", "esc")]
        wave.needsDisplay = true
        schedule(fps: 30)
    }

    /// Show the finished transcript on the card for a beat, then fade away.
    func showResult(_ text: String) {
        timer?.invalidate(); timer = nil
        wave.state = .result
        wave.resultText = text.replacingOccurrences(of: "\n", with: " ")
        wave.footerDim = false
        wave.footerRight = [("Close", "esc")]
        wave.needsDisplay = true
        closeTimer?.invalidate()
        let t = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in self?.hide() }
        RunLoop.main.add(t, forMode: .common)
        closeTimer = t
    }

    private func schedule(fps: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.wave.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate(); timer = nil
        closeTimer?.invalidate(); closeTimer = nil
        guard isVisible else { return }
        // Quick whole-card fade on the way out.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }   // a new show() won the race
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }

    func push(level: CGFloat) {
        wave.currentLevel = level
    }

    // Wherever you drag it to is where it comes back next time.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panelOrigin")
    }

    private func place() {
        // Preferred spot: wherever it was dragged last, else bottom-center
        // of the screen with the mouse.
        var screen: NSScreen?
        var o = NSPoint.zero
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            o = NSPointFromString(saved)
            screen = NSScreen.screens.first { $0.visibleFrame.intersects(NSRect(origin: o, size: frame.size)) }
        }
        if screen == nil {
            let mouse = NSEvent.mouseLocation
            let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            o = NSPoint(x: s.visibleFrame.midX - frame.width / 2, y: s.visibleFrame.minY + 90)
            screen = s
        }
        // Clamp the whole card onto that screen. A stale frame after a
        // sleep/wake once stranded the panel at x=2606 on a 1440-wide screen:
        // dictation kept working with no visualizer in sight.
        if let f = screen?.visibleFrame {
            o.x = min(max(o.x, f.minX), max(f.minX, f.maxX - frame.width))
            o.y = min(max(o.y, f.minY), max(f.minY, f.maxY - frame.height))
        }
        setFrameOrigin(o)
    }

    private func keycap(_ tok: String) -> String {
        switch tok.lowercased() {
        case "cmd", "command", "lcmd", "rcmd", "meta": return "⌘"
        case "alt", "opt", "option", "lalt", "ralt", "lopt", "ropt", "loption", "roption": return "⌥"
        case "shift", "lshift", "rshift": return "⇧"
        case "ctrl", "control", "lctrl", "rctrl": return "⌃"
        case "space": return "Space"
        default: return tok.capitalized
        }
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = Config.load()
    var recordHK: Hotkey!
    var cleanupHK: Hotkey!

    var statusItem: NSStatusItem!
    var state: State = .idle { didSet { DispatchQueue.main.async { self.refreshIcon() } } }
    var discardPrompt = false   // Esc during a take shows "Discard recording?"
    var history: [Transcript] = []

    var tap: CFMachPort?
    let panel = WavePanel()
    var ffmpeg: Process?
    var wavPath: URL?
    var recordStart: Date?
    let work = DispatchQueue(label: "ultrawhisper.work")

    static let dictationDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Dictation", isDirectory: true)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let r = Hotkey.parse(cfg.recordHotkey) else { fatal("Bad recordHotkey in config.json: \(cfg.recordHotkey)") }
        guard let c = Hotkey.parse(cfg.cleanupHotkey) else { fatal("Bad cleanupHotkey in config.json: \(cfg.cleanupHotkey)") }
        recordHK = r; cleanupHK = c

        // Transcripts are private: owner-only dir, and log() keeps files 600.
        try? FileManager.default.createDirectory(at: App.dictationDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: App.dictationDir.path)
        loadHistory()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        // Accessibility is what lets us watch keys globally and press Cmd+V.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            // Keep polling until the user flips the switch, then install the tap.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                if AXIsProcessTrusted() { t.invalidate(); self.installTap() }
            }
        } else {
            installTap()
        }
        if checkModel(quiet: true) { startServer() }
    }

    func applicationWillTerminate(_ note: Notification) { server?.terminate() }

    // MARK: Transcription server (model stays loaded in RAM between presses)

    var server: Process?
    var serverIsParakeet = false
    var serverURL: URL { URL(string: "http://127.0.0.1:\(cfg.serverPort)/inference")! }
    var parakeetWS: URL { URL(string: "ws://127.0.0.1:\(cfg.serverPort)")! }

    func parakeetReady() -> Bool {
        [Config.parakeetServerBin, Config.parakeetEncoder, Config.parakeetDecoder,
         Config.parakeetJoiner, Config.parakeetTokens]
            .allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    func startServer() {
        server?.terminate()
        // Kill any orphan from a previous run (a killed app doesn't take its helper with it).
        for pattern in ["whisper-server.*--port \(cfg.serverPort)",
                        "offline-websocket-server.*--port=\(cfg.serverPort)"] {
            _ = run("/usr/bin/pkill", ["-f", pattern])
        }

        // Preferred: Parakeet TDT v3 via sherpa-onnx (fully local, beats
        // whisper large-v3 on accuracy, ~0.3s per take once warm).
        if cfg.engineName == "parakeet", parakeetReady() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Config.parakeetServerBin)
            p.arguments = ["--port=\(cfg.serverPort)",
                           "--encoder=\(Config.parakeetEncoder)", "--decoder=\(Config.parakeetDecoder)",
                           "--joiner=\(Config.parakeetJoiner)", "--tokens=\(Config.parakeetTokens)",
                           "--model-type=nemo_transducer", "--num-threads=\(cfg.threads)"]
            var env = ProcessInfo.processInfo.environment
            env["DYLD_LIBRARY_PATH"] = Config.sherpaRoot + "/lib"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); server = p; serverIsParakeet = true; return }
            catch { NSLog("UltraWhisper: parakeet server failed: \(error)") }
        }

        // Fallback: whisper-server.
        let exe = URL(fileURLWithPath: cfg.whisperPath).deletingLastPathComponent().appendingPathComponent("whisper-server")
        guard FileManager.default.fileExists(atPath: exe.path) else {
            NSLog("UltraWhisper: no whisper-server next to whisper-cli; falling back to whisper-cli per press")
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-m", cfg.modelPath, "-t", String(cfg.threads), "-l", cfg.language,
                       "--host", "127.0.0.1", "--port", String(cfg.serverPort)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); server = p; serverIsParakeet = false } catch { NSLog("UltraWhisper: whisper-server failed: \(error)") }
    }

    func serverAlive() -> Bool {
        guard let s = server, s.isRunning else { return false }
        return true
    }

    func fatal(_ msg: String) -> Never {
        let a = NSAlert(); a.messageText = "UltraWhisper"; a.informativeText = msg; a.runModal()
        exit(1)
    }

    // MARK: Event tap

    func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let app = Unmanaged<App>.fromOpaque(refcon!).takeUnretainedValue()
            return app.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else {
            NSLog("UltraWhisper: could not create event tap (Accessibility not granted?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)

        let chords: [(Hotkey, Mode)] = [(cleanupHK!, .cleanup), (recordHK!, .plain)]
        let escape: Int64 = 53

        switch state {
        case .idle:
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return Unmanaged.passUnretained(event) }
                // Esc closes a lingering result card early.
                if key == escape, panel.isVisible {
                    DispatchQueue.main.async { self.panel.hide() }
                    return nil
                }
                for (hk, mode) in chords where hk.keyCode == key && hk.modifiersHeld(flags) {
                    startRecording(mode)
                    return nil   // swallow so the app underneath never sees it
                }
            } else if type == .keyUp {
                // Swallow the matching key-up too, so Finder never sees a full press.
                for (hk, _) in chords where hk.keyCode == key && hk.modifiersHeld(flags) { return nil }
            } else if type == .flagsChanged {
                for (hk, mode) in chords where hk.keyCode == nil && hk.modifiersHeld(flags) {
                    startRecording(mode)
                    break
                }
            }
        case .recording:
            // Tap the chord again to stop and paste. Esc asks first:
            // Return discards, Esc again resumes.
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                let returnKey: Int64 = 36
                if key == escape {
                    discardPrompt.toggle()
                    let showing = discardPrompt
                    DispatchQueue.main.async {
                        if showing { self.panel.discardPrompt(hotkey: self.cfg.recordHotkey) }
                        else { self.panel.resumeWave(hotkey: self.cfg.recordHotkey) }
                    }
                    return nil
                }
                if key == returnKey, discardPrompt { cancelRecording(); return nil }
                for (hk, _) in chords where hk.keyCode == key && hk.modifiersHeld(flags) {
                    stopRecording(); return nil
                }
            } else if type == .keyUp {
                if key == escape { return nil }
                for (hk, _) in chords where hk.keyCode == key { return nil }
            } else if type == .flagsChanged {
                for (hk, _) in chords where hk.keyCode == nil && hk.modifiersHeld(flags) {
                    stopRecording(); break
                }
            }
        case .transcribing:
            // Esc dismisses the card early; the transcription still finishes
            // and pastes in the background.
            if type == .keyDown, key == escape {
                DispatchQueue.main.async { self.panel.hide() }
                return nil
            }
            if type == .keyUp, key == escape { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Recording

    func startRecording(_ mode: Mode) {
        guard checkModel(quiet: false) else { return }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultrawhisper-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.ffmpegPath)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                       "-f", "avfoundation", "-i", ":\(cfg.audioDevice)",
                       "-ac", "1", "-ar", "16000", "-sample_fmt", "s16", "-y", path.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            alert("Couldn't start ffmpeg at \(cfg.ffmpegPath): \(error.localizedDescription)")
            return
        }
        ffmpeg = p; wavPath = path; recordStart = Date()
        discardPrompt = false
        state = .recording(mode)
        if cfg.sounds { NSSound(named: "Tink")?.play() }
        DispatchQueue.main.async {
            self.panel.show(mode: mode, hotkey: self.cfg.recordHotkey)
            self.startMeter()
        }
    }

    func cancelRecording() {
        guard case .recording = state, let p = ffmpeg, let wav = wavPath else { return }
        ffmpeg = nil; wavPath = nil
        discardPrompt = false
        state = .idle
        DispatchQueue.main.async { self.stopMeter(); self.panel.hide() }
        work.async {
            p.interrupt(); p.waitUntilExit()
            try? FileManager.default.removeItem(at: wav)
        }
    }

    // Live mic level for the waveform. ffmpeg does the real recording; this
    // AVAudioEngine tap only measures loudness and never touches disk.
    var engine: AVAudioEngine?
    func startMeter() {
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 1e-6))
            let level = min(1, max(0, (db + 50) / 40))   // -50 dB..-10 dB -> 0..1
            DispatchQueue.main.async { self.panel.push(level: CGFloat(level)) }
        }
        do { try e.start(); engine = e } catch { NSLog("UltraWhisper meter: \(error)") }
    }
    func stopMeter() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    func stopRecording() {
        guard case .recording(let mode) = state, let p = ffmpeg, let wav = wavPath else { return }
        let elapsed = Date().timeIntervalSince(recordStart ?? Date())
        discardPrompt = false
        state = .transcribing
        if cfg.sounds { NSSound(named: "Pop")?.play() }
        ffmpeg = nil; wavPath = nil
        DispatchQueue.main.async { self.stopMeter(); self.panel.transcribing() }

        work.async {
            // SIGINT makes ffmpeg finish the wav header cleanly.
            p.interrupt()
            p.waitUntilExit()
            // Whatever happens below, the take never leaves the panel stuck
            // on the spindle and the audio never sticks around.
            var pasted = false
            defer {
                try? FileManager.default.removeItem(at: wav)
                self.state = .idle
                if !pasted { DispatchQueue.main.async { self.panel.hide() } }
            }

            guard elapsed >= self.cfg.minSeconds else { return }
            var text = self.transcribe(wav)
            guard !text.isEmpty else {
                // Nothing intelligible; say so out loud instead of hanging.
                if self.cfg.sounds { DispatchQueue.main.async { NSSound(named: "Basso")?.play() } }
                return
            }

            if mode == .cleanup, let cleaned = self.cleanup(text) { text = cleaned }

            self.paste(text)
            self.log(text)
            pasted = true
            DispatchQueue.main.async {
                self.history.insert(Transcript(date: Date(), text: text), at: 0)
                if self.history.count > 10 { self.history.removeLast(self.history.count - 10) }
                // The card shows what it typed, then fades away on its
                // own (skipped if Esc already dismissed it).
                if self.panel.isVisible { self.panel.showResult(text) }
            }
        }
    }

    // MARK: Transcribe

    func transcribe(_ wav: URL) -> String {
        // The warm server answers in ~0.3s. Right after launch it may still be
        // loading the model, so retry briefly before falling back to the CLI.
        if serverAlive() {
            // Decode the audio once; only the network part retries.
            let payload = serverIsParakeet ? parakeetPayload(wav) : nil
            for wait: TimeInterval in [0, 0.4, 0.8, 1.6, 3.2] {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let text: String?
                if serverIsParakeet {
                    guard let payload = payload else { break }
                    text = transcribeViaParakeet(payload)
                } else {
                    text = transcribeViaServer(wav)
                }
                if let text = text { return clean(text) }
                if !serverAlive() { break }
            }
        } else {
            DispatchQueue.main.async { self.startServer() }   // heal it for the next take
        }
        let (out, _, _) = run(cfg.whisperPath, [
            "-m", cfg.modelPath, "-f", wav.path, "-l", cfg.language,
            "-t", String(cfg.threads), "-nt", "-np",
        ])
        return clean(out)
    }

    /// Drops [BLANK_AUDIO], (music), [MUSIC] and friends; joins lines.
    func clean(_ out: String) -> String {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("(") }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// sherpa-onnx offline websocket payload:
    /// [u32 sample-rate][u32 byte-count][float32 samples in -1..1].
    func parakeetPayload(_ wav: URL) -> Data? {
        guard let f = try? AVAudioFile(forReading: wav),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                         frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil,
              let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength)
        var payload = Data(capacity: 8 + n * 4)
        withUnsafeBytes(of: UInt32(f.processingFormat.sampleRate).littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(n * 4).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(Data(bytes: ch, count: n * 4))
        return payload
    }

    /// One binary message in, one JSON message (carrying the transcript) out.
    func transcribeViaParakeet(_ payload: Data) -> String? {
        let task = URLSession.shared.webSocketTask(with: parakeetWS)
        task.resume()
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        task.send(.data(payload)) { err in
            if err != nil { sem.signal(); return }
            task.receive { msg in
                defer { sem.signal() }
                var raw: String?
                if case .success(.string(let s)) = msg { raw = s }
                if case .success(.data(let d)) = msg { raw = String(data: d, encoding: .utf8) }
                guard let raw = raw else { return }
                if let data = raw.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    result = text
                } else {
                    result = raw
                }
            }
        }
        if sem.wait(timeout: .now() + 15) == .timedOut { task.cancel(); return nil }
        task.cancel(with: .normalClosure, reason: nil)
        return result
    }

    func transcribeViaServer(_ wav: URL) -> String? {
        guard let data = try? Data(contentsOf: wav) else { return nil }
        let boundary = "ultrawhisper-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "text")
        field("no_timestamps", "true")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: serverURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { d, r, e in
            defer { sem.signal() }
            guard let d = d, e == nil, (r as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("UltraWhisper server error: \(e?.localizedDescription ?? "http")"); return
            }
            result = String(data: d, encoding: .utf8)
        }.resume()
        sem.wait()
        return result
    }

    // MARK: Cleanup (optional LLM pass — local Ollama or xAI Grok ONLY;
    // this app never talks to OpenAI, Google, or Anthropic endpoints)

    func cleanup(_ text: String) -> String? {
        let env = Config.env()
        var req: URLRequest
        var body: [String: Any]
        var extract: ([String: Any]) -> String?

        if let model = env["OLLAMA_MODEL"], !model.isEmpty {
            // Fully local: talks only to an Ollama server on this Mac.
            req = URLRequest(url: URL(string: env["OLLAMA_URL"] ?? "http://127.0.0.1:11434/api/chat")!)
            body = ["model": model, "stream": false,
                    "messages": [["role": "system", "content": cfg.cleanupPrompt],
                                 ["role": "user", "content": text]]]
            extract = { json in
                ((json["message"] as? [String: Any])?["content"] as? String)
            }
        } else if let key = env["XAI_API_KEY"], !key.isEmpty {
            req = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
            req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": env["LLM_MODEL"] ?? "grok-4-fast-non-reasoning",
                    "messages": [["role": "system", "content": cfg.cleanupPrompt],
                                 ["role": "user", "content": text]]]
            extract = { json in
                (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
            }
        } else {
            return nil   // no provider configured: cleanup mode is just a plain paste
        }

        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            guard let data = data, err == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("UltraWhisper cleanup failed: \(err?.localizedDescription ?? "no data")"); return
            }
            if let s = extract(json)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                result = s
            } else {
                NSLog("UltraWhisper cleanup: unexpected response shape (body not logged)")
            }
        }.resume()
        sem.wait()
        return result
    }

    // MARK: Paste + clipboard restore

    func paste(_ text: String) {
        let pb = NSPasteboard.general
        // Snapshot everything on the clipboard (all items, all flavors).
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the target app a moment to read the clipboard before we put the old stuff back.
        Thread.sleep(forTimeInterval: 0.35)
        pb.clearContents()
        if !saved.isEmpty {
            let items: [NSPasteboardItem] = saved.map { d in
                let it = NSPasteboardItem()
                for (t, data) in d { it.setData(data, forType: t) }
                return it
            }
            pb.writeObjects(items)
        }
    }

    // MARK: Log + history

    static let monthFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()
    static let stampFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    func log(_ text: String) {
        let now = Date()
        let file = App.dictationDir.appendingPathComponent("\(App.monthFmt.string(from: now)).md")
        let line = "- **\(App.stampFmt.string(from: now))** \(text)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? ("# Dictation \(App.monthFmt.string(from: now))\n\n" + line).write(to: file, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func loadHistory() {
        let file = App.dictationDir.appendingPathComponent("\(App.monthFmt.string(from: Date())).md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let entries = text.split(separator: "\n").compactMap { line -> Transcript? in
            guard line.hasPrefix("- **"), let close = line.range(of: "** ") else { return nil }
            let stamp = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
            guard let d = App.stampFmt.date(from: stamp) else { return nil }
            return Transcript(date: d, text: String(line[close.upperBound...]))
        }
        history = Array(entries.suffix(10).reversed())
    }

    // MARK: Menu

    /// Menu bar glyph: the app-icon five bars (tall, low, mid, low, tall).
    /// Template image, so the bar tints it.
    static let glyph: NSImage = {
        let size: CGFloat = 22
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            // App-icon rects (1024 grid, center 512) mapped onto 22pt, y-up.
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (287, 292, 440), (391, 530, 202), (495, 362, 291),
                (599, 530, 202), (703, 292, 440)]
            let s: CGFloat = 0.034
            NSColor.black.setFill()
            for b in bars {
                let w = 34 * s
                let h = b.h * s
                let x = 11 + (b.x + 17 - 512) * s - w / 2
                let yTop = 11 + (512 - b.y) * s        // y-up: icon-grid top edge
                NSRect(x: x, y: yTop - h, width: w, height: h).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()

    func refreshIcon() {
        guard let b = statusItem.button else { return }
        let (tint, tip): (NSColor?, String)
        switch state {
        case .idle: (tint, tip) = (nil, "UltraWhisper: press \(cfg.recordHotkey) to dictate")
        case .recording: (tint, tip) = (.systemRed, "Recording…")
        case .transcribing: (tint, tip) = (.systemOrange, "Transcribing…")
        }
        b.image = App.glyph
        b.contentTintColor = tint
        b.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch state {
        case .idle: status = "Idle · press \(cfg.recordHotkey)"
        case .recording(let m): status = m == .cleanup ? "Recording (cleanup mode)…" : "Recording…"
        case .transcribing: status = "Transcribing…"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if history.isEmpty {
            menu.addItem(withTitle: "No transcripts yet", action: nil, keyEquivalent: "")
        } else {
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            for (i, t) in history.enumerated() {
                var preview = t.text.replacingOccurrences(of: "\n", with: " ")
                if preview.count > 70 { preview = String(preview.prefix(70)) + "…" }
                let it = NSMenuItem(title: "\(tf.string(from: t.date))  \(preview)",
                                    action: #selector(copyTranscript(_:)), keyEquivalent: "")
                it.target = self; it.tag = i
                it.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
                it.toolTip = "Click to copy:\n\(t.text)"
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Dictation Folder", action: #selector(openDictation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config Folder", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "").target = self
        if !FileManager.default.fileExists(atPath: cfg.modelPath) {
            menu.addItem(withTitle: "Download base.en Model (~150 MB)", action: #selector(downloadModel), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UltraWhisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func copyTranscript(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(history[sender.tag].text, forType: .string)
    }
    @objc func openDictation() { NSWorkspace.shared.open(App.dictationDir) }
    @objc func openConfig() { NSWorkspace.shared.open(Config.dir) }
    @objc func reloadConfig() {
        cfg = Config.load()
        if let r = Hotkey.parse(cfg.recordHotkey) { recordHK = r }
        if let c = Hotkey.parse(cfg.cleanupHotkey) { cleanupHK = c }
        refreshIcon()
        if checkModel(quiet: true) { startServer() }
    }

    // MARK: Model

    @discardableResult
    /// Can the selected engine transcribe? Parakeet needs its sherpa files;
    /// whisper (selected, or as the fallback) needs a ggml model, which we
    /// offer to download.
    func checkModel(quiet: Bool) -> Bool {
        if cfg.engineName == "parakeet" && parakeetReady() { return true }
        if FileManager.default.fileExists(atPath: cfg.modelPath) { return true }
        if !quiet {
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Whisper model not found"
                a.informativeText = "Expected it at:\n\(self.cfg.modelPath)\n\nDownload base.en now (about 150 MB, one time)?"
                a.addButton(withTitle: "Download"); a.addButton(withTitle: "Later")
                if a.runModal() == .alertFirstButtonReturn { self.downloadModel() }
            }
        }
        return false
    }

    @objc func downloadModel() {
        let name = URL(fileURLWithPath: cfg.modelPath).lastPathComponent
        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)"
        let dest = cfg.modelPath
        state = .transcribing   // reuse the "busy" icon while downloading
        work.async {
            let (_, err, code) = self.run("/usr/bin/curl", ["-L", "--fail", "--progress-bar", "-o", dest + ".part", url])
            if code == 0 {
                try? FileManager.default.removeItem(atPath: dest)
                try? FileManager.default.moveItem(atPath: dest + ".part", toPath: dest)
                self.notify("Model ready", "\(name) downloaded. Press \(self.cfg.recordHotkey) to dictate.")
                DispatchQueue.main.async { self.startServer() }
            } else {
                try? FileManager.default.removeItem(atPath: dest + ".part")
                self.alert("Model download failed (curl exit \(code)).\n\(err.suffix(300))")
            }
            self.state = .idle
        }
    }

    // MARK: Helpers

    func run(_ exe: String, _ args: [String]) -> (String, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ("", "\(error)", -1) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? "", p.terminationStatus)
    }

    func alert(_ msg: String) {
        DispatchQueue.main.async {
            let a = NSAlert(); a.messageText = "UltraWhisper"; a.informativeText = msg; a.runModal()
        }
    }

    func notify(_ title: String, _ body: String) {
        // Plain osascript notification: no UserNotifications entitlement dance needed.
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        _ = run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
