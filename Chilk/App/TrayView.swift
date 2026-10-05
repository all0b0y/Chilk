import AppKit
import ChilkBrain
import ChilkCore
import Observation
import SwiftUI

/// What the popover shows (slice 5a, decisions 6–9). The tray refreshes it twice a second while it is open.
@MainActor
@Observable
final class TrayModel {
    enum Page { case main, tools }
    enum Problem: Equatable {
        case codexSignedOut, codexDown(String), earsBroken(String)
    }
    struct TimerRow: Identifiable, Equatable {
        let id: String
        let title: String
        let deadline: Date
    }
    /// A shared folder (read-only, any number of them — branch `breaks-readonly-files`).
    struct FolderRow: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let place: String
        let kind: ChilkFileScope
    }

    var page = Page.main
    var card = HeroCard.make(pressure: { _ in 0 }, exitsLeft: 3, exitsMax: 3, mode: .soft)
    /// He came into the popover (free at the edge) — otherwise the sign.
    var heroHere = false
    var timers: [TimerRow] = []
    var problem: Problem?
    /// The last refusal of a softer mode («договор с собой»), shown under the card for a few seconds.
    var refusal: String?
    var switches = ToolSwitches()
    var earsOn = false
    var folders: [FolderRow] = []
    var canChangeFolders = false
    /// «Изменяю доступ…» / «Загружаю доступ…» while folders cannot be changed.
    var foldersNote: String?
    var now = Date()

    // Actions, wired by the tray.
    var breathe: (Double) -> Void = { _ in }
    var eyes: () -> Void = {}
    var drank: () -> Void = {}
    var warmup: () -> Void = {}
    var walk: () -> Void = {}
    var setMode: (BalanceMode) -> Bool = { _ in false }
    var toggle: (ChilkAbility, Bool) -> Void = { _, _ in }
    var toggleEars: (Bool) -> Void = { _ in }
    var addFolder: (ChilkFileScope) -> Void = { _ in }
    var removeFolder: (String) -> Void = { _ in }
    var login: () -> Void = {}
    var openChat: () -> Void = {}
    var reconnect: () -> Void = {}
    var restartEars: () -> Void = {}

    func chooseMode(_ m: BalanceMode) {
        if setMode(m) {
            refusal = nil
            card.mode = m
        } else {
            refusal = Lines.softerRefused
        }
    }
}

/// The popover: hero card, breaks, timers, a problem line only when something is broken, and the four buttons.
/// System controls and Liquid Glass come from macOS; the accent is Chilk's peach (decision 21).
struct TrayView: View {
    @Bindable var model: TrayModel
    let hero: HeroView
    static let peach = Color(red: 1, green: 0xB4 / 255.0, blue: 0x9A / 255.0)

    var body: some View {
        Group {
            switch model.page {
            case .main: main
            case .tools: tools
            }
        }
        .padding(14)
        .frame(width: 340)
        .tint(Self.peach)
    }

