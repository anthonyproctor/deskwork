// What a desk has: its MCP servers, skills, plugins and hooks.
//
// Four different things, and people meet them mixed together:
//
//   MCP server  a separate program giving the agent tools. Costs memory while
//               the desk runs. An open standard every vendor supports.
//   skill       a folder of instructions, read only when a task calls for it.
//   plugin      a vendor's package that can carry skills, hooks and servers.
//   hook        a command the vendor runs by itself on an event (session
//               start, every tool call...). The one kind that acts without
//               being asked, so it is listed on its own.
//
// Everything here is read from files on this Mac and nothing is changed. Each
// vendor keeps these in its own places; the reader for a vendor that is not
// installed simply finds nothing. claude.ai connectors live on the account,
// not on disk, so they are mentioned rather than listed.

import Foundation

public struct Inventory: Equatable {

    public struct Item: Equatable {
        public let name: String
        /// One line on what it is or does.
        public let detail: String
        /// Where it comes from: this folder, you (every folder), a plugin.
        public let source: String
        /// Switched off for this desk (see McpTrim).
        public var off: Bool = false
        public init(name: String, detail: String, source: String, off: Bool = false) {
            self.name = name; self.detail = detail; self.source = source; self.off = off
        }
    }

    public var mcp: [Item] = []
    public var skills: [Item] = []
    public var plugins: [Item] = []
    public var hooks: [Item] = []
    /// Things worth saying that are not items, e.g. the claude.ai connectors.
    public var notes: [String] = []

    public init() {}

    public var isEmpty: Bool { mcp.isEmpty && skills.isEmpty && plugins.isEmpty && hooks.isEmpty }

    /// What `desk` has, read from `home` (overridable for tests).
    public static func of(_ desk: Desk, home: String = NSHomeDirectory()) -> Inventory {
        switch desk.runtime {
        case "claude": return claude(cwd: desk.resolvedCwd, home: home, off: desk.mcpOff)
        case "codex":  return codex(cwd: desk.resolvedCwd, home: home)
        case "gemini": return gemini(home: home)
        default:
            var i = Inventory()
            i.notes.append(desk.runtime == "shell"
                ? "A plain shell. No agent, so no servers, skills or hooks."
                : "Coldfall doesn't read \(desk.runtime)'s configuration yet.")
            return i
        }
    }

    // MARK: - Claude

