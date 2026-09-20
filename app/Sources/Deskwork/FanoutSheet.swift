// Fan out one question across several directories at once.
//
// The interesting part of this sheet is not the list of checkboxes, it is the
// two numbers above the Run button: how many slices, and what they will cost
// against the vendor's real remaining week. Deskwork is the only thing in the
// loop that knows that number, and a fan-out that quietly spends the rest of
// your week is a bug rather than a feature.
//
// The second thing it does is tighten the privacy boundary rather than widen
// it. One responder pointed at a whole tree reads everything; twelve
// responders each pointed at one subdirectory read one twelfth each. Slicing
// is the safer shape, and the sheet says so.

import AppKit
import DeskworkCore

final class FanoutSheet: NSWindowController {

    private let root: String
    private let rt: Bridge.Runtime
    private let box: Mailbox
    private let fromName: String
    private let question: String
    private var onDone: (String, String) -> Void = { _, _ in }

    private var rows: [(dir: String, check: NSButton)] = []
    private let budgetLine = NSTextField(labelWithString: "")
    private let adviceLine = NSTextField(wrappingLabelWithString: "")
    private let runBtn = NSButton()
    private let spinner = NSProgressIndicator()
    private let progress = NSTextField(labelWithString: "")

    /// Directories that are never worth a slice: build output, dependencies and
    /// version control. Sending an agent into `node_modules` costs a full
    /// invocation to be told there is nothing there.
    private static let skip: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "target", ".next",
        "vendor", "Pods", ".venv", "venv", "__pycache__", ".cache", "DerivedData",
    ]

    init(root: String, runtime: Bridge.Runtime, box: Mailbox, from: String,
         question: String, onDone: @escaping (String, String) -> Void) {
        self.root = root
        self.rt = runtime
        self.box = box
        self.fromName = from
        self.question = question
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: w)
        self.onDone = onDone
        w.title = "Fan out across directories"
        build()
    }
    required init?(coder: NSCoder) { nil }

    private func candidates() -> [String] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        return kids.filter { name in
            guard !name.hasPrefix("."), !FanoutSheet.skip.contains(name) else { return false }
            var isDir: ObjCBool = false
            let p = (root as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    private func build() {
        guard let w = window else { return }
        let dirs = candidates()

        let head = NSTextField(wrappingLabelString:
            "Ask \(rt.name) the same question of each directory separately, then once "
            + "more with every answer as context.\n\n"
            + "Each slice reads only its own directory, so this exposes LESS than one "
            + "question pointed at \(((root as NSString).abbreviatingWithTildeInPath)).")
        head.font = .systemFont(ofSize: 11.5)
        head.textColor = .secondaryLabelColor

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3
        for d in dirs {
            let b = NSButton(checkboxWithTitle: d, target: self, action: #selector(recount))
            b.state = .on
            list.addArrangedSubview(b)
            rows.append((d, b))
        }
        if dirs.isEmpty {
            list.addArrangedSubview(NSTextField(labelWithString:
                "No subdirectories here to slice across."))
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor),
            flipped.bottomAnchor.constraint(greaterThanOrEqualTo: list.bottomAnchor, constant: 4),
        ])
        scroll.documentView = flipped

        budgetLine.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        adviceLine.font = .systemFont(ofSize: 11.5)
        adviceLine.textColor = .secondaryLabelColor
        progress.font = .systemFont(ofSize: 11.5)
        progress.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        runBtn.title = "Run"
        runBtn.bezelStyle = .rounded
        runBtn.keyEquivalent = "\r"
        runBtn.target = self
        runBtn.action = #selector(run)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let all = NSButton(title: "All", target: self, action: #selector(selectAll_))
        let none = NSButton(title: "None", target: self, action: #selector(selectNone))
        for b in [all, none] { b.bezelStyle = .inline; b.controlSize = .small }

        let buttons = NSStackView(views: [all, none, NSView(), spinner, progress, cancel, runBtn])
        buttons.orientation = .horizontal
        buttons.distribution = .gravityAreas

        let stack = NSStackView(views: [head, scroll, budgetLine, adviceLine, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            adviceLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        recount()
    }

    @objc private func selectAll_() { for r in rows { r.check.state = .on }; recount() }
    @objc private func selectNone() { for r in rows { r.check.state = .off }; recount() }

    private var chosen: [String] { rows.filter { $0.check.state == .on }.map(\.dir) }

    /// Re-price whenever the selection changes. The number is always on screen
    /// before Run is pressed, never discovered afterwards.
    @objc private func recount() {
        let n = chosen.count
        let b = Fanout.budget(vendor: rt.name, slices: n, limits: Limits.all())
        budgetLine.stringValue = n == 0
            ? "nothing selected"
            : "\(n) slice\(n == 1 ? "" : "s") + 1 merge = \(n + 1) calls to \(rt.name)"
        adviceLine.stringValue = b.advice ?? ""
        switch b.verdict {
        case .refuse:   adviceLine.textColor = .systemRed
        case .tight:    adviceLine.textColor = .systemOrange
        default:        adviceLine.textColor = .secondaryLabelColor
        }
        runBtn.isEnabled = n > 0 && b.allowsRun
    }

    @objc private func run() {
        let dirs = chosen
        guard !dirs.isEmpty else { return }
        let slices = dirs.map {
            Slice(label: $0, cwd: (root as NSString).appendingPathComponent($0))
        }
        runBtn.isEnabled = false
        spinner.startAnimation(nil)
        progress.stringValue = "0/\(slices.count)"

        box.fanout(from: fromName, to: rt, question: question, slices: slices,
                   topic: "review",
                   onProgress: { [weak self] done, total, label in
                       self?.progress.stringValue = "\(done)/\(total) · \(label)"
                   },
                   completion: { [weak self] result in
                       guard let self else { return }
                       self.spinner.stopAnimation(nil)
                       switch result {
                       case .success(let (_, merged, dir)):
                           self.close()
                           self.onDone(merged, dir)
                       case .failure(let e):
                           self.runBtn.isEnabled = true
                           self.progress.stringValue = ""
                           let a = NSAlert()
                           a.messageText = "The fan-out did not finish"
                           a.informativeText = e.message
                           a.runModal()
                       }
                   })
    }
}

private extension NSTextField {
    convenience init(wrappingLabelString s: String) {
        self.init(wrappingLabelWithString: s)
    }
}
