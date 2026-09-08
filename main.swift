// UltraWhisper - local push-to-talk dictation for macOS.
//
// Hold a hotkey, talk, let go. Mic PCM (AVAudioEngine, 16 kHz in RAM) goes
// to Parakeet TDT via sherpa-onnx (whisper.cpp as fallback) -> clipboard
// -> Cmd+V into whatever has focus, then the old clipboard comes back.
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

    // The one place the sherpa-onnx layout is spelled out.
    static let sherpaRoot = dir.appendingPathComponent("sherpa-onnx").path
    static let parakeetServerBin = sherpaRoot + "/bin/sherpa-onnx-offline-websocket-server"

    /// The build download-model.sh installs: small enough for an 8 GB Mac.
    /// The v2 fp16 build (~1.1 GB) hears takes int8 drops but costs more RAM
    /// and is only partly measured (eval/); set parakeetModel to use it.
    static let defaultParakeet = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"

    struct ParakeetFiles {
        let dir, encoder, decoder, joiner, tokens: String
        var name: String { URL(fileURLWithPath: dir).lastPathComponent }
    }

    /// The model folder to use and its files. Each build names its weights
    /// differently (encoder.fp16.onnx / encoder.int8.onnx / encoder.onnx),
    /// so look for whichever is there. nil = nothing usable installed.
    func parakeetFiles() -> ParakeetFiles? {
        let fm = FileManager.default
        let dir = Config.modelsDir.appendingPathComponent(parakeetModel ?? Config.defaultParakeet).path
        func find(_ stem: String) -> String? {
            [".int8.onnx", ".fp16.onnx", ".onnx"].map { "\(dir)/\(stem)\($0)" }.first(where: fm.fileExists)
        }
        let tokens = dir + "/tokens.txt"
        guard let e = find("encoder"), let d = find("decoder"), let j = find("joiner"),
              fm.fileExists(atPath: tokens) else { return nil }
        return ParakeetFiles(dir: dir, encoder: e, decoder: d, joiner: j, tokens: tokens)
    }

    /// Extra sherpa flags that make Parakeet favor the words in
    /// vocabulary.txt. Empty (plain greedy decoding) unless hotwordsScore is
    /// set in config.json, because on real takes it scored worse (README).
    /// Hotwords need beam search plus a sentencepiece vocab; the model ships
    /// without one, so we fabricate it from tokens.txt (equal scores =
    /// longest-match spelling).
    func hotwordArgs(for pk: ParakeetFiles) -> [String] {
        guard let score = hotwordsScore else { return [] }
        let words = Config.lines(of: Config.vocabularyFile)
        guard !words.isEmpty else { return [] }
        try? (words.joined(separator: "\n") + "\n").write(to: Config.hotwordsFile, atomically: true, encoding: .utf8)

        let vocab = pk.dir + "/bpe.vocab"
        if !FileManager.default.fileExists(atPath: vocab),
           let tokens = try? String(contentsOf: URL(fileURLWithPath: pk.tokens), encoding: .utf8) {
            let pieces = tokens.split(separator: "\n").compactMap { $0.split(separator: " ").first }
                .filter { !$0.hasPrefix("<") }
            try? pieces.map { "\($0)\t-1" }.joined(separator: "\n").write(toFile: vocab, atomically: true, encoding: .utf8)
        }
        return ["--decoding-method=modified_beam_search", "--hotwords-file=\(Config.hotwordsFile.path)",
                "--modeling-unit=bpe", "--bpe-vocab=\(vocab)", "--hotwords-score=\(score)"]
    }

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
            # Only used when config.json has "hotwordsScore" (try 1); see README.
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
        if checkModel(quiet: true) { startServer() }
    }

    func applicationWillTerminate(_ note: Notification) {
        _ = capture.stop()
        server?.terminate()
    }

    // MARK: Transcription server (model stays loaded in RAM between presses)

    var server: Process?
    var serverIsParakeet = false
    var serverURL: URL { URL(string: "http://127.0.0.1:\(cfg.serverPort)/inference")! }
    var parakeetWS: URL { URL(string: "ws://127.0.0.1:\(cfg.serverPort)")! }

    /// The Parakeet files to run, or nil when the engine isn't installed.
    func parakeetReady() -> Config.ParakeetFiles? {
        FileManager.default.fileExists(atPath: Config.parakeetServerBin) ? cfg.parakeetFiles() : nil
    }

    func startServer() {
        server?.terminate()
        // Kill any orphan from a previous run (a killed app doesn't take its helper with it).
        for pattern in ["whisper-server.*--port \(cfg.serverPort)",
                        "offline-websocket-server.*--port=\(cfg.serverPort)"] {
            _ = run("/usr/bin/pkill", ["-f", pattern])
        }

        // Preferred: Parakeet TDT via sherpa-onnx (fully local, beats
        // whisper large-v3 on accuracy, well under a second per take once warm).
        if cfg.engineName == "parakeet", let pk = parakeetReady() {
            NSLog("UltraWhisper: starting Parakeet server with \(pk.name)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Config.parakeetServerBin)
            p.arguments = ["--port=\(cfg.serverPort)",
                           "--encoder=\(pk.encoder)", "--decoder=\(pk.decoder)",
                           "--joiner=\(pk.joiner)", "--tokens=\(pk.tokens)",
                           "--model-type=nemo_transducer", "--num-threads=\(cfg.threads)"]
                + cfg.hotwordArgs(for: pk)
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
        guard capture.start() else {
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
        state = .idle
        _ = capture.stop()
        DispatchQueue.main.async { self.panel.hide() }
    }

    func stopRecording() {
        guard case .recording(let mode) = state else { return }
        discardPrompt = false
        state = .transcribing
        if cfg.sounds { NSSound(named: "Pop")?.play() }
        let samples = capture.stop()
        DispatchQueue.main.async { self.panel.transcribing() }

        work.async {
            let t0 = CFAbsoluteTimeGetCurrent()
            var pasted = false
            defer {
                self.state = .idle
                if !pasted { DispatchQueue.main.async { self.panel.hide() } }
            }

            let seconds = Double(samples.count) / Capture.sampleRate
            guard seconds >= self.cfg.minSeconds else { return }
            var text = self.transcribe(samples)
            let tAsr = CFAbsoluteTimeGetCurrent()
            guard !text.isEmpty else {
                if self.cfg.sounds { DispatchQueue.main.async { NSSound(named: "Basso")?.play() } }
                NSLog("UltraWhisper: %.1fs audio, asr=%.0fms empty", seconds, (tAsr - t0) * 1000)
                return
            }

            if mode == .cleanup, let cleaned = self.cleanup(text) { text = cleaned }
            text = Config.applyReplacements(self.replacements, to: text)

            pasted = true
            DispatchQueue.main.async {
                self.history.insert(Transcript(date: Date(), text: text), at: 0)
                if self.history.count > 10 { self.history.removeLast(self.history.count - 10) }
                self.panel.hide()
            }
            self.paste(text)
            self.log(text)
            NSLog("UltraWhisper: %.1fs audio, asr=%.0fms paste=%.0fms",
                  seconds, (tAsr - t0) * 1000, (CFAbsoluteTimeGetCurrent() - tAsr) * 1000)
        }
    }

    // MARK: Transcribe

    func transcribe(_ samples: [Float]) -> String {
        // The warm server answers in ~0.3s. Right after launch it may still be
        // loading the model, so retry briefly before falling back to the CLI.
        if serverAlive() {
            let payload = serverIsParakeet ? parakeetPayload(samples) : nil
            for wait: TimeInterval in [0, 0.4, 0.8, 1.6, 3.2] {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let text: String?
                if serverIsParakeet {
                    guard let payload = payload else { break }
                    text = transcribeViaParakeet(payload)
                } else {
                    text = withTempWav(samples) { self.transcribeViaServer($0) }
                }
                if let text = text { return clean(text) }
                if !serverAlive() { break }
            }
        } else {
            DispatchQueue.main.async { self.startServer() }   // heal it for the next take
        }
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

    /// sherpa-onnx offline websocket payload:
    /// [u32 sample-rate][u32 byte-count][float32 samples in -1..1].
    func parakeetPayload(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return nil }
        var payload = Data(capacity: 8 + samples.count * 4)
        withUnsafeBytes(of: UInt32(Capture.sampleRate).littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(samples.count * 4).littleEndian) { payload.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { payload.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return payload
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
        replacements = Config.loadReplacements()
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
        if cfg.engineName == "parakeet" && parakeetReady() != nil { return true }
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
