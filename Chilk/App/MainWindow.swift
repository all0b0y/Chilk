import AppKit
import ChilkBrain
import ChilkCore
import ChilkRender
import Observation
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case today, week, memory, tools, settings
    var id: String { rawValue }
}

/// What the main window shows (slice 5c, decisions 16–21). The controller refreshes it while the window is open.
@MainActor
@Observable
final class MainModel {
    struct AppRow: Identifiable, Equatable {
        let id: String
        let name: String
        let automatic: AppCategory
        let chosen: AppCategory?
    }
    struct ScreenRow: Identifiable, Equatable {
        let id: String
        let name: String
    }

    var section: MainSection? = .today

    // Сегодня / Неделя
    var card = HeroCard.make(pressure: { _ in 0 }, exitsLeft: 3, exitsMax: 3, mode: .soft)
    var portrait: NSImage?
    var today = TodaySummary.empty
    var week = WeekSummary.empty

    // Настройки
    var mode = BalanceMode.soft
    var care = CareSettings()
    /// «Договор с собой»: a request is on stage 3–4.
    var locked = false
    /// The last refused change, for a few seconds.
    var refusal: String?
    var apps: [AppRow] = []
    var appIcons: [String: NSImage] = [:]
    var hotkeyLabel = HotkeySpec.standard.label
    var recording = false
    var hotkeyNote: String?
    var edge = ChilkCore.Edge.right
    var screen = ScreenChoice.follow
    var screens: [ScreenRow] = []
    var name = ""
    var nameNote: String?
    var chatDays: Int? = 7
    var launchAtLogin = false
    var launchNote: String?
    var launchNeedsApproval = false
    var permissions: [Permissions.Kind: Permissions.State] = [:]

    // Actions, wired by the controller (the same paths the demo hooks use).
    var setMode: (BalanceMode) -> Void = { _ in }
    var changeCare: (CareChange) -> Void = { _ in }
    var setCategory: (String, AppCategory?) -> Void = { _, _ in }
    var record: (Bool) -> Void = { _ in }
    var setEdge: (ChilkCore.Edge) -> Void = { _ in }
    var setScreen: (ScreenChoice) -> Void = { _ in }
    var saveName: (String) -> Void = { _ in }
    var setChatDays: (Int?) -> Void = { _ in }
    var setLaunch: (Bool) -> Void = { _ in }
    var openPermission: (Permissions.Kind) -> Void = { _ in }
    var openLoginItems: () -> Void = {}
}

