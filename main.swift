// UltraWhisper - local push-to-talk dictation for macOS.
//
// Tap the hotkey, talk, tap again. Mic PCM (AVAudioEngine, 16 kHz in RAM) is
// segmented on pauses and decoded while you speak (FluidAudio Parakeet TDT
// on the Neural Engine), then pasted via clipboard -> Cmd+V into whatever
// has focus, then the old clipboard comes back.
// Everything runs on this Mac; nothing leaves it unless you opt into
// cleanup mode in ~/.config/ultrawhisper/.env (local Ollama, or xAI Grok —
// never OpenAI/Google/Anthropic endpoints).
//
// Build: ./build.sh   (see README.md)

import AppKit
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
    var parakeetModel: String?   // folder under models/; nil = best installed build
    var hotwordsScore: Double?   // set (e.g. 1) to turn on vocabulary.txt hotwords; nil = off

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ultrawhisper", isDirectory: true)
    static let file = dir.appendingPathComponent("config.json")
    static let envFile = dir.appendingPathComponent(".env")
    static let modelsDir = dir.appendingPathComponent("models", isDirectory: true)
    static let vocabularyFile = dir.appendingPathComponent("vocabulary.txt")
    static let hotwordsFile = dir.appendingPathComponent(".hotwords")   // generated from vocabulary.txt
    static let replacementsFile = dir.appendingPathComponent("replacements.txt")

    var engineName: String { engine ?? "parakeet" }

    static var defaults: Config {
        Config(
            modelPath: modelsDir.appendingPathComponent("ggml-base.en.bin").path,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            whisperPath: "/opt/homebrew/bin/whisper-cli",
            audioDevice: "0",
            threads: 4,
            serverPort: 8765,
            language: "en",
            recordHotkey: "alt+space",
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

    /// replacements.txt: one `heard -> wanted` per line, # comments allowed.
    /// The left side matches whole words, ignoring case; the right side is
    /// pasted exactly. Plain find-and-replace, no AI, so it only ever touches
    /// the words you listed.
    static func loadReplacements() -> [(NSRegularExpression, String)] {
        var rules: [(NSRegularExpression, String)] = []
        for t in lines(of: replacementsFile) {
            guard let arrow = t.range(of: "->") else { continue }
            let from = t[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = t[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { continue }
            // \b needs a word character on each side; fall back to plain lookarounds for things like "c++".
            let pat = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\w])"
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                rules.append((re, NSRegularExpression.escapedTemplate(for: to)))
            }
        }
        return rules
    }

    static func applyReplacements(_ rules: [(NSRegularExpression, String)], to text: String) -> String {
        var out = text
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    /// Starter files, written once alongside the first config.json so the
    /// folder explains itself. Deleting one later keeps it gone.
    static func writeTemplates() {
        let templates = [
            (vocabularyFile, """
            # Words Parakeet should lean toward when unsure. One per line.
            # Unused until FluidAudio vocabulary boosting is wired. See README.
            UltraWhisper

            """),
            (replacementsFile, """
            # Plain find-and-replace on every take: heard -> wanted
            # Left side matches whole words, any capitalization. No AI involved.
            ultra whisper -> UltraWhisper

            """),
        ]
        for (url, text) in templates where !FileManager.default.fileExists(atPath: url.path) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
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
        writeTemplates()
        return cfg
    }

    /// Non-blank, non-comment lines of a text file, trimmed. Missing file = [].
    static func lines(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Reads KEY=VALUE lines from ~/.config/ultrawhisper/.env (no accounts, no telemetry).
    static func env() -> [String: String] {
        var out: [String: String] = [:]
        for line in lines(of: envFile) {
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

/// One Option+Space take. `gen` lets Esc discard drop in-flight segment jobs.
final class StreamTake {
    let gen: Int
    var texts: [String] = []
    var decodeMs: Double = 0
    var unhealthy = false
    init(gen: Int) { self.gen = gen }
}


// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = Config.load()
    var replacements = Config.loadReplacements()
    var recordHK: Hotkey!
    var cleanupHK: Hotkey!

    var statusItem: NSStatusItem!
    var state: State = .idle { didSet { DispatchQueue.main.async { self.refreshIcon() } } }
    var discardPrompt = false   // Esc during a take shows "Discard recording?"
    var history: [Transcript] = []

    var tap: CFMachPort?
    let panel = WavePanel()
    let capture = Capture()
    let segmenter = Segmenter()
    let work = DispatchQueue(label: "ultrawhisper.work")
    var takeGen = 0
    var take: StreamTake?

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
        capture.onLevel = { [weak self] level in self?.panel.push(level: level) }

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
        if checkModel(quiet: true) { startEngine() }
    }

    func applicationWillTerminate(_ note: Notification) {
        takeGen += 1
        take = nil
        _ = capture.stop()
        server?.terminate()
    }

    // MARK: Engine (FluidAudio in-process; whisper-server only if engine is whisper)

    let parakeet = ParakeetEngine()
    var server: Process?
    var serverURL: URL { URL(string: "http://127.0.0.1:\(cfg.serverPort)/inference")! }

    func startEngine() {
        server?.terminate(); server = nil
        _ = run("/usr/bin/pkill", ["-f", "whisper-server.*--port \(cfg.serverPort)"])
        if cfg.engineName == "parakeet" {
            parakeet.start()
            return
        }
        startWhisperServer()
    }

    func startWhisperServer() {
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
        takeGen += 1
        let gen = takeGen
        take = StreamTake(gen: gen)
        segmenter.reset()
        capture.onChunk = { [weak self] chunk in
            self?.work.async { self?.ingest(chunk, gen: gen) }
        }
        guard capture.start() else {
            take = nil
            capture.onChunk = nil
            alert("Couldn't open the microphone.")
            return
        }
        discardPrompt = false
        state = .recording(mode)
        if cfg.sounds { NSSound(named: "Tink")?.play() }
        DispatchQueue.main.async {
            self.panel.show(mode: mode, hotkey: self.cfg.recordHotkey)
        }
    }

    func cancelRecording() {
        guard case .recording = state else { return }
        discardPrompt = false
        takeGen += 1
        take = nil
        state = .idle
        _ = capture.stop()
        work.async { self.segmenter.reset() }
        DispatchQueue.main.async { self.panel.hide() }
    }

    func stopRecording() {
        guard case .recording(let mode) = state else { return }
        discardPrompt = false
        state = .transcribing
        if cfg.sounds { NSSound(named: "Pop")?.play() }
        let samples = capture.stop()
        let gen = take?.gen ?? takeGen
        let tStop = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { self.panel.transcribing() }

        work.async { self.finishTake(samples: samples, mode: mode, gen: gen, tStop: tStop) }
    }

    func ingest(_ samples: [Float], gen: Int) {
        guard take?.gen == gen else { return }
        for chunk in segmenter.push(samples) {
            decodeSegment(chunk, gen: gen)
        }
    }

    func decodeSegment(_ chunk: Segmenter.Chunk, gen: Int) {
        guard chunk.voiced, take?.gen == gen else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let text = transcribe(chunk.samples, waitForServer: false)
        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard let take, take.gen == gen else { return }
        take.decodeMs += dt
        let secs = Double(chunk.samples.count) / Capture.sampleRate
        if text.isEmpty {
            take.unhealthy = true
            NSLog("UltraWhisper: segment %.1fs empty in %.0fms — will fall back", secs, dt)
        } else {
            take.texts.append(text)
            NSLog("UltraWhisper: segment %.1fs in %.0fms", secs, dt)
        }
    }

    func finishTake(samples: [Float], mode: Mode, gen: Int, tStop: CFAbsoluteTime) {
        var pasted = false
        defer {
            self.take = nil
            self.state = .idle
            if !pasted { DispatchQueue.main.async { self.panel.hide() } }
        }
        guard take?.gen == gen else { return }

        let overlapped = take?.decodeMs ?? 0
        let liveOk = take?.unhealthy == false && !(take?.texts.isEmpty ?? true)
        let seconds = Double(samples.count) / Capture.sampleRate
        guard seconds >= cfg.minSeconds else { return }

        var fallback = false
        var text: String
        if liveOk {
            // Pauses already decoded while talking. Only run the tail.
            if samples.count > segmenter.consumed {
                for chunk in segmenter.push(Array(samples[segmenter.consumed...])) {
                    decodeSegment(chunk, gen: gen)
                }
            }
            if let tail = segmenter.finalize() {
                decodeSegment(tail, gen: gen)
            }
            guard take?.gen == gen else { return }
            if let take, !take.unhealthy, !take.texts.isEmpty {
                text = take.texts.joined(separator: " ")
            } else {
                fallback = true
                text = transcribe(samples, waitForServer: true)
            }
        } else {
            // No live segments (two words, or no ~2s pause): one Parakeet call,
            // same as before stage 1. Do not decode the tail and then the
            // whole buffer.
            segmenter.reset()
            fallback = take?.unhealthy == true
            text = transcribe(samples, waitForServer: true)
        }

        let tAsr = CFAbsoluteTimeGetCurrent()
        guard !text.isEmpty else {
            if cfg.sounds { DispatchQueue.main.async { NSSound(named: "Basso")?.play() } }
            NSLog("UltraWhisper: %.1fs audio, overlapped=%.0fms asr=%.0fms empty fallback=%d",
                  seconds, overlapped, (tAsr - tStop) * 1000, fallback ? 1 : 0)
            return
        }

        if mode == .cleanup, let cleaned = cleanup(text) { text = cleaned }
        text = Config.applyReplacements(replacements, to: text)

        pasted = true
        DispatchQueue.main.async {
            self.history.insert(Transcript(date: Date(), text: text), at: 0)
            if self.history.count > 10 { self.history.removeLast(self.history.count - 10) }
            self.panel.hide()
        }
        paste(text)
        log(text)
        NSLog("UltraWhisper: %.1fs audio, overlapped=%.0fms asr=%.0fms paste=%.0fms segments=%d fallback=%d",
              seconds, overlapped, (tAsr - tStop) * 1000,
              (CFAbsoluteTimeGetCurrent() - tAsr) * 1000,
              take?.texts.count ?? 0, fallback ? 1 : 0)
    }

    // MARK: Transcribe

    func transcribe(_ samples: [Float], waitForServer: Bool = true) -> String {
        // FluidAudio stays loaded in-process. Right after launch it may still
        // be compiling CoreML, so retry briefly before falling back to whisper.
        // Live segments skip the retry so a miss just marks the take unhealthy
        // and the full buffer runs once at stop.
        if cfg.engineName == "parakeet" {
            let waits: [TimeInterval] = waitForServer ? [0, 0.4, 0.8, 1.6, 3.2] : [0]
            for wait in waits {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if parakeet.isReady {
                    return clean(parakeet.transcribe(samples))
                }
            }
            if !waitForServer { return "" }
            NSLog("UltraWhisper: FluidAudio not ready, falling back to whisper-cli")
        } else if serverAlive() {
            let waits: [TimeInterval] = waitForServer ? [0, 0.4, 0.8, 1.6, 3.2] : [0]
            for wait in waits {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if let text = withTempWav(samples, { self.transcribeViaServer($0) }) { return clean(text) }
                if !serverAlive() { break }
            }
        } else if waitForServer {
            DispatchQueue.main.async { self.startEngine() }
        }
        if !waitForServer { return "" }
        return withTempWav(samples) { wav in
            let (out, _, _) = self.run(self.cfg.whisperPath, [
                "-m", self.cfg.modelPath, "-f", wav.path, "-l", self.cfg.language,
                "-t", String(self.cfg.threads), "-nt", "-np",
            ])
            return self.clean(out)
        } ?? ""
    }

    /// Drops [BLANK_AUDIO], (music), [MUSIC] and friends; joins lines.
    func clean(_ out: String) -> String {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("(") }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper fallback still wants a file. Parakeet never hits this.
    func withTempWav(_ samples: [Float], _ body: (URL) -> String?) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultrawhisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeWav(samples, to: url) else { return nil }
        return body(url)
    }

    func writeWav(_ samples: [Float], to url: URL) -> Bool {
        let n = samples.count
        var data = Data()
        data.reserveCapacity(44 + n * 2)
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) { let x = v.littleEndian; withUnsafeBytes(of: x) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { let x = v.littleEndian; withUnsafeBytes(of: x) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + n * 2)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(UInt32(Capture.sampleRate)); u32(UInt32(Capture.sampleRate * 2))
        u16(2); u16(16)
        ascii("data"); u32(UInt32(n * 2))
        for s in samples {
            let x = max(-1 as Float, min(1 as Float, s))
            let v = Int16((x * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        }
        do { try data.write(to: url, options: .atomic); return true }
        catch { NSLog("UltraWhisper: wav write failed: \(error)"); return false }
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
        replacements = Config.loadReplacements()
        if let r = Hotkey.parse(cfg.recordHotkey) { recordHK = r }
        if let c = Hotkey.parse(cfg.cleanupHotkey) { cleanupHK = c }
        refreshIcon()
        if checkModel(quiet: true) { startEngine() }
    }

    // MARK: Model

    @discardableResult
    /// Can the selected engine transcribe? Parakeet downloads/compiles CoreML
    /// on first launch. Whisper needs a ggml model, which we offer to download.
    func checkModel(quiet: Bool) -> Bool {
        if cfg.engineName == "parakeet" { return true }
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
                DispatchQueue.main.async { self.startEngine() }
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
