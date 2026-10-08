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

    var send: () -> Void = {}
    var typed: () -> Void = {}
    var toggleMic: () -> Void = {}
    var delete: (UUID) -> Void = { _ in }
    /// «Память» lives in the main window (slice 5c).
    var openMemory: () -> Void = {}
    /// Slice 8c: the confirmation card on screen (the same as at the edge), its buttons and its inline editor.
    var card: ChatCard?
    var cardEdit: CardEditModel?
    var cardNote: String?
    var cardButton: (String) -> Void = { _ in }
    var cardSave: () -> Void = {}

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
                    Button { model.openMemory() } label: { Label(Lines.memoryTitle, systemImage: "brain") }
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
                    if let card = model.card {
                        CardBox(card: card, model: model).id("card")
                    }
                    if let note = model.cardNote {
                        Label(note, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).id("cardNote")
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
            .onChange(of: model.card) { proxy.scrollTo("bottom", anchor: .bottom) }
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

/// Slice 8c: what the chat shows of the card.
struct ChatCard: Equatable {
    let id: UUID
    let lines: [String]
    let buttons: [String]
}

/// The card in the chat: its lines, «Да / Изменить / Нет»; «Изменить» opens the fields right in it.
private struct CardBox: View {
    let card: ChatCard
    @Bindable var model: ChatModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(card.lines.enumerated()), id: \.offset) { i, line in
                    Text(line).font(i == 0 ? .body.weight(.semibold) : .callout)
                        .foregroundStyle(i == 0 ? Color.primary : (line.contains("?") ? TrayView.peach : Color.secondary))
                }
                if let edit = model.cardEdit {
                    Divider()
                    CardEditFields(model: edit)
                    HStack {
                        Button(String(localized: "Отмена")) { model.cardEdit = nil }
                        Button(String(localized: "Готово")) { model.cardSave() }.keyboardShortcut(.defaultAction).disabled(!edit.valid)
                    }
                } else {
                    HStack {
                        ForEach(card.buttons, id: \.self) { title in
                            Button(title) { model.cardButton(title) }
                        }
                    }
                }
            }
            .padding(12)
            .background(TrayView.peach.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TrayView.peach.opacity(0.5)))
            Spacer(minLength: 60)
        }
    }
}

struct CardEditFields: View {
    @Bindable var model: CardEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.hasTitle { TextField(model.titleLabel, text: $model.title) }
            if model.hasText && model.isNote {
                // A note has lines: Return makes a new one here (in a text field it would press «Готово»).
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.textLabel).foregroundStyle(.secondary)
                    TextEditor(text: $model.text).font(.body).scrollContentBackground(.hidden).frame(minHeight: 96, maxHeight: 150)
                }
            } else if model.hasText {
                TextField(model.textLabel, text: $model.text, axis: .vertical).lineLimit(2...4)
            }
            if model.hasDate {
                DatePicker(String(localized: "Когда"), selection: $model.date, in: model.earliest...,
                           displayedComponents: model.dateOnly ? [.date] : [.date, .hourAndMinute])
                    .environment(\.locale, Locale(identifier: "ru_RU"))
            }
            if model.hasMinutes { MinutesField(text: $model.minutesText, label: model.minutesLabel) }
        }
        .frame(maxWidth: 360)
    }
}
