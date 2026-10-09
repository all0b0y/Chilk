import ChilkCore
import Testing

/// Slice 10 (SPEC «Срез 10», Б9, decision 19): a plain «да» stays the app's own; anything else goes to Codex, which may
/// answer the card on screen — the app counts it only on the user's agreeing words of that very turn.
struct SliceTenCardAnswerTests {
    /// The incident (2026-10-08 23:27): not a plain «да» for `parse`, but it agrees.
    let incident = "Да всё я подтверждаю все правильно это сделал"

    @Test func theIncidentsWordsAreNotAPlainYesButTheyAgree() {
        #expect(CardAnswer.parse(incident) == .correction(incident))
        #expect(CardAnswer.agrees(incident))
        for words in ["Да, всё правильно, записывай", "подтверждаю, всё верно", "Да всё верно, ставь", "согласен, пиши"] {
            #expect(CardAnswer.agrees(words), "\(words)")
        }
    }

    @Test func aChangeAQuestionOrARefusalDoesNotAgree() {
        for words in ["Да, но в 11", "давай лучше в пятницу", "да?", "точно записал?", "нет, не надо", "да, не надо",
                      "какой ты милашка", "а что там на карточке", "запиши только хлеб", "", "а ты правильно записал", "правильно ли записал",
                      "да, давай в 11", "да, давай завтра", "как правильно"] {
            #expect(!CardAnswer.agrees(words), "\(words)")
        }
    }

    @Test func aRefusalDeclines() {
        for words in ["нет, такое не надо", "не, не надо", "Отмена, передумал я", "забудь про это"] {
            #expect(CardAnswer.declines(words), "\(words)")
        }
        for words in ["да, всё верно", "нет?", "нет, но в 11", "какой ты милашка"] {
            #expect(!CardAnswer.declines(words), "\(words)")
        }
    }

    @Test func codexAnswersOnlyTheCardThatWasUpOnTheUsersOwnWords() {
        func judge(_ yes: Bool, _ words: String?, up: Bool = true, same: Bool = true, deleting: Bool = false,
                   expired: Bool = false) -> CardModelAnswer {
            CardModelAnswer.judge(yes: yes, words: words, cardUp: up, sameCard: same, deleting: deleting, expired: expired)
        }
        #expect(judge(true, incident) == .confirm)
        #expect(judge(false, "нет, такое не надо") == .decline)
        #expect(judge(true, incident, up: false) == .noCard)
        #expect(judge(true, nil) == .notAgreed)                          // not a user turn while the card was up
        #expect(judge(true, incident, same: false) == .newCard)          // proposed in this turn: only the user confirms
        #expect(judge(true, "точно в 10?") == .question)
        #expect(judge(true, "Да, но в 11") == .notAgreed)                // a change: the card's tool again
        #expect(judge(true, "да, всё верно, сноси", deleting: true) == .deleteNeedsUser)
        #expect(judge(true, incident, expired: true) == .expired)
        #expect(judge(false, incident) == .notAgreed)                    // agreeing words never decline
        #expect(judge(true, "нет, не надо") == .notAgreed)               // refusing words never confirm
    }
}
