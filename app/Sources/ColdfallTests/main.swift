import Foundation
import ColdfallCore

// Regression tests for faults that actually shipped today, not invented cases.
// Each one names the bug it stops coming back.
//
// Deliberately not XCTest: that ships with Xcode, and this project builds on
// Command Line Tools alone. A test suite that reintroduces a 15GB dependency
// defeats the point.

var failures: [String] = []
/// Whether a real usage cache existed before any test ran. Lets the final
/// check tell test pollution apart from the user's own data.
let preexistingCache = FileManager.default.fileExists(
    atPath: NSString(string: "~/.local/share/coldfall/cache/usage.json").expandingTildeInPath)
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

// MARK: - fan-out budget
//
// The point of pricing a fan-out is that it REFUSES. A budget check that only
// ever says yes is decoration, so these pin the boundaries in both directions.

do {
    let now = Date().timeIntervalSince1970
    func lim(_ v: String, _ week: Double) -> VendorLimits {
        VendorLimits(vendor: v, weekPct: week, weekResetsAt: now + 86_400, at: now)
    }

    // Plenty of room: quiet. The router says nothing when there is nothing to do.
    let easy = Fanout.budget(vendor: "claude", slices: 4, limits: [lim("claude", 5)])
    check("fan-out is allowed with room to spare", easy.allowsRun)
    eq("and says nothing about it", easy.advice, nil)

    // Nearly spent: refuse, and say why rather than failing silently.
    let broke = Fanout.budget(vendor: "claude", slices: 12, limits: [lim("claude", 97)])
    check("fan-out refuses when the week cannot pay for it", !broke.allowsRun)
    check("and the refusal explains itself", (broke.advice ?? "").contains("left"))

    // A vendor with real room: advise, never act. Moving work to another
    // company is a decision, so the verdict still allows the run.
    let split = Fanout.budget(vendor: "claude", slices: 3,
                              limits: [lim("claude", 60), lim("codex", 8)])
    check("a much emptier vendor is suggested", (split.advice ?? "").contains("codex"))
    check("but the run is still allowed", split.allowsRun)

    // A vendor only slightly emptier is NOT worth interrupting over.
    let close = Fanout.budget(vendor: "claude", slices: 3,
                              limits: [lim("claude", 40), lim("codex", 30)])
    eq("a marginally emptier vendor stays quiet", close.advice, nil)

    // No local quota (Gemini, Copilot) must not become a block. Punishing the
    // user for their vendor exposing nothing would be the wrong default.
    let blind = Fanout.budget(vendor: "gemini", slices: 8, limits: [])
    check("unknown quota allows the run", blind.allowsRun)

    // Stale data is not usable data: a reading from last week says nothing
    // about this week, and must not be treated as quota in hand.
    let old = VendorLimits(vendor: "claude", weekPct: 99, weekResetsAt: now + 86_400,
                           at: now - 200_000)
    check("a day-old reading is ignored rather than trusted",
       Fanout.budget(vendor: "claude", slices: 9, limits: [old]).allowsRun)

    // Cost scales with slices: the same vendor state must refuse more slices
    // than it allows, or the count is not actually in the arithmetic.
    let mid = lim("claude", 90)
    check("more slices cost more",
       Fanout.budget(vendor: "claude", slices: 2, limits: [mid]).allowsRun
       && !Fanout.budget(vendor: "claude", slices: 40, limits: [mid]).allowsRun)
}

// MARK: - desk activity badges
//
// "Finished" is inferred from output STOPPING, which has two failure modes
// pulling opposite ways: a short quiet window flickers "ready" mid-answer, a
// long one lags. These pin the boundaries and the clearing rule.

do {
    let t0 = Date()
    let quiet = ActivityState.quietFor

    // Output still arriving: working, not ready. A badge that says "done"
    // while the agent is mid-sentence is worse than no badge.
    var s = ActivityState()
    s.setVisible(false)
    s.noteOutput(at: t0)
    eq("output just now reads as working", s.activity(now: t0.addingTimeInterval(0.5)), .working)

    // Gone quiet while you were elsewhere: ready.
    eq("quiet after output reads as ready", s.activity(now: t0.addingTimeInterval(quiet + 0.1)), .ready)

    // The window is exclusive: at EXACTLY the boundary it has already flipped
    // to ready. Named for what it asserts — an earlier version of this test
    // said "still working" while asserting .ready, which is a suite that lies.
    eq("the boundary itself already reads as ready",
       s.activity(now: t0.addingTimeInterval(quiet)), .ready)
    eq("a hair before the boundary is still working",
       s.activity(now: t0.addingTimeInterval(quiet - 0.01)), .working)

    // Looking at a desk clears it, and it stays clear.
    var seen = ActivityState()
    seen.setVisible(false)
    seen.noteOutput(at: t0)
    seen.setVisible(true)
    eq("a desk you are looking at never badges", seen.activity(now: t0.addingTimeInterval(quiet + 5)), .quiet)
    seen.setVisible(false)
    eq("and stays clear after you leave it", seen.activity(now: t0.addingTimeInterval(quiet + 6)), .quiet)

    // Output while VISIBLE must not queue up a badge for later. You saw it.
    var watched = ActivityState()
    watched.setVisible(true)
    watched.noteOutput(at: t0)
    watched.setVisible(false)
    eq("output you watched arrive does not badge later",
       watched.activity(now: t0.addingTimeInterval(quiet + 1)), .quiet)

    // A desk that has never written anything has nothing to say.
    var fresh = ActivityState()
    fresh.setVisible(false)
    eq("a silent desk is quiet", fresh.activity(now: t0), .quiet)

    // New output after you have left re-arms it.
    var again = ActivityState()
    again.setVisible(true)
    again.noteOutput(at: t0)
    again.setVisible(false)
    again.noteOutput(at: t0.addingTimeInterval(10))
    eq("new output after leaving re-arms the badge",
       again.activity(now: t0.addingTimeInterval(10 + quiet + 0.1)), .ready)
}

