import Foundation

/// One persistent specialist. Sessions are disposable; this is not.
public struct Desk {
    public init(name: String, agent: String? = nil, runtime: String = "claude",
                model: String? = nil, cwd: String? = nil, command: String? = nil,
                group: String? = nil, isDefault: Bool = false) {
        self.name = name; self.agent = agent; self.runtime = runtime
        self.model = model; self.cwd = cwd; self.command = command; self.group = group
        self.isDefault = isDefault
    }

    public var name: String
    public var agent: String?
    /// "shell" means no vendor — a plain terminal. A desk that runs a `command`
    /// without saying which vendor is shell by default, because Deskwork
    /// genuinely does not know what is behind the script. Guessing claude there
    /// would let a bare zsh prompt be picked as the Claude home.
    public var runtime: String = "claude"
    public var model: String?
    public var cwd: String?
    public var command: String?     // escape hatch: run this verbatim instead
    /// Desks are not a flat list. `study` belongs under `school` next to `mba`.
    /// Ungrouped desks sit at the top, above the first group header.
    public var group: String?
    /// The general-purpose desk for its runtime: what opens on launch, and
    /// where Deskwork routes work that belongs to the vendor rather than to a
    /// particular agent. One per runtime, not one overall — somebody running
    /// Claude and Codex wants a home for each.
    public var isDefault: Bool = false
    /// True when the config said which vendor, rather than us assuming.
    public var declaredRuntime: Bool = false

