// Deskwork M1 — the desk switcher.
//
// The agent is the unit of work. Each desk owns a long-lived terminal running
// the vendor's own CLI; switching desks swaps which one is visible without
// touching the process. Close the window, the desk keeps running.

import AppKit
import SwiftTerm

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
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // Hooks and desk-scoped behaviour key off this, same as the shell wrapper.
        env.append("CLAUDE_DESK=\(desk.name)")
        env.append("DESKWORK=1")
        term.startProcess(executable: "/bin/zsh", args: ["-l"], environment: env)

        // Land in the desk's directory, then launch its CLI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.term.send(txt: "cd \(self.desk.resolvedCwd.replacingOccurrences(of: " ", with: "\\ ")) && clear && \(self.desk.launchCommand())\n")
        }
    }
}

// MARK: - sidebar

final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?
    private var buttons: [NSButton] = []
    private var selected = -1

    func build(desks: [Desk]) {
        subviews.forEach { $0.removeFromSuperview() }
        buttons = []

        let title = NSTextField(labelWithString: "DESKS")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .tertiaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])

        var prev: NSView = title
        for (i, d) in desks.enumerated() {
            let b = NSButton(title: d.name, target: self, action: #selector(tapped(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.alignment = .left
            b.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            NSLayoutConstraint.activate([
                b.topAnchor.constraint(equalTo: prev.bottomAnchor, constant: i == 0 ? 10 : 2),
                b.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                b.heightAnchor.constraint(equalToConstant: 24),
            ])
            buttons.append(b)
            prev = b
        }
    }

    @objc private func tapped(_ sender: NSButton) { select(sender.tag); onSelect?(sender.tag) }

    func select(_ i: Int) {
        selected = i
        for (j, b) in buttons.enumerated() {
            let on = j == i
            b.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            b.font = .monospacedSystemFont(ofSize: 13, weight: on ? .bold : .regular)
            // A running desk keeps its marker even when it is not the visible one.
            b.title = (on ? "● " : "○ ") + b.title.replacingOccurrences(of: "● ", with: "").replacingOccurrences(of: "○ ", with: "")
        }
    }
}

// MARK: - app

final class Controller: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    let sidebar = SidebarView()
    let host = NSView()
    var desks: [Desk] = []
    var sessions: [String: DeskSession] = [:]
    var visible: DeskSession?

    func applicationDidFinishLaunching(_ n: Notification) {
        desks = DeskConfig.load()
        if desks.isEmpty {
            desks = [Desk(name: "shell", command: "echo 'No desks configured.'; echo 'Create \\(DeskConfig.path)'; exec zsh -l")]
        }

        let frame = NSRect(x: 0, y: 0, width: 1240, height: 780)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Deskwork"
        window.titlebarAppearsTransparent = true

        let root = NSView(frame: frame)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        root.addSubview(sidebar); root.addSubview(host)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root

        sidebar.build(desks: desks)
        sidebar.onSelect = { [weak self] i in self?.show(i) }

        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        show(0)
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
        sidebar.select(i)
        window.title = "Deskwork — \(d.name)"
        window.makeFirstResponder(s.term)
    }

    /// cmd-1..9 jumps between desks.
    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Deskwork", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let deskItem = NSMenuItem(); main.addItem(deskItem)
        let deskMenu = NSMenu(title: "Desks")
        for (i, d) in desks.prefix(9).enumerated() {
            let it = NSMenuItem(title: d.name, action: #selector(jump(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i; it.target = self
            deskMenu.addItem(it)
        }
        deskItem.submenu = deskMenu
        NSApp.mainMenu = main
    }

    @objc func jump(_ sender: NSMenuItem) { show(sender.tag) }

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
