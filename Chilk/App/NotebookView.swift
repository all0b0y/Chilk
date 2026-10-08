import AppKit
import ChilkCore
import Observation
import SwiftUI

/// What the notebook shows (slice 7a, SPEC decisions 26 and 29).
@MainActor
@Observable
final class TicTacToeModel {
    enum Phase: Equatable { case setup, placing, yourMove, chilkThinks, gameOver, matchOver }

    /// Slice 7c: the notebook holds tic-tac-toe or battleship.
    var kind = GameKind.ticTacToe
    var phase = Phase.setup
    var board = TicTacToe()
    var match = GameMatch()
    /// The length chosen on the first sheet.
    var length = GameMatch.defaultLength
    /// The winning line, struck through in pencil.
    var strike: [Int]?
    /// The pencil's wobble for this game: stable while the game lasts, new for the next one.
    var seed: UInt64 = 1
    /// Increments per game: the marks of a new game are drawn again.
    var gameIndex = 0
    var headline = GameLines.ticTacToe
    var status = GameLines.howMany

    /// Decision 32: a request shown in the notebook (between games, or as a sign after 10 min).
    var card: GameCard?
    /// A short reply written on the sheet for 3 s («Ты же только что пил»).
    var note: String?
    var answer: (Int) -> Void = { _ in }

    var start: (Int) -> Void = { _ in }
    var tap: (Int) -> Void = { _ in }
    // Slice 7c: battleship — both seas once the battle starts, your fleet while you place it.
    var sea: BattleshipGame?
    var placing = Fleet(ships: [])
    var fire: (Int) -> Void = { _ in }
    var place: (Int, Int, Int, Bool?) -> Void = { _, _, _, _ in }
    var shuffle: () -> Void = {}
    var battle: () -> Void = {}
    // Slice 7d: draughts — the board, your selected piece, Chilk's last move.
    var draughts: Draughts?
    var selected: Int?
    /// The squares of your move so far (the piece, then the landings clicked): a series is chosen step by step
    /// when two of them end alike.
    var partial: [Int] = []
    var lastMove: DraughtsMove?
    var square: (Int) -> Void = { _ in }
    var again: () -> Void = {}
    var close: () -> Void = {}
    /// Slice 9, decision 5: the dark sheet (remembered in games.json, shared by every notebook game).
    var dark = false
    var toggleTheme: () -> Void = {}
}

struct GameCard: Equatable {
    let text: String
    let buttons: [String]
}

/// The sheet's colours (slice 9, decision 5; was: squared paper with a red margin): plain white, or a dark graphite
/// sheet with light lines. One palette for every notebook game; the sticky request card stays light.
struct NotebookPalette: Equatable {
    var paper: Color
    var graphite: Color
    /// You write with a blue pen, Chilk draws with a pencil.
    var ink: Color
    /// A short reply written on the sheet («Бить обязательно!»).
    var note: Color

    static let light = NotebookPalette(paper: .white, graphite: Color(red: 0.24, green: 0.25, blue: 0.29),
                                       ink: Color(red: 0.16, green: 0.34, blue: 0.68),
                                       note: Color(red: 0.84, green: 0.33, blue: 0.33))
    /// Graphite #2B2938 — the colour of Chilk's own outline — with light lines.
    static let dark = NotebookPalette(paper: Color(red: 0x2B / 255, green: 0x29 / 255, blue: 0x38 / 255),
                                      graphite: Color(red: 0xEC / 255, green: 0xE9 / 255, blue: 0xF2 / 255),
                                      ink: Color(red: 0.55, green: 0.75, blue: 1.0),
                                      note: Color(red: 1.0, green: 0.56, blue: 0.56))
}

/// The notebook: a plain sheet, the board drawn by hand, Chilk beside it at the sheet's right edge (he comes out
/// from behind it, as from behind the screen edge). White, or dark with the ☀️/🌙 button (slice 9).
struct NotebookView: View {
    @Bindable var model: TicTacToeModel
    let hero: HeroView

