// Switching MCP servers off for one desk.
//
// Every Claude desk starts every MCP server its folder configures, each as its
// own process, which is most of the gigabyte a desk holds. A desk that never
// reads mail should not pay for a mail server.
//
// Claude has two ways to narrow this, and only one is safe. `--strict-mcp-config`
// with a list keeps ONLY the listed servers, and measured on a real desk it
// also dropped the claude.ai connectors (Gmail, Drive, Calendar) and every
// plugin's server. Passing `--settings '{"disabledMcpjsonServers":[...]}'`
// switches off just the named servers from the folder's .mcp.json and leaves
// everything else alone. Those .mcp.json servers are the local, heavy ones, so
// that is what a desk can trim.
//
// The desk records what is OFF, not what is on: a server added to .mcp.json
// later is on for every desk until someone switches it off, which is how it
// behaved before trimming existed.

import Foundation

public enum McpTrim {

    /// Handed to a desk's own command (a wrapper script), which passes it to
    /// Claude as `--settings "$COLDFALL_CLAUDE_SETTINGS"`. Coldfall cannot add
    /// flags to a command it does not build.
    public static let envKey = "COLDFALL_CLAUDE_SETTINGS"

    /// Server names are written into a shell command, so only the characters
    /// a name needs are allowed through.
    public static func validName(_ n: String) -> Bool {
        !n.isEmpty && n.count <= 64 && n.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// The servers a desk can trim: those in its folder's .mcp.json.
    public static func servers(cwd: String) -> [String] {
        let path = (cwd as NSString).appendingPathComponent(".mcp.json")
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = o["mcpServers"] as? [String: Any] else { return [] }
        return s.keys.filter(validName).sorted()
    }

    /// The servers `desk` can trim, by vendor: Claude's from the folder's
    /// .mcp.json, Codex's from its config.toml. Other vendors: none yet.
    public static func servers(for desk: Desk, home: String = NSHomeDirectory()) -> [String] {
        switch desk.runtime {
        case "claude": return servers(cwd: desk.resolvedCwd)
        case "codex":  return Inventory.codex(cwd: desk.resolvedCwd, home: home).mcp.map(\.name).filter(validName).sorted()
        default:       return []
        }
    }

    /// Codex's way: one `-c mcp_servers.<name>.enabled=false` per server,
    /// checked to switch off only that one. Quoted for the shell; names are
    /// already restricted to characters that need no escaping.
    public static func codexArgs(off: [String]) -> [String] {
        Array(Set(off.filter(validName))).sorted().flatMap { ["-c", "'mcp_servers.\($0).enabled=false'"] }
    }

    /// Claude settings that switch `off` off, or nil when nothing is.
    public static func settingsJSON(off: [String]) -> String? {
        let names = Array(Set(off.filter(validName))).sorted()
        guard !names.isEmpty,
              let d = try? JSONSerialization.data(withJSONObject: ["disabledMcpjsonServers": names], options: [.sortedKeys])
        else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Whether a desk's own command will pass the setting on. Looks for the
    /// variable's name in the script it runs; a command that is not a
    /// readable file cannot be checked and is treated as not passing it.
    public static func commandHonors(_ command: String) -> Bool {
        guard let first = command.split(separator: " ").first else { return false }
        let path = NSString(string: String(first)).expandingTildeInPath
        guard let d = FileManager.default.contents(atPath: path), d.count < 1_000_000 else { return false }
        return String(decoding: d, as: UTF8.self).contains(envKey)
    }
}

extension TomlText {
    /// `["a", "b"]` into ["a", "b"]. Strings only, which is all desks.toml
    /// needs; anything else is nil rather than a guess.
    public static func stringArray(_ raw: String) -> [String]? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = t.dropFirst().dropLast()
        var out: [String] = [], cur = "", inString = false, escaped = false
        for ch in inner {
            if inString {
                if escaped { cur.append("\\"); cur.append(ch); escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { out.append(unescape(cur)); cur = ""; inString = false }
                else { cur.append(ch) }
            } else if ch == "\"" { inString = true }
            else if ch == "," || ch == " " || ch == "\t" { continue }
            else { return nil }
        }
        return inString ? nil : out
    }
}
