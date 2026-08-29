// UltraWhisper - local push-to-talk dictation for macOS.
//
// Hold a hotkey, talk, let go. The audio goes ffmpeg -> whisper.cpp -> your
// clipboard -> Cmd+V into whatever has focus, then the old clipboard comes
// back. Everything runs on this Mac; nothing leaves it unless you opt into
// cleanup mode with an API key in ~/.config/ultrawhisper/.env.
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

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ultrawhisper", isDirectory: true)
    static let file = dir.appendingPathComponent("config.json")
    static let envFile = dir.appendingPathComponent(".env")
    static let modelsDir = dir.appendingPathComponent("models", isDirectory: true)

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
                + "cleaned text, no commentary, no quotes."
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

// MARK: - Floating waveform panel (Superwhisper-style)

final class WaveView: NSView {
    var levels: [CGFloat] = []
    var maxBars = 0
    var footerLeft = "UltraWhisper"
    var footerRight: [(String, String?)] = []   // (label, keycap)
    var busy = false

    override var isFlipped: Bool { false }

    override func draw(_ rect: NSRect) {
        let b = bounds
        // Card
        let card = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.11, alpha: 0.97).setFill(); card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke(); card.lineWidth = 1; card.stroke()

        // Footer strip
        let footerH: CGFloat = 40
        let footer = NSRect(x: 10, y: 10, width: b.width - 20, height: footerH)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: footer, xRadius: 12, yRadius: 12).fill()

        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let dim = NSColor(calibratedWhite: 1, alpha: 0.55)
        let bright = NSColor(calibratedWhite: 1, alpha: 0.9)

        // Left: mic glyph + label
        if let icon = NSImage(systemSymbolName: busy ? "waveform" : "mic.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let img = icon.withSymbolConfiguration(cfg) ?? icon
            let r = NSRect(x: footer.minX + 16, y: footer.midY - 8, width: 18, height: 16)
            img.isTemplate = true
            NSGraphicsContext.current?.cgContext.saveGState()
            dim.set()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        (footerLeft as NSString).draw(at: NSPoint(x: footer.minX + 46, y: footer.midY - 9),
                                      withAttributes: [.font: font, .foregroundColor: dim])

        // Right: "Stop [⌥][Space]  Cancel [esc]" laid out right-to-left
        var x = footer.maxX - 16
        for (label, cap) in footerRight.reversed() {
            if let cap = cap {
                let capFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
                let w = (cap as NSString).size(withAttributes: [.font: capFont]).width + 16
                let capRect = NSRect(x: x - w, y: footer.midY - 12, width: w, height: 24)
                NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
                NSBezierPath(roundedRect: capRect, xRadius: 6, yRadius: 6).fill()
                (cap as NSString).draw(at: NSPoint(x: capRect.minX + 8, y: capRect.midY - 8),
                                       withAttributes: [.font: capFont, .foregroundColor: bright])
                x = capRect.minX - 6
            }
            if !label.isEmpty {
                let w = (label as NSString).size(withAttributes: [.font: font]).width
                (label as NSString).draw(at: NSPoint(x: x - w, y: footer.midY - 9),
                                         withAttributes: [.font: font, .foregroundColor: dim])
                x -= w + 20
            }
        }

        // Waveform: newest sample on the right, scrolls left.
        let area = NSRect(x: 34, y: footer.maxY + 14, width: b.width - 68, height: b.height - footer.maxY - 28)
        let pitch: CGFloat = 4, barW: CGFloat = 2
        maxBars = Int(area.width / pitch)
        let mid = area.midY
        let maxH = area.height
        for i in 0..<maxBars {
            let idx = levels.count - maxBars + i
            let lv: CGFloat = idx >= 0 ? levels[idx] : 0
            let h = max(2, lv * maxH)
            let alpha: CGFloat = idx >= 0 ? (0.35 + 0.65 * lv) : 0.22
            NSColor(calibratedWhite: 1, alpha: alpha).setFill()
            let r = NSRect(x: area.minX + CGFloat(i) * pitch, y: mid - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
    }
}

final class WavePanel: NSPanel {
    let wave = WaveView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 122),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = false
        isMovableByWindowBackground = true   // grab anywhere on the card and drag
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = wave
    }

    func show(mode: Mode, hotkey: String) {
        wave.levels = []
        wave.busy = false
        wave.footerLeft = mode == .cleanup ? "Cleanup" : "Ultra"
        wave.footerRight = [("Stop", nil)] + hotkey.split(separator: "+").map { ("", keycap(String($0))) } + [("Cancel", "esc")]
        place()
        wave.needsDisplay = true
        orderFrontRegardless()
    }

    func transcribing() {
        wave.busy = true
        wave.footerLeft = "Transcribing…"
        wave.footerRight = []
        wave.needsDisplay = true
    }

    func hide() { orderOut(nil) }

    func push(level: CGFloat) {
        wave.levels.append(level)
        if wave.levels.count > 400 { wave.levels.removeFirst(wave.levels.count - 400) }
        wave.needsDisplay = true
    }

    // Wherever you drag it to is where it comes back next time.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panelOrigin")
    }

    private func place() {
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            let o = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: o, size: frame.size)) }) {
                setFrameOrigin(o); return
            }
        }
        // Bottom-center of the screen with the mouse, like Superwhisper.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 90))
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

        try? FileManager.default.createDirectory(at: App.dictationDir, withIntermediateDirectories: true)
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

    // MARK: Whisper server (model stays loaded between presses)

    var server: Process?
    var serverURL: URL { URL(string: "http://127.0.0.1:\(cfg.serverPort)/inference")! }

    func startServer() {
        server?.terminate()
        // Kill any orphan from a previous run (a killed app doesn't take its helper with it).
        _ = run("/usr/bin/pkill", ["-f", "whisper-server.*--port \(cfg.serverPort)"])
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
        do { try p.run(); server = p } catch { NSLog("UltraWhisper: whisper-server failed: \(error)") }
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
            // Tap the chord again to stop and paste; Esc throws the take away.
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                if key == escape { cancelRecording(); return nil }
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
            break
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
        state = .transcribing
        if cfg.sounds { NSSound(named: "Pop")?.play() }
        ffmpeg = nil; wavPath = nil
        DispatchQueue.main.async { self.stopMeter(); self.panel.transcribing() }

        work.async {
            // SIGINT makes ffmpeg finish the wav header cleanly.
            p.interrupt()
            p.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: wav) }   // audio never sticks around

            guard elapsed >= self.cfg.minSeconds else { self.state = .idle; return }
            var text = self.transcribe(wav)
            guard !text.isEmpty else { self.state = .idle; return }

            if mode == .cleanup, let cleaned = self.cleanup(text) { text = cleaned }

            self.paste(text)
            self.log(text)
            DispatchQueue.main.async {
                self.history.insert(Transcript(date: Date(), text: text), at: 0)
                if self.history.count > 10 { self.history.removeLast(self.history.count - 10) }
            }
            self.state = .idle
            DispatchQueue.main.async { self.panel.hide() }
        }
    }

    // MARK: Transcribe

    func transcribe(_ wav: URL) -> String {
        if serverAlive(), let text = transcribeViaServer(wav) { return clean(text) }
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
        req.timeoutInterval = 60

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

    // MARK: Cleanup (optional LLM pass)

    func cleanup(_ text: String) -> String? {
        let env = Config.env()
        var req: URLRequest
        var body: [String: Any]
        var extract: ([String: Any]) -> String?

        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty {
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.addValue(key, forHTTPHeaderField: "x-api-key")
            req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": env["LLM_MODEL"] ?? "claude-haiku-4-5-20251001",
                    "max_tokens": 2048, "system": cfg.cleanupPrompt,
                    "messages": [["role": "user", "content": text]]]
            extract = { json in
                ((json["content"] as? [[String: Any]])?.first?["text"] as? String)
            }
        } else if let key = env["OPENAI_API_KEY"], !key.isEmpty {
            req = URLRequest(url: URL(string: env["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1/chat/completions")!)
            req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": env["LLM_MODEL"] ?? "gpt-4o-mini",
                    "messages": [["role": "system", "content": cfg.cleanupPrompt],
                                 ["role": "user", "content": text]]]
            extract = { json in
                (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
            }
        } else {
            return nil   // no key: cleanup mode is just a plain paste
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
                NSLog("UltraWhisper cleanup: unexpected response \(String(data: data, encoding: .utf8) ?? "")")
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

    /// Menu bar glyph: Superwhisper's rounded triangle outline, pointing down.
    static let glyph: NSImage = {
        let size: CGFloat = 22
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let path = NSBezierPath()
            let cx = size / 2, cy = size / 2 + 0.5
            let r: CGFloat = 8.6          // distance from center to each corner
            let corner: CGFloat = 2.8     // corner rounding
            // triangle pointing down (apex at bottom)
            let pts = [NSPoint(x: cx - r * 0.95, y: cy + r * 0.5),
                       NSPoint(x: cx + r * 0.95, y: cy + r * 0.5),
                       NSPoint(x: cx, y: cy - r)]
            var mids: [NSPoint] = []
            for i in 0..<3 {
                let a = pts[i], b = pts[(i + 1) % 3]
                mids.append(NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            }
            path.move(to: mids[2])
            for i in 0..<3 { path.appendArc(from: pts[i], to: mids[i], radius: corner) }
            path.close()
            path.lineWidth = 2.5
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()

    func refreshIcon() {
        guard let b = statusItem.button else { return }
        let (name, tint, tip): (String, NSColor?, String)
        switch state {
        case .idle: (name, tint, tip) = ("mic", nil, "UltraWhisper: press \(cfg.recordHotkey) to dictate")
        case .recording: (name, tint, tip) = ("mic.fill", .systemRed, "Recording…")
        case .transcribing: (name, tint, tip) = ("waveform", .systemOrange, "Transcribing…")
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
    func checkModel(quiet: Bool) -> Bool {
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
