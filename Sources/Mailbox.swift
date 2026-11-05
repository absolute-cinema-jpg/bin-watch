import Foundation
import os

let mailLog = Logger(subsystem: "local.binwatch.BinWatch", category: "mailbox")

// ─────────────────────────────────────────────────────────────────────────────
//  Mailbox — how Bin Watch users ask each other for bins, with no network service.
//
//  Everyone who shares the Avid storage (NEXIS, SyncBox, a file server…) picks the
//  same "mailbox" folder on it. Messages are small JSON files in that folder:
//
//    people/<person-id>.json                  who's using Bin Watch (refreshed every minute)
//    requests/<request-id>.json               "please close this bin"   — written only by the asker
//    replies/<request-id>_<person-id>.json    "seen" / "closing it"…    — written only by the replier
//
//  Each file has exactly one writer, so two machines never edit the same file.
//
//  This is the ONLY place Bin Watch writes to shared storage. Every write goes through
//  `write(_:named:in:)`, which refuses anything outside those three subfolders. The
//  mailbox itself can never be inside an Avid project (see `validate`).
// ─────────────────────────────────────────────────────────────────────────────

struct Person: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var computer: String
    /// The Mac's network name (e.g. "Edit-2"), which Avid may use in lock files.
    var hostName: String? = nil

    /// Is this the person whose Mac (or name) Avid wrote into a lock file?
    func matches(lockHolder: String) -> Bool {
        let holder = Self.normalize(lockHolder)
        guard !holder.isEmpty else { return false }
        return [computer, hostName, name].compactMap { $0 }.contains { Self.normalize($0) == holder }
    }

    /// "Sam's Mac Pro", "SAMS-MAC-PRO" and "sams-mac-pro.local" all compare equal.
    static func normalize(_ name: String) -> String {
        var s = name.lowercased()
        if s.hasSuffix(".local") { s.removeLast(6) }
        return String(s.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}

/// What's in a people/ file: the person, plus when their Bin Watch last wrote it (by its own
/// clock, so a file server with the wrong time can't make someone look long gone).
/// Older versions of Bin Watch don't write `at`, and just ignore it when reading.
struct Presence: Codable {
    let id: UUID
    let name: String
    let computer: String
    var hostName: String? = nil
    var at: Date? = nil

    init(_ person: Person, at: Date) {
        id = person.id; name = person.name; computer = person.computer; hostName = person.hostName
        self.at = at
    }

    var person: Person { Person(id: id, name: name, computer: computer, hostName: hostName) }
}

struct BinRequest: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case open, resolved, cancelled }

    let id: UUID
    let from: Person
    let to: UUID?                // nil = everyone using Bin Watch
    let binName: String
    let binLocation: String      // human-readable, e.g. "Doc S1 › Reels"
    let binPath: String          // the asker's path, relative to their monitored folder
    let message: String?
    let created: Date
    var status: Status

    var isForEveryone: Bool { to == nil }
}

struct RequestReply: Codable, Equatable {
    enum Answer: String, Codable { case seen, closing, notNow, notMe }

    let requestID: UUID
    let from: Person
    var answer: Answer
    var at: Date
}

final class MailboxClient {
    let folder: URL
    let me: Person

    static let requestLifetime: TimeInterval = 12 * 3600
    static let onlineWindow: TimeInterval = 3 * 60

    private var peopleDir: URL { folder.appendingPathComponent("people", isDirectory: true) }
    private var requestsDir: URL { folder.appendingPathComponent("requests", isDirectory: true) }
    private var repliesDir: URL { folder.appendingPathComponent("replies", isDirectory: true) }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Decoded files, re-read only when their modification date changes.
    private var cache: [String: (modified: Date, value: Any)] = [:]

    /// How files are moved into place. Tests swap this to imitate other file systems.
    var renameFile: (String, String) -> Int32 = { rename($0, $1) }

