import Foundation

/// The panel's Orca strip: rows from `orca worktree ps --json` on this Mac and its paired
/// environments (`orca environment list`). Local only: nothing goes to a hub, nothing is
/// counted, nothing animates.
///
/// Everything in Orca's answer is untrusted text (a branch, a display name, a terminal
/// preview can hold anything). A row keeps only short, cleaned, one-line fields, and the
/// view draws them as plain text: never markdown, never a link. Unknown fields are ignored.
public struct OrcaWorktreeRow: Equatable, Sendable, Identifiable {
    /// The environment the row came from; nil for this Mac's Orca.
    public let environment: String?
    public let host: String
    public let name: String
    public let branch: String
    public let workspaceStatus: String
    public let status: String
    public let liveTerminals: Int
    public let unread: Bool
    public let lastActivity: Date?
    public let id: String

    public init(environment: String?, host: String, name: String, branch: String, workspaceStatus: String,
                status: String, liveTerminals: Int, unread: Bool, lastActivity: Date?, id: String) {
        self.environment = environment
        self.host = host
        self.name = name
        self.branch = branch
        self.workspaceStatus = workspaceStatus
        self.status = status
        self.liveTerminals = liveTerminals
        self.unread = unread
        self.lastActivity = lastActivity
        self.id = id
    }

    /// "in-progress · 2 terminals · unread", for the row's second line.
    public var detail: String {
        var bits: [String] = []
        if !workspaceStatus.isEmpty { bits.append(workspaceStatus) }
        bits.append(liveTerminals == 1 ? "1 terminal" : "\(liveTerminals) terminals")
        if unread { bits.append("unread") }
        if let environment { bits.append(environment) }
        return bits.joined(separator: " · ")
    }
}

public enum OrcaWorktrees {
    /// At most this many rows in the strip (most active first).
    public static let maxRows = 8
    /// How often the open panel refreshes the strip.
    public static let refreshInterval: TimeInterval = 45

    public static func psArguments(environment: String?) -> [String] {
        ["worktree", "ps", "--json"] + (environment.map { ["--environment", $0] } ?? [])
    }

    /// One line, no control, bidi or zero-width characters, at most `limit` characters.
    public static func clean(_ value: Any?, limit: Int) -> String {
        guard let s = value as? String else { return "" }
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let drop = v < 0x20 || (0x7f..<0xa0).contains(v) || (0x200b...0x200f).contains(v)
                || (0x202a...0x202e).contains(v) || (0x2060...0x2069).contains(v) || v == 0xfeff
            out.unicodeScalars.append(drop ? " " : scalar)
        }
        let collapsed = out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The rows in one `worktree ps --json` answer, archived ones left out; nil when it
    /// isn't an `"ok": true` answer.
    public static func parse(_ data: Data, environment: String?) -> [OrcaWorktreeRow]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true,
              let result = obj["result"] as? [String: Any]
        else { return nil }
        let list = result["worktrees"] as? [Any] ?? []
        var rows: [OrcaWorktreeRow] = []
        for (index, entry) in list.enumerated() {
            guard let w = entry as? [String: Any], w["isArchived"] as? Bool != true else { continue }
            let branch = clean(w["branch"], limit: 60)
            var name = clean(w["displayName"], limit: 40)
            if name.isEmpty { name = branch }
            let terminals = (w["liveTerminalCount"] as? NSNumber).flatMap { n -> Int? in
                CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : max(0, n.intValue)
            } ?? 0
            var last: Date?
            if let n = w["lastActivityAt"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue > 0 {
                let v = n.doubleValue
                last = Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)  // Orca uses epoch ms
            }
            let worktreeID = clean(w["worktreeId"], limit: 200)
            rows.append(OrcaWorktreeRow(
                environment: environment, host: clean(w["hostId"], limit: 30), name: name.isEmpty ? "?" : name,
                branch: branch, workspaceStatus: clean(w["workspaceStatus"], limit: 20),
                status: clean(w["status"], limit: 20), liveTerminals: terminals, unread: w["unread"] as? Bool == true,
                lastActivity: last,
                id: "\(environment ?? "")|\(worktreeID.isEmpty ? String(index) : worktreeID)"))
        }
        return rows
    }

    /// What the strip shows: live terminals first, then unread, then the most recent
    /// activity; at most `maxRows`.
    public static func visible(_ rows: [OrcaWorktreeRow]) -> [OrcaWorktreeRow] {
        let sorted = rows.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if (x.liveTerminals > 0) != (y.liveTerminals > 0) { return x.liveTerminals > 0 }
            if x.unread != y.unread { return x.unread }
            let tx = x.lastActivity ?? .distantPast, ty = y.lastActivity ?? .distantPast
            if tx != ty { return tx > ty }
            return a.offset < b.offset
        }
        return Array(sorted.map { $0.element }.prefix(maxRows))
    }

    /// The strip's header: "ORCA · 2 active of 7".
    public static func header(_ rows: [OrcaWorktreeRow]) -> String {
        let active = rows.filter { $0.liveTerminals > 0 }.count
        return active > 0 ? "ORCA · \(active) active of \(rows.count)" : "ORCA · \(rows.count)"
    }
}
