import Foundation

/// Hosts from ~/.ssh/config, offered as desks.
///
/// A remote box is exactly what a desk is for — something you come back to,
/// that holds state between visits. It needed no new concept, only discovery,
/// the same pattern that already works for agents.
///
/// The parser is deliberately small. Host blocks and a few keys are all that is
/// needed to build an `ssh` command; everything else is ssh's business and
/// passing the alias lets ssh apply the rest of the config itself.
public struct SSHHost {
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: String?

    public init(alias: String, hostName: String?, user: String?, port: String?) {
        self.alias = alias; self.hostName = hostName; self.user = user; self.port = port
    }

    /// Always connect by ALIAS. ssh then applies identity files, jump hosts and
    /// anything else in the config that this parser deliberately ignores.
    public var command: String { "ssh -t \(alias)" }

    public var blurb: String {
        var s = hostName ?? alias
        if let u = user { s = "\(u)@\(s)" }
        if let p = port, p != "22" { s += ":\(p)" }
        return s
    }
}

public enum SSHHosts {

    public static var configPath: String {
        NSString(string: "~/.ssh/config").expandingTildeInPath
    }

    public static func all() -> [SSHHost] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        var out: [SSHHost] = []
        var alias: String?
        var hostName: String?, user: String?, port: String?

        func flush() {
            guard let a = alias else { return }
            // Wildcards are defaults, not destinations.
            if !a.contains("*") && !a.contains("?") {
                out.append(SSHHost(alias: a, hostName: hostName, user: user, port: port))
            }
            alias = nil; hostName = nil; user = nil; port = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            line = TomlText.stripComment(line)
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]

            switch key {
            case "host":
                flush()
                // `Host a b` declares aliases; the first is enough to connect.
                alias = value.split(separator: " ").first.map(String.init)
            case "hostname": hostName = value
            case "user":     user = value
            case "port":     port = value
            default: break
            }
        }
        flush()
        return out.sorted { $0.alias < $1.alias }
    }

    /// Hosts with no desk yet — the only ones worth offering.
    public static func undesked(desks: [Desk]) -> [SSHHost] {
        let taken = Set(desks.map(\.name) + desks.compactMap(\.command))
        return all().filter { h in
            !taken.contains(h.alias) && !taken.contains(where: { $0.contains("ssh -t \(h.alias)") })
        }
    }

    public static func desk(from h: SSHHost) -> Desk {
        // cwd is local and irrelevant once ssh takes over, but it has to be
        // somewhere that exists.
        Desk(name: h.alias, cwd: NSHomeDirectory(), command: h.command, group: "remote")
    }
}
