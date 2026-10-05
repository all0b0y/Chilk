import AppKit
import ChilkBrain

/// Shared folders: read-only (decision 2026-10-05), any number of them, each chosen by the user — in the open panel
/// or with «Да» to Chilk's own «Можно я загляну…?». Bookmarks and filesystem work stay on dedicated actors.
///
/// Entry points for the tray popup (slice 5a): `grants`, `choose(_:)`, `remove(name:)`, `onChange`.
@MainActor
final class Files {
    typealias Runner = @Sendable (ChilkFileToolExecutor, String, JSON) async -> CodexToolResult
    enum AccessError: Error { case unavailable, busy }
    let executor: ChilkFileToolExecutor
    private var store: FolderAccessStore?
    private var loading: Task<(FolderAccessStore, [FolderGrant]), Error>?
    private var operations: [UUID: Task<CodexToolResult, Never>] = [:]
    private(set) var grants: [FolderGrant] = []
    private(set) var generation: UInt64 = 0
    private var selecting = false
    private var changing = false
    private let run: Runner
    private let requests = FolderRequests()
    private let home = FileManager.default.homeDirectoryForCurrentUser
    /// The «Да / Нет» bubble: `true` / `false`, `nil` = no answer in time or the conversation ended.
    var askUser: ((String) async -> Bool?)?
    /// The list changed (added, removed, loaded) — for whoever shows it.
    var onChange: (() -> Void)?

    init(file: URL, allowedContainer: URL = URL(fileURLWithPath: "/"),
         run: @escaping Runner = { executor, name, arguments in
             await Files.executeFileTool(executor, name, arguments)
         }) {
        executor = ChilkFileToolExecutor(allowedContainer: allowedContainer)
        self.run = run
        loading = Task {
            let store = try await FolderAccessStore(file: file, allowedContainer: allowedContainer)
            return (store, await store.grants)
        }
        Task { [weak self] in _ = await self?.waitUntilReady() }
    }

    nonisolated static func executeFileTool(_ executor: ChilkFileToolExecutor, _ name: String, _ arguments: JSON) async -> CodexToolResult {
        await executor.execute(name: name, arguments: arguments)
    }

    @discardableResult
    func waitUntilReady() async -> Bool {
        if store != nil { return true }
        guard let pending = loading else { return false }
        do {
            let loaded = try await pending.value
            guard store == nil else { return true }
            store = loaded.0
            grants = loaded.1
            loading = nil
            onChange?()
            return true
        } catch { loading = nil; return false }
    }

    func execute(_ call: CodexToolCall) async -> CodexToolResult {
        guard await waitUntilReady(), !changing else { return .failure("Folder access unavailable or changing") }
        if call.name == "chilk_request_folder" { return await request(call) }
        let snapshot = grants, version = generation, id = UUID()
        let operation = Task {
            await executor.configure(snapshot)
            guard !Task.isCancelled, !changing, generation == version else {
                return CodexToolResult.failure("Cancelled or folder access changed")
            }
            return await run(executor, call.name, call.arguments)
        }
        operations[id] = operation
        let result = await withTaskCancellationHandler(operation: { await operation.value }, onCancel: { operation.cancel() })
        operations.removeValue(forKey: id)
        guard !Task.isCancelled, !changing, generation == version else { return .failure("Cancelled or folder access changed") }
        return result
    }

    /// «Можно я загляну в „Документы/Работа“? Ищу там договор» — «Да» shares the folder for reading at once.
    private func request(_ call: CodexToolCall) async -> CodexToolResult {
        guard case .requestFolder(let path, let reason)? = try? ChilkToolCatalog.parse(name: call.name, arguments: call.arguments)
        else { return .failure("Invalid arguments: path is a full folder path, absolute or starting with ~/, without . or .. "
                                + "(see locations in chilk_list_folders); reason is 1–120 characters") }
        guard let store, let askUser else { return .failure("Chilk cannot ask right now") }
        let home = self.home
        let outcome = await requests.run(path: path, grants: grants,
            check: { url in try await store.check(.files, url: url) },
            ask: { url in await askUser(Lines.mayILook(FolderRequests.display(url, home: home), reason: reason)) },
            add: { [weak self] url in
                guard let self, !self.changing, !self.selecting else { throw AccessError.busy }
                self.beginChange()
                return try await self.finishChange { try await store.add(Self.kind(of: url), url: url) }
            })
        return .ok(FolderRequests.result(outcome))
    }

