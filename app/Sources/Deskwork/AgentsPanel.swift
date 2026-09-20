import AppKit
import DeskworkCore

/// Every agent on disk, in one list. Read-only, deliberately.
///
/// These files belong to the vendor. Claude Code owns .claude/agents and its
/// schema; if Deskwork wrote them back, a field added next month would be
/// silently dropped on save — and that is configuration people tune over
/// months. It also cuts against the rule the project rests on: never
/// reimplement an agent, launch the vendor's own CLI.
///
/// So this shows, opens and turns agents into desks. Editing and deleting stay
/// where they belong, and the buttons say so.
final class AgentsPanel: NSWindowController {
    var onDeskAdded: (() -> Void)?
    /// Routes to the vendor's own agent flow in a live desk.
    var onRunInDesk: ((String, String) -> Void)?   // (runtime, command to type)
    private var projectDir: String
    private let stack = NSStackView()

    init(projectDir: String) {
        self.projectDir = projectDir
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Agents"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        w.contentView = scroll
        w.center()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        stack.subviews.forEach { $0.removeFromSuperview() }
        let desks = DeskConfig.load()
        let desked = Set(desks.compactMap(\.agent))
        let agents = Discovery.agents(in: projectDir)

        let head = NSTextField(labelWithString: "\(agents.count) agents on disk")
        head.font = .systemFont(ofSize: 11, weight: .semibold)
        head.textColor = .secondaryLabelColor

        // Creating an agent well is a conversation, not a form. Route to the
        // vendor's own flow rather than building a worse one here.
        let newBtn = NSButton(title: "New agent…", target: self, action: #selector(newAgent))
        newBtn.bezelStyle = .rounded
        newBtn.toolTip = "Opens a Claude desk and runs /agents, which interviews you and writes the definition."
        let headRow = NSStackView(views: [head, NSView(), newBtn])
        headRow.orientation = .horizontal
        headRow.spacing = 10
        headRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(headRow)
        headRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true

        if agents.isEmpty {
            let l = NSTextField(wrappingLabelWithString:
                "No agent definitions found in .claude/agents, .github/agents or ~/.claude/agents.")
            l.textColor = .tertiaryLabelColor
            l.preferredMaxLayoutWidth = 680
            stack.addArrangedSubview(l)
        }

        for a in agents {
            stack.addArrangedSubview(row(a, hasDesk: desked.contains(a.name)))
        }

        let foot = NSTextField(wrappingLabelWithString:
            "Read-only on purpose. Creating an agent well is a conversation, not a form — the "
          + "vendor's own flow interviews you and writes the system prompt, which is the whole "
          + "craft. Deleting is worse to get wrong: the definition and the agent's memory "
          + "directory are separate things, and \"delete this agent\" does not say which. "
          + "New agent and Manage open the vendor's tooling in a desk; Deskwork picks up "
          + "whatever lands on disk.")
        foot.font = .systemFont(ofSize: 10.5)
        foot.textColor = .tertiaryLabelColor
        foot.preferredMaxLayoutWidth = 680
        stack.addArrangedSubview(foot)
    }

    private func row(_ a: DiscoveredAgent, hasDesk: Bool) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor

        let name = NSTextField(labelWithString: a.name)
        name.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)

        var bits = [a.runtime]
        if let m = a.model { bits.append(m) }
        bits.append(a.isProjectLevel ? "project" : "user")
        if hasDesk { bits.append("has a desk") }
        let meta = NSTextField(labelWithString: bits.joined(separator: "  ·  "))
        meta.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        meta.textColor = hasDesk ? .systemGreen : .tertiaryLabelColor

        let blurb = NSTextField(wrappingLabelWithString: a.blurb)
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 480

        let manage = NSButton(title: "Manage…", target: self, action: #selector(manage(_:)))
        manage.identifier = NSUserInterfaceItemIdentifier(a.runtime)
        manage.bezelStyle = .rounded
        manage.toolTip = "Opens a \(a.runtime) desk and runs its agent manager, where editing and deleting live."

        let reveal = NSButton(title: "Reveal", target: self, action: #selector(reveal(_:)))
        reveal.identifier = NSUserInterfaceItemIdentifier(a.path)
        reveal.bezelStyle = .rounded
        reveal.toolTip = a.path

        let add = NSButton(title: hasDesk ? "Desk exists" : "Make a desk",
                           target: self, action: #selector(addDesk(_:)))
        add.identifier = NSUserInterfaceItemIdentifier(a.name + "\u{1}" + a.runtime)
        add.bezelStyle = .rounded
        add.isEnabled = !hasDesk

        let left = NSStackView(views: [name, meta, blurb])
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 2
        let right = NSStackView(views: [reveal, manage, add])
        right.orientation = .vertical; right.spacing = 4
        let row = NSStackView(views: [left, NSView(), right])
        row.orientation = .horizontal; row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    /// The vendor's own agent manager. `/agents` in Claude Code interviews you,
    /// writes the definition, and is where deleting belongs too — it knows that
    /// an agent's memory directory is a separate thing from its definition.
    @objc private func newAgent() { route(runtime: "claude") }
    @objc private func manage(_ s: NSButton) { route(runtime: s.identifier?.rawValue ?? "claude") }

    private func route(runtime: String) {
        let cmd: String?
        switch runtime {
        case "claude":  cmd = "/agents"
        case "copilot": cmd = "/agents"
        default:        cmd = nil
        }
        guard let cmd else {
            let a = NSAlert()
            a.messageText = "\(runtime) has no agent manager Deskwork knows about"
            a.informativeText = "Create and edit its agents with its own tooling. "
                + "Deskwork will pick up whatever appears on disk."
            a.runModal(); return
        }
        onRunInDesk?(runtime, cmd)
        window?.orderOut(nil)
    }

    @objc private func reveal(_ s: NSButton) {
        guard let p = s.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc private func addDesk(_ s: NSButton) {
        guard let id = s.identifier?.rawValue else { return }
        let parts = id.split(separator: "\u{1}").map(String.init)
        guard parts.count == 2,
              let a = Discovery.agents(in: projectDir)
                  .first(where: { $0.name == parts[0] && $0.runtime == parts[1] }) else { return }
        var desks = DeskConfig.load()
        desks.append(Discovery.desk(from: a, cwd: projectDir))
        DeskConfig.write(desks)
        reload()
        onDeskAdded?()
    }
}
