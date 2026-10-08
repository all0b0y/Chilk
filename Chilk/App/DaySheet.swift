import AppKit
import ChilkBrain
import ChilkCore
import EventKit
import SwiftUI

/// Slice 9b (decision 16): «Лист дня» — a small window in the system style. The day is its title; timed things by time,
/// then the rest. Round Notes-style ticks: a tap fills the circle with peach and greys and strikes the text through (a
/// light spring); a second tap undoes it; Reminders is marked at once. «+» adds, a double click edits, ✕ deletes — direct
/// actions in Chilk's own window, no card. It opens beside Chilk at the edge: he peeks out, hops at a tick and cheers at
/// the last one.
@MainActor
@Observable
final class DaySheetModel {
    struct Row: Identifiable, Equatable {
        let id: String
        var title: String
        var time: PlanTime?
        var done: Bool
    }

    var day = Calendar.current.startOfDay(for: Date())
    var rows: [Row] = []
    var noAccess = false
    var editing: String?
    var editTitle = ""
    var editTimed = false
    var editTime = Date()
    var adding = false
    var addTitle = ""
    var addTimed = false
    var addTime = Date()

    /// Decision 17: «Подвести» — the day's results. Ticks wait for «Готово»; what is left open moves on (the default) or
    /// goes; «Готово» applies it all at once.
    var reviewing = false
    var choices: [String: PlanNotice.Choice] = [:]
    var finishReview: () -> Void = {}

    /// «→ Завтра», or «→ Сегодня» when the day after the reviewed one is today (yesterday's review in the morning).
    var moveLabel: String {
        let cal = Calendar.current
        return cal.isDateInToday(cal.date(byAdding: .day, value: 1, to: day)!) ? String(localized: "→ Сегодня")
                                                                               : String(localized: "→ Завтра")
    }

    /// Slice 10 (decisions 1, 3, 6): «Ещё не записано · после «Да»» — the draft being collected or the plan card waiting for
    /// «Да». `index` — the thing's place in the draft / on the card (the block shows timed things first).
    struct Unwritten: Identifiable, Equatable {
        let index: Int
        let item: PlanItem
        var id: Int { index }
    }
    var unwritten: [Unwritten] = []
    var canRecord = false
    var unwrittenEditing: Int?
    var editUnwritten: (Int, PlanItem?) -> Void = { _, _ in }
    var record: () -> Void = {}

    func beginUnwrittenEdit(_ u: Unwritten) {
        editing = nil
        adding = false
        unwrittenEditing = u.index
        editTitle = u.item.title
        editTimed = u.item.time != nil
        editTime = (u.item.time ?? PlanTime(hour: 9, minute: 0)!).date(on: day, calendar: .current)
    }

