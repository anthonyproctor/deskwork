// Making the meter cheap enough to open.
//
// The scan read every Claude transcript and every Codex rollout on every
// refresh, parsing each line as JSON. Measured on a real machine: 823MB across
// 267 files, **12 seconds**, every time the usage panel was opened. That is
// long enough that the honest reading of it is "the app hung".
//
// Two things were wrong, and they compound:
//
//   1. NO WINDOW GATE on the Claude scan. The report covers a fixed number of
//      days, so a file untouched since before the window opened cannot
//      contribute to it — but it was opened and parsed anyway. On the machine
//      above that was 262MB of the 823MB read for literally nothing.
//
//   2. NO CACHE. A transcript that has not changed since the last refresh
//      produces exactly the same numbers, and there is no reason to recompute
//      them. This is the same trick burn-refresh.py already uses: key each
//      file's contribution on (modification time, size) and reuse it.
//
// The cache is deliberately a plain JSON file rather than a database. It is
// derived data — deleting it costs one slow refresh and nothing else — and a
// format you can `cat` is worth more here than one that is marginally faster.

import Foundation

/// One file's contribution to a report, already aggregated.
///
/// Aggregated rather than raw rows because a busy transcript holds tens of
/// thousands of messages and at most a couple of dozen (day, vendor, desk)
/// combinations. Storing the rows would make the cache bigger than the win.
public struct UsageSlice: Codable {
    public var vendor: String
    public var desk: String?
    public var day: String
    public var tokens: Int
    public var calls: Int
    public var usd: Double?

    public init(vendor: String, desk: String?, day: String,
                tokens: Int, calls: Int, usd: Double?) {
        self.vendor = vendor; self.desk = desk; self.day = day
        self.tokens = tokens; self.calls = calls; self.usd = usd
    }
}

struct CachedFile: Codable {
    /// "modificationTime:size". Both, because a file can be rewritten to the
    /// same length within the same second, and mtime alone would miss it.
    var key: String
    /// The window this was computed for. A report over a different span is a
    /// different answer, so it must not be served from here.
    var since: Double
    var slices: [UsageSlice]
}

public enum UsageCache {

    public static var path: String {
        let dir = NSString(string: "~/.local/share/deskwork/cache").expandingTildeInPath
        return (dir as NSString).appendingPathComponent("usage.json")
    }

    private static var loaded: [String: CachedFile]?
    private static var dirty = false

    /// Fingerprint a file cheaply. Nil when it cannot be read at all, which
    /// callers treat as "skip", not as "unchanged".
    public static func fingerprint(_ path: String) -> (key: String, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let m = a[.modificationDate] as? Date else { return nil }
        let size = (a[.size] as? Int) ?? 0
        return ("\(Int(m.timeIntervalSince1970)):\(size)", m)
    }

    static func all() -> [String: CachedFile] {
        if let l = loaded { return l }
        let l = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONDecoder().decode([String: CachedFile].self, from: $0) } ?? [:]
        loaded = l
        return l
    }

    /// A file's cached contribution, or nil if it changed, is new, or was
    /// computed for a different window.
    public static func slices(for path: String, key: String, since: Date) -> [UsageSlice]? {
        guard let hit = all()[path], hit.key == key,
              abs(hit.since - since.timeIntervalSince1970) < 1 else { return nil }
        return hit.slices
    }

    public static func store(_ slices: [UsageSlice], for path: String,
                             key: String, since: Date) {
        var l = all()
        l[path] = CachedFile(key: key, since: since.timeIntervalSince1970, slices: slices)
        loaded = l
        dirty = true
    }

    /// Write once at the end of a scan rather than after each file, and drop
    /// entries for files that are gone so the cache cannot grow without bound.
    public static func flush(keeping live: Set<String>) {
        guard dirty else { return }
        var l = all()
        for k in l.keys where !live.contains(k) { l.removeValue(forKey: k) }
        loaded = l
        dirty = false
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(l) else { return }
        // Atomically, so a refresh interrupted halfway cannot leave a cache
        // file that parses as valid but describes work that never finished.
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Forget everything. Derived data, so this is always safe.
    public static func clear() {
        loaded = [:]
        dirty = false
        try? FileManager.default.removeItem(atPath: path)
    }
}
