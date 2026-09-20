import Foundation

/// One persistent specialist. Sessions are disposable; this is not.
struct Desk {
    var name: String
    var agent: String?
    var runtime: String = "claude"
    var model: String?
    var cwd: String?
    var command: String?     // escape hatch: run this verbatim instead

    /// argv for the login shell. Deskwork never reimplements an agent — it
    /// launches the vendor's own CLI so that CLI's config, hooks, memory and
    /// model pins all apply untouched.
    func launchCommand() -> String {
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

    var resolvedCwd: String {
        (cwd.map { NSString(string: $0).expandingTildeInPath }) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

/// Just enough TOML for `[desk.<name>]` tables of `key = "value"`. A real parser
/// is a dependency we do not need yet, and the config shape is deliberately flat.
enum DeskConfig {
    static var path: String {
        NSString(string: "~/.config/deskwork/desks.toml").expandingTildeInPath
    }

    static func load() -> [Desk] {
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
            default: break
            }
        }
        if let d = current { desks.append(d) }
        return desks
    }
}
