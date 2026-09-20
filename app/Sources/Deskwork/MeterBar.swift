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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11, weight: .semibold)
        hint.textColor = .labelColor          // adapts; orange on light grey was unreadable
        hint.lineBreakMode = .byTruncatingTail
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 4
        hint.drawsBackground = false

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
        var left: [String] = []

        // Real plan limits when the recorder is feeding us; otherwise say why not.
        if let l = Limits.load() {
            if let w = l.weekPct {
                var seg = "week \(w)%"
                if let ra = l.weekResetsAt {
                    let f = DateFormatter(); f.dateFormat = "EEE h:mma"
                    seg += " → " + f.string(from: Date(timeIntervalSince1970: ra)).lowercased()
                }
                left.append(seg)
            }
            if let h = l.fiveHourPct {
                var seg = "5h \(h)%"
                if let ra = l.fiveHourResetsAt {
                    let m = Int(max(0, Date(timeIntervalSince1970: ra).timeIntervalSinceNow) / 60)
                    seg += " \(m / 60)h\(String(format: "%02d", m % 60))m"
                }
                left.append(seg)
            }
        }

        for (v, b) in r.byVendor.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            var seg = "\(v) \(fmt(b.tokens))"
            if let usd = b.usd { seg += String(format: " $%.0f", usd) }
            left.append(seg)
        }
        if left.isEmpty { left = ["no usage recorded this week"] }

        let f = DateFormatter(); f.dateFormat = "EEE h:mma"
        summary.stringValue = left.joined(separator: "   ·   ")
            + "      since \(f.string(from: since).lowercased())"

        if Limits.load() == nil && !Limits.isInstalled {
            hint.stringValue = "plan limits off — turn on in Settings"
            hint.textColor = .tertiaryLabelColor
        } else if let h = Usage.routerHint(r) {
            hint.stringValue = h
            hint.textColor = .labelColor
        } else {
            hint.stringValue = ""
        }
    }
}
