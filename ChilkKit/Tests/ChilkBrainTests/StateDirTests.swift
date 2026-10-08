import Foundation
import Testing
@testable import ChilkBrain

/// Review 2026-10-08: an empty CHILK_STATE_DIR is the user's own state — demo hooks must not act on it.
struct StateDirTests {
    @Test func onlyASetNonEmptyStateDirIsolatesARun() {
        #expect(StateDir.isolated(in: [:]) == nil)
        #expect(StateDir.isolated(in: ["CHILK_STATE_DIR": ""]) == nil)
        #expect(StateDir.isolated(in: ["CHILK_STATE_DIR": "/tmp/s-run"])?.path == "/tmp/s-run")
    }
}