    static let size = CGSize(width: 600, height: 440)
    /// Slice 7c: two seas need a wider sheet.
    static func size(for kind: GameKind) -> CGSize {
        switch kind {
        case .battleship: CGSize(width: 900, height: 470)
        case .checkers: CGSize(width: 640, height: 470)
        default: size
        }
    }
    /// The sheet's palette now. Set only by GameController together with `model.dark` (main thread); the sheet's content
    /// is rebuilt (`.id(model.dark)`) when it changes, so every board's Canvas reads the new colours.
    nonisolated(unsafe) static var palette = NotebookPalette.light
    static var paper: Color { palette.paper }
    static var ink: Color { palette.ink }
    static var graphite: Color { palette.graphite }
    static var note: Color { palette.note }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Self.paper
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.headline).font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(model.status).font(.system(size: 15, design: .rounded)).foregroundStyle(Self.graphite.opacity(0.75))
                    // A fixed line: a reply or «Бить обязательно!» must not move the board under the cursor.
                    Text(model.note ?? " ").font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Self.note)
                }
                .foregroundStyle(Self.graphite)
                if model.kind == .battleship {
                    Group {
                        if model.phase == .setup { setup } else { SeaBoards(model: model) }
                    }
                    .frame(height: 240, alignment: .topLeading)
                } else if model.kind == .checkers {
                    Group {
                        if model.phase == .setup { setup } else { DraughtsBoard(model: model) }
                    }
                    .frame(width: DraughtsBoard.side, height: DraughtsBoard.side, alignment: .topLeading)
                } else {
                    Group {
                        if model.phase == .setup { setup } else { board }
                    }
                    .frame(width: 270, height: 270, alignment: .topLeading)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.leading, 66)
            .padding(.top, 34)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(model.dark)                                // a new palette: the boards and marks are drawn again (not Chilk)
            HeroPortrait(view: hero).frame(width: hero.size.width, height: hero.size.height)
            ThemeButton(dark: model.dark, toggle: model.toggleTheme)
                .padding(.top, 12)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            if let card = model.card {
                RequestCard(card: card, answer: model.answer)
                    .frame(width: 250)
                    .padding(.top, 64)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: Self.size(for: model.kind).width, height: Self.size(for: model.kind).height)
        .environment(\.colorScheme, model.dark ? .dark : .light)
        .tint(TrayView.peach)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: $model.length) {
                ForEach(Array(model.kind.matchLengths), id: \.self) {
                    Text(verbatim: "\($0)").tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: model.kind.matchLengths.count <= 3 ? 140 : 250)
            Button(GameLines.start) { model.start(model.length) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.card != nil)
                .controlSize(.large)
        }
        .padding(.top, 8)
    }

    private var board: some View {
        GeometryReader { geo in
            let cell = geo.size.width / 3
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    PencilStroke(from: BoardLines.ends(i).0, to: BoardLines.ends(i).1, seed: model.seed &+ UInt64(100 + i))
                        .stroke(Self.graphite.opacity(0.85), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                ForEach(0..<9, id: \.self) { i in
                    let center = CGPoint(x: cell * (CGFloat(i % 3) + 0.5), y: cell * (CGFloat(i / 3) + 0.5))
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: cell, height: cell)
                            .position(center)
                            .onTapGesture { model.tap(i) }
                        if let mark = model.board.cells[i] {
                            MarkView(mark: mark, seed: model.seed &+ UInt64(i) &* 7919)
                                .frame(width: cell * 0.6, height: cell * 0.6)
                                .position(center)
                                .allowsHitTesting(false)
                                .id("\(model.gameIndex)-\(i)")
                        }
                    }
                }
                if let line = model.strike {
                    StrikeView(line: line, seed: model.seed &+ 999)
                        .allowsHitTesting(false)
                        .id("strike-\(model.gameIndex)")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.phase == .placing {
                Button(GameLines.shuffle) { model.shuffle() }
                Button(GameLines.toBattle) { model.battle() }.keyboardShortcut(.defaultAction).disabled(model.card != nil)
            }
            if model.phase == .matchOver {
                Button(GameLines.again) { model.again() }.keyboardShortcut(.defaultAction).disabled(model.card != nil)
            }
            Button(GameLines.enough) { model.close() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.large)
    }
}

/// ☀️ / 🌙 in the sheet's corner (slice 9, decision 5): the sheet goes dark or white for every notebook game.
private struct ThemeButton: View {
    let dark: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: dark ? "sun.max" : "moon")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NotebookView.graphite.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(NotebookView.graphite.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(dark ? GameLines.lightSheet : GameLines.darkSheet)
    }
}

/// A request pinned to the sheet like a sticky note, with the request's own buttons (decision 32).
private struct RequestCard: View {
    let card: GameCard
    let answer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(NotebookPalette.light.graphite)    // a light sticky note on either sheet
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(Array(card.buttons.enumerated()), id: \.offset) { i, title in
                    Button(title) { answer(i) }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.95, blue: 0.66))
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2))
        .environment(\.colorScheme, .light)
        .rotationEffect(.degrees(-1.2))
    }
}

/// The board's four lines, in unit coordinates of the board.
private enum BoardLines {
    static func ends(_ i: Int) -> (CGPoint, CGPoint) {
        let at: CGFloat = i % 2 == 0 ? 1.0 / 3 : 2.0 / 3
        return i < 2 ? (CGPoint(x: at, y: 0.03), CGPoint(x: at, y: 0.97)) : (CGPoint(x: 0.03, y: at), CGPoint(x: 0.97, y: at))
    }
}