// MARK: - saving desks must not eat the rest of the file
//
// write() rebuilds desks.toml from the desk list. Anything it does not know
// about was silently deleted, so changing one desk in Settings wiped [theme]
// — and would have wiped whatever section came next, too.

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    defer { try? FileManager.default.removeItem(at: dir) }

    try? """
    [theme]
    palette = "gruvbox"
    mode = "light"
    size = 16

    [future]
    # a section this writer has never heard of
    setting = "keep me"

    [desk.one]
    runtime = "claude"
    cwd = "~/src"
    """.write(toFile: f, atomically: true, encoding: .utf8)

    // Save with no theme given: everything non-desk survives untouched.
    DeskConfig.write(DeskConfig.load(path: f), to: f)
    let after = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    check("saving desks keeps the theme table", after.contains("palette = \"gruvbox\""))
    check("saving desks keeps a section the writer never heard of",
          after.contains("setting = \"keep me\""))
    check("and still writes the desks", after.contains("[desk.one]"))

    // Headers from older builds, stacked by earlier saves, collapse to one;
    // a comment the user wrote stays.
    let hf = f + ".headers"
    try? """
    # Project Coldfall desks. Written by Project Coldfall; safe to edit by hand.

    # Project Coldfall desks. Written by Project Coldfall; safe to edit by hand.

    # Deskwork desks. Written by Deskwork; safe to edit by hand.
    # my own note

    [desk.one]
    runtime = "claude"
    """.write(toFile: hf, atomically: true, encoding: .utf8)
    DeskConfig.write(DeskConfig.load(path: hf), to: hf)
    DeskConfig.write(DeskConfig.load(path: hf), to: hf)
    let hdr = (try? String(contentsOfFile: hf, encoding: .utf8)) ?? ""
    eq("stacked headers collapse to one", hdr.components(separatedBy: "Written by").count - 1, 1)
    check("and a hand-written comment survives", hdr.contains("# my own note"))
    check("and the desks are still there", DeskConfig.load(path: hf).map(\.name) == ["one"])

    let t = DeskConfig.themeSettings(path: f)
    eq("the theme still parses after a save", t.palette, "gruvbox")
    eq("including the mode", t.mode, "light")
    eq("and the size", t.size, 16)

    // Now save WITH a new theme: it replaces the old one and keeps the rest.
    var t2 = DeskConfig.themeSettings(path: f)
    t2.palette = "vscode"; t2.mode = "dark"
    DeskConfig.write(DeskConfig.load(path: f), theme: t2, to: f)
    let t3 = DeskConfig.themeSettings(path: f)
    eq("a new theme replaces the old palette", t3.palette, "vscode")
    eq("and the old mode", t3.mode, "dark")
    let after2 = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    check("replacing the theme still keeps other sections",
          after2.contains("setting = \"keep me\""))
    check("and does not leave a second theme table",
          after2.components(separatedBy: "[theme]").count == 2)

    // Repeated saves must be stable rather than accreting blank lines or dupes.
    DeskConfig.write(DeskConfig.load(path: f), theme: t3, to: f)
    DeskConfig.write(DeskConfig.load(path: f), theme: t3, to: f)
    let after3 = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    check("saving repeatedly does not duplicate the theme",
          after3.components(separatedBy: "[theme]").count == 2)
    check("saving repeatedly does not duplicate a desk",
          after3.components(separatedBy: "[desk.one]").count == 2)
}

// Dark is the default, not the system setting. A terminal-first tool that
// opens white on a light-mode Mac has wasted its only first impression.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    defer { try? FileManager.default.removeItem(at: dir) }
    try? "[desk.one]\nruntime = \"claude\"\n".write(toFile: f, atomically: true, encoding: .utf8)
    eq("no theme table means no mode set, so the app default applies",
       DeskConfig.themeSettings(path: f).mode, nil)
}

// MARK: - the usage cache
//
// A cache that is fast and WRONG is worse than the 12-second scan it replaced,
// so these pin invalidation rather than hits. Every one of them is a way the
// meter could quietly report yesterday's numbers.

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("t.jsonl").path
    // Point the cache at this test's own directory. It used to write to the
    // real ~/.local/share/coldfall, and the empty directory it left behind was
    // enough to make the rename's migration refuse to run.
    let realRoot = UsageCache.root
    UsageCache.root = dir.appendingPathComponent("cache").path
    defer {
        UsageCache.clear()
        UsageCache.root = realRoot
        try? FileManager.default.removeItem(at: dir)
    }
    UsageCache.clear()

    try? "one".write(toFile: f, atomically: true, encoding: .utf8)
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    guard let fp1 = UsageCache.fingerprint(f) else { fatalError("no fingerprint") }

    let slice = UsageSlice(vendor: "claude", desk: "hub", day: "2026-09-20",
                           tokens: 100, calls: 2, usd: 1.5)
    UsageCache.store([slice], for: f, key: fp1.key, since: since)

    eq("an unchanged file serves its cached slices",
       UsageCache.slices(for: f, key: fp1.key, since: since)?.first?.tokens, 100)

    // A file whose CONTENTS changed must not serve the old numbers. Size is
    // part of the key precisely so a same-second rewrite is still caught.
    try? "one plus more text".write(toFile: f, atomically: true, encoding: .utf8)
    guard let fp2 = UsageCache.fingerprint(f) else { fatalError("no fingerprint") }
    check("a changed file invalidates its cache entry",
          UsageCache.slices(for: f, key: fp2.key, since: since) == nil)

    // A report over a different window is a different answer and must not be
    // served from an entry computed for another one.
    check("a different window invalidates the cache",
          UsageCache.slices(for: f, key: fp1.key,
                            since: since.addingTimeInterval(86_400)) == nil)

    // A file that no longer exists must not linger forever.
    UsageCache.store([slice], for: f, key: fp2.key, since: since)
    UsageCache.flush(keeping: [])
    check("flushing drops files that were not seen this pass",
          UsageCache.slices(for: f, key: fp2.key, since: since) == nil)

    // A file that IS still present survives the same flush.
    UsageCache.store([slice], for: f, key: fp2.key, since: since)
    UsageCache.flush(keeping: [f])
    eq("and keeps the ones that were",
       UsageCache.slices(for: f, key: fp2.key, since: since)?.first?.calls, 2)

    // An unknown path is a miss, not a crash.
    check("an unknown file is simply a miss",
          UsageCache.slices(for: "/nope/missing.jsonl", key: "x", since: since) == nil)

    // Fingerprinting something that is not there fails cleanly rather than
    // returning a key that would match every other missing file.
    check("fingerprinting a missing file returns nil",
          UsageCache.fingerprint("/nope/missing.jsonl") == nil)
}

// MARK: - dropping a file onto a desk
//
// The path goes onto a command line, so anything that escapes wrong either
// breaks the command or, worse, runs part of the filename. Real filenames are
// the test cases here, not invented ones.

do {
    eq("an ordinary path needs no escaping",
       ShellPath.escape("/srv/demo/notes.md"), "/srv/demo/notes.md")
    eq("a space is escaped",
       ShellPath.escape("/srv/demo/My File.png"), "/srv/demo/My\\ File.png")

    // Parentheses are ordinary in a filename and are NOT ordinary to zsh.
    eq("parentheses are escaped",
       ShellPath.escape("/x/report (final).pdf"), "/x/report\\ \\(final\\).pdf")

    // The ones that would actually execute something rather than just fail.
    check("a dollar sign is escaped", ShellPath.escape("/x/$HOME.txt").contains("\\$"))
    check("a backtick is escaped", ShellPath.escape("/x/`whoami`.txt").contains("\\`"))
    check("a semicolon is escaped", ShellPath.escape("/x/a;rm -rf b").contains("\\;"))
    check("an ampersand is escaped", ShellPath.escape("/x/a&b").contains("\\&"))
    check("a quote is escaped", ShellPath.escape("/x/it's here.txt").contains("\\'"))
    check("a backslash is escaped", ShellPath.escape("/x/a\\b").contains("\\\\"))

    // Globs must reach the program as literals, not be expanded by the shell.
    check("an asterisk is escaped", ShellPath.escape("/x/a*.log").contains("\\*"))

    // Non-ASCII names are common and must not be mangled; escaping them is
    // harmless, dropping or re-encoding them would not be.
    check("a unicode name survives", ShellPath.escape("/x/café.png").contains("caf"))
    check("an emoji name survives", !ShellPath.escape("/x/🎉.png").isEmpty)

    // The trailing space is what stops a second drop gluing onto the first.
    check("a dropped path ends with a space",
          ShellPath.line(["/x/a.png"]).hasSuffix(" "))
    eq("several paths are separated",
       ShellPath.line(["/x/a.png", "/x/b.png"]), "/x/a.png /x/b.png ")
    eq("dropping nothing types nothing", ShellPath.line([]), "")
}

