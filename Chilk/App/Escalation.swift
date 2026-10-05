import AppKit

/// Stages 3–4 on screen (decisions 2026-10-05). Stage 3 «мешает»: the screens slowly dim to ~40 %, clicks pass
/// through, work goes on. Stage 4 «блокирует»: a pause over everything on every screen until the rest is counted;
/// other apps are never touched. The emergency exit is always on the pause: a reason, 15/30/60 min, and once
/// the exits are spent a 10-second hold.
@MainActor
final class Escalation {
    enum Level: String { case none, dim, pause }

    private(set) var level = Level.none
    private var dims: [NSWindow] = []
    private var pauses: [PauseWindow] = []
    private var card: PauseCard?
    private var screenFrames: [NSRect] = []
    private var observers: [(NotificationCenter, Any)] = []

    /// reason, minutes, held → the engine accepted it.
    var onExit: ((String, Int, Bool) -> Bool)?
    /// The 10-second hold is in progress (Chilk is sad meanwhile).
    var onHolding: ((Bool) -> Void)?
    /// The pause went up / came down (the app turns ⌘Q off meanwhile).
    var onPause: ((Bool) -> Void)?
    /// Where Chilk stands: the pause card goes under him on that screen.
    var chilkFrame: () -> NSRect = { .zero }
    var log: (String) -> Void = { _ in }

    static let dimAlpha: CGFloat = 0.4
    static let dimSeconds = 25.0

    // MARK: Stage 3

    func dim() {
        guard level != .dim else { return }
        lift()
        level = .dim
        dims = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .black
            w.alphaValue = 0
            w.hasShadow = false
            w.ignoresMouseEvents = true                         // work goes on under the shade
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)   // under Chilk, over apps
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            return w
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.dimSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            for w in dims { w.animator().alphaValue = Self.dimAlpha }
        }
        log("escalation dim on \(dims.count) screen(s)")
    }

    // MARK: Stage 4

    func pause(exitsLeft: Int, restNeeded: TimeInterval) {
        if level == .pause { card?.exitsLeft = exitsLeft; return }
        lift()
        level = .pause
        screenFrames = NSScreen.screens.map(\.frame)
        let home = NSScreen.screens.first { $0.frame.contains(NSPoint(x: chilkFrame().midX, y: chilkFrame().midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        for screen in NSScreen.screens {
            let w = PauseWindow(screen: screen)
            if screen == home {
                let card = PauseCard(exitsLeft: exitsLeft, restNeeded: restNeeded)
                card.onExit = { [weak self] reason, minutes, held in self?.onExit?(reason, minutes, held) ?? false }
                card.onHolding = { [weak self] holding in self?.onHolding?(holding) }
                w.place(card, under: screen.frame.midY - 112)        // his feet are ~106 pt under the middle
                self.card = card
            }
            w.alphaValue = 0
            w.orderFrontRegardless()
            pauses.append(w)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            for w in pauses { w.animator().alphaValue = 1 }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                           object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.takeFocus() }
            }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockDown() }
        }))
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refitScreens() }
        }))
        takeFocus()
        onPause?(true)
        log("escalation pause on \(pauses.count) screen(s), exits \(exitsLeft)")
    }

    /// Seconds still to stay away from the keyboard (input resets it — that is the rule of rest).
    func update(restLeft: TimeInterval, exitsLeft: Int) {
        card?.exitsLeft = exitsLeft
        card?.restLeft = restLeft
    }

    func lift() {
        guard level != .none else { return }
        let was = level
        level = .none
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        let windows: [NSWindow] = dims + pauses
        dims = []
        pauses = []
        card = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            for w in windows { w.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated { for w in windows { w.orderOut(nil) } }
        })
        if was == .pause {
            NSApp.presentationOptions = []
            onHolding?(false)
            onPause?(false)
        }
        log("escalation lifted (\(was.rawValue))")
    }

    /// Acceptance runs only (CHILK_DEMO_EXIT): the exit through the same card path a person would use.
    func demoExit(reason: String) {
        card?.demoSubmit(reason: reason)
    }

    /// Acceptance runs only (CHILK_DEMO_SNAPSHOT): the pause as drawn on Chilk's screen, shade included, to a PNG.
    /// Rendering our own view needs no screen-recording permission. Chilk himself is a separate window.
    func snapshot(to url: URL, openForm: Bool) {
        guard let window = pauses.first(where: { $0.contentView?.subviews.isEmpty == false }),
              let view = window.contentView else { return }
        if openForm { card?.openFormForDemo() }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        let image = NSImage(size: view.bounds.size)
        view.cacheDisplay(in: view.bounds, to: rep)
        image.lockFocus()
        window.backgroundColor.setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    // MARK: Focus

    private func takeFocus() {
        guard level == .pause else { return }
        NSApp.activate()
        (pauses.first { $0.contentView?.subviews.isEmpty == false } ?? pauses.first)?.makeKeyAndOrderFront(nil)
        lockDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.level == .pause else { return }
                self.log("escalation pause focus active=\(NSApp.isActive) options=\(NSApp.currentSystemPresentationOptions.rawValue)")
            }
        }
    }

    /// While Chilk is active under the pause: no Dock, no menu bar, no ⌘Tab. Force Quit stays (never impossible).
    private func lockDown() {
        guard level == .pause, NSApp.isActive else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
    }

    private func refitScreens() {
        // Hiding the Dock and the menu bar also posts this; only a real change of screens rebuilds the pause.
        guard level == .pause, NSScreen.screens.map(\.frame) != screenFrames else { return }
        log("escalation screens changed")
        let exits = card?.exitsLeft ?? 0, rest = card?.restNeeded ?? 180
        level = .none
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        for w in pauses { w.orderOut(nil) }
        pauses = []
        card = nil
        pause(exitsLeft: exits, restNeeded: rest)
    }
}