    func saveUnwrittenEdit() {
        guard let i = unwrittenEditing else { return }
        let t = String(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !t.isEmpty else { return }
        unwrittenEditing = nil
        let time = editTimed ? PlanTime(of: editTime, calendar: .current) : nil
        // An untouched guessed time keeps its «· день?» mark (as «Изменить» did in 9b).
        let old = unwritten.first { $0.index == i }?.item
        editUnwritten(i, PlanItem(title: t, time: time, guessed: old?.guessed == true && old?.time == time))
    }

    static func unwritten(_ items: [PlanItem]) -> [Unwritten] {
        let all = items.enumerated().map { Unwritten(index: $0.offset, item: $0.element) }
        return all.filter { $0.item.time != nil }.sorted { ($0.item.time!, $0.index) < ($1.item.time!, $1.index) }
            + all.filter { $0.item.time == nil }
    }

    var toggle: (Row) -> Void = { _ in }
    var saveEdit: () -> Void = {}
    var delete: (Row) -> Void = { _ in }
    var add: () -> Void = {}

    /// «Пятница, 9 октября».
    var title: String {
        let t = PlanDay.title(day, now: Date(), calendar: .current)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    func beginEdit(_ row: Row) {
        unwrittenEditing = nil
        editing = row.id
        editTitle = row.title
        editTimed = row.time != nil
        editTime = (row.time ?? PlanTime(hour: 9, minute: 0)!).date(on: day, calendar: .current)
    }

    func beginAdd() {
        adding = true
        addTitle = ""
        addTimed = false
        addTime = PlanTime(hour: 9, minute: 0)!.date(on: day, calendar: .current)
    }

    static func rows(_ items: [ReminderInfo]) -> [Row] {
        let cal = Calendar.current
        let all = items.compactMap { r -> Row? in
            guard let id = r.id else { return nil }
            return Row(id: id, title: r.title, time: r.timed ? r.due.map { PlanTime(of: $0, calendar: cal) } : nil, done: r.done)
        }
        return all.filter { $0.time != nil }.sorted { $0.time! < $1.time! } + all.filter { $0.time == nil }
    }
}

/// Decision 16: a round Notes-style tick — a tap fills it with peach and a check (a light spring); again — empty.
struct PlanTick: View {
    let done: Bool
    let action: () -> Void
    static let peach = Color(red: 1, green: 0xB4 / 255, blue: 0x9A / 255)

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { action() } } label: {
            ZStack {
                Circle().fill(done ? Self.peach : Color.clear)
                Circle().strokeBorder(done ? Self.peach : Color.secondary.opacity(0.55), lineWidth: 1.5)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: 20, height: 20)
            .scaleEffect(done ? 1 : 0.94)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct DaySheetView: View {
    @Bindable var model: DaySheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.reviewing {
                Text(String(localized: "Подведём день")).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(model.title).font(.title2.weight(.semibold))
            if model.noAccess {
                Label(String(localized: "Нет доступа к «Напоминаниям» — разреши в Настройках"), systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else if model.rows.isEmpty && !model.adding && model.unwritten.isEmpty {
                Text(String(localized: "На этот день ничего нет")).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rows) { row in
                        if model.editing == row.id { editor(title: $model.editTitle, timed: $model.editTimed, time: $model.editTime,
                                                            save: model.saveEdit, cancel: { model.editing = nil }) }
                        else { line(row) }
                    }
                    if model.adding {
                        editor(title: $model.addTitle, timed: $model.addTimed, time: $model.addTime, save: model.add,
                               cancel: { model.adding = false })
                    }
                    if !model.reviewing && !model.unwritten.isEmpty { unwrittenBlock }
                }
            }
            if model.reviewing {
                HStack {
                    Spacer()
                    Button(String(localized: "Готово")) { model.finishReview() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.noAccess)
                }
            } else {
                Button { model.beginAdd() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help(String(localized: "Добавить дело")).disabled(model.noAccess)
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 320, alignment: .topLeading)
    }

    /// Slice 10: what Chilk has not written yet — paler, no ticks; ✕ and a double click edit it; «Записать» = «Да».
    private var unwrittenBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.vertical, 6)
            Text(String(localized: "Ещё не записано · после «Да»")).font(.subheadline).foregroundStyle(.secondary)
            ForEach(model.unwritten) { u in
                if model.unwrittenEditing == u.index {
                    editor(title: $model.editTitle, timed: $model.editTimed, time: $model.editTime,
                           save: model.saveUnwrittenEdit, cancel: { model.unwrittenEditing = nil })
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary).frame(width: 20, height: 20)
                        if let t = u.item.time { Text(t.text).monospacedDigit().foregroundStyle(.tertiary) }
                        Text(u.item.title).foregroundStyle(.secondary).lineLimit(1)
                            .onTapGesture(count: 2) { model.beginUnwrittenEdit(u) }
                        Spacer(minLength: 8)
                        Button { model.editUnwritten(u.index, nil) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary).help(String(localized: "Убрать"))
                    }
                    .padding(.vertical, 5)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Записать")) { model.record() }
                    .buttonStyle(.borderedProminent).disabled(!model.canRecord || model.noAccess)
            }
            .padding(.top, 4)
        }
    }

