import AppKit

// MARK: - Floating waveform panel

/// What the card is currently showing.
enum PanelState { case wave, discard, busy }

final class WaveView: NSView {
    var state: PanelState = .wave
    var currentLevel: CGFloat = 0   // latest mic level from the tap
    private var smoothLevel: CGFloat = 0    // eased mic level; the bars follow this, not the raw tap
    private var bars: [CGFloat] = []        // scrolled history, oldest first
    private var ticks = 0
    private var phase = 0.0                 // transcribing-spindle clock
    var footerLeft = "Ultra"
    var footerDim = false                   // transcribing dims the whole footer
    var footerRight: [(String, String?)] = []   // (label, keycap)

    // Card geometry: 428x120, thin bars on a 3pt pitch.
    static let inset: CGFloat = 24
    static let pitch: CGFloat = 3
    static let barW: CGFloat = 1.5
    static let footerH: CGFloat = 40
    static let radius: CGFloat = 32

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
        case .discard:
            return   // static card, nothing to animate
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
}

final class WavePanel: NSPanel {
    let wave = WaveView()
    private var timer: Timer?

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

    private func schedule(fps: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.wave.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate(); timer = nil
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
