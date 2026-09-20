import Foundation

/// Cross-vendor usage, read from what the CLIs already write to disk.
///
/// No API, no scraping, no credentials. Both vendors keep per-turn token records
/// locally, which is enough to answer the question that matters: where is the
/// week going, and who still has room.
///
///   Claude  ~/.claude/projects/<proj>/<session>.jsonl   message.usage
///   Codex   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl  type=token_usage_record
///
/// Two traps, both learned the hard way:
///
///  1. DEDUPE Claude on `message.id`. A streamed reply is written to the
///     transcript more than once; counting every record roughly doubled a real
///     30-day total.
///  2. Report TOKENS, not invented dollars. Claude's per-model prices are known
///     and worth showing. Frontier model pricing on the other side is not
///     something this tool should guess at, so it does not.
public enum Usage {

    public struct Bucket {
        public init() {}
        public var tokens: Int = 0
        public var usd: Double? = nil        // nil where pricing is not known
        public var calls: Int = 0
    }

    public struct Report {
        public init() {}
        public var byVendor: [String: Bucket] = [:]
        public var byDesk: [String: Bucket] = [:]      // Claude only: desks come from session titles
        public var byDay: [String: [String: Int]] = [:] // day -> vendor -> tokens
        public var generated = Date()
    }

    // Claude list prices, $ per 1M (input, output). Cache write 1.25x in, read 0.10x in.
    private static let claudePrices: [String: (Double, Double)] = [
        "claude-fable-5-1": (10, 50), "claude-fable-5": (10, 50),
        "claude-opus-5": (5, 25), "claude-opus-4-8": (5, 25),
        "claude-opus-4-7": (5, 25), "claude-opus-4-6": (5, 25),
        "claude-sonnet-5": (2, 10), "claude-sonnet-4-6": (3, 15),
        "claude-haiku-4-5": (1, 5),
    ]

    private static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    /// Anthropic's weekly window resets Saturday. Codex has its own cadence, but
    /// one shared boundary keeps the comparison honest.
    public static func weekStart() -> Date {
        let now = Date()
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .weekday], from: now)
        let back = ((c.weekday ?? 1) - 7 + 7) % 7      // Saturday == 7
        var start = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now))!
        start = cal.date(byAdding: .hour, value: 11, to: start)!
        if start > now { start = cal.date(byAdding: .day, value: -7, to: start)! }
        c = DateComponents()
        return start
    }

    public static func scan(since: Date) -> Report {
        var r = Report()
        scanClaude(since: since, into: &r)
        scanCodex(since: since, into: &r)
        return r
    }

    private static func add(_ r: inout Report, vendor: String, desk: String?,
                            tokens: Int, usd: Double?, when: Date) {
        var v = r.byVendor[vendor] ?? Bucket()
        v.tokens += tokens; v.calls += 1
        if let usd { v.usd = (v.usd ?? 0) + usd }
        r.byVendor[vendor] = v

        if let desk {
            var d = r.byDesk[desk] ?? Bucket()
            d.tokens += tokens; d.calls += 1
            if let usd { d.usd = (d.usd ?? 0) + usd }
            r.byDesk[desk] = d
        }
        let k = dayKey(when)
        r.byDay[k, default: [:]][vendor, default: 0] += tokens
    }

    private static func scanClaude(since: Date, into r: inout Report) {
        let root = NSString(string: "~/.claude/projects").expandingTildeInPath
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for proj in projects {
            let dir = (root as NSString).appendingPathComponent(proj)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

                var desk: String? = nil
                var seen = Set<String>()        // per-file dedupe: that is where dupes come from
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let d = line.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }

                    if desk == nil, o["type"] as? String == "custom-title" {
                        desk = o["customTitle"] as? String
                    }
                    guard let msg = o["message"] as? [String: Any],
                          let u = msg["usage"] as? [String: Any] else { continue }
                    if let id = msg["id"] as? String {
                        if seen.contains(id) { continue }
                        seen.insert(id)
                    }
                    guard let ts = o["timestamp"] as? String, let when = iso(ts), when >= since else { continue }

                    let i = u["input_tokens"] as? Int ?? 0
                    let cw = u["cache_creation_input_tokens"] as? Int ?? 0
                    let cr = u["cache_read_input_tokens"] as? Int ?? 0
                    let out = u["output_tokens"] as? Int ?? 0
                    let model = msg["model"] as? String ?? ""
                    let (pin, pout) = claudePrices[model] ?? (5, 25)
                    let usd = (Double(i) + 1.25 * Double(cw) + 0.10 * Double(cr)) / 1e6 * pin
                            + Double(out) / 1e6 * pout
                    add(&r, vendor: "claude", desk: desk, tokens: i + cw + cr + out, usd: usd, when: when)
                }
            }
        }
    }

    private static func scanCodex(since: Date, into r: inout Report) {
        let root = NSString(string: "~/.codex/sessions").expandingTildeInPath
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        for case let rel as String in e where rel.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(rel)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let m = attrs[.modificationDate] as? Date, m >= since,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["type"] as? String == "token_usage_record",
                      let p = o["payload"] as? [String: Any],
                      let u = p["usage"] as? [String: Any],
                      let ts = o["timestamp"] as? String, let when = iso(ts), when >= since else { continue }
                // Pricing for these models is not something this tool should guess.
                add(&r, vendor: "codex", desk: nil,
                    tokens: u["total_tokens"] as? Int ?? 0, usd: nil, when: when)
            }
        }
    }

    /// The router call: who has room, stated only when the gap is real.
    public static func routerHint(_ r: Report) -> String? {
        let v = r.byVendor.filter { $0.value.tokens > 0 }
        guard v.count >= 2 else { return nil }
        let sorted = v.sorted { $0.value.tokens > $1.value.tokens }
        guard let hot = sorted.first, let cold = sorted.last, hot.key != cold.key else { return nil }
        let total = v.values.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return nil }
        let hotShare = Double(hot.value.tokens) / Double(total)
        guard hotShare > 0.70 else { return nil }
        return "\(Int(hotShare * 100))% of this week is on \(hot.key). \(cold.key) is barely touched."
    }
}
