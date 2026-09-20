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
struct VendorLimits: Codable {
    var vendor: String
    var weekPct: Double?
    var weekResetsAt: Double?
    var fiveHourPct: Double?
    var fiveHourResetsAt: Double?
    var planType: String?
    var at: Double = 0

    var isFresh: Bool { Date().timeIntervalSince1970 - at < 3600 }
}

enum Limits {
    static var dir: String { NSString(string: "~/.local/share/deskwork/limits").expandingTildeInPath }
    static var recorderPath: String {
        NSString(string: "~/.config/deskwork/statusline-recorder.sh").expandingTildeInPath
    }

    /// Every vendor we can currently see, freshest wins, stale dropped.
    /// A number that has moved is worse than no number.
    static func all() -> [VendorLimits] {
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
        return out.filter(\.isFresh)
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
        let cutoff = Date().addingTimeInterval(-6 * 3600)
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

    static var recorderInstalled: Bool {
        guard let d = FileManager.default.contents(atPath:
                NSString(string: "~/.claude/settings.json").expandingTildeInPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sl = j["statusLine"] as? [String: Any],
              let c = sl["command"] as? String else { return false }
        return c.contains("statusline-recorder")
    }

    @discardableResult
    static func installRecorder() -> String {
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
