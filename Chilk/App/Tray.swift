import AppKit
import ChilkBrain
import ChilkCore
import ChilkRender
import QuartzCore
import SwiftUI

/// Chilk's place in the menu bar (slice 5a, SPEC «Срез 5», decisions 1–9): a template icon whose sprout mirrors the
/// user, a wiggle instead of the Dock bounce, the popover on a left click and a short menu on a right click.
/// When the popover opens and Chilk is free, he leaves the screen edge and comes out on the hero card.
@MainActor
final class Tray: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: TrayModel
    private let tools: ToolsBridge
    private let hero = HeroView()
    private var icons: [TrayIconState: NSImage] = [:]
    private var iconState: TrayIconState?
    private var iconTimer: Timer?
    private var openTimer: Timer?
    private var afterClose: (() -> Void)?
    private var loggedPage: TrayModel.Page?

    private let edge: EdgeController
    private let balance: BalanceController
    private let brain: Brain
    private let ears: Ears
    private let actions: Actions
    private let conversation: Conversation

    /// He is on the hero card right now: the edge is empty and the director waits (decision 7).
    private(set) var holdsChilk = false
    /// Free for the hand-off: nothing holds him at the edge (set by the app; includes the greeting).
    var isFree: () -> Bool = { true }
    /// Slice 7a: «Игры» → the notebook (after the popover gives Chilk back); why not now (`nil` = can play).
    var playGame: (GameKind) -> String? = { _ in nil }
    var gameRefusal: () -> String? = { nil }
    var savedGame: () -> (kind: GameKind, score: String)? = { nil }
    /// The right-click menu («Позвать», «Проверка ▸», «О Чилке», «Выйти»), built fresh each time.
    var menu: () -> NSMenu = { NSMenu() }
    /// «Чат» (slice 5b): opens the chat window.
    var openChat: () -> Void = {}
    /// «Открыть Чилка» / «Настройки» (slice 5c): the main window on «Сегодня» / «Настройки».
    var openMain: () -> Void = {}
    /// Slice 9b: today's plan («План: 2 из 5») and «Лист дня».
    var planSummary: () -> (done: Int, total: Int)? = { nil }
    var openPlan: () -> Void = {}
    var openSettings: () -> Void = {}
    var log: (String) -> Void = { _ in }
    private var spaceObserver: NSObjectProtocol?

    init(edge: EdgeController, balance: BalanceController, brain: Brain, ears: Ears, actions: Actions,
         conversation: Conversation, tools: ToolsBridge) {
        self.edge = edge
        self.balance = balance
        self.brain = brain
        self.ears = ears
        self.actions = actions
        self.conversation = conversation
        self.tools = tools
        model = TrayModel(tools: tools.model)
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(String(localized: "Чилк"))
            button.wantsLayer = true
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: TrayView(model: model, hero: hero))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        hero.fatigue = { [weak balance] in balance?.engine.leafFatigue ?? 0 }
        hero.eyeStrain = { [weak balance] in balance?.engine.eyeStrain ?? 0 }
        wire()
        // Slice 9, decision 3: a swipe to another desktop (or into a full-screen app) closes the popover; Chilk peeks
        // back at the edge as on any close.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.log("popover closed: space changed")
                self.close()
            }
        }
        refreshIcon()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
        iconTimer?.tolerance = 0.3
    }

    // MARK: Icon (decisions 3–4)

    /// Swapped only when the state changes: the image is drawn once per state, never animated continuously.
    private func refreshIcon() {
        let state = TrayIcon.state(leafFatigue: balance.engine.leafFatigue, shownStage: balance.shownStage,
                                   noticeWaiting: actions.noticeWaiting)
        guard state != iconState, let button = item.button else { return }
        iconState = state
        button.image = icons[state] ?? {
            let image = NSImage(size: TrayIconRenderer.size)
            for scale in [1.0, 2.0] {
                guard let cg = TrayIconRenderer.image(state, scale: scale) else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = TrayIconRenderer.size
                image.addRepresentation(rep)
            }
            image.isTemplate = true
            icons[state] = image
            return image
        }()
        log("tray icon \(state.leaf)\(state.dot ? " dot" : "")")
    }

    /// Stage 2 insists / a timer fell due: one ~1 s wiggle (was the Dock bounce). No timers afterwards.
    func nudge() {
        guard let layer = item.button?.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -2.5, 2.5, -2, 2, -1, 0]
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, 2, 0, 1, 0, 0, 0]
        let group = CAAnimationGroup()
        group.animations = [shake, hop]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "nudge")
        log("tray nudge")
    }

    // MARK: Clicks (decision 5)

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            if popover.isShown { popover.performClose(nil) }
            guard let button = item.button else { return }
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return
        }
        popover.isShown ? popover.performClose(nil) : show()
    }

    /// `demo`: opened by CHILK_DEMO_TRAY (acceptance) — only then the snapshots run. A user's click never takes them.
    func show(demo: Bool = false) {
        guard let button = item.button, !popover.isShown else { return }
        model.page = .main
        model.refusal = nil
        refreshModel()
        NSApp.activate()                                   // a transient popover of an accessory app needs it
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if demo { demoSnapshots() }
    }

    /// Acceptance only, no Screen Recording needed: CHILK_DEMO_SNAPSHOT=/dir writes the popover's own drawing to
    /// PNGs (main page after the hero came out; with CHILK_DEMO_TRAY_PAGE=tools also the Tools page).
    private func demoSnapshots() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CHILK_DEMO_SNAPSHOT"], !dir.isEmpty else { return }
        Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snapshot(to: URL(fileURLWithPath: dir).appending(path: "popover-main.png"))
                // «tools» or «games» (slice 7a).
                let page = env["CHILK_DEMO_TRAY_PAGE"]
                guard page == "tools" || page == "games" else { return }
                self?.model.page = page == "games" ? .games : .tools
                Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.snapshot(to: URL(fileURLWithPath: dir).appending(path: "popover-\(page ?? "tools").png"))
                    }
                }
            }
        }
    }

    private func snapshot(to url: URL) {
        // The whole popover frame (with its backdrop), so vibrant label text is drawn as on screen.
        guard let content = popover.contentViewController?.view else { return }
        let view = content.window?.contentView?.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("tray snapshot \(url.lastPathComponent) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
    }

    // MARK: The hand-off (decision 7)

    func popoverWillShow(_ notification: Notification) {
        loggedPage = model.page
        log("tray opened on \(model.page)")
        if isFree() {
            holdsChilk = true
            model.heroHere = true
            edge.sim.standOut = .away                      // he ducks behind the screen edge …
            hero.start(enterAfter: 0.35)                   // … and comes out from behind the card's edge
            log("tray: Chilk went into the popover")
        } else {
            model.heroHere = false
            log("tray: Chilk is busy at the edge")
        }
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.whileOpen() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        openTimer?.invalidate()
        openTimer = nil
        hero.stop()
        model.page = .main                                 // the next click always opens on the main page
        if holdsChilk {
            holdsChilk = false
            // Only if he is still ours: a call (`.out`) or a due timer (`.peek`) took him and places him itself.
            if edge.sim.standOut == .away {
                edge.sim.standOut = .docked                // peeks out at his place again
                balance.resume()                           // what waited while he was away
                log("tray: Chilk is back at the edge")
            } else {
                log("tray: Chilk was taken by \(conversation.isActive ? "a conversation" : "the stage")")
            }
        }
        let then = afterClose
        afterClose = nil
        then?()
    }

    private func whileOpen() {
        refreshModel()
        if model.page != loggedPage {
            loggedPage = model.page
            log("tray page \(model.page)")
        }
        // A call (hotkey, «Чилк») or a due timer needs him at the edge: the popover gives him back.
        if holdsChilk && (conversation.isActive || actions.noticeWaiting) { popover.performClose(nil) }
    }

    /// Closes the popover, gives Chilk back to the edge, then runs `action` (breaks start from the edge).
    private func closing(_ action: @escaping () -> Void) {
        guard popover.isShown else { return action() }
        afterClose = action
        popover.performClose(nil)
    }

    /// Acceptance (CHILK_DEMO_TRAY_CLOSE) and anyone who needs Chilk back.
    func close() { if popover.isShown { popover.performClose(nil) } }

    // MARK: The popover's data and buttons

    private func refreshModel() {
        let engine = balance.engine
        model.now = Date()
        model.gameRefusal = gameRefusal()
        model.resumeNote = savedGame().map { [$0.kind: $0.score] } ?? [:]
        let card = HeroCard.make(pressure: { engine.pressure($0) }, exitsLeft: engine.state.exitsLeft,
                                 exitsMax: engine.config.emergencyExits, mode: balance.mode, off: engine.config.needsOff)
        if card != model.card { model.card = card }
        let timers = (actions.executor?.entries ?? []).sorted { $0.deadline < $1.deadline }.prefix(3)
            .map { TrayModel.TimerRow(id: $0.id, title: $0.title, deadline: $0.deadline) }
        if timers != model.timers { model.timers = Array(timers) }
        if balance.focusUntil != model.focusUntil { model.focusUntil = balance.focusUntil }
        let plan = planSummary().map { TrayModel.PlanLine(done: $0.done, total: $0.total) }
        if plan != model.plan { model.plan = plan }
        let problem: TrayModel.Problem? = switch brain.state {
        case .signedOut: .codexSignedOut
        case .failed(let why): .codexDown(why)
        case .missingCodex: .codexDown(brain.statusLine)
        case .ready, .connecting: ears.broken ? .earsBroken(ears.status) : nil
        }
        if problem != model.problem { model.problem = problem }
        tools.refresh()
    }

    private func wire() {
        model.breathe = { [weak self] minutes in self?.closing { self?.balance.startBreathing(minutes: minutes) } }
        model.eyes = { [weak self] in self?.closing { self?.balance.startEyeGym() } }
        model.drank = { [weak self] in self?.closing { self?.balance.drankWater() } }
        model.warmup = { [weak self] in self?.closing { self?.balance.startWarmup() } }
        model.walk = { [weak self] in self?.closing { self?.balance.startWalk() } }
        model.play = { [weak self] kind in self?.closing { _ = self?.playGame(kind) } }
        model.setMode = { [weak self] m in
            guard let self else { return false }
            let ok = self.balance.setMode(m)
            self.log("tray mode \(m.rawValue) \(ok ? "set" : "refused")")
            return ok
        }
        model.addFolder = { [weak self] kind in self?.closing { self?.tools.addFolder(kind) } }
        model.login = { [weak self] in self?.closing { self?.brain.login() } }
        model.openChat = { [weak self] in self?.closing { self?.openChat() } }
        model.openMain = { [weak self] in self?.closing { self?.openMain() } }
        model.openPlan = { [weak self] in self?.closing { self?.openPlan() } }
        model.openSettings = { [weak self] in self?.closing { self?.openSettings() } }
        model.reconnect = { [weak self] in
            guard let brain = self?.brain else { return }
            Task { await brain.connect() }
        }
        model.restartEars = { [weak self] in self?.ears.restart() }
        model.startFocus = { [weak self] hours in
            guard let self else { return nil }
            let outcome = self.balance.startFocus(seconds: Double(hours) * 3600)
            self.log("tray focus \(hours) h \(outcome)")
            switch outcome {
            case .started:
                self.closing { [weak self] in self?.balance.announceFocus() }
                return nil
            case .refused(let r): return r == .focusSpent ? Lines.focusSpent : Lines.softerRefused
            case .notSaved: return Lines.focusNotSaved
            }
        }
        model.endFocus = { [weak self] in self?.closing { [weak self] in self?.balance.endFocus() } }
    }

    func shutdown() {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        iconTimer?.invalidate()
        openTimer?.invalidate()
        hero.stop()
    }
}
