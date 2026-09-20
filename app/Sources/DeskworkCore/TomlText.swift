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
            case let other?: out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }
}