/// A screen-sized shade over everything that can take keys (the reason field).
private final class PauseWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor(white: 0.04, alpha: 0.86)
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
        contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The card hangs centred under Chilk; `y` is a screen coordinate.
    func place(_ card: NSView, under y: CGFloat) {
        guard let root = contentView else { return }
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: frame.maxY - y),
            card.widthAnchor.constraint(equalToConstant: 380),
        ])
    }
}

/// Countdown, the emergency exit and its form.
@MainActor
private final class PauseCard: NSView, NSTextFieldDelegate {
    var onExit: ((String, Int, Bool) -> Bool)?
    var onHolding: ((Bool) -> Void)?
    let restNeeded: TimeInterval
    var exitsLeft: Int { didSet { if exitsLeft != oldValue { refresh() } } }
    var restLeft: TimeInterval = .infinity { didSet { refreshCountdown() } }

    private let countdown = NSTextField(labelWithString: "")
    private let exitButton = NSButton()
    private let form = NSStackView()
    private let reason = NSTextField()
    private let minutes = NSSegmentedControl(labels: Lines.exitMinutes.map(Lines.minutesLabel), trackingMode: .selectOne,
                                             target: nil, action: nil)
    private let confirm = NSButton()
    private let hold = HoldButton()
    private let hint = NSTextField(labelWithString: "")

