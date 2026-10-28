import AppKit
import SwiftUI

/// Asking other Bin Watch users to close a bin, and answering their requests.
/// Talks to the shared mailbox folder (see Mailbox.swift) — no network service needed.
final class RequestCenter: ObservableObject {
    static let shared = RequestCenter()

    struct PersonStatus: Identifiable, Equatable {
        let person: Person
        let lastSeen: Date
        var id: UUID { person.id }
        var isOnline: Bool { Date().timeIntervalSince(lastSeen) < MailboxClient.onlineWindow }
    }

    @Published private(set) var mailboxPath: String? { didSet { defaults.set(mailboxPath, forKey: "mailboxPath") } }
    @Published private(set) var mailboxOnline: Bool?
    @Published private(set) var people: [PersonStatus] = []
    /// My requests, newest first, with everyone's replies.
    @Published private(set) var outgoing: [BinRequest] = []
    @Published private(set) var replies: [UUID: [RequestReply]] = [:]
    @Published var myName: String {
        didSet {
            guard myName != oldValue else { return }
            defaults.set(myName, forKey: "myName")
            reconnect()
        }
    }

    private let defaults = UserDefaults.standard
    private let myID: UUID
    private var mailboxBookmark: Data? { didSet { defaults.set(mailboxBookmark, forKey: "mailboxBookmark") } }
    private var mailboxURL: URL?
    private var client: MailboxClient?
    private let queue = DispatchQueue(label: "binwatch.mailbox", qos: .utility)
    private var timer: Timer?
    private var polling = false
    private var lastPresence = Date.distantPast
    private var lastCleanUp = Date.distantPast

    /// Incoming requests I've answered or dismissed (so they don't pop up again).
    private var handled: [UUID: Date] = [:] { didSet { saveHandled() } }
    /// Alert cards on screen: request id → card id.
    private var requestCards: [UUID: UUID] = [:]
    /// Reply cards already shown: "requestID|personID|answer".
    private var shownReplies: Set<String> = []
    private var replyCardsByRequest: [UUID: [UUID]] = [:]

    var me: Person {
        Person(id: myID, name: myName, computer: Host.current().localizedName ?? "Mac",
               hostName: ProcessInfo.processInfo.hostName)
    }

    // MARK: Who has it open

    /// The Bin Watch user whose Mac matches the name in a lock file, if any.
    func person(holding holder: String) -> PersonStatus? {
        people.first { $0.person.matches(lockHolder: holder) }
    }

    /// "you", a colleague's Bin Watch name, or the name exactly as Avid wrote it.
    func describe(holder: String) -> String {
        if me.matches(lockHolder: holder) { return "you" }
        return person(holding: holder)?.person.name ?? holder
    }
    var isSetUp: Bool { client != nil }

