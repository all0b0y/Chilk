import ChilkCore
import SwiftUI

/// Slice 9b (decision 12): «Изменить» on a plan card — the plan as a list: the thing, its time (on or off), ✕, and a bare
/// «+». «Готово» makes a new card (no guess marks: the user set the times himself).
@MainActor
@Observable
final class PlanEditModel {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var timed: Bool
        var time: Date
    }

    let original: ActionCard
    let day: Date
    let already: [String]
    var rows: [Row]

    init?(_ card: ActionCard) {
        guard case .plan(let day, let items, let already) = card.kind else { return nil }
        original = card
        self.day = day
        self.already = already
        let nine = PlanTime(hour: 9, minute: 0)!
        rows = items.map { Row(title: $0.title, timed: $0.time != nil, time: ($0.time ?? nine).date(on: day, calendar: .current)) }
    }

    func add() {
        rows.append(Row(title: "", timed: false, time: PlanTime(hour: 9, minute: 0)!.date(on: day, calendar: .current)))
    }

    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }

    var canSave: Bool { rows.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    func edited() -> ActionCard {
        let items = rows.compactMap { r -> PlanItem? in
            let t = String(r.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard !t.isEmpty else { return nil }
            return PlanItem(title: t, time: r.timed ? PlanTime(of: r.time, calendar: .current) : nil)
        }
        return ActionCard(kind: .plan(day: day, items: items, already: already))
    }
}

struct PlanEditView: View {
    @Bindable var model: PlanEditModel
    var save: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($model.rows) { $row in
                        HStack(spacing: 8) {
                            TextField(String(localized: "Дело"), text: $row.title).textFieldStyle(.roundedBorder)
                            Toggle(String(localized: "Время"), isOn: $row.timed).toggleStyle(.checkbox)
                            DatePicker(String(localized: "Время"), selection: $row.time, displayedComponents: .hourAndMinute)
                                .labelsHidden().frame(width: 76).disabled(!row.timed).opacity(row.timed ? 1 : 0.35)
                            Button { model.remove(row.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).help(String(localized: "Убрать"))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Button { model.add() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help(String(localized: "Добавить дело"))
            HStack {
                Spacer()
                Button(String(localized: "Отмена"), action: cancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "Готово"), action: save).keyboardShortcut(.defaultAction).disabled(!model.canSave)
            }
        }
        .padding(14)
    }
}
