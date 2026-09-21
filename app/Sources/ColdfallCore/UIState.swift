import Foundation

/// Small bits of window state that should survive a restart.
public struct UIState: Codable {
    public var collapsed: [String] = []
    public var treeOnTop: Bool = false
    public var seenWelcome: Bool = false
    /// Layout toggles: cmd-B, cmd-opt-B, cmd-J.
    public var railHidden: Bool = false
    public var readerHidden: Bool = false
    public var readerPoppedOut: Bool = false
    public var meterHidden: Bool = false

    public init() {}

    /// Every field is optional on the way in.
    ///
    /// Swift's synthesised decoder THROWS on a missing key rather than using
    /// the default, and load() falls back to a fresh UIState on any failure.
    /// So adding a field used to silently wipe everyone's saved state the
    /// first time they ran the new build: the welcome screen came back and the
    /// tree moved. Decoding each key if present means an older file loads
    /// cleanly and any field added later is safe.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        collapsed       = try c.decodeIfPresent([String].self, forKey: .collapsed) ?? []
        treeOnTop       = try c.decodeIfPresent(Bool.self, forKey: .treeOnTop) ?? false
        seenWelcome     = try c.decodeIfPresent(Bool.self, forKey: .seenWelcome) ?? false
        railHidden      = try c.decodeIfPresent(Bool.self, forKey: .railHidden) ?? false
        readerHidden    = try c.decodeIfPresent(Bool.self, forKey: .readerHidden) ?? false
        readerPoppedOut = try c.decodeIfPresent(Bool.self, forKey: .readerPoppedOut) ?? false
        meterHidden     = try c.decodeIfPresent(Bool.self, forKey: .meterHidden) ?? false
    }

    public static var path: String { NSString(string: "~/.config/coldfall/ui.json").expandingTildeInPath }

    public static func load() -> UIState {
        guard let d = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(UIState.self, from: d) else { return UIState() }
        return s
    }
    public static func markSeenWelcome() {
        var s = UIState.load(); s.seenWelcome = true; s.save()
    }

    public func save() {
        let dir = (UIState.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: URL(fileURLWithPath: UIState.path))
    }
}

