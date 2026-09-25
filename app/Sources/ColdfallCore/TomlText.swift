import Foundation

/// Shared text handling for the small config parsers.
///
/// Both halves of this were bugs, found by a second agent reviewing the first
/// agent's tests. They are here rather than duplicated in four files because
/// that duplication is exactly how the same fault ended up in all of them.
public enum TomlText {

    /// Strip a trailing comment WITHOUT cutting inside a quoted string.
    ///
    /// The original stripped at the first `#` unconditionally, so
    /// `command = "git log --grep=#123"` silently became `git log --grep=`.
    /// A truncated command is worse than a rejected one: it runs, and does
    /// something else.
    public static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character? = nil
        var escaped = false
        for ch in line {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\", quote != nil { out.append(ch); escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                out.append(ch)
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; out.append(ch); continue }
            if ch == "#" { break }
            out.append(ch)
        }
        return out
    }

    /// Escape a value for a TOML basic string. Writing a command containing a
    /// quote produced a file that no longer parsed — silently corrupting the
    /// user's source of truth on the next save.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// Undo `escape` when reading a value back.
    /// Strip surrounding quotes, then unescape what is inside.
    ///
    /// Every TOML string value needs both steps and they were written out
    /// separately in two places. The theme parser did only the second, so
    /// `palette = "gruvbox"` parsed as the seven characters `"gruvbox"`,
    /// matched no known palette, and was silently ignored — a setting that had
    /// never once worked. One implementation, so that cannot happen again.
    public static func value(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return t }
        return unescape(String(t.dropFirst().dropLast()))
    }

    public static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            guard ch == "\\" else { out.append(ch); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            // \uXXXX and \UXXXXXXXX are valid TOML; "caf\u00e9" used to
            // read back as "cafu00e9" and be written that way on the next save.
            case let e? where e == "u" || e == "U":
                let want = (e == "u") ? 4 : 8
                var hex = ""
                while hex.count < want, let h = it.next() { hex.append(h) }
                if hex.count == want, let n = UInt32(hex, radix: 16), let sc = Unicode.Scalar(n) {
                    out.unicodeScalars.append(sc)
                } else {
                    out.append("\\"); out.append(hex)
                }
            case let other?: out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }

    /// The file as logical lines: comments stripped, whitespace and any CR
    /// trimmed, and an array that a person split across lines joined back
    /// into one. Before this, `mcp_off = [` on its own line read as an empty
    /// array and the next save wrote the setting away.
    public static func logicalLines(_ text: String) -> [String] {
        let raw = text.components(separatedBy: .newlines)
        var out: [String] = []
        var i = 0
        while i < raw.count {
            var line = stripComment(raw[i]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("["), !value.contains("]") {
                    var j = i + 1
                    while j < raw.count {
                        let more = stripComment(raw[j]).trimmingCharacters(in: .whitespacesAndNewlines)
                        line += " " + more
                        j += 1
                        if more.contains("]") { break }
                    }
                    i = j
                    out.append(line)
                    continue
                }
            }
            out.append(line)
            i += 1
        }
        return out
    }
}
