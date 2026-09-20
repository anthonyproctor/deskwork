import AppKit

/// Click the meter to open this: quota per vendor, then where it went.
final class MeterPanel: NSWindowController {
    private let stack = NSStackView()
    private var report = Usage.Report()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.init(window: w)
        w.title = "Usage"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        // An NSStackView used as a documentView has no size of its own. Without
        // these it lays out at zero and the window renders blank.
        // AppKit lays out from the bottom unless the documentView is flipped,
        // which is why the content sat at the foot of an empty window.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
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

    private func caps(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 9.5, weight: .semibold); l.textColor = .tertiaryLabelColor
        return l
    }
    private func mono(_ s: String, _ size: CGFloat = 11.5, _ w: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: size, weight: w)
        return l
    }
    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }
    /// A bar drawn in text keeps this readable in both themes with no colour tricks.
    /// Swift-native padding. String(format: "%-8s", ...) needs a C string and
    /// silently emits garbage when handed a Swift String — that is where the
    /// `¯ÊH˘` in the first build came from.
    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    private func lpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    private func bar(_ pct: Double, width: Int = 34) -> String {
        let f = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
        return String(repeating: "█", count: f) + String(repeating: "░", count: width - f)
    }

    func reload() {
        stack.subviews.forEach { $0.removeFromSuperview() }
        let since = Usage.weekStart()
        let df = DateFormatter(); df.dateFormat = "EEE h a"

        // ---- quota, the number that changes behaviour
        stack.addArrangedSubview(caps("PLAN REMAINING"))
        let limits = Limits.all()
        if limits.isEmpty {
            stack.addArrangedSubview(mono("no live quota — turn it on in Settings"))
        }
        for l in limits.sorted(by: { ($0.liveWeekPct ?? 0) > ($1.liveWeekPct ?? 0) }) {
            var line = pad(l.vendor, 9)
            if let w = l.liveWeekPct {
                line += "week  \(bar(w))  " + String(format: "%5.1f%%", w)
                if let r = l.weekResetsAt {
                    line += "  resets " + df.string(from: Date(timeIntervalSince1970: r)).lowercased()
                }
            }
            if l.liveWeekPct == nil && l.liveFiveHourPct == nil {
                line += "no live window — reading is from a cycle that has reset"
            }
            if let p = l.planType { line += "   (\(p))" }
            if let a = l.ageLabel { line += "   \(a)" }
            stack.addArrangedSubview(mono(line, 12, .medium))
            if let h = l.liveFiveHourPct {
                var s = pad("", 9) + "5h    \(bar(h))  " + lpad(String(format: "%.1f%%", h), 6)
                if let r = l.fiveHourResetsAt {
                    let m = Int(max(0, Date(timeIntervalSince1970: r).timeIntervalSinceNow) / 60)
                    s += "  \(m / 60)h\(String(format: "%02d", m % 60))m"
                }
                let f = mono(s); f.textColor = .secondaryLabelColor
                stack.addArrangedSubview(f)
            }
        }

        if let call = MeterBar.routerCall(limits) {
            let c = NSTextField(labelWithString: "→ " + call)
            c.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addArrangedSubview(c)
        }

        stack.addArrangedSubview(caps("SCANNING…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Usage.scan(since: since)
            DispatchQueue.main.async { self.report = r; self.renderUsage(since: since) }
        }
    }

    private func renderUsage(since: Date) {
        // drop the placeholder
        if let last = stack.arrangedSubviews.last as? NSTextField, last.stringValue == "SCANNING…" {
            last.removeFromSuperview()
        }
        let df = DateFormatter(); df.dateFormat = "EEE h a"
        let total = report.byVendor.values.reduce(0) { $0 + $1.tokens }

        stack.addArrangedSubview(caps("THIS WEEK, SINCE \(df.string(from: since).uppercased())"))
        for (v, b) in report.byVendor.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            let share = total > 0 ? Double(b.tokens) / Double(total) * 100 : 0
            var s = pad(v, 9) + lpad(fmt(b.tokens), 9) + " tokens  "
                  + bar(share, width: 20) + lpad(String(format: "%.1f%%", share), 7)
            if let usd = b.usd { s += String(format: "   $%.0f", usd) }
            stack.addArrangedSubview(mono(s))
        }
        if report.byVendor.isEmpty { stack.addArrangedSubview(mono("nothing recorded this week")) }

        // ---- per desk: only Claude names its sessions, so say so rather than
        // silently showing a partial picture.
        if !report.byDesk.isEmpty {
            stack.addArrangedSubview(caps("BY DESK  (claude sessions that were given a name)"))
            let deskTotal = report.byDesk.values.reduce(0) { $0 + $1.tokens }
            for (d, b) in report.byDesk.sorted(by: { $0.value.tokens > $1.value.tokens }).prefix(15) {
                let share = deskTotal > 0 ? Double(b.tokens) / Double(deskTotal) * 100 : 0
                var s = pad(d, 15) + lpad(fmt(b.tokens), 9) + "  "
                      + bar(share, width: 18) + lpad(String(format: "%.1f%%", share), 7)
                      + lpad("\(b.calls)", 7) + " calls"
                if let usd = b.usd { s += String(format: "  $%.0f", usd) }
                stack.addArrangedSubview(mono(s))
            }
        }

        // ---- last 14 days
        stack.addArrangedSubview(caps("LAST 14 DAYS"))
        let days = report.byDay.keys.sorted().suffix(14)
        let peak = report.byDay.values.map { $0.values.reduce(0, +) }.max() ?? 1
        let fin = DateFormatter(); fin.dateFormat = "yyyy-MM-dd"
        let fout = DateFormatter(); fout.dateFormat = "EEE dd"
        for k in days {
            let byV = report.byDay[k] ?? [:]
            let t = byV.values.reduce(0, +)
            let label = fin.date(from: k).map { fout.string(from: $0) } ?? k
            let width = max(1, Int(Double(t) / Double(peak) * 44))
            let breakdown = byV.sorted { $0.value > $1.value }
                .map { "\($0.key) \(fmt($0.value))" }.joined(separator: " · ")
            stack.addArrangedSubview(mono(
                pad(label, 8) + pad(String(repeating: "▇", count: width), 46) + " " + breakdown))
        }

        let foot = NSTextField(wrappingLabelWithString:
            "Read from files the CLIs already write. Claude records are deduplicated on message.id — "
          + "a streamed reply is written more than once and counting every record roughly doubles the total. "
          + "Dollar figures are Claude list prices; no price is guessed for other vendors.")
        foot.font = .systemFont(ofSize: 10.5)
        foot.textColor = .tertiaryLabelColor
        foot.preferredMaxLayoutWidth = 760
        stack.addArrangedSubview(caps(""))
        stack.addArrangedSubview(foot)
    }
}


/// AppKit's default coordinate system puts the origin at the bottom left, so an
/// unflipped documentView stacks its content upward from the foot of the window.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
