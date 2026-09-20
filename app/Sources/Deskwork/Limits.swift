import Foundation

/// Live plan limits, which consumption alone cannot give you.
///
/// No CLI writes its remaining quota to disk. Claude Code DOES hand its
/// statusline command a JSON payload containing `rate_limits.seven_day` and
/// `five_hour` — the real numbers, straight off the last API response. So the
/// way to get them out is to be that statusline.
///
/// Deskwork installs a recorder that writes those fields to a shared file and
/// then hands stdin to whatever statusline you already had, printing its output
/// unchanged. Your line keeps working; Deskwork gets the numbers.
struct Limits: Codable {
    var weekPct: Int?
    var weekResetsAt: Double?
    var fiveHourPct: Int?
    var fiveHourResetsAt: Double?
    var at: Double = 0

    static var path: String {
        NSString(string: "~/.local/share/deskwork/limits.json").expandingTildeInPath
    }

    static func load() -> Limits? {
        guard let d = FileManager.default.contents(atPath: path),
              let l = try? JSONDecoder().decode(Limits.self, from: d) else { return nil }
        // Stale data is worse than none: it would show a number that has moved.
        guard Date().timeIntervalSince1970 - l.at < 3600 else { return nil }
        return l
    }

    static var recorderPath: String {
        NSString(string: "~/.config/deskwork/statusline-recorder.sh").expandingTildeInPath
    }

    /// Writes the recorder and points Claude Code's statusLine at it, preserving
    /// any statusline the user already had by chaining to it.
    @discardableResult
    static func installRecorder() -> String {
        let settings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Could not read ~/.claude/settings.json"
        }

        var wrapped = ""
        if let sl = json["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String,
           !cmd.contains("statusline-recorder") {
            wrapped = cmd
        }

        let script = """
        #!/bin/bash
        # Installed by Deskwork. Records Claude Code's live rate limits so the
        # meter can show remaining quota, then hands stdin to your own
        # statusline unchanged. Remove the statusLine entry in
        # ~/.claude/settings.json to undo.
        input=$(cat)
        out="$HOME/.local/share/deskwork/limits.json"
        mkdir -p "$(dirname "$out")"
        printf '%s' "$input" | jq -c '{
          weekPct:           (.rate_limits.seven_day.used_percentage // null),
          weekResetsAt:      (.rate_limits.seven_day.resets_at       // null),
          fiveHourPct:       (.rate_limits.five_hour.used_percentage // null),
          fiveHourResetsAt:  (.rate_limits.five_hour.resets_at       // null),
          at: now
        }' > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" 2>/dev/null

        WRAPPED=\(wrapped.isEmpty ? "\"\"" : "\"\(wrapped)\"")
        if [ -n "$WRAPPED" ]; then
          printf '%s' "$input" | eval "$WRAPPED"
        fi
        """
        let dir = (recorderPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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

    static var isInstalled: Bool {
        guard let d = FileManager.default.contents(atPath:
                NSString(string: "~/.claude/settings.json").expandingTildeInPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sl = j["statusLine"] as? [String: Any],
              let c = sl["command"] as? String else { return false }
        return c.contains("statusline-recorder")
    }
}
