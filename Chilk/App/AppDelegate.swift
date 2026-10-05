import AppKit
import ChilkCore
import ChilkBrain

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instance: AppDelegate?   // NSApplication.delegate is weak
    private var edge: EdgeController?
    private var presence: PresenceMonitor?
    private var balance: BalanceController?
    private var brain: Brain?
    private var actions: Actions?
    private var conversation: Conversation?
    private var ears: Ears?
    private var hotkey: Hotkey?
    private var phrases: PhraseBatches?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)       // lives in the Dock, not in the menu bar tray (В2)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let edge = EdgeController()
        edge.show()
        self.edge = edge
        let presence = PresenceMonitor(sim: edge.sim)
        self.presence = presence
        let balance = BalanceController(sim: edge.sim, edge: edge, presence: presence)
        self.balance = balance
        let actions = Actions(balance: balance, sim: edge.sim)
        self.actions = actions
        let brain = Brain(tools: ChilkToolCatalog.tools) { [weak actions] call in
            guard let actions else { return .failure("Chilk actions unavailable") }
            return await actions.execute(call)
        }
        let ears = Ears()
        self.ears = ears
        let conversation = Conversation(sim: edge.sim, brain: brain, ears: ears)
        self.brain = brain
        self.conversation = conversation
        let phrases = PhraseBatches(brain: brain)
        phrases.busy = { [weak conversation] in conversation?.isActive ?? false }
        phrases.log = { [weak balance] in balance?.log($0) }
        self.phrases = phrases
        conversation.context = { [weak balance] in Lines.context(sittingMinutes: balance?.sittingMinutes ?? 0) }
        conversation.onEnd = { [weak balance, weak ears] in balance?.resume(); ears?.resume() }
        conversation.chilkFrame = { [weak edge] in (edge?.windowFrame ?? .zero, edge?.edge == .left) }
        // «Подробнее» under a long answer belongs to the conversation; every other bubble button to the balance.
        let balanceButton = edge.onButton
        edge.onButton = { [weak conversation] i in
            if conversation?.pressedButton(i) == true { return }
            balanceButton?(i)
        }
        ears.onWake = { [weak conversation] in conversation?.wake() }
        ears.onDisabled = { [weak conversation] in conversation?.muteEars() }
        ears.onError = { [weak conversation] in conversation?.muteEars() }
        ears.notice = { [weak edge, weak conversation] line in
            if conversation?.isActive != true { edge?.sim.call(line: line) }
        }
        ears.log = { [weak balance] in balance?.log($0) }
        ears.start()
        conversation.log = { [weak balance] in balance?.log($0) }
        balance.isBusy = { [weak conversation, weak actions] in
            (conversation?.isActive ?? false) || (actions?.ownsStage ?? false)
        }
        actions.conversationActive = { [weak conversation] in conversation?.isActive ?? false }
        brain.onChange = { [weak balance, weak brain, weak phrases] in
            balance?.log("brain \(brain?.statusLine ?? "?")")
            phrases?.refreshIfNeeded()                     // the day's batch as soon as Codex is ready
        }
        // A click on him while he listens = «I'm done talking»; on a due timer = «seen»; otherwise the balance poke.
        edge.onPoke = { [weak conversation, weak actions, weak balance] in
            if conversation?.clicked() == true { return }
            if actions?.clicked() == true { return }
            balance?.poked()
        }
        let key = Hotkey.defaultKey
        hotkey = Hotkey(keyCode: key.code, modifiers: key.modifiers, id: 1) { [weak conversation] in conversation?.trigger() }
        if ProcessInfo.processInfo.environment["CHILK_DEMO_TALK"] != nil {
            Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak conversation] _ in
                MainActor.assumeIsolated { conversation?.trigger() }
            }
        }
        // The Dock icon is the static AppIcon (user decision: a live tile was costly and laggy).
    }

    /// Clicking the Dock icon calls Чилк out (until the voice slice arrives).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        conversation?.trigger()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        balance?.save()
        actions?.shutdown()
        phrases?.shutdown()
        brain?.shutdown()
        ears?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Позвать Чилка") + "  " + Hotkey.defaultKey.label, #selector(callChilk)))
        if let brain {
            let status = NSMenuItem(title: brain.statusLine, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if brain.state == .signedOut { menu.addItem(item(String(localized: "Войти в Codex через ChatGPT…"), #selector(loginCodex))) }
            if case .failed = brain.state { menu.addItem(item(String(localized: "Переподключить Codex"), #selector(reconnectCodex))) }
        }
        if let ears {
            let status = NSMenuItem(title: ears.status, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(item(ears.enabled ? String(localized: "Выключить уши") : String(localized: "Включить уши"), #selector(toggleEars)))
        }
        let timers = NSMenuItem(title: String(localized: "Таймеры Чилка"), action: nil, keyEquivalent: "")
        let timersMenu = NSMenu()
        let entries = actions?.executor?.entries ?? []
        if entries.isEmpty {
            let empty = NSMenuItem(title: String(localized: "Нет таймеров"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            timersMenu.addItem(empty)
        }
        for entry in entries.sorted(by: { $0.deadline < $1.deadline }) {
            let date = entry.deadline.formatted(date: .abbreviated, time: .shortened)
            let row = NSMenuItem(title: "\(entry.title) · \(date)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            timersMenu.addItem(row)
        }
        timers.submenu = timersMenu
        menu.addItem(timers)
        if let files = actions?.files { menu.addItem(files.dockItem()) }
        let side = edge?.edge == .left
            ? item(String(localized: "Переселить к правому краю"), #selector(moveRight))
            : item(String(localized: "Переселить к левому краю"), #selector(moveLeft))
        menu.addItem(side)
        menu.addItem(.separator())

        // Breaks on demand (В18).
        let pause = NSMenuItem(title: String(localized: "Перерыв"), action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        pauseMenu.addItem(item(String(localized: "Подышать 1 минуту"), #selector(breathe1)))
        pauseMenu.addItem(item(String(localized: "Подышать 3 минуты"), #selector(breathe3)))
        pauseMenu.addItem(item(String(localized: "Гимнастика для глаз"), #selector(eyeGym)))
        pauseMenu.addItem(item(String(localized: "Я попил воды"), #selector(drank)))
        pause.submenu = pauseMenu
        menu.addItem(pause)
        menu.addItem(.separator())

        // Manual acceptance helpers.
        let check = NSMenuItem(title: String(localized: "Проверка"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let needs: [(String, Need)] = [(String(localized: "Сейчас: вода"), .water), (String(localized: "Сейчас: размяться"), .stretch),
                                       (String(localized: "Сейчас: глаза"), .eyes), (String(localized: "Сейчас: прогулка"), .walk),
                                       (String(localized: "Сейчас: конец дня"), .endOfDay)]
        for (title, need) in needs {
            let i = item(title, #selector(makeDue(_:)))
            i.representedObject = need.rawValue
            sub.addItem(i)
        }
        sub.addItem(item(String(localized: "Показать давление потребностей"), #selector(showPressure)))
        let fast = item(String(localized: "Ускорить время ×60"), #selector(toggleFast))
        fast.state = (balance?.timeScale ?? 1) > 1 ? .on : .off
        sub.addItem(fast)
        sub.addItem(item(String(localized: "Сбросить потребности"), #selector(resetNeeds)))
        sub.addItem(.separator())
        sub.addItem(item(String(localized: "Уснуть"), #selector(sleepNow)))
        sub.addItem(item(String(localized: "Проснуться: «с возвращением»"), #selector(wakeWelcome)))
        sub.addItem(item(String(localized: "Проснуться: «доброе утро»"), #selector(wakeMorning)))
        check.submenu = sub
        menu.addItem(check)
        return menu
    }

    @objc private func callChilk() { conversation?.trigger() }
    @objc private func toggleEars() { ears?.toggle() }
    @objc private func loginCodex() { brain?.login() }
    @objc private func reconnectCodex() { if let brain { Task { await brain.connect() } } }
    @objc private func moveLeft() { edge?.move(to: .left) }
    @objc private func moveRight() { edge?.move(to: .right) }
    @objc private func breathe1() { balance?.startBreathing(minutes: 1) }
    @objc private func breathe3() { balance?.startBreathing(minutes: 3) }
    @objc private func eyeGym() { balance?.startEyeGym() }
    @objc private func drank() { balance?.drankWater() }
    @objc private func makeDue(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let n = Need(rawValue: raw) { balance?.makeDue(n) }
    }
    @objc private func showPressure() { balance?.showPressure() }
    @objc private func toggleFast() { if let b = balance { b.timeScale = b.timeScale > 1 ? 1 : 60 } }
    @objc private func resetNeeds() { balance?.resetNeeds() }
    @objc private func sleepNow() { edge?.sim.fallAsleep() }
    @objc private func wakeWelcome() { presence?.wake(after: 30 * 60, hour: 15) }
    @objc private func wakeMorning() { presence?.wake(after: 8 * 3600, hour: 8) }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "О Чилке"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Выйти из Чилка"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}
