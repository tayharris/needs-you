import Foundation

// Notes (docs/API.md "Notes", ADR 0014): one markdown document the person keeps beside the
// alerts. The panel shows it as lines (headings, checkboxes, bullets, text) rendered with the
// card renderer; a checkbox click flips that one line and saves the whole document with the
// rev it was read at. Typing happens only in the separate NotesWindow.

public struct NotesDocument: Decodable, Equatable, Sendable {
    public var text: String
    /// "" while the hub has no notes yet; a `PUT` must send the rev it read.
    public var rev: String
    public var updatedAt: Date?

    public init(text: String = "", rev: String = "", updatedAt: Date? = nil) {
        self.text = text
        self.rev = rev
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case text, rev
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Bounded like the hub bounds it, and bidi controls gone (LimitedMarkdown's rule).
        let raw = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        text = LimitedMarkdown.stripBidiControls(String(raw.prefix(NotesText.maxLength)))
        rev = String(((try? c.decodeIfPresent(String.self, forKey: .rev)) ?? "")?.prefix(64) ?? "")
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
    }
}

/// One `GET /v1/notes` answer.
public enum NotesFetch: Equatable, Sendable {
    /// 304: the last fetch with this ETag still holds.
    case unchanged
    /// 404: a hub that predates notes.
    case unsupported
    case fresh(NotesDocument, etag: String?)
}

/// One `PUT /v1/notes` answer.
public enum NotesSave: Equatable, Sendable {
    case saved(NotesDocument)
    /// 409: the notes changed since they were read; read them again.
    case conflict
    /// Another refusal (`invalid`, `secret_in_text`, `rate_limited`, ...), with its message.
    case refused(code: String, message: String)
}

/// A feed that holds notes. HubClient, FailoverFeed and DemoFeed are.
public protocol NotesFeed: Sendable {
    func fetchNotes(etag: String?) async throws -> NotesFetch
    func saveNotes(text: String, baseRev: String) async throws -> NotesSave
}

extension HubClient: NotesFeed {
    public static func notesURL(base: URL) -> URL {
        base.appendingPathComponent("v1/notes")
    }

