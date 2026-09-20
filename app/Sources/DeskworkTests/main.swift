import Foundation
import DeskworkCore

// Regression tests for faults that actually shipped today, not invented cases.
// Each one names the bug it stops coming back.
//
// Deliberately not XCTest: that ships with Xcode, and this project builds on
// Command Line Tools alone. A test suite that reintroduces a 15GB dependency
// defeats the point.

var failures: [String] = []
var passed = 0

func check(_ name: String, _ cond: @autoclosure () -> Bool, _ note: String = "") {
    if cond() { passed += 1; print("  ok    \(name)") }
    else { failures.append(name + (note.isEmpty ? "" : " — " + note)); print("  FAIL  \(name)") }
}

func eq<T: Equatable>(_ name: String, _ a: T?, _ b: T?) {
    if a == b { passed += 1; print("  ok    \(name)") }
    else {
        failures.append("\(name) — got \(String(describing: a)), wanted \(String(describing: b))")
        print("  FAIL  \(name): got \(String(describing: a)), wanted \(String(describing: b))")
    }
}

func parse(_ toml: String) -> [Desk] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml")
    try? toml.write(to: f, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: dir) }
    return DeskConfig.load(path: f.path)
}

print("\nconfig parsing")

// A desk running a bare shell was labelled claude, so it could be chosen as
// the claude home — meaning "Manage" would type /agents at a zsh prompt.
eq("bare command is shell, not claude",
   parse("[desk.shell]\ncommand = \"exec zsh -l\"\n").first?.runtime, "shell")

eq("declared runtime survives a command",
   parse("[desk.m]\nruntime = \"claude\"\ncommand = \"~/bin/desk m\"\n").first?.runtime, "claude")

// A shell is nobody's home; routing into one produces nonsense.
check("a shell is never a home",
      DeskConfig.general(for: "shell",
                         in: parse("[desk.s]\ncommand = \"exec zsh -l\"\n")) == nil)

let two = parse("""
[desk.a]
runtime = "claude"

[desk.b]
runtime = "claude"
default = true
""")
eq("explicit home beats first match",
   DeskConfig.general(for: "claude", in: two).map { two[$0].name }, "b")

let both = parse("""
[desk.c]
runtime = "claude"
default = true

[desk.x]
runtime = "codex"
default = true
""")
eq("claude home", DeskConfig.general(for: "claude", in: both).map { both[$0].name }, "c")
eq("codex home, independently", DeskConfig.general(for: "codex", in: both).map { both[$0].name }, "x")

print("\ndefault runtime (was hardcoded to claude)")

eq("follows the majority",
   DeskConfig.preferredRuntime(given: [Desk(name: "a", runtime: "codex"),
                                       Desk(name: "b", runtime: "codex"),
                                       Desk(name: "c", runtime: "claude")]), "codex")

eq("shells do not get a vote",
   DeskConfig.preferredRuntime(given: [Desk(name: "s", runtime: "shell"),
                                       Desk(name: "t", runtime: "shell"),
                                       Desk(name: "g", runtime: "grok")]), "grok")

print("\nlaunch commands")

let api = parse("[desk.api]\ngroup = \"work\"\nruntime = \"claude\"\nagent = \"backend\"\n")
eq("group stays presentation only", api.first?.group, "work")
eq("claude agent launch", api.first?.launchCommand(), "claude --agent backend -n api")

// -p and --agent are different flags; confusing them yields a command that
// does not run.
let prof = Discovery.desk(
    from: DiscoveredAgent(name: "review", runtime: "codex", description: "codex profile",
                          model: nil, path: "/tmp/c.toml", isProjectLevel: false),
    cwd: "/tmp")
eq("codex profile uses -p", prof.command, "codex -p review")
check("codex profile sets no agent field", prof.agent == nil)

print("\nfront matter")

let fm = Discovery.frontMatter("""
---
name: golf-caddie
description: "Uses data: launch monitors, and more"
model: sonnet
---
body
""")
eq("name", fm["name"], "golf-caddie")
eq("model", fm["model"], "sonnet")
// Splitting on every colon mangles real descriptions.
eq("splits on the first colon only", fm["description"], "Uses data: launch monitors, and more")
check("no front matter is empty, not a crash", Discovery.frontMatter("plain text").isEmpty)