    private func line(_ row: DaySheetModel.Row) -> some View {
        HStack(spacing: 10) {
            PlanTick(done: row.done) { model.toggle(row) }
            if let t = row.time { Text(t.text).monospacedDigit().foregroundStyle(.secondary) }
            Text(row.title).strikethrough(row.done).foregroundStyle(row.done ? .secondary : .primary).lineLimit(1)
                .onTapGesture(count: 2) { if !model.reviewing { model.beginEdit(row) } }
            Spacer(minLength: 8)
            if model.reviewing {
                if !row.done {
                    Picker(String(localized: "Что дальше"), selection: Binding(get: { model.choices[row.id] ?? .tomorrow },
                                                                           set: { model.choices[row.id] = $0 })) {
                        Text(model.moveLabel).tag(PlanNotice.Choice.tomorrow)
                        Text(String(localized: "✕ Не нужно")).tag(PlanNotice.Choice.drop)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            } else {
                Button { model.delete(row) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help(String(localized: "Удалить"))
            }
        }
        .padding(.vertical, 5)
    }

    private func editor(title: Binding<String>, timed: Binding<Bool>, time: Binding<Date>, save: @escaping () -> Void,
                        cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Дело"), text: title).textFieldStyle(.roundedBorder).onSubmit(save)
            Toggle(String(localized: "Время"), isOn: timed).toggleStyle(.checkbox)
            DatePicker(String(localized: "Время"), selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden().frame(width: 76).disabled(!timed.wrappedValue).opacity(timed.wrappedValue ? 1 : 0.35)
            Button(String(localized: "Готово"), action: save).keyboardShortcut(.defaultAction)
                .disabled(title.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button { cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
final class DaySheet: NSObject, NSWindowDelegate {
    private let reminders: ChilkReminderExecutor
    private let model = DaySheetModel()
    private var window: NSWindow?
    /// His window and side: the sheet opens beside him.
    var chilkFrame: () -> (frame: NSRect, onLeftEdge: Bool) = { (.zero, false) }
    /// A tick (`last`: every thing of the day is done now).
    var onTick: (_ last: Bool) -> Void = { _ in }
    /// Chilk's own write went through: the popover and the main window re-read.
    var onWrite: () -> Void = {}
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    /// «Готово» in the review: the day, how many were done, how many there were, how many writes Reminders refused.
    var onReviewed: (_ day: Date, _ done: Int, _ total: Int, _ failed: Int) -> Void = { _, _, _, _ in }
    /// Slice 10: what is not written yet for a day (the planner), its edit (nil — ✕) and «Записать».
    var unwritten: (Date) -> (items: [PlanItem], canRecord: Bool)? = { _ in nil }
    var editUnwritten: (Date, Int, PlanItem?) -> Void = { _, _, _ in }
    var recordUnwritten: (Date) -> Void = { _ in }
    /// The review's done states as Reminders had them: only what changed is written.
    private var original: [String: Bool] = [:]
    /// Counted with `WindowPolicy` from open to close: a minimised sheet is still open (`isVisible` is false for it).
    private var counted = false
    private var observer: NSObjectProtocol?
    var log: (String) -> Void = { _ in }

    init(reminders: ChilkReminderExecutor) {
        self.reminders = reminders
        super.init()
        model.toggle = { [weak self] row in self?.toggle(row) }
        model.saveEdit = { [weak self] in self?.saveEdit() }
        model.delete = { [weak self] row in self?.delete(row) }
        model.add = { [weak self] in self?.add() }
        model.finishReview = { [weak self] in self?.finishReview() }
        model.editUnwritten = { [weak self] i, item in
            guard let self else { return }
            self.log("plan sheet: unwritten \(item == nil ? "removed" : "edited")")
            self.editUnwritten(self.model.day, i, item)
        }
        model.record = { [weak self] in
            guard let self else { return }
            self.log("plan sheet: «Записать»")
            self.recordUnwritten(self.model.day)
        }
        // Decision 16 (review 9b): edits in Reminders (Mac, iPhone) reach the open sheet of any day, not only today's.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isOpen == true { self?.reload() } }
        }
    }

    var isOpen: Bool { counted }
    var shownDay: Date { model.day }

    func open(day: Date, review: Bool = false) {
        let d = Calendar.current.startOfDay(for: day)
        // Slice 10: the same day asked again (after «Да», «Изменить») — the open sheet stays where the user put it.
        if counted, model.day == d, !review, !model.reviewing, window?.isMiniaturized == false {
            window?.makeKeyAndOrderFront(nil)
            log("plan sheet shown again for \(PlanDay.iso(d, calendar: .current))")
            reload()
            return
        }
        model.day = d
        model.editing = nil
        model.unwrittenEditing = nil
        model.adding = false
        model.reviewing = review
        model.choices = [:]
        original = [:]
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "Лист дня")
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: DaySheetView(model: model))
            w.setContentSize(NSSize(width: 380, height: 440))
            w.minSize = NSSize(width: 340, height: 320)
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        window?.setContentSize(NSSize(width: review ? 480 : 380, height: 440))
        place()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if !counted {
            counted = true
            WindowPolicy.opened()
            onOpen()
        }
        log("plan sheet opened for \(PlanDay.iso(model.day, calendar: .current))\(review ? " (review)" : "")")
        reload()
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        guard counted else { return }
        counted = false
        WindowPolicy.closed()
        onClose()
    }

    /// Beside Chilk, on the screen's side away from the edge he lives at.
    private func place() {
        guard let w = window else { return }
        let chilk = chilkFrame()
        let size = w.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(chilk.frame) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = chilk.onLeftEdge ? chilk.frame.maxX - 20 : chilk.frame.minX - size.width + 20
        x = min(max(x, screen.minX + 12), screen.maxX - size.width - 12)
        let y = min(max(chilk.frame.midY - size.height / 2, screen.minY + 12), screen.maxY - size.height - 12)
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Re-read the day (after Chilk's writes, and on every change in Reminders while it is open).
    func reload() {
        refreshUnwritten()
        if model.reviewing, !original.isEmpty { return }      // the review keeps its own ticks until «Готово»
        let day = model.day
        Task {
            do {
                let items = try await reminders.day(day)
                guard day == model.day else { return }
                model.noAccess = false
                model.rows = DaySheetModel.rows(items)
                if model.reviewing { original = Dictionary(model.rows.map { ($0.id, $0.done) }, uniquingKeysWith: { a, _ in a }) }
            } catch ReminderAccessError.denied {
                guard day == model.day else { return }
                model.noAccess = true
                model.rows = []
            } catch {
                log("plan sheet: Reminders not readable — \(error)")       // what is shown stays
            }
        }
    }

    /// Slice 10: the «Ещё не записано» block from the planner (the draft or the waiting card changed).
    func refreshUnwritten() {
        let u = unwritten(model.day)
        let rows = DaySheetModel.unwritten(u?.items ?? [])
        if model.unwritten != rows {
            if let i = model.unwrittenEditing, !rows.contains(where: { $0.index == i }) { model.unwrittenEditing = nil }
            model.unwritten = rows
        }
        model.canRecord = u?.canRecord ?? false
    }

    private func toggle(_ row: DaySheetModel.Row) {
        guard let i = model.rows.firstIndex(where: { $0.id == row.id }) else { return }
        if model.reviewing { model.rows[i].done.toggle(); return }      // decision 17: «Готово» writes it all at once
        let done = !row.done
        model.rows[i].done = done                                       // at once; undone again if Reminders refuses
        let last = done && model.rows.allSatisfy(\.done)
        if done { onTick(last) }
        Task {
            let r = await reminders.setDone(id: row.id, done: done)
            log("plan sheet tick \(done ? "on" : "off") ok=\(r.success)")
            if !r.success, let j = model.rows.firstIndex(where: { $0.id == row.id }) { model.rows[j].done = row.done }
            onWrite()
        }
    }

    private func entry(_ title: String, timed: Bool, time: Date) -> (title: String, due: Date, timed: Bool)? {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !t.isEmpty else { return nil }
        let due = timed ? PlanTime(of: time, calendar: .current).date(on: model.day, calendar: .current) : model.day
        return (t, due, timed)
    }

    private func add() {
        guard let e = entry(model.addTitle, timed: model.addTimed, time: model.addTime) else { return }
        model.adding = false
        Task {
            let r = await reminders.create(title: e.title, due: e.due, timed: e.timed)
            log("plan sheet add ok=\(r.success)")
            reload()
            onWrite()
        }
    }

    private func saveEdit() {
        guard let id = model.editing, let e = entry(model.editTitle, timed: model.editTimed, time: model.editTime) else { return }
        model.editing = nil
        Task {
            let r = await reminders.edit(id: id, title: e.title, due: e.due, timed: e.timed)
            log("plan sheet edit ok=\(r.success)")
            reload()
            onWrite()
        }
    }

    private func delete(_ row: DaySheetModel.Row) {
        model.rows.removeAll { $0.id == row.id }
        Task {
            let r = await reminders.delete(id: row.id)
            log("plan sheet delete ok=\(r.success)")
            reload()
            onWrite()
        }
    }

    /// A tick from elsewhere (the main window's «Сегодня»): the same write and the same reaction. `last`: every thing of
    /// the day is done after it.
    func setDone(_ row: DaySheetModel.Row, done: Bool, last: Bool) {
        if done { onTick(last) }
        if isOpen, let i = model.rows.firstIndex(where: { $0.id == row.id }) { model.rows[i].done = done }
        Task {
            let r = await reminders.setDone(id: row.id, done: done)
            log("plan tick from «Сегодня» \(done ? "on" : "off") ok=\(r.success)")
            if isOpen { reload() }
            onWrite()
        }
    }

    /// Decision 17: «Готово» — the ticks that changed, then every open thing «→ Завтра» (on the next day, without a time)
    /// or «✕ Не нужно» (deleted); the sheet closes and he reacts.
    private func finishReview() {
        guard model.reviewing else { return }
        let cal = Calendar.current
        let day = model.day
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let rows = model.rows
        let choices = model.choices
        let original = original
        let done = rows.filter(\.done).count
        let ops = PlanNotice.reviewOps(rows.map { PlanNotice.ReviewRow(id: $0.id, title: $0.title, done: $0.done) },
                                       original: original, choices: choices)
        model.reviewing = false
        self.original = [:]
        close()
        Task {
            var moved = 0, dropped = 0, failed = 0
            for op in ops {
                switch op {
                case .setDone(let id, let on):
                    if !(await reminders.setDone(id: id, done: on)).success { failed += 1 }
                case .move(let id, let title):
                    if (await reminders.edit(id: id, title: title, due: next, timed: false)).success { moved += 1 } else { failed += 1 }
                case .drop(let id):
                    if (await reminders.delete(id: id)).success { dropped += 1 } else { failed += 1 }
                }
            }
            log("plan review \(PlanDay.iso(day, calendar: cal)): \(done) of \(rows.count) done, \(moved) moved to "
                + "\(PlanDay.iso(next, calendar: cal)), \(dropped) dropped, \(failed) failed")
            onWrite()
            onReviewed(day, done, rows.count, failed)
        }
    }

    /// Acceptance only: in the review, the second open thing «✕ Не нужно».
    func demoReviewDropSecond() {
        let open = model.rows.filter { !$0.done }
        if model.reviewing, open.count > 1 { model.choices[open[1].id] = .drop }
    }

    /// Acceptance only: «Готово» in the review.
    func demoFinishReview() { finishReview() }

    /// Acceptance only: tick the first open thing through the same path as a click.
    func demoTickFirst() {
        if let row = model.rows.first(where: { !$0.done }) { model.toggle(row) }
    }

    /// Acceptance: the sheet's own window to a PNG.
    func snapshot(to url: URL) {
        guard let w = window else { return }
        _ = WindowSnapshot.write(w, to: url)
    }
}