/// The main window: a normal big window with a sidebar (decision 16). While it is open the app is a regular one.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let model = MainModel()
    let memoryModel = MemoryModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var counted = false
    private var portraits: [TrayLeaf: NSImage] = [:]
    private var refusalTimer: Timer?
    private var appCache: [String: (name: String, icon: NSImage?)] = [:]

    private let balance: BalanceController
    private let settings: SettingsStore
    private let profile: ProfileStore
    private let chats: ChatStore
    private let memory: MemoryStore
    private let tools: ToolsBridge
    private let edge: EdgeController

    /// Registers a new call hotkey; `false` = refused (the old one stays).
    var setHotkey: (HotkeySpec) -> Bool = { _ in false }
    /// While the user records a new hotkey the current one is off (otherwise pressing it would call Chilk).
    var pauseHotkey: (Bool) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    init(balance: BalanceController, settings: SettingsStore, profile: ProfileStore, chats: ChatStore, memory: MemoryStore,
         tools: ToolsBridge, edge: EdgeController) {
        self.balance = balance
        self.settings = settings
        self.profile = profile
        self.chats = chats
        self.memory = memory
        self.tools = tools
        self.edge = edge
        super.init()
        memory.onChange.append { [weak self] in self?.refreshMemory() }
        wire()
        refreshMemory()
    }

    // MARK: Window

    func show(_ section: MainSection) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = Lines.mainTitle
            let host = NSHostingController(rootView: MainView(model: model, memory: memoryModel, tools: tools.model,
                                                              addFolder: { [weak self] in self?.tools.addFolder($0) }))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.minSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.collectionBehavior.insert(.fullScreenPrimary)          // the green button may, but it never opens so
            if !w.setFrameUsingName("ChilkMain") || w.frame.width < w.minSize.width || w.frame.height < w.minSize.height {
                w.setContentSize(NSSize(width: 1000, height: 700))
                w.center()
            }
            w.setFrameAutosaveName("ChilkMain")
            window = w
        }
        model.section = section
        refresh()
        refreshSettings()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if !counted {
            counted = true
            WindowPolicy.opened()
        } else {
            NSApp.activate()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
        log("main window open on \(section.rawValue)")
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        stopRecording()
        if counted {
            counted = false
            WindowPolicy.closed()
        }
        log("main window closed")
    }

    var isOpen: Bool { window?.isVisible == true }

    // MARK: Refresh

    /// Every 2 s while open: the numbers that move by themselves.
    private func refresh() {
        let engine = balance.engine
        let now = Date()
        let card = HeroCard.make(pressure: { engine.pressure($0) }, exitsLeft: engine.state.exitsLeft,
                                 exitsMax: engine.config.emergencyExits, mode: balance.mode, off: engine.config.needsOff)
        if card != model.card { model.card = card }
        let leaf = TrayIcon.state(leafFatigue: engine.leafFatigue, shownStage: nil, noticeWaiting: false).leaf
        let portrait = portraits[leaf] ?? Self.portrait(leaf)
        portraits[leaf] = portrait
        if model.portrait !== portrait { model.portrait = portrait }
        let today = engine.today(now: now)
        if today != model.today { model.today = today }
        let week = engine.week(now: now)
        if week != model.week { model.week = week }
        if model.mode != balance.mode { model.mode = balance.mode }
        if model.locked != balance.settingsLocked { model.locked = balance.settingsLocked }
        for k in Permissions.Kind.allCases {
            let s = Permissions.state(k)
            if model.permissions[k] != s { model.permissions[k] = s }
        }
        let launch = LoginItem.status
        if model.launchAtLogin != (launch != .off) { model.launchAtLogin = launch != .off }
        if model.launchNeedsApproval != (launch == .needsApproval) { model.launchNeedsApproval = launch == .needsApproval }
        refreshApps()
        tools.refresh()
        // Monitors come and go while Settings are open.
        let screens = NSScreen.screens.map { MainModel.ScreenRow(id: EdgeController.uuid(of: $0) ?? "", name: $0.localizedName) }
        if screens != model.screens { model.screens = screens }
    }

    /// On open and after every change: values only the user changes.
    private func refreshSettings() {
        let s = settings.settings
        let care = balance.engine.state.care
        if model.care != care { model.care = care }
        if model.hotkeyLabel != Hotkey.label { model.hotkeyLabel = Hotkey.label }
        if model.edge != edge.edge { model.edge = edge.edge }
        if model.screen != s.screen { model.screen = s.screen }
        model.name = profile.profile.name ?? ""
        if model.chatDays != chats.log.autoDeleteDays { model.chatDays = chats.log.autoDeleteDays }
        refreshApps()
    }

    private func refreshApps() {
        let rules = settings.settings.apps
        let rows = rules.listed.map { id -> MainModel.AppRow in
            let info = appInfo(id)
            return MainModel.AppRow(id: id, name: info.name, automatic: AppCatalog.automatic(bundleID: id),
                                    chosen: rules.overrides[id])
        }
        if rows != model.apps { model.apps = rows }
    }

    private func appInfo(_ id: String) -> (name: String, icon: NSImage?) {
        if let hit = appCache[id] { return hit }
        var info: (name: String, icon: NSImage?) = (id, nil)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            info = (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
            info.icon?.size = NSSize(width: 16, height: 16)
        }
        appCache[id] = info
        if let icon = info.icon { model.appIcons[id] = icon }
        return info
    }

    private func refreshMemory() {
        let facts = memory.book.facts
        if facts != memoryModel.facts { memoryModel.facts = facts }
    }

    private static func portrait(_ leaf: TrayLeaf) -> NSImage? {
        let fatigue = switch leaf {
        case .fresh: 0.0
        case .drooping: 0.55
        case .wilted: 1.0
        }
        guard let cg = Portrait.image(fatigue: fatigue, side: 150) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 150, height: 150))
    }

    private func refused() {
        model.refusal = Lines.locked
        refusalTimer?.invalidate()
        refusalTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refusal = nil }
        }
    }

    // MARK: Actions

    private func wire() {
        model.setMode = { [weak self] m in
            guard let self else { return }
            if self.balance.setMode(m) { self.model.mode = m } else { self.refused() }
            self.log("settings mode \(m.rawValue) \(self.model.mode == m ? "set" : "refused")")
        }
        model.changeCare = { [weak self] change in
            guard let self else { return }
            if !self.balance.changeCare(change) { self.refused() }
            self.model.care = self.balance.engine.state.care
            self.refresh()
        }
        model.setCategory = { [weak self] id, category in
            guard let self else { return }
            if !self.balance.setCategory(id, to: category) { self.refused() }
            self.refreshApps()
        }
        model.record = { [weak self] on in on ? self?.startRecording() : self?.stopRecording() }
        model.setEdge = { [weak self] e in
            self?.edge.move(to: e)
            self?.model.edge = e
            self?.log("settings edge \(e.rawValue)")
        }
        model.setScreen = { [weak self] choice in
            self?.settings.update { $0.screen = choice }
            self?.model.screen = choice
            self?.log("settings screen \(choice == .follow ? "follow" : "pinned")")
        }
        model.saveName = { [weak self] raw in
            guard let self else { return }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.profile.clearName()
                self.model.nameNote = Lines.nameCleared
            } else if self.profile.setName(raw) {
                self.model.nameNote = Lines.nameSaved
            } else {
                self.model.nameNote = Lines.nameRefused
            }
            self.model.name = self.profile.profile.name ?? raw
            self.log("settings name \(self.model.nameNote == Lines.nameRefused ? "refused" : "saved")")
        }
        model.setChatDays = { [weak self] days in
            self?.chats.setAutoDelete(days: days)
            self?.model.chatDays = days
            self?.log("settings chats \(days.map(String.init) ?? "never")")
        }
        model.setLaunch = { [weak self] on in
            guard let self else { return }
            self.model.launchNote = LoginItem.set(on)
            if self.model.launchNote == nil { self.settings.update { $0.launchAtLogin = on } }   // only what really happened
            self.refresh()
            self.log("settings launch at login \(on)\(self.model.launchNote.map { ": \($0)" } ?? "")")
        }
        model.openPermission = { Permissions.open($0) }
        model.openLoginItems = { LoginItem.openSystemSettings() }
        memoryModel.remember = { [weak self] text in
            guard let self else { return nil }
            return Lines.memoryOutcome(self.memory.remember(text, selfNoted: false))
        }
        memoryModel.edit = { [weak self] id, text in
            guard let self else { return nil }
            return Lines.memoryOutcome(self.memory.edit(id, to: text))
        }
        memoryModel.forget = { [weak self] id in self?.memory.forget(id) }
    }

    // MARK: Hotkey recording

    private func startRecording() {
        guard keyMonitor == nil else { return }
        model.recording = true
        model.hotkeyNote = nil
        pauseHotkey(true)
        // Only keys pressed in this window; ⌘V in the chat window stays a paste.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return false }
                self.recorded(event)
                return true
            }
            return taken ? nil : event
        }
    }

    /// Another window (or app) took the keyboard: recording stops, the current hotkey comes back.
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    private func recorded(_ event: NSEvent) {
        if event.keyCode == 53 { return stopRecording() }                       // Esc
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= HotkeySpec.command }
        if event.modifierFlags.contains(.shift) { mods |= HotkeySpec.shift }
        if event.modifierFlags.contains(.option) { mods |= HotkeySpec.option }
        if event.modifierFlags.contains(.control) { mods |= HotkeySpec.control }
        guard let spec = HotkeySpec.recorded(keyCode: UInt32(event.keyCode), modifiers: mods,
                                             characters: event.charactersIgnoringModifiers) else {
            model.hotkeyNote = Lines.hotkeyNeedsModifier
            return
        }
        apply(hotkey: spec)
    }

    /// Also the demo hook's path.
    func apply(hotkey spec: HotkeySpec) {
        stopRecording(resume: false)
        if setHotkey(spec) {
            settings.update { $0.hotkey = spec }
            model.hotkeyNote = nil
            log("settings hotkey \(spec.label)")
        } else {
            pauseHotkey(false)
            model.hotkeyNote = Lines.hotkeyRefused
            log("settings hotkey \(spec.label) refused")
        }
        model.hotkeyLabel = Hotkey.label
    }

    private func stopRecording(resume: Bool = true) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        let was = keyMonitor != nil
        keyMonitor = nil
        model.recording = false
        if was && resume { pauseHotkey(false) }
    }

    // MARK: Acceptance (CHILK_DEMO_MAIN, CHILK_DEMO_SETTINGS, CHILK_DEMO_MAIN_SNAPSHOT)

    /// Runs Settings steps through the same model actions a click uses, logs what each did, then (optionally) draws
    /// every section. Steps: `off:water`, `on:water`, `low:water:30`, `high:walk:200`, `budget:weekday:9`,
    /// `mode:strict`, `due:stretch`, `stage:3` (wait for it), `app:<bundle>:<work|leisure|call|untouchable|auto>`,
    /// `hotkey` (⌃⌥K), `hotkey:std`, `chats:30|never`, `name:<text>`, `reset`, `shot:<section>:<label>`.
    func runDemo(_ steps: [String], snapshot dir: URL?) {
        Task {
            for step in steps where !step.isEmpty {
                model.refusal = nil
                let parts = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let need = parts.count > 1 ? Need(rawValue: parts[1]) : nil
                switch parts[0] {
                case "off": if let need { model.changeCare(.need(need, on: false)) }
                case "on": if let need { model.changeCare(.need(need, on: true)) }
                case "low": if let need, parts.count > 2, let v = Int(parts[2]) { model.changeCare(.low(need, v)) }
                case "high": if let need, parts.count > 2, let v = Int(parts[2]) { model.changeCare(.high(need, v)) }
                case "budget":
                    if parts.count > 2, let h = Int(parts[2]) { model.changeCare(.budget(weekend: parts[1] == "weekend", hours: h)) }
                case "mode": if parts.count > 1, let m = BalanceMode(rawValue: parts[1]) { model.setMode(m) }
                case "due": if let need { balance.makeDue(need) }
                case "stage":
                    let target = parts.count > 1 ? Int(parts[1]) ?? 3 : 3
                    for _ in 0..<480 where (balance.engine.state.episode?.stage ?? -1) < target {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    balance.timeScale = 1                        // stay on this stage while the next steps run
                case "app":
                    if parts.count > 2 { model.setCategory(parts[1], parts[2] == "auto" ? nil : AppCategory(rawValue: parts[2])) }
                case "hotkey":
                    apply(hotkey: parts.count > 1 && parts[1] == "std" ? .standard
                          : HotkeySpec(keyCode: 40, modifiers: HotkeySpec.control | HotkeySpec.option, label: "⌃⌥K"))
                case "chats": model.setChatDays(parts.count > 1 ? Int(parts[1]) : nil)
                case "name": model.saveName(parts.dropFirst().joined(separator: ":"))
                case "reset": balance.resetNeeds()
                case "shot":                                                   // draw a section right now
                    model.section = parts.count > 1 ? MainSection(rawValue: parts[1]) ?? .settings : .settings
                    try? await Task.sleep(for: .milliseconds(1500))
                    if let dir { snapshot(to: dir.appending(path: "main-\(model.section?.rawValue ?? "")-\(parts.count > 2 ? parts[2] : "now").png")) }
                default: log("main demo: unknown step \(step)")
                }
                refresh()
                refreshSettings()
                let care = model.care
                log("main demo \(step): refused=\(model.refusal != nil) locked=\(model.locked) mode=\(model.mode.rawValue) "
                    + "off=\(care.off.map(\.rawValue).sorted()) water=\(care.range(.water).low)-\(care.range(.water).high) "
                    + "weekday=\(care.weekdayHours)h hotkey=\(model.hotkeyLabel) chats=\(model.chatDays.map(String.init) ?? "never") "
                    + "stage=\(balance.engine.state.episode.map { "\($0.need.rawValue)@\($0.stage)" } ?? "-")")
                try? await Task.sleep(for: .milliseconds(800))
            }
            if let dir { await snapshots(to: dir) }
            log("main demo done")
        }
    }

    /// Each section's own drawing to `<dir>/main-<section>.png` (no Screen Recording needed).
    /// The window is made tall for it (long sections fit), then put back.
    func snapshots(to dir: URL) async {
        guard let window else { return }
        let saved = window.frame
        var tall = saved
        tall.size.height = 1500
        tall.origin.y = saved.maxY - tall.height
        window.setFrame(tall, display: true)
        for section in MainSection.allCases {
            model.section = section
            try? await Task.sleep(for: .milliseconds(2000))
            snapshot(to: dir.appending(path: "main-\(section.rawValue).png"))
            if section == .settings || section == .today || section == .week, scrollToBottom(window.contentView) {
                try? await Task.sleep(for: .milliseconds(1200))
                snapshot(to: dir.appending(path: "main-\(section.rawValue)-end.png"))
            }
        }
        window.setFrame(saved, display: true)
    }

    /// The section's scroll view, scrolled to its end (`false` = nothing to scroll).
    private func scrollToBottom(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView,
           doc.frame.height > scroll.contentView.bounds.height + 1, scroll.frame.width > 300 {
            let y = doc.isFlipped ? doc.frame.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return true
        }
        return view.subviews.contains { scrollToBottom($0) }
    }

    private func snapshot(to url: URL) {
        guard let window else { return }
        let ok = WindowSnapshot.write(window, to: url)
        log("main snapshot \(url.lastPathComponent) \(ok ? "\(Int(window.frame.width))×\(Int(window.frame.height))" : "failed")")
    }
}
