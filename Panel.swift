import AppKit
import QuartzCore

// MARK: - Floating waveform panel

/// What the card is currently showing.
enum PanelState { case wave, busy }

final class WaveView: NSView {
    var state: PanelState = .wave
    var compact = false                 // size mode; not cleared by reset()
    var currentLevel: CGFloat = 0       // latest mic level from the tap
    private var smoothLevel: CGFloat = 0    // eased mic level; the bars follow this, not the raw tap
    private var bars: [CGFloat] = []        // scrolled history, oldest first
    private var ticks = 0
    private var phase = 0.0                 // transcribing-spindle clock
    var footerLeft = "Whisper"
    var footerDim = false                   // transcribing dims the whole footer
    var footerRight: [(String, String?)] = []   // (label, keycap)

    // Card geometry: 428x120, thin bars on a 3pt pitch.
    static let inset: CGFloat = 24
    static let pitch: CGFloat = 3
    static let barW: CGFloat = 1.5
    static let footerH: CGFloat = 40
    static let radius: CGFloat = 32
    static let fullSize = NSSize(width: 428, height: 120)
    static let compactSize = NSSize(width: 100, height: 28)
    static let compactRadius: CGFloat = 14
    static let compactSlots = 7

    var radius: CGFloat { compact ? Self.compactRadius : Self.radius }

    var waveArea: NSRect {
        if compact {
            return NSRect(x: 12, y: 6,
                          width: bounds.width - 24, height: bounds.height - 12)
        }
        return NSRect(x: Self.inset, y: Self.footerH + 4,
                      width: bounds.width - 2 * Self.inset, height: bounds.height - Self.footerH - 18)
    }
    private var slots: Int {
        compact ? Self.compactSlots : max(2, Int(waveArea.width / Self.pitch))
    }

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

