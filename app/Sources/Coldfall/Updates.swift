import AppKit
import ColdfallCore

/// Runs the daily update check (see ColdfallCore/UpdateCheck.swift for what
/// it sends and why) and tells the title strip when a release is out.
final class Updates {
    /// Called with the newer version, or nil when there is none.
    var onChange: ((String?) -> Void)?
    private var timer: Timer?
    private var inFlight = false

    /// The newer release to point at, if the last reply named one.
    var available: (version: String, url: String?)? {
        let s = UpdateState.load()
        guard let l = s.latest, UpdateCheck.isNewer(l, than: SelfUpdate.version) else { return nil }
        return (l, s.latestURL)
    }

    /// `firstRun` people see the notice on the Welcome screen instead, and
    /// nothing is sent until they have finished it.
    func start(firstRun: Bool) {
        onChange?(available?.version)
        if !firstRun, !UpdateState.load().noticeShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showNotice() }
        }
        // Hourly look at whether a day has passed; the check itself is daily.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    /// Once, for installs that had Coldfall before the check existed.
    private func showNotice() {
        var s = UpdateState.load()
        guard !s.noticeShown else { return }
        let a = NSAlert()
        a.messageText = UpdateCheck.noticeTitle
        a.informativeText = UpdateCheck.noticeBody
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Turn Off")
        s.enabled = a.runModal() == .alertFirstButtonReturn
        s.noticeShown = true
        s.save()
        checkIfDue()
    }

    func checkIfDue() {
        guard !inFlight, UpdateCheck.due(UpdateState.load()), let url = URL(string: UpdateCheck.endpoint) else { return }
        inFlight = true
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = UpdateCheck.body(UpdateState.load(), appVersion: SelfUpdate.version)
        // No cookies, no cache: the request is the three fields and nothing else.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        URLSession(configuration: cfg).dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                // Offline or the server is down: say nothing, try next hour.
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let reply = UpdateCheck.parse(data) else { return }
                var s = UpdateState.load()
                s.lastCheck = Date()
                s.latest = reply.latest
                s.latestURL = reply.url
                s.save()
                self.onChange?(self.available?.version)
            }
        }.resume()
    }

    func openRelease() {
        let fallback = "https://github.com/anthonyproctor/project-coldfall/releases/latest"
        if let u = URL(string: available?.url ?? fallback) { NSWorkspace.shared.open(u) }
    }
}
