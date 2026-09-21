// Offering a desk for an agent that's installed but has none.
//
// The Welcome screen makes a desk for every agent it finds, but only on the
// first run. Install Copilot or Gemini a week later and nothing happened:
// the app didn't know, and the only way in was editing desks.toml. Now the
// rail offers a desk for each installed agent that has none, until it's added
// or waved off.

import Foundation

public enum AgentOffer {

    /// Runtimes installed on this Mac with no desk, in the order Coldfall
    /// lists runtimes, leaving out any the person has said "not now" to.
    /// A desk of any kind with that runtime counts, a wrapper script included.
    public static func missing(installed: [String], desks: [Desk], dismissed: Set<String>) -> [String] {
        let have = Set(desks.map(\.runtime))
        return installed.filter { !have.contains($0) && !dismissed.contains($0) }
    }

    /// The name people use for it, short enough for the rail.
    public static func shortName(_ runtime: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini", "copilot": "Copilot",
         "grok": "Grok", "ollama": "Ollama"][runtime] ?? runtime
    }

    /// What's installed now, of the runtimes Coldfall knows.
    public static func installed() -> [String] {
        Bridge.known.filter { DeskConfig.which($0.bin) != nil }.map(\.name)
    }

    /// The desk to add for `runtime`: named after it (or `runtime-2` if that
    /// name is taken), its vendor's home desk, working where the other home
    /// desks do, or in the home folder if there are none.
    public static func desk(for runtime: String, in desks: [Desk], home: String = NSHomeDirectory()) -> Desk {
        let names = Set(desks.map { $0.name.lowercased() })
        var name = runtime, n = 2
        while names.contains(name.lowercased()) { name = "\(runtime)-\(n)"; n += 1 }
        let cwd = desks.first(where: { $0.isDefault && $0.runtime != "shell" })?.cwd
            ?? desks.first(where: { $0.runtime != "shell" })?.cwd
            ?? home
        var d = Desk(name: name, runtime: runtime, cwd: cwd)
        d.isDefault = true
        return d
    }
}
