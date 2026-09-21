// Spike: can SwiftTerm keep up?
//
// The whole Project Coldfall design rests on the terminal not being the bottleneck.
// SwiftTerm renders through CoreText rather than the GPU, so this measures
// throughput the only way that matters: run the benchmark INSIDE the terminal
// and let pty backpressure do the timing. A terminal that cannot consume
// output fast enough slows the process writing it.
//
// Compare the number this prints against the same command in Ghostty.

import AppKit
import SwiftTerm

final class Delegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var term: LocalProcessTerminalView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        term = LocalProcessTerminalView(frame: frame)
        term.processDelegate = self

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "DeskSpike — SwiftTerm throughput"
        window.contentView = term
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Bare shell, no rc files, so the measurement is the terminal and not zsh.
        term.startProcess(executable: "/bin/zsh", args: ["-f"],
                          environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))

        // Give the shell a beat, then run the benchmark in it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let bench = """
            printf '\n== SwiftTerm throughput: 3x seq 1 200000 ==\n'; \
            rm -f /tmp/bench-swiftterm.txt; \
            for n in 1 2 3; do /usr/bin/time -p sh -c 'seq 1 200000' 2>>/tmp/bench-swiftterm.txt; done; \
            printf '\nDONE\n'; grep real /tmp/bench-swiftterm.txt

            """
            self?.term.send(txt: bench)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }

    // LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { window?.title = "DeskSpike — \(title)" }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { NSApp.terminate(nil) }
}

// Swift 6: the delegate is main-actor isolated by protocol conformance,
// so the bootstrap has to be too.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    _ = delegate          // keep it alive; NSApp holds the delegate weakly
    app.run()
}
