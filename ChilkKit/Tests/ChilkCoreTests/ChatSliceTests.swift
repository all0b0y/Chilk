import Foundation
import Testing
@testable import ChilkCore

/// Slice 5b (SPEC «Срез 5», decisions 10–12, 17): the shared chat log and Chilk's memory.
@Suite("Chat log")
struct ChatLogTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    @Test func aFirstExchangeStartsAChatTitledByTheQuestion() {
        var log = ChatLog()
        let id = log.record(question: "  Поставь таймер на чай ", answer: "Поставил", via: .voice,
                            chips: [ChatChip(kind: .timer, subject: "чай", minutes: 10)], thread: "t1", continuing: nil, at: t0)
        #expect(log.sessions.count == 1)
        let s = log.sessions[0]
        #expect(s.id == id && s.title == "Поставь таймер на чай")
        #expect(s.turns.map(\.role) == [.user, .chilk])
        #expect(s.turns.map(\.via) == [.voice, .voice])
        #expect(s.turns[1].chips == [ChatChip(kind: .timer, subject: "чай", minutes: 10)])
        #expect(s.turns[0].chips.isEmpty)
    }

    @Test func theSameThreadKeepsTheChatANewThreadStartsAnother() {
        var log = ChatLog()
        let a = log.record(question: "раз", answer: "1", via: .voice, chips: [], thread: "t1", continuing: nil, at: t0)
        let b = log.record(question: "два", answer: "2", via: .text, chips: [], thread: "t1", continuing: nil, at: at(5))
        let c = log.record(question: "три", answer: "3", via: .text, chips: [], thread: "t2", continuing: nil, at: at(30))
        #expect(a == b && c != a)
        #expect(log.sessions.map(\.id) == [c, a])                          // newest first
        #expect(log.sessions[1].turns.count == 4 && log.sessions[1].lastActive == at(5))
        #expect(log.session(forThread: "t1")?.id == a)
    }

    @Test func anOldChatContinuedOnAFreshThreadGrowsInPlace() {
        var log = ChatLog()
        let old = log.record(question: "про отпуск", answer: "ок", via: .text, chips: [], thread: "t1", continuing: nil, at: t0)
        _ = log.record(question: "другое", answer: "ок", via: .voice, chips: [], thread: "t2", continuing: nil, at: at(60))
        let again = log.record(question: "так что с отпуском?", answer: "Помню", via: .text, chips: [], thread: "t3",
                               continuing: old, at: at(120))
        let more = log.record(question: "ещё", answer: "да", via: .text, chips: [], thread: "t3", continuing: nil, at: at(121))
        #expect(again == old && more == old)
        #expect(log.sessions.count == 2 && log.sessions[0].id == old)
        #expect(log.sessions[0].turns.count == 6)
    }

    @Test func aContinuedChatThatWasDeletedMeanwhileStartsANewOne() {
        var log = ChatLog()
        let old = log.record(question: "a", answer: "b", via: .text, chips: [], thread: "t1", continuing: nil, at: t0)
        log.delete(old)
        let id = log.record(question: "c", answer: "d", via: .text, chips: [], thread: "t2", continuing: old, at: at(1))
        #expect(id != old && log.sessions.count == 1)
        // A deleted chat's thread does not bring it back either.
        let next = log.record(question: "e", answer: "f", via: .text, chips: [], thread: "t1", continuing: nil, at: at(2))
        #expect(next != old && log.sessions.count == 2)
    }

    @Test func inactiveChatsGoAfterTheChosenDays() {
        var log = ChatLog()
        _ = log.record(question: "старый", answer: "x", via: .text, chips: [], thread: "t1", continuing: nil, at: t0)
        _ = log.record(question: "свежий", answer: "y", via: .text, chips: [], thread: "t2", continuing: nil, at: at(2 * 24 * 60))
        #expect(log.autoDeleteDays == 7)
        #expect(log.purge(now: at(8 * 24 * 60)) == 1)
        #expect(log.sessions.map(\.title) == ["свежий"])
        log.autoDeleteDays = nil                                           // «не удалять»
        #expect(log.purge(now: at(365 * 24 * 60)) == 0)
    }

    @Test func theSeedIsTheLastTurnsAsPlainText() {
        var log = ChatLog()
        var id: UUID?
        for i in 1...12 {
            id = log.record(question: "вопрос \(i)", answer: i == 12 ? String(repeating: "я", count: 600) : "ответ \(i)",
                            via: .text, chips: [ChatChip(kind: .webSearch)], thread: "t1", continuing: nil, at: at(Double(i)))
        }
        let seed = log.seed(for: id!)
        let lines = seed.split(separator: "\n").map(String.init)
        #expect(lines.first == "[переписка ранее]" && lines.last == "[конец переписки]")
        #expect(lines.count == 22)                                         // 20 turns + 2 markers
        #expect(lines[1] == "Пользователь: вопрос 3")
        #expect(lines[20].hasPrefix("Чилк: ") && lines[20].count == "Чилк: ".count + 501)   // 500 + «…»
        #expect(!seed.contains("Искал"))                                   // chips stay out
    }

    @Test func titlesAreShortAndNewlinesAreFolded() {
        var log = ChatLog()
        _ = log.record(question: "Очень длинный вопрос\nпро то, как правильно заваривать зелёный чай дома", answer: "x",
                       via: .text, chips: [], thread: "t", continuing: nil, at: t0)
        let title = log.sessions[0].title
        #expect(title.count == 41 && title.hasSuffix("…") && !title.contains("\n"))
    }

    @Test func theThreadMapIsNotSaved() throws {
        var log = ChatLog()
        let a = log.record(question: "a", answer: "b", via: .voice, chips: [], thread: "t1", continuing: nil, at: t0)
        var back = try JSONDecoder().decode(ChatLog.self, from: JSONEncoder().encode(log))
        #expect(back.sessions == log.sessions && back.autoDeleteDays == 7)
        // Threads are ephemeral: after a restart the same id is a new thread, so a new chat.
        let b = back.record(question: "c", answer: "d", via: .voice, chips: [], thread: "t1", continuing: nil, at: at(1))
        #expect(b != a)
    }

    @Test func whereATypedQuestionGoes() {
        var log = ChatLog()
        let old = log.record(question: "про Эльбрус", answer: "ок", via: .text, chips: [], thread: "t1", continuing: nil, at: t0)
        let live = log.record(question: "сейчас", answer: "ок", via: .voice, chips: [], thread: "t2", continuing: nil, at: at(60))
        // The live chat picked: the live thread goes on; the seed is there only if that thread ran out meanwhile.
        let same = log.plan(picked: live, liveThread: "t2")
        #expect(!same.fresh && same.continuing == live && same.seed?.contains("сейчас") == true)
        // An old chat picked: a clean thread that hears it first.
        let back = log.plan(picked: old, liveThread: "t2")
        #expect(back.fresh && back.continuing == old && back.seed?.contains("про Эльбрус") == true)
        // Nothing picked: the shared thread decides (15 minutes); no seed.
        let none = log.plan(picked: nil, liveThread: "t2")
        #expect(!none.fresh && none.continuing == nil && none.seed == nil)
        // The live thread ran out: the picked chat is continued on a clean thread.
        let expired = log.plan(picked: live, liveThread: nil)
        #expect(expired.fresh && expired.continuing == live)
    }

    @Test func aTypedQuestionSaysItIsFromTheChat() {
        let voice = VoiceContext.text(sittingMinutes: 5, now: t0, zone: TimeZone(identifier: "Europe/Moscow")!)
        let chat = VoiceContext.chat(voice)
        #expect(chat.hasSuffix("; написано в чате]\n") && chat.hasPrefix("[контекст: сейчас"))
        #expect(VoiceContext.chat("") == "[написано в чате]\n")
    }
}

