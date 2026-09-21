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
