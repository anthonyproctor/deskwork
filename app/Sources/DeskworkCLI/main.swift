// deskwork-cli — the core, headless.
//
// Two jobs. It proves DeskworkCore carries no UI dependency, because this
// binary links nothing but Foundation. And it gives a front end written in any
// language something to shell out to, so porting Deskwork does not mean
// reimplementing desk discovery, usage scanning or quota reading.
//
//   deskwork-cli desks            configured desks
//   deskwork-cli limits           remaining quota, per vendor
//   deskwork-cli usage [--days N] consumption by vendor and desk
//   deskwork-cli formats          where everything lives on disk
import Foundation
import DeskworkCore

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
    deskwork-cli — DeskworkCore, headless

      desks              configured desks and how each launches
      limits             remaining quota per vendor, stale entries dropped
      usage [--days N]   consumption by vendor and by desk (default: this week)
      formats            where every file Deskwork reads or writes lives

    Everything is JSON on stdout. A front end in any language can use this
    instead of reimplementing the core.
    """)
}
