import AppKit
import Charts
import ChilkBrain
import ChilkCore
import SwiftUI

/// The main window (slice 5c, decisions 16–21): sidebar Сегодня · Неделя · Память · Инструменты · Настройки.
/// System macOS look with the peach accent; the sticker style only for Chilk himself (the portrait).
struct MainView: View {
    @Bindable var model: MainModel
    let memory: MemoryModel
    let tools: ToolsModel
    let addFolder: (ChilkFileScope) -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(MainSection.allCases) { s in
                    Label(Lines.sectionName(s), systemImage: Lines.sectionIcon(s)).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(TrayView.peach)
    }

    @ViewBuilder private var detail: some View {
        switch model.section ?? .today {
        case .today:
            ScrollView { TodaySection(model: model).frame(maxWidth: 680, alignment: .leading).padding(24) }
        case .week:
            ScrollView { WeekSection(model: model).frame(maxWidth: 680, alignment: .leading).padding(24) }
        case .memory:
            ScrollView { MemorySection(model: memory).frame(maxWidth: 640, alignment: .leading).padding(24) }
        case .tools:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Title(text: Lines.sectionName(.tools))
                    ToolsPane(model: tools, addFolder: addFolder)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(24)
            }
        case .settings:
            SettingsSection(model: model)
        }
    }
}

// MARK: - Shared pieces

private struct Title: View {
    let text: String
    var body: some View { Text(text).font(.title2.weight(.semibold)) }
}

/// One big number with its caption.
private struct Figure: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }
}

/// A rounded box with a caption — the sections of «Сегодня» and «Неделя».
private struct Card<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).help(help ?? "")
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
    }
}

/// Per need: «засчитано N · дожимал M».
private struct Tallies: View {
    let tallies: [NeedTally]