    public static func notesRequest(base: URL, token: String, etag: String?) -> URLRequest {
        var request = makeRequest(url: notesURL(base: base), method: "GET", token: token)
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    public static func saveNotesRequest(base: URL, token: String, text: String, baseRev: String) -> URLRequest {
        let body = try? JSONSerialization.data(withJSONObject: ["text": text, "base_rev": baseRev])
        return makeRequest(url: notesURL(base: base), method: "PUT", token: token, body: body)
    }

    /// The HTTP answer to a GET (pure, tested).
    public static func notesOutcome(status: Int, body: Data, etag: String?) throws -> NotesFetch {
        switch status {
        case 304: return .unchanged
        case 404: return .unsupported
        case 200..<300:
            guard let doc = try? HubJSON.makeDecoder().decode(NotesDocument.self, from: body) else {
                throw HubError.invalidResponse
            }
            return .fresh(doc, etag: etag)
        case 401, 403: throw HubError.unauthorized
        case 421: throw HubError.misdirected
        default: throw HubError.http(status: status)
        }
    }

    /// The HTTP answer to a PUT (pure, tested).
    public static func saveNotesOutcome(status: Int, body: Data) throws -> NotesSave {
        switch status {
        case 200..<300:
            guard let doc = try? HubJSON.makeDecoder().decode(NotesDocument.self, from: body) else {
                throw HubError.invalidResponse
            }
            return .saved(doc)
        case 409: return .conflict
        case 400, 413, 429:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = json?["error"] as? String ?? "http_\(status)"
            let message = OrcaWorktrees.clean(json?["message"] as? String ?? "", limit: 200)
            return .refused(code: code, message: message)
        case 401, 403: throw HubError.unauthorized
        case 421: throw HubError.misdirected
        default: throw HubError.http(status: status)
        }
    }

    public func fetchNotes(etag: String?) async throws -> NotesFetch {
        let request = Self.notesRequest(base: config.baseURL, token: config.token, etag: etag)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        return try Self.notesOutcome(status: http.statusCode, body: data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    public func saveNotes(text: String, baseRev: String) async throws -> NotesSave {
        let request = Self.saveNotesRequest(base: config.baseURL, token: config.token, text: text, baseRev: baseRev)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        return try Self.saveNotesOutcome(status: http.statusCode, body: data)
    }
}

/// The notes as the panel shows them, and the one edit the panel makes (a checkbox).
public enum NotesText {
    /// The hub's limit (MAX_NOTES_TEXT).
    public static let maxLength = 12_000

    public enum Line: Equatable, Sendable {
        case heading(level: Int, text: String)
        /// `index` is the line's number in the document, for `toggle`.
        case checkbox(index: Int, checked: Bool, text: String, indent: Int)
        case bullet(text: String, indent: Int)
        case text(String)
        case blank
    }

    /// The document as lines. Code fences show as plain text; nothing is ever a link unless
    /// LimitedMarkdown allows it when the line is drawn.
    public static func lines(_ doc: String) -> [Line] {
        var out: [Line] = []
        var fence = false
        for (i, raw) in doc.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence.toggle()
                continue
            }
            if fence {
                out.append(.text(raw))
                continue
            }
            if trimmed.isEmpty {
                if out.last != .blank && !out.isEmpty { out.append(.blank) }
                continue
            }
            let indent = indentLevel(raw)
            if let (checked, rest) = checkbox(trimmed) {
                out.append(.checkbox(index: i, checked: checked, text: rest, indent: indent))
            } else if let rest = bullet(trimmed) {
                out.append(.bullet(text: rest, indent: indent))
            } else if let (level, rest) = heading(trimmed) {
                out.append(.heading(level: level, text: rest))
            } else {
                out.append(.text(trimmed))
            }
        }
        if out.last == .blank { out.removeLast() }
        return out
    }

    /// Unticked checkboxes: the count beside "Notes".
    public static func openCount(_ doc: String) -> Int {
        lines(doc).reduce(0) { n, line in
            if case .checkbox(_, false, _, _) = line { return n + 1 }
            return n
        }
    }

    /// `doc` with the checkbox on line `index` flipped, or nil when that line isn't one (the
    /// text changed underneath). `expect` is the line's text as shown, so a click never ticks
    /// a different line after the notes moved.
    public static func toggle(_ doc: String, index: Int, expect: String) -> String? {
        var all = doc.components(separatedBy: "\n")
        guard all.indices.contains(index) else { return nil }
        let raw = all[index]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let (checked, rest) = checkbox(trimmed), rest == expect,
              let mark = raw.range(of: checked ? "[x]" : "[ ]", options: .caseInsensitive) else { return nil }
        all[index] = raw.replacingCharacters(in: mark, with: checked ? "[ ]" : "[x]")
        return all.joined(separator: "\n")
    }

    /// The first line of `doc` that is a checkbox with text `expect` and state `checked`, for
    /// redoing a click on a fresh copy after a conflict.
    public static func find(_ doc: String, expect: String, checked: Bool) -> Int? {
        for line in lines(doc) {
            if case let .checkbox(index, c, text, _) = line, c == checked, text == expect { return index }
        }
        return nil
    }

    private static func indentLevel(_ raw: String) -> Int {
        var spaces = 0
        for ch in raw {
            if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 4 } else { break }
        }
        return min(spaces / 2, 4)
    }

    private static func checkbox(_ s: String) -> (Bool, String)? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            let rest = s.dropFirst(2)
            for (box, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where rest.hasPrefix(box) {
                return (checked, String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces))
            }
            for (box, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where rest == box {
                return (checked, "")
            }
        }
        return nil
    }

    private static func bullet(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(2))
        }
        return nil
    }

    private static func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    /// What the hub would refuse in a whole document (checked before a save, so the window
    /// can say so); nil when it's fine. Token-shaped text is left to the hub's answer.
    public static func problem(_ doc: String) -> String? {
        if doc.count > maxLength { return "Notes are limited to \(maxLength) characters." }
        for s in doc.unicodeScalars {
            let v = s.value
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || v == 0x7F || (0x80...0x9F).contains(v)
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x2028 || v == 0x2029 {
                return "The notes contain a control character the hub refuses."
            }
        }
        return nil
    }
}
