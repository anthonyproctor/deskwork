import Foundation

/// Remaining quota, per vendor.
///
/// Consumption is easy — both CLIs write token records to disk. Quota is the
/// hard half, and each vendor exposes it differently:
///
///   Codex   writes it straight into the session rollout: an `event_msg` whose
///           payload carries `rate_limits` with a `primary` and `secondary`
///           window. Classified by `window_minutes` (300 = 5h, 10080 = week)
///           rather than by position, because position is not a contract.
///
///   Claude  tells only its statusline. So Deskwork offers to BE that
///           statusline: a recorder captures the numbers and then chains to
///           whatever statusline you already had, printing its output unchanged.
///
///   Anyone  drop `~/.local/share/deskwork/limits/<vendor>.json` with the same
///           shape and it appears. That is the extension point — a vendor
///           Deskwork has never heard of needs no code change here.
public struct VendorLimits: Codable {
    public var vendor: String
    public var weekPct: Double?
    public var weekResetsAt: Double?
    public var fiveHourPct: Double?
    public var fiveHourResetsAt: Double?
    public var planType: String?
    public var at: Double = 0

    public var age: TimeInterval { Date().timeIntervalSince1970 - at }

    /// A vendor you have not touched in hours is precisely the one with room,
    /// so an old reading is still worth showing — the weekly number barely
    /// moves while you are idle. A day is the point where it stops being
    /// trustworthy. Show the age instead of hiding the number.
    public var isUsable: Bool { age < 86_400 }
    public var isStale: Bool { age > 1_200 }

    /// A window whose reset time has passed has rolled over; its percentage is
    /// meaningless now. Drop those rather than report a number from last cycle.
    public var liveWeekPct: Double? {
        guard let r = weekResetsAt, r > Date().timeIntervalSince1970 else { return nil }
        return weekPct
    }
    public var liveFiveHourPct: Double? {
        guard let r = fiveHourResetsAt, r > Date().timeIntervalSince1970 else { return nil }
        return fiveHourPct
    }

    public var ageLabel: String? {
        guard isStale else { return nil }
        let m = Int(age / 60)
        return m < 120 ? "\(m)m ago" : "\(m / 60)h ago"
    }
}

public enum Limits {
    public static var dir: String { NSString(string: "~/.local/share/deskwork/limits").expandingTildeInPath }
    public static var recorderPath: String {
        NSString(string: "~/.config/deskwork/statusline-recorder.sh").expandingTildeInPath
    }

