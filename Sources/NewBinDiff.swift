import Foundation

/// Works out which bins in a folder are genuinely new since the last look.
/// Pure logic (no file access), so it's easy to test.
///
///  • The first look only records what's there — nothing that already existed is "new".
///  • A bin that disappears briefly (e.g. while Avid saves it) and comes back isn't new:
///    vanished bins are remembered for an hour.
///  • A bin moved to another subfolder isn't new: it's matched by its file name.
///  • An unreadable folder (workspace offline) changes nothing — the caller simply
///    doesn't call this without a successful listing.
enum NewBinDiff {
    static let forgetAfter: TimeInterval = 3600

    struct Result: Equatable {
        var added: [String]                 // relative paths of new bins, as listed
        var known: [String: Date]           // updated memory: normalised path → last seen
    }

    /// - Parameters:
    ///   - known: what was seen before (normalised path → last seen), or nil on the first look.
    ///   - current: relative paths of the bins there now.
    static func compare(known: [String: Date]?, current: [String], now: Date = Date()) -> Result {
        var memory: [String: Date] = [:]
        for path in current { memory[ReadOnlyFS.key(path)] = now }
        guard var known else { return Result(added: [], known: memory) }

        // Forget bins that had already vanished at the last look and have been gone a while.
        // (Bins that were there at the last look are kept however long ago that was, so
        // nothing looks "new" just because Bin Watch was closed overnight.)
        if let lastLook = known.values.max() {
            known = known.filter { $0.value == lastLook || now.timeIntervalSince($0.value) < forgetAfter }
        }

        // Remember recently vanished bins, so a quick disappear/reappear isn't "new".
        for (key, lastSeen) in known where memory[key] == nil && now.timeIntervalSince(lastSeen) < forgetAfter {
            memory[key] = lastSeen
        }

        let currentKeys = Set(current.map(ReadOnlyFS.key))
        let vanishedNames = Set(known.keys.filter { !currentKeys.contains($0) }.map(fileName))
        let added = current.filter { path in
            known[ReadOnlyFS.key(path)] == nil && !vanishedNames.contains(fileName(ReadOnlyFS.key(path)))
        }
        return Result(added: added, known: memory)
    }

    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