// MARK: - migration from Deskwork paths
//
// The one piece of the rename that can lose a user's data. A plain directory
// rename would have broken the author's Claude Code statusline in every
// session on the machine, so the contract is: move, leave a link, never delete,
// and refuse to guess when both sides exist.

do {
    let fm = FileManager.default
    func sandbox() -> String {
        let d = fm.temporaryDirectory.appendingPathComponent("mig-" + UUID().uuidString).path
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    // Nothing there: a fresh install does nothing.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        eq("no old directory means nothing to migrate",
           Migration.migrate(from: d + "/old", to: d + "/new"), .nothing)
    }

    // The ordinary upgrade: data moves, a link is left, and the file is still
    // readable through the OLD path — which is what keeps external references
    // like a statusline command working.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? fm.createDirectory(atPath: d + "/old", withIntermediateDirectories: true)
        try? "[desk.hub]\n".write(toFile: d + "/old/desks.toml", atomically: true, encoding: .utf8)

        eq("an old directory is migrated", Migration.migrate(from: d + "/old", to: d + "/new"), .migrated)
        check("the data is at the new path", fm.fileExists(atPath: d + "/new/desks.toml"))
        check("the old path is now a link",
              (try? fm.destinationOfSymbolicLink(atPath: d + "/old")) != nil)
        eq("and the old path still reads the same file",
           try? String(contentsOfFile: d + "/old/desks.toml", encoding: .utf8), "[desk.hub]\n")

        // Running it again on the next launch must be a no-op.
        eq("a second launch sees it is already done",
           Migration.migrate(from: d + "/old", to: d + "/new"), .alreadyDone)
        check("and the data is still there", fm.fileExists(atPath: d + "/new/desks.toml"))
    }

    // Both exist as real directories: refuse, and touch neither. This is the
    // state a too-early save would have produced, and guessing here means
    // destroying one side.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? fm.createDirectory(atPath: d + "/old", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: d + "/new", withIntermediateDirectories: true)
        try? "old".write(toFile: d + "/old/a", atomically: true, encoding: .utf8)
        try? "new".write(toFile: d + "/new/a", atomically: true, encoding: .utf8)

        eq("two real directories is a conflict", Migration.migrate(from: d + "/old", to: d + "/new"), .conflict)
        eq("the old side is untouched", try? String(contentsOfFile: d + "/old/a", encoding: .utf8), "old")
        eq("the new side is untouched", try? String(contentsOfFile: d + "/new/a", encoding: .utf8), "new")
        check("and no link was made over real data",
              (try? fm.destinationOfSymbolicLink(atPath: d + "/old")) == nil)
    }

    // A plain FILE where the old directory should be is not a directory to
    // move. Leave it alone.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? "x".write(toFile: d + "/old", atomically: true, encoding: .utf8)
        eq("a file at the old path is not migrated",
           Migration.migrate(from: d + "/old", to: d + "/new"), .nothing)
        check("and it is left where it was", fm.fileExists(atPath: d + "/old"))
    }

    // The new parent directory does not exist yet (a first run on a machine
    // that has never had ~/.local/share). The move must create it.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? fm.createDirectory(atPath: d + "/old", withIntermediateDirectories: true)
        eq("migrating into a parent that does not exist yet still works",
           Migration.migrate(from: d + "/old", to: d + "/deep/nested/new"), .migrated)
    }
}

// MARK: - markdown rendering
//
// Markdown used to be shown as raw source. These pin that it renders, and —
// because the reader shows files the user may not have written — that nothing
// in a file can inject markup or script.

do {
    let h = MarkdownHTML.body

    // The original complaint, line by line.
    check("a heading renders without its pound sign", h("# Desks").contains("<h1>Desks</h1>"))
    check("bold renders without its asterisks", h("a **b** c").contains("<strong>b</strong>"))
    check("italic renders", h("a *b* c").contains("<em>b</em>"))

    // Tables were the worst of it: rows of pipes wrapping across the window.
    let t = h("| Desk | Model |\n|---|---|\n| hub | Opus |\n| money | Fable |")
    check("a GFM table becomes a real table", t.contains("<table>") && t.contains("<th>Desk</th>"))
    check("and its rows are cells, not pipes", t.contains("<td>hub</td>") && t.contains("<td>Fable</td>"))
    check("the separator row is not rendered as data", !t.contains("---"))
    check("a right-aligned column keeps its alignment",
          h("| a |\n|--:|\n| 1 |").contains("text-align:right"))
    check("an escaped pipe stays inside its cell",
          h("| a |\n|---|\n| x \\| y |").contains("<td>x | y</td>"))

    // Code must stay literal: underscores in code are not emphasis.
    check("underscores inside code are not italicised",
          h("run `a_b_c` now").contains("<code>a_b_c</code>"))
    check("snake_case in prose is not italicised", !h("the desk_name field").contains("<em>"))
    check("a fenced block keeps its contents verbatim",
          h("```\nlet x = **y**\n```").contains("let x = **y**"))

    // Lists, quotes, rules.
    check("a bullet list renders", h("- one\n- two").contains("<ul>") && h("- one").contains("<li>one</li>"))
    check("a numbered list renders", h("1. one\n2. two").contains("<ol>"))
    check("a task box renders checked", h("- [x] done").contains("checked"))
    check("a blockquote renders", h("> quoted").contains("<blockquote>"))
    check("a rule renders", h("---").contains("<hr>"))

    // SECURITY. Every line of this is escaping a file's contents, and files
    // come from cloned repos and agents, not only from the user.
    check("a script tag in a file is escaped, not run",
          !h("<script>alert(1)</script>").contains("<script>"))
    check("and shows as visible text", h("<script>x</script>").contains("&lt;script&gt;"))
    check("markup inside a table cell is escaped",
          !h("| a |\n|---|\n| <img src=x onerror=alert(1)> |").contains("<img"))
    check("a javascript: link is not made clickable",
          !h("[click](javascript:alert(1))").contains("href"))
    check("a normal https link is clickable",
          h("[site](https://example.com)").contains("href=\"https://example.com\""))
    check("a relative link to another file is clickable",
          h("[notes](other.md)").contains("href=\"other.md\""))
    check("a quote in text cannot break out of an attribute",
          !h("[x](https://a.com\"onmouseover=\"alert(1))").contains("onmouseover=\"alert"))
}


