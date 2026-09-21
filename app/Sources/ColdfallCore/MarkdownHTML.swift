// Turning a markdown file into something a person can read.
//
// The reader used to show markdown as raw source in a terminal font: `#`
// before every heading, `**` around every bold word, and tables as wrapping
// rows of `|---|---|`. Reported, fairly, as looking like dogshit. A markdown
// file is prose meant to be rendered, and in a workspace full of agents most
// of what they write IS markdown — notes, plans, memory, READMEs.
//
// This is a deliberately small GFM subset, not a full CommonMark engine. It
// covers what agent-written markdown actually uses: headings, paragraphs,
// emphasis, inline and fenced code, lists, blockquotes, rules, links and —
// the one that mattered most — GFM tables. It lives in the core, not the view,
// because it is pure string work and belongs under test.
//
// Every piece of text is HTML-escaped before any markup is added. A markdown
// file can contain a literal <script>, and this renders files the user did not
// necessarily write — a cloned repo, an agent's output — so escaping is the
// security boundary, not a nicety. The view also disables JavaScript.

import Foundation

public enum MarkdownHTML {

    // MARK: - escaping

    public static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }

    // MARK: - inline

    /// Render inline markup inside one line or cell.
    ///
    /// Code spans are pulled out FIRST and held aside, so that `**` or `_`
    /// inside backticks stays literal — `a_b_c` in code must not become italic.
    public static func inline(_ raw: String) -> String {
        var codes: [String] = []
        var text = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "`" {
                // Match a run of backticks of the same length.
                var run = 0
                var j = i
                while j < raw.endIndex, raw[j] == "`" { run += 1; j = raw.index(after: j) }
                let fence = String(repeating: "`", count: run)
                if let close = raw.range(of: fence, range: j..<raw.endIndex) {
                    let body = String(raw[j..<close.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    codes.append("<code>\(escape(body))</code>")
                    text += "\u{0}C\(codes.count - 1)\u{0}"
                    i = close.upperBound
                    continue
                }
                text += fence
                i = j
                continue
            }
            text.append(raw[i])
            i = raw.index(after: i)
        }

        var s = escape(text)

        // Links: [text](url). The URL is escaped too; only http(s), mailto and
        // relative paths survive — a javascript: link is rendered as text.
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { m in
            let label = m[1], url = m[2]
            let lower = url.lowercased()
            let safe = lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("mailto:") || !lower.contains(":")
            return safe ? "<a href=\"\(url)\">\(label)</a>" : label
        }
        s = replace(s, #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"__([^_]+)__"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"~~([^~]+)~~"#) { "<del>\($0[1])</del>" }
        // Single-star/underscore emphasis, not touching word-internal
        // underscores like snake_case identifiers.
        s = replace(s, #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#) { "<em>\($0[1])</em>" }
        s = replace(s, #"(?<![\w])_([^_\n]+)_(?![\w])"#) { "<em>\($0[1])</em>" }

        // Restore code spans.
        for (n, c) in codes.enumerated() {
            s = s.replacingOccurrences(of: "\u{0}C\(n)\u{0}", with: c)
        }
        return s
    }

    private static func replace(_ s: String, _ pattern: String,
                                _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: - blocks

    public static func body(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var i = 0
        var para: [String] = []

        func flushPara() {
            guard !para.isEmpty else { return }
            html += "<p>" + para.map { inline($0) }.joined(separator: " ") + "</p>\n"
            para.removeAll()
        }
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

        while i < lines.count {
            let line = lines[i]
            let t = trimmed(line)

            // Blank line ends a paragraph.
            if t.isEmpty { flushPara(); i += 1; continue }

            // Fenced code.
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara()
                let fence = String(t.prefix(3))
                let lang = trimmed(String(t.dropFirst(3)))
                var code: [String] = []
                i += 1
                while i < lines.count, !trimmed(lines[i]).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1   // closing fence (or end of file)
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                html += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Horizontal rule.
            if t.count >= 3, ["-", "*", "_"].contains(where: { ch in
                t.allSatisfy { String($0) == ch || $0 == " " } && t.contains(ch) }) {
                flushPara(); html += "<hr>\n"; i += 1; continue
            }

            // ATX heading.
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                if level <= 6, t.dropFirst(level).first == " " || t.count == level {
                    flushPara()
                    let text = trimmed(String(t.dropFirst(level)))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        .trimmingCharacters(in: .whitespaces)
                    html += "<h\(level)>\(inline(text))</h\(level)>\n"
                    i += 1; continue
                }
            }

            // GFM table: a pipe row followed by a separator row of dashes.
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara()
                let header = cells(t)
                let aligns = cells(lines[i + 1]).map(alignment)
                i += 2
                html += "<table>\n<thead><tr>"
                for (n, h) in header.enumerated() {
                    html += "<th\(alignAttr(aligns, n))>\(inline(h))</th>"
                }
                html += "</tr></thead>\n<tbody>\n"
                while i < lines.count, trimmed(lines[i]).contains("|"), !trimmed(lines[i]).isEmpty {
                    let row = cells(trimmed(lines[i]))
                    html += "<tr>"
                    for n in 0..<header.count {
                        let v = n < row.count ? row[n] : ""
                        html += "<td\(alignAttr(aligns, n))>\(inline(v))</td>"
                    }
                    html += "</tr>\n"
                    i += 1
                }
                html += "</tbody>\n</table>\n"
                continue
            }

            // Blockquote: gather consecutive `>` lines and render them as a
            // nested document, so lists and emphasis inside still work.
            if t.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count, trimmed(lines[i]).hasPrefix(">") {
                    var s = trimmed(lines[i]).dropFirst()
                    if s.first == " " { s = s.dropFirst() }
                    q.append(String(s)); i += 1
                }
                html += "<blockquote>\n\(body(q.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            // Lists.
            if let kind = listKind(t) {
                flushPara()
                let tag = kind == .ordered ? "ol" : "ul"
                html += "<\(tag)>\n"
                while i < lines.count, let k = listKind(trimmed(lines[i])), k == kind {
                    var item = stripMarker(trimmed(lines[i]), kind)
                    i += 1
                    // Continuation lines indented under the item belong to it.
                    while i < lines.count, !trimmed(lines[i]).isEmpty,
                          listKind(trimmed(lines[i])) == nil,
                          lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") {
                        item += " " + trimmed(lines[i]); i += 1
                    }
                    // GitHub task list checkboxes.
                    if item.hasPrefix("[ ] ") {
                        html += "<li class=\"task\"><input type=\"checkbox\" disabled> \(inline(String(item.dropFirst(4))))</li>\n"
                    } else if item.lowercased().hasPrefix("[x] ") {
                        html += "<li class=\"task\"><input type=\"checkbox\" checked disabled> \(inline(String(item.dropFirst(4))))</li>\n"
                    } else {
                        html += "<li>\(inline(item))</li>\n"
                    }
                }
                html += "</\(tag)>\n"
                continue
            }

            para.append(t)
            i += 1
        }
        flushPara()
        return html
    }

    // MARK: - list helpers

    enum ListKind { case bullet, ordered }

    static func listKind(_ t: String) -> ListKind? {
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return .bullet }
        let digits = t.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let rest = t.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return .ordered }
        }
        return nil
    }

    static func stripMarker(_ t: String, _ k: ListKind) -> String {
        switch k {
        case .bullet: return String(t.dropFirst(2))
        case .ordered:
            let digits = t.prefix(while: { $0.isNumber }).count
            return String(t.dropFirst(digits + 2))
        }
    }

    // MARK: - table helpers

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        // An escaped pipe `\|` is a literal pipe inside a cell.
        let parts = t.replacingOccurrences(of: "\\|", with: "\u{1}").components(separatedBy: "|")
        return parts.map {
            $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    static func alignment(_ sep: String) -> String? {
        let l = sep.hasPrefix(":"), r = sep.hasSuffix(":")
        if l && r { return "center" }
        if r { return "right" }
        if l { return "left" }
        return nil
    }

    static func alignAttr(_ a: [String?], _ n: Int) -> String {
        guard n < a.count, let v = a[n] else { return "" }
        return " style=\"text-align:\(v)\""
    }

    // MARK: - full document

    /// A complete HTML page, styled from theme colours passed in as hex.
    ///
    /// Proportional type for prose, monospace only for code — the same split
    /// VS Code's markdown preview makes. A reading column rather than full
    /// window width, because a 180-character line is hard to follow no matter
    /// what font it is in.
    public static func page(_ md: String, bg: String, text: String, dim: String,
                            border: String, accent: String, codeBg: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: dark light; }
          html, body { margin: 0; background: \(bg); }
          body {
            color: \(text);
            font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            padding: 22px 28px 60px;
            max-width: 880px;
            -webkit-font-smoothing: antialiased;
          }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .5em; font-weight: 600; }
          h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid \(border); }
          h2 { font-size: 1.45em; padding-bottom: .25em; border-bottom: 1px solid \(border); }
          h3 { font-size: 1.2em; }
          h1:first-child, h2:first-child { margin-top: 0; }
          p, ul, ol, table, pre, blockquote { margin: 0 0 1em; }
          a { color: \(accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          strong { font-weight: 600; }
          code {
            font: 12.5px ui-monospace, "JetBrains Mono", SFMono-Regular, Menlo, monospace;
            background: \(codeBg); padding: .15em .4em; border-radius: 4px;
          }
          pre { background: \(codeBg); padding: 12px 14px; border-radius: 6px;
                overflow-x: auto; line-height: 1.45; }
          pre code { background: none; padding: 0; font-size: 12.5px; }
          ul, ol { padding-left: 1.6em; }
          li { margin: .2em 0; }
          li.task { list-style: none; margin-left: -1.3em; }
          blockquote { margin-left: 0; padding: .1em 1em; color: \(dim);
                       border-left: 3px solid \(border); }
          hr { border: 0; border-top: 1px solid \(border); margin: 1.6em 0; }
          table { border-collapse: collapse; display: block; overflow-x: auto; }
          th, td { border: 1px solid \(border); padding: 6px 12px; vertical-align: top; }
          th { font-weight: 600; background: \(codeBg); text-align: left; }
          tr:nth-child(even) td { background: \(codeBg)55; }
          del { color: \(dim); }
        </style></head><body>
        \(body(md))
        </body></html>
        """
    }
}
