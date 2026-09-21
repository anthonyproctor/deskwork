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
    /// without saying which vendor is shell by default, because Coldfall
    /// genuinely does not know what is behind the script. Guessing claude there
    /// would let a bare zsh prompt be picked as the Claude home.
    public var runtime: String = "claude"
    public var model: String?
    public var cwd: String?
    public var command: String?     // escape hatch: run this verbatim instead
    /// MCP servers from the folder's .mcp.json switched off for this desk
    /// (see McpTrim). Empty means all of them, as before.
    public var mcpOff: [String] = []
    /// The Claude conversation this desk reopens, by id. Set when a built-in
    /// desk is renamed: its conversation is titled with the OLD name, so the
    /// lookup by name would stop finding it. Unset, the desk finds its
    /// conversation by name, as before.
    public var session: String?
    /// Out of the rail and cmd-1..9, but kept: its settings, group and
    /// conversation stay, and quick open still finds it.
    public var hidden: Bool = false
    /// Desks are not a flat list. `study` belongs under `school` next to `mba`.
    /// Ungrouped desks sit at the top, above the first group header.
    public var group: String?
    /// The general-purpose desk for its runtime: what opens on launch, and
    /// where Coldfall routes work that belongs to the vendor rather than to a
    /// particular agent. One per runtime, not one overall — somebody running
    /// Claude and Codex wants a home for each.
    public var isDefault: Bool = false
    /// True when the config said which vendor, rather than us assuming.
    public var declaredRuntime: Bool = false

    /// Whether Coldfall launches this desk itself, and so decides whether it
    /// resumes. A desk with its own command leaves that to the command.
    public var resumesItself: Bool {
        (command ?? "").isEmpty && (runtime == "claude" || runtime == "codex")
    }

    /// This desk renamed from `old`. A built-in Claude desk keeps its
    /// conversation by remembering its id, looked up under the old name now,
    /// while that name still finds it.
    public func renamed(from old: String, to new: String, claudeRoot: String = Resume.claudeProjectsRoot) -> Desk {
        var d = self
        d.name = new
        if resumesItself, runtime == "claude", d.session == nil {
            d.session = Resume.claudeSession(named: old, cwd: resolvedCwd, root: claudeRoot)
        }
        return d
    }

    /// The command to start this desk, reopening its earlier conversation
    /// when there is one. Looks on disk, so call it off the main thread for
    /// a desk with a long history.
    public func resumingLaunchCommand(claudeRoot: String = Resume.claudeProjectsRoot,
                                      codexRoot: String = Resume.codexSessionsRoot) -> String {
        guard resumesItself else { return launchCommand() }
        if runtime == "claude" {
            // A remembered conversation first, while it still exists; then
            // the newest one titled with the desk's name.
            if let s = session, Resume.claudeTranscriptExists(s, cwd: resolvedCwd, root: claudeRoot) {
                return launchCommand(claudeSession: s)
            }
            return launchCommand(claudeSession: Resume.claudeSession(named: name, cwd: resolvedCwd, root: claudeRoot))
        }
        return launchCommand(codexResume: Resume.codexHasSession(cwd: resolvedCwd, root: codexRoot))
    }

    /// argv for the login shell. Coldfall never reimplements an agent — it
    /// launches the vendor's own CLI so that CLI's config, hooks, memory and
    /// model pins all apply untouched.
    ///
    /// `claudeSession` is the id of this desk's earlier Claude conversation and
    /// `codexResume` says Codex has one in this directory; either reopens it
    /// instead of starting fresh. A desk with its own command ignores both.
    public func launchCommand(claudeSession: String? = nil, codexResume: Bool = false) -> String {
        if let c = command, !c.isEmpty { return c }
        switch runtime {
        case "shell":
            return command ?? "exec $SHELL -l"
        case "claude":
            var parts = ["claude"]
            // Every value from desks.toml is quoted: see Shell.quote.
            if let a = agent, !a.isEmpty { parts += ["--agent", Shell.quote(a)] }
            if let s = claudeSession, !s.isEmpty { parts += ["--resume", Shell.quote(s)] } else { parts += ["-n", Shell.quote(name)] }
            // Names are checked to letters, digits, - _ . so the JSON has no
            // single quote to break out of.
            if let s = McpTrim.settingsJSON(off: mcpOff) { parts += ["--settings", "'\(s)'"] }
            return parts.joined(separator: " ")
        case "codex":
            let base = codexResume ? ["codex", "resume", "--last"] : ["codex"]
            return (base + McpTrim.codexArgs(off: mcpOff)).joined(separator: " ")
        case "gemini": return "gemini"
        case "copilot": return "copilot"
        case "ollama":
            // `ollama run <model>` is interactive; the model is required.
            return "ollama run \(Shell.quote(model ?? "llama3"))"
        case "grok":
            var parts = ["grok"]
            if let m = model, !m.isEmpty { parts += ["-m", Shell.quote(m)] }
            return parts.joined(separator: " ")
        default: return Shell.quote(runtime)
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
        NSString(string: "~/.config/coldfall/desks.toml").expandingTildeInPath
    }

    /// First run: leave a working config on disk rather than an empty window.
    /// Only desks whose CLI is actually installed get written.
    public static func writeStarter() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: path) else { return }

        var out = """
        # Project Coldfall desks. A desk is a persistent specialist; sessions are disposable.
        # Written on first run. Edit freely, then restart Project Coldfall.

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
            + loginShellPath
        for p in paths {
            let full = (p as NSString).appendingPathComponent(bin)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    /// The PATH your login shell sets up, where Terminal would find a tool.
    ///
    /// An app opened from the Dock gets a bare PATH, so a CLI installed with
    /// npm under nvm, or anywhere a shell profile adds, was invisible to it.
    /// Asked once, off the main thread, via `warmLoginShellPath`; empty until
    /// then, so `which` never waits on a shell.
    public private(set) static var loginShellPath: [String] = []

    public static func warmLoginShellPath(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            // A profile that hangs must not hang this: give up after a few seconds.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let dirs = String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
                .filter { $0.hasPrefix("/") }
            DispatchQueue.main.async {
                loginShellPath = dirs
                completion?()
            }
        }
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
        /// "dark" (the default), "light", or "system" to follow the OS.
        ///
        /// Dark rather than system on purpose. This is a terminal-first tool
        /// and every terminal-first tool it sits next to — VS Code, Ghostty,
        /// iTerm — opens dark. Following the OS means someone whose Mac is in
        /// light mode gets a white terminal they never asked for on first
        /// launch, and first launch is the only impression there is.
        public var mode: String?
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
            let v = TomlText.value(String(l[l.index(after: eq)...]))
            switch k {
            case "font":    t.font = v.isEmpty ? nil : v
            case "size":    t.size = Int(v)
            case "palette": t.palette = v.isEmpty ? nil : v
            case "mode":    t.mode = v.isEmpty ? nil : v
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
            case "mcp_off": current?.mcpOff = TomlText.stringArray(val) ?? []
            case "hidden":  current?.hidden = val == "true"
            case "session": current?.session = UUID(uuidString: val) != nil ? val.lowercased() : nil
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
    public static func write(_ desks: [Desk]) { write(desks, theme: nil, to: path) }
    public static func write(_ desks: [Desk], to path: String) {
        write(desks, theme: nil, to: path)
    }

    /// Path injectable so the write -> load round trip can be tested.
    /// Everything in the file that is NOT a `[desk.*]` table, kept verbatim.
    ///
    /// The writer builds desks.toml from the desk list, so any section it does
    /// not know about would be silently deleted on save — `[theme]` was, and
    /// the next section somebody adds would be too. Rather than teach the
    /// writer about each one, keep whatever else is there exactly as written,
    /// comments and all.
    public static func preservedTables(from path: String = DeskConfig.path,
                                       dropping: Set<String> = []) -> String {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        var kept: [String] = []
        var skipping = false
        for line in raw.components(separatedBy: .newlines) {
            let t = TomlText.stripComment(line).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                // A table header ends the previous table, so the decision is
                // remade here rather than carried. Slicing the file at the
                // first "[theme]" instead would have thrown away every table
                // that came after it.
                skipping = t.hasPrefix("[desk.") || dropping.contains(t)
                if skipping { continue }
            }
            if !skipping { kept.append(line) }
        }
        // Trim the blank run at either end so the rebuilt file does not grow a
        // gap every time it is saved.
        while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// Render a `[theme]` table. Only non-default values are written, so the
    /// file stays about what the user chose rather than restating every default.
    public static func themeTable(_ t: ThemeSettings) -> String {
        var lines: [String] = []
        if let v = t.palette, !v.isEmpty { lines.append("palette = \"\(TomlText.escape(v))\"") }
        if let v = t.mode, !v.isEmpty { lines.append("mode = \"\(TomlText.escape(v))\"") }
        if let v = t.font, !v.isEmpty { lines.append("font = \"\(TomlText.escape(v))\"") }
        if let v = t.size { lines.append("size = \(v)") }
        if t.padX != 12 { lines.append("padding_x = \(t.padX)") }
        if t.padY != 10 { lines.append("padding_y = \(t.padY)") }
        return lines.isEmpty ? "" : "[theme]\n" + lines.joined(separator: "\n") + "\n"
    }

    public static func write(_ desks: [Desk], theme: ThemeSettings?, to path: String) {
        var head: String
        if let theme {
            // Keep every other non-desk table, dropping only the one being
            // replaced, then append the new one.
            let others = preservedTables(from: path, dropping: ["[theme]"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let table = themeTable(theme)
            head = others.isEmpty ? table
                 : (table.isEmpty ? others : others + "\n\n" + table)
        } else {
            // No new theme: keep whatever the file already had, untouched.
            head = preservedTables(from: path)
        }
        writeBody(desks, head: head, to: path)
    }

    public static func write(_ desks: [Desk], theme: ThemeSettings?) {
        write(desks, theme: theme, to: path)
    }

    static let header = "# Project Coldfall desks. Written by Project Coldfall; safe to edit by hand."

    /// A header line this writer, or an older one, put at the top of the file.
    static func isHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("#") && t.contains(" desks. Written by ") && t.hasSuffix("safe to edit by hand.")
    }

    private static func writeBody(_ desks: [Desk], head: String, to path: String) {
        var out = header + "\n"
        // The kept head starts with the header from the last save, and older
        // builds wrote their own under the old name. Drop those rather than
        // stacking one more copy on every save.
        let head = head.components(separatedBy: "\n")
            .filter { !isHeader($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { out += "\n" + head + "\n" }
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
            if let m = d.model { out += "model = \"\(TomlText.escape(m))\"\n" }
            if let s = d.session { out += "session = \"\(TomlText.escape(s))\"\n" }
            if d.hidden { out += "hidden = true\n" }
            if !d.mcpOff.isEmpty {
                out += "mcp_off = [" + d.mcpOff.map { "\"\(TomlText.escape($0))\"" }.joined(separator: ", ") + "]\n"
            }
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