// MARK: - quick open (fuzzy matching)
//
// The ranking is the whole point: a palette that finds the right thing but
// puts it fifth is one you stop using.

do {
    // Matching itself.
    check("an in-order subsequence matches", Fuzzy.score("cpa", "cpa-strategy-copilot") != nil)
    check("out-of-order letters do not match", Fuzzy.score("apc", "cpa") == nil)
    check("matching ignores case", Fuzzy.score("README", "docs/readme.md") != nil)
    check("a query longer than the candidate does not match", Fuzzy.score("hubhub", "hub") == nil)
    eq("an empty query matches with score 0", Fuzzy.score("", "anything"), 0)

    // Ranking — what you meant comes first.
    let desks = ["market", "money", "mba", "hub"]
    eq("an exact prefix wins", Fuzzy.rank("mo", desks, key: { $0 }).first, "money")
    eq("word starts beat scattered letters",
       Fuzzy.rank("sst", ["self-study-tutor", "sasstrings"], key: { $0 }).first, "self-study-tutor")

    // A match in the file NAME beats one buried in the directory above it.
    let files = ["docs/desks/notes.md", "notes/DESKS.md"]
    eq("the file name outranks the path", Fuzzy.rank("desks", files, key: { $0 }).first, "notes/DESKS.md")

    // Consecutive letters beat the same letters spread out.
    eq("consecutive characters rank higher",
       Fuzzy.rank("desk", ["d_e_s_k.txt", "desk.txt"], key: { $0 }).first, "desk.txt")

    check("non-matches are dropped from the ranking",
          !Fuzzy.rank("zzz", desks, key: { $0 }).contains("hub"))
    eq("an empty query returns the list as-is",
       Fuzzy.rank("", desks, key: { $0 }), desks)

    // The file index skips what nobody opens by name.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fz-" + UUID().uuidString)
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dir) }
    for p in ["README.md", "src/app.swift", "node_modules/pkg/index.js", ".git/HEAD", ".build/x.o"] {
        let u = dir.appendingPathComponent(p)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "x".write(to: u, atomically: true, encoding: .utf8)
    }
    let found = Set(FileIndex.files(under: dir.path))
    check("the index finds ordinary files", found.contains("README.md") && found.contains("src/app.swift"))
    check("the index skips node_modules", !found.contains(where: { $0.hasPrefix("node_modules") }))
    check("the index skips .git", !found.contains(where: { $0.hasPrefix(".git") }))
    check("the index skips build output", !found.contains(where: { $0.hasPrefix(".build") }))
    eq("the index respects its limit", FileIndex.files(under: dir.path, limit: 1).count, 1)
}


// MARK: - saved UI state survives new fields
//
// Adding a field to UIState used to wipe everyone's saved state: the default
// decoder throws on a missing key and load() falls back to defaults. This is
// the author's real ui.json from before the layout toggles existed.

do {
    let old = #"{"collapsed":["WORK"],"treeOnTop":true,"seenWelcome":true}"#
    let s = try? JSONDecoder().decode(UIState.self, from: Data(old.utf8))
    check("a ui.json from before the new fields still decodes", s != nil)
    eq("and keeps the tree position", s?.treeOnTop, true)
    eq("and keeps having seen the welcome screen", s?.seenWelcome, true)
    eq("and keeps collapsed groups", s?.collapsed, ["WORK"])
    eq("new fields take their defaults", s?.railHidden, false)

    // A completely empty object is the extreme case and must not throw.
    check("an empty object decodes to defaults",
          (try? JSONDecoder().decode(UIState.self, from: Data("{}".utf8))) != nil)

    // Round trip keeps the new fields.
    var u = UIState(); u.railHidden = true; u.readerPoppedOut = true
    let back = (try? JSONEncoder().encode(u)).flatMap { try? JSONDecoder().decode(UIState.self, from: $0) }
    eq("a saved layout toggle comes back", back?.railHidden, true)
    eq("and the reader's pop-out state", back?.readerPoppedOut, true)
}


// MARK: - renaming, reordering, memory

do {
    let names = ["hub", "money", "work"]
    check("a plain name is fine", DeskName.problem("career", existing: names) == nil)
    check("an empty name is refused", DeskName.problem("", existing: names) != nil)
    check("a dot would nest the TOML table", DeskName.problem("a.b", existing: names) != nil)
    check("so would a space", DeskName.problem("my desk", existing: names) != nil)
    check("a taken name is refused, case-insensitively", DeskName.problem("Money", existing: names) != nil)
    check("keeping its own name is not a clash",
          DeskName.problem("hub", existing: names, current: "hub") == nil)
    check("over the length limit is refused",
          DeskName.problem(String(repeating: "a", count: 41), existing: names) != nil)

    let list = [Desk(name: "a"), Desk(name: "b", group: "g"), Desk(name: "c", group: "g"),
                Desk(name: "d", group: "h")]
    let n = { (ds: [Desk]) in ds.map(\.name).joined() }
    eq("move down within a group", n(DeskOrder.move(list, from: 1, to: .after(2))), "acbd")
    eq("move up to the top", n(DeskOrder.move(list, from: 3, to: .before(0))), "dabc")
    let joined = DeskOrder.move(list, from: 0, to: .after(2))
    eq("landing beside a grouped desk joins its group", joined.first { $0.name == "a" }?.group, "g")
    eq("end of a group lands after its last member",
       n(DeskOrder.move(list, from: 0, to: .endOfGroup("g"))), "bcad")
    eq("end of the ungrouped section is ungrouped",
       DeskOrder.move(list, from: 3, to: .endOfGroup(nil)).first { $0.name == "d" }?.group ?? "none", "none")
    eq("a drop onto itself changes nothing", n(DeskOrder.move(list, from: 2, to: .before(2))), "abcd")

    // A group scattered through the file, as a hand edit leaves it.
    let messy = [Desk(name: "hub"), Desk(name: "cpa", group: "money"), Desk(name: "work", group: "work"),
                 Desk(name: "zed"), Desk(name: "market", group: "money"), Desk(name: "golf", group: "Personal"),
                 Desk(name: "desk10", group: "work"), Desk(name: "desk2", group: "work")]
    let ns = { (ds: [Desk]) in ds.map(\.name).joined(separator: " ") }
    eq("groups follow first appearance, ungrouped first",
       DeskOrder.groups(messy).map { $0 ?? "-" }, ["-", "money", "work", "Personal"])
    eq("grouped gathers each group's desks together",
       ns(DeskOrder.grouped(messy)), "hub zed cpa market work desk10 desk2 golf")
    eq("A to Z: ungrouped on top, groups by name ignoring case, desks by name, numbers natural",
       ns(DeskOrder.sortedAZ(messy)), "hub zed cpa market golf desk2 desk10 work")
    check("sorting keeps every desk", DeskOrder.sortedAZ(messy).count == messy.count)
    check("and every desk keeps its group",
          DeskOrder.sortedAZ(messy).allSatisfy { d in messy.first { $0.name == d.name }?.group == d.group })
    eq("a group moves as a block", ns(DeskOrder.moveGroup(messy, "Personal", before: "money")),
       "hub zed golf cpa market work desk10 desk2")
    eq("moving a group last", ns(DeskOrder.moveGroup(messy, "money", before: nil)),
       "hub zed work desk10 desk2 golf cpa market")
    eq("moving before itself only tidies", ns(DeskOrder.moveGroup(messy, "work", before: "work")),
       ns(DeskOrder.grouped(messy)))
    eq("an unknown group changes nothing but the tidy",
       ns(DeskOrder.moveGroup(messy, "nope", before: nil)), ns(DeskOrder.grouped(messy)))
    eq("an unknown target puts the group last", ns(DeskOrder.moveGroup(messy, "money", before: "nope")),
       "hub zed work desk10 desk2 golf cpa market")

    let ps = ProcessTree.parse("""
      100     1   2000
      101   100 900000
      102   101  50000
      103   101  40000
      200     1   1000
    garbage line
    """)
    eq("ps rows parse, garbage skipped", ps.count, 5)
    eq("a desk's memory is its whole tree", ProcessTree.totalKB(root: 100, in: ps), 992000)
    eq("an unrelated tree is not counted", ProcessTree.totalKB(root: 200, in: ps), 1000)
    eq("a pid that is gone counts nothing", ProcessTree.totalKB(root: 999, in: ps), 0)
    let tree = ProcessTree.descendants(of: 100, in: ps)
    eq("ending a desk reaches every process under its shell", Set(tree), [100, 101, 102, 103])
    eq("the shell is ended last", tree.last, 100)
    check("and children before their parent",
          tree.firstIndex(of: 102)! < tree.firstIndex(of: 101)! && tree.firstIndex(of: 103)! < tree.firstIndex(of: 101)!)
    check("an unrelated tree is left alone", !tree.contains(200))
    eq("a pid that is gone ends nothing", ProcessTree.descendants(of: 999, in: ps), [])
    eq("labels megabytes", ProcessTree.label(kb: 2048), "2 MB")
    eq("and gigabytes", ProcessTree.label(kb: 992000), "969 MB")
    eq("over a thousand MB reads as GB", ProcessTree.label(kb: 1_300_000), "1.2 GB")
}

