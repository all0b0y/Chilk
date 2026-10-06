import ChilkCore
import CoreGraphics
import Testing
@testable import ChilkRender

// Slice 6c, found in the live acceptance run: a blink drew ^ ^ (happy) in sad states — one signal, one meaning.
@Suite("Blinks keep the mood")
@MainActor
struct BlinkMoodTests {
    let m = Metrics.standard

    func eyes(_ mood: (inout Mood) -> Void) -> [Part] {
        var p = CharacterPose()
        p.x = m.dockX
        p.eyeOpen = 0.05                                             // mid-blink
        mood(&p.mood)
        return ChilkRenderer.placements(pose: p, metrics: m, mirrored: false)
            .filter { $0.slot == Slot.eye || $0.slot == Slot.eye + 1 }.map(\.part)
    }

    @Test func aBlinkInASadOrStoneMoodIsNeverASmile() {
        for set in [{ (m: inout Mood) in m.sad = true }, { $0.slumped = true }, { $0.sulking = true }, { $0.deadpan = true }] {
            let parts = eyes(set)
            #expect(parts.count == 2)
            #expect(!parts.contains(.eyeHappy(lw: 1)), "\(parts)")
        }
        #expect(eyes { _ in }.allSatisfy { $0 == .eyeHappy(lw: 1) })   // an ordinary blink stays as it was
    }
}
