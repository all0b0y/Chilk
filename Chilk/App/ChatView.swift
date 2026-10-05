import ChilkCore
import Foundation
import SwiftUI

/// What the chat window shows (slice 5b). Actions are wired by `ChatController`.
@MainActor
@Observable
final class ChatModel {
    var sessions: [ChatSession] = []
    /// The chat on the right; `nil` = a new one (the next question starts it).
    var selected: UUID?
    /// The typed question being answered right now.
    var pending: String?
    var draft = ""
    var error: String?
    var listening = false
    var voiceBusy = false
    var facts: [MemoryFact] = []
    var showMemory = false

    var send: () -> Void = {}
    var typed: () -> Void = {}
    var toggleMic: () -> Void = {}
    var delete: (UUID) -> Void = { _ in }
    /// Returns why it was not kept (`nil` = kept).
    var remember: (String) -> String? = { _ in nil }
    var edit: (UUID, String) -> String? = { _, _ in nil }
    var forget: (UUID) -> Void = { _ in }

    var current: ChatSession? { selected.flatMap { id in sessions.first { $0.id == id } } }
}

/// Decision 21: system macOS 26 look, peach accent; the sticker style only for Chilk himself (the avatar).
struct ChatView: View {
    @Bindable var model: ChatModel
    @State private var confirmDelete: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selected) {
                ForEach(model.sessions) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title.isEmpty ? Lines.chatUntitled : s.title).lineLimit(1)
                        Text(s.lastActive, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(s.id)
                    .contextMenu { Button(Lines.chatDelete, role: .destructive) { confirmDelete = s.id } }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .overlay {
                if model.sessions.isEmpty {
                    Text(Lines.chatNoChats).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        } detail: {
            VStack(spacing: 0) {
                transcript
                Divider()
                inputBar
            }
            .toolbar {
                ToolbarItem {
                    Button { model.showMemory = true } label: { Label(Lines.memoryTitle, systemImage: "brain") }
                        .help(Lines.memoryHelp)
                }
                if let id = model.selected {
                    ToolbarItem {
                        Button { confirmDelete = id } label: { Label(Lines.chatDelete, systemImage: "trash") }
                    }
                }
            }
        }
        .tint(TrayView.peach)
        .sheet(isPresented: $model.showMemory) { MemoryView(model: model) }
        .confirmationDialog(Lines.chatDeleteQuestion, isPresented: Binding(get: { confirmDelete != nil },
                                                                           set: { if !$0 { confirmDelete = nil } })) {
            Button(Lines.chatDelete, role: .destructive) {
                if let id = confirmDelete { model.delete(id) }
                confirmDelete = nil
            }
        } message: { Text(Lines.chatDeleteNote) }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.current == nil && model.pending == nil {
                        empty
                    }
                    ForEach(model.current?.turns ?? []) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                    if let pending = model.pending {
                        TurnRow(turn: ChatTurn(role: .user, via: .text, text: pending, at: Date()))
                        HStack(spacing: 8) {
                            Avatar()
                            ProgressView().controlSize(.small)
                            Text(Lines.chatThinking).foregroundStyle(.secondary)
                        }
                        .id("pending")
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout).id("error")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: model.current?.turns.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.pending) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.selected) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Avatar(size: 64)
            Text(Lines.chatEmpty).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { model.toggleMic() } label: {
                Image(systemName: model.listening ? "mic.fill" : "mic").foregroundStyle(model.listening ? TrayView.peach : .secondary)
            }
            .buttonStyle(.borderless)
            .help(Lines.chatMicHelp)
            .disabled(model.voiceBusy || model.pending != nil)
            TextField(model.voiceBusy ? Lines.chatVoiceBusy : (model.listening ? Lines.chatListening : Lines.chatPlaceholder),
                      text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { model.send() }
                .onChange(of: model.draft) { model.typed() }
                .disabled(model.voiceBusy)
            Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.voiceBusy || model.pending != nil
                          || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }
}

private struct TurnRow: View {
    let turn: ChatTurn

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 60)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if turn.via == .voice { Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary).help(Lines.chatViaVoice) }
                    Text(turn.text).textSelection(.enabled)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(TrayView.peach.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Avatar()
                VStack(alignment: .leading, spacing: 6) {
                    Text(turn.text).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    if !turn.chips.isEmpty {
                        ChipRow(chips: turn.chips)
                    }
                }
                Spacer(minLength: 60)
            }
        }
    }
}

/// Decision 14: system icons, no content; a failure is red.
private struct ChipRow: View {
    let chips: [ChatChip]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Label(Lines.chipTitle(chip), systemImage: Lines.chipIcon(chip))
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(chip.failed ? Color.red : Color.secondary)
                    .background(Capsule().fill(chip.failed ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12)))
            }
        }
    }
}

/// Chilk himself (the app icon is his sticker portrait).
private struct Avatar: View {
    var size: CGFloat = 26

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size, height: size)
    }
}

/// Decision 17: what Chilk remembers — edit, remove, add. In 5c it moves to the main window's «Память».
struct MemoryView: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var newFact = ""
    @State private var note: String?
    @State private var editing: UUID?
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Lines.memoryTitle).font(.headline)
                Text(verbatim: "\(model.facts.count)/\(MemoryBook.limit)").foregroundStyle(.secondary)
                Spacer()
                Button(Lines.memoryDone) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(Lines.memoryHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if model.facts.isEmpty { Text(Lines.memoryEmpty).foregroundStyle(.secondary) }
                ForEach(model.facts) { fact in
                    HStack(spacing: 8) {
                        if editing == fact.id {
                            TextField(Lines.memoryEdit, text: $editText).onSubmit { commitEdit(fact.id) }
                            Button(Lines.memorySave) { commitEdit(fact.id) }
                        } else {
                            Text(fact.text)
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
                }
            }
            .frame(minHeight: 220)
            HStack {
                TextField(Lines.memoryNew, text: $newFact).onSubmit(add)
                Button(Lines.memoryAdd, action: add)
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty || model.facts.count >= MemoryBook.limit)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
        .frame(width: 460, height: 420)
        .tint(TrayView.peach)
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
