import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

@Suite("EdgePlacement")
struct EdgePlacementTests {
    let visible = CGRect(x: 0, y: 102, width: 1710, height: 971)   // MacBook Air 15", Dock at the bottom
    let panel = CGSize(width: 300, height: 300)

    @Test func rightEdgeTouchesTheRightSide() {
        let o = EdgePlacement(edge: .right, verticalFraction: 0.5).panelOrigin(panelSize: panel, visibleFrame: visible)
        #expect(o.x == visible.maxX - panel.width)
    }

    @Test func leftEdgeTouchesTheLeftSide() {
        let o = EdgePlacement(edge: .left, verticalFraction: 0.5).panelOrigin(panelSize: panel, visibleFrame: visible)
        #expect(o.x == visible.minX)
    }

    @Test func verticalFractionSpansTheVisibleFrame() {
        let bottom = EdgePlacement(edge: .right, verticalFraction: 0).panelOrigin(panelSize: panel, visibleFrame: visible)
        let top = EdgePlacement(edge: .right, verticalFraction: 1).panelOrigin(panelSize: panel, visibleFrame: visible)
        #expect(bottom.y == visible.minY)
        #expect(top.y == visible.maxY - panel.height)
    }

    @Test func droppingPicksTheNearestEdgeAndKeepsHeight() {
        let left = EdgePlacement.dropped(panelOrigin: CGPoint(x: 300, y: 500), panelSize: panel, visibleFrame: visible)
        #expect(left.edge == .left)
        let right = EdgePlacement.dropped(panelOrigin: CGPoint(x: 1100, y: 500), panelSize: panel, visibleFrame: visible)
        #expect(right.edge == .right)
        let back = right.panelOrigin(panelSize: panel, visibleFrame: visible)
        #expect(abs(back.y - 500) < 0.001)
    }

    @Test func droppingOutsideClampsInsideTheScreen() {
        let high = EdgePlacement.dropped(panelOrigin: CGPoint(x: 1500, y: 5000), panelSize: panel, visibleFrame: visible)
        #expect(high.verticalFraction == 1)
        let low = EdgePlacement.dropped(panelOrigin: CGPoint(x: 1500, y: -400), panelSize: panel, visibleFrame: visible)
        #expect(low.verticalFraction == 0)
    }

    @Test func survivesARoundTripThroughUserDefaults() throws {
        let p = EdgePlacement(edge: .left, verticalFraction: 0.25)
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(EdgePlacement.self, from: data) == p)
    }
}
