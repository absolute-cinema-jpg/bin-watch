import Foundation

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
        guard rename(temp.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Deletes one of *my own* files (only ever inside the mailbox subfolders).
    private func deleteMine(_ name: String, in dir: URL) {
        let allowed = [peopleDir, requestsDir, repliesDir].map(\.standardizedFileURL.path)
        guard allowed.contains(dir.standardizedFileURL.path), !name.contains("/"), !name.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    func publishPresence() throws {
        try write(encoder.encode(me), named: "\(me.id.uuidString).json", in: peopleDir)
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

    private func entries(_ dir: URL) -> [(name: String, modified: Date)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.map {
            ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String, in dir: URL, modified: Date) -> T? {
        let key = dir.lastPathComponent + "/" + name
        if let hit = cache[key], hit.modified == modified, let value = hit.value as? T { return value }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let value = try? decoder.decode(T.self, from: data) else { return nil }
        cache[key] = (modified, value)
        return value
    }

    var isReachable: Bool { FileManager.default.fileExists(atPath: requestsDir.path) }

    /// Everyone else who has used this mailbox, with when they were last seen.
    func people() -> [(person: Person, lastSeen: Date)] {
        entries(peopleDir).compactMap { entry in
            guard let person = decode(Person.self, entry.name, in: peopleDir, modified: entry.modified),
                  person.id != me.id else { return nil }
            return (person, entry.modified)
        }
    }

    /// Requests that haven't expired.
    func requests(now: Date = Date()) -> [BinRequest] {
        entries(requestsDir).compactMap { entry in
            guard let request = decode(BinRequest.self, entry.name, in: requestsDir, modified: entry.modified),
                  now.timeIntervalSince(request.created) < Self.requestLifetime else { return nil }
            return request
        }
    }

    func replies(to requestIDs: Set<UUID>) -> [RequestReply] {
        guard !requestIDs.isEmpty else { return [] }
        return entries(repliesDir).compactMap { entry in
            guard let id = UUID(uuidString: String(entry.name.prefix(36))), requestIDs.contains(id) else { return nil }
            return decode(RequestReply.self, entry.name, in: repliesDir, modified: entry.modified)
        }
    }

    /// Tidies up my own old files. Never touches anyone else's.
    func cleanUp(now: Date = Date()) {
        for entry in entries(requestsDir) {
            guard let request = decode(BinRequest.self, entry.name, in: requestsDir, modified: entry.modified),
                  request.from.id == me.id else { continue }
            let age = now.timeIntervalSince(request.created)
            if age > Self.requestLifetime || (request.status != .open && age > 3600) { deleteMine(entry.name, in: requestsDir) }
        }
        for entry in entries(repliesDir) where entry.name.hasSuffix("_\(me.id.uuidString).json") {
            if now.timeIntervalSince(entry.modified) > Self.requestLifetime { deleteMine(entry.name, in: repliesDir) }
        }
    }
}

private extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") && count > 1 ? String(dropLast()) : self }
}
