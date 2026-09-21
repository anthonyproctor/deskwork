import AppKit
import ColdfallCore

/// Settings, so nobody has to hand-edit TOML to use this.
///
/// Three things people need to change: which desks exist, which CLIs Coldfall
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
    private let themePalette = NSPopUpButton()
    private let themeMode = NSPopUpButton()
    private let themeFont = NSTextField()
    private let themeSize = NSTextField()
    private var editing: Int?
    private var projectDir = FileManager.default.currentDirectoryPath
    private let discoveredStack = NSStackView()
    private let hostsStack = NSStackView()

    convenience init(projectDir: String = FileManager.default.currentDirectoryPath) {
        // Never taller than the screen it opens on.
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(860, vis.width - 40),
                                             height: min(600, vis.height - 60)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 700, height: 420)
        self.init(window: w)
        w.title = "Project Coldfall Settings"
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
    private func note(_ s: String, width: CGFloat = 520) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = width
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
               + "already have a wrapper script that handles resume-vs-new.", width: 350),
        ])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 6

        // Appearance belongs here, not only in a TOML file. "Where do I go to
        // change the theme" having no answer but "edit a config file" is a
        // wrong answer for the thing a user looks at all day.
        let t = DeskConfig.themeSettings()
        themePalette.addItems(withTitles: ["vscode", "gruvbox", "nord", "solarized"])
        themePalette.selectItem(withTitle: t.palette ?? "vscode")
        themeMode.addItems(withTitles: ["dark", "light", "system"])
        themeMode.selectItem(withTitle: t.mode ?? "dark")
        themeFont.stringValue = t.font ?? "JetBrainsMono Nerd Font Mono"
        themeFont.placeholderString = "font, e.g. JetBrains Mono"
        themeSize.stringValue = String(t.size ?? 14)
        themeSize.placeholderString = "size"
        for f in [themeFont, themeSize] { f.font = .systemFont(ofSize: 12) }
        themeSize.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let themeRow = NSStackView(views: [themePalette, themeMode, themeSize])
        themeRow.orientation = .horizontal; themeRow.spacing = 8
        let themeBlock = NSStackView(views: [
            caps("APPEARANCE"), themeRow, themeFont,
            note("nord and solarized are dark only and stay dark in light mode, "
               + "rather than inventing a light variant badly. A font that is not "
               + "installed falls back to the next one that is."),
        ])
        themeBlock.orientation = .vertical; themeBlock.alignment = .leading; themeBlock.spacing = 6

        let addBtn = NSButton(title: "Add / Update", target: self, action: #selector(addOrUpdate))
        let delBtn = NSButton(title: "Remove", target: self, action: #selector(remove))
        let saveBtn = NSButton(title: "Save to desks.toml", target: self, action: #selector(save))
        saveBtn.keyEquivalent = "\r"
        [addBtn, delBtn, saveBtn].forEach { $0.bezelStyle = .rounded }
        let btns = NSStackView(views: [addBtn, delBtn, NSView(), saveBtn])
        btns.orientation = .horizontal; btns.spacing = 8

        // What Coldfall actually found, and what it can guarantee.
        var rtLines: [NSView] = [caps("RUNTIMES DETECTED")]
        for rt in Bridge.known {
            let p = DeskConfig.which(rt.bin)
            let l = NSTextField(labelWithString: (p != nil ? "✓  " : "✗  ") + rt.name
                + (p != nil ? (rt.readOnlyEnforced ? "   read-only enforced" : "   read-only not enforced") : "   not installed"))
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = p != nil ? .labelColor : .tertiaryLabelColor
            rtLines.append(l)
            // Not installed: how to install it, right there.
            if p == nil, let v = VendorInstall.of(rt.name) {
                let cmd = NSTextField(labelWithString: v.command)
                cmd.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                cmd.textColor = .secondaryLabelColor
                cmd.isSelectable = true
                let row = NSStackView(views: [cmd, CopyButton(text: v.command)])
                row.orientation = .horizontal; row.spacing = 6
                row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
                rtLines.append(row)
            }
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
            + "Any other tool can join by writing ~/.local/share/coldfall/limits/<vendor>.json."))
        rtLines.append(caps("AGENTS FOUND ON DISK"))
        discoveredStack.orientation = .vertical
        discoveredStack.alignment = .leading
        discoveredStack.spacing = 3
        rtLines.append(discoveredStack)
        rtLines.append(note("Agent definitions already in .claude/agents or .github/agents that "
            + "have no desk yet. Adding one creates a desk that launches the vendor's own CLI "
            + "with that agent."))
        refreshDiscovered()

        rtLines.append(caps("SSH HOSTS"))
        hostsStack.orientation = .vertical
        hostsStack.alignment = .leading
        hostsStack.spacing = 3
        rtLines.append(hostsStack)
        rtLines.append(note("Hosts from ~/.ssh/config with no desk yet. A remote box is exactly "
            + "what a desk is for — it holds state between visits. Connects by alias, so ssh "
            + "applies identity files and jump hosts from your own config."))
        refreshHosts()

        rtLines.append(caps("AGENT MAIL"))
        let box = Mailbox.load()
        rtLines.append(note("Threads are appended to \((box.dir as NSString).abbreviatingWithTildeInPath)."
            + (box.runner != nil ? " Using your own runner: \(box.runner!)." : " Using the built-in handoff.")))

        var updLines: [NSView] = [caps("UPDATES")]
        let upd = UpdateState.load()
        let updSwitch = NSButton(checkboxWithTitle: UpdateCheck.switchLabel, target: self,
                                 action: #selector(toggleUpdateCheck(_:)))
        updSwitch.state = upd.enabled ? .on : .off
        updLines.append(updSwitch)
        updLines.append(note(UpdateCheck.noticeBody.replacingOccurrences(
            of: " You can turn this off any time in Settings.", with: "")
            + " The server's code is in the repo under server/."))

        // Four tabs instead of one column. The single column was taller than
        // a laptop screen, and the window could not be made to fit it.
        let deskSide = NSStackView(views: [form, btns])
        deskSide.orientation = .vertical; deskSide.alignment = .leading; deskSide.spacing = 10
        let desksTab = NSStackView(views: [tScroll, deskSide])
        desksTab.orientation = .horizontal; desksTab.alignment = .top; desksTab.spacing = 16
        deskSide.widthAnchor.constraint(equalToConstant: 350).isActive = true
        tScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, content, scrolls) in [("Desks", desksTab as NSView, false),
                                          ("Appearance", column([themeBlock]), true),
                                          ("Agents", column(rtLines), true),
                                          ("Updates", column(updLines), true)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = pad(content, scrolls: scrolls)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs
        c.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
            tabs.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            tabs.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
        ])
    }

    private(set) var tabs: NSTabView?

    /// A vertical run of settings, as wide as a note.
    private func column(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 10
        return s
    }

    /// Inset a tab's content, and let it scroll when it is taller than the
    /// window rather than running off the bottom of the screen.
    private func pad(_ content: NSView, scrolls: Bool) -> NSView {
        let box = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        guard scrolls else {
            box.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            ])
            return box
        }
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -20),
        ])
        return box
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

    private func refreshHosts() {
        hostsStack.subviews.forEach { $0.removeFromSuperview() }
        let found = SSHHosts.undesked(desks: desks)
        if found.isEmpty {
            let l = NSTextField(labelWithString:
                SSHHosts.all().isEmpty ? "no ~/.ssh/config hosts found" : "every host already has a desk")
            l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            hostsStack.addArrangedSubview(l)
            return
        }
        for h in found.prefix(20) {
            let b = NSButton(title: "＋  \(h.alias)   \(h.blurb)", target: self,
                             action: #selector(addHost(_:)))
            b.bezelStyle = .inline; b.isBordered = false; b.alignment = .left
            b.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            b.contentTintColor = .controlAccentColor
            b.toolTip = h.command
            b.identifier = NSUserInterfaceItemIdentifier(h.alias)
            hostsStack.addArrangedSubview(b)
        }
    }

    @objc private func addHost(_ sender: NSButton) {
        guard let alias = sender.identifier?.rawValue,
              let h = SSHHosts.all().first(where: { $0.alias == alias }) else { return }
        desks.append(SSHHosts.desk(from: h))
        table.reloadData(); refreshHosts()
    }

    @objc private func addOrUpdate() {
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { NSSound.beep(); return }
        // Start from the desk being edited, so what this form does not show
        // (agent, model, default, trimmed MCP servers) survives the edit.
        var d = desks.first(where: { $0.name == n }) ?? Desk(name: n)
        d.group = group.stringValue.isEmpty ? nil : group.stringValue
        d.cwd = cwd.stringValue.isEmpty ? nil : cwd.stringValue
        d.command = command.stringValue.isEmpty ? nil : command.stringValue
        d.runtime = runtime.titleOfSelectedItem ?? "claude"
        if let i = desks.firstIndex(where: { $0.name == n }) { desks[i] = d } else { desks.append(d) }
        table.reloadData()
    }

    @objc private func toggleUpdateCheck(_ sender: NSButton) {
        var s = UpdateState.load()
        s.enabled = sender.state == .on
        s.noticeShown = true        // they have plainly seen it now
        s.save()
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
        refreshDiscovered(); refreshHosts()
    }

    @objc private func save() {
        // The theme goes out with the desks. Saving used to rebuild the file
        // from the desk list alone, which silently deleted [theme].
        var t = DeskConfig.themeSettings()
        t.palette = themePalette.titleOfSelectedItem
        t.mode = themeMode.titleOfSelectedItem
        t.font = themeFont.stringValue.trimmingCharacters(in: .whitespaces)
        t.size = Int(themeSize.stringValue) ?? t.size
        Theme.invalidate()
        defer { Theme.applyGlobally() }   // switching dark/light takes effect now, every window
        DeskConfig.write(desks, theme: t)
        onSaved?()
        close()
    }
}
