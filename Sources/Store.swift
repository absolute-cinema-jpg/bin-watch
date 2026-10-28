import AppKit
import SwiftUI

/// Holds the monitored folder and watched bins, polls their lock state and raises alerts.
final class AppStore: ObservableObject {
    static let shared = AppStore()

    /// The one folder Bin Watch looks in: a single project, or a whole "Avid Projects" folder.
    @Published private(set) var rootPath: String? { didSet { defaults.set(rootPath, forKey: "rootPath") } }
    @Published private(set) var rootOnline: Bool?
    @Published private(set) var watched: [WatchedBin] = [] { didSet { save(watched, "watchedBins") } }
    @Published var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            save(settings, "settings")
            if settings.pollInterval != oldValue.pollInterval { startPolling() }
            if settings.showLockHolders != oldValue.showLockHolders {
                LockHolders.enabled = settings.showLockHolders
                if !settings.showLockHolders { holders = [:] }
                BrowserModel.shared.listingCache = [:]
            }
        }
    }
    @Published private(set) var states: [UUID: BinState] = [:]
    /// Who has each locked watched bin open (as Avid wrote it in the lock file).
    @Published private(set) var holders: [UUID: String] = [:]
    @Published private(set) var pendingAlerts: Set<UUID> = []
    @Published private(set) var customSounds: [String] = SoundLibrary.customSounds()

    private var rootBookmark: Data? { didSet { defaults.set(rootBookmark, forKey: "rootBookmark") } }
    private(set) var root: URL?                       // resolved, security-scoped (read-only)
    private var lastResolveAttempt = Date.distantPast
    private var detector = UnlockDetector()
    private var timer: Timer?
    private var probing = false
    private let queue = DispatchQueue(label: "binwatch.probe", qos: .utility)
    private let defaults = UserDefaults.standard

    var rootName: String { rootPath.map { ($0 as NSString).lastPathComponent } ?? "No folder" }

    private init() {
        rootBookmark = defaults.data(forKey: "rootBookmark")
        rootPath = defaults.string(forKey: "rootPath")
        watched = load("watchedBins") ?? []
        settings = load("settings") ?? AppSettings()
        save(settings, "settings")      // store any settings migration straight away
        LockHolders.enabled = settings.showLockHolders
        migrateFromProjects()
        resolveRoot()
        for bin in watched { states[bin.id] = .checking }
        startPolling()
    }

    // MARK: Monitored folder

    func chooseRootViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Monitor"
        panel.message = "Choose an Avid project folder, or a folder of projects (like “Avid Projects”).\nBin Watch keeps read-only access to it, and restarts once to make sure of that."
        panel.prompt = "Monitor This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = root ?? URL(fileURLWithPath: "/Volumes")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    func setRoot(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        else { NSSound.beep(); return }

        // Keep watching any bins that are still inside the new folder.
        let oldBase = (root?.path ?? rootPath).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let newBase = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var kept: [WatchedBin] = []
        var dropped: [WatchedBin] = []
        for bin in watched {
            let absolute = (oldBase ?? "") + bin.relativePath
            if oldBase != nil, absolute.hasPrefix(newBase) {
                var moved = bin
                moved.relativePath = String(absolute.dropFirst(newBase.count))
                kept.append(moved)
            } else {
                dropped.append(bin)
            }
        }
        if !dropped.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Stop watching \(AvidItem.count(dropped.map(\.relativePath)))?"
            alert.informativeText = "\(dropped.map(\.name).prefix(5).joined(separator: ", "))\(dropped.count > 5 ? "…" : "") "
                + "\(dropped.count == 1 ? "isn't" : "aren't") inside “\(url.lastPathComponent)”, so Bin Watch can't keep watching \(dropped.count == 1 ? "it" : "them")."
            alert.addButton(withTitle: "Change Folder")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        for bin in dropped { unwatch(bin) }
        // Keep "new bin" folders that are still inside the new monitored folder.
        let oldRoot = (root?.path ?? rootPath) ?? ""
        NewBinWatcher.shared.rootChanged { folder in
            let absolute = folder.isEmpty ? oldRoot : (oldBase ?? "") + folder
            if ReadOnlyFS.key(absolute) == ReadOnlyFS.key(url.path) { return "" }
            return absolute.hasPrefix(newBase) ? String(absolute.dropFirst(newBase.count)) : nil
        }
        root?.stopAccessingSecurityScopedResource()
        root = nil
        rootBookmark = bookmark
        rootPath = url.path
        watched = kept
        resolveRoot()
        BrowserModel.shared.reset()
        poll()
        // The folder picker grants write access for the rest of this session. Restart so
        // Bin Watch only ever holds the read-only access saved in the bookmark.
        Relauncher.relaunch()
    }

    private func resolveRoot() {
        lastResolveAttempt = Date()
        guard let bookmark = rootBookmark else { rootOnline = nil; return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        else { rootOnline = false; return }
        if let old = root {
            if old == url { return }
            old.stopAccessingSecurityScopedResource()
        }
        _ = url.startAccessingSecurityScopedResource()
        root = url
        if rootPath != url.path { rootPath = url.path }
        if stale, let fresh = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil) {
            rootBookmark = fresh
        }
    }

    // MARK: Watching

    /// NEXIS and macOS volumes are case-insensitive, so compare paths the same way.
    private func watchedBin(at relativePath: String) -> WatchedBin? {
        let key = ReadOnlyFS.key(relativePath)
        return watched.first { ReadOnlyFS.key($0.relativePath) == key }
    }

    func isWatched(_ relativePath: String) -> Bool {
        watchedBin(at: relativePath) != nil
    }

    func toggleWatch(_ bin: ScannedBin) {
        if let existing = watchedBin(at: bin.relativePath) {
            unwatch(existing)
        } else {
            let new = WatchedBin(relativePath: bin.relativePath)
            watched.append(new)
            detector.seed(new.id, locked: bin.isLocked)
            states[new.id] = bin.isLocked ? .locked : .available
            poll()
        }
    }

    /// Watch a bin by path (used when asking someone for it). Assumes it's locked right now.
    func ensureWatched(relativePath: String) {
        guard !isWatched(relativePath) else { return }
        let new = WatchedBin(relativePath: relativePath)
        watched.append(new)
        detector.seed(new.id, locked: true)
        states[new.id] = .locked
        poll()
    }

    /// Return key on a selection: if every selected bin is already watched, stop watching
    /// them all; otherwise watch them all.
    func toggleWatch(_ bins: [ScannedBin]) {
        guard !bins.isEmpty else { return }
        if bins.allSatisfy({ isWatched($0.relativePath) }) {
            for bin in bins { if let w = watchedBin(at: bin.relativePath) { unwatch(w) } }
        } else {
            for bin in bins where !isWatched(bin.relativePath) { toggleWatch(bin) }
        }
    }

    func unwatch(_ bin: WatchedBin) {
        RequestCenter.shared.cancelRequest(for: bin.relativePath)
        watched.removeAll { $0.id == bin.id }
        states[bin.id] = nil
        holders[bin.id] = nil
        detector.forget(bin.id)
        pendingAlerts.remove(bin.id)
        AlertCenter.shared.remove(bin.id)
    }

    func unwatchAll() {
        for bin in watched { unwatch(bin) }
    }

    var lockedCount: Int { watched.filter { states[$0.id] == .locked }.count }

    // MARK: Polling

    func startPolling() {
        timer?.invalidate()
        let t = Timer(timeInterval: max(1, settings.pollInterval), repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func poll() {
        guard !probing else { return }

        // Retry when the workspace isn't mounted (or was remounted somewhere else).
        if rootOnline != true, Date().timeIntervalSince(lastResolveAttempt) > 10 { resolveRoot() }

        let root = self.root
        let jobs = watched.compactMap { bin -> ProbeJob? in
            guard let root else { return nil }
            let url = root.appendingPathComponent(bin.relativePath)
            return ProbeJob(id: bin.id, directory: url.deletingLastPathComponent(), binFileName: bin.fileName)
        }
        let unresolved = root == nil ? watched.map(\.id) : []

        probing = true
        queue.async { [weak self] in
            var holders: [UUID: String] = [:]
            let results = ReadOnlyFS.probe(jobs, holders: &holders)
            let online = root.map(ReadOnlyFS.isReachable)
            DispatchQueue.main.async {
                self?.apply(results, unresolved: unresolved, online: online)
                if self?.holders != holders { self?.holders = holders }
                self?.probing = false
            }
        }
    }

    private func apply(_ results: [UUID: BinState], unresolved: [UUID], online: Bool?) {
        if let online, rootOnline != online { rootOnline = online }

        var readings = results
        for id in unresolved { readings[id] = .offline }

        for (id, reading) in readings {
            guard let bin = watched.first(where: { $0.id == id }) else { continue }
            let (display, unlocked) = detector.update(id, with: reading)
            if states[id] != display { states[id] = display }
            if unlocked { binBecameAvailable(bin) }
        }
    }

    private func binBecameAvailable(_ bin: WatchedBin) {
        RequestCenter.shared.binBecameAvailable(bin.relativePath)
        pendingAlerts.insert(bin.id)
        let url = root?.appendingPathComponent(bin.relativePath)
        AlertCenter.shared.present(
            AlertItem(binID: bin.id, binName: bin.name, detail: displayPath(bin.folder, root: rootName),
                      noun: AvidItem.noun(bin.relativePath)),
            onRespond: { [weak self] response in
                if response == .primary, let url { BinOpener.show([url]) }   // "Show Bin"
                self?.acknowledge(bin.id)                                     // either way, it's been seen
            })
        NSApp.requestUserAttention(.informationalRequest)   // one gentle Dock bounce
    }

    /// "Show Bin" or "Dismiss": the alert goes away and, by default, the bin stops being watched.
    private func acknowledge(_ id: UUID) {
        pendingAlerts.remove(id)
        if settings.stopWatchingAfterAlert, let bin = watched.first(where: { $0.id == id }) { unwatch(bin) }
    }

    func showTestAlert(count: Int = 1) {
        let samples = [("Reel 3 — Assembly", "Example Project  ›  Reels"),
                       ("Interviews — Selects", "Example Project  ›  Selects"),
                       ("Day 04 Dailies", "Example Project  ›  Dailies"),
                       ("Music", "Example Project"),
                       ("Reel 1 — Fine Cut", "Example Project  ›  Reels")]
        for i in 0..<count {
            let id = UUID()
            let sample = samples[i % samples.count]
            pendingAlerts.insert(id)
            AlertCenter.shared.present(binID: id, binName: sample.0, detail: sample.1,
                                       onAcknowledge: { [weak self] in self?.pendingAlerts.remove(id) })
        }
    }

    // MARK: Sounds

    func addSounds() throws {
        if let added = try SoundLibrary.importViaPanel() {
            customSounds = SoundLibrary.customSounds()
            settings.soundName = added
            AlertCenter.shared.playChime()
        }
    }

    func removeSound(_ id: String) {
        SoundLibrary.remove(id)
        customSounds = SoundLibrary.customSounds()
        if settings.soundName == id { settings.soundName = "Glass" }
    }

    // MARK: Persistence (app preferences only — never the project)

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Version 1 stored a list of projects; carry the first one over as the monitored folder.
    private func migrateFromProjects() {
        struct OldProject: Decodable { var id: UUID; var path: String; var bookmark: Data }
        struct OldBin: Decodable { var id: UUID; var projectID: UUID; var relativePath: String }
        guard rootBookmark == nil, let projects: [OldProject] = load("projects"), !projects.isEmpty else { return }
        let oldBins: [OldBin] = load("watched") ?? []
        // Prefer the project you were actually watching bins in.
        let chosen = projects.max { a, b in
            oldBins.filter { $0.projectID == a.id }.count < oldBins.filter { $0.projectID == b.id }.count
        } ?? projects[0]
        rootBookmark = chosen.bookmark
        rootPath = chosen.path
        watched = oldBins.filter { $0.projectID == chosen.id }.map { WatchedBin(id: $0.id, relativePath: $0.relativePath) }
        defaults.removeObject(forKey: "projects")
        defaults.removeObject(forKey: "watched")
    }
}
