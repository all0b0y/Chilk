import ChilkCore
import SwiftUI

/// Slice 7c (decision 30): the two seas on the notebook's sheet — yours on the left (your ships in blue pen, his
/// shots in pencil), his on the right (your shots in blue pen). While placing: drag a ship, click to turn it.
struct SeaBoards: View {
    @Bindable var model: TicTacToeModel

    static let cell: CGFloat = 19
    static let side = cell * CGFloat(Sea.size)
    static let letters = ["А", "Б", "В", "Г", "Д", "Е", "Ж", "З", "И", "К"]

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 4) {
                Text(GameLines.yourSea).font(.system(size: 13, weight: .medium, design: .rounded))
                labelled(yourSea)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(GameLines.hisSea).font(.system(size: 13, weight: .medium, design: .rounded))
                labelled(hisSea)
            }
        }
        .foregroundStyle(NotebookView.graphite)
    }

    /// Letters over the columns, numbers before the rows, as on a school sheet.
    private func labelled(_ board: some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 18, height: 12)
                ForEach(0..<Sea.size, id: \.self) { i in
                    Text(verbatim: Self.letters[i]).font(.system(size: 9, design: .rounded)).frame(width: Self.cell)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<Sea.size, id: \.self) { i in
                        Text(verbatim: "\(i + 1)").font(.system(size: 9, design: .rounded)).frame(width: 18, height: Self.cell)
                    }
                }
                board.frame(width: Self.side, height: Self.side)
            }
        }
    }

    private static func center(_ cell: Int) -> CGPoint {
        CGPoint(x: (CGFloat(cell % Sea.size) + 0.5) * Self.cell, y: (CGFloat(cell / Sea.size) + 0.5) * Self.cell)
    }

    private static func rect(_ ship: Ship) -> CGRect {
        CGRect(x: CGFloat(ship.x) * cell, y: CGFloat(ship.y) * cell,
               width: CGFloat(ship.horizontal ? ship.length : 1) * cell, height: CGFloat(ship.horizontal ? 1 : ship.length) * cell)
    }

    // MARK: Your sea

    private var yourSea: some View {
        ZStack(alignment: .topLeading) {
            Grid(seed: model.seed)
            if model.phase == .placing {
                ForEach(Array(model.placing.ships.enumerated()), id: \.offset) { i, ship in
                    PlacingShip(ship: ship, index: i, model: model)
                }
            } else if let sea = model.sea?.yours {
                ForEach(Array(sea.fleet.ships.enumerated()), id: \.offset) { _, ship in
                    ShipOutline(rect: Self.rect(ship), sunk: sea.isSunk(ship), pen: true)
                }
                Marks(sea: sea, pen: false, gameIndex: model.gameIndex)        // his shots, in pencil
            }
        }
    }

    // MARK: His sea

    private var hisSea: some View {
        ZStack(alignment: .topLeading) {
            Grid(seed: model.seed &+ 50)
            if let sea = model.sea?.his {
                ForEach(Array(sea.sunkShips.enumerated()), id: \.offset) { _, ship in
                    ShipOutline(rect: Self.rect(ship), sunk: true, pen: true)
                }
                Marks(sea: sea, pen: true, gameIndex: model.gameIndex)         // your shots, in blue pen
            }
            Color.clear
                .contentShape(Rectangle())
                .frame(width: Self.side, height: Self.side)
                .onTapGesture(coordinateSpace: .local) { p in
                    let x = Int(p.x / Self.cell), y = Int(p.y / Self.cell)
                    guard (0..<Sea.size).contains(x), (0..<Sea.size).contains(y) else { return }
                    model.fire(y * Sea.size + x)
                }
                .allowsHitTesting(model.phase == .yourMove)
        }
    }

    /// The sea's frame and its pencil grid.
    private struct Grid: View {
        let seed: UInt64
        var body: some View {
            Canvas { ctx, size in
                var p = Path()
                for i in 0...Sea.size {
                    let v = CGFloat(i) * SeaBoards.cell
                    p.move(to: CGPoint(x: v, y: 0)); p.addLine(to: CGPoint(x: v, y: size.height))
                    p.move(to: CGPoint(x: 0, y: v)); p.addLine(to: CGPoint(x: size.width, y: v))
                }
                ctx.stroke(p, with: .color(NotebookView.graphite.opacity(0.35)), lineWidth: 0.8)
                ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(NotebookView.graphite.opacity(0.85)), lineWidth: 1.6)
            }
        }
    }

    private struct ShipOutline: View {
        let rect: CGRect
        let sunk: Bool
        let pen: Bool
        var body: some View {
            RoundedRectangle(cornerRadius: 3)
                .fill(NotebookView.ink.opacity(sunk ? 0.08 : 0.16))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(NotebookView.ink, lineWidth: 2))
                .frame(width: rect.width - 3, height: rect.height - 3)
                .offset(x: rect.minX + 1.5, y: rect.minY + 1.5)
        }
    }

    /// Shots: a dot for a miss, a cross for a hit, small dots around a sunk ship.
    private struct Marks: View {
        let sea: Sea
        let pen: Bool
        let gameIndex: Int
        var body: some View {
            let color = pen ? NotebookView.ink : NotebookView.graphite
            ForEach(Array(sea.shots.union(sea.dots).sorted()), id: \.self) { c in
                let m = sea.mark(c), at = SeaBoards.center(c)
                Group {
                    switch m {
                    case .hit, .sunk:
                        CrossMark(color: color, seed: UInt64(c &* 31 &+ gameIndex))
                            .frame(width: SeaBoards.cell * 0.7, height: SeaBoards.cell * 0.7)
                    case .miss:
                        Circle().fill(color).frame(width: 5, height: 5)
                    default:
                        Circle().fill(color.opacity(0.55)).frame(width: 3, height: 3)
                    }
                }
                .position(at)
                .allowsHitTesting(false)
                .id("\(gameIndex)-\(c)-\(m == .sunk ? 1 : 0)")
            }
        }
    }

    private struct CrossMark: View {
        let color: Color
        let seed: UInt64
        @State private var drawn = 0.0
        var body: some View {
            ZStack {
                PencilStroke(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.9, y: 0.9), seed: seed, wobble: 0.04)
                    .trim(from: 0, to: drawn).stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                PencilStroke(from: CGPoint(x: 0.9, y: 0.1), to: CGPoint(x: 0.1, y: 0.9), seed: seed &+ 1, wobble: 0.04)
                    .trim(from: 0, to: drawn).stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { drawn = 1 } }
        }
    }

    /// A ship being placed: drag it to a new place (it snaps to the cells, or goes back if it does not fit), click to
    /// turn it.
    private struct PlacingShip: View {
        let ship: Ship
        let index: Int
        let model: TicTacToeModel
        @State private var drag = CGSize.zero

        var body: some View {
            let r = SeaBoards.rect(ship)
            RoundedRectangle(cornerRadius: 3)
                .fill(NotebookView.ink.opacity(drag == .zero ? 0.16 : 0.28))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(NotebookView.ink, lineWidth: 2))
                .frame(width: r.width - 3, height: r.height - 3)
                .contentShape(Rectangle())
                .offset(x: r.minX + 1.5 + drag.width, y: r.minY + 1.5 + drag.height)
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { drag = $0.translation }
                    .onEnded { v in
                        let dx = Int((v.translation.width / SeaBoards.cell).rounded())
                        let dy = Int((v.translation.height / SeaBoards.cell).rounded())
                        drag = .zero
                        model.place(index, ship.x + dx, ship.y + dy, nil)
                    })
                .onTapGesture { model.place(index, ship.x, ship.y, !ship.horizontal) }
        }
    }
}