    /// Every vendor we can currently see, freshest wins, stale dropped.
    /// A number that has moved is worse than no number.
    public static func all() -> [VendorLimits] {
        var out: [VendorLimits] = []
        if let c = fromDroppedFile("claude") ?? legacyClaudeFile() { out.append(c) }
        if let x = fromCodexRollouts() { out.append(x) }
        for v in ["gemini", "copilot"] {
            if let g = fromDroppedFile(v) { out.append(g) }
        }
        // Anything else someone dropped in.
        if let extra = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in extra where f.hasSuffix(".json") {
                let name = String(f.dropLast(5))
                if out.contains(where: { $0.vendor == name }) { continue }
                if let v = fromDroppedFile(name) { out.append(v) }
            }
        }
        return out.filter(\.isUsable)
    }

    private static func fromDroppedFile(_ vendor: String) -> VendorLimits? {
        let p = (dir as NSString).appendingPathComponent("\(vendor).json")
        guard let d = FileManager.default.contents(atPath: p),
              var v = try? JSONDecoder().decode(VendorLimits.self, from: d) else { return nil }
        v.vendor = vendor
        return v
    }

    /// Earlier builds wrote a single flat file; keep reading it.
    private static func legacyClaudeFile() -> VendorLimits? {
        let p = NSString(string: "~/.local/share/deskwork/limits.json").expandingTildeInPath
        guard let d = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return VendorLimits(vendor: "claude",
                            weekPct: (o["weekPct"] as? NSNumber)?.doubleValue,
                            weekResetsAt: (o["weekResetsAt"] as? NSNumber)?.doubleValue,
                            fiveHourPct: (o["fiveHourPct"] as? NSNumber)?.doubleValue,
                            fiveHourResetsAt: (o["fiveHourResetsAt"] as? NSNumber)?.doubleValue,
                            planType: nil,
                            at: (o["at"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Codex writes quota into its own session log, so nothing needs installing.
    private static func fromCodexRollouts() -> VendorLimits? {
        let root = NSString(string: "~/.codex/sessions").expandingTildeInPath
        guard let e = FileManager.default.enumerator(atPath: root) else { return nil }
        var newest: (Date, String)? = nil
        // Match isUsable (24h). A 6h file cutoff silently discarded readings
        // that the freshness rule would have accepted, so an idle vendor
        // vanished for the wrong reason.
        let cutoff = Date().addingTimeInterval(-86_400)
        for case let rel as String in e where rel.hasSuffix(".jsonl") {
            let p = (root as NSString).appendingPathComponent(rel)
            guard let a = try? FileManager.default.attributesOfItem(atPath: p),
                  let m = a[.modificationDate] as? Date, m > cutoff else { continue }
            if newest == nil || m > newest!.0 { newest = (m, p) }
        }
        guard let (_, path) = newest,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        var found: VendorLimits? = nil
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = o["payload"] as? [String: Any],
                  let rl = p["rate_limits"] as? [String: Any] else { continue }

            var v = VendorLimits(vendor: "codex")
            v.planType = rl["plan_type"] as? String
            // Classify by window length, not by which key it happened to be in.
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any],
                      let mins = (w["window_minutes"] as? NSNumber)?.intValue else { continue }
                let pct = (w["used_percent"] as? NSNumber)?.doubleValue
                let reset = (w["resets_at"] as? NSNumber)?.doubleValue
                if mins >= 7 * 24 * 60 - 60 { v.weekPct = pct; v.weekResetsAt = reset }
                else { v.fiveHourPct = pct; v.fiveHourResetsAt = reset }
            }
            if let ts = o["timestamp"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                v.at = (f.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) ?? Date()).timeIntervalSince1970
            }
            found = v            // keep the last one in the file: newest wins
        }
        return found
    }

    // MARK: - the Claude recorder

    public static var recorderInstalled: Bool {
        guard let d = FileManager.default.contents(atPath:
                NSString(string: "~/.claude/settings.json").expandingTildeInPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sl = j["statusLine"] as? [String: Any],
              let c = sl["command"] as? String else { return false }
        return c.contains("statusline-recorder")
    }

    @discardableResult
    public static func installRecorder() -> String {
        let settings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Could not read ~/.claude/settings.json"
        }
        var wrapped = ""
        if let sl = json["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String, !cmd.contains("statusline-recorder") {
            wrapped = cmd
        }
        let script = """
        #!/bin/bash
        # Installed by Deskwork. Captures Claude Code's live rate limits so the
        # meter can show remaining quota, then hands stdin to your own statusline
        # unchanged. To undo, point statusLine in ~/.claude/settings.json back at
        # your own script.
        input=$(cat)
        out="$HOME/.local/share/deskwork/limits/claude.json"
        mkdir -p "$(dirname "$out")"
        printf '%s' "$input" | jq -c '{
          vendor: "claude",
          weekPct:          (.rate_limits.seven_day.used_percentage // null),
          weekResetsAt:     (.rate_limits.seven_day.resets_at       // null),
          fiveHourPct:      (.rate_limits.five_hour.used_percentage // null),
          fiveHourResetsAt: (.rate_limits.five_hour.resets_at       // null),
          at: now
        }' > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" 2>/dev/null

        # Context window is per SESSION, not per vendor, so it is keyed by the
        # desk name Claude Code reports. Each desk writes its own file and they
        # stop overwriting one another.
        name=$(printf '%s' "$input" | jq -r '.session_name // .agent.name // empty' 2>/dev/null)
        if [ -n "$name" ]; then
          sdir="$HOME/.local/share/deskwork/sessions"
          mkdir -p "$sdir"
          printf '%s' "$input" | jq -c '{
            desk:   (.session_name // .agent.name),
            ctxPct: (.context_window.used_percentage // null),
            model:  (.model.display_name // null),
            effort: (.effort.level // null),
            usd:    (.cost.total_cost_usd // null),
            at: now
          }' > "$sdir/$name.json.tmp" 2>/dev/null && mv "$sdir/$name.json.tmp" "$sdir/$name.json" 2>/dev/null
        fi

        WRAPPED=\(wrapped.isEmpty ? "\"\"" : "\"\(wrapped)\"")
        if [ -n "$WRAPPED" ]; then
          printf '%s' "$input" | eval "$WRAPPED"
        fi
        """
        try? FileManager.default.createDirectory(
            atPath: (recorderPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try script.write(toFile: recorderPath, atomically: true, encoding: .utf8) }
        catch { return "Could not write the recorder: \(error)" }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorderPath)

        json["statusLine"] = ["type": "command", "command": recorderPath, "padding": 0]
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: settings))) != nil else {
            return "Could not write ~/.claude/settings.json"
        }
        return wrapped.isEmpty
            ? "Installed. Limits appear after your next Claude message."
            : "Installed, chaining to your existing statusline. Limits appear after your next Claude message."
    }
}


/// Per-desk state, written by the same recorder. Context is a property of a
/// session, so it is keyed by desk rather than by vendor.
public struct DeskState: Codable {
    public var desk: String
    public var ctxPct: Double?
    public var model: String?
    public var effort: String?
    public var usd: Double?
    public var at: Double = 0

    public static var dir: String { NSString(string: "~/.local/share/deskwork/sessions").expandingTildeInPath }

    public static func load(_ desk: String) -> DeskState? {
        let p = (dir as NSString).appendingPathComponent("\(desk).json")
        guard let d = FileManager.default.contents(atPath: p),
              let s = try? JSONDecoder().decode(DeskState.self, from: d) else { return nil }
        // Context moves fast and only while the desk is working, so an old
        // reading is genuinely misleading here — unlike weekly quota.
        return Date().timeIntervalSince1970 - s.at < 900 ? s : nil
    }
}
