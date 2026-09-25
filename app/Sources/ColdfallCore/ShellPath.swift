// Putting a file path on a command line without breaking it.
//
// Dragging a file onto a desk inserts its path, which means the path has to
// survive a shell. Backslash escaping rather than quoting, because that is
// what dragging into Terminal.app produces and what the user will then edit
// the line against — a quoted path behaves differently the moment they type
// another argument after it.
//
// The escaped set is deliberately everything a shell can act on rather than
// just spaces. `report (final).pdf` is an ordinary filename and its
// parentheses are not ordinary to zsh; so are `&`, `;`, `$`, `*` and `?`.
// Allow-listing what is safe is the only version of this that stays correct
// when somebody names a file something nobody predicted.

import Foundation

public enum ShellPath {

    /// Characters that never need escaping in any shell this runs under.
    /// Everything else gets a backslash, including characters that happen to
    /// be harmless today.
    private static func isSafe(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || "._-/~".contains(ch)
    }

    public static func escape(_ path: String) -> String {
        var out = ""
        for ch in path {
            if isSafe(ch) { out.append(ch) } else { out.append("\\"); out.append(ch) }
        }
        return out
    }

    /// Several paths as one argument list, with a trailing space so a second
    /// drop cannot glue itself onto the last path.
    public static func line(_ paths: [String]) -> String {
        paths.isEmpty ? "" : paths.map(escape).joined(separator: " ") + " "
    }
}

/// One word for a shell command line, however it came in.
///
/// Launch commands are typed into a login shell, so anything read from
/// desks.toml (a desk's name, agent, model, runtime, folder) that reached it
/// unquoted could run as code: a desk named `x; rm -rf ~` would. Plain words
/// pass through as they are, so ordinary commands read as before; anything
/// else is single-quoted, with any single quote inside closed, escaped and
/// reopened. A newline inside single quotes is just a character.
public enum Shell {
    public static func quote(_ word: String) -> String {
        // A word starting with "=" is expanded by zsh (`=ls` -> /bin/ls).
        let safe = !word.isEmpty && !word.hasPrefix("=") && word.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || "@%+=:,./_-".unicodeScalars.contains($0)
        }
        if safe { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