    private init() {
        if let saved = defaults.string(forKey: "myID").flatMap(UUID.init(uuidString:)) {
            myID = saved
        } else {
            myID = UUID()
            defaults.set(myID.uuidString, forKey: "myID")
        }
        myName = defaults.string(forKey: "myName") ?? NSFullUserName()
        mailboxBookmark = defaults.data(forKey: "mailboxBookmark")
        mailboxPath = defaults.string(forKey: "mailboxPath")
        outgoing = (defaults.data(forKey: "outgoingRequests")).flatMap { try? JSONDecoder.iso.decode([BinRequest].self, from: $0) } ?? []
        handled = (defaults.dictionary(forKey: "handledRequests") as? [String: Date] ?? [:])
            .reduce(into: [:]) { result, pair in if let id = UUID(uuidString: pair.key) { result[id] = pair.value } }
        reconnect()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Mailbox folder

    func chooseMailboxViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Shared Mailbox Folder"
        panel.message = "Choose (or create) an empty folder on the shared storage, outside your Avid projects. Everyone using Bin Watch should choose the same folder."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = mailboxURL ?? AppStore.shared.root?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Volumes")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let refusal = MailboxClient.validate(url, monitoredRoot: AppStore.shared.root) {
            let alert = NSAlert()
            alert.messageText = "Bin Watch can't use that folder"
            alert.informativeText = refusal.message + "\n\nBin Watch will restart so it doesn't keep any access to that folder."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            Relauncher.relaunch()   // drop the access the folder picker just granted
            return
        }
        if !connect(to: url) { NSSound.beep() }
    }

    /// Start using a (validated) mailbox folder.
    @discardableResult
    func connect(to url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        mailboxBookmark = bookmark
        mailboxPath = url.path
        reconnect()
        return true
    }

    func turnOff() {
        for request in outgoing where request.status == .open { setStatus(.cancelled, of: request.id) }
        mailboxURL?.stopAccessingSecurityScopedResource()
        mailboxURL = nil
        client = nil
        mailboxBookmark = nil
        mailboxPath = nil
        mailboxOnline = nil
        people = []
    }

    private func reconnect() {
        guard let bookmark = mailboxBookmark else { client = nil; return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        else { mailboxOnline = false; client = nil; return }
        if mailboxURL != url {
            mailboxURL?.stopAccessingSecurityScopedResource()
            _ = url.startAccessingSecurityScopedResource()
            mailboxURL = url
        }
        if mailboxPath != url.path { mailboxPath = url.path }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            mailboxBookmark = fresh
        }
        let client = MailboxClient(folder: url, me: me)
        self.client = client
        lastPresence = .distantPast
        queue.async {
            try? client.setUp()
            try? client.publishPresence()
        }
        poll()
    }

    // MARK: Asking

    /// Ask someone (or everyone) to close a bin. The bin is watched too, so you're alerted when it frees up.
    func ask(binPath: String, binName: String, to recipient: UUID?, message: String) {
        guard let client else { return }
        AppStore.shared.ensureWatched(relativePath: binPath)
        let folder = (binPath as NSString).deletingLastPathComponent
        let request = BinRequest(
            id: UUID(), from: me, to: recipient, binName: binName,
            binLocation: displayPath(folder, root: AppStore.shared.rootName),
            binPath: binPath,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : message,
            created: Date(), status: .open)
        // Asking again replaces any earlier request for the same bin.
        for old in outgoing where old.binPath == binPath && old.status == .open { setStatus(.cancelled, of: old.id) }
        outgoing.insert(request, at: 0)
        saveOutgoing()
        queue.async { try? client.post(request) }
    }

    func openRequest(for binPath: String) -> BinRequest? {
        outgoing.first { $0.binPath == binPath && $0.status == .open }
    }

    func cancelRequest(for binPath: String) {
        for request in outgoing where request.binPath == binPath && request.status == .open {
            setStatus(.cancelled, of: request.id)
        }
    }

    /// Called when a watched bin frees up: any request for it is done.
    func binBecameAvailable(_ binPath: String) {
        for request in outgoing where request.binPath == binPath && request.status == .open {
            setStatus(.resolved, of: request.id)
            for card in replyCardsByRequest[request.id] ?? [] { AlertCenter.shared.remove(card) }
        }
    }

    private func setStatus(_ status: BinRequest.Status, of id: UUID) {
        guard let i = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[i].status = status
        let updated = outgoing[i]
        saveOutgoing()
        if let client { queue.async { try? client.post(updated) } }
    }

    func name(of personID: UUID?) -> String {
        guard let personID else { return "Everyone" }
        return people.first { $0.id == personID }?.person.name ?? "someone"
    }

    // MARK: Polling

    private func poll() {
        guard let client, !polling else { return }
        polling = true
        let now = Date()
        let needsPresence = now.timeIntervalSince(lastPresence) > 60
        let needsCleanUp = now.timeIntervalSince(lastCleanUp) > 600
        if needsPresence { lastPresence = now }
        if needsCleanUp { lastCleanUp = now }
        let mine = Set(outgoing.filter { $0.status == .open }.map(\.id))

        queue.async { [weak self] in
            let online = client.isReachable
            if online && needsPresence { try? client.publishPresence() }
            if online && needsCleanUp { client.cleanUp() }
            let people = online ? client.people() : []
            let requests = online ? client.requests() : []
            let replies = online ? client.replies(to: mine) : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                guard self.client === client else { return }
                if self.mailboxOnline != online { self.mailboxOnline = online }
                guard online else { return }
                let statuses = people.map { PersonStatus(person: $0.person, lastSeen: $0.lastSeen) }
                    .sorted { ($0.isOnline ? 0 : 1, $0.person.name) < ($1.isOnline ? 0 : 1, $1.person.name) }
                if self.people != statuses { self.people = statuses }
                self.handleIncoming(requests)
                self.handleReplies(replies)
            }
        }
    }

    private func handleIncoming(_ requests: [BinRequest]) {
        let byID = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Take down cards for requests that were resolved, cancelled or have expired.
        for (requestID, cardID) in requestCards where byID[requestID]?.status != .open {
            AlertCenter.shared.remove(cardID)
            requestCards[requestID] = nil
            handled[requestID] = Date()
        }

        for request in requests where request.status == .open
            && request.from.id != myID
            && (request.to == nil || request.to == myID)
            && handled[request.id] == nil
            && requestCards[request.id] == nil {
            showRequest(request)
        }
    }

    private func showRequest(_ request: BinRequest) {
        let cardID = UUID()
        requestCards[request.id] = cardID
        let detail = request.message.map { "“\($0)”" } ?? request.binLocation
        AlertCenter.shared.present(
            AlertItem(id: cardID, kind: .request(everyone: request.isForEveryone),
                      title: "\(request.from.name) would like “\(request.binName)”",
                      detail: detail, time: request.created, noun: AvidItem.noun(request.binPath)),
            onRespond: { [weak self] response in self?.answer(request, response) })
        reply(to: request, .seen)
    }

    private func answer(_ request: BinRequest, _ response: AlertResponse) {
        requestCards[request.id] = nil
        handled[request.id] = Date()
        switch response {
        case .primary:   reply(to: request, .closing)
        case .secondary: reply(to: request, request.isForEveryone ? .notMe : .notNow)
        case .dismissed: break
        }
    }

    private func reply(to request: BinRequest, _ answer: RequestReply.Answer) {
        guard let client else { return }
        let reply = RequestReply(requestID: request.id, from: me, answer: answer, at: Date())
        queue.async { try? client.send(reply) }
    }

    private func handleReplies(_ incoming: [RequestReply]) {
        var grouped: [UUID: [RequestReply]] = [:]
        for reply in incoming { grouped[reply.requestID, default: []].append(reply) }
        if grouped != replies { replies = grouped }
        for reply in incoming where reply.answer == .closing || reply.answer == .notNow {
            let key = "\(reply.requestID)|\(reply.from.id)|\(reply.answer.rawValue)"
            guard !shownReplies.contains(key),
                  let request = outgoing.first(where: { $0.id == reply.requestID && $0.status == .open }) else { continue }
            shownReplies.insert(key)
            let cardID = UUID()
            replyCardsByRequest[request.id, default: []].append(cardID)
            let title = reply.answer == .closing
                ? "\(reply.from.name) is closing it"
                : "\(reply.from.name) can't close it yet"
            AlertCenter.shared.present(
                AlertItem(id: cardID, kind: .reply(positive: reply.answer == .closing),
                          title: title, detail: "\(request.binName) · \(request.binLocation)", time: reply.at),
                onRespond: { _ in })
        }
    }

    // MARK: Persistence

    private func saveOutgoing() {
        let recent = outgoing.filter { Date().timeIntervalSince($0.created) < MailboxClient.requestLifetime }
        defaults.set(try? JSONEncoder.iso.encode(recent), forKey: "outgoingRequests")
    }

    private func saveHandled() {
        let recent = handled.filter { Date().timeIntervalSince($0.value) < MailboxClient.requestLifetime }
        defaults.set(Dictionary(uniqueKeysWithValues: recent.map { ($0.key.uuidString, $0.value) }), forKey: "handledRequests")
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

/// Restarts Bin Watch. Used after a folder is picked, so the app never keeps the write
/// access macOS's folder picker grants for the rest of the session — only the
/// read-only access saved for the monitored folder (and write access to the mailbox).
enum Relauncher {
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    static func relaunch() {
        guard isSandboxed else { return }     // tests and harnesses run unsandboxed
        UserDefaults.standard.synchronize()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--show-window"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            // Only quit once the new copy is running — never leave the person with no Bin Watch.
            guard app != nil, error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
