import Foundation

/// Find agents that already exist on disk and could become desks.
///
/// Creating an agent should surface a desk. Every vendor keeps its agent
/// definitions as markdown with YAML front matter, in a known place, so this
/// needs no API and no vendor cooperation:
///
///   claude   <project>/.claude/agents/*.md        and ~/.claude/agents/*.md
///   copilot  <project>/.github/agents/*.agent.md
///
/// Front matter is read with a deliberately small parser. These files are
/// hand-written and the only fields that matter here are `name`, `description`
/// and `model`; anything else is the vendor's business, not Deskwork's.
public struct DiscoveredAgent {
    public let name: String
    public let runtime: String
    public let description: String?
    public let model: String?
    public let path: String
    /// Project-level agents belong to one workspace; user-level ones are global.
    public let isProjectLevel: Bool

    public init(name: String, runtime: String, description: String?, model: String?,
                path: String, isProjectLevel: Bool) {
        self.name = name; self.runtime = runtime; self.description = description
        self.model = model; self.path = path; self.isProjectLevel = isProjectLevel
    }

    /// A one-line summary for a list. Agent descriptions run to paragraphs.
    public var blurb: String {
        guard let d = description else { return path }
        let first = d.replacingOccurrences(of: "\\n", with: " ")
            .split(separator: ".").first.map(String.init) ?? d
        let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 110 ? String(t.prefix(107)) + "…" : t
    }
}

public enum Discovery {

    /// Codex has no agent DEFINITIONS. Its `agents` subcommand browses running
    /// sessions, and what it actually offers is profiles: named config bundles
    /// in ~/.codex/config.toml selected with -p. Different concept, same role —
    /// a named way of running the CLI — so they are discovered as desks too,
    /// and labelled honestly as profiles rather than pretending otherwise.
    public static func codexProfiles() -> [DiscoveredAgent] {
        let path = NSString(string: "~/.codex/config.toml").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [DiscoveredAgent] = []
        var name: String?
        var model: String?
        func flush() {
            if let n = name {
                out.append(DiscoveredAgent(name: n, runtime: "codex",
                                           description: "codex profile",
                                           model: model, path: path, isProjectLevel: false))
            }
            name = nil; model = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            line = TomlText.stripComment(line)
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                // [profiles.<name>] — quoted or bare.
                if header.hasPrefix("profiles.") {
                    name = String(header.dropFirst("profiles.".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                continue
            }
            guard name != nil, let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if k == "model" {
                model = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        flush()
        return out.sorted { $0.name < $1.name }
    }

    public static func agents(in projectDir: String) -> [DiscoveredAgent] {
        var out: [DiscoveredAgent] = []
        let home = NSHomeDirectory()

        out += scan(dir: (projectDir as NSString).appendingPathComponent(".claude/agents"),
                    suffix: ".md", runtime: "claude", projectLevel: true)
        out += scan(dir: (home as NSString).appendingPathComponent(".claude/agents"),
                    suffix: ".md", runtime: "claude", projectLevel: false)
        out += scan(dir: (projectDir as NSString).appendingPathComponent(".github/agents"),
                    suffix: ".agent.md", runtime: "copilot", projectLevel: true)
        out += codexProfiles()

        // A project agent shadows a user one of the same name, which is how the
        // vendors resolve them too.
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.runtime)/\($0.name)").inserted }
    }

    /// Agents that have no desk yet — the only ones worth offering.
    public static func undeskedAgents(in projectDir: String, desks: [Desk]) -> [DiscoveredAgent] {
        let taken = Set(desks.compactMap { $0.agent } + desks.map { $0.name })
        return agents(in: projectDir).filter { !taken.contains($0.name) }
    }

    public static func desk(from a: DiscoveredAgent, cwd: String) -> Desk {
        // A codex profile is selected with -p, not --agent, so it cannot go in
        // the agent field without producing a command that does not work.
        if a.runtime == "codex" {
            return Desk(name: a.name, runtime: "codex", cwd: cwd,
                        command: "codex -p \(a.name)", group: "discovered")
        }
        return Desk(name: a.name, agent: a.name, runtime: a.runtime,
                    cwd: cwd, group: "discovered")
    }

    private static func scan(dir: String, suffix: String, runtime: String,
                             projectLevel: Bool) -> [DiscoveredAgent] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(suffix) }.compactMap { file in
            let path = (dir as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let fm = frontMatter(text)
            let fallback = String(file.dropLast(suffix.count))
            return DiscoveredAgent(name: fm["name"] ?? fallback,
                                   runtime: runtime,
                                   description: fm["description"],
                                   model: fm["model"],
                                   path: path,
                                   isProjectLevel: projectLevel)
        }.sorted { $0.name < $1.name }
    }

    /// Reads the leading `---` block. Values may be quoted and may contain
    /// colons, so the split is on the FIRST colon only.
    /// Public so it can be tested: front-matter parsing is exactly the kind of
    /// small thing that breaks quietly on a real file.
    public static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        for raw in lines.dropFirst() {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#"), !key.hasPrefix(" ") else { continue }
            var val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
            out[key] = val
        }
        return out
    }
}