    // MARK: Main page

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroCard
            if let refusal = model.refusal {
                Label(refusal, systemImage: "hand.raised").font(.callout).foregroundStyle(.secondary)
            }
            breaks
            if !model.timers.isEmpty { timers }
            if let problem = model.problem { problemLine(problem) }
            Divider()
            buttons
        }
    }

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Self.peach.opacity(0.16))
                HeroPortrait(view: hero).opacity(model.heroHere ? 1 : 0)
                if !model.heroHere {
                    Text(Lines.heroBusy)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .padding(8)
                }
            }
            .frame(width: HeroView.size.width, height: HeroView.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.card.stats, id: \.need) { stat in statBar(stat) }
                HStack(spacing: 3) {
                    ForEach(0..<model.card.potionsMax, id: \.self) { i in
                        Image(systemName: i < model.card.potions ? "flask.fill" : "flask")
                            .foregroundStyle(i < model.card.potions ? Self.peach : .secondary)
                    }
                    .help(String(localized: "Экстренные выходы"))
                    Spacer(minLength: 4)
                    Menu {
                        ForEach([BalanceMode.strict, .soft, .silent], id: \.self) { m in
                            Button { model.chooseMode(m) } label: {
                                if m == model.card.mode { Label(Lines.modeName(m), systemImage: "checkmark") } else { Text(Lines.modeName(m)) }
                            }
                        }
                    } label: {
                        Text(Lines.modeName(model.card.mode)).font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Сложность — режим перерывов"))
                }
                .padding(.top, 2)
            }
        }
    }

    private func statBar(_ stat: HeroStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Lines.statNames[stat.need] ?? "").font(.caption2).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color(stat.tone)).frame(width: max(4, g.size.width * stat.fill))
                }
            }
            .frame(height: 6)
        }
    }

    /// Leaf green, wilting to yellow and brown as the pressure grows.
    private func color(_ tone: HeroStat.Tone) -> Color {
        switch tone {
        case .fresh: Color(red: 0x8F / 255.0, green: 0xD8 / 255.0, blue: 0x6A / 255.0)
        case .tired: Color(red: 0.93, green: 0.78, blue: 0.29)
        case .wilted: Color(red: 0.62, green: 0.42, blue: 0.24)
        }
    }

    private var breaks: some View {
        // Warm-up and walk come from the guided-breaks work (SPEC: «Кнопки … в попапе трея — исполнитель 5a»).
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { model.warmup() } label: { Label(String(localized: "Разминка"), systemImage: "figure.cooldown") }
                Button { model.walk() } label: { Label(String(localized: "Прогулка"), systemImage: "figure.walk") }
            }
            HStack(spacing: 8) {
                Menu {
                    Button(String(localized: "1 минуту")) { model.breathe(1) }
                    Button(String(localized: "3 минуты")) { model.breathe(3) }
                } label: {
                    Label(String(localized: "Подышать"), systemImage: "wind")
                }
                .menuStyle(.button)
                .fixedSize()
                Button { model.eyes() } label: { Label(String(localized: "Глаза"), systemImage: "eye") }
                Button { model.drank() } label: { Label(String(localized: "Попил"), systemImage: "cup.and.saucer") }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var timers: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.timers) { t in
                HStack(spacing: 6) {
                    Image(systemName: "timer").foregroundStyle(.secondary)
                    Text(t.title).lineLimit(1)
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Text(t.deadline, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func problemLine(_ p: TrayModel.Problem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            switch p {
            case .codexSignedOut:
                Text(String(localized: "Codex: не выполнен вход")).font(.callout)
                Spacer()
                Button(String(localized: "Войти в Codex")) { model.login() }.controlSize(.small)
            case .codexDown(let why):
                Text(String(localized: "Codex не на связи")).font(.callout).help(why)
                Spacer()
                Button(String(localized: "Переподключить")) { model.reconnect() }.controlSize(.small)
            case .earsBroken(let why):
                Text(String(localized: "Слух сломался")).font(.callout).help(why)
                Spacer()
                Button(String(localized: "Включить")) { model.restartEars() }.controlSize(.small)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            Button { model.openChat() } label: { Label(String(localized: "Чат"), systemImage: "bubble.left.and.bubble.right") }
            Spacer(minLength: 4)
            Button { model.page = .tools } label: { Label(String(localized: "Инструменты"), systemImage: "switch.2") }
            Spacer(minLength: 4)
            soon(String(localized: "Настройки"), "gearshape")
            Spacer(minLength: 4)
            soon(String(localized: "Открыть Чилка"), "macwindow")
        }
        .labelStyle(VerticalLabel())
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
    }

    /// Until 5b/5c land: visible, disabled, «скоро» (so the agreed layout is there in acceptance).
    private func soon(_ title: String, _ image: String) -> some View {
        Button {} label: { Label(title, systemImage: image) }
            .disabled(true)
            .help(Lines.soon)
            .overlay(alignment: .topTrailing) {
                Text(Lines.soon).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).offset(x: 4, y: -6)
            }
    }

    // MARK: Tools page (decision 9)

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.page = .main } label: { Label(String(localized: "Назад"), systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(String(localized: "Инструменты")).font(.headline)
                Spacer()
            }
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
                Button(String(localized: "Добавить папку…")) { model.addFolder(.files) }
                Button(String(localized: "Добавить Obsidian…")) { model.addFolder(.obsidian) }
            }
            .disabled(!model.canChangeFolders)
            if let note = model.foldersNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

private struct VerticalLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.system(size: 16))
            configuration.title.font(.caption2)
        }
        .frame(minWidth: 44)
    }
}
