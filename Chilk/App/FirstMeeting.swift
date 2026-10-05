import AppKit
import ChilkCore

/// First meeting (slice 5a, SPEC «Срез 5», decisions 22–23): while the name is unknown Chilk introduces himself in
/// bubbles at the edge (they wait while the user is away), then asks for the name with a field right in his last
/// bubble. «Готово» / Enter keeps the name, «Позже» never asks again (the name goes to Settings in 5c).
@MainActor
final class FirstMeeting {
    private var flow = GreetingFlow(lengths: Lines.greeting.map(\.count))
    private let profile: ProfileStore
    private let edge: EdgeController
    private let balance: BalanceController
    private var timer: Timer?
    private var fieldTimer: Timer?
    private var field: NameFieldPanel?
    private var thanking = false
    /// The stage is free for him: no conversation, no timer, no prompt, not in the popover.
    var canPresent: () -> Bool = { true }
    /// The name was given: the tray icon wiggles («вот где я теперь живу»).
    var onNamed: () -> Void = {}
    var log: (String) -> Void = { _ in }

    /// He is greeting right now: the balance director and timers wait for him.
    var isActive: Bool { profile.profile.needsGreeting && (flow.current != nil || flow.isAsking) || thanking }

    init(profile: ProfileStore, edge: EdgeController, balance: BalanceController) {
        self.profile = profile
        self.edge = edge
        self.balance = balance
        guard profile.profile.needsGreeting else { return }
        // CHILK_GREETING_FAST=1 (acceptance only): every line goes 1 s after it appears, even with nobody at the Mac.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    private var fast: Bool { ProcessInfo.processInfo.environment["CHILK_GREETING_FAST"] != nil }

    private func tick() {
        guard profile.profile.needsGreeting else { return stop() }
        let showing = flow.current != nil || flow.isAsking
        let free = canPresent()
        if showing && !free {
            // A conversation, a timer or the popover took the stage: the same line comes back afterwards.
            flow.interrupted()
            hideField()
            log("greeting interrupted")
            return
        }
        let signals = balance.lastSignals
        let now = ProcessInfo.processInfo.systemUptime
        let idle = fast ? 0.2 : (signals?.idle ?? 0)
        switch flow.step(now: now, idle: idle, locked: fast ? false : (signals?.locked ?? false), canPresent: free) {
        case .none:
            if fast, flow.current != nil { flow.clicked() }
        case .say(let i):
            edge.sim.say(Lines.greeting[i], duration: .infinity)
            edge.sim.standOut = .peek
            log("greeting line \(i + 1)")
        case .ask:
            edge.sim.say(Lines.greeting[Lines.greeting.count - 1], duration: .infinity,
                         buttons: [Lines.nameFieldSlot, Lines.nameDone, Lines.nameLater])
            edge.sim.standOut = .peek
            showField()
            log("greeting asks for the name")
            // Acceptance only: CHILK_DEMO_NAME types this into the field and presses «Готово» after 2 s
            // (CHILK_DEMO_NAME=- presses «Позже»).
            if let demo = ProcessInfo.processInfo.environment["CHILK_DEMO_NAME"] {
                Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.flow.isAsking else { return }
                        if demo == "-" { _ = self.pressedButton(2); return }
                        self.field?.text = demo
                        _ = self.pressedButton(1)
                    }
                }
            }
        }
    }

    /// A click on Chilk: the line on screen is read (`false` = not ours).
    func clicked() -> Bool {
        guard profile.profile.needsGreeting else { return false }
        if flow.current != nil { flow.clicked(); return true }
        if flow.isAsking { field?.focus(); return true }
        return false
    }

    /// Buttons under the question: the field's slot, «Готово», «Позже» (`false` = not ours).
    func pressedButton(_ index: Int) -> Bool {
        guard profile.profile.needsGreeting, flow.isAsking else { return false }
        switch index {
        case 0: field?.focus()
        case 1: submit()
        default: later()
        }
        return true
    }

    private func submit() {
        let text = field?.text ?? ""
        guard profile.setName(text), let name = profile.profile.name else {
            edge.sim.updateBubble(Lines.nameRefused)
            field?.focus()
            log("greeting: name refused")
            return
        }
        log("greeting: name set")                                  // the name itself stays out of logs
        hideField()
        thanking = true
        edge.sim.setBubbleButtons([])
        edge.sim.say(Lines.niceToMeet(name), duration: 4)
        onNamed()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thanking = false
                // Only if he is still ours: a call took him (`.out`) and brings him back itself.
                guard self.edge.sim.standOut == .peek else { return }
                self.edge.sim.standOut = .docked
                self.balance.resume()
            }
        }
        stop()
    }

    private func later() {
        profile.later()
        log("greeting: later")
        hideField()
        edge.sim.clearBubble()
        edge.sim.standOut = .docked
        stop()
        balance.resume()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: The field in the bubble

    private func showField() {
        if field == nil {
            let f = NameFieldPanel()
            f.onSubmit = { [weak self] in self?.submit() }
            field = f
        }
        fieldTimer?.invalidate()
        fieldTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeField() }
        }
    }

    /// Exactly over the blank first button of the bubble, once it has popped in; follows him if he moves.
    private func placeField() {
        guard let field, let slot = edge.buttonRects.first(where: { $0.index == 0 }) else {
            field?.orderOut(nil)
            return
        }
        let frame = edge.screenRect(fromScene: slot.rect).insetBy(dx: 0.5, dy: 0.5)
        if field.frame != frame { field.setFrame(frame, display: true) }
        if !field.isVisible { field.orderFrontRegardless() }
    }

    private func hideField() {
        fieldTimer?.invalidate()
        fieldTimer = nil
        field?.orderOut(nil)
    }
}

/// A borderless panel holding only the name field. It becomes key only when clicked (so the user's typing elsewhere
/// is never captured) and never activates Chilk: the app the user was in stays in front.
final class NameFieldPanel: NSPanel, NSTextFieldDelegate {
    private let input = NSTextField()
    var onSubmit: (() -> Void)?
    var text: String {
        get { input.stringValue }
        set { input.stringValue = newValue }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 140, height: 24), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        input.placeholderString = Lines.namePlaceholder
        input.font = .systemFont(ofSize: 13)
        input.bezelStyle = .roundedBezel
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(enter)
        input.autoresizingMask = [.width, .height]
        let content = NSView(frame: contentRect(forFrameRect: frame))
        input.frame = content.bounds
        content.addSubview(input)
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func focus() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(input)
    }

    @objc private func enter() { onSubmit?() }
}
