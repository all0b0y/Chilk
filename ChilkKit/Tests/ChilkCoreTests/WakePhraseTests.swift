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

    /// Bench 3c (2026-10-05): Whisper sometimes glues or doubles letters. Spelling only — no new sounds become names.
    @Test func gluedOrDoubledSpellingsOfTheNameStillWake() {
        for text in ["Эйчилк, поставь таймер", "Чиллк, найди файл", "Эй, Чиилк!", "И эйчилк, привет"] {
            #expect(WakePhrase.matches(text), "miss: \(text)")
        }
        for text in ["Чилл, отстань", "Эйчел, привет", "Короче, Чилк опять тупит", "Скажи Чилку, что я ушёл", "Чиллить дома"] {
            #expect(!WakePhrase.matches(text), "false wake: \(text)")
        }
    }
}
