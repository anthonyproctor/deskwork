// What Claude usage costs, in one place.
//
// This was two copies of one table, both assuming a cache read costs a tenth
// of input and a cache write a quarter more. Both assumptions went stale:
//
//   - Opus 5.5 (2026-09-22) reads cache at 1/20 of input, Fable 5.1 at 1/40.
//     The flat tenth overstated a Fable-heavy week's cache reads fourfold.
//   - Claude Code writes the ONE-HOUR cache almost always (99% of writes on
//     a real machine), which costs 2x input, not the 5-minute cache's 1.25x.
//     Rebuilds were understated by more than a third.
//
// Prices move. This table says where it came from and when, so the next
// person to find it wrong knows how old it is.
//
// Source: https://platform.claude.com/docs/en/about-claude/pricing
// Checked: 2026-09-23

import Foundation

public enum Pricing {

    public struct Model: Equatable {
        /// $ per million tokens.
        public let input: Double
        public let output: Double
        /// A cache read, as a fraction of input.
        public let cacheRead: Double
        public init(_ input: Double, _ output: Double, cacheRead: Double = 0.1) {
            self.input = input; self.output = output; self.cacheRead = cacheRead
        }
    }

    public static let checked = "2026-09-23"
    public static let source = "https://platform.claude.com/docs/en/about-claude/pricing"

    static let models: [String: Model] = [
        "claude-fable-5-1":  Model(10, 50, cacheRead: 0.025),
        "claude-mythos-5-1": Model(10, 50, cacheRead: 0.025),
        "claude-fable-5":    Model(10, 50),
        "claude-opus-5-5":   Model(4, 20, cacheRead: 0.05),
        "claude-opus-5":     Model(5, 25),
        "claude-opus-4-8":   Model(5, 25),
        "claude-opus-4-7":   Model(5, 25),
        "claude-opus-4-6":   Model(5, 25),
        "claude-opus-4-5":   Model(5, 25),
        "claude-sonnet-5":   Model(2, 10),
        "claude-sonnet-4-6": Model(3, 15),
        "claude-sonnet-4-5": Model(3, 15),
        "claude-haiku-4-5":  Model(1, 5),
    ]

    /// Writing to the 5-minute cache, and to the 1-hour one, as fractions of input.
    public static let write5m = 1.25
    public static let write1h = 2.0

    /// A model's prices. An id this table has never seen is priced as the
    /// nearest family it names, and failing that as Opus, the most common.
    public static func model(_ id: String) -> Model {
        if let m = models[id] { return m }
        // A dated or suffixed id ("claude-opus-5-5-20260922", "...[1m]").
        if let hit = models.keys.sorted(by: { $0.count > $1.count }).first(where: { id.hasPrefix($0) }) {
            return models[hit]!
        }
        return models["claude-opus-5"]!
    }

    /// One turn's cost. `write5m` and `write1h` split the cache write when
    /// the record says which; `write` is the total, used when it doesn't
    /// (Claude Code writes the 1-hour cache, so that is the assumption).
    public static func cost(model id: String, fresh: Int, read: Int, write: Int,
                            write5m: Int? = nil, write1h: Int? = nil, output: Int) -> Double {
        let m = model(id)
        let writeCost: Double
        if let a = write5m, let b = write1h, a + b > 0 {
            writeCost = Double(a) * Pricing.write5m + Double(b) * Pricing.write1h
        } else {
            writeCost = Double(write) * Pricing.write1h
        }
        return (Double(fresh) + writeCost + Double(read) * m.cacheRead) / 1e6 * m.input
             + Double(output) / 1e6 * m.output
    }

    /// Just the cache write of a turn: what rebuilding a conversation costs.
    public static func writeCost(model id: String, write: Int, write5m: Int? = nil, write1h: Int? = nil) -> Double {
        cost(model: id, fresh: 0, read: 0, write: write, write5m: write5m, write1h: write1h, output: 0)
    }

    /// The split Claude Code records under usage.cache_creation, when present.
    public static func writeSplit(_ usage: [String: Any]) -> (Int?, Int?) {
        guard let c = usage["cache_creation"] as? [String: Any] else { return (nil, nil) }
        return (c["ephemeral_5m_input_tokens"] as? Int, c["ephemeral_1h_input_tokens"] as? Int)
    }
}
