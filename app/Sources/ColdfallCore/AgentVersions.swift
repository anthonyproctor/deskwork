// Noticing when an agent updates.
//
// The vendors ship every few days, and what they ship changes how the agents
// behave and what they cost: a Claude Code release that fixed prompt-cache
// misses on resume is money, and nobody reads changelogs unprompted. So when
// Coldfall sees an agent's version change, it says so once, with a link to
// what's new.
//
// Asking a CLI for its version runs it locally and sends nothing anywhere:
// no model call, no tokens.

import Foundation

public enum AgentVersions {

    public struct Change: Equatable {
        public let runtime: String
        public let from: String
        public let to: String
        public init(runtime: String, from: String, to: String) {
            self.runtime = runtime; self.from = from; self.to = to
        }
        /// "Claude Code updated to 2.1.280": short enough for the rail.
        public var line: String { "\(AgentOffer.shortName(runtime)) updated to \(to)" }
        /// The longer form, for a tooltip.
        public var detail: String { "\(AgentOffer.shortName(runtime)) went from \(from) to \(to)." }
        public var url: String? { AgentVersions.changelogs[runtime] }
    }

    /// Where each vendor says what changed.
    public static let changelogs: [String: String] = [
        "claude": "https://code.claude.com/docs/en/changelog",
        "codex": "https://github.com/openai/codex/releases",
        "copilot": "https://github.com/github/copilot-cli/releases",
        "antigravity": "https://antigravity.google/docs/cli/overview",
        "ollama": "https://github.com/ollama/ollama/releases",
    ]

    /// The first version number in a CLI's `--version` output:
    /// "2.1.280 (Claude Code)" → "2.1.280", "codex-cli 0.155.1" → "0.155.1".
    public static func parse(_ output: String) -> String? {
        let parts = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," })
        for p in parts {
            var s = Substring(p)
            if s.first == "v" || s.first == "V" { s = s.dropFirst() }
            while let last = s.last, !last.isNumber { s = s.dropLast() }
            let pieces = s.split(separator: ".")
            if pieces.count >= 2, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return String(s)
            }
        }
        return nil
    }

    /// What changed between two readings. An agent seen for the first time
    /// is not news, and neither is one that has gone.
    public static func changes(from old: [String: String], to new: [String: String]) -> [Change] {
        new.keys.sorted().compactMap { rt in
            guard let was = old[rt], let now = new[rt], was != now else { return nil }
            return Change(runtime: rt, from: was, to: now)
        }
    }

    /// Ask each installed agent its version. Runs each CLI with --version, a
    /// few seconds at most each, off whatever thread calls it.
    public static func current(runtimes: [Bridge.Runtime] = Bridge.known) -> [String: String] {
        var out: [String: String] = [:]
        for rt in runtimes {
            guard let bin = DeskConfig.which(rt.bin) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); continue }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let v = parse(text) { out[rt.name] = v }
        }
        return out
    }
}