/// A hand-drawn stroke between two unit points: slightly bent and off, by a wobble fixed by `seed`, so it stays still
/// while it is on paper.
struct PencilStroke: Shape {
    let from: CGPoint
    let to: CGPoint
    let seed: UInt64
    var wobble: CGFloat = 0.012

    func path(in rect: CGRect) -> Path {
        var r = SeededRandom(seed: seed &* 2_654_435_761 &+ 1)
        func n() -> CGFloat { CGFloat(r.next() * 2 - 1) * wobble }
        func point(_ u: CGPoint) -> CGPoint { CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height) }
        let a = CGPoint(x: from.x + n(), y: from.y + n()), b = CGPoint(x: to.x + n(), y: to.y + n())
        let bend = n() * 1.6
        let nx = -(b.y - a.y), ny = b.x - a.x                    // perpendicular: the bow of a hand-drawn line
        let c1 = CGPoint(x: a.x + (b.x - a.x) / 3 + nx * bend, y: a.y + (b.y - a.y) / 3 + ny * bend)
        let c2 = CGPoint(x: a.x + (b.x - a.x) * 2 / 3 + nx * bend * 0.6, y: a.y + (b.y - a.y) * 2 / 3 + ny * bend * 0.6)
        var p = Path()
        p.move(to: point(a))
        p.addCurve(to: point(b), control1: point(c1), control2: point(c2))
        return p
    }
}

/// Chilk's nought: one pencil loop that overshoots its start a little.
struct PencilRing: Shape {
    let seed: UInt64

    func path(in rect: CGRect) -> Path {
        var r = SeededRandom(seed: seed &* 6_364_136_223_846_793_005 &+ 7)
        let start = r.next() * 2 * .pi
        let sweep = 2 * .pi * (1.06 + r.next() * 0.08)
        let rx = 0.44 + r.next() * 0.04, ry = 0.46 + r.next() * 0.03
        let phase = r.next() * 2 * .pi
        var p = Path()
        let steps = 56
        for s in 0...steps {
            let u = Double(s) / Double(steps)
            let a = start - sweep * u                              // counter-clockwise, as a hand draws it
            let wob = 1 + 0.035 * sin(a * 2 + phase) - 0.04 * u   // the end comes in a little
            let pt = CGPoint(x: rect.midX + CGFloat(cos(a) * rx * wob) * rect.width,
                             y: rect.midY + CGFloat(sin(a) * ry * wob) * rect.height)
            if s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// One mark, drawn when it appears: your cross in two quick pen strokes, his nought in one pencil loop.
private struct MarkView: View {
    let mark: TicMark
    let seed: UInt64
    @State private var first = 0.0
    @State private var second = 0.0

    var body: some View {
        ZStack {
            if mark == .x {
                PencilStroke(from: CGPoint(x: 0.08, y: 0.1), to: CGPoint(x: 0.92, y: 0.9), seed: seed, wobble: 0.03)
                    .trim(from: 0, to: first)
                    .stroke(NotebookView.ink, style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                PencilStroke(from: CGPoint(x: 0.9, y: 0.08), to: CGPoint(x: 0.1, y: 0.92), seed: seed &+ 1, wobble: 0.03)
                    .trim(from: 0, to: second)
                    .stroke(NotebookView.ink, style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            } else {
                PencilRing(seed: seed)
                    .trim(from: 0, to: first)
                    .stroke(NotebookView.graphite, style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: mark == .x ? 0.14 : 0.45)) { first = 1 }
            withAnimation(.easeOut(duration: 0.14).delay(0.17)) { second = 1 }
        }
    }
}

/// The winning three, struck through in pencil past both ends.
private struct StrikeView: View {
    let line: [Int]
    let seed: UInt64
    @State private var drawn = 0.0

    var body: some View {
        let a = Self.center(line.first!), b = Self.center(line.last!)
        let dx = b.x - a.x, dy = b.y - a.y, over: CGFloat = 0.32
        PencilStroke(from: CGPoint(x: a.x - dx * over / 2, y: a.y - dy * over / 2),
                     to: CGPoint(x: b.x + dx * over / 2, y: b.y + dy * over / 2), seed: seed, wobble: 0.01)
            .trim(from: 0, to: drawn)
            .stroke(NotebookView.graphite, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            .onAppear { withAnimation(.easeInOut(duration: 0.38)) { drawn = 1 } }
    }

    private static func center(_ i: Int) -> CGPoint {
        CGPoint(x: (CGFloat(i % 3) + 0.5) / 3, y: (CGFloat(i / 3) + 0.5) / 3)
    }
}
