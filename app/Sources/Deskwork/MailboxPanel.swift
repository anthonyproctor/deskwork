import AppKit
import DeskworkCore

/// Read the thread, write the next message, get an answer from the other vendor.
final class MailboxPanel: NSWindowController {
    static var acknowledged = Set<String>()
    private let thread = NSTextView()
    private let compose = NSTextView()
    private let target = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let readonlyNote = NSTextField(labelWithString: "")
    private let sendBtn = NSButton()
    private let spinner = NSProgressIndicator()
    private let scopeNote = NSTextField(labelWithString: "")
    private var box = Mailbox.load()
    private var cwd = NSHomeDirectory()
    private var fromName = "you"

    convenience init(cwd: String, from: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 820),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.init(window: w)
        self.cwd = cwd
        self.fromName = from
        w.title = "Agent mail"
        build()
        reload()
        w.center()
    }

    private func lbl(_ s: String, dim: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: dim ? 10 : 11, weight: dim ? .semibold : .regular)
        l.textColor = dim ? .tertiaryLabelColor : .secondaryLabelColor
        return l
    }

    private func scrolled(_ tv: NSTextView, editable: Bool) -> NSScrollView {
        tv.isEditable = editable; tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let s = NSScrollView(); s.documentView = tv
        s.hasVerticalScroller = true; s.borderType = .bezelBorder
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func build() {
        guard let c = window?.contentView else { return }
        let avail = Bridge.available()
        target.addItems(withTitles: avail.map(\.name))
        target.target = self; target.action = #selector(targetChanged)

        sendBtn.title = "Send"
        sendBtn.bezelStyle = .rounded
        sendBtn.keyEquivalent = "\r"
        sendBtn.target = self; sendBtn.action = #selector(send)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        readonlyNote.font = .systemFont(ofSize: 10); readonlyNote.textColor = .tertiaryLabelColor

        compose.string = ""
        let reloadBtn = NSButton(title: "Reload", target: self, action: #selector(reloadTapped))
        reloadBtn.bezelStyle = .rounded

        let tScroll = scrolled(thread, editable: false)
        let cScroll = scrolled(compose, editable: true)
        scopeNote.font = .systemFont(ofSize: 10.5)
        scopeNote.textColor = .secondaryLabelColor
        scopeNote.lineBreakMode = .byTruncatingMiddle
        let row = NSStackView(views: [lbl("ASK"), target, readonlyNote, NSView(), spinner, reloadBtn, sendBtn])
        row.orientation = .horizontal; row.spacing = 8

        let stack = NSStackView(views: [lbl("THREAD"), tScroll, lbl("YOUR MESSAGE"), cScroll, row, scopeNote, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: c.topAnchor),
            stack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            tScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            cScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scopeNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            cScroll.heightAnchor.constraint(equalToConstant: 160),
            tScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        targetChanged()
    }

    private var selectedRuntime: Bridge.Runtime? {
        let a = Bridge.available()
        let i = target.indexOfSelectedItem
        return a.indices.contains(i) ? a[i] : nil
    }

    @objc private func targetChanged() {
        guard let rt = selectedRuntime else {
            readonlyNote.stringValue = "no runtimes found on PATH"; return
        }
        // Never overstate the guarantee.
        readonlyNote.stringValue = rt.readOnlyEnforced
            ? "cannot write"
            : "read-only asked for in the prompt only, not enforced"
        // The honest framing: read-only stops writes, not reads.
        let scope = box.effectiveScope(deskCwd: cwd)
        scopeNote.stringValue = "\(rt.name) will be able to READ everything under "
            + (scope as NSString).abbreviatingWithTildeInPath
            + "  ·  narrow it with `scope` in bridge.toml"
        reload()
    }

    @objc private func reloadTapped() { reload() }

    private func reload() {
        guard let rt = selectedRuntime else { return }
        let path = box.threadPath(fromName, rt.name)
        let text = box.read(path)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        thread.string = lines.suffix(250).joined(separator: "\n")
        thread.scrollToEndOfDocument(nil)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
        status.stringValue = "\((path as NSString).abbreviatingWithTildeInPath)  ·  \(bytes / 1024)KB"
    }

    @objc private func send() {
        guard let rt = selectedRuntime else { return }
        let msg = compose.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }

        // Once per vendor per launch, say plainly what it will be able to read.
        let scope = box.effectiveScope(deskCwd: cwd)
        if !MailboxPanel.acknowledged.contains(rt.name) {
            let a = NSAlert()
            a.messageText = "\(rt.name) will read this directory"
            a.informativeText = "Sending this lets \(rt.name) read every file under:\n\n"
                + (scope as NSString).abbreviatingWithTildeInPath
                + "\n\nIt cannot write, but read-only is not private. If that tree holds "
                + "anything you would not hand to \(rt.name), set `scope` in "
                + "~/.config/deskwork/bridge.toml to a narrower directory first."
            a.addButton(withTitle: "Send"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            MailboxPanel.acknowledged.insert(rt.name)
        }
        compose.string = ""
        sendBtn.isEnabled = false; spinner.startAnimation(nil)
        status.stringValue = "asking \(rt.name)… the whole thread goes with it"
        box.ask(from: fromName, to: rt, message: msg, cwd: cwd) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil); self.sendBtn.isEnabled = true
            self.reload()
            if case .failure(let e) = result { self.status.stringValue = e.message }
        }
    }
}
