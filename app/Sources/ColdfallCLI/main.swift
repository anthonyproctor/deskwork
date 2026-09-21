// coldfall-cli — the core, headless.
//
// Two jobs. It proves ColdfallCore carries no UI dependency, because this
// binary links nothing but Foundation. And it gives a front end written in any
// language something to shell out to, so porting Coldfall does not mean
// reimplementing desk discovery, usage scanning or quota reading.
//
//   coldfall-cli desks            configured desks
//   coldfall-cli limits           remaining quota, per vendor
//   coldfall-cli usage [--days N] consumption by vendor and desk
//   coldfall-cli formats          where everything lives on disk
import Foundation
import ColdfallCore

// Same migration as the app, so the CLI never reads an empty new path first.
Migration.runAll()

func out(_ any: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: any,
                                           options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "help" {

case "desks":
    out(DeskConfig.load().map { d -> [String: Any] in
        var o: [String: Any] = ["name": d.name, "runtime": d.runtime, "cwd": d.resolvedCwd]
        if let g = d.group { o["group"] = g }
        if let a = d.agent { o["agent"] = a }
        o["launch"] = d.launchCommand()
        return o
    })

case "limits":
    out(Limits.all().map { l -> [String: Any] in
        var o: [String: Any] = ["vendor": l.vendor, "ageSeconds": Int(l.age)]
        if let w = l.liveWeekPct { o["weekPct"] = w }
        if let r = l.weekResetsAt { o["weekResetsAt"] = r }
        if let h = l.liveFiveHourPct { o["fiveHourPct"] = h }
        if let p = l.planType { o["plan"] = p }
        return o
    })

case "usage":
    var days = 7
    if let i = args.firstIndex(of: "--days"), args.count > i + 1, let n = Int(args[i + 1]) { days = n }
    let since = days == 7 ? Usage.weekStart()
                          : Date().addingTimeInterval(-Double(days) * 86_400)
    let r = Usage.scan(since: since)
    out([
        "since": ISO8601DateFormatter().string(from: since),
        "byVendor": r.byVendor.mapValues { ["tokens": $0.tokens, "calls": $0.calls, "usd": $0.usd ?? 0] },
        "byDesk": r.byDesk.mapValues { ["tokens": $0.tokens, "calls": $0.calls, "usd": $0.usd ?? 0] },
        "routerHint": Usage.routerHint(r) ?? "",
    ])

case "agents":
    let dir = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
    out(Discovery.agents(in: dir).map { a -> [String: Any] in
        var o: [String: Any] = ["name": a.name, "runtime": a.runtime,
                                "path": a.path, "scope": a.isProjectLevel ? "project" : "user"]
        if let m = a.model { o["model"] = m }
        o["blurb"] = a.blurb
        return o
    })

case "hosts":
    out(SSHHosts.all().map { ["alias": $0.alias, "target": $0.blurb, "command": $0.command] })

case "formats":
    out([
        "desks":    DeskConfig.path,
        "bridge":   Mailbox.configPath,
        "limits":   Limits.dir + "/<vendor>.json",
        "sessions": DeskState.dir + "/<desk>.json",
        "mail":     Mailbox.load().dir + "/thread-<a>-<b>.md",
        "uiState":  UIState.path,
    ])

default:
    print("""
    coldfall-cli — ColdfallCore, headless

      desks              configured desks and how each launches
      agents [dir]       agent definitions on disk that could become desks
      hosts              ssh hosts that could become desks
      limits             remaining quota per vendor, stale entries dropped
      usage [--days N]   consumption by vendor and by desk (default: this week)
      formats            where every file Project Coldfall reads or writes lives

    Everything is JSON on stdout. A front end in any language can use this
    instead of reimplementing the core.
    """)
}