print("\nquota windows")

// A window whose reset has passed is from a dead cycle: dropping it is right.
// An old-but-live reading is not, and hiding those made idle vendors vanish —
// which is backwards, since an idle vendor is the one with headroom.
let past = VendorLimits(vendor: "x", weekPct: 50, weekResetsAt: Date().timeIntervalSince1970 - 60,
                        fiveHourPct: nil, fiveHourResetsAt: nil, planType: nil,
                        at: Date().timeIntervalSince1970)
check("rolled-over window is dropped", past.liveWeekPct == nil)

let live = VendorLimits(vendor: "x", weekPct: 50, weekResetsAt: Date().timeIntervalSince1970 + 3600,
                        fiveHourPct: nil, fiveHourResetsAt: nil, planType: nil,
                        at: Date().timeIntervalSince1970 - 7200)
eq("two-hour-old live reading still counts", live.liveWeekPct, 50)
check("and is usable", live.isUsable)
check("and is labelled stale", live.ageLabel != nil)

let ancient = VendorLimits(vendor: "x", weekPct: 50, weekResetsAt: Date().timeIntervalSince1970 + 3600,
                           fiveHourPct: nil, fiveHourResetsAt: nil, planType: nil,
                           at: Date().timeIntervalSince1970 - 90_000)
check("a day-old reading is not usable", !ancient.isUsable)

print("\nconfig text handling  (found by codex reviewing these tests)")

// The parser cut at the first # regardless of quoting, so a command with a #
// in it was silently truncated — it still ran, just doing something else.
eq("a # inside a quoted value survives",
   parse("[desk.t]\ncommand = \"git log --grep=#123 --oneline\"\n").first?.command,
   "git log --grep=#123 --oneline")

eq("a real trailing comment is still stripped",
   parse("[desk.t]\nruntime = \"codex\"   # the home\n").first?.runtime, "codex")

check("stripComment leaves a bare line alone",
      TomlText.stripComment("runtime = \"claude\"") == "runtime = \"claude\"")
check("stripComment removes an unquoted comment",
      TomlText.stripComment("a = 1 # note").trimmingCharacters(in: .whitespaces) == "a = 1")

// Writing an unescaped quote produced a file that no longer parsed, quietly
// corrupting the source of truth on the next save.
eq("quotes survive an escape round trip",
   TomlText.unescape(TomlText.escape("say \"hi\" now")), "say \"hi\" now")
eq("backslashes survive too",
   TomlText.unescape(TomlText.escape("C:\\path\\to")), "C:\\path\\to")

// The write -> load round trip was never tested at all.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    let awkward = [
        Desk(name: "hash", runtime: "claude", cwd: "~", command: "echo \"#prod\" && ls"),
        Desk(name: "plain", agent: "backend", runtime: "claude", cwd: "~/src", group: "work"),
    ]
    DeskConfig.write(awkward, to: f)
    let back = DeskConfig.load(path: f)
    eq("round trip keeps the count", back.count, 2)
    eq("round trip keeps a # inside quotes", back.first?.command, "echo \"#prod\" && ls")
    eq("round trip keeps the agent", back.last?.agent, "backend")
    eq("round trip keeps the group", back.last?.group, "work")
    try? FileManager.default.removeItem(at: dir)
}

// Weak assertion called out in review: check the label, not just that one exists.
do {
    let twoHours = VendorLimits(vendor: "x", weekPct: 10,
                                weekResetsAt: Date().timeIntervalSince1970 + 3600,
                                at: Date().timeIntervalSince1970 - 7200)
    eq("stale label reads in hours", twoHours.ageLabel, "2h ago")
    let fortyMin = VendorLimits(vendor: "x", weekPct: 10,
                                weekResetsAt: Date().timeIntervalSince1970 + 3600,
                                at: Date().timeIntervalSince1970 - 2400)
    eq("stale label reads in minutes", fortyMin.ageLabel, "40m ago")
}

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
    print("\nfailures:")
    failures.forEach { print("  " + $0) }
    exit(1)
}