    var body: some View {
        Card(title: Lines.byNeed, help: Lines.tallyHelp) {
            ForEach(tallies, id: \.need) { t in
                HStack {
                    Text(Lines.name(t.need))
                    Spacer()
                    Text(Lines.tally(credited: t.credited, pushed: t.pushed)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(Lines.tallyHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Emergency exits with their reasons (В13), newest first.
private struct Exits: View {
    let exits: [EmergencyExit]
    let empty: String
    let withDay: Bool

    var body: some View {
        Card(title: Lines.exitsTitle) {
            if exits.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(Array(exits.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.at, format: withDay ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute())
                        .foregroundStyle(.secondary).monospacedDigit()
                    Text(Lines.exitLine(e))
                    Text(e.reason).foregroundStyle(.secondary).lineLimit(2)
                    if e.held {
                        Text(Lines.exitHeld).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
        }
    }
}

// MARK: - Сегодня

private struct TodaySection: View {
    let model: MainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Title(text: Lines.sectionName(.today))
            HStack(alignment: .center, spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(TrayView.peach.opacity(0.16))
                    if let p = model.portrait { Image(nsImage: p).resizable().frame(width: 150, height: 150) }
                }
                .frame(width: 170, height: 170)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.card.stats, id: \.need) { StatBar(stat: $0, height: 10, font: .callout) }
                    HStack(spacing: 4) {
                        ForEach(0..<model.card.potionsMax, id: \.self) { i in
                            Image(systemName: i < model.card.potions ? "flask.fill" : "flask")
                                .foregroundStyle(i < model.card.potions ? TrayView.peach : .secondary)
                        }
                        .help(Lines.exitsTitle)
                        Spacer()
                        Text(Lines.modeName(model.card.mode)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 360)
            }
            HStack(spacing: 12) {
                Figure(title: Lines.todayStreak, value: Lines.duration(model.today.streak))
                Figure(title: Lines.todayActive, value: Lines.duration(model.today.active))
                Figure(title: model.today.left >= 0 ? Lines.todayLeft : Lines.todayOver, value: Lines.duration(abs(model.today.left)))
                Figure(title: Lines.deferrals, value: "\(model.today.deferrals)")
            }
            Tallies(tallies: model.today.tallies)
            Exits(exits: model.today.exits, empty: Lines.noExitsToday, withDay: false)
        }
    }
}

// MARK: - Неделя

private struct WeekSection: View {
    let model: MainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Title(text: Lines.sectionName(.week))
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(model.week.days, id: \.key) { d in
                        BarMark(x: .value(Lines.weekDay, d.date, unit: .day), y: .value(Lines.weekHours, d.active / 3600))
                            .foregroundStyle(d.active > d.budget ? Color.orange : TrayView.peach)
                        RectangleMark(x: .value(Lines.weekDay, d.date, unit: .day), y: .value(Lines.weekBudget, d.budget / 3600),
                                      height: .fixed(2))
                            .foregroundStyle(Color.primary.opacity(0.65))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                    }
                }
                .frame(height: 220)
                Text(Lines.weekCaption).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Figure(title: Lines.weekTotals, value: Lines.duration(model.week.days.reduce(0) { $0 + $1.active }))
                Figure(title: Lines.deferrals, value: "\(model.week.deferrals)")
            }
            Tallies(tallies: model.week.tallies)
            Exits(exits: model.week.exits, empty: Lines.noExitsWeek, withDay: true)
        }
    }
}

// MARK: - Настройки (decisions 19–20)

private struct SettingsSection: View {
    @Bindable var model: MainModel
    @State private var name = ""

    private static let careOrder: [Need] = [.water, .stretch, .eyes, .walk]

    var body: some View {
        Form {
            if model.locked || model.refusal != nil {
                Section {
                    Label(model.refusal ?? Lines.locked, systemImage: "hand.raised").foregroundStyle(.orange)
                }
            }
            Section(Lines.settingsMode) {
                HStack(spacing: 8) {
                    ForEach([BalanceMode.strict, .soft, .silent], id: \.self) { m in modeButton(m) }
                }
                Text(Lines.modeHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Self.careOrder, id: \.self) { n in careRow(n) }
                Toggle(Lines.name(.endOfDay), isOn: needBinding(.endOfDay))
                    .disabled(model.locked && model.care.isOn(.endOfDay))
                budgetStepper(weekend: false)
                budgetStepper(weekend: true)
            } header: {
                Text(Lines.care)
            } footer: {
                Text(Lines.contractHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.apps.isEmpty { Text(Lines.appsEmpty).foregroundStyle(.secondary) }
                ForEach(model.apps) { app in appRow(app) }
            } header: {
                Text(Lines.apps)
            } footer: {
                Text(Lines.appsHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section(Lines.hotkey) {
                HStack {
                    Text(Lines.hotkeyCall)
                    Spacer()
                    Text(model.recording ? Lines.hotkeyRecording : model.hotkeyLabel)
                        .foregroundStyle(model.recording ? Color.orange : Color.secondary)
                    Button(model.recording ? Lines.hotkeyCancel : Lines.hotkeyChange) { model.record(!model.recording) }
                }
                if let note = model.hotkeyNote { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Section(Lines.screen) {
                Picker(Lines.edgeTitle, selection: Binding(get: { model.edge }, set: { model.setEdge($0) })) {
                    Text(Lines.edgeLeft).tag(ChilkCore.Edge.left)
                    Text(Lines.edgeRight).tag(ChilkCore.Edge.right)
                }
                .pickerStyle(.segmented)
                Picker(Lines.monitor, selection: screenBinding) {
                    Text(Lines.followActive).tag("")
                    ForEach(model.screens) { s in Text(Lines.pinnedTo(s.name)).tag(s.id) }
                    if case .pinned(let id, let name) = model.screen, !model.screens.contains(where: { $0.id == id }) {
                        Text(Lines.notConnected(name)).tag(id)
                    }
                }
            }
            Section(Lines.callMe) {
                HStack {
                    TextField(Lines.namePlaceholder, text: $name).labelsHidden().onSubmit { model.saveName(name) }
                    Button(Lines.save) { model.saveName(name) }
                }
                if let note = model.nameNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Section(Lines.chats) {
                Picker(Lines.deleteInactive, selection: Binding(get: { model.chatDays ?? 0 },
                                                                set: { model.setChatDays($0 == 0 ? nil : $0) })) {
                    ForEach([1, 7, 30], id: \.self) { d in Text(Lines.days(d)).tag(d) }
                    Text(Lines.never).tag(0)
                }
            }
            Section(Lines.launchTitle) {
                Toggle(Lines.launchAtLogin, isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunch($0) }))
                if model.launchNeedsApproval {
                    HStack {
                        Text(Lines.launchNeedsApproval).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(Lines.openLoginItems) { model.openLoginItems() }
                    }
                }
                if let note = model.launchNote { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                ForEach(Permissions.Kind.allCases) { k in
                    HStack {
                        Text(Lines.permissionName(k))
                        Spacer()
                        Text(Lines.permissionState(model.permissions[k] ?? .notAsked)).foregroundStyle(.secondary)
                        Button(Lines.openSystemSettings) { model.openPermission(k) }
                    }
                }
            } header: {
                Text(Lines.permissions)
            } footer: {
                Text(Lines.permissionsHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { name = model.name }
        .onChange(of: model.name) { name = model.name }
    }

    // MARK: Mode

    private func modeButton(_ m: BalanceMode) -> some View {
        let selected = m == model.mode
        return Button { model.setMode(m) } label: {
            Label(Lines.modeName(m), systemImage: selected ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .disabled(model.locked && m.cap < model.mode.cap)          // softer: not on stages 3–4
    }

    // MARK: Care

    private func needBinding(_ n: Need) -> Binding<Bool> {
        Binding(get: { model.care.isOn(n) }, set: { model.changeCare(.need(n, on: $0)) })
    }

    /// A switch row, then (while on) «Каждые 40 ⇅ – 70 ⇅ мин сидения» as its own row.
    @ViewBuilder private func careRow(_ n: Need) -> some View {
        Toggle(Lines.name(n), isOn: needBinding(n)).disabled(model.locked && model.care.isOn(n))
        if model.care.isOn(n) {
            LabeledContent(Lines.every) {
                HStack(spacing: 4) {
                    bound(n, low: true)
                    Text(verbatim: "–").foregroundStyle(.secondary)
                    bound(n, low: false)
                    Text(Lines.minutesOfSitting).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    /// Raising a bound is softer (decision 20): no «+» on stages 3–4. Lowering always works.
    private func bound(_ n: Need, low: Bool) -> some View {
        let r = model.care.range(n)
        let l = CareSettings.limits(n)
        let v = low ? r.low : r.high
        let up: (() -> Void)? = model.locked || v >= l.max ? nil : { model.changeCare(low ? .low(n, v + l.step) : .high(n, v + l.step)) }
        let down: (() -> Void)? = v <= l.min ? nil : { model.changeCare(low ? .low(n, v - l.step) : .high(n, v - l.step)) }
        return HStack(spacing: 2) {
            Text(verbatim: "\(v)").monospacedDigit()
            Stepper("", onIncrement: up, onDecrement: down).labelsHidden()
        }
    }

    private func budgetStepper(weekend: Bool) -> some View {
        let h = weekend ? model.care.weekendHours : model.care.weekdayHours
        let b = CareSettings.budgetLimits
        let up: (() -> Void)? = model.locked || h >= b.max ? nil : { model.changeCare(.budget(weekend: weekend, hours: h + b.step)) }
        let down: (() -> Void)? = h <= b.min ? nil : { model.changeCare(.budget(weekend: weekend, hours: h - b.step)) }
        return LabeledContent(weekend ? Lines.budgetWeekend : Lines.budgetWeekday) {
            HStack(spacing: 2) {
                Text(Lines.hours(h)).monospacedDigit()
                Stepper("", onIncrement: up, onDecrement: down).labelsHidden()
            }
        }
    }

    // MARK: Apps

    private func appRow(_ app: MainModel.AppRow) -> some View {
        HStack(spacing: 8) {
            if let icon = model.appIcons[app.id] { Image(nsImage: icon) }
            Text(app.name).lineLimit(1).help(app.id)
            Spacer()
            Menu(app.chosen.map(Lines.categoryName) ?? Lines.automatic(app.automatic)) {
                Button(Lines.automatic(app.automatic)) { model.setCategory(app.id, nil) }
                    .disabled(softens(app, to: nil))
                Divider()
                ForEach(AppCategory.choices, id: \.self) { c in
                    Button(Lines.categoryName(c)) { model.setCategory(app.id, c) }
                        .disabled(softens(app, to: c))
                }
            }
            .fixedSize()
        }
    }

    /// The engine's rule (decision 20 + A): a looser category, or anything into «Созвон», is softer.
    private func softens(_ app: MainModel.AppRow, to c: AppCategory?) -> Bool {
        model.locked && AppRules.softens(from: app.chosen ?? app.automatic, to: c ?? app.automatic)
    }

    // MARK: Screen

    private var screenBinding: Binding<String> {
        Binding(get: {
            if case .pinned(let id, _) = model.screen { return id }
            return ""
        }, set: { id in
            if id.isEmpty { return model.setScreen(.follow) }
            let name = model.screens.first { $0.id == id }?.name ?? id
            model.setScreen(.pinned(id: id, name: name))
        })
    }
}
