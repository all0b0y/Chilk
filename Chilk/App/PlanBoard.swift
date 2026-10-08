import AppKit
import ChilkBrain
import ChilkCore
import EventKit

/// Slice 9b (decisions 9, 14, 16): today's plan as the «Чилк» list has it — the popover's «План: 2 из 5» and the main
/// window read it here. Re-read on every change in Reminders (Mac or iPhone: `EKEventStoreChanged`), after Chilk's own
/// writes and when the day turns. Never asks for access: without it there is simply no plan line.
@MainActor
final class PlanBoard {
    private let reminders: ChilkReminderExecutor
    private let fake: Bool
    private(set) var items: [ReminderInfo] = []
    private(set) var day = Calendar.current.startOfDay(for: Date())
    /// The «Напоминания» switch in «Инструменты» (decision 18: no plan without it).
    var enabled: () -> Bool = { true }
    var onChange: [() -> Void] = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var reading = false
    private var again = false

    init(reminders: ChilkReminderExecutor, fake: Bool) {
        self.reminders = reminders
        self.fake = fake
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayTick() }
        }
        timer?.tolerance = 10
    }

    /// Reading needs access granted earlier (the first plan or reminder asks for it) and the switch on.
    var canRead: Bool { enabled() && (fake || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess) }

    /// «План: 2 из 5» — nil when nothing is planned today (or no access).
    var summary: (done: Int, total: Int)? { items.isEmpty ? nil : (items.filter(\.done).count, items.count) }

    func refresh() {
        guard canRead else {
            if !items.isEmpty { items = []; changed() }
            return
        }
        if reading { again = true; return }
        reading = true
        let day = self.day
        Task {
            let fresh = (try? await reminders.day(day)) ?? items              // a failed read keeps what was there
            reading = false
            if day == self.day, fresh != items { items = fresh; changed() }   // the day may have turned meanwhile
            if again { again = false; refresh() }
        }
    }

    private func dayTick() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != day else { return }
        day = today
        items = []
        changed()
        refresh()
    }

    private func changed() { for f in onChange { f() } }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
