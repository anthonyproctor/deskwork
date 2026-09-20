import Foundation

/// Watches a desk's directory and reports files an agent has just written.
///
/// This is the half of "see the code it was editing" that a per-file watcher
/// cannot do: you have not opened the file yet, because you do not know which
/// file the agent is about to touch.
///
/// FSEvents reports directories on some paths and coalesces bursts, so events
/// are debounced and each candidate is confirmed by modification time before
/// anything is opened. Noise matters here — an unfiltered watch on a real
/// workspace fires constantly on .git and build output, and a reader that
/// opens junk is worse than one that opens nothing.
final class WorkspaceWatcher {
    var onChanged: (([URL]) -> Void)?

    private var stream: FSEventStreamRef?
    private var root: String = ""
    private var startedAt = Date()
    private var pending = Set<String>()
    private var flushWork: DispatchWorkItem?

    /// Directory names that are never interesting, and the dotfile rule.
    private static let skipDirs: Set<String> = [
        ".git", ".build", "node_modules", ".venv", "venv", "target",
        "DerivedData", ".next", "dist", "__pycache__", ".pytest_cache",
        ".claude", ".codex", ".cargo", ".swiftpm", "Pods",
    ]
    /// Extensions worth showing. A binary or an image dump is not "the code it
    /// was editing", and opening one costs attention for nothing.
    private static let watchExts: Set<String> = [
        "swift","rs","py","js","ts","tsx","jsx","go","rb","java","kt","c","h","cpp","hpp",
        "m","mm","sh","bash","zsh","toml","yaml","yml","json","md","txt","html","css",
        "sql","tf","gradle","cfg","ini","conf","env","proto","graphql","vue","svelte",
    ]

    func start(root path: String) {
        stop()
        root = path
        startedAt = Date()

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // eventPaths is only a CFArray when kFSEventStreamCreateFlagUseCFTypes
        // is set. Without it FSEvents hands back a raw char **, and bit-casting
        // that to NSArray walks into path text as if it were object pointers —
        // a segfault whose address is literally ASCII bytes. Ask for CF types.
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let cf = unsafeBitCast(paths, to: CFArray?.self),
                  let arr = cf as? [String] else { return }
            me.ingest(Array(arr.prefix(count)))
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &ctx,
            [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents
                   | kFSEventStreamCreateFlagNoDefer
                   | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
        flushWork?.cancel()
        pending.removeAll()
    }

    private func ingest(_ paths: [String]) {
        for p in paths where interesting(p) { pending.insert(p) }
        guard !pending.isEmpty else { return }
        // Agents write in bursts. Debounce so a single edit does not open the
        // same file three times.
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flush() {
        let urls = pending.sorted().map { URL(fileURLWithPath: $0) }
        pending.removeAll()
        guard !urls.isEmpty else { return }
        onChanged?(urls)
    }

    private func interesting(_ path: String) -> Bool {
        let rel = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        for part in rel.split(separator: "/") {
            let name = String(part)
            if Self.skipDirs.contains(name) { return false }
            // Hidden directories are almost always machinery, not work.
            if name.hasPrefix(".") && name.contains(".") && !name.hasPrefix(".env") && rel.hasSuffix("/" + name) == false {
                if name != rel.split(separator: "/").last.map(String.init) { return false }
            }
        }
        let url = URL(fileURLWithPath: path)
        guard Self.watchExts.contains(url.pathExtension.lowercased()) else { return false }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
        else { return false }
        // Confirm it really changed since we started watching. FSEvents reports
        // plenty that did not.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let m = attrs[.modificationDate] as? Date, m >= startedAt else { return false }
        return true
    }

    deinit { stop() }
}
