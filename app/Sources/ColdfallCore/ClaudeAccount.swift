// A second Claude login, and a third.
//
// Claude Code keeps everything that makes an account yours (its login,
// settings, conversations) in one folder, ~/.claude, and reads another
// folder instead when CLAUDE_CONFIG_DIR names one. So a desk with
//
//     account = "~/.claude-second"
//
// runs on whichever account signed in there. The first start asks for a
// login; after that the desk stays on it. Everything Coldfall reads for a
// Claude desk (conversations to resume, servers, skills, usage, plan limits)
// is read from that desk's folder, and the account is named after the folder:
// ~/.claude-second is "claude-second" in the rail, the meter and agent mail.

import Foundation

public struct ClaudeAccount: Equatable {
    /// The folder, as written in desks.toml.
    public let folder: String
    /// "second" for ~/.claude-second.
    public let label: String

    public init?(folder: String, home: String = NSHomeDirectory()) {
        let path = ClaudeAccount.expand(folder, home: home)
        guard !folder.trimmingCharacters(in: .whitespaces).isEmpty,
              path != ClaudeAccount.expand("~/.claude", home: home) else { return nil }
        self.folder = folder
        self.label = ClaudeAccount.label(for: path)
    }

    /// The folder in full, with ~ expanded.
    public func path(home: String = NSHomeDirectory()) -> String { ClaudeAccount.expand(folder, home: home) }

    /// How it is named wherever vendors are: "claude-second".
    public var vendor: String { "claude-" + label }

    /// Where Claude keeps this account's conversations.
    public func projectsRoot(home: String = NSHomeDirectory()) -> String {
        (path(home: home) as NSString).appendingPathComponent("projects")
    }

    /// The part of the folder's name that tells accounts apart:
    /// ".claude-second" and "claude_second" are "second", "work" is "work".
    public static func label(for path: String) -> String {
        var name = (path as NSString).lastPathComponent.lowercased()
        while name.hasPrefix(".") { name.removeFirst() }
        for prefix in ["claude-", "claude_", "claude."] where name.hasPrefix(prefix) && name.count > prefix.count {
            name.removeFirst(prefix.count)
        }
        let kept = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return kept.isEmpty || kept == "claude" ? "other" : kept
    }

    static func expand(_ folder: String, home: String) -> String {
        let f = folder.trimmingCharacters(in: .whitespaces)
        let full = f == "~" ? home : f.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(f.dropFirst(2))) : f
        return (full as NSString).standardizingPath
    }

    /// The accounts desks use, besides the default one, each once.
    public static func used(by desks: [Desk], home: String = NSHomeDirectory()) -> [ClaudeAccount] {
        var out: [ClaudeAccount] = []
        for d in desks where d.runtime == "claude" {
            if let a = d.claudeAccount(home: home), !out.contains(where: { $0.path(home: home) == a.path(home: home) }) {
                out.append(a)
            }
        }
        return out
    }

    /// What desks.toml has now. For callers with no desk list in hand.
    public static func known() -> [ClaudeAccount] { used(by: DeskConfig.load()) }
}

extension Desk {
    /// The account a Claude desk runs on, when it isn't the default one.
    public func claudeAccount(home: String = NSHomeDirectory()) -> ClaudeAccount? {
        guard runtime == "claude", let a = account else { return nil }
        return ClaudeAccount(folder: a, home: home)
    }

    /// The runtime as the rail and the meter name it: "claude-second" for a
    /// desk on a second Claude account.
    public var vendorLabel: String { claudeAccount()?.vendor ?? runtime }
}