    /// argv for the login shell. Deskwork never reimplements an agent — it
    /// launches the vendor's own CLI so that CLI's config, hooks, memory and
    /// model pins all apply untouched.
    public func launchCommand() -> String {
        if let c = command, !c.isEmpty { return c }
        switch runtime {
        case "shell":
            return command ?? "exec $SHELL -l"
        case "claude":
            var parts = ["claude"]
            if let a = agent, !a.isEmpty { parts += ["--agent", a] }
            parts += ["-n", name]
            return parts.joined(separator: " ")
        case "codex":  return "codex"
        case "gemini": return "gemini"
        case "copilot": return "copilot"
        case "ollama":
            // `ollama run <model>` is interactive; the model is required.
            return "ollama run \(model ?? "llama3")"
        case "grok":
            var parts = ["grok"]
            if let m = model, !m.isEmpty { parts += ["-m", m] }
            return parts.joined(separator: " ")
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
        for (runtime, bin) in [("claude", "claude"), ("codex", "codex"), ("gemini", "gemini"),
                               ("copilot", "copilot"), ("grok", "grok"), ("ollama", "ollama")] {
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

    /// The general desk for a runtime: explicitly marked, else the first plain
    /// desk of that runtime, else nothing. No magic names.
    public static func general(for runtime: String, in desks: [Desk]) -> Int? {
        guard runtime != "shell" else { return nil }   // a shell is nobody's home
        return desks.firstIndex { $0.isDefault && $0.runtime == runtime }
            ?? desks.firstIndex { $0.runtime == runtime && $0.agent == nil }
            ?? desks.firstIndex { $0.runtime == runtime }
    }

    /// What opens on launch.
    public static func startup(in desks: [Desk]) -> Int {
        desks.firstIndex(where: \.isDefault) ?? 0
    }

    /// The runtime to assume when a desk names none and runs no command.
    ///
    /// Previously this was hardcoded to claude, which quietly made one vendor
    /// the default for everybody. It is now whichever runtime the config
    /// already uses most — so it reflects what you actually run — falling back
    /// to the first one installed, in no particular order of preference.
    public static func preferredRuntime(given desks: [Desk] = []) -> String {
        var counts: [String: Int] = [:]
        for d in desks where d.runtime != "shell" { counts[d.runtime, default: 0] += 1 }
        if let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key { return top }
        for r in ["claude", "codex", "gemini", "copilot", "grok", "ollama"]
        where which(r) != nil { return r }
        return "shell"
    }

    public static func load() -> [Desk] { load(path: path) }

    /// Look of the terminal, from an optional `[theme]` table in desks.toml.
    ///
    /// Separate from the desk list on purpose: a desk describes work, a theme
    /// describes the window, and merging them would mean a per-desk theme,
    /// which sounds appealing and means every desk switch repaints.
    public struct ThemeSettings {
        public var font: String?
        public var size: Int?
        public var palette: String?
        /// Space between the terminal and the edge of its pane. Ghostty's
        /// defaults, because text butting against the frame is the first thing
        /// that makes a terminal feel cheap.
        public var padX: Int = 12
        public var padY: Int = 10
    }

    public static func themeSettings(path: String = DeskConfig.path) -> ThemeSettings {
        var t = ThemeSettings()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return t }
        var inTheme = false
        for line in raw.components(separatedBy: .newlines) {
            let l = TomlText.stripComment(line).trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { inTheme = (l == "[theme]"); continue }
            guard inTheme, let eq = l.firstIndex(of: "=") else { continue }
            let k = l[l.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let v = TomlText.unescape(String(l[l.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces))
            switch k {
            case "font":    t.font = v.isEmpty ? nil : v
            case "size":    t.size = Int(v)
            case "palette": t.palette = v.isEmpty ? nil : v
            case "padding_x", "padx": t.padX = Int(v) ?? t.padX
            case "padding_y", "pady": t.padY = Int(v) ?? t.padY
            default: break
            }
        }
        return t
    }

    /// Path is injectable so the parser can be tested without touching the
    /// user's real config.
    public static func load(path: String) -> [Desk] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var desks: [Desk] = []
        var current: Desk?
        var explicitRuntime = false

        func finish() {
            guard var d = current else { return }
            // No vendor declared and a command to run: we do not know what is
            // behind it, so it is a shell as far as routing is concerned.
            if !explicitRuntime, d.command != nil { d.runtime = "shell" }
            desks.append(d)
            current = nil
            explicitRuntime = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            line = TomlText.stripComment(line)
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                finish()
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let parts = header.split(separator: ".").map(String.init)
                if parts.count == 2, parts[0] == "desk" { current = Desk(name: parts[1]) }
                continue
            }

            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip ONE surrounding pair of quotes, then undo escaping.
            // trimmingCharacters removed every leading and trailing quote,
            // which mangles a value that legitimately ends in one.
            if val.count >= 2,
               (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                let inner = String(val.dropFirst().dropLast())
                val = val.hasPrefix("\"") ? TomlText.unescape(inner) : inner
            }

            switch key {
            case "agent":   current?.agent = val
            case "runtime":
                current?.runtime = val
                current?.declaredRuntime = true
                explicitRuntime = true
            case "model":   current?.model = val
            case "cwd":     current?.cwd = val
            case "command": current?.command = val
            case "group":   current?.group = val
            case "default": current?.isDefault = (val == "true")
            default: break
            }
        }
        finish()
        // Resolve any desk that named neither a runtime nor a command.
        let fallback = preferredRuntime(given: desks)
        return desks.map { d in
            var d = d
            if d.command == nil && !d.declaredRuntime { d.runtime = fallback }
            return d
        }
    }

    /// Write desks back out. The file stays the source of truth, so anything
    /// written here must be something a human can also edit by hand.
    public static func write(_ desks: [Desk]) { write(desks, to: path) }

    /// Path injectable so the write -> load round trip can be tested.
    public static func write(_ desks: [Desk], to path: String) {
        var out = "# Deskwork desks. Written by Deskwork; safe to edit by hand.\n"
        for d in desks {
            out += "\n[desk.\(d.name)]\n"
            if let g = d.group { out += "group = \"\(TomlText.escape(g))\"\n" }
            if d.isDefault { out += "default = true\n" }
            if let c = d.command {
                out += "command = \"\(TomlText.escape(c))\"\n"
                // Only worth writing when it says something the command does not.
                if d.runtime != "shell" { out += "runtime = \"\(TomlText.escape(d.runtime))\"\n" }
            } else {
                out += "runtime = \"\(TomlText.escape(d.runtime))\"\n"
                if let a = d.agent { out += "agent = \"\(TomlText.escape(a))\"\n" }
            }
            if let w = d.cwd { out += "cwd = \"\(TomlText.escape(w))\"\n" }
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
