import ChilkCore
import Foundation
import Observation
import SwiftUI

/// Decision 17: what Chilk remembers — the main window's «Память» (slice 5c; was a sheet of the chat window in 5b).
@MainActor
@Observable
final class MemoryModel {
    var facts: [MemoryFact] = []
    /// Each returns why it was not kept (`nil` = kept).
    var remember: (String) -> String? = { _ in nil }
    var edit: (UUID, String) -> String? = { _, _ in nil }
    var forget: (UUID) -> Void = { _ in }
}

struct MemorySection: View {
    @Bindable var model: MemoryModel
    @State private var newFact = ""
    @State private var note: String?
    @State private var editing: UUID?
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Lines.memoryTitle).font(.title2.weight(.semibold))
                Text(verbatim: "\(model.facts.count)/\(MemoryBook.limit)").foregroundStyle(.secondary)
            }
            Text(Lines.memoryHelp).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(Lines.memoryNew, text: $newFact).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(Lines.memoryAdd, action: add)
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty || model.facts.count >= MemoryBook.limit)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 0) {
                if model.facts.isEmpty {
                    Text(Lines.memoryEmpty).foregroundStyle(.secondary).padding(12)
                }
                ForEach(model.facts) { fact in
                    row(fact)
                    if fact.id != model.facts.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
        }
    }

    private func row(_ fact: MemoryFact) -> some View {
        HStack(spacing: 8) {
            if editing == fact.id {
                TextField(Lines.memoryEdit, text: $editText).textFieldStyle(.roundedBorder).onSubmit { commitEdit(fact.id) }
                Button(Lines.memorySave) { commitEdit(fact.id) }
            } else {
                Text(fact.text).textSelection(.enabled)
                if fact.selfNoted {
                    Text(Lines.memorySelfNoted).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()
                Button { editing = fact.id; editText = fact.text } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help(Lines.memoryEdit)
                Button { model.forget(fact.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(Lines.memoryForget)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func add() {
        note = model.remember(newFact)
        if note == nil { newFact = "" }
    }

    private func commitEdit(_ id: UUID) {
        note = model.edit(id, editText)
        if note == nil { editing = nil }
    }
}