    /// A folder with .obsidian is a vault (Markdown only); anything else is a files folder.
    nonisolated private static func kind(of url: URL) -> ChilkFileScope {
        var isDirectory: ObjCBool = false
        let marker = url.appendingPathComponent(".obsidian").path
        return FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory) && isDirectory.boolValue ? .obsidian : .files
    }

    func add(_ kind: ChilkFileScope, url: URL) async throws {
        guard await waitUntilReady(), canChange, let store else { throw AccessError.busy }
        beginChange()
        _ = try await finishChange { try await store.add(kind, url: url) }
    }

    func remove(name: String) async throws {
        guard await waitUntilReady(), canChange, let store else { throw AccessError.busy }
        beginChange()
        _ = try await finishChange { try await store.remove(name: name) }
    }

    private func beginChange() {
        changing = true
        generation &+= 1
        for operation in Array(operations.values) { operation.cancel() }
    }

    private func finishChange<T>(_ change: () async throws -> T) async throws -> T {
        defer { changing = false; onChange?() }
        guard let store else { throw AccessError.unavailable }
        for operation in Array(operations.values) { _ = await operation.value }
        do {
            let value = try await change()
            grants = await store.grants
            await executor.configure(grants)
            return value
        } catch {
            grants = await store.grants
            await executor.configure(grants)
            throw error
        }
    }

    func dockItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Файлы и Obsidian"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: grants.isEmpty ? String(localized: "Папок нет — только чтение")
                                                      : String(localized: "Только чтение:"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for grant in grants {
            let where_ = FolderRequests.display(grant.root, home: home)
            let title = grant.kind == .obsidian ? String(localized: "Убрать «\(where_)» (Obsidian)")
                                                : String(localized: "Убрать «\(where_)»")
            let remove = action(title, #selector(removeFolder(_:)))
            remove.representedObject = grant.name
            menu.addItem(remove)
        }
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Добавить папку…"), #selector(chooseFiles)))
        menu.addItem(action(String(localized: "Добавить хранилище Obsidian…"), #selector(chooseVault)))
        if changing || store == nil {
            let title = changing ? String(localized: "Изменяю доступ…")
                : (loading != nil ? String(localized: "Загружаю доступ…") : String(localized: "Хранилище доступа недоступно"))
            let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        item.submenu = menu
        return item
    }

    var canChange: Bool { store != nil && !selecting && !changing }
    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = canChange
        return item
    }

    @objc private func chooseFiles() { choose(.files) }
    @objc private func chooseVault() { choose(.obsidian) }
    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { do { try await remove(name: name) } catch { report(error) } }
    }

    /// The system folder panel; the chosen folder is added for reading.
    func choose(_ kind: ChilkFileScope) {
        guard canChange else { return }
        selecting = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = String(localized: "Разрешить")
        panel.title = kind == .files ? String(localized: "Папка для Чилка") : String(localized: "Хранилище Obsidian")
        panel.message = kind == .files
            ? String(localized: "Только чтение: поиск имён и чтение .md, .txt и .csv по твоей просьбе. Чилк ничего не меняет, не перемещает и не удаляет. Найденные имена и прочитанный текст отправляются Codex/OpenAI. Папку можно убрать.")
            : String(localized: "Выбери корень хранилища с папкой .obsidian. Только чтение .md по твоей просьбе: Чилк ничего не создаёт и не меняет. Найденные имена и прочитанный текст отправляются Codex/OpenAI.")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.selecting = false
            guard response == .OK, let url = panel.url else { return }
            Task { do { try await self.add(kind, url: url) } catch { self.report(error) } }
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Не получилось изменить доступ")
        switch error {
        case FolderAccessStore.AccessError.invalidVault:
            alert.informativeText = String(localized: "Выбери корневую папку хранилища Obsidian: внутри должна быть папка .obsidian.")
        case FolderAccessStore.AccessError.tooBroad:
            alert.informativeText = String(localized: "Целиком домашнюю папку или диск дать нельзя — выбери папку внутри.")
        default:
            alert.informativeText = String(localized: "Папка недоступна или выбор не удалось сохранить. Прежний доступ не изменён. Скрытые и системные папки выбирать нельзя.")
        }
        alert.addButton(withTitle: String(localized: "Понятно"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
