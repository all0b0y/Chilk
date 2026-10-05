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

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(profile).write(to: url, options: .atomic)
    }
}
