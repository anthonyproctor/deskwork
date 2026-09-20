import Foundation

/// One persistent specialist. Sessions are disposable; this is not.
public struct Desk {
    public init(name: String, agent: String? = nil, runtime: String = "claude",
                model: String? = nil, cwd: String? = nil, command: String? = nil,
                group: String? = nil) {
        self.name = name; self.agent = agent; self.runtime = runtime
        self.model = model; self.cwd = cwd; self.command = command; self.group = group
    }

    public var name: String
    public var agent: String?
    public var runtime: String = "claude"
    public var model: String?
    public var cwd: String?
    public var command: String?     // escape hatch: run this verbatim instead
    /// Desks are not a flat list. `study` belongs under `school` next to `mba`.
    /// Ungrouped desks sit at the top, above the first group header.
    public var group: String?

    /// argv for the login shell. Deskwork never reimplements an agent — it
    /// launches the vendor's own CLI so that CLI's config, hooks, memory and
    /// model pins all apply untouched.
    public func launchCommand() -> String {
        if let c = command, !c.isEmpty { return c }
        switch runtime {
        case "claude":
            var parts = ["claude"]
            if let a = agent, !a.isEmpty { parts += ["--agent", a] }
            parts += ["-n", name]
            return parts.joined(separator: " ")
        case "codex":  return "codex"
        case "gemini": return "gemini"
        case "copilot": return "copilot"
        default: return runtime
        }
    }

    public var resolvedCwd: String {
        (cwd.map { NSString(string: $0).expandingTildeInPath }) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

/// Just enough TOML for `[desk.<name>]` tables of `key = "value"`. A real parser
/// is a dependency we do not need yet, and the config shape is deliberately flat.
public enum DeskConfig {
    public static var path: String {
        NSString(string: "~/.config/deskwork/desks.toml").expandingTildeInPath
    }

    /// First run: leave a working config on disk rather than an empty window.
    /// Only desks whose CLI is actually installed get written.
    public static func writeStarter() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: path) else { return }

        var out = """
        # Deskwork desks. A desk is a persistent specialist; sessions are disposable.
        # Written on first run. Edit freely, then restart Deskwork.

        [desk.shell]
        # A plain shell first, so opening the app costs nothing.
        command = "exec zsh -l"
        cwd = "~"

        """
        for (runtime, bin) in [("claude", "claude"), ("codex", "codex"), ("gemini", "gemini"), ("copilot", "copilot")] {
            guard which(bin) != nil else { continue }
            out += """

            [desk.\(runtime)]
            runtime = "\(runtime)"
            cwd = "~"

            """
        }
        out += """

        # An agent-backed desk, once you have one defined in that CLI:
        # [desk.notes]
        # agent   = "research-copilot"
        # runtime = "claude"
        # cwd     = "~/notes"

        # `command` is the escape hatch: run anything verbatim, including your own
        # wrapper that already handles resume-vs-new.
        # [desk.api]
        # command = "~/bin/desk api"
        # cwd     = "~/src/api"

        """
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Is this CLI on PATH? Used so the starter config only lists real runtimes.
    public static func which(_ bin: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":").map(String.init)
            + [NSString(string: "~/.local/bin").expandingTildeInPath, "/opt/homebrew/bin", "/usr/local/bin"]
        for p in paths {
            let full = (p as NSString).appendingPathComponent(bin)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    public static func load() -> [Desk] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var desks: [Desk] = []
        var current: Desk?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                if let d = current { desks.append(d); current = nil }
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let parts = header.split(separator: ".").map(String.init)
                if parts.count == 2, parts[0] == "desk" { current = Desk(name: parts[1]) }
                continue
            }

            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "agent":   current?.agent = val
            case "runtime": current?.runtime = val
            case "model":   current?.model = val
            case "cwd":     current?.cwd = val
            case "command": current?.command = val
            case "group":   current?.group = val
            default: break
            }
        }
        if let d = current { desks.append(d) }
        return desks
    }
}
