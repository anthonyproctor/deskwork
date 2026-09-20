import AppKit

/// The meter: a strip along the bottom of the window showing where the week is
/// going, across vendors. Scanning happens off the main thread and is throttled,
/// so the bar never costs anything while you work.
final class MeterBar: NSView {
    private let summary = NSTextField(labelWithString: "reading usage…")
    private let hint = NSTextField(labelWithString: "")
    private var lastScan = Date.distantPast
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .systemOrange
        hint.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [summary, NSView(), hint])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }

    func refresh() {
        guard Date().timeIntervalSince(lastScan) > 30 else { return }
        lastScan = Date()
        let since = Usage.weekStart()
        DispatchQueue.global(qos: .utility).async {
            let r = Usage.scan(since: since)
            DispatchQueue.main.async { self.render(r, since: since) }
        }
    }

    private func render(_ r: Usage.Report, since: Date) {
        let f = DateFormatter(); f.dateFormat = "EEE h:mma"
        var parts: [String] = []
        for (v, b) in r.byVendor.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            var s = "\(v) \(fmt(b.tokens))"
            if let usd = b.usd { s += String(format: " ($%.0f)", usd) }
            parts.append(s)
        }
        if parts.isEmpty { parts = ["no usage recorded this week"] }
        summary.stringValue = "week from \(f.string(from: since))   ·   " + parts.joined(separator: "   ·   ")
        hint.stringValue = Usage.routerHint(r) ?? ""
    }
}
