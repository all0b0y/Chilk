import Foundation
import ChilkCore

/// Tray → Tools (slice 5a, decision 9) and the user's name (decisions 22–23), next to the rest of Chilk's state.
/// A damaged file falls back to the defaults: every tool on, no name (the greeting asks again).
@MainActor
final class ToolSwitchStore {
    private let url = AppState.directory.appendingPathComponent("tools.json")
    private(set) var switches: ToolSwitches
    /// Called after every change (the brain rebuilds its spare thread; phrases follow the switch).
    var onChange: [() -> Void] = []

    init() {
        switches = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ToolSwitches.self, from: $0) } ?? ToolSwitches()
    }

    func isOn(_ a: ChilkAbility) -> Bool { switches.isOn(a) }

    func set(_ a: ChilkAbility, on: Bool) {
        guard switches.isOn(a) != on else { return }
        switches.set(a, on: on)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(switches).write(to: url, options: .atomic)
        for f in onChange { f() }
    }
}

@MainActor
final class ProfileStore {
    private let url = AppState.directory.appendingPathComponent("profile.json")
    private(set) var profile: UserProfile

    init() {
        profile = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
    }

    /// `false` = the name was refused (empty, too long, brackets).
    @discardableResult
    func setName(_ raw: String) -> Bool {
        guard let name = UserProfile.cleanName(raw) else { return false }
        profile.name = name
        profile.greetingDone = true
        save()
        return true
    }

    func later() {
        profile.greetingDone = true
        save()
    }

    /// Settings → «Как тебя называть» (slice 5c): an empty field forgets the name; the greeting does not come back.
    func clearName() {
        profile.name = nil
        profile.greetingDone = true
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(profile).write(to: url, options: .atomic)
    }
}

/// Reads a saved value. A file that cannot be decoded is set aside (`<name>.damaged-<time>.json`); a file that cannot
/// be read or set aside is left alone and the store does not write over it (chats and memory are the only copies).
private enum Loaded<T> {
    case missing
    case value(T)
    case untouchable
}

@MainActor
private func load<T: Decodable>(_ type: T.Type, from url: URL) -> Loaded<T> {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    guard let data = try? Data(contentsOf: url) else { return .untouchable }
    if let value = try? JSONDecoder().decode(T.self, from: data) { return .value(value) }
    let stamp = Int(Date().timeIntervalSince1970)
    let aside = url.deletingPathExtension().appendingPathExtension("damaged-\(stamp).json")
    do {
        try FileManager.default.moveItem(at: url, to: aside)
        return .missing
    } catch {
        return .untouchable
    }
}

@MainActor
private func store<T: Encodable>(_ value: T, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(value).write(to: url, options: .atomic)
}

/// Slice 5b (decisions 10–12): the chat log on disk (`chats.json`), voice kept as text only. Inactive chats are
/// removed after `autoDeleteDays` at launch and every hour.
@MainActor
final class ChatStore {
    private let url = AppState.directory.appendingPathComponent("chats.json")
    private(set) var log: ChatLog
    var onChange: [() -> Void] = []
    private var purgeTimer: Timer?
    /// `false` when the file exists but could not be read: this session keeps the chat in memory only.
    private let writable: Bool

    init() {
        switch load(ChatLog.self, from: url) {
        case .value(let log): self.log = log; writable = true
        case .missing: log = ChatLog(); writable = true
        case .untouchable: log = ChatLog(); writable = false
        }
        purge()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
        purgeTimer?.tolerance = 60
    }

    @discardableResult
    func record(question: String, answer: String, via: ChatTurn.Via, chips: [ChatChip], thread: String,
                continuing: UUID?) -> UUID {
        let id = log.record(question: question, answer: answer, via: via, chips: chips, thread: thread,
                            continuing: continuing, at: Date())
        changed()
        return id
    }

    /// 6b: a pair that never went to Codex (lying, he does not talk).
    func recordLocal(question: String, answer: String, via: ChatTurn.Via, continuing: UUID?) -> UUID {
        let id = log.recordLocal(question: question, answer: answer, via: via, continuing: continuing, at: Date())
        changed()
        return id
    }

