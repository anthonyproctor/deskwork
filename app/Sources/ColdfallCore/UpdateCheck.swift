// The daily update check, which is also how installs are counted.
//
// Once a day the app sends three things: a random ID made on this Mac, the
// app's version and the macOS version. The reply names the latest release, so
// the app can say when one is out. The server keeps no list of IDs; it adds
// each to a per-day estimate of unique installs and throws it away. The
// server's code is in this repo under server/, so what happens to the three
// things can be read, not just trusted.
//
// On a first run nothing is sent until the Welcome screen, which describes
// it and has its switch, is done. Nothing at all is sent when it is off. It never sends desks, paths, files or anything
// typed; the request is built here, from these three fields and nothing else.

import Foundation

public struct UpdateState: Codable, Equatable {
    /// Random, made once. Not derived from anything about the Mac or person.
    public var id: String = UUID().uuidString.lowercased()
    public var enabled: Bool = true
    /// Set once the Welcome screen is done (or at once, for an install that
    /// predates the check). Nothing is sent before it.
    public var noticeShown: Bool = false
    public var lastCheck: Date?
    /// The newest release the server named, and its page.
    public var latest: String?
    public var latestURL: String?

    public init() {}

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        enabled     = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        noticeShown = try c.decodeIfPresent(Bool.self, forKey: .noticeShown) ?? false
        lastCheck   = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        latest      = try c.decodeIfPresent(String.self, forKey: .latest)
        latestURL   = try c.decodeIfPresent(String.self, forKey: .latestURL)
    }

    /// Overridable so tests never touch the real data directory.
    public static var root: String = NSString(string: "~/.local/share/coldfall").expandingTildeInPath
    public static var path: String { (root as NSString).appendingPathComponent("update.json") }

    /// Loads the saved state, or makes a fresh one (with a new ID) and saves
    /// it, so the ID is stable from the first launch on.
    public static func load() -> UpdateState {
        if let d = FileManager.default.contents(atPath: path),
           let s = try? JSONDecoder().decode(UpdateState.self, from: d) { return s }
        let s = UpdateState()
        s.save()
        return s
    }

    public func save() {
        try? FileManager.default.createDirectory(atPath: UpdateState.root, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) {
            try? d.write(to: URL(fileURLWithPath: UpdateState.path), options: .atomic)
        }
    }
}

public enum UpdateCheck {

    public static let interval: TimeInterval = 24 * 3600

    /// The notice, word for word, wherever it is shown: the Welcome screen
    /// and Settings.
    public static let noticeTitle = "Project Coldfall checks for updates once a day."
    public static let noticeBody =
        "It sends a random ID made on this Mac, the app's version and your macOS version. "
        + "That's how we know how many people use it and when a new version is out for you. "
        + "It never sends your desks, files, conversations or anything you type, and we can't "
        + "tell who you are from it. You can turn this off any time in Settings."
    public static let switchLabel = "Check for updates and count this install"

    /// Where the check goes. COLDFALL_UPDATE_URL points it elsewhere for testing.
    public static var endpoint: String {
        ProcessInfo.processInfo.environment["COLDFALL_UPDATE_URL"]
            ?? "https://project-coldfall.vercel.app/api/check"
    }

    /// Whether a check should go out now.
    public static func due(_ s: UpdateState, now: Date = Date()) -> Bool {
        guard s.enabled, s.noticeShown else { return false }
        guard let last = s.lastCheck else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// A version as the server should count it. A build from source between
    /// releases reads like "v0.3.0-5-gabc1234"; every such build is reported
    /// as "v0.3.0-dev", so one commit is not one bucket and no commit hash
    /// leaves the machine.
    public static func reportedVersion(_ v: String) -> String {
        guard let (nums, rest) = split(v) else { return "unknown" }
        let base = "v" + nums.map(String.init).joined(separator: ".")
        return rest.isEmpty ? base : base + "-dev"
    }

    /// "15.6.1" from the running system, digits and dots only.
    public static func osVersion(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The whole request body. Built from exactly these three fields.
    public static func body(_ s: UpdateState, appVersion: String, os: String = osVersion()) -> Data {
        let payload = ["id": s.id, "v": reportedVersion(appVersion), "os": os]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    public struct Reply: Equatable {
        public let latest: String
        public let url: String?
        public init(latest: String, url: String?) { self.latest = latest; self.url = url }
    }

    /// The server's answer, or nil if it is not one.
    public static func parse(_ data: Data) -> Reply? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = o["latest"] as? String, split(latest) != nil else { return nil }
        // Only a release page on GitHub: the link is opened in the browser,
        // so a reply from anywhere else, or a URL that only starts with
        // https://, is dropped.
        let url = (o["url"] as? String).flatMap { s -> String? in
            guard let c = URLComponents(string: s), c.scheme == "https", c.host == "github.com",
                  c.path.hasPrefix("/anthonyproctor/project-coldfall/") else { return nil }
            return s
        }
        return Reply(latest: latest, url: url)
    }

    /// Whether `latest` is a newer release than `current`. A build from
    /// source after a release ("v0.3.0-5-g…") counts as that release, never
    /// as older, so building from main does not nag about the tag it is past.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let (a, _) = split(latest), let (b, _) = split(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "v1.2.3-rest" into ([1, 2, 3], "-rest"). Nil when it does not start
    /// with a version number.
    static func split(_ v: String) -> ([Int], String)? {
        var s = Substring(v)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        var nums: [Int] = [], digits = ""
        while let ch = s.first {
            if ch.isASCII, ch.isNumber { digits.append(ch); s = s.dropFirst() }
            else if ch == ".", !digits.isEmpty { nums.append(Int(digits) ?? 0); digits = ""; s = s.dropFirst() }
            else { break }
        }
        if !digits.isEmpty { nums.append(Int(digits) ?? 0) }
        guard !nums.isEmpty, nums.count <= 4 else { return nil }
        return (nums, String(s))
    }
}
