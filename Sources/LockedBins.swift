import Foundation

/// Whoever has a set of locked bins open, as shown on the Locked page.
struct LockOwner: Hashable, Identifiable {
    enum Kind: Hashable { case me, colleague, computer, unknown }
    let id: String
    let name: String
    let kind: Kind

    static let unknown = LockOwner(id: "unknown", name: "Unknown", kind: .unknown)
}

/// Groups locked bins by who has them open. Pure logic, so it's easy to test.
enum LockedBins {
    struct Group: Identifiable {
        let owner: LockOwner
        var items: [ScannedBin]
        var id: String { owner.id }
    }

    /// You, a colleague who uses Bin Watch (by their name), the computer name Avid wrote in
    /// the lock file, or "Unknown" if it didn't say (or reading lock files is turned off).
    /// "EDIT-2" and "edit-2.local" count as the same computer.
    static func owner(of holder: String?, me: Person, people: [Person]) -> LockOwner {
        guard let holder, !Person.normalize(holder).isEmpty else { return .unknown }
        if me.matches(lockHolder: holder) { return LockOwner(id: "me", name: "You", kind: .me) }
        if let person = people.first(where: { $0.matches(lockHolder: holder) }) {
            return LockOwner(id: person.id.uuidString, name: person.name, kind: .colleague)
        }
        return LockOwner(id: "mac:" + Person.normalize(holder), name: holder, kind: .computer)
    }

    /// You first, then people and computers A–Z, and "Unknown" last.
    static func group(_ items: [ScannedBin], me: Person, people: [Person]) -> [Group] {
        var groups: [String: Group] = [:]
        for item in items {
            let owner = owner(of: item.lockedBy, me: me, people: people)
            groups[owner.id, default: Group(owner: owner, items: [])].items.append(item)
        }
        func rank(_ kind: LockOwner.Kind) -> Int {
            switch kind {
            case .me: return 0
            case .colleague, .computer: return 1
            case .unknown: return 2
            }
        }
        return groups.values.sorted { a, b in
            rank(a.owner.kind) != rank(b.owner.kind) ? rank(a.owner.kind) < rank(b.owner.kind)
                : a.owner.name.localizedStandardCompare(b.owner.name) == .orderedAscending
        }
    }

    /// Name or folder contains the search text (ignoring case and accents).
    static func matches(_ item: ScannedBin, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [item.name, item.folder].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
