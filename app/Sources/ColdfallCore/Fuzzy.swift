// Fuzzy matching for the quick-open palette.
//
// Typing "cpa" should find "cpa-strategy-copilot", "stc" should find
// "self-study-tutor", and "readme" should find README.md at any depth. The
// rule is VS Code's: every character of the query must appear in the
// candidate, in order, case-insensitively. Among the ones that match, the
// ranking is what makes the palette usable rather than merely correct — the
// thing you meant has to be at the top.
//
// What scores higher, in order of weight:
//   * a match at the start of a word (after /, -, _, ., space, or a case hump)
//   * consecutive characters, so "desk" beats d…e…s…k scattered across a path
//   * a match in the file NAME rather than somewhere up its directory path
//   * shorter candidates, as a tiebreak
//
// It lives in the core because it is pure logic with a real failure mode — a
// ranking that buries the obvious answer — and belongs under test.

import Foundation

public enum Fuzzy {

    /// Score `candidate` against `query`. Nil when it does not match at all.
    /// Higher is better. An empty query matches everything with score 0.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let cOrig = Array(candidate)
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        // Where the file name starts, so matches there count for more.
        let nameStart = (candidate.lastIndex(of: "/").map { candidate.distance(from: candidate.startIndex, to: $0) + 1 }) ?? 0

        var score = 0
        var qi = 0
        var prevMatch = -2
        for (ci, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var s = 1
            // Start of a word.
            if ci == 0 || "/-_. ".contains(c[ci - 1]) { s += 8 }
            // camelCase hump: lower then upper in the original.
            else if cOrig[ci].isUppercase && cOrig[ci - 1].isLowercase { s += 6 }
            // Consecutive with the previous match.
            if ci == prevMatch + 1 { s += 5 }
            // Inside the file name rather than the path above it.
            if ci >= nameStart { s += 3 }
            score += s
            prevMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }

        // A whole-name prefix match is almost always what was meant.
        let name = candidate.lowercased().split(separator: "/").last.map(String.init) ?? ""
        if name.hasPrefix(String(q)) { score += 20 }
        // Shorter wins ties.
        score -= c.count / 8
        return score
    }

    /// Rank candidates for a query, best first, dropping the non-matches.
    public static func rank<T>(_ query: String, _ items: [T], limit: Int = 50,
                               key: (T) -> String) -> [T] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(items.prefix(limit))
        }
        return items.compactMap { item -> (T, Int)? in
            guard let s = score(query, key(item)) else { return nil }
            return (item, s)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }
}

/// Every file under a directory, relative, for the palette.
///
/// Skips what nobody opens by name: version control, dependencies, build
/// output. Capped, because a palette that takes ten seconds to open on a big
/// tree is worse than one that misses a file in the 20,001st place.
public enum FileIndex {

    public static let skip: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "target", ".next",
        ".venv", "venv", "__pycache__", ".cache", "DerivedData", "Pods", ".pytest_cache",
        ".tmp", ".DS_Store",
    ]

    public static func files(under root: String, limit: Int = 20_000) -> [String] {
        // Resolve symlinks first. The enumerator reports RESOLVED paths, so a
        // root behind a symlink (/var/folders -> /private/var/folders, or a
        // workspace linked from elsewhere) never matched its own prefix, and
        // every result came back as a full absolute path instead of a relative
        // one. Caught by the test suite on its first run.
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let url as URL in e {
            let name = url.lastPathComponent
            if skip.contains(name) {
                e.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            let full = url.resolvingSymlinksInPath().path
            let rel = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
            out.append(rel)
            if out.count >= limit { break }
        }
        return out
    }
}
