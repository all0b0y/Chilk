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
    private var game: GameController?
    /// Slice 8c: confirmation cards.
    private var cards: CardDesk?
    /// Slice 8d: timers in Apple's Clock.
    private var clock: ClockTimers?
    /// Slice 8a: «Я упал» waits for a free moment (after the greeting, not over a conversation or a game).
    private var crashTimer: Timer?
    private var crashWaits = 0
    private var greeting: FirstMeeting?
    private var hide: HideController?
    private var ambience: AmbienceController?
    private var disco: DiscoController?
    private let switches = ToolSwitchStore()
    private let profile = ProfileStore()
    private let chats = ChatStore()
    private let memory = MemoryStore()
    private let settings = SettingsStore()
    private var chat: ChatController?
    private var main: MainWindowController?

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
        let settings = self.settings
        let edge = EdgeController()
        edge.screenChoice = { settings.settings.screen }
        edge.show()
        self.edge = edge
        let presence = PresenceMonitor(sim: edge.sim)
        self.presence = presence
        let balance = BalanceController(sim: edge.sim, edge: edge, presence: presence, settings: settings)
        self.balance = balance
        // Slice 6d: hidden behind the screen edge (survives a relaunch).
        let hide = HideController(sim: edge.sim)
        hide.log = { [weak balance] in balance?.log($0) }
        ClockCheck.log = { [weak balance] in balance?.log($0) }
        if hide.isHidden { balance.log("hidden at launch") }
        self.hide = hide
        balance.hideout = hide
        edge.onHideDrop = { [weak hide] in hide?.hide("dragged") }
        edge.onPullOut = { [weak hide] in hide?.show("dragged out") }
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
        conversation.context = { [weak balance, weak hide] in
            Lines.context(sittingMinutes: balance?.sittingMinutes ?? 0, name: profile.profile.name,
                          balance: balance?.engine.brief(), hidden: hide?.isHidden ?? false)
        }
        conversation.onEnd = { [weak balance, weak ears, weak hide] in hide?.applyPending(); balance?.resume(); ears?.resume() }
        conversation.refusal = { [weak balance] in balance?.refusal() }        // «лежит» (6b)
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
        let chat = ChatController(store: chats, brain: brain, conversation: conversation, ears: ears, sim: edge.sim)
        chat.context = { [weak conversation] in conversation?.context() ?? "" }
        chat.log = { [weak balance] in balance?.log($0) }
        chat.refusal = { [weak balance] in balance?.refusal() }
        self.chat = chat
        actions.memory = memory
        actions.onChip = { [weak chat] thread, chip in chat?.chip(chip, thread: thread) }
        // Slice 6c: Codex's emotions play on the live Chilk at the edge — in a conversation (before the words) and
        // for a chat turn while he thinks there; otherwise `chilk_busy`.
        // Lying (6b) he plays nothing: in Тишина he talks, but an emotion would fight the pose.
        actions.canEmote = { [weak conversation, weak chat, weak balance] in
            !(balance?.engine.slumped ?? false) && ((conversation?.canEmote ?? false) || (chat?.canEmote ?? false))
        }
        actions.playEmote = { [weak balance] e, strong in balance?.queueEmote(e, strong: strong) }
        conversation.takeEmote = { [weak balance] in balance?.takeQueuedEmote() }
        conversation.playEmote = { [weak balance] e, strong in balance?.playBesideBubble(e, strong: strong) }
        chat.takeEmote = { [weak balance] in balance?.takeQueuedEmote() }
        chat.playEmote = { [weak balance] e, strong in balance?.playBesideBubble(e, strong: strong) }
        brain.onWebSearch = { [weak chat] thread in chat?.chip(ChatChip(kind: .webSearch), thread: thread) }
        brain.onTurnStart = { [weak chat] thread in chat?.turnStarted(thread) }
        chat.onTurnEnd = { [weak balance, weak hide] in hide?.applyPending(); balance?.resume() }
        memory.onChange.append { [weak brain] in brain?.memoryChanged() }
        conversation.onTurn = { [weak chat] question, answer, thread in
            chat?.recordVoice(question: question, answer: answer, thread: thread)
        }

        let tools = ToolsBridge(switches: switches, ears: ears, files: actions.files)
        tools.log = { [weak balance] in balance?.log($0) }
        let tray = Tray(edge: edge, balance: balance, brain: brain, ears: ears, actions: actions,
                        conversation: conversation, tools: tools)
        tray.log = { [weak balance] in balance?.log($0) }
        tray.menu = { [weak self] in self?.trayMenu() ?? NSMenu() }
        tray.openChat = { [weak chat] in chat?.show() }
        self.tray = tray
        // Slice 7a: the notebook with the games; Chilk leaves the edge for it.
        let game = GameController(edge: edge, balance: balance,
                                  seed: ProcessInfo.processInfo.environment["CHILK_DEMO_GAME_SEED"].flatMap { UInt64($0) })
        game.log = { [weak balance] in balance?.log($0) }
        game.conversationActive = { [weak conversation, weak actions] in
            (conversation?.isActive ?? false) || (actions?.noticeWaiting ?? false)
        }
        game.court.log = { [weak balance] in balance?.log($0) }
        game.court.conversationActive = game.conversationActive
        // Decision 32: the user's call puts the hoop away with a «тсс»; full screen — quietly.
        let demoCall = ProcessInfo.processInfo.environment["CHILK_DEMO_CALL"].map { $0.split(separator: ",").compactMap { Double($0) } }
        let launched = Date()
        game.court.inCall = { [weak balance] in
            if let d = demoCall, d.count == 2 {
                let t = Date().timeIntervalSince(launched)
                return t >= d[0] && t < d[0] + d[1]
            }
            return balance?.lastSignals?.inCall ?? false
        }
        game.court.fullScreen = { [weak balance] in demoCall == nil && (balance?.lastSignals?.fullscreen ?? false) }
        actions.openGame = { [weak game] kind, length in game?.request(kind, length: length) ?? .failure("Games unavailable") }
        tray.playGame = { [weak game] kind in game?.playFromPopover(kind) }
        tray.savedGame = { [weak game] in game?.savedScore }
        tray.gameRefusal = { [weak game] in game?.refusalLine() }
        self.game = game

        // Slice 5c: the main window — Сегодня, Неделя, Память, Инструменты, Настройки.
        let main = MainWindowController(balance: balance, settings: settings, profile: profile, chats: chats, memory: memory,
                                        tools: tools, edge: edge)
        main.log = { [weak balance] in balance?.log($0) }
        main.setHotkey = { [weak self] spec in self?.registerHotkey(spec) ?? false }
        main.pauseHotkey = { [weak self] paused in
            guard let self else { return }
            if paused { self.hotkey = nil } else if !self.registerHotkey(settings.settings.hotkey) { _ = self.registerHotkey(.standard) }
        }
        self.main = main
        tray.openMain = { [weak main] in main?.show(.today) }
        tray.openSettings = { [weak main] in main?.show(.settings) }
        chat.model.openMemory = { [weak main] in main?.show(.memory) }
        let greeting = FirstMeeting(profile: profile, edge: edge, balance: balance)
        greeting.log = { [weak balance] in balance?.log($0) }
        greeting.onNamed = { [weak tray] in tray?.nudge() }
        self.greeting = greeting

        // Who holds the stage: a conversation, a due timer, Chilk on the hero card, the greeting, a typed question.
        balance.isBusy = { [weak conversation, weak actions, weak tray, weak greeting, weak chat, weak game] in
            (conversation?.isActive ?? false) || (actions?.ownsStage ?? false) || (tray?.holdsChilk ?? false)
                || (greeting?.isActive ?? false) || (chat?.thinking ?? false) || (game?.holdsChilk ?? false)
        }
        chat.chilkFree = { [weak conversation, weak actions, weak balance, weak tray, weak greeting, weak edge, weak game] in
            guard let edge else { return false }
            return !(conversation?.isActive ?? true) && !(actions?.noticeWaiting ?? true) && !(balance?.isOccupied ?? true)
                && !(tray?.holdsChilk ?? true) && !(greeting?.isActive ?? true) && !edge.sim.isTalking
                && !(game?.holdsChilk ?? true)
                && !edge.sim.hidden                           // 6d: hidden, no thinking pose (and no emotions)
        }
        actions.conversationActive = { [weak conversation, weak tray, weak greeting] in
            (conversation?.isActive ?? false) || (tray?.holdsChilk ?? false) || (greeting?.isActive ?? false)
        }
        greeting.canPresent = { [weak conversation, weak actions, weak balance, weak tray, weak game] in
            !(conversation?.isActive ?? true) && !(actions?.ownsStage ?? true) && !(balance?.isOccupied ?? true)
                && !(tray?.holdsChilk ?? true) && !(game?.holdsChilk ?? true)
        }
        tray.isFree = { [weak conversation, weak actions, weak balance, weak greeting, weak edge] in
            guard let edge else { return false }
            return !(conversation?.isActive ?? true) && !(actions?.noticeWaiting ?? true) && !(balance?.isOccupied ?? true)
                && !(greeting?.isActive ?? true) && !edge.sim.isTalking && edge.sim.standOut == .docked
        }
        // Slice 7a: like the popover's rule, but a stage 1–2 request bubble does not keep him — it moves into the
        // notebook. Wired here: `greeting` must exist before it is captured.
        game.whyBusy = { [weak conversation, weak actions, weak balance, weak greeting, weak tray, weak edge] in
            guard let edge else { return ["gone"] }
            let reasons: [(Bool, String)] = [
                (conversation?.isActive ?? true, "conversation"), (actions?.noticeWaiting ?? true, "notice"),
                (balance?.isOccupiedApartFromRequest ?? true, "balance"), (greeting?.isActive ?? true, "greeting"),
                (tray?.holdsChilk ?? true, "popover"), (edge.sim.isTalking, "talking"),
                (edge.sim.act?.isEmotion == true, "emotion"),
            ]
            return reasons.filter(\.0).map(\.1)
        }
        game.isFree = { [weak game] in game?.whyBusy().isEmpty ?? false }
        // Slice 6e: a leap to another monitor waits until Chilk is free.
        edge.hopBusy = { [weak conversation, weak actions, weak balance, weak tray, weak greeting, weak chat, weak edge,
                          weak game] in
            (conversation?.isActive ?? false) || (actions?.noticeWaiting ?? false) || (balance?.isOccupied ?? false)
                || (tray?.holdsChilk ?? false) || (greeting?.isActive ?? false) || (chat?.thinking ?? false)
                || (edge?.sim.isTalking ?? false) || (game?.holdsChilk ?? false)
        }
        edge.log = { [weak balance] in balance?.log($0) }
        // Slice 6f-1: the light around him (the built-in display's brightness).
        let ambience = AmbienceController(sim: edge.sim)
        ambience.log = { [weak balance] in balance?.log($0) }
        ambience.busy = { [weak edge] in edge?.hopBusy() ?? false }
        ambience.eyesPressure = { [weak balance] in balance?.engine.pressure(.eyes) ?? 0 }
        ambience.onBuiltin = { [weak edge] in edge?.homeIsBuiltin ?? false }
        self.ambience = ambience
        // Slice 6f-2: music → the disco ball and a dance.
        let disco = DiscoController(sim: edge.sim, edge: edge)
        disco.log = { [weak balance] in balance?.log($0) }
        disco.busy = { [weak edge] in edge?.hopBusy() ?? false }
        disco.marked = { [weak self] in self?.settings.settings.apps.music ?? [] }
        disco.callOrVideo = { [weak balance] in
            guard let s = balance?.lastSignals else { return false }
            return s.inCall || s.video
        }
        self.disco = disco
        hide.onHideAsked = { [weak conversation] in conversation?.endForHide() }
        hide.canPeek = { [weak tray, weak chat, weak edge] in
            (tray?.isFree() ?? false) && !(tray?.holdsChilk ?? true) && !(chat?.thinking ?? true) && edge?.sim.act == nil
        }
        hide.onShown = { [weak balance] in balance?.resume() }
        balance.onNudge = { [weak tray] in tray?.nudge() }
        actions.onDue = { [weak tray] in tray?.nudge() }

        // Slice 8c: confirmation cards — after a conversation, a due notice or a request, the card comes back.
        let cards = CardDesk(sim: edge.sim)
        cards.log = { [weak balance] in balance?.log($0) }
        cards.chilkFrame = conversation.chilkFrame
        cards.stageFree = { [weak conversation, weak actions, weak balance, weak tray, weak greeting, weak chat, weak game, weak edge] in
            guard let edge else { return false }
            return !(conversation?.isActive ?? true) && !(actions?.noticeWaiting ?? true) && !(balance?.isOccupied ?? true)
                && !(tray?.holdsChilk ?? true) && !(greeting?.isActive ?? true) && !(chat?.thinking ?? true)
                && !(game?.holdsChilk ?? true) && !edge.sim.isTalking
        }
        cards.commit = { [weak actions] card in await actions?.commit(card) ?? (false, String(localized: "Не получилось — ничего не изменилось")) }
        cards.onChange = { [weak chat] in chat?.refreshCard() }
        cards.onResult = { [weak chat] id, line, _ in chat?.cardResult(id, line) }
        // Slice 8d: Clock timers through the shortcut «Чилк» — offered once at launch of a new build.
        let clock = ClockTimers()
        clock.log = { [weak balance] in balance?.log($0) }
        clock.stageFree = { [weak cards] in cards?.stageFree() ?? false }
        clock.speak = { [weak edge] line in edge?.sim.say(line, duration: 9) }
        actions.clock = clock
        self.clock = clock
        clock.checkAtLaunch()
        cards.onLeftConversation = { [weak conversation] in conversation?.cardLeft() }
        if let dir = ProcessInfo.processInfo.environment["CHILK_DEMO_CARD_SNAPSHOT"].map({ URL(fileURLWithPath: $0) }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            cards.snapshot = { [weak edge, weak chat] name in
                guard let edge else { return }
                _ = WindowSnapshot.writeScreen(edge.homeVisibleFrame, to: dir.appending(path: "\(name).png"))
                chat?.snapshot(to: dir.appending(path: "\(name)-chat.png"))
            }
        }
        actions.cards = cards
        conversation.cards = cards
        chat.cards = cards
        self.cards = cards
        let chatFree = chat.chilkFree
        chat.chilkFree = { [weak cards] in !(cards?.ownsStage ?? false) && chatFree() }
        let trayFree = tray.isFree
        tray.isFree = { [weak cards] in !(cards?.ownsStage ?? false) && trayFree() }
        let greetingCan = greeting.canPresent
        greeting.canPresent = { [weak cards] in !(cards?.ownsStage ?? false) && greetingCan() }
        let gameWhy = game.whyBusy
        game.whyBusy = { [weak cards] in gameWhy() + ((cards?.hasCard ?? false) ? ["card"] : []) }   // decision: no game over a card
        let hop = edge.hopBusy
        edge.hopBusy = { [weak cards] in (cards?.ownsStage ?? false) || hop() }

        // Bubble buttons: a conversation's own («Подробнее», «Да / Нет», a card in its bubble), the greeting's,
        // basketball's, a card's at the edge, then the balance's.
        let balanceButton = edge.onButton
        edge.onButton = { [weak conversation, weak greeting, weak game, weak cards] i in
            if conversation?.pressedButton(i) == true { return }
            if greeting?.pressedButton(i) == true { return }
            if game?.pressedButton(i) == true { return }             // 7b: basketball's own bubbles
            if cards?.pressed(i, source: .edge) == true { return }   // 8c
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
        ears.notice = { [weak edge, weak conversation, weak hide, weak balance] line in
            // 6d: hidden, an ears notice («Учусь слышать…» at launch) must not pull him out — the tray shows it.
            if hide?.isHidden == true { balance?.log("ears notice while hidden: \(line)"); return }
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
        edge.onPoke = { [weak conversation, weak actions, weak greeting, weak balance, weak hide] in
            if conversation?.clicked() == true { return }
            if actions?.clicked() == true { return }
            if greeting?.clicked() == true { return }
            if hide?.clicked() == true { return }                 // 6d: a click on him peeking = out for good
            balance?.poked()
        }
        if !registerHotkey(settings.settings.hotkey) { _ = registerHotkey(.standard) }
        let env = ProcessInfo.processInfo.environment
        // Slice 8a (decision 15): «Я упал в ЧЧ:ММ — уже снова тут» after a real crash — once, when he is free.
        let left = CrashWatch.launch()
        if !left.isEmpty {
            if let crashed = CrashWatch.check(left, final: false) {
                tellCrash(crashed)
            } else {
                Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if let crashed = CrashWatch.check(left, final: true) { self?.tellCrash(crashed) }
                    }
                }
            }
        }
        if let s = env["CHILK_DEMO_CRASH"].flatMap(Double.init), env["CHILK_STATE_DIR"] != nil {
            Timer.scheduledTimer(withTimeInterval: s, repeats: false) { _ in fatalError("CHILK_DEMO_CRASH: acceptance crash") }
        }
        if let spec = env["CHILK_DEMO_GAME"] { game.demo(spec, snapshots: env["CHILK_DEMO_GAME_SNAPSHOT"]) }
        if let spec = env["CHILK_DEMO_DRAUGHTS"] { game.demoDraughts(spec, snapshots: env["CHILK_DEMO_GAME_SNAPSHOT"]) }
        if let spec = env["CHILK_DEMO_SEA"] { game.demoSea(spec, snapshots: env["CHILK_DEMO_GAME_SNAPSHOT"]) }
        if let spec = env["CHILK_DEMO_COURT"] { game.demoCourt(spec, snapshots: env["CHILK_DEMO_GAME_SNAPSHOT"]) }
        // SPEC «Умолчания»: launch at login is on until the user switches it off (not in isolated acceptance runs).
        // Saved only once it really worked: a failed registration is tried again at the next launch.
        if settings.settings.launchAtLogin == nil, env["CHILK_STATE_DIR"] == nil {
            if let failure = LoginItem.set(true) {
                balance.log("launch at login not registered, will retry: \(failure)")
            } else {
                settings.update { $0.launchAtLogin = true }
                balance.log("launch at login on by default")
            }
        } else if settings.settings.launchAtLogin == true, env["CHILK_STATE_DIR"] == nil {
            _ = LoginItem.set(true)                         // follows the app if it moved (build folder → /Applications)
        }
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
        // Acceptance only: CHILK_DEMO_MAIN=<section> opens the main window after 3 s; CHILK_DEMO_SETTINGS="off:water,…"
        // runs Settings steps through the same actions as clicks; CHILK_DEMO_MAIN_SNAPSHOT=/dir draws every section.
        if let raw = env["CHILK_DEMO_MAIN"], let section = MainSection(rawValue: raw) {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak main] _ in
                MainActor.assumeIsolated {
                    main?.show(section)
                    let steps = (env["CHILK_DEMO_SETTINGS"] ?? "").components(separatedBy: ",")
                    main?.runDemo(steps, snapshot: env["CHILK_DEMO_MAIN_SNAPSHOT"].map { URL(fileURLWithPath: $0) })
                }
            }
        }
        if let raw = env["CHILK_DEMO_TOOL_OFF"] {
            for name in raw.split(separator: ",") { if let a = ChilkAbility(rawValue: String(name)) { switches.set(a, on: false) } }
        }
        // Acceptance only: CHILK_DEMO_PICK="obsidian:/a|/b" sends these folders through the panel's «Разрешить» after
        // 1.5 s, several at once (before CHILK_DEMO_MAIN's window at 3 s); what the alert would say goes to the log.
        if let spec = env["CHILK_DEMO_PICK"], env["CHILK_STATE_DIR"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak actions, weak balance] _ in
                MainActor.assumeIsolated { actions?.files.demoPick(spec) { balance?.log($0) } }
            }
        }
        // Acceptance only: CHILK_DEMO_CHAT="first||second||@new||@oldest||…" types these into the chat window one by
        // one once Codex is ready; CHILK_DEMO_CHAT_SNAPSHOT=/file.png draws the window afterwards.
        if let raw = env["CHILK_DEMO_CHAT"], !raw.isEmpty {
            chat.runDemo(raw.components(separatedBy: "||"),
                         snapshot: env["CHILK_DEMO_CHAT_SNAPSHOT"].map { URL(fileURLWithPath: $0) })
        }
    }

    private func tellCrash(_ crashed: Date) {
        guard let when = CrashNotice.when(crashed, now: Date()) else {
            balance?.log("crash notice: the last run crashed at \(crashed) — too long ago to say")
            return
        }
        let line = Lines.crashed(when)
        balance?.log("crash notice: the last run crashed at \(crashed)")
        crashWaits = 0
        crashTimer?.invalidate()
        crashTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.crashTick(line) }
        }
    }

    private func crashTick(_ line: String) {
        crashWaits += 1
        if hide?.isHidden == true {
            balance?.log("crash notice: hidden — journal only")
        } else if crashWaits < 3 || tray?.isFree() != true {
            guard crashWaits > 300 else { return }               // 10 min without a free moment: journal only
            balance?.log("crash notice: never free — journal only")
        } else if let edge {
            edge.sim.say(line, duration: 5)
            balance?.log("crash notice said")
        }
        crashTimer?.invalidate()
        crashTimer = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashWatch.quitNormally()
        balance?.save()
        settings.flush()
        actions?.shutdown()
        phrases?.shutdown()
        tray?.shutdown()
        cards?.shutdown()
        brain?.shutdown()
        ears?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Right click on the tray icon (decision 5)

    /// «Позвать Чилка», «Проверка ▸» for acceptance, «О Чилке», «Выйти». Everything else is in the popover.
    private func trayMenu() -> NSMenu {
        let menu = NSMenu()
        if hide?.isHidden == true {
            menu.addItem(item(String(localized: "Позвать Чилка"), #selector(showChilk)))       // 6d: just comes out
        } else {
            menu.addItem(item(String(localized: "Позвать Чилка") + "  " + Hotkey.label, #selector(callChilk)))
            menu.addItem(item(String(localized: "Спрятать Чилка"), #selector(hideChilk)))
        }
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
        sub.addItem(item(String(localized: "Выходка: чешет листик"), #selector(anticScratch)))
        sub.addItem(item(String(localized: "Выходка: ловит пылинку"), #selector(anticSpeck)))
        sub.addItem(item(String(localized: "Ликует"), #selector(cheerNow)))
        sub.addItem(item(String(localized: "Лежит"), #selector(slumpNow)))
        if hide?.isHidden == true { sub.addItem(item(String(localized: "Выглянуть"), #selector(peekNow))) }
        // Slice 6f-1: the looks, past the roll.
        let light = NSMenuItem(title: String(localized: "Свет"), action: nil, keyEquivalent: "")
        let lightMenu = NSMenu()
        for (title, key) in [(String(localized: "Колпак и сон"), "nightcap"), (String(localized: "Лампа"), "lamp"),
                             (String(localized: "Очки"), "sunglasses")] {
            let i = item(title, #selector(ambienceNow(_:)))
            i.representedObject = key
            lightMenu.addItem(i)
        }
        light.submenu = lightMenu
        sub.addItem(light)
        sub.addItem(item(String(localized: "Диско"), #selector(discoNow)))
        // Slice 6c: Codex's emotions, played at once and past the limits (the clown's 14 days are not spent).
        let emotions = NSMenuItem(title: String(localized: "Эмоции"), action: nil, keyEquivalent: "")
        let emotionsMenu = NSMenu()
        for (title, key) in [(String(localized: "Смеётся"), "laugh"), (String(localized: "Смеётся до упаду"), "laughStrong"),
                             (String(localized: "Клоун"), "clown"), (String(localized: "Обиделся"), "offended"),
                             (String(localized: "Голова кругом"), "dizzy"), (String(localized: "Грустит"), "sad")] {
            let i = item(title, #selector(emoteNow(_:)))
            i.representedObject = key
            emotionsMenu.addItem(i)
        }
        emotions.submenu = emotionsMenu
        sub.addItem(emotions)
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
    @objc private func showChilk() { hide?.show("tray") }
    @objc private func hideChilk() { hide?.hide("tray") }
    @objc private func peekNow() { hide?.look(seconds: 2, why: "check") }
    @objc private func ambienceNow(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let a = Ambience(rawValue: raw) { ambience?.put(a, check: true) }
    }
    @objc private func discoNow() { disco?.dance(why: "check") }
    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func makeDue(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let n = Need(rawValue: raw) { balance?.makeDue(n) }
    }
    @objc private func showPressure() { balance?.showPressure() }
    @objc private func toggleFast() { if let b = balance { b.timeScale = b.timeScale > 1 ? 1 : 60 } }
    @objc private func resetNeeds() { balance?.resetNeeds() }
    @objc private func sleepNow() { edge?.sim.fallAsleep() }
    @objc private func wakeWelcome() { presence?.wake(after: 30 * 60, hour: 15) }
    @objc private func wakeMorning() { presence?.wake(after: 8 * 3600, hour: 8) }
    @objc private func anticScratch() { edge?.sim.startAntic(.scratchLeaf) }
    @objc private func anticSpeck() { edge?.sim.startAntic(.catchSpeck) }
    @objc private func cheerNow() { balance?.cheer() }
    @objc private func slumpNow() { balance?.makeSlumped() }
    @objc private func emoteNow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        balance?.emoteForCheck(key)
    }

    /// Registers the call hotkey (replacing the current one). `false` = the system refused it; nothing is registered.
    @discardableResult
    private func registerHotkey(_ spec: HotkeySpec) -> Bool {
        hotkey = nil                                                  // unregisters the old one
        hotkey = Hotkey(keyCode: spec.keyCode, modifiers: spec.modifiers, id: 1) { [weak self] in self?.conversation?.trigger() }
        if hotkey != nil { Hotkey.label = spec.label }
        return hotkey != nil
    }

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
