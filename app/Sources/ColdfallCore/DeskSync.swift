// Keeping the running app and desks.toml in step when something else edits
// the file: another agent, a script, or a person in a text editor.
//
// Two things can go wrong. The rail can go stale: a desk renamed on disk
// still shows its old name until a relaunch. Worse, the app can clobber the
// edit: it saves from the list it loaded at launch, so saving anything in
// the app wrote the old desk back. The app now reloads when the file
// changes and never saves over a version it hasn't seen.

import Foundation

public enum DeskSync {

    /// The file as it is now, to tell "changed by someone else" from "what I
    /// wrote myself". Nil when it can't be read.
    public static func snapshot(_ path: String = DeskConfig.path) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Desks that were renamed between `old` and `new`, as old name -> new
    /// name, so a running desk keeps its terminal through a rename made on
    /// disk.
    ///
    /// A desk that vanished and one that appeared are the same desk when
    /// they run the same way from the same folder: the same runtime, cwd and
    /// agent, and the same command once the old name in it is read as the
    /// new one (`scripts/desk garage` -> `scripts/desk cars`). Only a pairing
    /// with exactly one candidate on each side counts; anything ambiguous is
    /// treated as a removal and an addition, which is the safe reading.
    public static func renames(from old: [Desk], to new: [Desk]) -> [String: String] {
        let oldNames = Set(old.map(\.name)), newNames = Set(new.map(\.name))
        let gone = old.filter { !newNames.contains($0.name) }
        let added = new.filter { !oldNames.contains($0.name) }
        func same(_ a: Desk, _ b: Desk) -> Bool {
            guard a.runtime == b.runtime, a.resolvedCwd == b.resolvedCwd, a.agent == b.agent else { return false }
            switch (a.command, b.command) {
            case (nil, nil): return true
            case let (x?, y?): return x == y || swapWord(x, a.name, b.name) == y
            default: return false
            }
        }
        var out: [String: String] = [:]
        for g in gone {
            let candidates = added.filter { same(g, $0) }
            guard candidates.count == 1, let a = candidates.first,
                  gone.filter({ same($0, a) }).count == 1 else { continue }
            out[g.name] = a.name
        }
        return out
    }

    /// `text` with `word` replaced by `with` wherever it stands as a whole
    /// word, so "desk garage" becomes "desk cars" but "garages" is left.
    public static func swapWord(_ text: String, _ word: String, _ with: String) -> String {
        guard !word.isEmpty else { return text }
        var out = "", i = text.startIndex
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }
        while i < text.endIndex {
            if text[i...].hasPrefix(word) {
                let end = text.index(i, offsetBy: word.count)
                let before = i == text.startIndex ? nil : text[text.index(before: i)]
                let after = end == text.endIndex ? nil : text[end]
                if !(before.map(isWordChar) ?? false), !(after.map(isWordChar) ?? false) {
                    out += with; i = end; continue
                }
            }
            out.append(text[i]); i = text.index(after: i)
        }
        return out
    }
}