    static func claude(cwd: String, home: String, off: [String]) -> Inventory {
        var inv = Inventory()
        let claudeDir = (home as NSString).appendingPathComponent(".claude")
        let projectClaude = (cwd as NSString).appendingPathComponent(".claude")
        let here = "this folder", you = "you, every folder"

        // MCP servers
        for (name, cfg) in servers(json(at: (cwd as NSString).appendingPathComponent(".mcp.json"))) {
            inv.mcp.append(Item(name: name, detail: serverDetail(cfg), source: here, off: off.contains(name)))
        }
        let claudeJSON = json(at: (home as NSString).appendingPathComponent(".claude.json"))
        for (name, cfg) in servers(claudeJSON) {
            inv.mcp.append(Item(name: name, detail: serverDetail(cfg), source: you))
        }
        if let projects = claudeJSON?["projects"] as? [String: Any], let p = projects[cwd] as? [String: Any] {
            for (name, cfg) in servers(p) {
                inv.mcp.append(Item(name: name, detail: serverDetail(cfg), source: "this folder, in Claude's settings"))
            }
        }

        // Skills
        inv.skills += skills(in: (projectClaude as NSString).appendingPathComponent("skills"), source: here)
        inv.skills += skills(in: (claudeDir as NSString).appendingPathComponent("skills"), source: you)

        // Hooks, from each settings file that applies to this folder
        for (file, source) in [((claudeDir as NSString).appendingPathComponent("settings.json"), you),
                               ((projectClaude as NSString).appendingPathComponent("settings.json"), here),
                               ((projectClaude as NSString).appendingPathComponent("settings.local.json"), here + ", local")] {
            inv.hooks += hooks(json(at: file), source: source)
        }

        // Plugins: enabled in any of those settings, installed under ~/.claude/plugins.
        var enabled: [String] = []
        for file in [(claudeDir as NSString).appendingPathComponent("settings.json"),
                     (projectClaude as NSString).appendingPathComponent("settings.json"),
                     (projectClaude as NSString).appendingPathComponent("settings.local.json")] {
            for (k, v) in (json(at: file)?["enabledPlugins"] as? [String: Any]) ?? [:] {
                if (v as? Bool) == true { enabled.append(k) } else { enabled.removeAll { $0 == k } }
            }
        }
        let installed = (json(at: (claudeDir as NSString).appendingPathComponent("plugins/installed_plugins.json"))?["plugins"]
                         as? [String: Any]) ?? [:]
        for key in Array(Set(enabled)).sorted() {
            let short = String(key.split(separator: "@").first ?? Substring(key))
            let from = "plugin \(short)"
            guard let entries = installed[key] as? [[String: Any]],
                  let path = entries.last?["installPath"] as? String else {
                inv.plugins.append(Item(name: short, detail: "enabled but not found on disk", source: key))
                continue
            }
            let version = entries.last?["version"] as? String
            let pSkills = skills(in: (path as NSString).appendingPathComponent("skills"), source: from)
            let pHooks = hooks(json(at: (path as NSString).appendingPathComponent("hooks/hooks.json")), source: from)
            let pServers = servers(json(at: (path as NSString).appendingPathComponent(".mcp.json")))
            var parts: [String] = []
            if !pSkills.isEmpty { parts.append(count(pSkills.count, "skill")) }
            if !pHooks.isEmpty { parts.append(count(pHooks.count, "hook")) }
            if !pServers.isEmpty { parts.append(count(pServers.count, "MCP server")) }
            inv.plugins.append(Item(name: short, detail: (version.map { "v\($0)" } ?? "installed")
                                    + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")), source: key))
            inv.skills += pSkills
            inv.hooks += pHooks
            for (name, cfg) in pServers { inv.mcp.append(Item(name: name, detail: serverDetail(cfg), source: from)) }
        }

        inv.notes.append("Plus any claude.ai connectors on your account (Gmail, Drive and so on). "
                         + "Those run on Anthropic's side and aren't stored on this Mac.")
        return inv
    }

    // MARK: - Codex

    static func codex(cwd: String, home: String) -> Inventory {
        var inv = Inventory()
        let codexDir = (home as NSString).appendingPathComponent(".codex")
        if let toml = try? String(contentsOfFile: (codexDir as NSString).appendingPathComponent("config.toml"), encoding: .utf8) {
            var seen = Set<String>()
            for line in toml.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("[mcp_servers."), t.hasSuffix("]") else { continue }
                let name = t.dropFirst("[mcp_servers.".count).dropLast()
                    .split(separator: ".").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? ""
                if !name.isEmpty, seen.insert(name).inserted {
                    inv.mcp.append(Item(name: name, detail: "set up in Codex's config.toml", source: "you, every folder"))
                }
            }
        }
        inv.skills += skills(in: (codexDir as NSString).appendingPathComponent("skills"), source: "you, every folder")
        if FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent("AGENTS.md")) {
            inv.notes.append("Codex also reads AGENTS.md in this folder.")
        }
        return inv
    }

    // MARK: - Gemini

