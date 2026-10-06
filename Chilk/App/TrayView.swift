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

    var page = Page.main
    var card = HeroCard.make(pressure: { _ in 0 }, exitsLeft: 3, exitsMax: 3, mode: .soft)
    /// He came into the popover (free at the edge) — otherwise the sign.
    var heroHere = false
    var timers: [TimerRow] = []
    var problem: Problem?
    /// The last refusal of a softer mode («договор с собой»), shown under the card for a few seconds.
    var refusal: String?
    /// The Tools page (shared with the main window's «Инструменты»).
    let tools: ToolsModel
    var now = Date()

    init(tools: ToolsModel) { self.tools = tools }

    // Actions, wired by the tray.
    var breathe: (Double) -> Void = { _ in }
    var eyes: () -> Void = {}
    var drank: () -> Void = {}
    var warmup: () -> Void = {}
    var walk: () -> Void = {}
    var setMode: (BalanceMode) -> Bool = { _ in false }
    var addFolder: (ChilkFileScope) -> Void = { _ in }
    var login: () -> Void = {}
    var openChat: () -> Void = {}
    /// «Открыть Чилка» → the main window on «Сегодня»; «Настройки» → on «Настройки» (slice 5c).
    var openMain: () -> Void = {}
    var openSettings: () -> Void = {}
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
        StatBar(stat: stat, height: 6, font: .caption2)
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
            Button { model.openSettings() } label: { Label(String(localized: "Настройки"), systemImage: "gearshape") }
            Spacer(minLength: 4)
            Button { model.openMain() } label: { Label(String(localized: "Открыть Чилка"), systemImage: "macwindow") }
        }
        .labelStyle(VerticalLabel())
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
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
            ToolsPane(model: model.tools, addFolder: model.addFolder)
        }
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

/// One need as a stat bar: leaf green, wilting to yellow and brown as the pressure grows; «выкл» when switched off.
struct StatBar: View {
    let stat: HeroStat
    var height: CGFloat = 6
    var font: Font = .caption2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(Lines.statNames[stat.need] ?? "")
                if stat.off { Text(Lines.statOff) }
            }
            .font(font).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if !stat.off {
                        Capsule().fill(Self.color(stat.tone)).frame(width: max(height * 0.66, g.size.width * stat.fill))
                    }
                }
            }
            .frame(height: height)
        }
    }

    static func color(_ tone: HeroStat.Tone) -> Color {
        switch tone {
        case .fresh: Color(red: 0x8F / 255.0, green: 0xD8 / 255.0, blue: 0x6A / 255.0)
        case .tired: Color(red: 0.93, green: 0.78, blue: 0.29)
        case .wilted: Color(red: 0.62, green: 0.42, blue: 0.24)
        }
    }
}