    /// Template SF Symbols draw black with `.sourceOver` + a fraction. Tint
    /// with the same color as the footer word so idle and busy match.
    private func drawTinted(_ img: NSImage, in r: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        color.setFill()
        r.fill(using: .sourceIn)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
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
    /// Transcribing: a soft ripple slides across the bars from right to left.
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
        }
        // Only the bars move frame to frame; leave the card and footer alone.
        setNeedsDisplay(waveArea.insetBy(dx: 0, dy: -4))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if !path.contains(point) { return nil }
        return super.hitTest(point)
    }

    override func draw(_ rect: NSRect) {
        let b = bounds
        let r = radius
        // Clip to the pill so tall bars can't paint through the corners
        // and show up as a halo outside the card.
        NSBezierPath(roundedRect: b, xRadius: r, yRadius: r).addClip()
        // Near-opaque dark wash over the blur, plus a hairline border.
        // (The soft edge translucency comes from the NSVisualEffectView behind us.)
        let card = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        NSColor(calibratedWhite: 0.07, alpha: 0.55).setFill(); card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke(); card.lineWidth = 1; card.stroke()

        if !compact { drawFooter(rect) }
        drawBars()
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

        if let img = symbol("mic.fill", size: 13) {
            // Draw at the symbol's own size. A 15x14 dest squashed mic.fill
            // (taller than wide) into a short wide blob.
            let s = img.size
            let r = NSRect(x: footer.minX + 14, y: (footer.midY - s.height / 2).rounded(),
                           width: s.width, height: s.height)
            drawTinted(img, in: r, color: dim)
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
        var busyAlpha = [CGFloat](repeating: 0.65, count: n)   // brighter on the crests
        switch state {
        case .wave:
            // Right-aligned history plus a live bar hugging the right edge.
            let recent = bars.suffix(n - 1)
            let start = n - 1 - recent.count
            for (i, v) in recent.enumerated() { levels[start + i] = v }
            levels[n - 1] = min(1, pow(smoothLevel * 1.35, 0.9))
        case .busy:
            // Ripple: one long, gentle sine sliding right to left, tapered at
            // both ends so it fades into the edges. `+ phase` is what makes it
            // travel leftward; 0.9 cycles/s, 2.2 waves across the card.
            for i in 0..<n {
                let x = Double(i) / Double(n - 1)
                let env = pow(sin(.pi * x), 0.6)
                let s = 0.5 + 0.5 * sin(2 * .pi * (x * 2.2 + phase * 0.9))
                levels[i] = CGFloat(0.08 + 0.55 * env * s)
                busyAlpha[i] = CGFloat(0.45 + 0.35 * s)
            }
        }
        let mid = area.midY
        let maxH = area.height
        let pitch: CGFloat = compact ? area.width / CGFloat(n) : Self.pitch
        let barW: CGFloat = compact ? 2.4 : Self.barW
        let minH: CGFloat = compact ? 2.4 : 1.6
        let totalW = CGFloat(n) * pitch - (pitch - barW)
        let x0 = area.midX - totalW / 2
        for i in 0..<n {
            let lv = levels[i]
            let h = max(minH, lv * maxH)
            let alpha: CGFloat = h <= minH ? 0.30
                : state == .busy ? busyAlpha[i]
                : 0.40 + 0.60 * min(1, lv * 1.5)
            NSColor(calibratedWhite: 1, alpha: alpha).setFill()
            let r = NSRect(x: x0 + CGFloat(i) * pitch, y: mid - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }

}

/// Frosted card. maskImage clips the blur; hitTest still uses the square
/// bounds, so corners would eat clicks on the tabs under a compact pill.
final class PillEffectView: NSVisualEffectView {
    var radius: CGFloat = WaveView.radius
    override func hitTest(_ point: NSPoint) -> NSView? {
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if !path.contains(point) { return nil }
        return super.hitTest(point)
    }
}

/// Invisible until the cursor is in this view's bounds. Alpha 0 still
/// hit-tests; isHidden would not. `.activeAlways` because the panel is
/// nonactivating and would never be key.
final class ChevronButton: NSButton {
    var lit: CGFloat = 0.55

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        contentTintColor = .white
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = lit
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 0
    }
}

final class WavePanel: NSPanel {
    let wave = WaveView()
    private let chevron = ChevronButton(frame: .zero)
    private var timer: Timer?
    private var compact = false
    private var mouseDownCompact = false

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: WaveView.fullSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = false
        hidesOnDeactivate = false   // the settings window can make us active; the card must survive us going inactive again
        isMovableByWindowBackground = true   // grab anywhere on the card and drag
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Frosted-glass card. layer.cornerRadius does not clip the material, so
        // the blur would fill the window's square and show as a halo outside the
        // pill. maskImage on the contentView clips the blur and shapes the
        // window shadow to the same rounded rect.
        let effect = PillEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.maskImage = Self.roundedMask(radius: WaveView.radius)
        contentView = effect
        wave.wantsLayer = true
        wave.layer?.cornerRadius = WaveView.radius
        wave.layer?.masksToBounds = true
        wave.frame = effect.bounds
        wave.autoresizingMask = [.width, .height]
        effect.addSubview(wave)

        chevron.target = self
        chevron.action = #selector(toggleCompact)
        chevron.image = Self.chevronImage()
        chevron.toolTip = "Collapse"
        wave.addSubview(chevron)
        layoutChevron()

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

    func show(mode: Mode, hotkey: String, footer: String? = nil, closeLabel: String = "Close") {
        wave.reset()
        wave.footerDim = false
        wave.footerLeft = footer ?? (mode == .cleanup ? "Cleanup" : "Whisper")
        wave.footerRight = [("Stop", nil)] + keycaps(hotkey) + [(closeLabel, "esc")]
        // Size before place/orderFront so the first frame is already compact
        // when that's the saved mode (no 428x120 flash then shrink).
        setCompact(UserDefaults.standard.bool(forKey: "panelCompact"), animated: false)
        wave.needsDisplay = true
        // Re-assert "show on every Space" each time. The window server can
        // drop this tag (seen after a sleep/wake, or after the card was
        // dragged) and pin the panel to one Space, so the card only appeared
        // on a desktop the user was not looking at while dictation kept
        // working. Setting it again right before ordering front re-tags it.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The card fades in quickly rather than popping.
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            invalidateShadow()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                self.animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
            invalidateShadow()
        }
        schedule(fps: 60)
        // Right after a wake the window server can drop the panel somewhere
        // stale; one more place() after things settle brings it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isVisible else { return }
            self.place()
        }
    }

    func transcribing(status: String? = nil) {
        wave.state = .busy
        wave.footerDim = true
        if let status { wave.footerLeft = status }
        wave.footerRight = [("Close", "esc")]
        wave.needsDisplay = true
        schedule(fps: 30)
    }

    /// Busy-state progress ("Transcribing…", "Loading model…"). Tick only
    /// dirties the bars, so this forces a full redraw for the footer word.
    func setFooterLeft(_ text: String) {
        wave.footerLeft = text
        wave.needsDisplay = true
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
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }   // a new show() won the race
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }

    func push(level: CGFloat) {
        wave.currentLevel = level
    }

    @objc private func toggleCompact() {
        setCompact(!compact, animated: true)
    }

    private func setCompact(_ on: Bool, animated: Bool) {
        compact = on
        wave.compact = on
        UserDefaults.standard.set(on, forKey: "panelCompact")
        isMovableByWindowBackground = !on
        applyChrome()
        chevron.toolTip = on ? "Expand" : "Collapse"
        chevron.alphaValue = 0
        layoutChevron()
        wave.needsDisplay = true
        let next = frame(for: currentSize)
        if animated, isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(next, display: true)
            }, completionHandler: { [weak self] in
                self?.layoutChevron()
                self?.invalidateShadow()
                self?.syncChevronHover()
            })
        } else {
            setFrame(next, display: true)
            layoutChevron()
            invalidateShadow()
            syncChevronHover()
        }
    }

    private var currentSize: NSSize {
        compact ? WaveView.compactSize : WaveView.fullSize
    }

    private func applyChrome() {
        let r = wave.radius
        if let effect = contentView as? PillEffectView {
            effect.radius = r
            effect.maskImage = Self.roundedMask(radius: r)
        }
        wave.layer?.cornerRadius = r
    }

    /// After a morph the cursor may already sit in the icon hitbox.
    private func syncChevronHover() {
        let win = convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        let local = chevron.convert(win, from: nil)
        chevron.alphaValue = chevron.bounds.contains(local) ? chevron.lit : 0
    }

    private func layoutChevron() {
        let s: CGFloat = 18
        let b = wave.bounds
        if compact {
            chevron.autoresizingMask = [.minXMargin]
            chevron.frame = NSRect(x: b.maxX - s - 6, y: (b.height - s) / 2, width: s, height: s)
        } else {
            chevron.autoresizingMask = [.minXMargin, .minYMargin]
            chevron.frame = NSRect(x: b.maxX - s - 12, y: b.maxY - s - 10, width: s, height: s)
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownCompact = compact
        super.mouseDown(with: event)
    }

    // Full card: wherever you drag it is where it comes back next time.
    // Compact: a click expands. Do not write panelOrigin from the top-dock
    // frame or the next full show jumps to the menu bar.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if mouseDownCompact {
            if compact { setCompact(false, animated: true) }
            return
        }
        if !compact, abs(frame.height - WaveView.fullSize.height) < 1 {
            UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panelOrigin")
        }
    }

    private func place() {
        setFrameOrigin(origin(for: frame.size))
    }

    private func frame(for size: NSSize) -> NSRect {
        NSRect(origin: origin(for: size), size: size)
    }

    private func origin(for size: NSSize) -> NSPoint {
        if compact {
            let mouse = NSEvent.mouseLocation
            let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            // screen.frame, not visibleFrame: Superwhisper sits on the menu bar.
            return NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height)
        }
        // Preferred spot: wherever it was dragged last, else bottom-center
        // of the screen with the mouse.
        var screen: NSScreen?
        var o = NSPoint.zero
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            o = NSPointFromString(saved)
            screen = NSScreen.screens.first { $0.visibleFrame.intersects(NSRect(origin: o, size: size)) }
        }
        if screen == nil {
            let mouse = NSEvent.mouseLocation
            let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            o = NSPoint(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.minY + 90)
            screen = s
        }
        // Clamp the whole card onto that screen. A stale frame after a
        // sleep/wake once stranded the panel at x=2606 on a 1440-wide screen:
        // dictation kept working with no visualizer in sight.
        if let f = screen?.visibleFrame {
            o.x = min(max(o.x, f.minX), max(f.minX, f.maxX - size.width))
            o.y = min(max(o.y, f.minY), max(f.minY, f.maxY - size.height))
        }
        return o
    }

    /// Stretchable rounded-rect mask. capInsets of `radius` keep the corners
    /// unscaled so the pill stays circular at any size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: radius * 2, height: radius * 2), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    private static func chevronImage() -> NSImage? {
        guard let icon = NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left",
                                 accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let img = icon.withSymbolConfiguration(cfg) ?? icon
        let s = img.size
        // 90° CCW: (x, y) -> (-y, x), then shift by height so it sits in the new bounds.
        let rotated = NSImage(size: NSSize(width: s.height, height: s.width), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: s.height, y: 0)
            ctx.rotate(by: .pi / 2)
            img.draw(in: NSRect(origin: .zero, size: s), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        rotated.isTemplate = true
        return rotated
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
