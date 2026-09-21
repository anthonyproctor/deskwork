// Picking a desk's conversation back up.
//
// A desk is meant to be persistent: stop it, relaunch the app, and it should
// come back holding the same conversation. Desks that run their own command
// (a wrapper script) decide that for themselves. This is for the desks
// Coldfall launches itself, which used to start fresh every time.
//
// Claude: a desk starts its session with `-n <desk>`, which Claude records in
// the transcript as {"type":"custom-title","customTitle":"<desk>"}. The newest
// transcript carrying that title, in the project folder for the desk's
// directory, is the one to reopen, by its session id.
//
// Codex: sessions have no names, but `codex resume --last` picks the newest
// session started in the current directory. Used only when one exists there,
// so a first start is an ordinary `codex`.

import Foundation

public enum Resume {

    /// What starting `desk` again brings back, in a sentence for a dialog.
    /// Nil for a plain shell, where there is nothing to say.
    public static func afterRestart(_ desk: Desk) -> String? {
        if desk.resumesItself {
            return desk.runtime == "claude"
                ? "Starting it again picks up the same conversation. Anything it was in the middle of stops."
                : "Starting it again picks up its latest Codex conversation in this folder. Anything it was in the middle of stops."
        }
        if desk.runtime == "shell" { return nil }
        return "Starting it again runs its own command, which decides whether the conversation comes back."
    }

    /// Where Claude keeps a directory's transcripts. Every character that is
    /// not a letter, digit or `-` becomes `-`: `/srv/demo.app` is
    /// `-srv-demo-app`.
    public static func claudeProjectDir(for cwd: String, root: String) -> String {
        let key = String(cwd.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" ? Character($0) : "-"
        })
        return (root as NSString).appendingPathComponent(key)
    }

    public static var claudeProjectsRoot: String {
        NSString(string: "~/.claude/projects").expandingTildeInPath
    }

    /// The id of the newest Claude session titled `name` for `cwd`, or nil.
    public static func claudeSession(named name: String, cwd: String,
                                     root: String = claudeProjectsRoot) -> String? {
        let dir = claudeProjectDir(for: cwd, root: root)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let needle = Data("\"customTitle\":\"\(TomlText.escape(name))\"".utf8)
        // Newest first, stopping at the first match: a desk's own session is
        // usually the newest file, so most starts read one transcript.
        let dated = files.filter { $0.hasSuffix(".jsonl") }.map { f -> (String, Date) in
            let path = (dir as NSString).appendingPathComponent(f)
            return (f, ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (f, _) in dated {
            let path = (dir as NSString).appendingPathComponent(f)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), data.range(of: needle) != nil {
                return String(f.dropLast(".jsonl".count))
            }
        }
        return nil
    }

    public static var codexSessionsRoot: String {
        NSString(string: "~/.codex/sessions").expandingTildeInPath
    }

    /// Whether an interactive Codex session was started in `cwd`. Reads only
    /// each session file's first line, where Codex writes its metadata.
    public static func codexHasSession(cwd: String, root: String = codexSessionsRoot) -> Bool {
        guard let walk = FileManager.default.enumerator(atPath: root) else { return false }
        let wanted = Data("\"cwd\":\"\(TomlText.escape(cwd))\"".utf8)
        let tui = Data("\"originator\":\"codex-tui\"".utf8)
        let sub = Data("\"subagent\"".utf8)
        for case let rel as String in walk where rel.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(rel)
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            let head = h.readData(ofLength: 16_384)
            try? h.close()
            let line = head.firstIndex(of: 0x0A).map { head[..<$0] } ?? head
            if line.range(of: wanted) != nil, line.range(of: tui) != nil, line.range(of: sub) == nil {
                return true
            }
        }
        return false
    }
}
