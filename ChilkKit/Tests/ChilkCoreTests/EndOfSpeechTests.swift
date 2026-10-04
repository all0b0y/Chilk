import Testing
@testable import ChilkCore

@Suite("End of speech")
struct EndOfSpeechTests {
    @Test func stopsAfterAPauseFollowingSpeech() {
        var d = EndOfSpeech(start: 0)
        d.heard("Какая", isFinal: false, at: 0.8)
        d.heard("Какая погода", isFinal: false, at: 1.3)
        #expect(d.verdict(at: 2.5) == .keepListening)
        #expect(d.verdict(at: 2.81) == .done)
    }

    @Test func aFinalSegmentAnswersSooner() {
        var d = EndOfSpeech(start: 0)
        d.heard("Пошути", isFinal: true, at: 1)
        #expect(d.verdict(at: 2.1) == .done)
    }

    @Test func revisionsKeepHimListening() {
        var d = EndOfSpeech(start: 0)
        d.heard("Найди", isFinal: false, at: 1)
        d.heard("Найди файл", isFinal: false, at: 2.4)
        #expect(d.verdict(at: 3.6) == .keepListening)
        d.heard("Найди файл", isFinal: false, at: 3.7)                       // same text: not a change
        #expect(d.verdict(at: 3.95) == .done)
    }

    @Test func silenceAndEndlessTalk() {
        let quiet = EndOfSpeech(start: 0)
        #expect(quiet.verdict(at: 6.9) == .keepListening)
        #expect(quiet.verdict(at: 7) == .nothingHeard)
        var chatty = EndOfSpeech(start: 0)
        for t in stride(from: 0.5, through: 25, by: 0.5) { chatty.heard("слово \(t)", isFinal: false, at: t) }
        #expect(chatty.verdict(at: 25) == .tooLong)
    }

    @Test func callingOnlyHisNameIsNotARequest() {
        for text in ["Чилк", "Чел", "Чу", "Эй, Чилк!", "И эй, Чилк"] {
            #expect(EndOfSpeech.stripAddress(text, allowNameOnly: true).isEmpty)
        }
        #expect(EndOfSpeech.stripAddress("И эй, Чел, найди файл", allowNameOnly: true) == "Найди файл")
        #expect(EndOfSpeech.stripAddress("Человек на луне", allowNameOnly: true) == "Человек на луне")
    }

    @Test func independentlyConfirmedWakeStripsApplesChikMishearing() {
        #expect(EndOfSpeech.stripAddress("Чик пошути про понедельник", allowNameOnly: true) == "Пошути про понедельник")
        #expect(EndOfSpeech.stripAddress("Чик", allowNameOnly: true).isEmpty)
        #expect(EndOfSpeech.stripAddress("Чикаго — большой город", allowNameOnly: true) == "Чикаго — большой город")
        #expect(EndOfSpeech.stripAddress("Чик пошути") == "Чик пошути")
        #expect(!WakePhrase.matches("Чик пошути"))
    }

    @Test func theAddressIsNotPartOfTheRequest() {
        #expect(EndOfSpeech.stripAddress("Чилк, пошути в пять") == "Пошути в пять")
        #expect(EndOfSpeech.stripAddress("эй чилк найди файл") == "Найди файл")
        #expect(EndOfSpeech.stripAddress("Какая погода?") == "Какая погода?")
        #expect(EndOfSpeech.stripAddress("Чел напомни позвонить маме") == "Напомни позвонить маме")   // misheard name
        #expect(EndOfSpeech.stripAddress("Человек на луне") == "Человек на луне")                    // a real word stays
        #expect(EndOfSpeech.stripAddress("Эй, как дела") == "Эй, как дела")                          // «эй» alone stays
        #expect(EndOfSpeech.stripAddress("Чилк") == "Чилк")                                          // nothing after the name
    }
}