    static func gemini(home: String) -> Inventory {
        var inv = Inventory()
        let dir = (home as NSString).appendingPathComponent(".gemini")
        for (name, cfg) in servers(json(at: (dir as NSString).appendingPathComponent("settings.json"))) {
            inv.mcp.append(Item(name: name, detail: serverDetail(cfg), source: "you, every folder"))
        }
        let ext = (dir as NSString).appendingPathComponent("extensions")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: ext)) ?? []).sorted() where !name.hasPrefix(".") {
            inv.plugins.append(Item(name: name, detail: "Gemini extension", source: "you, every folder"))
        }
        return inv
    }

    // MARK: - reading

    static func json(at path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func servers(_ o: [String: Any]?) -> [(String, [String: Any])] {
        guard let s = o?["mcpServers"] as? [String: Any] else { return [] }
        return s.keys.sorted().map { ($0, (s[$0] as? [String: Any]) ?? [:]) }
    }

    /// "runs node", or "remote, mcp.vercel.com". A local one is a process on
    /// this Mac; a remote one is not.
    static func serverDetail(_ cfg: [String: Any]) -> String {
        if let url = cfg["url"] as? String {
            let host = URL(string: url)?.host ?? url
            return "remote, \(host)"
        }
        if let cmd = cfg["command"] as? String {
            return "runs \((cmd as NSString).lastPathComponent) on this Mac"
        }
        return "configured"
    }

    /// Skills under `dir`: each folder with a SKILL.md, one level down, or two
    /// for a folder of skill folders (as claude.ai sync leaves them).
    static func skills(in dir: String, source: String) -> [Item] {
        let fm = FileManager.default
        var out: [Item] = []
        for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !name.hasPrefix(".") {
            let sub = (dir as NSString).appendingPathComponent(name)
            let file = (sub as NSString).appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: file) {
                out.append(skillItem(file: file, fallback: name, source: source))
            } else {
                for inner in ((try? fm.contentsOfDirectory(atPath: sub)) ?? []).sorted() where !inner.hasPrefix(".") {
                    let f = ((sub as NSString).appendingPathComponent(inner) as NSString).appendingPathComponent("SKILL.md")
                    if fm.fileExists(atPath: f) { out.append(skillItem(file: f, fallback: inner, source: source)) }
                }
            }
        }
        return out
    }

    static func skillItem(file: String, fallback: String, source: String) -> Item {
        let head = (try? String(contentsOfFile: file, encoding: .utf8)).map { String($0.prefix(4000)) } ?? ""
        let (name, description) = frontmatter(head)
        return Item(name: name ?? fallback, detail: description.map { short($0) } ?? "", source: source)
    }

    /// `name:` and `description:` from a SKILL.md's frontmatter.
    static func frontmatter(_ text: String) -> (String?, String?) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?, desc: String?
        for l in lines.dropFirst() {
            if l.trimmingCharacters(in: .whitespaces) == "---" { break }
            func value(_ key: String) -> String? {
                guard l.hasPrefix(key + ":") else { return nil }
                let v = l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if let v = value("name"), !v.isEmpty { name = v }
            if let v = value("description"), !v.isEmpty { desc = v }
        }
        return (name, desc)
    }

    /// Hooks in a settings or hooks.json object: one item per command, named
    /// by the event that runs it.
    static func hooks(_ o: [String: Any]?, source: String) -> [Item] {
        guard let h = o?["hooks"] as? [String: Any] else { return [] }
        var out: [Item] = []
        for event in h.keys.sorted() {
            for group in (h[event] as? [[String: Any]]) ?? [] {
                let matcher = (group["matcher"] as? String).flatMap { $0.isEmpty || $0 == "*" ? nil : $0 }
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    let cmd = (hook["command"] as? String) ?? (hook["type"] as? String) ?? "?"
                    out.append(Item(name: event + (matcher.map { " (\($0))" } ?? ""),
                                    detail: short(commandName(cmd), 90), source: source))
                }
            }
        }
        return out
    }

    /// The script a hook command runs, not its whole invocation:
    /// `node "${CLAUDE_PLUGIN_ROOT}/hooks/telemetry.mjs" --x` -> telemetry.mjs.
    static func commandName(_ cmd: String) -> String {
        let words = cmd.split(whereSeparator: { $0 == " " }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        let runners: Set<String> = ["node", "bun", "python", "python3", "bash", "sh", "zsh", "npx", "uvx", "deno"]
        let pick = words.first { w in
            let base = (w as NSString).lastPathComponent
            return !w.hasPrefix("-") && !runners.contains(base) && !w.contains("=")
        } ?? words.first ?? cmd
        return (pick as NSString).lastPathComponent
    }

    static func short(_ s: String, _ n: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count <= n ? one : String(one.prefix(n - 1)) + "…"
    }

    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}
