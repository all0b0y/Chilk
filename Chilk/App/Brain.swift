import AppKit
import ChilkBrain
import ChilkCore

/// Чилк's connection to Codex (В4, В7): his own isolated profile. A conversation continues its thread for
/// 15 minutes; after that it starts clean on a spare thread that is already warm (a new thread's first turn
/// takes 4–11 s, later ones 1–2.5 s — spike 002). Problems are reported, never papered over.
@MainActor
final class Brain {
    enum State: Equatable {
        case missingCodex
        case signedOut
        case connecting
        case ready
        case failed(String)
    }

    private(set) var state: State = .connecting { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    private(set) var account: String?
    private var setup: CodexSetup?
    private var client: CodexClient?
    /// The thread of the current (or last) conversation and when it last answered.
    private var active: String?
    private var lastExchange: Date?
    /// A warm thread for the next clean start.
    private var spare: Task<String, Error>?
    /// The turn in flight: an interrupted one must finish before the next starts on the same thread.
    private var inFlight: Task<String, Error>?

    private let tools: [CodexTool]
    private let onTool: CodexToolHandler?

    init(tools: [CodexTool] = [], onTool: CodexToolHandler? = nil) {
        self.tools = tools
        self.onTool = onTool
        Task { await connect() }
    }

    /// What to tell the user instead of answering (`nil` = can talk).
    var problem: String? {
        switch state {
        case .ready, .connecting: nil
        case .signedOut: Lines.brainSignedOut
        case .missingCodex: Lines.brainMissing
        case .failed: Lines.brainFailed
        }
    }

    var statusLine: String {
        switch state {
        case .ready: String(localized: "Codex: на связи") + (account.map { " (\($0))" } ?? "")
        case .connecting: String(localized: "Codex: подключаюсь…")
        case .signedOut: String(localized: "Codex: не выполнен вход")
        case .missingCodex: String(localized: "Codex: не найден на этом Mac")
        case .failed(let why): String(localized: "Codex: ошибка — \(why)")
        }
    }

    func connect() async {
        await client?.stop()
        active = nil
        spare = nil
        inFlight = nil
        state = .connecting
        guard let exe = CodexSetup.locateCodex() else { state = .missingCodex; return }
        let setup = CodexSetup(dataDir: CodexSetup.defaultDataDir, executable: exe)
        do { try setup.prepare() } catch { state = .failed(error.localizedDescription); return }
        let client = setup.makeClient()
        self.setup = setup
        self.client = client
        await client.observe("account/login/completed") { params in
            let ok = params["success"]?.bool == true
            Task { @MainActor [weak self] in self?.loginFinished(ok) }
        }
        do {
            try await client.start()
            guard let acc = try await client.account() else { state = .signedOut; return }
            account = acc.email
            warmSpare()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// A fresh thread with one tiny turn already spent, so a clean start answers fast.
    private func warmSpare() {
        guard let client, let setup else { return }
        let task = Task<String, Error> {
            let id = try await client.startThread(model: setup.model, instructions: Persona.text, cwd: setup.workDir,
                                                  tools: self.tools, onTool: self.onTool)
            _ = try await client.ask(threadId: id, text: "Прогрев. Ответь одним словом: «готов».", allowTools: false)
            return id
        }
        spare = task
        Task {
            do { _ = try await task.value; if state != .ready { state = .ready } } catch { state = .failed(String(describing: error)) }
        }
    }

    /// One turn of the conversation. `onDelta` gets the whole raw message so far (JSON `{reply, mode}`).
    func ask(_ text: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        _ = try? await inFlight?.value
        let task = Task<String, Error> {
            guard let client = self.client else { throw CodexClient.ClientError.notStarted }
            let thread = try await self.threadForNow()
            let reply = try await client.ask(threadId: thread, text: text, outputSchema: JSON(any: Dialogue.schema), onDelta: onDelta)
            self.lastExchange = Date()
            return reply
        }
        inFlight = task
        return try await task.value
    }

    /// Same thread within 15 minutes of the last answer; otherwise the warm spare (and a new spare behind it).
    private func threadForNow() async throws -> String {
        if let active, Dialogue.continues(lastExchange: lastExchange, now: Date()) { return active }
        if spare == nil { warmSpare() }
        guard let spare else { throw CodexClient.ClientError.notStarted }
        let fresh = try await spare.value
        active = fresh
        warmSpare()
        return fresh
    }

    func interrupt() async {
        if let client, let active { await client.interrupt(threadId: active) }
    }

    func login() {
        guard let client else { return }
        Task {
            do { NSWorkspace.shared.open(try await client.startLogin()) } catch { state = .failed(String(describing: error)) }
        }
    }

    private func loginFinished(_ ok: Bool) {
        guard ok else { state = .signedOut; return }
        Task {
            account = try? await client?.account()?.email
            warmSpare()
        }
    }

    func shutdown() {
        let client = self.client
        Task { await client?.stop() }
    }
}

/// Чилк's character for Codex (В23). Context about the user is added per question and kept minimal (В24).
enum Persona {
    static let text = """
    Ты — Чилк, милый анимированный компаньон, живёшь у края экрана Mac и заботишься о work-life balance \
    пользователя: вода, разминка, глаза, прогулки, вовремя закончить день. Говори по-русски, на «ты», коротко: \
    1–2 предложения, до 160 символов. Тон добрый, с лёгкой подколкой. Нельзя: мат, шутки про внешность, вес и \
    здоровье, стыжение, токсичная продуктивность. Не выдумывай факты; если не знаешь — так и скажи.

    Это голосовой диалог: каждый ответ — JSON по схеме. reply — твоя реплика (простой текст, без markdown и ссылок; \
    источник называй словами). mode — что дальше: "question" — ты задал вопрос, просишь уточнить или подтвердить и \
    ждёшь ответа; "done" — просьба выполнена, ждать нечего; "end" — пользователь благодарит, прощается или говорит \
    «всё», тогда reply — короткое тёплое прощание; "answer" — во всех остальных случаях. Если просьба неоднозначна \
    (какой матч? какой город?) — сначала коротко уточни.

    Для свежих фактов (счёт, погода, новости, «последний», «сегодня») обязательно ищи в интернете. Текущая дата и \
    timezone даны в [контекст]. Различай дату события и дату публикации; для матча называй дату самого матча, \
    счёт и источник словами. Если дата или источник не подтверждены результатом поиска — не угадывай и не \
    выдавай результат за проверенный. Не смешивай завершённый матч с будущим, мужскую команду с женской.

    Реальные действия выполняй только предоставленными функциями Чилка и только по просьбе пользователя. \
    Факт «я попил воды» засчитывай через chilk_water; обещание попить не засчитывай. Таймеры и запланированный \
    короткий текст — локальные, именно в Чилке, не Apple Reminders: приложение должно работать, просроченное \
    показывается при следующем запуске. Системные напоминания, файлы и Obsidian пока недоступны. Не обещай \
    несуществующее действие. Говори «сделал» только после успешного результата инструмента; cancelled/credited=false \
    и error не означают успех. Если время сегодня уже прошло или неясно, сначала уточни. Перед отменой найди \
    точный id в списке; несколько одноимённых таймеров — повод уточнить. [контекст] не цитируй.
    """
}
