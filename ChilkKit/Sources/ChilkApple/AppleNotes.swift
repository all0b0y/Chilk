import ChilkBrain
import Foundation

/// Apple Notes through AppleScript (SPEC «Срез 8», decision 10). Notes has no framework API; `/usr/bin/osascript` runs
/// the script below off the main thread, so a slow Notes never stops the character, and a stuck run is killed (90 s: the
/// first call waits while macOS asks whether Chilk may control Notes). Chilk keeps itself to its own «Чилк» folder: the
/// script reads only that folder and, before a change or deletion, checks that the note lives there. The user's text
/// travels only as arguments, never inside the script source.
public actor AppleNotes: NotesStore {
    public typealias Runner = @Sendable ([String]) async -> ClockShortcut.Run
    private let runner: Runner
    /// A defaults domain for tests (nil: the app's own). `UserDefaults` itself is not Sendable, so the actor opens it.
    private let suite: String?
    private var defaults: UserDefaults { suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }
    static let folderKey = "notesFolderID"
    /// The last answer macOS gave about controlling Notes ("granted" / "denied"), for Settings → Permissions: macOS
    /// tells it directly only while Notes runs.
    public static let automationKey = "notesAutomation"

    public init(suite: String? = nil, runner: Runner? = nil) {
        self.suite = suite
        self.runner = runner ?? { await ClockShortcut.run(executable: "/usr/bin/osascript", $0, timeout: 90) }
    }

    public func add(title: String, text: String) async throws -> NoteInfo {
        try Self.first(await call("add", [Self.html(title: title, text: text)]))
    }

    public func notes() async throws -> [NoteInfo] { try await call("list", []) }

    public func note(id: String) async throws -> NoteInfo { try Self.first(await call("read", [id])) }

    public func append(id: String, text: String) async throws -> NoteInfo {
        try Self.first(await call("append", [id, Self.html(lines: text)]))
    }

    public func rewrite(id: String, title: String, text: String) async throws -> NoteInfo {
        try Self.first(await call("rewrite", [id, Self.html(title: title, text: text)]))
    }

    public func delete(id: String) async throws { _ = try await call("delete", [id]) }

    private static func first(_ rows: [NoteInfo]) throws -> NoteInfo {
        guard let row = rows.first else { throw NotesAccessError.notFound }
        return row
    }

    /// One osascript run: `op`, the remembered folder id, then the op's own arguments.
    private func call(_ op: String, _ args: [String]) async throws -> [NoteInfo] {
        let remembered = defaults.string(forKey: Self.folderKey) ?? ""
        let run = await runner(["-e", Self.script, op, remembered] + args)
        if run.status != 0 {
            let failure = Self.failure(run)
            switch failure as? NotesAccessError {
            case .denied?: defaults.set("denied", forKey: Self.automationKey)
            case .timeout?, nil: break
            case .some: defaults.set("granted", forKey: Self.automationKey)        // the script ran: Notes answered
            }
            throw failure
        }
        defaults.set("granted", forKey: Self.automationKey)
        let reply = Self.parse(run.output)
        if let folder = reply.folder, !folder.isEmpty, folder != remembered { defaults.set(folder, forKey: Self.folderKey) }
        return reply.notes
    }

    /// osascript itself failed (no AppleScript error number).
    struct ScriptFailure: Error {}

    /// osascript ends a failed run with the error number in brackets: «… execution error: … (-1743)». A run killed
    /// after 90 s may have written already: that is `timeout`, never «nothing changed».
    static func failure(_ run: ClockShortcut.Run) -> any Error {
        guard run.status != ClockShortcut.timedOut else { return NotesAccessError.timeout }
        let code = run.error.range(of: #"\((-?[0-9]+)\)\s*$"#, options: .regularExpression)
            .flatMap { Int(run.error[$0].dropFirst().prefix { $0 != ")" }) }
        switch code {
        case -1743, -1744: return NotesAccessError.denied     // not permitted / would need a consent it cannot ask for
        case 1001, -1728: return NotesAccessError.notFound
        case 1002: return NotesAccessError.locked
        case 1003: return NotesAccessError.unavailable
        case 1004: return NotesAccessError.rich
        case let code?: return NotesAccessError.script(code)
        case nil: return ScriptFailure()
        }
    }

    /// The script's answer: the folder's id, then one record per note (U+001E between records, U+001F between fields:
    /// id, name, locked, rich, modified, plain text — the script removes those two characters from names and texts).
    /// An absent folder answers nothing.
    static func parse(_ output: String) -> (folder: String?, notes: [NoteInfo]) {
        let text = output.hasSuffix("\n") ? String(output.dropLast()) : output
        guard !text.isEmpty else { return (nil, []) }
        let records = text.split(separator: "\u{1E}", omittingEmptySubsequences: false)
        return (String(records[0]), records.dropFirst().compactMap(row))
    }

    static func row(_ record: Substring) -> NoteInfo? {
        let f = record.split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 6, !f[0].isEmpty else { return nil }
        let modified = stamp(f[4]) ?? Date(timeIntervalSince1970: 0)
        let title = f[1].trimmingCharacters(in: .whitespaces)
        var body = f[5].replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // The plain text starts with the title line.
        if let nl = body.firstIndex(of: "\n") {
            if body[..<nl].trimmingCharacters(in: .whitespaces) == title { body = String(body[body.index(after: nl)...]) }
        } else if body.trimmingCharacters(in: .whitespaces) == title {
            body = ""
        }
        return NoteInfo(id: f[0], title: title, text: body.trimmingCharacters(in: .whitespacesAndNewlines), modified: modified,
                        locked: f[2] == "true", rich: f[3] == "true")
    }

    /// «2026-10-8-39780»: AppleScript's year, month, day and seconds since midnight — local wall-clock time.
    static func stamp(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3] / 3600,
                                                          minute: p[3] % 3600 / 60, second: p[3] % 60))
    }

    /// The note's HTML: the title as the heading line, then the text line by line (an empty line kept).
    static func html(title: String, text: String) -> String {
        "<div><h1>\(escape(title))</h1></div>" + html(lines: text)
    }

    static func html(lines text: String) -> String {
        guard !text.isEmpty else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = escape(String(line))
            return s.isEmpty ? "<div><br></div>" : "<div>\(s)</div>"
        }.joined()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// argv: op (list / read / add / append / rewrite / delete), the remembered folder id, then the note id and/or the
    /// HTML. Own errors: 1001 not in the folder, 1002 locked, 1003 no folder could be made, 1004 rich content. The folder
    /// lives only in Notes' default account (where a deleted note goes to «Recently Deleted»): a folder named exactly
    /// «Чилк», at the top of the account, not shared; a remembered id is checked the same way. Every write reads the
    /// body back first and refuses pictures, files, lists or tables — Notes would lose or flatten them.
    static let script = #"""
    on run argv
    	set op to item 1 of argv
    	set RS to character id 30
    	tell application "Notes"
    		set chilk to my chilkFolder(item 2 of argv, op is "add")
    		if chilk is missing value then return ""
    		set answerText to (id of chilk) as text
    		if op is "list" then
    			repeat with n in (notes of chilk)
    				set answerText to answerText & RS & my noteRow(contents of n, 300)
    			end repeat
    		else if op is "read" then
    			set answerText to answerText & RS & my noteRow(my ownNote(chilk, item 3 of argv), 0)
    		else if op is "add" then
    			set n to make new note at chilk with properties {body:item 3 of argv}
    			set answerText to answerText & RS & my noteRow(n, 0)
    		else if op is "append" or op is "rewrite" or op is "delete" then
    			set n to my ownNote(chilk, item 3 of argv)
    			if password protected of n then error "locked" number 1002
    			if op is "delete" then
    				delete n
    			else
    				if my isRich(n) then error "rich" number 1004
    				if op is "append" then
    					set body of n to (body of n) & (item 4 of argv)
    				else
    					set body of n to item 4 of argv
    				end if
    				set answerText to answerText & RS & my noteRow(n, 0)
    			end if
    		else
    			error "unknown operation" number 1099
    		end if
    		return answerText
    	end tell
    end run

    on chilkFolder(remembered, makeIt)
    	tell application "Notes"
    		if remembered is not "" then
    			try
    				set f to folder id remembered
    				if my isChilk(f) then return f
    			end try
    		end if
    		set acc to default account
    		repeat with f in (folders of acc)
    			if my isChilk(contents of f) then return (contents of f)
    		end repeat
    		if not makeIt then return missing value
    		try
    			return make new folder at acc with properties {name:"Чилк"}
    		on error
    			error "no folder" number 1003
    		end try
    	end tell
    end chilkFolder

    on isChilk(f)
    	tell application "Notes"
    		considering case
    			if (name of f) is not "Чилк" then return false
    		end considering
    		if shared of f then return false
    		return (class of (container of f)) is account
    	end tell
    end isChilk

    on ownNote(chilk, noteID)
    	tell application "Notes"
    		try
    			set n to note id noteID
    			set homeID to id of (container of n)
    		on error
    			error "not found" number 1001
    		end try
    		if homeID is not (id of chilk) then error "not found" number 1001
    		return n
    	end tell
    end ownNote

    on isRich(n)
    	tell application "Notes"
    		if (count of attachments of n) > 0 then return true
    		set noteHTML to body of n
    	end tell
    	repeat with marker in {"<ul", "<ol", "<table", "<img", "<object"}
    		if noteHTML contains (contents of marker) then return true
    	end repeat
    	return false
    end isRich

    on clean(t)
    	set saved to AppleScript's text item delimiters
    	set AppleScript's text item delimiters to {character id 30, character id 31}
    	set pieces to text items of t
    	set AppleScript's text item delimiters to " "
    	set t to pieces as text
    	set AppleScript's text item delimiters to saved
    	return t
    end clean

    on noteRow(n, maxLength)
    	tell application "Notes"
    		set US to character id 31
    		set noteName to ""
    		set isLocked to false
    		set noteText to ""
    		set stampText to ""
    		set richNote to false
    		try
    			set noteName to name of n
    		end try
    		try
    			set isLocked to password protected of n
    		end try
    		if not isLocked then
    			try
    				set noteText to plaintext of n
    			end try
    		end if
    		if maxLength > 0 and (length of noteText) > maxLength then set noteText to text 1 thru maxLength of noteText
    		try
    			set d to modification date of n
    			set stampText to ((year of d) as text) & "-" & (((month of d) as integer) as text) & "-" & ((day of d) as text) & "-" & ((time of d) as text)
    		end try
    		try
    			if maxLength > 0 then
    				set richNote to ((count of attachments of n) > 0)
    			else if not isLocked then
    				set richNote to my isRich(n)
    			end if
    		end try
    		return (id of n) & US & my clean(noteName) & US & (isLocked as text) & US & (richNote as text) & US & stampText & US & my clean(noteText)
    	end tell
    end noteRow
    """#
}