@Suite("Memory")
struct MemoryBookTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aFactIsCleanedAndMarkedWhoRememberedIt() {
        var book = MemoryBook()
        guard case .added(let id) = book.remember("  пьёт чай\n без   сахара ", selfNoted: true, now: now) else {
            Issue.record("not added"); return
        }
        #expect(book.facts == [MemoryFact(id: id, text: "пьёт чай без сахара", selfNoted: true, added: now)])
    }

    @Test func duplicatesEmptyAndTooLongAreNotAdded() {
        var book = MemoryBook()
        _ = book.remember("Зовут кота Барсик", selfNoted: false, now: now)
        #expect(book.remember("зовут  кота барсик", selfNoted: true, now: now) == .duplicate)
        #expect(book.remember("   ", selfNoted: false, now: now) == .empty)
        #expect(book.remember(String(repeating: "а", count: 201), selfNoted: false, now: now) == .tooLong)
        #expect(book.facts.count == 1)
    }

    @Test func fiftyFactsAtMost() {
        var book = MemoryBook()
        for i in 0..<MemoryBook.limit { _ = book.remember("факт \(i)", selfNoted: false, now: now) }
        #expect(book.facts.count == 50)
        #expect(book.remember("ещё один", selfNoted: false, now: now) == .full)
    }

    @Test func secretsAreRefused() {
        var book = MemoryBook()
        for secret in ["мой пароль от почты qwerty", "Password: hunter2", "карта 1234 5678 9012 3456", "ключ sk-abc123def",
                       "API key у него в заметках", "пин-код 4512", "токен бота 123:ABC", "PIN: 1234", "пин 0000",
                       "паспорт 1234 567890", "СНИЛС 123-456-789 00", "ИНН 7701234567", "код из смс 5521",
                       "код домофона 1234"] {
            #expect(book.remember(secret, selfNoted: false, now: now) == .looksSecret, "\(secret)")
        }
        // A phone number (11 digits) and ordinary facts with numbers or «код» in another sense are fine.
        guard case .added = book.remember("телефон мамы +7 999 123-45-67", selfNoted: false, now: now) else {
            Issue.record("phone refused"); return
        }
        guard case .added = book.remember("бегает по 5 км утром", selfNoted: false, now: now) else {
            Issue.record("number refused"); return
        }
        guard case .added = book.remember("пишет код на Swift", selfNoted: false, now: now),
              case .added = book.remember("любит спиннинг", selfNoted: false, now: now) else {
            Issue.record("ordinary words refused"); return
        }
    }

    @Test func editAndForget() {
        var book = MemoryBook()
        guard case .added(let a) = book.remember("любит кофе", selfNoted: true, now: now),
              case .added(let b) = book.remember("живёт в Казани", selfNoted: false, now: now) else { Issue.record("setup"); return }
        #expect(book.edit(a, to: "живёт в казани") == .duplicate)          // would duplicate another fact
        #expect(book.edit(a, to: "любит кофе с молоком") == .added(a))
        #expect(book.facts.first { $0.id == a }?.text == "любит кофе с молоком")
        #expect(book.facts.first { $0.id == a }?.selfNoted == false)        // the user wrote it now
        book.forget(b)
        #expect(book.facts.map(\.id) == [a])
    }

    @Test func instructionsListTheFactsOrNothing() {
        var book = MemoryBook()
        #expect(book.instructions == nil)
        _ = book.remember("пьёт чай без сахара", selfNoted: false, now: now)
        _ = book.remember("зовут кота Барсик", selfNoted: true, now: now)
        let text = book.instructions ?? ""
        #expect(text.contains("[память]"))
        #expect(text.contains("- пьёт чай без сахара\n- зовут кота Барсик"))
    }
}