    func delete(_ id: UUID) {
        log.delete(id)
        changed()
    }

    /// Settings (slice 5c): 1 / 7 / 30 days, `nil` = never; applies at once.
    func setAutoDelete(days: Int?) {
        guard log.autoDeleteDays != days else { return }
        log.autoDeleteDays = days
        _ = log.purge(now: Date())
        changed()
    }

    private func purge() {
        if log.purge(now: Date()) > 0 { changed() }
    }

    private func changed() {
        if writable { store(log, to: url) }
        for f in onChange { f() }
    }
}

/// Slice 5b (decision 17): Chilk's memory on disk (`memory.json`).
@MainActor
final class MemoryStore {
    private let url = AppState.directory.appendingPathComponent("memory.json")
    private(set) var book: MemoryBook
    /// After every change (the brain re-warms its spare thread; the memory panel refreshes).
    var onChange: [() -> Void] = []
    /// `false` when the file exists but could not be read: nothing is written over it this session.
    private let writable: Bool

    init() {
        switch load(MemoryBook.self, from: url) {
        case .value(let book): self.book = book; writable = true
        case .missing: book = MemoryBook(); writable = true
        case .untouchable: book = MemoryBook(); writable = false
        }
    }

    func remember(_ text: String, selfNoted: Bool) -> MemoryBook.Outcome {
        let outcome = book.remember(text, selfNoted: selfNoted, now: Date())
        if case .added = outcome { changed() }
        return outcome
    }

    func edit(_ id: UUID, to text: String) -> MemoryBook.Outcome {
        let outcome = book.edit(id, to: text)
        if case .added = outcome { changed() }
        return outcome
    }

    func forget(_ id: UUID) {
        book.forget(id)
        changed()
    }

    private func changed() {
        if writable { store(book, to: url) }
        for f in onChange { f() }
    }
}

/// Slice 5c (decisions 19–20): the main window's Settings on disk (`settings.json`). Care, app categories, hotkey,
/// screen and launch at login; the mode stays in `balance.json`, the name in `profile.json`, the chat retention in
/// `chats.json`, the edge in the user defaults. A damaged file is set aside and the defaults apply.
@MainActor
final class SettingsStore {
    private let url = AppState.directory.appendingPathComponent("settings.json")
    private(set) var settings: AppSettings
    /// After every change made through `update` (the recent-apps list does not notify).
    var onChange: [() -> Void] = []
    private let writable: Bool
    private var dirty = false
    private var flushTimer: Timer?

    init() {
        switch load(AppSettings.self, from: url) {
        case .value(let s):
            settings = s
            writable = true
            Self.keepCopyIfLossy(url, decoded: s)
        case .missing: settings = AppSettings(); writable = true
        case .untouchable: settings = AppSettings(); writable = false
        }
    }

    /// `throws` = refused (the change is not applied, nothing is written).
    func update(_ change: (inout AppSettings) throws -> Void) rethrows {
        var s = settings
        try change(&s)
        guard s != settings else { return }
        settings = s
        save()
        for f in onChange { f() }
    }

    /// The front app changed: kept for the Settings list, written at most once a minute.
    func noteFront(_ id: String) {
        guard settings.apps.noteFront(id) else { return }
        dirty = true
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushTimer = nil
                self?.flush()
            }
        }
    }

    func flush() {
        guard dirty else { return }
        save()
    }

    /// A file read only in part (a damaged field fell back to its default) is copied aside before anything writes over
    /// it, like a file that cannot be read at all.
    private static func keepCopyIfLossy(_ url: URL, decoded: AppSettings) {
        guard let original = try? Data(contentsOf: url),
              let before = (try? JSONSerialization.jsonObject(with: original)) as? NSDictionary,
              let data = try? JSONEncoder().encode(decoded),
              let after = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
              before != after else { return }
        let aside = url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: aside)
    }

    private func save() {
        dirty = false
        if writable { store(settings, to: url) }
    }
}
