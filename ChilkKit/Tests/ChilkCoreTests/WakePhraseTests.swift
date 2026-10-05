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

    /// Decision 2026-10-05 (MVP): in noise the request is what Whisper heard after the name.
    @Test func theRequestIsTheTextAfterTheAddress() {
        #expect(WakePhrase.request(in: "Чилк, поставь таймер на 10 минут") == "поставь таймер на 10 минут")
        #expect(WakePhrase.request(in: "Эй, Чилк! Какая погода завтра?") == "Какая погода завтра?")
        #expect(WakePhrase.request(in: "И эйчилк, найди файл с отчётом.") == "найди файл с отчётом.")
        #expect(WakePhrase.request(in: "Чиллк — напомни позвонить маме") == "напомни позвонить маме")
        #expect(WakePhrase.request(in: "Чилк.") == "")
        #expect(WakePhrase.request(in: "Короче, Чилк опять тупит") == nil)
    }

    @Test func aWakeRequestJoinsWhatWhisperHeardWithWhatFollowed() {
        #expect(WakePhrase.request(heardInCheck: nil, dictated: "Чилк, найди файл") == "Найди файл")
        #expect(WakePhrase.request(heardInCheck: "поставь таймер", dictated: "") == "Поставь таймер")
        #expect(WakePhrase.request(heardInCheck: "поставь таймер", dictated: " на 10 минут") == "Поставь таймер на 10 минут")
        #expect(WakePhrase.request(heardInCheck: "", dictated: "Чел, какая погода?") == "Какая погода?")
        #expect(WakePhrase.request(heardInCheck: "", dictated: "") == "")
    }
}
