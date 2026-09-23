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

    /// Whether a big conversation has sat long enough to be worth a word.
    public static func shouldAsk(_ c: ConversationInfo, now: Date = Date()) -> Bool {
        c.tokens >= bigTokens && now.timeIntervalSince(c.lastUsed) >= staleAfter
    }

    /// Whether to ask at all when this desk opens. A desk wrapped up on its
    /// way out is always asked, whatever its size: that is what wrapping up
    /// was for. Otherwise only a big idle one, and never when the person has
    /// said not to, for this desk or for every desk.
    public static func shouldAsk(desk: Desk, _ c: ConversationInfo?, wrapped: Bool,
                                 enabled: Bool, now: Date = Date()) -> Bool {
        guard enabled, !desk.alwaysResume, desk.freshCommand() != nil else { return false }
        if wrapped { return true }
        guard let c else { return false }
        return shouldAsk(c, now: now)
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

    /// How to get an older conversation back, in the vendor's own terms.
    public static func howToGoBack(_ runtime: String) -> String {
        switch runtime {
        case "codex": return "run codex resume in the desk and pick it"
        default:      return "type /resume in the desk and pick it"
        }
    }

    public struct Question: Equatable {
        public let title: String
        public let body: String
        /// Which button Return presses. Resume, unless the desk was wrapped
        /// up on its way out: then a clean start is what was asked for.
        public let freshIsDefault: Bool
    }

    /// Opening a desk. Leads with what resuming does, so the choice reads as
    /// an option and not a warning.
    public static func question(desk: Desk, _ c: ConversationInfo?, wrappedAt: Date?,
                                now: Date = Date()) -> Question {
        let back = "Nothing is deleted either way: to reopen an older conversation, \(howToGoBack(desk.runtime))."
        if let w = wrappedAt {
            return Question(
                title: "Start \(desk.name) fresh?",
                body: "You wrapped \(desk.name) up \(ago(w, now: now)), so what was worth keeping is in its notes.\n\n"
                    + "Start Fresh opens a clean conversation: same desk, same folder, instructions and memory files. "
                    + "Pick Up Where I Left Off reloads the whole previous conversation"
                    + (c.map { " (about \(short($0.tokens)) tokens)" } ?? "") + ".\n\n" + back,
                freshIsDefault: true)
        }
        let size = c.map { "about \(short($0.tokens)) tokens" } ?? "large"
        let when = c.map { ", last used \(ago($0.lastUsed, now: now))" } ?? ""
        return Question(
            title: "Pick up where you left off in \(desk.name)?",
            body: "\(desk.name) will pick up this conversation right where it was. It's \(size)\(when), "
                + "so your first message sends all of it once more, at a little over the usual price.\n\n"
                + "If the topic has moved on, you can start a clean conversation instead. The desk keeps its "
                + "name, folder, instructions and memory files; what was only said in the chat stays in the "
                + "old conversation.\n\n" + back,
            freshIsDefault: false)
    }

    /// Stopping a desk. Says first, plainly, that nothing is lost: stopping
    /// and opening a desk brings its conversation back, and that is still the
    /// default. Wrapping up is offered as finishing a topic, not as a rescue.
    public static func stopBody(desk: Desk, memory: String?, _ c: ConversationInfo?) -> String {
        var s = "Ends its processes" + (memory.map { " and frees about \($0)" } ?? "") + ". "
              + "When you open it again, it picks up this conversation right where you left off."
        if let c, c.tokens >= bigTokens {
            s += "\n\nDone with this topic? Wrap Up first: \(desk.name) saves what's worth keeping to its "
               + "notes, so next time you can start clean instead of reloading about \(short(c.tokens)) tokens."
        }
        return s
    }

    /// Whether Stop offers Wrap Up at all: only where it would matter, and
    /// only where Coldfall can actually start the desk fresh afterwards.
    public static func offersWrapUp(desk: Desk, _ c: ConversationInfo?) -> Bool {
        guard desk.runtime == "claude", desk.freshCommand() != nil, let c else { return false }
        return c.tokens >= bigTokens
    }

    /// What Wrap Up types into the desk. Worded to use whatever memory the
    /// desk already keeps, rather than inventing a file of Coldfall's own.
    public static let wrapUpPrompt =
        "We're wrapping up this conversation. Save anything from it that's worth keeping to your "
      + "memory or notes, the way you normally would, so a fresh conversation can pick it up. "
      + "Then reply with one short line saying what you saved."
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
