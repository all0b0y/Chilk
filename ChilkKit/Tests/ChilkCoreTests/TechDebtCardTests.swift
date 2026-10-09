import ChilkCore
import Testing

/// Tech-debt pass 2026-10-09 on the installed build: Д1 — Codex said «yes» to the card on another topic («сегодня
/// солнечно»), and «давай про погоду» would have passed the app's check; Д2 — live, «Да, но в одиннадцать» came from
/// the dictation as «Да» while the microphone still heard a voice, and the card was written at 10:00.
struct TechDebtCardTests {
    @Test func anotherTopicIsNoAgreement() {
        for words in ["давай про погоду", "сегодня солнечно и тепло", "задай мне короткий вопрос про погоду",
                      "давай поиграем в баскетбол", "ага, расскажи анекдот", "хорошо, а что с погодой"] {
            #expect(!CardAnswer.agrees(words), "\(words)")
            #expect(!CardAnswer.mayAnswer(words), "\(words)")
        }
    }

    @Test func agreementKeepsItsCompany() {
        for words in ["Да всё я подтверждаю все правильно это сделал", "Да, всё правильно, записывай", "Подтверждаю, всё верно",
                      "да, отлично, спасибо большое", "конечно, сохраняй её", "Чилк, да, всё верно", "согласен, пиши"] {
            #expect(CardAnswer.agrees(words), "\(words)")
            #expect(CardAnswer.mayAnswer(words), "\(words)")
        }
        #expect(CardAnswer.mayAnswer("нет, такое не надо"))
    }

    /// Review of the pass: words that answer HIS question count only next to a word about the card itself.
    @Test func hisQuestionsAnswerIsNoAgreement() {
        for words in ["да, сделал", "да, мне нормально", "да, круто", "да, готово"] {
            #expect(!CardAnswer.agrees(words), "\(words)")
        }
        #expect(CardAnswer.agrees("да, всё правильно, готово"))
    }

    @Test func aRefusalKeepsItsCompanyToo() {
        for words in ["нет, давай про погоду", "нет, сегодня солнечно", "нет, расскажи анекдот"] {
            #expect(!CardAnswer.declines(words), "\(words)")
            #expect(!CardAnswer.mayAnswer(words), "\(words)")
        }
        for words in ["нет, такое не надо", "не, не надо", "Отмена, передумал я", "забудь про это", "нет, не сохраняй",
                      "нет, спасибо"] {
            #expect(CardAnswer.declines(words), "\(words)")
        }
    }

    @Test func codexYesOnAnotherTopicDoesNotCount() {
        for words in ["давай про погоду", "сегодня солнечно и тепло"] {
            #expect(CardModelAnswer.judge(yes: true, words: words, cardUp: true, sameCard: true, deleting: false,
                                          expired: false) == .notAgreed, "\(words)")
        }
    }

    @Test func aVoiceAfterTheLastWordMayMeanCutWords() {
        var d = EndOfSpeech(start: 0)
        d.heard("Да", isFinal: false, at: 1.0)
        #expect(!d.cutShort)
        d.voice(at: 1.2)                       // the tail of «да» itself: the dictation lags the voice
        #expect(!d.cutShort)
        d.voice(at: 1.5)                       // half a second more: a breath, a drawn-out «да-а»
        #expect(!d.cutShort)
        d.voice(at: 1.9)                       // «…но в одиннадцать» the dictation never wrote
        #expect(d.cutShort)
        #expect(d.verdict(at: 4.9) == .keepListening)   // 4 s after the last word and 1.5 s after the voice
        #expect(d.verdict(at: 5.0) == .done)
    }

    @Test func newWordsAfterTheVoiceAreNotCut() {
        var d = EndOfSpeech(start: 0)
        d.heard("Да", isFinal: false, at: 1.0)
        d.voice(at: 1.9)
        d.heard("Да но в 11", isFinal: false, at: 2.2)
        #expect(!d.cutShort)
        var quiet = EndOfSpeech(start: 0)
        quiet.voice(at: 0.5)                   // a voice before any words is not «after the last word»
        #expect(!quiet.cutShort)
    }
}
