import ChilkCore
import Testing

@Suite("Wake phrase")
struct WakePhraseTests {
    @Test func onlyAnExactNameAtTheStartWakesHim() {
        for text in ["Чилк", "Чилк, какая погода?", "Эй, Чилк!", "эй чилк найди файл", "И эй, Чилк, привет", "Чилка, привет"] {
            #expect(WakePhrase.matches(text), "miss: \(text)")
        }
        for text in ["", "Человек, ты где?", "Чел, привет", "Чилл", "училка", "Я позову Чилка", "Эй, человек", "Эй, я не Чилк", "не Чилк", "Чилковый чай"] {
            #expect(!WakePhrase.matches(text), "false wake: \(text)")
        }
    }
}
