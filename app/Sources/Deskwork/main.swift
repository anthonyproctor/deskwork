// Deskwork M1 — the desk switcher.
//
// The agent is the unit of work. Each desk owns a long-lived terminal running
// the vendor's own CLI; switching desks swaps which one is visible without
// touching the process. Close the window, the desk keeps running.

import AppKit
import SwiftTerm
import DeskworkCore

// MARK: - one live desk

final class DeskSession {
    let desk: Desk
    let term: LocalProcessTerminalView
    private(set) var started = false

    init(desk: Desk) {
        self.desk = desk
        term = LocalProcessTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true

        // A CLI can take several seconds to boot. Paint something immediately,
        // written straight to the view rather than through the pty, so a blank
        // screen never reads as "nothing happened".
        term.feed(text: "\u{1b}[2J\u{1b}[H"
            + "\u{1b}[36m●\u{1b}[0m starting \u{1b}[1m\(desk.name)\u{1b}[0m\r\n"
            + "\u{1b}[2m  \(desk.launchCommand())\r\n"
            + "  in \(desk.resolvedCwd)\u{1b}[0m\r\n\r\n")

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")

        // Deskwork hands its own environment to every desk, so anything the app
        // inherited is inherited again by the agent. CLAUDECODE marks "you are
        // already inside a Claude Code session" and makes a nested one refuse to
        // start — which happens whenever Deskwork is launched from a terminal
        // that is itself running an agent. Scrub it rather than depending on how
        // the app was launched.
        let poison = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                      "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID",
                      "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
                      "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_EFFORT"]
        env.removeAll { entry in poison.contains(where: { entry.hasPrefix($0 + "=") }) }

        // Hooks and desk-scoped behaviour key off this, same as the shell wrapper.
        env.append("CLAUDE_DESK=\(desk.name)")
        env.append("DESKWORK=1")
        term.startProcess(executable: "/bin/zsh", args: ["-l"], environment: env)

        // Land in the desk's directory, then launch its CLI. No `clear` here —
        // wiping the screen would throw away the only feedback there is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            let dir = self.desk.resolvedCwd.replacingOccurrences(of: " ", with: "\\ ")
            self.term.send(txt: "cd \(dir) && \(self.desk.launchCommand())\n")
        }
    }
}

// MARK: - app

final class Controller: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate, NSSplitViewDelegate {
    var window: NSWindow!
    let sidebar = SidebarView()
    let tree = FileTreeView()
    let host = NSView()
    let reader = ReaderView()
    let split = NSSplitView()
    let meter = MeterBar()
    let watcher = WorkspaceWatcher()
    var desks: [Desk] = []
    var sessions: [String: DeskSession] = [:]
    var visible: DeskSession?
    var ui = UIState.load()
    let deskScroll = NSScrollView()
    var rail: NSSplitView!

    func applicationDidFinishLaunching(_ n: Notification) {
        desks = DeskConfig.load()
        let firstRun = desks.isEmpty || !ui.seenWelcome
        if desks.isEmpty {
            DeskConfig.writeStarter()
            desks = DeskConfig.load()
        }
        if desks.isEmpty {
            desks = [Desk(name: "shell", command: "exec zsh -l")]
        }

        // Size to the screen so the resize corner is always reachable. The window
        // was opening taller than the display, which made it look unresizable.
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: 0, y: 0,
                           width: min(1240, vis.width - 40),
                           height: min(820, vis.height - 40))
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Deskwork"
        window.titlebarAppearsTransparent = true

        // Left rail: desks on top, folder tree beneath, with a DRAGGABLE divider.
        // A fixed desk height starved the tree once the list got long.
        deskScroll.documentView = sidebar
        deskScroll.hasVerticalScroller = true
        deskScroll.drawsBackground = false
        deskScroll.automaticallyAdjustsContentInsets = false

