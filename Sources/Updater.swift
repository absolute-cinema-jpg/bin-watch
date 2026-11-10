import AppKit
import os

let updateLog = Logger(subsystem: "local.binwatch.BinWatch", category: "update")

/// Checks GitHub for a newer Bin Watch and installs it when you click Update.
/// Checking and downloading happen here, inside the sandbox; the swap itself is done by the
/// updater helper inside Bin Watch.app (Sources/Updater/main.swift).
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double)
        case installing, restarting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var update: AvailableUpdate?
    @Published private(set) var lastChecked: Date? { didSet { defaults.set(lastChecked, forKey: "updateLastChecked") } }
    /// True when the last failure was while installing (rather than checking), so the
    /// UI offers to try the install again or download it by hand.
    @Published private(set) var installFailed = false
    /// Set for the session after Bin Watch restarts into a new version.
    @Published var justUpdated: Bool

    let currentVersion: String
    private let current: AppVersion
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progressWatch: NSKeyValueObservation?
    private lazy var session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "BinWatch/\(currentVersion)", "Accept": "application/vnd.github+json"]
        return c
    }())

    static let checkInterval: TimeInterval = 24 * 3600

    /// Tests replace the network with these.
    var fetchRelease: ((@escaping (Result<GitHubRelease, UpdateError>) -> Void) -> Void)?
    var installHook: ((AvailableUpdate) -> Void)?

    private var feedOverride: String? { defaults.string(forKey: "UpdateFeedURL") }
    private var feed: URL { UpdateLogic.feedURL(override: feedOverride) }
    private var allowLocal: Bool { UpdateLogic.isLocalTestURL(feed) }

    override init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        current = AppVersion(currentVersion) ?? AppVersion("0")!
        // macOS doesn't pass launch arguments from a sandboxed app, so the old version leaves
        // a note in Bin Watch's settings instead, for the new one to find once.
        justUpdated = UserDefaults.standard.string(forKey: "justUpdatedTo") == currentVersion
        super.init()
        defaults.removeObject(forKey: "justUpdatedTo")
        if justUpdated { updateLog.notice("now running \(self.currentVersion, privacy: .public) after updating") }
        lastChecked = defaults.object(forKey: "updateLastChecked") as? Date
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing, .restarting: return true
        default: return false
        }
    }

    /// Checks shortly after launch (unless it checked recently), then once a day.
    func start() {
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        // Lets the end-to-end test drive a whole update from the command line, but only
        // against a test server on this Mac.
        if CommandLine.arguments.contains("--install-update"), allowLocal {
            check { [weak self] in if self?.update != nil { self?.install() } }
        }
    }

    private func checkIfDue() {
        guard AppStore.shared.settings.checkForUpdates, !isBusy else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        check()
    }

    func check(then done: (() -> Void)? = nil) {
        guard !isBusy else { return }
        phase = .checking
        installFailed = false
        let finish: (Result<GitHubRelease, UpdateError>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastChecked = Date()
                switch result {
                case .success(let release):
                    do {
                        self.update = try UpdateLogic.update(from: release, current: self.current)
                        self.phase = self.update == nil ? .upToDate : .available
                        updateLog.notice("checked: latest \(release.tagName, privacy: .public), running \(self.currentVersion, privacy: .public)")
                    } catch {
                        self.update = nil
                        self.phase = .failed(error.localizedDescription)
                    }
                case .failure(let error):
                    updateLog.notice("check failed: \(error.localizedDescription, privacy: .public)")
                    self.phase = .failed(error.localizedDescription)
                }
                done?()
            }
        }
        if let fetchRelease { fetchRelease(finish) } else { fetchLatest(finish) }
    }

    private func fetchLatest(_ done: @escaping (Result<GitHubRelease, UpdateError>) -> Void) {
        session.dataTask(with: feed) { data, response, error in
            if let error { return done(.failure(.network(error.localizedDescription))) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let data, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
                else { return done(.failure(.unreadable)) }
                done(.success(release))
            case 404: done(.failure(.notPublished))
            case 403, 429: done(.failure(.rateLimited))
            default: done(.failure(.server(status)))
            }
        }.resume()
    }

    /// Download, check and install, then restart into the new version. If alerts are on
    /// screen it asks first, since restarting clears them.
    func installAsking() {
        let waiting = AppStore.shared.pendingAlerts.count
        guard waiting > 0 else { return install() }
        let alert = NSAlert()
        alert.messageText = "Update and restart Bin Watch?"
        alert.informativeText = "Bin Watch restarts to finish updating, which clears the \(waiting == 1 ? "alert" : "\(waiting) alerts") on screen. Your watched bins are kept."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] in
            if $0 == .alertFirstButtonReturn { self?.install() }
        }
        if let window = ManageWindow.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    func install() {
        guard let update, !isBusy else { return }
        installFailed = false
        if let installHook { installHook(update); return }
        guard UpdateLogic.isTrustedDownload(update.zipURL, allowLocal: allowLocal) else {
            return fail(UpdateError.untrustedDownload.localizedDescription)
        }
        phase = .downloading(0)
        updateLog.notice("downloading \(update.version, privacy: .public)")
        let task = session.downloadTask(with: update.zipURL) { [weak self] file, response, error in
            guard let self else { return }
            let result: Result<URL, UpdateError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let file, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let final = http.url, UpdateLogic.isTrustedDownload(final, allowLocal: self.allowLocal) {
                // The temporary file goes away when this returns, so keep it.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Bin-Watch-\(update.version).zip")
                try? FileManager.default.removeItem(at: kept)
                do { try FileManager.default.moveItem(at: file, to: kept); result = .success(kept) }
                catch { result = .failure(.network(error.localizedDescription)) }
            } else if response?.url.map({ UpdateLogic.isTrustedDownload($0, allowLocal: self.allowLocal) }) == false {
                result = .failure(.untrustedDownload)
            } else {
                result = .failure(.server((response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            switch result {
            case .success(let zip): self.verifyAndInstall(zip, update)
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
        progressWatch = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.phase { self?.phase = .downloading(progress.fractionCompleted) }
            }
        }
        download = task
        task.resume()
    }

    private func verifyAndInstall(_ zip: URL, _ update: AvailableUpdate) {
        expectedChecksum(for: update) { [weak self] expected in
            guard let self else { return }
            guard let expected else { return self.fail(UpdateError.checksumMissing.localizedDescription) }
            guard (try? UpdateShared.sha256(of: zip)) == expected else {
                try? FileManager.default.removeItem(at: zip)
                return self.fail(UpdateError.checksumMismatch.localizedDescription)
            }
            DispatchQueue.main.async { self.phase = .installing }
            self.handToHelper(zip, sha256: expected, version: update.version)
        }
    }

    private func expectedChecksum(for update: AvailableUpdate, _ done: @escaping (String?) -> Void) {
        if let sha = update.sha256 { return done(sha) }
        guard let url = update.checksumURL, UpdateLogic.isTrustedDownload(url, allowLocal: allowLocal) else { return done(nil) }
        session.dataTask(with: url) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return done(nil) }
            done(UpdateLogic.parseChecksum(String(decoding: data, as: UTF8.self)))
        }.resume()
    }

    private func handToHelper(_ zip: URL, sha256: String, version: String) {
        guard let bundleID = Bundle.main.bundleIdentifier, let handle = try? FileHandle(forReadingFrom: zip) else {
            return fail("The download couldn't be opened. Try again.")
        }
        let connection = NSXPCConnection(serviceName: UpdateShared.serviceName(forApp: bundleID))
        connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstalling.self)
        connection.resume()
        var answered = false
        let finish: (String?) -> Void = { [weak self] problem in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                try? handle.close()
                try? FileManager.default.removeItem(at: zip)
                connection.invalidate()
                if let problem { self?.fail(problem) } else { self?.restart(into: version) }
            }
        }
        let helper = connection.remoteObjectProxyWithErrorHandler { error in
            updateLog.error("updater helper: \(error.localizedDescription, privacy: .public)")
            finish("Bin Watch's updater couldn't start, so nothing was changed. Download the new version from GitHub instead.")
        } as? UpdateInstalling
        guard let helper else { return finish("Bin Watch's updater couldn't start, so nothing was changed.") }
        helper.install(zip: handle, sha256: sha256, version: version, reply: finish)
    }

    private func restart(into version: String) {
        phase = .restarting
        updateLog.notice("installed \(version, privacy: .public); restarting")
        defaults.set(version, forKey: "justUpdatedTo")
        Relauncher.relaunch { [weak self] launched in
            if !launched {
                self?.defaults.removeObject(forKey: "justUpdatedTo")
                self?.fail("Bin Watch \(version) is installed. Quit Bin Watch and open it again to start using it.")
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            updateLog.error("update failed: \(message, privacy: .public)")
            self.installFailed = true
            self.phase = .failed(message)
        }
    }

    // MARK: Words for the UI

    var statusText: String {
        switch phase {
        case .idle:
            if let lastChecked { return "Last checked \(lastChecked.formatted(.relative(presentation: .named)))" }
            return "Not checked yet"
        case .checking: return "Checking for updates…"
        case .upToDate: return "Up to date"
        case .available: return "Version \(update?.version ?? "") is available"
        case .downloading(let f): return f > 0 ? "Downloading… \(Int(f * 100))%" : "Downloading…"
        case .installing: return "Installing…"
        case .restarting: return "Restarting…"
        case .failed(let message): return message
        }
    }
}
