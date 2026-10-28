import Foundation
import os

let fsLog = Logger(subsystem: "local.binwatch.BinWatch", category: "fs")

func elapsedMS(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

// ─────────────────────────────────────────────────────────────────────────────
//  ReadOnlyFS — the ONLY code in Bin Watch that touches an Avid project.
//
//  It lists directory contents, and — only if "Show who has it open" is on — reads the
//  first 1 KB of a .lck file once, to show whose name Avid wrote in it (see LockHolders).
//  It never creates, writes, renames, moves or deletes anything.
//
//  On top of that, the app is built with the macOS App Sandbox and the
//  `files.user-selected.read-only` entitlement, so the operating system itself
//  refuses any attempt by this app to modify the folders you give it.
// ─────────────────────────────────────────────────────────────────────────────

enum BinState: String, Equatable {
    case checking, locked, available, missing, offline
}

/// Bins (.avb) and scripts (.avc) behave the same in Avid: both are files in the project,
/// and both get a "<name>.lck" lock file beside them while someone has them open.
enum AvidItem {
    static let extensions: Set<String> = ["avb", "avc"]

    static func isItem(_ fileName: String) -> Bool {
        extensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    static func isScript(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "avc"
    }

    /// "bin" / "script" — for labels.
    static func noun(_ path: String) -> String { isScript(path) ? "script" : "bin" }

    /// "3 bins", "1 script", "2 bins and 1 script" — for counts of mixed items.
    static func count(_ paths: [String]) -> String {
        let scripts = paths.filter(isScript).count, bins = paths.count - scripts
        let parts = [bins > 0 ? "\(bins) bin\(bins == 1 ? "" : "s")" : nil,
                     scripts > 0 ? "\(scripts) script\(scripts == 1 ? "" : "s")" : nil].compactMap { $0 }
        return parts.isEmpty ? "0 bins" : parts.joined(separator: " and ")
    }
}

/// A bin or script found while browsing a project.
struct ScannedBin: Identifiable, Hashable {
    var id: String { relativePath }
    let relativePath: String   // e.g. "Reels/Reel 1.avb"
    let name: String           // e.g. "Reel 1"
    let folder: String         // e.g. "Reels" ("" for the project root)
    let isLocked: Bool
    /// Who has it open, as Avid wrote it in the lock file (usually a computer name).
    var lockedBy: String? = nil

    var isScript: Bool { AvidItem.isScript(relativePath) }
}

struct FolderItem: Identifiable, Hashable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    var isProject: Bool
}

struct FolderListing {
    var folders: [FolderItem] = []
    var bins: [ScannedBin] = []
}

struct ProbeJob {
    let id: UUID
    let directory: URL
    let binFileName: String    // e.g. "Reel 1.avb"
}

enum ReadOnlyFS {

    /// Normalise names so "Reel 1.avb" on NEXIS/SMB (often NFD) matches what we stored.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Lowercased names in a directory, or nil if it can't be listed (volume offline, etc).
    static func listing(of directory: URL) -> Set<String>? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return Set(names.map(key))
    }

    static func isReachable(_ directory: URL) -> Bool {
        let start = DispatchTime.now()
        let ok = listing(of: directory) != nil
        let ms = elapsedMS(since: start)
        if ms > 300 { fsLog.notice("isReachable took \(ms)ms") }
        return ok
    }

    /// Avid writes "<Name>.lck" next to "<Name>.avb" (or "<Name>.avc" for a script) while
    /// it's open. We also accept "<Name>.avb.lck" to be tolerant of variations.
    static func isLocked(binFileName: String, in names: Set<String>) -> Bool {
        lockKey(for: binFileName, in: names) != nil
    }

    /// The (normalised) name of the lock file for a bin, if there is one.
    static func lockKey(for binFileName: String, in names: Set<String>) -> String? {
        let stem = (binFileName as NSString).deletingPathExtension
        return [key(stem + ".lck"), key(binFileName + ".lck")].first(where: names.contains)
    }

    /// Real names of the entries in a directory, keyed by normalised name. nil if unreadable.
    static func realNames(in directory: URL) -> [String: String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return Dictionary(names.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Checks the lock state of each watched bin. Each directory is listed once per call.
    static func probe(_ jobs: [ProbeJob]) -> [UUID: BinState] {
        var holders: [UUID: String] = [:]
        return probe(jobs, holders: &holders)
    }

    /// As above, also noting who has each locked bin open (when that's turned on).
    static func probe(_ jobs: [ProbeJob], holders: inout [UUID: String]) -> [UUID: BinState] {
        let start = DispatchTime.now()
        defer { if !jobs.isEmpty { fsLog.debug("probe \(jobs.count) bins took \(elapsedMS(since: start))ms") } }
        var listings: [URL: [String: String]?] = [:]
        var results: [UUID: BinState] = [:]
        for job in jobs {
            if listings[job.directory] == nil {
                listings[job.directory] = .some(realNames(in: job.directory))
            }
            guard let real = listings[job.directory] ?? nil else {
                results[job.id] = .offline
                continue
            }
            let names = Set(real.keys)
            if !names.contains(key(job.binFileName)) {
                results[job.id] = .missing
            } else if let lock = lockKey(for: job.binFileName, in: names) {
                results[job.id] = .locked
                if let name = real[lock], let holder = LockHolders.holder(of: job.directory.appendingPathComponent(name)) {
                    holders[job.id] = holder
                }
            } else {
                results[job.id] = .available
            }
        }
        return results
    }

    /// The folders and bins directly inside one folder (like a Finder window).
    /// `relative` is this folder's path relative to the monitored folder.
    /// With `detectProjects`, each subfolder is also checked for an .avp file so
    /// Avid projects can get their own icon. Returns nil if the folder can't be read.
    static func listFolder(_ dir: URL, relative: String, detectProjects: Bool) -> FolderListing? {
        let start = DispatchTime.now()
        defer {
            let ms = elapsedMS(since: start)
            if ms > 300 { fsLog.notice("slow listFolder '\(relative, privacy: .public)' took \(ms)ms") }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }

        let byKey = Dictionary(entries.map { (key($0.lastPathComponent), $0) }, uniquingKeysWith: { a, _ in a })
        let names = Set(byKey.keys)
        var listing = FolderListing()
        for entry in entries {
            let name = entry.lastPathComponent
            let rel = relative.isEmpty ? name : relative + "/" + name
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let isProject = detectProjects && containsProjectFile(entry)
                listing.folders.append(FolderItem(name: name, relativePath: rel, isProject: isProject))
            } else if AvidItem.isItem(name) {
                let lock = lockKey(for: name, in: names).flatMap { byKey[$0] }
                listing.bins.append(ScannedBin(relativePath: rel, name: (name as NSString).deletingPathExtension,
                                               folder: relative, isLocked: lock != nil,
                                               lockedBy: lock.flatMap { LockHolders.holder(of: $0) }))
            }
        }
        listing.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listing.bins.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return listing
    }

    /// Which of these subfolders are Avid projects (contain an .avp). Checked in parallel,
    /// because on network storage each check is a round trip.
    static func projectFolders(among folders: [FolderItem], in parent: URL) -> Set<String> {
        let start = DispatchTime.now()
        let lock = NSLock()
        var found = Set<String>()
        DispatchQueue.concurrentPerform(iterations: folders.count) { i in
            if containsProjectFile(parent.appendingPathComponent(folders[i].name)) {
                lock.lock(); found.insert(folders[i].relativePath); lock.unlock()
            }
        }
        fsLog.debug("projectFolders checked \(folders.count) folders in \(elapsedMS(since: start))ms")
        return found
    }

    static func containsProjectFile(_ dir: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { $0.lowercased().hasSuffix(".avp") }
    }

    /// Every folder and bin beneath `root` (used for search). Paths are prefixed with `prefix`.
    /// Returns nil if the folder can't be read.
    static func index(_ root: URL, prefix: String = "", maxDepth: Int = 16) -> FolderListing? {
        guard isReachable(root) else { return nil }
        var result = FolderListing()
        walk(root, relative: prefix, depth: 0, maxDepth: maxDepth, into: &result)
        return result
    }

    private static func walk(_ dir: URL, relative: String, depth: Int, maxDepth: Int, into result: inout FolderListing) {
        guard depth <= maxDepth,
              let listing = listFolder(dir, relative: relative, detectProjects: false) else { return }
        result.bins += listing.bins
        result.folders += listing.folders
        for folder in listing.folders {
            walk(dir.appendingPathComponent(folder.name), relative: folder.relativePath,
                 depth: depth + 1, maxDepth: maxDepth, into: &result)
        }
    }
}

/// Who has a bin or script open. Avid writes the name of the computer (or user) holding a
/// lock into its .lck file. This is the only time Bin Watch opens a file in your project,
/// and only to read it: at most 1 KB, closed straight away, and just once per lock — the
/// answer is remembered until the lock file changes. Turn it off in Settings and Bin Watch
/// never opens a .lck file at all.
enum LockHolders {
    private static let lock = NSLock()
    private static var _enabled = true
    private static var cache: [String: (modified: Date, holder: String?)] = [:]

    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; if !newValue { cache = [:] }; lock.unlock() }
    }

    /// How many lock files have actually been read (tests check the caching).
    private(set) static var reads = 0

    static func holder(of lockFile: URL) -> String? {
        guard enabled else { return nil }
        let modified = (try? lockFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let path = lockFile.path
        lock.lock()
        if let hit = cache[path], hit.modified == modified { lock.unlock(); return hit.holder }
        lock.unlock()

        let holder = readFirstKilobyte(path).flatMap(parse)
        lock.lock()
        cache[path] = (modified, holder)
        reads += 1
        if cache.count > 2000 { cache = [:] }
        lock.unlock()
        return holder
    }

    /// Opens read-only and non-blocking, reads up to 1 KB, closes immediately.
    private static func readFirstKilobyte(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 ? Data(buffer.prefix(count)) : nil
    }

    /// Pulls the name out of a lock file: plain text or UTF-16, padded with zeros.
    static func parse(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(1024))
        guard !bytes.isEmpty else { return nil }
        var text: String
        // UTF-16LE: letters with a zero byte after each.
        let pairs = stride(from: 0, to: bytes.count - 1, by: 2).map { (bytes[$0], bytes[$0 + 1]) }
        let wide = pairs.prefix { $0 != (0, 0) }
        if wide.count >= 2, wide.filter({ $0.1 == 0 }).count * 10 >= wide.count * 8 {
            let units = wide.map { UInt16($0.0) | UInt16($0.1) << 8 }
            text = String(decoding: units, as: UTF16.self)
        } else {
            let narrow = Array(bytes.prefix { $0 != 0 })
            text = String(bytes: narrow, encoding: .utf8) ?? String(bytes: narrow, encoding: .macOSRoman) ?? ""
        }
        // The first run of printable text.
        text = text.components(separatedBy: .controlCharacters)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        text = String(text.unicodeScalars.filter { !CharacterSet.illegalCharacters.contains($0) })
        guard !text.isEmpty, text.count <= 128 else { return nil }
        return text
    }
}

