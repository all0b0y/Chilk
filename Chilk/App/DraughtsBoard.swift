import ChilkCore
import SwiftUI

/// Slice 7d (decision 31): the draughts board on the notebook's sheet — dark squares hatched in pencil, your pieces in
/// blue pen at the bottom, Chilk's in pencil at the top, a king with a small crown. Click your piece, then where it goes
/// (the possible squares get a dot); Chilk's last move is drawn as a pencil line.
struct DraughtsBoard: View {
    @Bindable var model: TicTacToeModel

    static let cell: CGFloat = 31
    static let side = cell * 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for s in 0..<64 where Draughts.isDark(s) {
                    let r = Self.rect(s)
                    ctx.fill(Path(r), with: .color(NotebookView.graphite.opacity(0.13)))
                    var hatch = Path()                                     // pencil hatching
                    var x = r.minX - r.height
                    while x < r.maxX {
                        hatch.move(to: CGPoint(x: max(r.minX, x), y: r.maxY - max(0, r.minX - x)))
                        hatch.addLine(to: CGPoint(x: min(r.maxX, x + r.height), y: r.minY + max(0, x + r.height - r.maxX)))
                        x += 6
                    }
                    ctx.stroke(hatch, with: .color(NotebookView.graphite.opacity(0.18)), lineWidth: 0.6)
                }
            }
            PencilBox(seed: model.seed, wobble: 0.004)
                .stroke(NotebookView.graphite.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            if model.partial.count > 1 {                               // your series so far, in blue
                LastMove(path: model.partial).stroke(NotebookView.ink.opacity(0.6),
                                                     style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
            if let m = model.lastMove {
                LastMove(path: m.path).stroke(NotebookView.graphite.opacity(0.55),
                                              style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
            if let b = model.draughts {
                ForEach(0..<64, id: \.self) { s in
                    if let p = b.squares[s] {
                        PieceView(piece: p, selected: model.selected == s)
                            .frame(width: Self.cell * 0.78, height: Self.cell * 0.78)
                            .position(Self.center(s))
                            .allowsHitTesting(false)
                    }
                }
                ForEach(targets(b), id: \.self) { s in
                    Circle().fill(NotebookView.ink.opacity(0.45)).frame(width: 8, height: 8)
                        .position(Self.center(s)).allowsHitTesting(false)
                }
            }
            Color.clear
                .contentShape(Rectangle())
                .frame(width: Self.side, height: Self.side)
                .onTapGesture(coordinateSpace: .local) { p in
                    let c = Int(p.x / Self.cell), r = Int(p.y / Self.cell)
                    guard (0..<8).contains(c), (0..<8).contains(r) else { return }
                    model.square(r * 8 + c)
                }
                .allowsHitTesting(model.phase == .yourMove)
        }
        .frame(width: Self.side, height: Self.side)
    }

    /// The next square of every legal move that goes through your squares so far.
    private func targets(_ b: Draughts) -> [Int] {
        guard model.selected != nil, model.phase == .yourMove, !model.partial.isEmpty else { return [] }
        let p = model.partial
        return Array(Set(b.moves.filter { $0.path.count > p.count && Array($0.path.prefix(p.count)) == p }
            .map { $0.path[p.count] })).sorted()
    }

    static func rect(_ s: Int) -> CGRect {
        CGRect(x: CGFloat(s % 8) * cell, y: CGFloat(s / 8) * cell, width: cell, height: cell)
    }

    static func center(_ s: Int) -> CGPoint { CGPoint(x: rect(s).midX, y: rect(s).midY) }

    private struct LastMove: Shape {
        let path: [Int]
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: DraughtsBoard.center(path[0]))
            for s in path.dropFirst() { p.addLine(to: DraughtsBoard.center(s)) }
            return p
        }
    }

    private struct PieceView: View {
        let piece: DraughtsPiece
        let selected: Bool
        var body: some View {
            let color = piece.side == .you ? NotebookView.ink : NotebookView.graphite
            ZStack {
                Circle().fill(color.opacity(piece.side == .you ? 0.22 : 0.3))
                PencilRing(seed: UInt64(piece.side == .you ? 11 : 23))
                    .stroke(color, style: StrokeStyle(lineWidth: selected ? 3.4 : 2.2, lineCap: .round))
                if piece.king {
                    Crown().stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 13, height: 9)
                }
            }
            .shadow(color: selected ? NotebookView.ink.opacity(0.5) : .clear, radius: 3)
        }
    }

    /// A little three-point crown on a king.
    private struct Crown: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.25))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.6))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - r.width * 0.28, y: r.minY + r.height * 0.6))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.25))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}
