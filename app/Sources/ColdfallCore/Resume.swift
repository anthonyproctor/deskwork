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
//
// Antigravity: `agy --continue` picks up the most recent conversation. It
// lists each folder it has worked in in ~/.gemini/projects.json, so it is
// used only once the desk's folder is there.

import Foundation

public enum Resume {

    /// What starting `desk` again brings back, in a sentence for a dialog.
    /// Nil for a plain shell, where there is nothing to say.
    public static func afterRestart(_ desk: Desk) -> String? {
        if desk.resumesItself {
            return desk.runtime == "claude"
                ? "Starting it again picks up the same conversation. Anything it was in the middle of stops."
                : "Starting it again picks up its latest conversation in this folder. Anything it was in the middle of stops."
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

    /// Whether `needle` occurs at the start of a line.
    static func hasRecord(_ data: Data, _ needle: Data) -> Bool {
        var from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) {
            if r.lowerBound == data.startIndex || data[r.lowerBound - 1] == 0x0A { return true }
            from = r.upperBound
        }
        return false
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
        // The record itself, at the start of a line, not the same text
        // anywhere in a transcript: a session that merely read or was shown a
        // transcript would otherwise be resumed as that desk.
        let needle = Data("{\"type\":\"custom-title\",\"customTitle\":\"\(TomlText.escape(name))\"".utf8)
        // Newest first, stopping at the first match: a desk's own session is
        // usually the newest file, so most starts read one transcript.
        let dated = files.filter { $0.hasSuffix(".jsonl") }.map { f -> (String, Date) in
            let path = (dir as NSString).appendingPathComponent(f)
            return (f, ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (f, _) in dated {
            let path = (dir as NSString).appendingPathComponent(f)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
               hasRecord(data, needle) {
                return String(f.dropLast(".jsonl".count))
            }
        }
        return nil
    }

    /// Whether Claude still has conversation `id` for `cwd`.
    public static func claudeTranscriptExists(_ id: String, cwd: String, root: String = claudeProjectsRoot) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        let path = (claudeProjectDir(for: cwd, root: root) as NSString).appendingPathComponent(id + ".jsonl")
        return FileManager.default.fileExists(atPath: path)
    }

    public static var codexSessionsRoot: String {
        NSString(string: "~/.codex/sessions").expandingTildeInPath
    }

    /// Whether an interactive Codex session was started in `cwd`. Reads only
    /// each session file's first line, where Codex writes its metadata.
    public static var antigravityProjectsFile: String {
        NSString(string: "~/.gemini/projects.json").expandingTildeInPath
    }

    /// Whether Antigravity has worked in `cwd`, so there is a conversation
    /// for `--continue` to reopen.
    public static func antigravityHasProject(cwd: String, file: String = antigravityProjectsFile) -> Bool {
        guard let d = FileManager.default.contents(atPath: file),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = o["projects"] as? [String: Any] else { return false }
        let want = (cwd as NSString).standardizingPath
        return p.keys.contains { (NSString(string: $0).expandingTildeInPath as NSString).standardizingPath == want }
    }

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
