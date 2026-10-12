import Foundation
import os

let fsLog = Logger(subsystem: "local.binwatch.BinWatch", category: "fs")

func elapsedMS(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

// ─────────────────────────────────────────────────────────────────────────────
//  ReadOnlyFS — the ONLY code in Bin Watch that touches an Avid project.
//
//  It only ever *lists directory contents*. It never opens, reads, creates,
//  writes, renames, moves or deletes any file — not even the .lck files
//  (it only checks whether their names are present).
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
        let stem = (binFileName as NSString).deletingPathExtension
        return names.contains(key(stem + ".lck")) || names.contains(key(binFileName + ".lck"))
    }

    /// Checks the lock state of each watched bin. Each directory is listed once per call.
    static func probe(_ jobs: [ProbeJob]) -> [UUID: BinState] {
        let start = DispatchTime.now()
        defer { if !jobs.isEmpty { fsLog.debug("probe \(jobs.count) bins took \(elapsedMS(since: start))ms") } }
        var listings: [URL: Set<String>?] = [:]
        var results: [UUID: BinState] = [:]
        for job in jobs {
            if listings[job.directory] == nil {
                listings[job.directory] = .some(listing(of: job.directory))
            }
            guard let names = listings[job.directory] ?? nil else {
                results[job.id] = .offline
                continue
            }
            if !names.contains(key(job.binFileName)) {
                results[job.id] = .missing
            } else if isLocked(binFileName: job.binFileName, in: names) {
                results[job.id] = .locked
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
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }

        let names = Set(entries.map { key($0.lastPathComponent) })
        var listing = FolderListing()
        for entry in entries {
            let name = entry.lastPathComponent
            let rel = relative.isEmpty ? name : relative + "/" + name
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let isProject = detectProjects && containsProjectFile(entry)
                listing.folders.append(FolderItem(name: name, relativePath: rel, isProject: isProject))
            } else if AvidItem.isItem(name) {
                listing.bins.append(ScannedBin(relativePath: rel, name: (name as NSString).deletingPathExtension,
                                               folder: relative, isLocked: isLocked(binFileName: name, in: names)))
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
