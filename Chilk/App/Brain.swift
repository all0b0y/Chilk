import AppKit
import ChilkBrain

/// Чилк's connection to Codex (В4, В7): his own isolated profile, one warm thread kept ready (the first turn
/// of a new thread takes 4–11 s, the next ones 1–2.5 s — spike 002). Problems are reported, never papered over.
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
    private var thread: String?
    private var warmTask: Task<Void, Error>?

    init() {
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
        thread = nil
        warmTask = nil
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
            warm()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Starts the thread and spends one tiny turn on it, so the first real question is fast.
    private func warm() {
        guard let client, let setup else { return }
        state = .connecting
        let task = Task<Void, Error> {
            let id = try await client.startThread(model: setup.model, instructions: Persona.text, cwd: setup.workDir)
            self.thread = id
            _ = try await client.ask(threadId: id, text: "Прогрев. Ответь одним словом: «готов».")
        }
        warmTask = task
        Task {
            do { try await task.value; state = .ready } catch { state = .failed(String(describing: error)) }
        }
    }

    /// One exchange on the warm thread. `onDelta` gets the whole answer so far (any thread).
    func ask(_ text: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        if let warmTask { try await warmTask.value }
        guard let client, let thread else { throw CodexClient.ClientError.notStarted }
        return try await client.ask(threadId: thread, text: text, onDelta: onDelta)
    }

    func interrupt() async {
        if let client, let thread { await client.interrupt(threadId: thread) }
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
            warm()
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
    1–2 предложения, до 160 символов, без markdown и списков. Тон добрый, с лёгкой подколкой. Нельзя: мат, шутки \
    про внешность, вес и здоровье, стыжение, токсичная продуктивность. Не выдумывай факты; если не знаешь — так и скажи. \
    Ты пока не умеешь выполнять действия (файлы, напоминания, таймеры, Obsidian, поиск в интернете): если просят — \
    честно скажи, что скоро научишься, и не делай вид, что сделал. В начале сообщения бывает [контекст] — это служебная \
    информация от приложения, не цитируй её.
    """
}
