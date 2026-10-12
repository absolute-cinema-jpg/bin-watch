import AppKit
import SwiftUI

/// Alerts you when new bins appear in folders you choose (e.g. new scene bins landing
/// in the project). Read-only like everything else: it only lists folders.
final class NewBinWatcher: ObservableObject {
    static let shared = NewBinWatcher()

    struct FolderWatch: Codable, Identifiable, Equatable {
        var id = UUID()
        var folder: String            // relative to the monitored folder ("" = the monitored folder)
        var includeSubfolders: Bool
    }

    struct Event: Codable, Identifiable, Equatable {
        var id = UUID()
        var binPath: String           // relative to the monitored folder
        var detected: Date

        var name: String { ((binPath as NSString).lastPathComponent as NSString).deletingPathExtension }
        var folder: String { (binPath as NSString).deletingLastPathComponent }
    }

    @Published private(set) var watches: [FolderWatch] = [] { didSet { save(watches, "newBinWatches") } }
    @Published private(set) var events: [Event] = [] { didSet { save(events, "newBinEvents") } }
    /// nil = not looked yet, false = couldn't read the folder last time.
    @Published private(set) var reachable: [UUID: Bool] = [:]

    private var baselines: [UUID: [String: Date]] = [:] { didSet { save(baselines, "newBinBaselines") } }
    /// Bins already announced (normalised path → when), so overlapping folders never
    /// announce the same bin twice.
    private var announced: [String: Date] = [:]
    private var lastScan: [UUID: Date] = [:]
    private var scanning = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "binwatch.newbins", qos: .utility)
    private let defaults = UserDefaults.standard

    /// How often to look: a single folder is cheap; a whole tree less often.
    static let interval: TimeInterval = 5
    static let subfolderInterval: TimeInterval = 30
    static let maxEvents = 200

    private init() {
        watches = load("newBinWatches") ?? []
        events = load("newBinEvents") ?? []
        baselines = load("newBinBaselines") ?? [:]
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.scan() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.async { [weak self] in self?.scan() }
    }

    // MARK: Choosing folders

    func watch(for folder: String) -> FolderWatch? {
        watches.first { ReadOnlyFS.key($0.folder) == ReadOnlyFS.key(folder) }
    }

    enum Coverage: Equatable {
        case none
        case direct                    // this folder is watched for new bins
        case viaParent(String)         // a parent folder is, with subfolders included
    }

    func coverage(of folder: String) -> Coverage {
        if watch(for: folder) != nil { return .direct }
        let key = ReadOnlyFS.key(folder)
        if let parent = watches.first(where: { w in
            w.includeSubfolders && (w.folder.isEmpty || key.hasPrefix(ReadOnlyFS.key(w.folder) + "/"))
        }) { return .viaParent(parent.folder) }
        return .none
    }

    func toggle(folder: String) {
        if let existing = watch(for: folder) { remove(existing) } else { add(folder: folder) }
    }

    func add(folder: String, includeSubfolders: Bool = false) {
        guard watch(for: folder) == nil else { return }
        let new = FolderWatch(folder: folder, includeSubfolders: includeSubfolders)
        watches.append(new)
        scan(force: true)
    }

    func remove(_ watch: FolderWatch) {
        watches.removeAll { $0.id == watch.id }
        baselines[watch.id] = nil
        reachable[watch.id] = nil
    }

    /// Changing what's covered starts afresh, so existing bins in newly-covered
    /// subfolders don't all arrive as "new".
    func setIncludeSubfolders(_ include: Bool, for watch: FolderWatch) {
        guard let i = watches.firstIndex(where: { $0.id == watch.id }), watches[i].includeSubfolders != include else { return }
        watches[i].includeSubfolders = include
        baselines[watch.id] = nil
        scan(force: true)
    }

    func clearEvents() { events = [] }

    /// When the monitored folder changes, keep the folders that are still inside it.
    func rootChanged(remap: (String) -> String?) {
        var kept: [FolderWatch] = []
        for var watch in watches {
            guard let folder = remap(watch.folder) else { baselines[watch.id] = nil; continue }
            watch.folder = folder
            kept.append(watch)
            baselines[watch.id] = nil
        }
        watches = kept
        events = []
    }

    // MARK: Scanning

    func scan(force: Bool = false) {
        guard !scanning, let root = AppStore.shared.root else { return }
        let now = Date()
        let due = watches.filter { watch in
            force || now.timeIntervalSince(lastScan[watch.id] ?? .distantPast)
                >= (watch.includeSubfolders ? Self.subfolderInterval : Self.interval) - 0.5
        }
        guard !due.isEmpty else { return }
        for watch in due { lastScan[watch.id] = now }
        scanning = true

        queue.async { [weak self] in
            var listings: [UUID: [String]?] = [:]
            for watch in due {
                let url = watch.folder.isEmpty ? root : root.appendingPathComponent(watch.folder)
                let bins = watch.includeSubfolders
                    ? ReadOnlyFS.index(url, prefix: watch.folder)?.bins
                    : ReadOnlyFS.listFolder(url, relative: watch.folder, detectProjects: false)?.bins
                listings[watch.id] = .some(bins?.map(\.relativePath))
            }
            DispatchQueue.main.async {
                self?.scanning = false
                self?.apply(listings)
            }
        }
    }

    private func apply(_ listings: [UUID: [String]?]) {
        let now = Date()
        for (id, listing) in listings {
            guard watches.contains(where: { $0.id == id }) else { continue }
            guard let current = listing else {
                // Couldn't read it (workspace offline?): change nothing, try again later.
                if reachable[id] != false { reachable[id] = false }
                continue
            }
            if reachable[id] != true { reachable[id] = true }
            let result = NewBinDiff.compare(known: baselines[id], current: current, now: now)
            baselines[id] = result.known
            var fresh: [String] = []
            for path in result.added where announced[ReadOnlyFS.key(path)] == nil {
                announced[ReadOnlyFS.key(path)] = now
                fresh.append(path)
            }
            if !fresh.isEmpty { announce(fresh.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, at: now) }
        }
        announced = announced.filter { now.timeIntervalSince($0.value) < NewBinDiff.forgetAfter }
    }

    private func announce(_ added: [String], at date: Date) {
        let new = added.map { Event(binPath: $0, detected: date) }
        events = Array((new + events).prefix(Self.maxEvents))

        let names = new.map(\.name)
        let folders = Set(new.map(\.folder))
        let folderName = new[0].folder.isEmpty ? AppStore.shared.rootName : (new[0].folder as NSString).lastPathComponent
        let scripts = new.filter { AvidItem.isScript($0.binPath) }.count
        let noun = scripts == 0 ? "bin" : scripts == new.count ? "script" : "item"
        let title = new.count == 1 ? names[0]
            : folders.count == 1 ? "\(new.count) new \(noun)s in \(folderName)" : "\(new.count) new \(noun)s"
        let detail = new.count == 1 ? displayPath(new[0].folder, root: AppStore.shared.rootName)
                                    : names.joined(separator: ", ")
        let urls = AppStore.shared.root.map { root in new.map { root.appendingPathComponent($0.binPath) } } ?? []
        AlertCenter.shared.present(
            AlertItem(id: UUID(), kind: .newBins(count: new.count), title: title, detail: detail, time: date, noun: noun),
            onRespond: { response in if response == .primary { BinOpener.show(urls) } })
        NSApp?.requestUserAttention(.informationalRequest)
    }

    // MARK: Persistence (app preferences only)

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
