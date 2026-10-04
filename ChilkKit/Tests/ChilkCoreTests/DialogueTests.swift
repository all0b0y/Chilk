import Foundation
import Testing
@testable import ChilkCore

@Suite("Dialogue")
struct DialogueTests {
    @Test func windowsDependOnWhatHeSaid() {
        #expect(Dialogue.followUpWindow(mode: .question, replyLength: 28) == 12)      // 2 s to read + 10
        #expect(Dialogue.followUpWindow(mode: .answer, replyLength: 140) == 16)       // 10 s to read + 6
        #expect(Dialogue.followUpWindow(mode: .done, replyLength: 10) == 6)           // at least 2 s to read + 4
        #expect(Dialogue.followUpWindow(mode: .end, replyLength: 20) == nil)
    }

    @Test func theHotkeyAndAClickMeanDifferentThingsInEachPhase() {
        #expect(Dialogue.hotkey(.idle) == .startListening)
        #expect(Dialogue.hotkey(.listening) == .doneTalking)
        #expect(Dialogue.hotkey(.waiting) == .leaveQuietly)
        #expect(Dialogue.hotkey(.thinking) == .interruptAndListen)
        #expect(Dialogue.hotkey(.answering) == .interruptAndListen)
        #expect(Dialogue.click(.idle) == nil)
        #expect(Dialogue.click(.waiting) == .leaveQuietly)
        #expect(Dialogue.click(.answering) == .cancel)
    }

    @Test func aShortPauseContinuesTheConversationALongOneStartsClean() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(!Dialogue.continues(lastExchange: nil, now: t))
        #expect(Dialogue.continues(lastExchange: t - 14 * 60, now: t))
        #expect(!Dialogue.continues(lastExchange: t - 15 * 60, now: t))
    }

    @Test func structuredRepliesAreParsed() {
        let r = Dialogue.parse(#"{"reply":"Уточни, какой матч?","mode":"question"}"#)
        #expect(r.reply == "Уточни, какой матч?")
        #expect(r.mode == .question)
        #expect(Dialogue.parse("```json\n{\"mode\":\"end\",\"reply\":\"Обращайся 🙂\"}\n```").mode == .end)
    }

    @Test func plainTextStillWorksIfTheModelIgnoresTheSchema() {
        #expect(Dialogue.parse("Какой матч ты имеешь в виду?").mode == .question)
        #expect(Dialogue.parse("Сегодня воскресенье.") == ("Сегодня воскресенье.", .answer))
    }

    @Test func bubblesGetPlainText() {
        #expect(Dialogue.plain("Победа 5:3. [Источник](https://www.mancity.com/results/mens)") == "Победа 5:3. Источник (mancity.com)")
        #expect(Dialogue.plain("**Важно**: `код`") == "Важно: код")
    }

    /// Decision 2026-10-04: emoji belong to Chilk's own canned lines, never to Codex replies.
    @Test func codexRepliesLoseEmojiButKeepOrdinarySymbols() {
        #expect(Dialogue.plain("Хорошего вечера 🌙") == "Хорошего вечера")
        #expect(Dialogue.plain("Пока! 👋🏽 Береги себя ❤️") == "Пока! Береги себя")
        #expect(Dialogue.plain("Готово 👨‍👩‍👧 , таймер 1️⃣") == "Готово, таймер")
        #expect(Dialogue.plain("🇷🇺 Флаг") == "Флаг")
        #expect(Dialogue.plain("Счёт 2:1, +5°C, № 3, 10 → 12, © УЕФА, #1 и *") == "Счёт 2:1, +5°C, № 3, 10 → 12, © УЕФА, #1 и *")
        #expect(Dialogue.plain("Первая строка 🙂\nвторая") == "Первая строка\nвторая")
    }

    @Test func theReplyStreamsOutOfUnfinishedJSON() {
        #expect(Dialogue.partialReply(#"{"re"#) == "")
        #expect(Dialogue.partialReply(#"{"reply":"Прив"#) == "Прив")
        #expect(Dialogue.partialReply(#"{"reply": "Он сказал \"гол\"\nи уш"#) == "Он сказал \"гол\"\nи уш")
        #expect(Dialogue.partialReply(#"{"reply":"Готово","mode":"do"#) == "Готово")
        #expect(Dialogue.partialReply(#"{"reply":"\u0441\u0443"#) == "су")
        #expect(Dialogue.partialReply(#"{"reply":"а\u04"#) == "а")                   // escape split across deltas
        #expect(Dialogue.partialReply(#"{"mode":"answer","reply":"Ок"#) == "Ок")
        #expect(Dialogue.partialReply("Просто текст") == "Просто текст")
    }
}
