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
//   coldfall-cli inventory <desk> a desk's MCP servers, hooks, skills, plugins
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

case "menu":
    // The right-click menu for a desk, as data. Here because a context menu
    // cannot be captured in an offscreen snapshot, and its order and wording
    // are the part that matters.
    let name = args.count > 1 ? args[1] : nil
    let d = name.flatMap { n in DeskConfig.load().first { $0.name == n } } ?? Desk(name: "example")
    out(DeskMenu.items(runtime: d.runtime, running: true, hidden: d.hidden,
                       canReveal: d.agent != nil, canMakeDefault: !d.isDefault,
                       hasInventory: d.runtime != "shell", hasMcp: ["claude", "codex"].contains(d.runtime))
        .map { e -> [String: Any] in
            var o: [String: Any] = ["action": e.action.rawValue, "title": e.title]
            if let s = e.subtitle { o["subtitle"] = s }
            if let s = e.symbol { o["symbol"] = s }
            o["tone"] = e.tone == .danger ? "danger" : (e.tone == .caution ? "caution" : "normal")
            return o
        })

case "tokenomics":
    // Where the week went, and what to change. The same reading the usage
    // panel shows, as data.
    var tdays = 7
    if let i = args.firstIndex(of: "--days"), args.count > i + 1, let n = Int(args[i + 1]) { tdays = n }
    let tsince = tdays == 7 ? Usage.weekStart() : Date().addingTimeInterval(-Double(tdays) * 86_400)
    let t = Tokenomics.scan(since: tsince, accounts: ClaudeAccount.known())
    var counts: [String: Int] = [:]
    for d in DeskConfig.load() where d.runtime != "shell" {
        let n = Inventory.of(d).mcp.filter { !$0.off }.count
        if n > 0 { counts[d.name] = n }
    }
    out([
        "since": ISO8601DateFormatter().string(from: tsince),
        "turns": t.all.turns,
        "freshPct": Int((t.freshShare * 100).rounded()),
        "cacheReadPct": Int((t.cacheReadShare * 100).rounded()),
        "usd": t.all.usd,
        "usdOnSonnet": t.savingsOnSonnet(),
        "modelMix": t.modelMix.map { ["model": $0.model, "pct": Int($0.share * 100)] },
        "byDesk": t.byDesk.mapValues {
            ["turns": $0.turns, "perTurn": Int($0.perTurn), "usd": $0.usd, "floor": $0.floor]
        },
        "notes": t.notes(servers: counts).map {
            ["kind": $0.kind.rawValue, "finding": $0.finding, "advice": $0.advice, "measured": $0.measured]
        },
    ])

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
    let r = Usage.scan(since: since, accounts: ClaudeAccount.known())
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

case "inventory":
    guard args.count > 1, let d = DeskConfig.load().first(where: { $0.name == args[1] }) else {
        print("usage: coldfall-cli inventory <desk>"); exit(1)
    }
    let inv = Inventory.of(d)
    func items(_ xs: [Inventory.Item]) -> [[String: Any]] {
        xs.map { ["name": $0.name, "detail": $0.detail, "source": $0.source, "off": $0.off] }
    }
    out(["desk": d.name, "mcp": items(inv.mcp), "hooks": items(inv.hooks), "skills": items(inv.skills),
         "plugins": items(inv.plugins), "notes": inv.notes, "seen": inv.seen,
         "changes": InventorySeen.load(d.name).map { before -> [String: Any] in
             let c = inv.changes(since: before)
             return ["added": c.added.sorted().map(Inventory.label), "updated": c.updated.keys.sorted().map(Inventory.label),
                     "removed": c.removed]
         } ?? NSNull()])

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
        "inventorySeen": InventorySeen.root + "/<desk>.json",
    ])

default:
    print("""
    coldfall-cli — ColdfallCore, headless

      desks              configured desks and how each launches
      agents [dir]       agent definitions on disk that could become desks
      hosts              ssh hosts that could become desks
      inventory <desk>   its MCP servers, hooks, skills and plugins, and what changed
      limits             remaining quota per vendor, stale entries dropped
      usage [--days N]   consumption by vendor and by desk (default: this week)
      formats            where every file Project Coldfall reads or writes lives

    Everything is JSON on stdout. A front end in any language can use this
    instead of reimplementing the core.
    """)
}
