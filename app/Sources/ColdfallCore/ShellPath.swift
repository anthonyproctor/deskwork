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