    init(folder: URL, me: Person) {
        self.folder = folder
        self.me = me
    }

    // MARK: Checking a folder before using it

    enum Refusal: Error, Equatable {
        case isMonitoredFolder
        case containsMonitoredFolder
        case insideAvidProject(String)
        case containsProjectFiles
        case unreadable

        var message: String {
            switch self {
            case .isMonitoredFolder:
                return "That's the folder Bin Watch monitors. Choose a separate folder for messages, outside your Avid projects."
            case .containsMonitoredFolder:
                return "That folder contains the folder Bin Watch monitors. Choose a separate folder for messages, outside your Avid projects."
            case .insideAvidProject(let project):
                return "That folder is inside the Avid project “\(project)”. Bin Watch never writes inside a project — choose a folder outside it."
            case .containsProjectFiles:
                return "That folder contains Avid project files, bins or scripts. Choose an empty folder, or create a new one."
            case .unreadable:
                return "Bin Watch couldn't read that folder."
            }
        }
    }

    /// The mailbox must never be (or contain, or be inside) an Avid project or the monitored folder.
    static func validate(_ candidate: URL, monitoredRoot: URL?) -> Refusal? {
        let path = candidate.standardizedFileURL.path
        if let root = monitoredRoot?.standardizedFileURL.path {
            if same(path, root) { return .isMonitoredFolder }
            if isInside(root, path) { return .containsMonitoredFolder }
            // Walk from the candidate up to the monitored folder, looking for an Avid project.
            if isInside(path, root) {
                var dir = candidate.standardizedFileURL
                while isInside(dir.path, root) || same(dir.path, root) {
                    if ReadOnlyFS.containsProjectFile(dir) { return .insideAvidProject(dir.lastPathComponent) }
                    if same(dir.path, root) { break }
                    dir = dir.deletingLastPathComponent()
                }
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return .unreadable }
        if names.contains(where: { ["avp", "avb", "avc", "avs"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            return .containsProjectFiles
        }
        return nil
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        ReadOnlyFS.key(a.trimmingTrailingSlash) == ReadOnlyFS.key(b.trimmingTrailingSlash)
    }

    /// Is `path` strictly inside `ancestor`?
    private static func isInside(_ path: String, _ ancestor: String) -> Bool {
        ReadOnlyFS.key(path).hasPrefix(ReadOnlyFS.key(ancestor.trimmingTrailingSlash) + "/")
    }

    // MARK: Writing (guarded)

    private struct OutsideMailbox: Error {}

    func setUp() throws {
        // Never create the mailbox folder itself (e.g. if the volume isn't mounted) — only
        // its subfolders. Another Mac may be creating them at the same moment: that's fine.
        guard FileManager.default.fileExists(atPath: folder.path) else { throw CocoaError(.fileNoSuchFile) }
        for dir in [peopleDir, requestsDir, repliesDir] where !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        let readme = folder.appendingPathComponent("About this folder.txt")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            This folder is a shared mailbox for Bin Watch. People use it to ask each other \
            to close Avid bins they need. It only holds small message files; it's safe to \
            leave alone. Please don't put project files here.
            """
            try write(Data(text.utf8), named: readme.lastPathComponent, in: folder)
        }
    }

    /// The single write path. Only ever writes a plain file name directly inside the mailbox
    /// or one of its three subfolders, atomically (temp file + rename).
    private func write(_ data: Data, named name: String, in dir: URL) throws {
        let allowed = [folder, peopleDir, requestsDir, repliesDir].map(\.standardizedFileURL.path)
        guard allowed.contains(dir.standardizedFileURL.path),
              !name.contains("/"), !name.hasPrefix("."), name != ".."
        else { throw OutsideMailbox() }
        let destination = dir.appendingPathComponent(name)
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        if renameFile(temp.path, destination.path) == 0 { return }
        let failure = errno
        // Some network file systems won't rename over an existing file. Each file here has
        // one writer, so it's safe to take the old one away and try again.
        if FileManager.default.fileExists(atPath: destination.path) {
            mailLog.notice("rename over \(name, privacy: .public) failed (errno \(failure)); replacing it instead")
            try? FileManager.default.removeItem(at: destination)
            if renameFile(temp.path, destination.path) == 0 {
                replaceNeededWorkaround = true
                return
            }
        }
        try? FileManager.default.removeItem(at: temp)
        mailLog.error("couldn't write \(name, privacy: .public): errno \(failure)")
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    /// Set once this storage has refused to rename over an existing file.
    private(set) var replaceNeededWorkaround = false

    /// Deletes one of *my own* files (only ever inside the mailbox subfolders).
    private func deleteMine(_ name: String, in dir: URL) {
        let allowed = [peopleDir, requestsDir, repliesDir].map(\.standardizedFileURL.path)
        guard allowed.contains(dir.standardizedFileURL.path), !name.contains("/"), !name.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    func publishPresence(now: Date = Date()) throws {
        try write(encoder.encode(Presence(me, at: now)), named: "\(me.id.uuidString).json", in: peopleDir)
    }

    func post(_ request: BinRequest) throws {
        guard request.from.id == me.id else { throw OutsideMailbox() }
        try write(encoder.encode(request), named: "\(request.id.uuidString).json", in: requestsDir)
    }

    func send(_ reply: RequestReply) throws {
        guard reply.from.id == me.id else { throw OutsideMailbox() }
        try write(encoder.encode(reply), named: "\(reply.requestID.uuidString)_\(me.id.uuidString).json", in: repliesDir)
    }

    // MARK: Reading

    /// The message files in a folder, or nil if it couldn't be listed just now.
    private func entries(_ dir: URL) -> [(name: String, modified: Date)]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return nil }
        return urls.filter { $0.pathExtension == "json" }.map {
            ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String, in dir: URL, modified: Date) -> T? {
        let key = dir.lastPathComponent + "/" + name
        if let hit = cache[key], hit.modified == modified, modified != .distantPast, let value = hit.value as? T { return value }
        // A read that fails (a network blip) falls back to what we last read successfully.
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let value = try? decoder.decode(T.self, from: data) else { return cache[key]?.value as? T }
        cache[key] = (modified, value)
        return value
    }

    var isReachable: Bool { FileManager.default.fileExists(atPath: requestsDir.path) }

    enum Access: Equatable { case ok, unavailable, denied }

    /// Can we actually read the mailbox? "Denied" means macOS is refusing us, as opposed to
    /// the storage just not being there.
    func checkAccess() -> Access {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: requestsDir.path)
            return .ok
        } catch {
            return Self.isPermissionError(error) ? .denied : .unavailable
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == CocoaError.fileReadNoPermission.rawValue { return true }
        let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError) ?? e
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    /// Everyone else who has used this mailbox, with when they were last seen. nil if the
    /// list couldn't be read. Someone who reinstalled appears once, as their newest self.
    func listPeople(now: Date = Date()) -> [(person: Person, lastSeen: Date)]? {
        guard let files = entries(peopleDir) else { return nil }
        var newest: [String: (person: Person, lastSeen: Date)] = [:]
        for entry in files {
            guard let presence = decode(Presence.self, entry.name, in: peopleDir, modified: entry.modified),
                  presence.id != me.id else { continue }
            let person = presence.person
            let lastSeen = min(presence.at ?? entry.modified, now)
            let key = Person.normalize(person.name) + "|" + Person.normalize(person.computer)
            if let seen = newest[key], seen.lastSeen >= lastSeen { continue }
            newest[key] = (person, lastSeen)
        }
        return Array(newest.values)
    }

    func people() -> [(person: Person, lastSeen: Date)] { listPeople() ?? [] }

    struct RequestListing {
        var requests: [BinRequest] = []
        /// Files that are there but can't be read yet — not the same as being gone.
        var unreadable: Set<UUID> = []
    }

    /// Requests that haven't expired, or nil if the list couldn't be read.
    func listRequests(now: Date = Date()) -> RequestListing? {
        guard let files = entries(requestsDir) else { return nil }
        var listing = RequestListing()
        for entry in files {
            guard let request = decode(BinRequest.self, entry.name, in: requestsDir, modified: entry.modified) else {
                if let id = UUID(uuidString: String(entry.name.prefix(36))) { listing.unreadable.insert(id) }
                continue
            }
            if now.timeIntervalSince(request.created) < Self.requestLifetime { listing.requests.append(request) }
        }
        return listing
    }

    func requests(now: Date = Date()) -> [BinRequest] { listRequests(now: now)?.requests ?? [] }

    // MARK: Checking the connection

    struct CheckResult: Equatable {
        var problem: String?           // nil = everything worked
        var usedReplaceWorkaround = false
        /// How far the storage's clock is from this Mac's (seconds; positive = storage ahead).
        var clockOffset: TimeInterval?
    }

    /// Tries everything the mailbox needs: listing, writing, replacing and reading back a small
    /// test file of our own, which it then removes.
    func runCheck(now: Date = Date()) -> CheckResult {
        var result = performCheck(now: now)
        result.usedReplaceWorkaround = replaceNeededWorkaround
        mailLog.notice("check: problem=\(result.problem ?? "none", privacy: .public) replaceWorkaround=\(result.usedReplaceWorkaround) clockOffset=\(result.clockOffset ?? 0)")
        return result
    }

    private func performCheck(now: Date) -> CheckResult {
        var result = CheckResult()
        let name = "check-\(me.id.uuidString).json"
        let file = folder.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            for dir in [peopleDir, requestsDir, repliesDir] { _ = try FileManager.default.contentsOfDirectory(atPath: dir.path) }
        } catch {
            result.problem = Self.isPermissionError(error) ? "macOS is refusing access to the mailbox folder." : "The mailbox folder can't be read."
            return result
        }
        do {
            try write(Data("first".utf8), named: name, in: folder)
            let secondWrite = Data("second".utf8)
            try write(secondWrite, named: name, in: folder)
            guard try Data(contentsOf: file) == secondWrite else {
                result.problem = "A message written to the mailbox read back differently."
                return result
            }
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                result.clockOffset = modified.timeIntervalSince(now)
            }
        } catch {
            result.problem = Self.isPermissionError(error) ? "macOS is refusing to let Bin Watch write to the mailbox folder." : "Bin Watch couldn't write to the mailbox folder."
        }
        return result
    }

    func replies(to requestIDs: Set<UUID>) -> [RequestReply] {
        guard !requestIDs.isEmpty else { return [] }
        return (entries(repliesDir) ?? []).compactMap { entry in
            guard let id = UUID(uuidString: String(entry.name.prefix(36))), requestIDs.contains(id) else { return nil }
            return decode(RequestReply.self, entry.name, in: repliesDir, modified: entry.modified)
        }
    }

    /// Tidies up my own old files. Never touches anyone else's.
    func cleanUp(now: Date = Date()) {
        for entry in entries(requestsDir) ?? [] {
            guard let request = decode(BinRequest.self, entry.name, in: requestsDir, modified: entry.modified),
                  request.from.id == me.id else { continue }
            let age = now.timeIntervalSince(request.created)
            if age > Self.requestLifetime || (request.status != .open && age > 3600) { deleteMine(entry.name, in: requestsDir) }
        }
        for entry in entries(repliesDir) ?? [] where entry.name.hasSuffix("_\(me.id.uuidString).json") {
            if now.timeIntervalSince(entry.modified) > Self.requestLifetime { deleteMine(entry.name, in: repliesDir) }
        }
    }
}

private extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") && count > 1 ? String(dropLast()) : self }
}
