import Foundation

/// Tells the controller when desks.toml changes on disk.
///
/// Watches the folder as well as the file: editors and `sed -i` write a new
/// file and rename it over the old one, which a watch on the old file alone
/// never sees, and after which that watch points at a file that's gone. The
/// file watch is re-armed on every event. Bursts are debounced.
public final class DeskConfigWatcher {
    public var onChange: (() -> Void)?
    private let path: String
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(path: String) { self.path = path }

    public func start() {
        let dir = (path as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { close(fd) }
            s.resume()
            dirSource = s
        }
        armFile()
    }

    /// Watch the file that's there now; after a replace, that's a new one.
    private func armFile() {
        fileSource?.cancel(); fileSource = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        fileSource = s
    }

    private func changed() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.armFile()
            self?.onChange?()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}
