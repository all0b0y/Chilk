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
    private var tray: Tray?
    private var greeting: FirstMeeting?
    private let switches = ToolSwitchStore()
    private let profile = ProfileStore()
    private let chats = ChatStore()
    private let memory = MemoryStore()
    private var chat: ChatController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        // Slice 5a (SPEC «Срез 5», decision 1): the app lives in the menu-bar tray, Chilk himself at the screen edge.
        // No Dock icon (Info.plist LSUIElement as well, so it never flashes at launch).
        app.setActivationPolicy(.accessory)
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
        let switches = self.switches
        let memory = self.memory
        let brain = Brain(tools: { ChilkToolCatalog.tools(for: switches.switches) },
                          threadConfig: { ChilkToolCatalog.threadConfig(for: switches.switches) },
                          memory: { memory.book.instructions }) { [weak actions] call in
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
        phrases.enabled = { switches.isOn(.phrases) }
        phrases.log = { [weak balance] in balance?.log($0) }
        if !switches.isOn(.phrases) { phrases.switchChanged() }
        self.phrases = phrases
        // Codex-written warm-ups, prepared ahead; the library when there is none (decision 2026-10-05).
        let warmups = WarmupSource(brain: brain)
        warmups.busy = { [weak conversation] in conversation?.isActive ?? false }
        warmups.log = { [weak balance] in balance?.log($0) }
        balance.warmups = warmups
        let profile = self.profile
        conversation.context = { [weak balance] in
            Lines.context(sittingMinutes: balance?.sittingMinutes ?? 0, name: profile.profile.name)
        }
        conversation.onEnd = { [weak balance, weak ears] in balance?.resume(); ears?.resume() }
        conversation.chilkFrame = { [weak edge] in (edge?.windowFrame ?? .zero, edge?.edge == .left) }

        // Tray → Tools (decision 9): switched-off tools leave new threads; folder kinds pause their folders.
        actions.switches = { switches.switches }
        actions.files.enabledKinds = {
            Set([ChilkFileScope.files, .obsidian].filter { switches.isOn($0.ability) })
        }
        switches.onChange.append { [weak brain, weak phrases] in
            brain?.catalogChanged()
            phrases?.switchChanged()
        }

        // Slice 5b: the chat (voice and text in one log) and Chilk's memory.
        let chat = ChatController(store: chats, memory: memory, brain: brain, conversation: conversation, ears: ears,
                                  sim: edge.sim)
        chat.context = { [weak conversation] in conversation?.context() ?? "" }
        chat.log = { [weak balance] in balance?.log($0) }
        self.chat = chat
        actions.memory = memory
        actions.onChip = { [weak chat] thread, chip in chat?.chip(chip, thread: thread) }
        brain.onWebSearch = { [weak chat] thread in chat?.chip(ChatChip(kind: .webSearch), thread: thread) }
        brain.onTurnStart = { [weak chat] thread in chat?.turnStarted(thread) }
        chat.onTurnEnd = { [weak balance] in balance?.resume() }
        memory.onChange.append { [weak brain] in brain?.memoryChanged() }
        conversation.onTurn = { [weak chat] question, answer, thread in
            chat?.recordVoice(question: question, answer: answer, thread: thread)
        }

        let tray = Tray(edge: edge, balance: balance, brain: brain, ears: ears, actions: actions,
                        conversation: conversation, switches: switches)
        tray.log = { [weak balance] in balance?.log($0) }
        tray.menu = { [weak self] in self?.trayMenu() ?? NSMenu() }
        tray.openChat = { [weak chat] in chat?.show() }
        self.tray = tray
        let greeting = FirstMeeting(profile: profile, edge: edge, balance: balance)
        greeting.log = { [weak balance] in balance?.log($0) }
        greeting.onNamed = { [weak tray] in tray?.nudge() }
        self.greeting = greeting

        // Who holds the stage: a conversation, a due timer, Chilk on the hero card, the greeting, a typed question.
        balance.isBusy = { [weak conversation, weak actions, weak tray, weak greeting, weak chat] in
            (conversation?.isActive ?? false) || (actions?.ownsStage ?? false) || (tray?.holdsChilk ?? false)
                || (greeting?.isActive ?? false) || (chat?.thinking ?? false)
        }
        chat.chilkFree = { [weak conversation, weak actions, weak balance, weak tray, weak greeting, weak edge] in
            guard let edge else { return false }
            return !(conversation?.isActive ?? true) && !(actions?.noticeWaiting ?? true) && !(balance?.isOccupied ?? true)
                && !(tray?.holdsChilk ?? true) && !(greeting?.isActive ?? true) && !edge.sim.isTalking
        }
        actions.conversationActive = { [weak conversation, weak tray, weak greeting] in
            (conversation?.isActive ?? false) || (tray?.holdsChilk ?? false) || (greeting?.isActive ?? false)
        }
        greeting.canPresent = { [weak conversation, weak actions, weak balance, weak tray] in
            !(conversation?.isActive ?? true) && !(actions?.ownsStage ?? true) && !(balance?.isOccupied ?? true)
                && !(tray?.holdsChilk ?? true)
        }
        tray.isFree = { [weak conversation, weak actions, weak balance, weak greeting, weak edge] in
            guard let edge else { return false }
            return !(conversation?.isActive ?? true) && !(actions?.noticeWaiting ?? true) && !(balance?.isOccupied ?? true)
                && !(greeting?.isActive ?? true) && !edge.sim.isTalking && edge.sim.standOut == .docked
        }
        balance.onNudge = { [weak tray] in tray?.nudge() }
        actions.onDue = { [weak tray] in tray?.nudge() }

        // Bubble buttons: a conversation's own («Подробнее», «Да / Нет»), the greeting's, then the balance's.
        let balanceButton = edge.onButton
        edge.onButton = { [weak conversation, weak greeting] i in
            if conversation?.pressedButton(i) == true { return }
            if greeting?.pressedButton(i) == true { return }
            balanceButton?(i)
        }
        ears.onWake = { [weak conversation] in conversation?.wake() }
        // «Можно я загляну…?» (decision 2026-10-05): buttons only, 60 s, no answer = no for now.
        actions.files.askUser = { [weak conversation] text in
            guard let index = await conversation?.ask(text, buttons: [Lines.yes, Lines.no], timeout: 60) else { return nil }
            return index == 0
        }
        ears.onDisabled = { [weak conversation] in conversation?.muteEars() }
        ears.onError = { [weak conversation] in conversation?.muteEars() }
        ears.notice = { [weak edge, weak conversation] line in
            if conversation?.isActive != true { edge?.sim.call(line: line) }
        }
        ears.log = { [weak balance] in balance?.log($0) }
        ears.start()
        conversation.log = { [weak balance] in balance?.log($0) }
        balance.escalation.onPause = { [weak self] paused in self?.quitShortcut(enabled: !paused) }
        brain.onChange = { [weak balance, weak brain, weak phrases] in
            balance?.log("brain \(brain?.statusLine ?? "?")")
            phrases?.refreshIfNeeded()                     // the day's batch as soon as Codex is ready
            balance?.warmups?.prepareIfNeeded()
        }
        // A click on him while he listens = «I'm done talking»; on a due timer = «seen»; in the greeting = next line;
        // otherwise the balance poke.
        edge.onPoke = { [weak conversation, weak actions, weak greeting, weak balance] in
            if conversation?.clicked() == true { return }
            if actions?.clicked() == true { return }
            if greeting?.clicked() == true { return }
            balance?.poked()
        }
        let key = Hotkey.defaultKey
        hotkey = Hotkey(keyCode: key.code, modifiers: key.modifiers, id: 1) { [weak conversation] in conversation?.trigger() }
        let env = ProcessInfo.processInfo.environment
        if env["CHILK_DEMO_TALK"] != nil {
            Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak conversation] _ in
                MainActor.assumeIsolated { conversation?.trigger() }
            }
        }
        // Acceptance only: CHILK_DEMO_TRAY=<seconds> opens the popover after that long (no Screen Recording needed
        // to check the hand-off in the log); CHILK_DEMO_TRAY_CLOSE=<seconds> closes it again.
        if let after = env["CHILK_DEMO_TRAY"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak tray] _ in
                MainActor.assumeIsolated { tray?.show(demo: true) }
            }
            if let close = env["CHILK_DEMO_TRAY_CLOSE"].flatMap(Double.init) {
                Timer.scheduledTimer(withTimeInterval: after + close, repeats: false) { [weak tray] _ in
                    MainActor.assumeIsolated { tray?.close() }
                }
            }
        }
        if let raw = env["CHILK_DEMO_TOOL_OFF"] {
            for name in raw.split(separator: ",") { if let a = ChilkAbility(rawValue: String(name)) { switches.set(a, on: false) } }
        }
        // Acceptance only: CHILK_DEMO_CHAT="first||second||@new||@oldest||…" types these into the chat window one by
        // one once Codex is ready; CHILK_DEMO_CHAT_SNAPSHOT=/file.png draws the window afterwards.
        if let raw = env["CHILK_DEMO_CHAT"], !raw.isEmpty {
            chat.runDemo(raw.components(separatedBy: "||"),
                         snapshot: env["CHILK_DEMO_CHAT_SNAPSHOT"].map { URL(fileURLWithPath: $0) })
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        balance?.save()
        actions?.shutdown()
        phrases?.shutdown()
        tray?.shutdown()
        brain?.shutdown()
        ears?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Right click on the tray icon (decision 5)

    /// «Позвать Чилка», «Проверка ▸» for acceptance, «О Чилке», «Выйти». Everything else is in the popover.
    private func trayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Позвать Чилка") + "  " + Hotkey.defaultKey.label, #selector(callChilk)))
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
        sub.addItem(.separator())
        // The edge side moves to Settings (5c); until then it is here and by dragging him.
        sub.addItem(edge?.edge == .left
            ? item(String(localized: "Переселить к правому краю"), #selector(moveRight))
            : item(String(localized: "Переселить к левому краю"), #selector(moveLeft)))
        check.submenu = sub
        menu.addItem(check)
        menu.addItem(.separator())
        let about = NSMenuItem(title: String(localized: "О Чилке"), action: #selector(about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(withTitle: String(localized: "Выйти из Чилка"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func callChilk() { conversation?.trigger() }
    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func moveLeft() { edge?.move(to: .left) }
    @objc private func moveRight() { edge?.move(to: .right) }
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

    /// Under the pause ⌘Q is off: the way out is the emergency exit. Logout and Force Quit still work.
    private func quitShortcut(enabled: Bool) {
        NSApp.mainMenu?.items.first?.submenu?.items.first { $0.action == #selector(NSApplication.terminate(_:)) }?
            .keyEquivalent = enabled ? "q" : ""
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
        // Slice 5b: the chat window needs editing keys (⌘C / ⌘V / ⌘A / ⌘Z) and ⌘W / ⌘M.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: String(localized: "Правка"))
        edit.addItem(withTitle: String(localized: "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Выделить всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: String(localized: "Окно"))
        window.addItem(withTitle: String(localized: "Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        NSApp.windowsMenu = window
        return main
    }
}
