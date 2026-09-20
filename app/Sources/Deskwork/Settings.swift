import AppKit
import DeskworkCore

/// Settings, so nobody has to hand-edit TOML to use this.
///
/// Three things people need to change: which desks exist, which CLIs Deskwork
/// found, and where agent mail lives. Writing the config back out keeps the file
/// as the source of truth — you can still edit it by hand, and this never
/// silently owns it.
final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onSaved: (() -> Void)?
    private var desks: [Desk] = []
    private let table = NSTableView()
    private let name = NSTextField(), group = NSTextField()
    private let cwd = NSTextField(), command = NSTextField()
    private let runtime = NSPopUpButton()
    private var editing: Int?
    private var projectDir = FileManager.default.currentDirectoryPath
    private let discoveredStack = NSStackView()

    convenience init(projectDir: String = FileManager.default.currentDirectoryPath) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.init(window: w)
        w.title = "Deskwork Settings"
        self.projectDir = projectDir
        desks = DeskConfig.load()
        build()
        w.center()
    }

    private func caps(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 9.5, weight: .semibold); l.textColor = .tertiaryLabelColor
        return l
    }
    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 360
        return l
    }
    private func field(_ f: NSTextField, _ ph: String) -> NSView {
        f.placeholderString = ph
        f.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        return f
    }

    private func build() {
        guard let c = window?.contentView else { return }

        for col in [("name", "Desk", 110), ("group", "Group", 130),
                    ("how", "Runs", 420)] {
            let t = NSTableColumn(identifier: .init(col.0))
            t.title = col.1; t.width = CGFloat(col.2)
            table.addTableColumn(t)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let tScroll = NSScrollView(); tScroll.documentView = table
        tScroll.hasVerticalScroller = true; tScroll.borderType = .bezelBorder
        tScroll.translatesAutoresizingMaskIntoConstraints = false

        runtime.addItems(withTitles: ["claude", "codex", "gemini", "copilot", "grok", "ollama"])
        let form = NSStackView(views: [
            caps("DESK"),
            field(name, "name, e.g. api"),
            field(group, "group (optional), e.g. work"),
            caps("RUNTIME"), runtime,
            field(cwd, "working directory, e.g. ~/src/api"),
            caps("OR RUN THIS VERBATIM"),
            field(command, "command (optional) — overrides runtime"),
            note("Leave command empty to launch the runtime's own CLI. Use it when you "
               + "already have a wrapper script that handles resume-vs-new."),
        ])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 6

        let addBtn = NSButton(title: "Add / Update", target: self, action: #selector(addOrUpdate))
        let delBtn = NSButton(title: "Remove", target: self, action: #selector(remove))
        let saveBtn = NSButton(title: "Save to desks.toml", target: self, action: #selector(save))
        saveBtn.keyEquivalent = "\r"
        [addBtn, delBtn, saveBtn].forEach { $0.bezelStyle = .rounded }
        let btns = NSStackView(views: [addBtn, delBtn, NSView(), saveBtn])
        btns.orientation = .horizontal; btns.spacing = 8

        // What Deskwork actually found, and what it can guarantee.
        var rtLines: [NSView] = [caps("RUNTIMES DETECTED")]
        for rt in Bridge.known {
            let p = DeskConfig.which(rt.bin)
            let l = NSTextField(labelWithString: (p != nil ? "✓  " : "✗  ") + rt.name
                + (p != nil ? (rt.readOnlyEnforced ? "   read-only enforced" : "   read-only not enforced") : "   not installed"))
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = p != nil ? .labelColor : .tertiaryLabelColor
            rtLines.append(l)
        }
        rtLines.append(caps("LIVE PLAN LIMITS"))
        let limitsBtn = NSButton(title: Limits.recorderInstalled ? "Claude recorder installed ✓" : "Turn on live limits for Claude",
                                 target: self, action: #selector(installLimits))
        limitsBtn.bezelStyle = .rounded
        limitsBtn.isEnabled = !Limits.recorderInstalled
        rtLines.append(limitsBtn)
        var seen: [String] = []
        for l in Limits.all() {
            var t = "✓  \(l.vendor)"
            if let w = l.weekPct { t += String(format: "  week %.0f%%", w) }
            if let p = l.planType { t += "  (\(p))" }
            seen.append(t)
        }
        let live = NSTextField(labelWithString: seen.isEmpty ? "no live limits yet" : seen.joined(separator: "\n"))
        live.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rtLines.append(live)
        rtLines.append(note("Codex writes its quota into its own session log, so it needs nothing. "
            + "Claude tells only its statusline, so the button above installs a recorder as that "
            + "statusline — any statusline you already have keeps working, the recorder chains to it. "
            + "Any other tool can join by writing ~/.local/share/deskwork/limits/<vendor>.json."))
        rtLines.append(caps("AGENTS FOUND ON DISK"))
        discoveredStack.orientation = .vertical
        discoveredStack.alignment = .leading
        discoveredStack.spacing = 3
        rtLines.append(discoveredStack)
        rtLines.append(note("Agent definitions already in .claude/agents or .github/agents that "
            + "have no desk yet. Adding one creates a desk that launches the vendor's own CLI "
            + "with that agent."))
        refreshDiscovered()

        rtLines.append(caps("AGENT MAIL"))
        let box = Mailbox.load()
        rtLines.append(note("Threads are appended to \((box.dir as NSString).abbreviatingWithTildeInPath)."
            + (box.runner != nil ? " Using your own runner: \(box.runner!)." : " Using the built-in handoff.")))

        let right = NSStackView(views: [form, btns] + rtLines)
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 10

        let split = NSStackView(views: [tScroll, right])
        split.orientation = .horizontal; split.spacing = 16
        split.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        split.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: c.topAnchor),
            split.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            tScroll.widthAnchor.constraint(equalToConstant: 440),
            right.widthAnchor.constraint(equalToConstant: 370),
        ])
    }

    func numberOfRows(in t: NSTableView) -> Int { desks.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let d = desks[row]
        let s: String
        switch col?.identifier.rawValue {
        case "name":  s = d.name
        case "group": s = d.group ?? "—"
        default:      s = d.command ?? (d.agent.map { "\(d.runtime) --agent \($0)" } ?? d.runtime)
        }
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.lineBreakMode = .byTruncatingMiddle
        l.isBordered = false; l.drawsBackground = false
        return l
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let r = table.selectedRow
        guard desks.indices.contains(r) else { return }
        editing = r
        let d = desks[r]
        name.stringValue = d.name
        group.stringValue = d.group ?? ""
        cwd.stringValue = d.cwd ?? ""
        command.stringValue = d.command ?? ""
        runtime.selectItem(withTitle: d.runtime)
    }

    /// Only agents without a desk are worth showing; the rest is noise.
    private func refreshDiscovered() {
        discoveredStack.subviews.forEach { $0.removeFromSuperview() }
        let found = Discovery.undeskedAgents(in: projectDir, desks: desks)
        if found.isEmpty {
            let l = NSTextField(labelWithString: "every agent already has a desk")
            l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            discoveredStack.addArrangedSubview(l)
            return
        }
        for a in found.prefix(20) {
            let b = NSButton(title: "＋  \(a.name)   \(a.runtime)", target: self,
                             action: #selector(addDiscovered(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.alignment = .left
            b.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            b.contentTintColor = .controlAccentColor
            b.toolTip = a.blurb + "\n\n" + a.path
            b.identifier = NSUserInterfaceItemIdentifier(a.name + "\u{1}" + a.runtime)
            discoveredStack.addArrangedSubview(b)
        }
    }

    @objc private func addDiscovered(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: "\u{1}").map(String.init)
        guard parts.count == 2,
              let a = Discovery.agents(in: projectDir).first(where: { $0.name == parts[0] && $0.runtime == parts[1] })
        else { return }
        desks.append(Discovery.desk(from: a, cwd: projectDir))
        table.reloadData()
        refreshDiscovered()
    }

    @objc private func addOrUpdate() {
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { NSSound.beep(); return }
        var d = Desk(name: n)
        d.group = group.stringValue.isEmpty ? nil : group.stringValue
        d.cwd = cwd.stringValue.isEmpty ? nil : cwd.stringValue
        d.command = command.stringValue.isEmpty ? nil : command.stringValue
        d.runtime = runtime.titleOfSelectedItem ?? "claude"
        if let i = desks.firstIndex(where: { $0.name == n }) { desks[i] = d } else { desks.append(d) }
        table.reloadData()
    }

    @objc private func installLimits() {
        let msg = Limits.installRecorder()
        let a = NSAlert(); a.messageText = "Live plan limits"; a.informativeText = msg
        a.runModal()
    }

    @objc private func remove() {
        guard desks.indices.contains(table.selectedRow) else { return }
        desks.remove(at: table.selectedRow)
        table.reloadData()
        refreshDiscovered()
    }

    @objc private func save() {
        DeskConfig.write(desks)
        onSaved?()
        close()
    }
}
