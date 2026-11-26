import Foundation

/// Why a lock may have been left behind, usually when Avid crashed or a Mac was switched off
/// with the bin open. Bin Watch only points it out: it never touches lock files. Pure logic,
/// so it's easy to test.
enum LeftoverLock: Equatable {
    /// The person whose Mac the lock names replied that they don't have it open.
    case notOpenThere(name: String)
    /// The lock names this Mac, but Avid isn't running here.
    case avidNotRunning
    /// The lock names this Mac, but it's older than Avid's current session here.
    case beforeAvidStarted
    /// The colleague whose Mac the lock names hasn't had Bin Watch running since before it
    /// was locked, for days.
    case ownerAway(name: String, days: Int)
    /// Simply locked for a long time.
    case old(days: Int)

    struct Facts {
        /// When the lock file was written.
        var lockedSince: Date?
        /// The lock names this Mac (or you).
        var holderIsMe = false
        /// When Avid started on this Mac, or nil if it isn't running.
        var avidStarted: Date?
        /// The holder's name, if they replied "doesn't have it open" after it was locked.
        var deniedBy: String?
        /// The colleague whose Mac the lock names, and when their Bin Watch was last seen.
        var ownerName: String?
        var ownerLastSeen: Date?
        var now = Date()
        /// Flag locks older than this many days. 0 = never by age alone.
        var oldAfterDays = 7
    }

    static let awayAfter: TimeInterval = 3 * 86_400
    /// Lock times come from the storage's clock, which can be a few minutes out.
    static let clockMargin: TimeInterval = 10 * 60

    /// The strongest reason to think this lock is left over, or nil if it looks genuine.
    static func check(_ f: Facts) -> LeftoverLock? {
        if let name = f.deniedBy { return .notOpenThere(name: name) }
        if f.holderIsMe {
            guard let started = f.avidStarted else { return .avidNotRunning }
            if let since = f.lockedSince, since < started.addingTimeInterval(-clockMargin) { return .beforeAvidStarted }
            // Avid is running here and locked it this session: it really is open.
            return nil
        }
        if let since = f.lockedSince {
            if let name = f.ownerName, let seen = f.ownerLastSeen,
               f.now.timeIntervalSince(seen) >= awayAfter, since <= seen.addingTimeInterval(clockMargin) {
                return .ownerAway(name: name, days: Int(f.now.timeIntervalSince(seen) / 86_400))
            }
            let days = Int(f.now.timeIntervalSince(since) / 86_400)
            if f.oldAfterDays > 0 && days >= f.oldAfterDays { return .old(days: days) }
        }
        return nil
    }

    /// One line on why, e.g. "Locked for 9 days".
    var reason: String {
        switch self {
        case .notOpenThere(let name): return "\(name) said they don't have it open"
        case .avidNotRunning: return "It's locked by this Mac, but Avid isn't running"
        case .beforeAvidStarted: return "It was locked before Avid was last started on this Mac"
        case .ownerAway(let name, let days): return "\(name)'s Bin Watch hasn't been on for \(days) days"
        case .old(let days): return "Locked for \(days) days"
        }
    }

    /// The tooltip: why, and what to do about it.
    var explanation: String {
        "\(reason), so this may be a leftover lock, e.g. from Avid crashing. Bin Watch never removes locks. If you're sure no one has it open, its .lck file can be removed in Finder."
    }
}
