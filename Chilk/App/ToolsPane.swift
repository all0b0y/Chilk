import AppKit
import ChilkBrain
import ChilkCore
import Observation
import SwiftUI

/// Tray → Tools and the main window's «Инструменты» (decision 9, slice 5c): the same switches and folders in both
/// places, from one model.
@MainActor
@Observable
final class ToolsModel {
    /// A shared folder (read-only, any number of them).
    struct FolderRow: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let place: String
        let kind: ChilkFileScope
    }

    var switches = ToolSwitches()
    var earsOn = false
    var folders: [FolderRow] = []
    var canChangeFolders = false
    /// «Изменяю доступ…» / «Загружаю доступ…» while folders cannot be changed.
    var foldersNote: String?

    var toggle: (ChilkAbility, Bool) -> Void = { _, _ in }
    var toggleEars: (Bool) -> Void = { _ in }
    var removeFolder: (String) -> Void = { _ in }
}

/// Feeds the tools model from the stores (the popover and the main window refresh it while they are open).
@MainActor
final class ToolsBridge {
    let model = ToolsModel()
    private let switches: ToolSwitchStore
    private let ears: Ears
    private let files: Files
    var log: (String) -> Void = { _ in }

    init(switches: ToolSwitchStore, ears: Ears, files: Files) {
        self.switches = switches
        self.ears = ears
        self.files = files
        model.toggle = { [weak self] a, on in
            guard let self else { return }
            self.switches.set(a, on: on)
            self.model.switches = self.switches.switches
            self.log("tool \(a.rawValue) \(on ? "on" : "off")")
        }
        model.toggleEars = { [weak self] on in
            guard let self, self.ears.enabled != on else { return }
            self.ears.toggle()
            self.model.earsOn = self.ears.enabled
        }
        model.removeFolder = { [weak self] name in self?.files.forget(name: name) }
    }

    /// Opens the system folder panel (the popover closes itself first).
    func addFolder(_ kind: ChilkFileScope) { files.choose(kind) }

    func refresh() {
        if model.switches != switches.switches { model.switches = switches.switches }
        if model.earsOn != ears.enabled { model.earsOn = ears.enabled }
        let folders = files.grants.map { ToolsModel.FolderRow(name: $0.name, place: files.place(of: $0), kind: $0.kind) }
        if folders != model.folders { model.folders = folders }
        if model.canChangeFolders != files.canChange { model.canChangeFolders = files.canChange }
        if model.foldersNote != files.busyNote { model.foldersNote = files.busyNote }
    }
}

/// The switches and the folder list. `addFolder` differs by place: the popover closes before the panel opens.
struct ToolsPane: View {
    @Bindable var model: ToolsModel
    var addFolder: (ChilkFileScope) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switchRow(String(localized: "Уши: слышит «Чилк»"), isOn: Binding(get: { model.earsOn }, set: { model.toggleEars($0) }))
            ForEach([ChilkAbility.webSearch, .timers, .reminders], id: \.self) { a in abilityToggle(a) }
            abilityToggle(.files)
            abilityToggle(.obsidian)
            abilityToggle(.phrases)
            folderList
            Text(String(localized: "Выключенное действует со следующего ответа. Папки на паузе не забываются."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func abilityToggle(_ a: ChilkAbility) -> some View {
        switchRow(Lines.abilityName(a), isOn: Binding(get: { model.switches.isOn(a) }, set: { model.toggle(a, $0) }))
    }

    /// Name on the left, the switch on the right edge — every switch in one column.
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    /// Shared folders, read-only: a folder of a switched-off kind is paused (dimmed), «Убрать» forgets it.
    private var folderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Папки — только чтение")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.folders.isEmpty {
                Text(String(localized: "Пока пусто. Чилк может и сам спросить: «Можно я загляну?»"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.folders) { f in
                let paused = !model.switches.isOn(f.kind.ability)
                HStack(spacing: 6) {
                    Image(systemName: f.kind == .obsidian ? "book.closed" : "folder").foregroundStyle(.secondary)
                    Text(f.place).lineLimit(1).truncationMode(.middle)
                    if paused { Text(String(localized: "на паузе")).foregroundStyle(.secondary) }
                    Spacer()
                    Button(String(localized: "Убрать")) { model.removeFolder(f.name) }.disabled(!model.canChangeFolders)
                }
                .opacity(paused ? 0.5 : 1)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Добавить папку…")) { addFolder(.files) }
                Button(String(localized: "Добавить Obsidian…")) { addFolder(.obsidian) }
            }
            .disabled(!model.canChangeFolders)
            if let note = model.foldersNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .controlSize(.small)
    }
}