/// Decides when a bin has genuinely become free. Pure logic, so it's easy to test.
///  • Only a locked → available change triggers an alert (never the first reading).
///  • "Available" must be seen on `confirmations` consecutive checks, so a brief
///    flicker of the lock file doesn't cause a false alarm.
///  • Offline / missing readings never alert, and don't erase the last known state.
struct UnlockDetector {
    var confirmations = 2
    private var lastDefinite: [UUID: BinState] = [:]
    private var availableStreak: [UUID: Int] = [:]

    init(confirmations: Int = 2) { self.confirmations = confirmations }

    /// Returns the state to display, and whether to fire an "available" alert.
    mutating func update(_ id: UUID, with reading: BinState) -> (display: BinState, unlocked: Bool) {
        switch reading {
        case .locked:
            lastDefinite[id] = .locked
            availableStreak[id] = 0
            return (.locked, false)
        case .available:
            let streak = (availableStreak[id] ?? 0) + 1
            availableStreak[id] = streak
            switch lastDefinite[id] {
            case .locked?:
                if streak >= confirmations {
                    lastDefinite[id] = .available
                    return (.available, true)
                }
                return (.locked, false)
            default:
                lastDefinite[id] = .available
                return (.available, false)
            }
        case .missing, .offline, .checking:
            availableStreak[id] = 0
            return (reading, false)
        }
    }

    mutating func seed(_ id: UUID, locked: Bool) {
        lastDefinite[id] = locked ? .locked : .available
        availableStreak[id] = 0
    }

    mutating func forget(_ id: UUID) {
        lastDefinite[id] = nil
        availableStreak[id] = nil
    }
}
