import AppKit

/// The meter: a strip along the bottom of the window showing where the week is
/// going, across vendors. Scanning happens off the main thread and is throttled,
/// so the bar never costs anything while you work.
final class MeterBar: NSView {
    private let summary = NSTextField(labelWithString: "reading usage…")
    private let hint = NSTextField(labelWithString: "")
    private var lastScan = Date.distantPast
    private var timer: Timer?
    var onClick: (() -> Void)?

    override func mouseDown(with e: NSEvent) { onClick?() }

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
        var segs: [String] = []
        let limits = Limits.all()

        // Quota first, per vendor. This is the number that changes behaviour.
        for l in limits.sorted(by: { ($0.weekPct ?? 0) > ($1.weekPct ?? 0) }) {
            var s = l.vendor
            if let w = l.weekPct {
                s += String(format: " wk %.0f%%", w)
                if let ra = l.weekResetsAt {
                    let f = DateFormatter(); f.dateFormat = "EEE h a"
                    s += "→" + f.string(from: Date(timeIntervalSince1970: ra)).lowercased()
                }
            }
            if let h = l.fiveHourPct { s += String(format: " · 5h %.0f%%", h) }
            segs.append(s)
        }

        // Then consumption, for whoever has no quota signal.
        for (v, b) in r.byVendor.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            if limits.contains(where: { $0.vendor == v }) { continue }
            var s = "\(v) \(fmt(b.tokens))"
            if let usd = b.usd { s += String(format: " $%.0f", usd) }
            segs.append(s)
        }

        if segs.isEmpty { segs = ["no usage recorded this week"] }
        summary.stringValue = segs.joined(separator: "     ")

        // The router: only speak when there is a real gap to act on.
        if let call = Self.routerCall(limits) {
            hint.stringValue = call
            hint.textColor = .labelColor
        } else if limits.isEmpty && !Limits.recorderInstalled {
            hint.stringValue = "plan limits off — turn on in Settings"
            hint.textColor = .tertiaryLabelColor
        } else if let h = Usage.routerHint(r) {
            hint.stringValue = h
            hint.textColor = .labelColor
        } else {
            hint.stringValue = ""
        }
    }

    /// With real quota on both sides the router stops guessing from token share
    /// and says the actionable thing: who is nearly out, who has room.
    static func routerCall(_ ls: [VendorLimits]) -> String? {
        let withWeek = ls.compactMap { l -> (String, Double)? in l.weekPct.map { (l.vendor, $0) } }
        guard withWeek.count >= 2 else {
            if let one = withWeek.first, one.1 >= 75 {
                return String(format: "%@ is %.0f%% through the week.", one.0, one.1)
            }
            return nil
        }
        let sorted = withWeek.sorted { $0.1 > $1.1 }
        guard let hot = sorted.first, let cold = sorted.last else { return nil }
        if hot.1 >= 60 && hot.1 - cold.1 >= 25 {
            return String(format: "%@ %.0f%% used, %@ only %.0f%% — send the next one to %@.",
                          hot.0, hot.1, cold.0, cold.1, cold.0)
        }
        if hot.1 >= 90 {
            return String(format: "%@ is at %.0f%%.", hot.0, hot.1)
        }
        return nil
    }
}