    init(exitsLeft: Int, restNeeded: TimeInterval) {
        self.exitsLeft = exitsLeft
        self.restNeeded = restNeeded
        super.init(frame: .zero)
        countdown.font = .systemFont(ofSize: 17, weight: .medium)
        countdown.textColor = NSColor(white: 1, alpha: 0.92)
        countdown.alignment = .center
        countdown.maximumNumberOfLines = 2
        countdown.lineBreakMode = .byWordWrapping
        countdown.preferredMaxLayoutWidth = 380

        exitButton.isBordered = false
        exitButton.target = self
        exitButton.action = #selector(openForm)

        reason.placeholderString = Lines.exitReasonPlaceholder
        reason.font = .systemFont(ofSize: 14)
        reason.delegate = self
        reason.target = self
        reason.action = #selector(submit)
        minutes.selectedSegment = 0
        confirm.bezelStyle = .rounded
        confirm.target = self
        confirm.action = #selector(submit)
        hold.onHolding = { [weak self] holding in self?.onHolding?(holding) }
        hold.onComplete = { [weak self] in self?.finish(held: true) }
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = NSColor(white: 1, alpha: 0.6)
        hint.alignment = .center
        let back = NSButton(title: Lines.exitBack, target: self, action: #selector(closeForm))
        back.isBordered = false
        back.attributedTitle = Self.link(Lines.exitBack, alpha: 0.55)

        let actions = NSStackView(views: [back, confirm, hold])
        actions.spacing = 12
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .centerX
        form.setViews([reason, minutes, actions, hint], in: .top)
        reason.widthAnchor.constraint(equalToConstant: 320).isActive = true
        hold.widthAnchor.constraint(equalToConstant: 200).isActive = true
        hold.heightAnchor.constraint(equalToConstant: 30).isActive = true
        form.isHidden = true

        let stack = NSStackView(views: [countdown, exitButton, form])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        refreshCountdown()
    }

    required init?(coder: NSCoder) { nil }

    private func refresh() {
        exitButton.attributedTitle = Self.link(Lines.exitButton(left: exitsLeft), alpha: 0.6)
        let spent = exitsLeft <= 0
        confirm.title = Lines.exitConfirm
        confirm.isHidden = spent
        hold.isHidden = !spent
        hold.title = Lines.exitHold
        hint.stringValue = spent ? Lines.exitsSpent : ""
        hint.isHidden = !spent
        validate()
    }

    private func refreshCountdown() {
        countdown.stringValue = restLeft > restNeeded - 5 || !restLeft.isFinite        // typing right now: the rule, not 2:59
            ? Lines.pauseStart(minutes: Int((restNeeded / 60).rounded()))
            : Lines.pauseCountdown(seconds: Int(max(0, restLeft).rounded(.up)))
    }

    private func validate() {
        let ok = !reason.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        confirm.isEnabled = ok
        hold.isEnabled = ok
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    @objc private func openForm() {
        form.isHidden = false
        exitButton.isHidden = true
        window?.makeFirstResponder(reason)
    }

    func openFormForDemo() { openForm() }

    @objc private func closeForm() {
        form.isHidden = true
        exitButton.isHidden = false
        window?.makeFirstResponder(nil)
    }

    @objc private func submit() {
        guard exitsLeft > 0 else { return }               // spent: only the hold
        finish(held: false)
    }

    private func finish(held: Bool) {
        let text = reason.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { window?.makeFirstResponder(reason); return }
        let chosen = Lines.exitMinutes[max(0, minutes.selectedSegment)]
        if onExit?(text, chosen, held) != true { NSSound.beep() }
    }

    func demoSubmit(reason text: String) {
        openForm()
        reason.stringValue = text
        validate()
        if exitsLeft > 0 { submit() } else { finish(held: true) }
    }

    private static func link(_ title: String, alpha: CGFloat) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.foregroundColor: NSColor(white: 1, alpha: alpha),
                                                       .font: NSFont.systemFont(ofSize: 13),
                                                       .underlineStyle: NSUnderlineStyle.single.rawValue])
    }
}

/// «Удерживай 10 с»: fills while pressed, starts over when released early.
@MainActor
private final class HoldButton: NSView {
    var onHolding: ((Bool) -> Void)?
    var onComplete: (() -> Void)?
    var title = "" { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    static let seconds = 10.0
    private var progress = 0.0 { didSet { needsDisplay = true } }
    private var timer: Timer?
    private var started: Date?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(white: 1, alpha: isEnabled ? 0.12 : 0.05).setFill()
        shape.fill()
        if progress > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor(white: 1, alpha: 0.35).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width * progress, height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(white: 1, alpha: isEnabled ? 0.5 : 0.2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                  .foregroundColor: NSColor(white: 1, alpha: isEnabled ? 0.9 : 0.35)])
        let size = text.size()
        text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        started = Date()
        onHolding?(true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard started != nil else { return }
        reset()
    }

    private func step() {
        guard let started else { return }
        progress = min(1, Date().timeIntervalSince(started) / Self.seconds)
        if progress >= 1 {
            reset()
            onComplete?()
        }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        started = nil
        progress = 0
        onHolding?(false)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
}
