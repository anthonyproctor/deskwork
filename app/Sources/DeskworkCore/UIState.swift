import Foundation

/// Small bits of window state that should survive a restart.
public struct UIState: Codable {
    public var collapsed: [String] = []
    public var treeOnTop: Bool = false
    public var seenWelcome: Bool = false

    public static var path: String { NSString(string: "~/.config/deskwork/ui.json").expandingTildeInPath }

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

