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
    var lastMove: DraughtsMove?
    var square: (Int) -> Void = { _ in }
    var again: () -> Void = {}
    var close: () -> Void = {}
}

struct GameCard: Equatable {
    let text: String
    let buttons: [String]
}

/// The notebook: a sheet of squared paper, the board drawn by hand, Chilk beside it at the sheet's right edge
/// (he comes out from behind it, as from behind the screen edge). Light on purpose: it is paper.
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
    static let paper = Color(red: 0.985, green: 0.975, blue: 0.94)
    static let grid = Color(red: 0.55, green: 0.72, blue: 0.86).opacity(0.38)
    static let margin = Color(red: 0.9, green: 0.45, blue: 0.45).opacity(0.55)
    /// You write with a blue pen, Chilk draws with a pencil.
    static let ink = Color(red: 0.16, green: 0.34, blue: 0.68)
    static let graphite = Color(red: 0.24, green: 0.25, blue: 0.29)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SquaredPaper()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.headline).font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(model.status).font(.system(size: 15, design: .rounded)).foregroundStyle(Self.graphite.opacity(0.75))
                    if let note = model.note {
                        Text(note).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Self.margin.opacity(1))
                    }
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
            HeroPortrait(view: hero).frame(width: hero.size.width, height: hero.size.height)
            if let card = model.card {
                RequestCard(card: card, answer: model.answer)
                    .frame(width: 250)
                    .padding(.top, 64)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: Self.size(for: model.kind).width, height: Self.size(for: model.kind).height)
        .environment(\.colorScheme, .light)
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

/// A request pinned to the sheet like a sticky note, with the request's own buttons (decision 32).
private struct RequestCard: View {
    let card: GameCard
    let answer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(NotebookView.graphite)
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
        .rotationEffect(.degrees(-1.2))
    }
}

/// Squared paper with the red margin line.
private struct SquaredPaper: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(NotebookView.paper))
            var grid = Path()
            let step: CGFloat = 18
            var x: CGFloat = 0
            while x <= size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(grid, with: .color(NotebookView.grid), lineWidth: 0.7)
            var margin = Path()
            margin.move(to: CGPoint(x: 46, y: 0))
            margin.addLine(to: CGPoint(x: 46, y: size.height))
            ctx.stroke(margin, with: .color(NotebookView.margin), lineWidth: 1.2)
        }
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
