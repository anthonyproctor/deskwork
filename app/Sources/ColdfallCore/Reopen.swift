// Coming back to a big conversation.
//
// Every message re-sends the whole conversation. What keeps that cheap is the
// cache: sent again within a few minutes, it is read back at a tenth of the
// price. After a break the cache has expired, and the first message rebuilds
// it at a quarter MORE than normal price, on all of it. For a desk whose
// conversation is 600K tokens, that first message after lunch is the most
// expensive thing it does all day. Stopping the desk is not what causes it;
// the break is.
//
// Resuming stays the default, always: the conversation coming back whole is
// what makes a desk feel like it remembers, and an accidental close must not
// cost anyone their context. What this adds is a choice, offered only for a
// big conversation that has sat for a while, with the trade said plainly:
// what a fresh start keeps, what it drops, and that the old conversation is
// kept and can be reopened.

import Foundation

/// A desk's current conversation, as far as the transcript on disk says.
public struct ConversationInfo: Equatable {
    public let path: String
    /// What the last turn sent: the size the next message will re-send.
    public let tokens: Int
    public let lastUsed: Date
    public init(path: String, tokens: Int, lastUsed: Date) {
        self.path = path; self.tokens = tokens; self.lastUsed = lastUsed
    }
}

public enum Reopen {

    /// Big enough that rebuilding its cache is a real cost.
    public static let bigTokens = 150_000
    /// Long enough that the cache has certainly gone, and the topic may have
    /// too. The cache goes after minutes; asking every few minutes would be a
    /// nag, so this waits an hour.
    public static let staleAfter: TimeInterval = 3600

    /// The title a desk's conversation carries: `conversation` when set (a
    /// wrapper script that maps names, like `desk cpa` resuming "money"),
    /// otherwise the desk's own name.
    public static func title(of desk: Desk) -> String { desk.conversation ?? desk.name }

    /// Find the desk's Claude conversation and read how big it is. Nil for
    /// other runtimes, or when there is no conversation yet.
    public static func claude(_ desk: Desk, root: String = Resume.claudeProjectsRoot) -> ConversationInfo? {
        guard desk.runtime == "claude" else { return nil }
        let root = desk.claudeAccount()?.projectsRoot() ?? root
        let id: String?
        if let s = desk.session, Resume.claudeTranscriptExists(s, cwd: desk.resolvedCwd, root: root) {
            id = s
        } else {
            id = Resume.claudeSession(named: title(of: desk), cwd: desk.resolvedCwd, root: root)
        }
        guard let id else { return nil }
        let path = (Resume.claudeProjectDir(for: desk.resolvedCwd, root: root) as NSString)
            .appendingPathComponent(id + ".jsonl")
        guard let tokens = lastContext(path),
              let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        return ConversationInfo(path: path, tokens: tokens, lastUsed: m)
    }

    /// The size of the last turn in a transcript: fresh input plus what was
    /// read from and written to cache. Read from the END of the file, since a
    /// long conversation's transcript runs to tens of megabytes and only its
    /// last turn matters here.
    public static func lastContext(_ path: String, tail: Int = 512 * 1024) -> Int? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"usage\""), let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = o["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { continue }
            let n = (u["input_tokens"] as? Int ?? 0)
                  + (u["cache_read_input_tokens"] as? Int ?? 0)
                  + (u["cache_creation_input_tokens"] as? Int ?? 0)
            if n > 0 { return n }
        }
        return nil
    }

    /// Whether to offer a fresh start at all.
    public static func shouldAsk(_ c: ConversationInfo, now: Date = Date()) -> Bool {
        c.tokens >= bigTokens && now.timeIntervalSince(c.lastUsed) >= staleAfter
    }

    /// "3 days ago", "5 hours ago".
    public static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s >= 86_400 * 2 { return "\(s / 86_400) days ago" }
        if s >= 86_400 { return "yesterday" }
        if s >= 7200 { return "\(s / 3600) hours ago" }
        if s >= 3600 { return "an hour ago" }
        return "\(max(1, s / 60)) minutes ago"
    }

    public static func short(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : "\(n / 1000)K"
    }

    /// How to get the old conversation back, in the vendor's own terms.
    public static func howToGoBack(_ runtime: String) -> String {
        switch runtime {
        case "codex": return "run codex resume in the desk and pick it"
        default:      return "type /resume in the desk and pick it"
        }
    }

    /// The question, with the trade said plainly.
    public static func question(desk: Desk, _ c: ConversationInfo, now: Date = Date())
    -> (title: String, body: String) {
        ("Resume \(desk.name)'s conversation?",
         "It's about \(short(c.tokens)) tokens and was last used \(ago(c.lastUsed, now: now)). "
         + "Your first message will send all of it again, at more than the usual price, "
         + "because it has been out of the cache for a while.\n\n"
         + "Resume picks up exactly where you left off.\n\n"
         + "Start Fresh opens an empty conversation. The desk keeps its name, folder, "
         + "instructions and memory files, and anything it saved to them. What was only said "
         + "in the chat won't be in its head.\n\n"
         + "Nothing is deleted. To go back to the old conversation, \(howToGoBack(desk.runtime)).")
    }

    /// One line for the Stop Desk dialog.
    public static func stopNote(_ c: ConversationInfo) -> String {
        "Its conversation is about \(short(c.tokens)) tokens. After a break, the first message "
        + "re-sends all of it once, whether or not the desk was stopped."
    }
}

extension Desk {
    /// How to start this desk with a new conversation, or nil when Coldfall
    /// can't: a desk running its own script says how in `fresh`.
    public func freshCommand() -> String? {
        if let c = command, !c.isEmpty { return fresh }
        switch runtime {
        case "claude", "codex", "antigravity": return launchCommand()
        default: return nil
        }
    }
}