// The writer used to drop `model`, so reordering or renaming an ollama desk
// would have silently switched it back to the default model.
do {
    let tmp = NSTemporaryDirectory() + "coldfall-model-\(UUID().uuidString).toml"
    DeskConfig.write([Desk(name: "local", runtime: "ollama", model: "qwen3")], to: tmp)
    eq("model survives a write", DeskConfig.load(path: tmp).first?.model, "qwen3")
    try? FileManager.default.removeItem(atPath: tmp)
}



// MARK: - resuming a desk's conversation

do {
    let root = NSTemporaryDirectory() + "coldfall-resume-\(UUID().uuidString)"
    let fm = FileManager.default
    eq("claude's folder for a directory", Resume.claudeProjectDir(for: "/srv/demo.app/my dir", root: "/r"),
       "/r/-srv-demo-app-my-dir")
    eq("dashes survive", Resume.claudeProjectDir(for: "/srv/a-b", root: "/r"), "/r/-srv-a-b")

    let cdir = Resume.claudeProjectDir(for: "/srv/demo", root: root + "/claude")
    try? fm.createDirectory(atPath: cdir, withIntermediateDirectories: true)
    func transcript(_ id: String, _ title: String?, age: TimeInterval) {
        let path = cdir + "/\(id).jsonl"
        var text = "{\"type\":\"user\",\"message\":\"hi\"}\n"
        if let title { text += "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"\(id)\"}\n" }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    eq("no transcripts, nothing to resume",
       Resume.claudeSession(named: "demo", cwd: "/srv/demo", root: root + "/claude"), nil)
    transcript("old-demo", "demo", age: 3000)
    transcript("new-demo", "demo", age: 100)
    transcript("other", "demo2", age: 10)
    transcript("untitled", nil, age: 5)
    eq("the newest transcript with the desk's title",
       Resume.claudeSession(named: "demo", cwd: "/srv/demo", root: root + "/claude"), "new-demo")
    eq("a longer title is not a match", Resume.claudeSession(named: "dem", cwd: "/srv/demo", root: root + "/claude"), nil)
    eq("another directory's desk finds nothing",
       Resume.claudeSession(named: "demo", cwd: "/srv/elsewhere", root: root + "/claude"), nil)

    let croot = root + "/codex/2026/09/20"
    try? fm.createDirectory(atPath: croot, withIntermediateDirectories: true)
    func rollout(_ name: String, cwd: String, subagent: Bool = false) {
        let src = subagent ? ",\"source\":{\"subagent\":{}}" : ""
        try? "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"\(cwd)\",\"originator\":\"codex-tui\"\(src)}}\n{}\n"
            .write(toFile: croot + "/\(name).jsonl", atomically: true, encoding: .utf8)
    }
    rollout("a", cwd: "/srv/demo", subagent: true)
    check("a subagent's session is not one to resume", !Resume.codexHasSession(cwd: "/srv/demo", root: root + "/codex"))
    rollout("b", cwd: "/srv/demo")
    check("an interactive session in the folder is", Resume.codexHasSession(cwd: "/srv/demo", root: root + "/codex"))
    check("but not for another folder", !Resume.codexHasSession(cwd: "/srv/other", root: root + "/codex"))

    let claudeDesk = Desk(name: "demo", runtime: "claude", cwd: "/srv/demo")
    eq("a claude desk with history resumes it by id",
       claudeDesk.resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"),
       "claude --resume new-demo")
    eq("without history it starts a named session",
       Desk(name: "fresh", runtime: "claude", cwd: "/srv/demo")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "claude -n fresh")
    eq("an agent desk keeps its agent when resuming",
       Desk(name: "demo", agent: "helper", runtime: "claude", cwd: "/srv/demo")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"),
       "claude --agent helper --resume new-demo")
    eq("a codex desk with history resumes the latest",
       Desk(name: "cx", runtime: "codex", cwd: "/srv/demo")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "codex resume --last")
    eq("without it, plain codex",
       Desk(name: "cx", runtime: "codex", cwd: "/srv/other")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "codex")
    let scripted = Desk(name: "demo", runtime: "claude", cwd: "/srv/demo", command: "/srv/demo/bin/desk demo")
    eq("a desk with its own command runs exactly that",
       scripted.resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "/srv/demo/bin/desk demo")

    check("the stop dialog promises the conversation for a built-in desk",
          Resume.afterRestart(claudeDesk)?.contains("same conversation") == true)
    check("and makes no promise for a scripted one",
          Resume.afterRestart(scripted)?.contains("its own command") == true)
    eq("and says nothing for a shell", Resume.afterRestart(Desk(name: "sh", runtime: "shell")), nil)
    try? fm.removeItem(atPath: root)
}


// MARK: - needs you

do {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let e = [NeedsYou.Entry(name: "hub", activity: .ready, lastOutput: t0.addingTimeInterval(60)),
             NeedsYou.Entry(name: "money", activity: .working, lastOutput: t0),
             NeedsYou.Entry(name: "career", activity: .ready, lastOutput: t0),
             NeedsYou.Entry(name: "golf", activity: .quiet, lastOutput: nil),
             NeedsYou.Entry(name: "study", activity: .ready, lastOutput: t0.addingTimeInterval(60))]
    let q = NeedsYou.queue(e)
    eq("only waiting desks, oldest wait first, ties by name", q, ["career", "hub", "study"])
    eq("cmd-0 goes to the oldest", NeedsYou.next(in: q, current: "golf"), "career")
    eq("and never to the desk already on screen", NeedsYou.next(in: q, current: "career"), "hub")
    eq("nothing waiting, nowhere to go", NeedsYou.next(in: [], current: nil), nil)
    eq("one desk reads as a sentence", NeedsYou.summary(["career"]), "career needs you")
    eq("several are counted and named", NeedsYou.summary(q), "3 need you: career, hub, study")
    eq("a long queue is cut short", NeedsYou.summary(q + ["work"]), "4 need you: career, hub, study, …")
    eq("an empty queue says nothing", NeedsYou.summary([]), nil)
}

// MARK: - the daily update check

do {
    let dir = NSTemporaryDirectory() + "coldfall-update-\(UUID().uuidString)"
    let realRoot = UpdateState.root
    UpdateState.root = dir
    defer { UpdateState.root = realRoot; try? FileManager.default.removeItem(atPath: dir) }

    let first = UpdateState.load()
    check("a fresh install gets a random id", UUID(uuidString: first.id) != nil)
    eq("and keeps it", UpdateState.load().id, first.id)
    check("on by default", first.enabled)

    var s = first
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    check("nothing is sent before the notice is shown", !UpdateCheck.due(s, now: now))
    s.noticeShown = true
    check("after the notice, a first check is due", UpdateCheck.due(s, now: now))
    s.lastCheck = now.addingTimeInterval(-3600)
    check("not again within the day", !UpdateCheck.due(s, now: now))
    s.lastCheck = now.addingTimeInterval(-UpdateCheck.interval)
    check("but once a day has passed", UpdateCheck.due(s, now: now))
    s.enabled = false
    check("and never when turned off", !UpdateCheck.due(s, now: now))
    s.save()
    eq("turning it off is remembered", UpdateState.load().enabled, false)

    eq("a release reports as itself", UpdateCheck.reportedVersion("v0.3.0"), "v0.3.0")
    eq("a build from source hides its commit", UpdateCheck.reportedVersion("v0.3.0-5-gabc1234"), "v0.3.0-dev")
    eq("a build with no tag is unknown", UpdateCheck.reportedVersion("abc1234"), "unknown")

    let body = UpdateCheck.body(first, appVersion: "v0.3.0-2-gdeadbee", os: "15.6.1")
    let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
    eq("the request carries exactly three fields", sent.map { Set($0.keys) }, ["id", "v", "os"])
    eq("the id", sent?["id"], first.id)
    eq("the reported version", sent?["v"], "v0.3.0-dev")
    eq("the macOS version", sent?["os"], "15.6.1")

    eq("a reply names the latest release",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"https://github.com/o/r/releases/tag/v0.4.0"}"#.utf8)),
       UpdateCheck.Reply(latest: "v0.4.0", url: "https://github.com/o/r/releases/tag/v0.4.0"))
    eq("a link that is not https is dropped",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"javascript:alert(1)"}"#.utf8))?.url, nil)
    eq("anything else is not a reply", UpdateCheck.parse(Data("<html>".utf8)), nil)
    eq("nor is a version that is not one", UpdateCheck.parse(Data(#"{"latest":"soon"}"#.utf8)), nil)

    check("a higher release is newer", UpdateCheck.isNewer("v0.4.0", than: "v0.3.0"))
    check("numbers compare as numbers", UpdateCheck.isNewer("v0.10.0", than: "v0.9.2"))
    check("the same release is not", !UpdateCheck.isNewer("v0.3.0", than: "v0.3.0"))
    check("an older one is not", !UpdateCheck.isNewer("v0.2.0", than: "v0.3.0"))
    check("a build past a release does not nag about it",
          !UpdateCheck.isNewer("v0.3.0", than: "v0.3.0-5-gabc1234"))
    check("but does hear about the next", UpdateCheck.isNewer("v0.3.1", than: "v0.3.0-5-gabc1234"))
    check("an unreadable version never claims an update", !UpdateCheck.isNewer("v0.4.0", than: "abc1234"))
}

// MARK: - double-click to fill the screen and back

do {
    let screen = Frame(x: 0, y: 80, w: 1512, h: 862)
    let small = Frame(x: 200, y: 200, w: 900, h: 600)
    let (filled, saved) = WindowFill.toggle(frame: small, visible: screen, saved: nil)
    eq("a double-click fills the screen", filled, screen)
    eq("and remembers where it was", saved, small)
    let nudged = Frame(x: filled.x + 2, y: filled.y - 3, w: filled.w, h: filled.h)
    let (back, cleared) = WindowFill.toggle(frame: nudged, visible: screen, saved: saved)
    eq("a second double-click goes back, even after the drag's nudge", back, small)
    eq("and forgets the saved frame", cleared, nil)
    let (fallback, _) = WindowFill.toggle(frame: screen, visible: screen, saved: nil)
    check("filled with nothing saved still shrinks",
          fallback.w < screen.w && fallback.x >= screen.x && fallback.x + fallback.w <= screen.x + screen.w)
    check("a saved frame that also filled is not a way back",
          WindowFill.toggle(frame: screen, visible: screen, saved: screen).next != screen)
}

// MARK: - trimming a desk's MCP servers

do {
    eq("a TOML string list", TomlText.stringArray(#"["gmail", "chrome-devtools"]"#), ["gmail", "chrome-devtools"])
    eq("an empty one", TomlText.stringArray("[]"), [])
    eq("escapes inside", TomlText.stringArray(#"["a\"b"]"#), [#"a"b"#])
    eq("not a list", TomlText.stringArray(#""gmail""#), nil)
    eq("a bare word is not a string", TomlText.stringArray("[gmail]"), nil)
    eq("an unfinished string", TomlText.stringArray(#"["gmail]"#), nil)

    check("ordinary server names pass", McpTrim.validName("chrome-devtools") && McpTrim.validName("mcp_1.x"))
    check("a quote cannot reach the shell", !McpTrim.validName("x'; rm -rf ~; '"))
    check("nor a space", !McpTrim.validName("a b"))
    eq("settings switch off exactly the named servers, sorted, once",
       McpTrim.settingsJSON(off: ["gmail", "chrome-devtools", "gmail"]),
       #"{"disabledMcpjsonServers":["chrome-devtools","gmail"]}"#)
    eq("an unsafe name is dropped, not quoted", McpTrim.settingsJSON(off: ["bad'name", "gmail"]),
       #"{"disabledMcpjsonServers":["gmail"]}"#)
    eq("nothing off, no setting", McpTrim.settingsJSON(off: []), nil)

    let dir = NSTemporaryDirectory() + "coldfall-mcp-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? #"{"mcpServers":{"gmail":{"command":"x"},"mission-control":{"command":"node"},"bad name":{}}}"#
        .write(toFile: dir + "/.mcp.json", atomically: true, encoding: .utf8)
    eq("a desk can trim the servers in its folder's .mcp.json", McpTrim.servers(cwd: dir), ["gmail", "mission-control"])
    eq("a folder without one has none", McpTrim.servers(cwd: dir + "/nowhere"), [])

    var d = Desk(name: "golf", runtime: "claude", cwd: "/srv/demo")
    d.mcpOff = ["gmail", "chrome-devtools"]
    eq("a built-in desk starts Claude with them off", d.launchCommand(),
       #"claude -n golf --settings '{"disabledMcpjsonServers":["chrome-devtools","gmail"]}'"#)
    eq("and keeps them off when it resumes", d.launchCommand(claudeSession: "abc"),
       #"claude --resume abc --settings '{"disabledMcpjsonServers":["chrome-devtools","gmail"]}'"#)
    eq("an untrimmed desk is unchanged", Desk(name: "golf", runtime: "claude").launchCommand(), "claude -n golf")

    let f = dir + "/desks.toml"
    DeskConfig.write([d], to: f)
    eq("the choice survives a save", DeskConfig.load(path: f).first?.mcpOff, ["gmail", "chrome-devtools"])
    DeskConfig.write([Desk(name: "golf")], to: f)
    check("and an untrimmed desk writes no line for it",
          !((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").contains("mcp_off"))

    try? "#!/bin/sh\nexec claude \"$@\"\n".write(toFile: dir + "/plain", atomically: true, encoding: .utf8)
    try? "#!/bin/sh\nexec claude ${COLDFALL_CLAUDE_SETTINGS:+--settings \"$COLDFALL_CLAUDE_SETTINGS\"} \"$@\"\n"
        .write(toFile: dir + "/aware", atomically: true, encoding: .utf8)
    check("a script that ignores the setting is noticed", !McpTrim.commandHonors(dir + "/plain hub"))
    check("one that passes it on is too", McpTrim.commandHonors(dir + "/aware hub"))
    check("a command that is not a file cannot be vouched for", !McpTrim.commandHonors("claude --agent x"))
}

// MARK: - renaming a desk keeps its conversation

do {
    let root = NSTemporaryDirectory() + "coldfall-rename-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = Resume.claudeProjectDir(for: "/srv/demo", root: root)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let id = "3f2b8c1e-7a4d-4e5f-9b6c-1d2e3f4a5b6c"
    try? #"{"type":"custom-title","customTitle":"notes"}"#.write(toFile: dir + "/\(id).jsonl", atomically: true, encoding: .utf8)

    let before = Desk(name: "notes", runtime: "claude", cwd: "/srv/demo")
    eq("before, the desk finds its conversation by name",
       before.resumingLaunchCommand(claudeRoot: root), "claude --resume \(id)")
    let after = before.renamed(from: "notes", to: "journal", claudeRoot: root)
    eq("renaming remembers that conversation", after.session, id)
    eq("so the renamed desk still reopens it",
       after.resumingLaunchCommand(claudeRoot: root), "claude --resume \(id)")
    eq("a second rename keeps the same one",
       after.renamed(from: "journal", to: "diary", claudeRoot: root).session, id)
    eq("a desk with nothing to resume remembers nothing",
       Desk(name: "fresh", runtime: "claude", cwd: "/srv/demo").renamed(from: "fresh", to: "new", claudeRoot: root).session, nil)
    let scripted = Desk(name: "hub", runtime: "claude", cwd: "/srv/demo", command: "/srv/demo/desk hub")
    eq("a desk with its own command is left to it",
       scripted.renamed(from: "hub", to: "home", claudeRoot: root).session, nil)

    var gone = after
    gone.session = "00000000-0000-4000-8000-000000000000"
    eq("a remembered conversation that no longer exists falls back to the name",
       gone.resumingLaunchCommand(claudeRoot: root), "claude -n journal")

    let f = root + "/desks.toml"
    DeskConfig.write([after], to: f)
    eq("the id survives a save", DeskConfig.load(path: f).first?.session, id)
    try? "[desk.x]\nruntime = \"claude\"\nsession = \"x'; rm -rf ~\"\n".write(toFile: f, atomically: true, encoding: .utf8)
    eq("anything but an id is ignored, never run", DeskConfig.load(path: f).first?.session, nil)
}

// MARK: - what a desk has

do {
    let root = NSTemporaryDirectory() + "coldfall-inv-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let home = root + "/home", cwd = root + "/srv/demo"
    let fm = FileManager.default
    func put(_ path: String, _ text: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    put(cwd + "/.mcp.json", #"{"mcpServers":{"mail":{"command":"/srv/demo/bin/mail-server"},"docs":{"type":"http","url":"https://docs.example.com/mcp"}}}"#)
    put(home + "/.claude.json", #"{"mcpServers":{"notes":{"command":"npx"}},"projects":{"\#(cwd)":{"mcpServers":{"trading":{"command":"node"}}}}}"#)
    put(cwd + "/.claude/skills/tax-notice/SKILL.md", "---\nname: tax-notice\ndescription: File a tax notice and log it.\n---\nbody")
    put(home + "/.claude/skills/synced/writing/SKILL.md", "---\nname: writing\ndescription: \"Plain writing.\"\n---\n")
    put(home + "/.claude/skills/not-a-skill/readme.txt", "x")
    put(cwd + "/.claude/settings.json", #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"python3 /srv/demo/hooks/brief.py --quiet"}]}]}}"#)
    let pdir = home + "/.claude/plugins/cache/market/helper/1.2.0"
    put(home + "/.claude/settings.json", #"{"enabledPlugins":{"helper@market":true,"off@market":false}}"#)
    put(home + "/.claude/plugins/installed_plugins.json",
        #"{"version":2,"plugins":{"helper@market":[{"installPath":"\#(pdir)","version":"1.2.0"}]}}"#)
    put(pdir + "/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship it.\n---\n")
    put(pdir + "/hooks/hooks.json", #"{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}/hooks/telemetry.mjs\""}]}]}}"#)
    put(pdir + "/.mcp.json", #"{"mcpServers":{"helper":{"type":"http","url":"https://mcp.helper.dev"}}}"#)

    var desk = Desk(name: "demo", runtime: "claude", cwd: cwd)
    desk.mcpOff = ["mail"]
    let inv = Inventory.of(desk, home: home)
    let mcp = Dictionary(uniqueKeysWithValues: inv.mcp.map { ($0.name, $0) })
    eq("servers from the folder, you and plugins", Set(mcp.keys), ["mail", "docs", "notes", "trading", "helper"])
    eq("a local server says it runs on this Mac", mcp["mail"]?.detail, "runs mail-server on this Mac")
    eq("a remote one says where", mcp["docs"]?.detail, "remote, docs.example.com")
    eq("a trimmed server is marked off", mcp["mail"]?.off, true)
    eq("a server from a plugin says so", mcp["helper"]?.source, "plugin helper")
    eq("skills from the folder, you (synced too) and plugins",
       Set(inv.skills.map(\.name)), ["tax-notice", "writing", "deploy"])
    eq("a skill's description is its detail", inv.skills.first { $0.name == "tax-notice" }?.detail, "File a tax notice and log it.")
    eq("quotes around a description are dropped", inv.skills.first { $0.name == "writing" }?.detail, "Plain writing.")
    eq("only enabled plugins, with what they carry", inv.plugins.map(\.detail), ["v1.2.0: 1 skill, 1 hook, 1 MCP server"])
    let hooks = inv.hooks.map { "\($0.name) \($0.detail) \($0.source)" }.sorted()
    eq("hooks name their event and script, not the whole command", hooks,
       ["PostToolUse telemetry.mjs plugin helper", "SessionStart brief.py this folder"])
    check("claude.ai connectors are mentioned, not invented", inv.notes.contains { $0.contains("claude.ai connectors") })

    put(home + "/.codex/config.toml", "model = \"x\"\n[mcp_servers.search]\ncommand = \"s\"\n[mcp_servers.search.env]\nK = \"v\"\n")
    put(cwd + "/AGENTS.md", "rules")
    let cx = Inventory.of(Desk(name: "cx", runtime: "codex", cwd: cwd), home: home)
    eq("Codex servers from config.toml, once each", cx.mcp.map(\.name), ["search"])
    check("and it says Codex reads AGENTS.md", cx.notes.contains { $0.contains("AGENTS.md") })
    check("a shell desk has nothing, and says why",
          Inventory.of(Desk(name: "sh", runtime: "shell"), home: home).isEmpty)
    check("an empty home finds nothing and doesn't fail",
          Inventory.of(Desk(name: "x", runtime: "claude", cwd: root + "/none"), home: root + "/none").isEmpty)
}

// MARK: - install help for a first run with no vendor CLI

do {
    let names = VendorInstall.all.map(\.runtime)
    eq("each runtime appears once", names.count, Set(names).count)
    check("every install line is for a runtime Coldfall knows",
          names.allSatisfy { n in Bridge.known.contains { $0.name == n } })
    check("every command is a single pasteable line", VendorInstall.all.allSatisfy { !$0.command.contains("\n") })
    check("docs are https", VendorInstall.all.allSatisfy { $0.docs.hasPrefix("https://") })
    check("each says what it needs from you", VendorInstall.all.allSatisfy { !$0.needs.isEmpty })
    eq("lookup by runtime", VendorInstall.of("codex")?.command, "npm install -g @openai/codex")
    eq("no line for a vendor with no official CLI", VendorInstall.of("grok"), nil)
}

// MARK: - what changed since you last looked

do {
    let dir = NSTemporaryDirectory() + "coldfall-seen-\(UUID().uuidString)"
    let realRoot = InventorySeen.root
    InventorySeen.root = dir
    defer { InventorySeen.root = realRoot; try? FileManager.default.removeItem(atPath: dir) }

    var before = Inventory()
    before.mcp = [.init(name: "mail", detail: "runs mail on this Mac", source: "this folder")]
    before.plugins = [.init(name: "helper", detail: "v1.0.0: 1 skill", source: "helper@market")]
    before.hooks = [.init(name: "SessionStart", detail: "brief.py", source: "this folder")]
    before.skills = [.init(name: "old-skill", detail: "", source: "you, every folder")]

    eq("the first look is a baseline, not a list of everything", before.changes(since: nil).isEmpty, true)
    eq("nothing changed, nothing to say", before.changes(since: before.seen).isEmpty, true)

    var now = before
    now.plugins = [.init(name: "helper", detail: "v1.1.0: 1 skill, 2 hooks", source: "helper@market")]
    now.hooks.append(.init(name: "PostToolUse", detail: "telemetry.mjs", source: "plugin helper"))
    now.skills = []
    let c = now.changes(since: before.seen)
    eq("a new hook is new", c.added, [Inventory.key(kind: "hook", now.hooks[1])])
    eq("a plugin whose version moved is updated, with what it was",
       c.updated[Inventory.key(kind: "plugin", now.plugins[0])], "v1.0.0: 1 skill")
    eq("a skill that went away is listed as removed", c.removed, ["skill old-skill"])
    eq("the nudge counts new and updated, not removed", c.count, 2)
    eq("a hook's label names its script", Inventory.label(Inventory.key(kind: "hook", now.hooks[1])),
       "hook PostToolUse (telemetry.mjs)")

    eq("nothing saved for a desk yet", InventorySeen.load("golf"), nil)
    InventorySeen.save("golf", now.seen)
    eq("what was seen comes back", InventorySeen.load("golf"), now.seen)
}

// MARK: - trimming a Codex desk's MCP servers

do {
    let root = NSTemporaryDirectory() + "coldfall-cxmcp-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    try? FileManager.default.createDirectory(atPath: root + "/.codex", withIntermediateDirectories: true)
    try? "[mcp_servers.search]\ncommand = \"s\"\n[mcp_servers.browser]\ncommand = \"b\"\n"
        .write(toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
    var d = Desk(name: "cx", runtime: "codex", cwd: "/srv/demo")
    eq("a Codex desk can trim the servers in config.toml", McpTrim.servers(for: d, home: root), ["browser", "search"])
    d.mcpOff = ["search"]
    eq("a trimmed Codex desk starts with that one off",
       d.launchCommand(), "codex -c 'mcp_servers.search.enabled=false'")
    eq("and keeps it off when it resumes",
       d.launchCommand(codexResume: true), "codex resume --last -c 'mcp_servers.search.enabled=false'")
    d.mcpOff = ["x'; rm -rf ~"]
    eq("an unsafe name never reaches the shell", d.launchCommand(), "codex")
    eq("vendors without a checked way have nothing to trim",
       McpTrim.servers(for: Desk(name: "g", runtime: "gemini"), home: root), [])
}

// MARK: - the suite must not touch a real home directory
//
// Checked LAST, after every other test has run. A test that writes to the
// user's real ~/.local/share/coldfall creates exactly the directory that makes
// the rename's migration refuse to act — so this is not tidiness, it is the
// difference between an upgrade that works and one that loses history.
do {
    let real = NSString(string: "~/.local/share/coldfall/cache/usage.json").expandingTildeInPath
    let createdByUs = FileManager.default.fileExists(atPath: real) && !preexistingCache
    check("the test suite left no cache in the real home directory", !createdByUs)
}

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
    print("\nfailures:")
    failures.forEach { print("  " + $0) }
    exit(1)
}

