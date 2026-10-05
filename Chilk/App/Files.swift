import AppKit
import ChilkBrain

/// Folder choice is a local user interaction. All bookmarks and filesystem work stay on dedicated actors.
@MainActor
final class Files {
    typealias Runner = @Sendable (ChilkFileToolExecutor, String, JSON) async -> CodexToolResult
    enum AccessError: Error { case unavailable, busy }
    let executor: ChilkFileToolExecutor
    private var store: FolderAccessStore?
    private var loading: Task<(FolderAccessStore, [ChilkFileScope: URL]), Error>?
    private var operations: [UUID: Task<CodexToolResult, Never>] = [:]
    private(set) var roots: [ChilkFileScope: URL] = [:]
    private(set) var generation: UInt64 = 0
    private var selecting = false
    private var changing = false
    private let run: Runner

    init(file: URL, allowedContainer: URL = URL(fileURLWithPath: "/"),
         run: @escaping Runner = { executor, name, arguments in
             await Files.executeFileTool(executor, name, arguments)
         }) {
        executor = ChilkFileToolExecutor(allowedContainer: allowedContainer)
        self.run = run
        loading = Task {
            let store = try await FolderAccessStore(file: file, allowedContainer: allowedContainer)
            return (store, await store.roots)
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
            roots = loaded.1
            loading = nil
            return true
        } catch { loading = nil; return false }
    }

    func execute(_ call: CodexToolCall) async -> CodexToolResult {
        guard await waitUntilReady(), !changing else { return .failure("Folder access unavailable or changing") }
        let snapshot = roots, version = generation, id = UUID()
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
        guard !Task.isCancelled, !changing, generation == version else {
            let message = call.name == "chilk_append_note"
                ? "Cancelled or folder access changed. A started note write may have changed the note; check before retrying"
                : "Cancelled or folder access changed"
            return .failure(message)
        }
        return result
    }

    func select(_ scope: ChilkFileScope, url: URL) async throws {
        guard await waitUntilReady(), !changing else { throw AccessError.busy }
        beginChange()
        try await finishChange(scope, url: url)
    }

    func revoke(_ scope: ChilkFileScope) async throws {
        guard await waitUntilReady(), !changing else { throw AccessError.busy }
        beginChange()
        try await finishChange(scope, url: nil)
    }

    private func beginChange() {
        changing = true
        generation &+= 1
        for operation in operations.values { operation.cancel() }
    }

    private func finishChange(_ scope: ChilkFileScope, url: URL?) async throws {
        defer { changing = false }
        guard let store else { throw AccessError.unavailable }
        // Do not report revocation complete while an old write could still be settling.
        for operation in Array(operations.values) { _ = await operation.value }
        do {
            if let url { try await store.select(scope, url: url) }
            else { try await store.revoke(scope) }
            roots = await store.roots
            await executor.configure(roots)
        } catch {
            roots = await store.roots
            await executor.configure(roots)
            throw error
        }
    }

    func dockItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Файлы и Obsidian"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let files = roots[.files]?.lastPathComponent ?? String(localized: "не выбраны")
        let vault = roots[.obsidian]?.lastPathComponent ?? String(localized: "не выбран")
        let fileStatus = NSMenuItem(title: String(localized: "Файлы: \(files)"), action: nil, keyEquivalent: "")
        fileStatus.isEnabled = false
        menu.addItem(fileStatus)
        menu.addItem(action(String(localized: "Выбрать папку файлов…"), #selector(chooseFiles)))
        let revokeFiles = action(String(localized: "Отозвать доступ к файлам"), #selector(revokeFiles))
        revokeFiles.isEnabled = canChange && roots[.files] != nil
        menu.addItem(revokeFiles)
        menu.addItem(.separator())
        let vaultStatus = NSMenuItem(title: String(localized: "Obsidian: \(vault)"), action: nil, keyEquivalent: "")
        vaultStatus.isEnabled = false
        menu.addItem(vaultStatus)
        menu.addItem(action(String(localized: "Выбрать хранилище Obsidian…"), #selector(chooseVault)))
        let revokeVault = action(String(localized: "Отозвать доступ к Obsidian"), #selector(revokeVault))
        revokeVault.isEnabled = canChange && roots[.obsidian] != nil
        menu.addItem(revokeVault)
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

    private var canChange: Bool { store != nil && !selecting && !changing }
    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = canChange
        return item
    }

    @objc private func chooseFiles() { choose(.files) }
    @objc private func chooseVault() { choose(.obsidian) }
    @objc private func revokeFiles() { startRevoking(.files) }
    @objc private func revokeVault() { startRevoking(.obsidian) }

    private func startRevoking(_ scope: ChilkFileScope) {
        guard canChange else { return }
        beginChange()
        Task { do { try await finishChange(scope, url: nil) } catch { report(error) } }
    }

    private func choose(_ scope: ChilkFileScope) {
        guard canChange else { return }
        selecting = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = String(localized: "Разрешить")
        panel.title = scope == .files ? String(localized: "Папка файлов Чилка") : String(localized: "Хранилище Obsidian")
        panel.message = scope == .files
            ? String(localized: "Только поиск имён и чтение .md, .txt и .csv по твоей просьбе. Найденные имена и прочитанный текст отправляются Codex/OpenAI. Доступ можно отозвать в Dock.")
            : String(localized: "Выбери корень хранилища с папкой .obsidian. Чилк сможет читать, создавать и дописывать .md по твоей просьбе, без удаления и перезаписи. Найденные имена и прочитанный текст отправляются Codex/OpenAI.")
        panel.directoryURL = roots[scope]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.selecting = false
            guard response == .OK, let url = panel.url else { return }
            self.beginChange()
            Task { do { try await self.finishChange(scope, url: url) } catch { self.report(error) } }
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Не получилось изменить доступ")
        if case FolderAccessStore.AccessError.invalidVault = error {
            alert.informativeText = String(localized: "Выбери корневую папку хранилища Obsidian: внутри должна быть папка .obsidian.")
        } else {
            alert.informativeText = String(localized: "Папка недоступна или выбор не удалось сохранить. Прежний доступ не изменён. Скрытые и системные папки выбирать нельзя.")
        }
        alert.addButton(withTitle: String(localized: "Понятно"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
