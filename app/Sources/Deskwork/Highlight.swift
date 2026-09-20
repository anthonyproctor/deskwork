import AppKit

/// Syntax highlighting, deliberately shallow.
///
/// A real parser (tree-sitter) is the right answer for an editor. This is a
/// reader: the job is to make a diff legible at a glance, not to be correct
/// about every edge of every grammar. Comments, strings, keywords and numbers
/// get you most of the readability for a fraction of the weight — and shallow
/// is honest here, because nothing downstream depends on it being exact.
enum Highlight {

    private static let common = [
        "if","else","for","while","return","break","continue","switch","case","default",
        "func","function","def","class","struct","enum","interface","protocol","extension",
        "let","var","const","static","public","private","internal","import","from","package",
        "try","catch","throw","throws","async","await","new","self","this","nil","null",
        "true","false","in","is","as","where","guard","defer","type","impl","fn","use","mut","pub",
    ]

    private static let byExt: [String: Set<String>] = [
        "swift": Set(common + ["init","deinit","some","any","inout","lazy","weak","unowned"]),
        "rs":    Set(common + ["trait","match","loop","move","crate","dyn","unsafe"]),
        "py":    Set(common + ["elif","lambda","with","yield","pass","raise","global","None","True","False"]),
        "js":    Set(common + ["export","typeof","instanceof","yield","undefined"]),
        "ts":    Set(common + ["export","typeof","instanceof","yield","undefined","readonly","namespace"]),
        "go":    Set(common + ["chan","defer","go","map","range","select","nil"]),
        "sh":    Set(["if","then","fi","else","elif","for","while","do","done","case","esac",
                      "function","local","export","return","echo","printf","set","source"]),
        "toml":  Set(["true","false"]),
        "json":  Set(["true","false","null"]),
    ]

    private static func lineComment(_ ext: String) -> String? {
        switch ext {
        case "py","sh","bash","zsh","toml","yml","yaml","rb","conf": return "#"
        case "swift","rs","js","ts","go","c","h","cpp","java","kt","m","mm": return "//"
        default: return nil
        }
    }

    /// Returns nil for anything not worth colouring, so the caller can fall
    /// back to plain text rather than pretend.
    static func attributed(_ text: String, ext: String, font: NSFont) -> NSAttributedString? {
        let e = ext.lowercased()
        guard byExt[e] != nil || lineComment(e) != nil else { return nil }
        let keywords = byExt[e] ?? []

        let out = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        func paint(_ pattern: String, _ colour: NSColor, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            re.enumerateMatches(in: text, range: all) { m, _, _ in
                if let r = m?.range { out.addAttribute(.foregroundColor, value: colour, range: r) }
            }
        }

        // Order matters: keywords first, then literals, then comments last so a
        // keyword inside a comment ends up comment-coloured rather than the
        // other way round.
        if !keywords.isEmpty {
            paint("\\b(" + keywords.joined(separator: "|") + ")\\b",
                  NSColor.systemPurple)
        }
        paint("\\b\\d[\\d_]*(\\.\\d+)?\\b", NSColor.systemTeal)
        paint("\"[^\"\\n]*\"|'[^'\\n]*'", NSColor.systemGreen)
        if let c = lineComment(e) {
            paint(NSRegularExpression.escapedPattern(for: c) + ".*$",
                  NSColor.secondaryLabelColor, options: [.anchorsMatchLines])
        }
        return out
    }
}
