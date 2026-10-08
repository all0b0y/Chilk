import AppKit
import ChilkBrain
import ChilkCore
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

struct DaySheetView: View {
    @Bindable var model: DaySheetModel
    static let peach = Color(red: 1, green: 0xB4 / 255, blue: 0x9A / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.title2.weight(.semibold))
            if model.noAccess {
                Label(String(localized: "Нет доступа к «Напоминаниям» — разреши в Настройках"), systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else if model.rows.isEmpty && !model.adding {
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
                }
            }
            Button { model.beginAdd() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help(String(localized: "Добавить дело")).disabled(model.noAccess)
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 320, alignment: .topLeading)
    }

    private func line(_ row: DaySheetModel.Row) -> some View {
        HStack(spacing: 10) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { model.toggle(row) } } label: {
                ZStack {
                    Circle().fill(row.done ? Self.peach : Color.clear)
                    Circle().strokeBorder(row.done ? Self.peach : Color.secondary.opacity(0.55), lineWidth: 1.5)
                    if row.done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 20, height: 20)
                .scaleEffect(row.done ? 1 : 0.94)
            }
            .buttonStyle(.plain)
            if let t = row.time { Text(t.text).monospacedDigit().foregroundStyle(.secondary) }
            Text(row.title).strikethrough(row.done).foregroundStyle(row.done ? .secondary : .primary)
                .onTapGesture(count: 2) { model.beginEdit(row) }
            Spacer(minLength: 8)
            Button { model.delete(row) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary).help(String(localized: "Удалить"))
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
    var log: (String) -> Void = { _ in }

    init(reminders: ChilkReminderExecutor) {
        self.reminders = reminders
        super.init()
        model.toggle = { [weak self] row in self?.toggle(row) }
        model.saveEdit = { [weak self] in self?.saveEdit() }
        model.delete = { [weak self] row in self?.delete(row) }
        model.add = { [weak self] in self?.add() }
    }

    var isOpen: Bool { window?.isVisible == true }
    var shownDay: Date { model.day }

    func open(day: Date) {
        model.day = Calendar.current.startOfDay(for: day)
        model.editing = nil
        model.adding = false
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
        place()
        let wasOpen = isOpen
        window?.makeKeyAndOrderFront(nil)
        if !wasOpen { WindowPolicy.opened(); onOpen() }
        log("plan sheet opened for \(PlanDay.iso(model.day, calendar: .current))")
        reload()
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
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
        let day = model.day
        Task {
            do {
                let items = try await reminders.day(day)
                guard day == model.day else { return }
                model.noAccess = false
                model.rows = DaySheetModel.rows(items)
            } catch {
                model.noAccess = true
                model.rows = []
            }
        }
    }

    private func toggle(_ row: DaySheetModel.Row) {
        guard let i = model.rows.firstIndex(where: { $0.id == row.id }) else { return }
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
