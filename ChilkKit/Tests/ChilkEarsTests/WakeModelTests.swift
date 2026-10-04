import Foundation
@testable import ChilkEars
import Testing

@Suite("Wake model")
struct WakeModelTests {
    @Test func shortWakeWindowsDoNotRequireASRTimestamps() {
        let options = WakeModel.decodingOptions(prompt: [17, 23])
        #expect(options.withoutTimestamps)
        #expect(options.language == "ru")
        #expect(options.promptTokens == [17, 23])
        #expect(options.concurrentWorkerCount == 1)
    }

    @Test func anExplicitMissingModelFailsWithoutDownloadingAFallback() async {
        let model = WakeModel()
        do {
            try await model.prepare(folder: URL(fileURLWithPath: "/nonexistent/chilk-model"), base: FileManager.default.temporaryDirectory)
            Issue.record("missing model was silently replaced")
        } catch {
            #expect(String(describing: error).contains("model"))
        }
    }
}
