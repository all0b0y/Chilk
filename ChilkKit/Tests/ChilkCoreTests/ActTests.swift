import CoreGraphics
import Testing
@testable import ChilkCore

@Suite("CharacterSim: slice 2 acts and props")
@MainActor
struct ActTests {
    let m = Metrics.standard

    func run(_ sim: CharacterSim, seconds: Double, every: ((CharacterSim) -> Void)? = nil) {
        for _ in 0..<Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: nil)
            every?(sim)
        }
    }

    @Test func standOutLevelsBringHimFurtherFromTheEdge() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 1))
        sim.standOut = .peek
        run(sim, seconds: 2)
        #expect(abs(sim.pose.x - m.peekX) < 3)
        sim.standOut = .out
        run(sim, seconds: 2)
        #expect(abs(sim.pose.x - m.outX) < 3)
        sim.standOut = .docked
        run(sim, seconds: 3)
        #expect(abs(sim.pose.x - m.dockX) < 3)
    }

    @Test func drinkingBringsAMugToHisMouthAndPutsItAway() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 2))
        sim.perform(.drink)
        run(sim, seconds: 1.3)
        #expect(sim.pose.props.contains(.mug))
        #expect(sim.pose.mugLift > 0.8)
        #expect(sim.pose.eyeOpen < 0.14)                  // ^ ^ while sipping
        run(sim, seconds: 2.0)
        #expect(sim.act == nil)
        #expect(!sim.pose.props.contains(.mug))
    }

    @Test func wornPropsStayWhileActPropsGo() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        sim.wear(.hat)
        sim.perform(.pack)
        run(sim, seconds: 3)
        #expect(sim.pose.props == [.hat, .backpack])
        sim.perform(.drink)
        run(sim, seconds: 3.5)
        #expect(sim.pose.props == [.hat, .backpack])
    }

    @Test func breathingInflatesOnTheInBreathAndDeflatesOnTheOutBreath() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 4))
        sim.perform(.breathe(seconds: 30))
        run(sim, seconds: 3.9)
        #expect(sim.breath?.inhaling == true)
        let full = sim.pose.scaleY
        run(sim, seconds: 5.9)                            // end of the out-breath
        #expect(sim.breath?.inhaling == false)
        #expect(full > sim.pose.scaleY + 0.07)
        #expect(sim.busyReason == nil || sim.busyReason == "blink" || sim.busyReason?.hasPrefix("eyes") == true)
        run(sim, seconds: 21)
        #expect(sim.act == nil)
    }

    @Test func earsPopUpWhileListeningAndHideAfter() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 8))
        sim.listening = true
        sim.hearing = 0.8
        var peak = 0.0
        run(sim, seconds: 0.6) { peak = max(peak, $0.pose.earsUp) }
        #expect(peak > 1.05)                              // springy pop, overshoots a little
        #expect(abs(sim.pose.earsUp - 1) < 0.1)
        sim.listening = false
        run(sim, seconds: 1)
        #expect(sim.pose.earsUp < 0.05)
    }

    @Test func thinkingLooksUpUntilStopped() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 9))
        sim.perform(.think(seconds: 60))
        run(sim, seconds: 1)
        #expect(sim.pose.lookY < -0.4)
        sim.stopAct()
        #expect(sim.act == nil)
    }

    @Test func noAnticsDuringActs() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 5))
        sim.perform(.breathe(seconds: 60))
        var antics = 0
        run(sim, seconds: 59) { if $0.currentAntic != nil { antics += 1 } }
        #expect(antics == 0)
    }

    @Test func aBubbleWithButtonsStaysUntilClearedWithoutBurning60fps() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 6))
        sim.say("Попей водички", buttons: ["Попил", "Я занят"])
        run(sim, seconds: 90)
        #expect(sim.pose.bubble == "Попей водички")
        #expect(sim.pose.buttons == ["Попил", "Я занят"])
        #expect(sim.busyReason != "bubble")
        sim.updateBubble("Ну попей же")
        run(sim, seconds: 0.1)
        #expect(sim.pose.bubble == "Ну попей же")
        #expect(sim.pose.bubbleAge > 80)                  // replaced in place, no new pop
        sim.clearBubble()
        run(sim, seconds: 0.5)
        #expect(sim.pose.bubble == nil)
    }
}