        rail = NSSplitView()
        rail.delegate = self
        rail.isVertical = false          // stacked, so the divider is horizontal
        rail.dividerStyle = .thin
        applyRailOrder()
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        split.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(rail)
        split.addArrangedSubview(host)
        // Meter along the bottom, under both panes.
        let outer = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        meter.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(split); outer.addSubview(meter)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: outer.topAnchor),
            split.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            meter.topAnchor.constraint(equalTo: split.bottomAnchor),
            meter.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            meter.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
        ])
        window.contentView = outer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let w = self.window.contentView?.bounds.width ?? frame.width
            let h = self.window.contentView?.bounds.height ?? frame.height
            _ = w
            self.split.setPosition(240, ofDividerAt: 0)
            // Desks get a third of the rail, the tree keeps the rest.
            let want = self.ui.treeOnTop ? h * 0.5 : min(self.sidebar.contentHeight, h * 0.45)
            self.rail.setPosition(max(120, min(want, h - 120)), ofDividerAt: 0)
        }

        tree.onOpen = { [weak self] url in self?.openReader(url) }
        meter.onClick = { [weak self] in self?.openMeter() }

        // The VS Code behaviour: files the agent touches open themselves.
        watcher.onChanged = { [weak self] urls in
            guard let self else { return }
            for u in urls.prefix(3) { self.reader.openFromAgent(u) }
            if !urls.isEmpty { self.openReaderWindow() }
            self.tree.refresh()
        }

        sidebar.collapsed = Set(ui.collapsed)
        sidebar.build(desks: desks)
        sidebar.onToggleGroup = { [weak self] g in self?.toggleGroup(g) }
        sidebar.onRenameGroup = { [weak self] g in self?.renameGroup(g) }
        sidebar.onRemoveDesk = { [weak self] i in self?.removeDesk(i) }
        sidebar.onMakeDefault = { [weak self] i in self?.makeDefault(i) }
        sidebar.onRevealAgent = { [weak self] i in self?.revealAgent(i) }
        sidebar.onSelect = { [weak self] i in self?.show(i) }

        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        show(DeskConfig.startup(in: desks))
        if firstRun { showWelcome() }
    }

    /// Swap which desk is on screen. The others keep running.
    func show(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        let s = sessions[d.name] ?? {
            let new = DeskSession(desk: d)
            new.term.processDelegate = self
            sessions[d.name] = new
            return new
        }()

        visible?.term.removeFromSuperview()
        host.addSubview(s.term)
        NSLayoutConstraint.activate([
            s.term.topAnchor.constraint(equalTo: host.topAnchor),
            s.term.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            s.term.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            s.term.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        s.startIfNeeded()
        visible = s
        meter.currentDesk = d.name
        // Follow the desk that is on screen.
        watcher.start(root: d.resolvedCwd)
        tree.setRoot(d.resolvedCwd)
        sidebar.select(i)
        window.title = "Deskwork — \(d.name)"
        window.makeFirstResponder(s.term)
    }

    /// cmd-1..9 jumps between desks.
    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let upd = NSMenuItem(title: "Update Deskwork…", action: #selector(openUpdate), keyEquivalent: "u")
        upd.keyEquivalentModifierMask = [.command, .shift, .option]
        upd.target = self
        appMenu.addItem(upd)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        let welcome = NSMenuItem(title: "Show Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        appMenu.addItem(welcome)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Deskwork", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let deskItem = NSMenuItem(); main.addItem(deskItem)
        let deskMenu = NSMenu(title: "Desks")
        for (i, d) in desks.prefix(9).enumerated() {
            let it = NSMenuItem(title: d.name, action: #selector(jump(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i; it.target = self
            deskMenu.addItem(it)
        }
        deskMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Files", action: #selector(refreshTree), keyEquivalent: "r")
        refresh.target = self
        deskMenu.addItem(refresh)
        let undo = NSMenuItem(title: "Undo Move", action: #selector(undoMove), keyEquivalent: "z")
        undo.target = self
        deskMenu.addItem(undo)
        let flip = NSMenuItem(title: "Tree on Top", action: #selector(toggleTreePosition), keyEquivalent: "t")
        flip.target = self
        deskMenu.addItem(flip)
        deskMenu.addItem(.separator())
        let agentsItem = NSMenuItem(title: "Agents…", action: #selector(openAgents), keyEquivalent: "a")
        agentsItem.keyEquivalentModifierMask = [.command, .shift]
        agentsItem.target = self
        deskMenu.addItem(agentsItem)
        let usage = NSMenuItem(title: "Usage…", action: #selector(openMeter), keyEquivalent: "u")
        usage.keyEquivalentModifierMask = [.command, .shift]
        usage.target = self
        deskMenu.addItem(usage)
        let mail = NSMenuItem(title: "Agent Mail…", action: #selector(openMailbox), keyEquivalent: "m")
        mail.keyEquivalentModifierMask = [.command, .shift]
        mail.target = self
        deskMenu.addItem(mail)
        deskItem.submenu = deskMenu
        NSApp.mainMenu = main
    }

    @objc func jump(_ sender: NSMenuItem) { show(sender.tag) }
    /// Removing a desk removes the shortcut. It does NOT delete the agent
    /// definition and it does NOT stop a running session — both said out loud,
    /// because guessing wrong about either would be somebody's bad afternoon.
    ///
    /// Confirmation is graduated on purpose. A desk backed by a discoverable
    /// agent or an ssh host is one click to restore, so demanding typed
    /// confirmation there is friction without risk — and friction people learn
    /// to click through stops protecting them. A desk carrying a hand-written
    /// `command` is not recoverable, so that one asks you to type its name.
    func removeDesk(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let d = desks[i]
        let running = sessions[d.name] != nil
        let recoverable = d.agent != nil || d.command?.hasPrefix("ssh -t ") == true

        var detail = "Removes it from desks.toml. Nothing else is deleted."
        if d.agent != nil {
            detail += "\n\nThe agent definition stays where it is, with its memory. "
                + "Delete that with the vendor's own tooling if you want it gone. "
                + "Deskwork will offer this desk back the next time it looks."
        } else if d.command?.hasPrefix("ssh -t ") == true {
            detail += "\n\nThe host stays in ~/.ssh/config, so Deskwork will offer it back."
        } else if let c = d.command {
            detail += "\n\nThis desk runs a command you wrote by hand and nothing else knows "
                + "about it, so removing it loses that configuration:\n\n    \(c)"
        }
        if running {
            detail += "\n\nIts session is running and keeps running until Deskwork quits."
        }

        let a = NSAlert()
        a.messageText = "Remove the \(d.name) desk?"
        a.informativeText = detail
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")

        // Unrecoverable: make them type the name.
        var field: NSTextField? = nil
        if !recoverable {
            a.alertStyle = .critical
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            f.placeholderString = "type \(d.name) to confirm"
            a.accessoryView = f
            field = f
            a.buttons.first?.title = "Remove"
        }

        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !recoverable {
            let typed = (field?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard typed == d.name else {
                let no = NSAlert()
                no.messageText = "Not removed"
                no.informativeText = typed.isEmpty
                    ? "Nothing was typed, so nothing was changed."
                    : "\"\(typed)\" does not match \"\(d.name)\", so nothing was changed."
                no.runModal()
                return
            }
        }

        desks.remove(at: i)
        DeskConfig.write(desks)
        sidebar.build(desks: desks)
        installMenu()
        if visible?.desk.name == d.name, !desks.isEmpty { show(0) }
        else if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) {
            sidebar.select(j)
        }
    }

    /// The safe half of deleting an agent: show it, let them decide.
    func revealAgent(_ i: Int) {
        guard desks.indices.contains(i), let agent = desks[i].agent else { return }
        let root = desks[i].resolvedCwd
        let candidates = [
            "\(root)/.claude/agents/\(agent).md",
            "\(root)/.github/agents/\(agent).agent.md",
            NSString(string: "~/.claude/agents/\(agent).md").expandingTildeInPath,
        ]
        if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit)])
        } else {
            let a = NSAlert()
            a.messageText = "No definition found for \(agent)"
            a.informativeText = "Looked in .claude/agents, .github/agents and ~/.claude/agents."
            a.runModal()
        }
    }

    @objc func refreshTree() { tree.refresh() }
    @objc func undoMove() { tree.undoLastMove() }

    // MARK: - NSSplitViewDelegate
    //
    // Floors on every pane. Without these the rail divider could be dragged —
    // or land, on a short window — such that the desk list had zero height and
    // no way back, which is exactly what happened with the tree on top.

    func splitView(_ sv: NSSplitView, constrainMinCoordinate p: CGFloat,
                   ofSubviewAt i: Int) -> CGFloat {
        sv === rail ? p + 80 : p + 170
    }

    func splitView(_ sv: NSSplitView, constrainMaxCoordinate p: CGFloat,
                   ofSubviewAt i: Int) -> CGFloat {
        sv === rail ? p - 120 : p - 320
    }

    func splitView(_ sv: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // The terminal absorbs resizing; the rail keeps its width.
        sv === split ? view !== rail : true
    }

    /// One default per runtime. Marking a desk clears the flag on its siblings
    /// but leaves other runtimes alone, so a Claude home and a Codex home can
    /// both exist.
    func makeDefault(_ i: Int) {
        guard desks.indices.contains(i) else { return }
        let rt = desks[i].runtime
        for j in desks.indices where desks[j].runtime == rt { desks[j].isDefault = false }
        desks[i].isDefault = true
        DeskConfig.write(desks)
        sidebar.build(desks: desks)
        if let v = visible, let j = desks.firstIndex(where: { $0.name == v.desk.name }) {
            sidebar.select(j)
        }
    }

    /// The cross-vendor bridge: drive the mailbox rather than invent a protocol.
    var updateWindow: UpdateWindow?
    @objc func openUpdate() {
        guard let root = SelfUpdate.sourceRoot else {
            let a = NSAlert()
            a.messageText = "This build has no source to update from"
            a.informativeText = "Deskwork records where it was built from when you run "
                + "scripts/build-app.sh. This bundle has no such record, or the source has moved, "
                + "so there is nothing to rebuild."
            a.runModal(); return
        }
        updateWindow = UpdateWindow(root: root)
        updateWindow?.showWindow(nil)
        updateWindow?.window?.makeKeyAndOrderFront(nil)
    }

    var settings: SettingsWindow?
    var welcome: WelcomeWindow?

    @objc func openSettings() {
        settings = SettingsWindow(projectDir: visible?.desk.resolvedCwd
                                  ?? desks.first?.resolvedCwd
                                  ?? FileManager.default.currentDirectoryPath)
        settings?.onSaved = { [weak self] in self?.reloadDesks() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showWelcome() {
        welcome = WelcomeWindow(projectDir: desks.first?.resolvedCwd
                                ?? FileManager.default.currentDirectoryPath)
        welcome?.onFinish = { [weak self] in self?.reloadDesks() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    /// Config changed under us: rebuild the rail, keep running desks alive.
    func reloadDesks() {
        let fresh = DeskConfig.load()
        guard !fresh.isEmpty else { return }
        desks = fresh
        sidebar.build(desks: desks)
        installMenu()
        if let v = visible, let i = desks.firstIndex(where: { $0.name == v.desk.name }) {
            sidebar.select(i)
        }
    }

    var agentsPanel: AgentsPanel?
    @objc func openAgents() {
        let dir = visible?.desk.resolvedCwd ?? desks.first?.resolvedCwd
                  ?? FileManager.default.currentDirectoryPath
        agentsPanel = AgentsPanel(projectDir: dir)
        agentsPanel?.onDeskAdded = { [weak self] in self?.reloadDesks() }
        agentsPanel?.onRunInDesk = { [weak self] runtime, cmd in
            self?.runInDesk(runtime: runtime, command: cmd)
        }
        agentsPanel?.showWindow(nil)
        agentsPanel?.window?.makeKeyAndOrderFront(nil)
    }

    /// Open a desk for this runtime and type a command into it. Used to hand
    /// agent creation back to the vendor instead of rebuilding it here.
    func runInDesk(runtime: String, command: String) {
        let idx = DeskConfig.general(for: runtime, in: desks)
        guard let i = idx else {
            let a = NSAlert()
            a.messageText = "No \(runtime) desk to run that in"
            a.informativeText = "Add one in Settings, then try again."
            a.runModal(); return
        }
        show(i)
        window.makeKeyAndOrderFront(nil)
        // Let the CLI finish starting before typing at it.
        let delay = sessions[desks[i].name]?.started == true ? 0.3 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.visible?.term.send(txt: command + "\n")
        }
    }

    var meterPanel: MeterPanel?
    @objc func openMeter() {
        if meterPanel == nil { meterPanel = MeterPanel() } else { meterPanel?.reload() }
        meterPanel?.showWindow(nil)
        meterPanel?.window?.makeKeyAndOrderFront(nil)
    }

    var mailPanel: MailboxPanel?
    @objc func openMailbox() {
        let from = visible?.desk.name ?? "you"
        let cwd = visible?.desk.resolvedCwd ?? NSHomeDirectory()
        if mailPanel == nil { mailPanel = MailboxPanel(cwd: cwd, from: from) }
        mailPanel?.showWindow(nil)
        mailPanel?.window?.makeKeyAndOrderFront(nil)
    }

    /// Desks above the tree, or the tree above the desks. Persisted.
    func applyRailOrder() {
        rail.arrangedSubviews.forEach { rail.removeArrangedSubview($0); $0.removeFromSuperview() }
        if ui.treeOnTop {
            rail.addArrangedSubview(tree); rail.addArrangedSubview(deskScroll)
        } else {
            rail.addArrangedSubview(deskScroll); rail.addArrangedSubview(tree)
        }
    }

    @objc func toggleTreePosition() {
        ui.treeOnTop.toggle(); ui.save()
        applyRailOrder()
        let h = window.contentView?.bounds.height ?? 800
        let want = ui.treeOnTop ? h * 0.5 : min(sidebar.contentHeight, h * 0.45)
        rail.setPosition(max(120, min(want, h - 120)), ofDividerAt: 0)
    }

    func toggleGroup(_ g: String) {
        if sidebar.collapsed.contains(g) { sidebar.collapsed.remove(g) } else { sidebar.collapsed.insert(g) }
        ui.collapsed = Array(sidebar.collapsed); ui.save()
        sidebar.build(desks: desks)
    }

    /// Renaming writes back to the config, so the change survives a restart.
    func renameGroup(_ g: String) {
        let a = NSAlert()
        a.messageText = "Rename group"
        a.informativeText = "Renames it in ~/.config/deskwork/desks.toml."
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = g
        a.accessoryView = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let new = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != g else { return }

        if let text = try? String(contentsOfFile: DeskConfig.path, encoding: .utf8) {
            let updated = text.replacingOccurrences(of: "group = \"\(g)\"", with: "group = \"\(new)\"")
            try? updated.write(toFile: DeskConfig.path, atomically: true, encoding: .utf8)
        }
        for i in desks.indices where desks[i].group == g { desks[i].group = new }
        if sidebar.collapsed.remove(g) != nil { sidebar.collapsed.insert(new) }
        ui.collapsed = Array(sidebar.collapsed); ui.save()
        sidebar.build(desks: desks)
    }

    /// Files open in their own window. Keeps the main layout to two panes and
    /// means you can leave a PDF up beside the desk that is working on it.
    var readerWindow: NSWindow?
    /// Bring the reader window up without changing what is in it.
    func openReaderWindow() {
        ensureReaderWindow()
        if readerWindow?.isVisible != true { readerWindow?.orderFront(nil) }
    }

    private func ensureReaderWindow() {
        if readerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentView = reader
            w.title = "Files"
            w.isReleasedWhenClosed = false
            if let main = window {
                w.setFrameOrigin(NSPoint(x: main.frame.maxX + 12, y: main.frame.origin.y))
            }
            readerWindow = w
        }
    }

    func openReader(_ url: URL) {
        if false {
        }
        ensureReaderWindow()
        reader.open(url)
        readerWindow?.makeKeyAndOrderFront(nil)
    }

    // LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // A desk exiting is not the app exiting. Mark it dead and leave the rest alone.
        if let name = sessions.first(where: { $0.value.term === source })?.key {
            sessions.removeValue(forKey: name)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let c = Controller()
    app.delegate = c
    app.setActivationPolicy(.regular)
    withExtendedLifetime(c) { app.run() }
}
