import AppKit
import SystemConfiguration
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

    enum MailboxStatus: Equatable {
        case off                 // no mailbox chosen
        case connecting
        case connected
        case waitingForStorage   // the storage isn't there yet: keeps trying by itself
        case needsPermission     // the storage is there, but macOS won't let us in
    }

    @Published private(set) var mailboxPath: String? { didSet { defaults.set(mailboxPath, forKey: "mailboxPath") } }
    @Published private(set) var status: MailboxStatus = .off
    /// My open requests that are confirmed to be in the mailbox.
    @Published private(set) var delivered: Set<UUID> = []
    @Published private(set) var lastCheck: MailboxClient.CheckResult?
    @Published private(set) var checking = false
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
    private var queue = DispatchQueue(label: "binwatch.mailbox", qos: .utility)
    private var timer: Timer?
    private var polling = false
    private var pollStarted = Date.distantPast
    private var pollAgain = false
    private var connecting = false
    private var connectAgain = false
    /// Bumped when a stuck network call is abandoned, so its late answer is ignored.
    private var generation = 0
    private var lastConnectAttempt = Date.distantPast
    private var failingSince: Date?
    private var lastPresence = Date.distantPast
    private var lastCleanUp = Date.distantPast
    private var problemCard: UUID?
    private var problemCardDismissed = false

    /// Replies waiting to be written (a later answer replaces an earlier one).
    private var unsentReplies: [UUID: RequestReply] = [:]
    /// How many looks in a row a request's card has found its file gone.
    private var missingLooks: [UUID: Int] = [:]

    static let retryInterval: TimeInterval = 10
    /// A call to the storage that takes longer than this is treated as stuck.
    static let stuckAfter: TimeInterval = 90
    /// How long the storage must be there, yet refuse us, before asking for the folder again.
    /// It can take a moment after mounting, and asking is an interruption.
    static var permissionGrace: TimeInterval = 30

    /// Incoming requests I've answered or dismissed (so they don't pop up again).
    private var handled: [UUID: Date] = [:] { didSet { saveHandled() } }
    /// Alert cards on screen: request id → card id.
    private var requestCards: [UUID: UUID] = [:]
    /// Reply cards already shown: "requestID|personID|answer".
    private var shownReplies: Set<String> = []
    private var replyCardsByRequest: [UUID: [UUID]] = [:]

    var me: Person {
        Person(id: myID, name: myName, computer: Self.computerName, hostName: Self.localHostName)
    }

    // Read from the Mac's own settings. Host.current() and ProcessInfo.hostName do DNS and
    // Bonjour lookups instead, which makes macOS ask for Local Network access.
    private static let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    private static let localHostName = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }

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

    /// A mailbox has been chosen. It may not be connected right now: see `status`.
    var isSetUp: Bool { mailboxBookmark != nil }
    var mailboxName: String { mailboxPath.map { ($0 as NSString).lastPathComponent } ?? "the mailbox" }

    /// What's wrong, in words, or nil when all is well.
    var statusMessage: String? {
        switch status {
        case .off, .connected: return nil
        case .connecting: return "Connecting to the mailbox…"
        case .waitingForStorage:
            let parts = (mailboxPath ?? "").split(separator: "/")
            let storage = parts.first == "Volumes" && parts.count > 1 ? "“\(parts[1])”" : "The mailbox folder"
            return "\(storage) isn't connected. Bin Watch will reconnect by itself and send anything waiting."
        case .needsPermission:
            return "macOS needs you to choose “\(mailboxName)” again before Bin Watch can use it."
        }
    }

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
        // Network volumes often mount after login items start, and drop during sleep.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.retryNow() }
        }
    }

    /// Look again straight away, rather than at the next retry.
    func retryNow() {
        lastConnectAttempt = .distantPast
        lastPresence = .distantPast
        poll()
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
        panel.directoryURL = mailboxURL ?? mailboxPath.map { URL(fileURLWithPath: $0) }
            ?? AppStore.shared.root?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Volumes")
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
        failingSince = nil
        problemCardDismissed = false
        reconnect()
        return true
    }

    func turnOff() {
        for request in outgoing where request.status == .open { setStatus(.cancelled, of: request.id) }
        if let client {
            let closing = outgoing
            queue.async { for request in closing { try? client.post(request) } }
        }
        mailboxURL?.stopAccessingSecurityScopedResource()
        mailboxURL = nil
        client = nil
        mailboxBookmark = nil
        mailboxPath = nil
        failingSince = nil
        status = .off
        people = []
        delivered = []
        lastCheck = nil
        updateProblemCard()
    }

    /// Opens the saved mailbox, on the background queue because the storage can be slow or
    /// absent. A failure is never final: `poll` keeps calling this until it works, and the
    /// chosen folder is only ever forgotten if you turn it off.
    private func reconnect() {
        guard let bookmark = mailboxBookmark else {
            client = nil
            if status != .off { status = .off }
            return
        }
        guard !connecting else { connectAgain = true; return }
        connecting = true
        lastConnectAttempt = Date()
        if status == .off { status = .connecting }
        let person = me, old = mailboxURL, savedPath = mailboxPath ?? "", started = generation

        queue.async { [weak self] in
            var stale = false
            var url: URL?
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                mailLog.notice("couldn't open the saved mailbox: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            }
            var fresh: Data?
            var client: MailboxClient?
            var access = MailboxClient.Access.unavailable
            var check: MailboxClient.CheckResult?
            if let url {
                // Always ask again: access granted before a volume dropped may no longer work.
                old?.stopAccessingSecurityScopedResource()
                _ = url.startAccessingSecurityScopedResource()
                if stale { fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
                let opened = MailboxClient(folder: url, me: person)
                try? opened.setUp()
                access = opened.checkAccess()
                if access == .ok {
                    client = opened
                    check = opened.runCheck()
                }
            }
            let mounted = Self.volumeIsMounted(for: url?.path ?? savedPath)
            DispatchQueue.main.async {
                guard let self, started == self.generation else { return }
                self.finishConnecting(bookmark: bookmark, url: url, fresh: fresh, client: client,
                                      access: access, mounted: mounted, check: check)
            }
        }
    }

    private func finishConnecting(bookmark: Data, url: URL?, fresh: Data?, client: MailboxClient?,
                                  access: MailboxClient.Access, mounted: Bool, check: MailboxClient.CheckResult?) {
        connecting = false
        defer {
            if connectAgain { connectAgain = false; reconnect() }
        }
        // Turned off, or a different folder chosen, while this was under way.
        guard mailboxBookmark == bookmark else {
            url?.stopAccessingSecurityScopedResource()
            return
        }
        if let url {
            mailboxURL = url
            if mailboxPath != url.path { mailboxPath = url.path }
        }
        if let fresh { mailboxBookmark = fresh }
        if let client, !connectAgain {
            self.client = client
            failingSince = nil
            lastCheck = check
            lastPresence = .distantPast
            setStatus(.connected)
            poll()
        } else if client == nil {
            connectionFailed(access: access, mounted: mounted)
        }
    }

    private func connectionFailed(access: MailboxClient.Access, mounted: Bool) {
        client = nil
        let since = failingSince ?? Date()
        failingSince = since
        let refused = access == .denied || mounted
        setStatus(refused && Date().timeIntervalSince(since) >= Self.permissionGrace ? .needsPermission : .waitingForStorage)
    }

    private func setStatus(_ new: MailboxStatus) {
        if status != new {
            mailLog.notice("mailbox status: \(String(describing: new), privacy: .public)")
            status = new
        }
        updateProblemCard()
    }

    /// Losing access is the one problem Bin Watch can't fix alone, and until it's fixed
    /// colleagues' requests can't reach you, so it says so rather than waiting to be noticed.
    private func updateProblemCard() {
        if status == .needsPermission {
            guard problemCard == nil, !problemCardDismissed else { return }
            let id = UUID()
            problemCard = id
            AlertCenter.shared.present(
                AlertItem(id: id, kind: .mailboxProblem, title: "Bin requests aren't connected",
                          detail: "Choose “\(mailboxName)” again so requests can reach you.", time: Date()),
                onRespond: { [weak self] response in
                    self?.problemCard = nil
                    self?.problemCardDismissed = true
                    if response == .primary {
                        DispatchQueue.main.async { self?.chooseMailboxViaPanel() }
                    }
                })
        } else if let id = problemCard {
            problemCard = nil
            AlertCenter.shared.remove(id)
        }
    }

    static func volumeIsMounted(for path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.first == "Volumes", parts.count > 1 else { return true }
        let volume = "/Volumes/\(parts[1])"
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .contains { $0.path == volume }
    }

    /// "Check Connection" in Settings.
    func checkConnection() {
        guard let client else {
            retryNow()
            return
        }
        checking = true
        queue.async { [weak self] in
            let result = client.runCheck()
            DispatchQueue.main.async {
                self?.checking = false
                self?.lastCheck = result
            }
        }
    }

    // MARK: Asking

    /// Ask someone (or everyone) to close a bin. The bin is watched too, so you're alerted when it frees up.
    /// If the mailbox can't be reached right now, it's sent as soon as it can be.
    func ask(binPath: String, binName: String, to recipient: UUID?, message: String) {
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
        poll()
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
        saveOutgoing()
        poll()
    }

    func name(of personID: UUID?) -> String {
        guard let personID else { return "Everyone" }
        return people.first { $0.id == personID }?.person.name ?? "someone"
    }

    // MARK: Polling

    private func poll() {
        let now = Date()
        // A call to unresponsive storage can hang. Don't let it stop everything for good.
        if (polling && now.timeIntervalSince(pollStarted) > Self.stuckAfter)
            || (connecting && now.timeIntervalSince(lastConnectAttempt) > Self.stuckAfter) {
            mailLog.error("mailbox call stuck; starting over")
            generation += 1
            queue = DispatchQueue(label: "binwatch.mailbox", qos: .utility)
            polling = false
            connecting = false
            client = nil
            setStatus(.waitingForStorage)
        }
        guard !polling else { pollAgain = true; return }
        guard let client else {
            if isSetUp, now.timeIntervalSince(lastConnectAttempt) >= Self.retryInterval { reconnect() }
            return
        }
        polling = true
        pollStarted = now
        let needsPresence = now.timeIntervalSince(lastPresence) > 60
        let needsCleanUp = now.timeIntervalSince(lastCleanUp) > 600
        if needsCleanUp { lastCleanUp = now }
        let mine = Set(outgoing.filter { $0.status == .open }.map(\.id))
        let current = outgoing.filter { now.timeIntervalSince($0.created) < MailboxClient.requestLifetime }
        let unsent = Array(unsentReplies.values)
        let started = generation

        queue.async { [weak self] in
            let access = client.checkAccess()
            var presenceWritten = false
            var people: [(person: Person, lastSeen: Date)]?
            var listing: MailboxClient.RequestListing?
            var confirmed = Set<UUID>()
            var sent: [RequestReply] = []
            var replies: [RequestReply] = []
            if access == .ok {
                if needsPresence {
                    do {
                        try client.publishPresence()
                        presenceWritten = true
                    } catch {
                        mailLog.error("couldn't update presence: \(error.localizedDescription, privacy: .public)")
                    }
                }
                if needsCleanUp { client.cleanUp() }
                people = client.listPeople()
                listing = client.listRequests()
                // The mailbox should match what I know about my requests. Anything that
                // didn't get there, or changed since, is written again.
                if let listing {
                    let listed = Dictionary(listing.requests.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
                    for request in current where request.status == .open || listed[request.id] != nil {
                        if listed[request.id] == request.status {
                            if request.status == .open { confirmed.insert(request.id) }
                            continue
                        }
                        do {
                            try client.post(request)
                            if request.status == .open { confirmed.insert(request.id) }
                        } catch {
                            mailLog.error("couldn't post a request: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
                for reply in unsent where (try? client.send(reply)) != nil { sent.append(reply) }
                replies = client.replies(to: mine)
            }
            DispatchQueue.main.async {
                guard let self, started == self.generation else { return }
                self.polling = false
                defer {
                    if self.pollAgain { self.pollAgain = false; self.poll() }
                }
                guard self.client === client else { return }
                guard access == .ok else {
                    mailLog.notice("lost the mailbox: \(String(describing: access), privacy: .public)")
                    self.connectionFailed(access: access, mounted: Self.volumeIsMounted(for: client.folder.path))
                    self.lastConnectAttempt = .distantPast
                    return
                }
                if presenceWritten { self.lastPresence = now } else if needsPresence { self.lastPresence = now.addingTimeInterval(-45) }
                for reply in sent where self.unsentReplies[reply.requestID] == reply { self.unsentReplies[reply.requestID] = nil }
                self.expireOldRequests()
                if let people {
                    let statuses = people.map { PersonStatus(person: $0.person, lastSeen: $0.lastSeen) }
                        .sorted { ($0.isOnline ? 0 : 1, $0.person.name) < ($1.isOnline ? 0 : 1, $1.person.name) }
                    if self.people != statuses { self.people = statuses }
                }
                if listing != nil, self.delivered != confirmed { self.delivered = confirmed }
                self.handleIncoming(listing)
                self.handleReplies(replies)
            }
        }
    }

    /// My requests stop counting after 12 hours, like everyone else's view of them.
    private func expireOldRequests() {
        let now = Date()
        let isOld: (BinRequest) -> Bool = { now.timeIntervalSince($0.created) >= MailboxClient.requestLifetime }
        guard outgoing.contains(where: isOld) else { return }
        outgoing.removeAll(where: isOld)
        saveOutgoing()
    }

    private func handleIncoming(_ listing: MailboxClient.RequestListing?) {
        // Couldn't look just now: that says nothing about the requests, so change nothing.
        guard let listing else { return }
        let requests = listing.requests
        let byID = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Take down cards for requests that were resolved, cancelled or have expired. A file
        // that's unreadable, or missing for a single look, may just be mid-update.
        for (requestID, cardID) in requestCards {
            if let request = byID[requestID] {
                missingLooks[requestID] = nil
                if request.status == .open { continue }
            } else {
                if listing.unreadable.contains(requestID) { continue }
                let looks = (missingLooks[requestID] ?? 0) + 1
                missingLooks[requestID] = looks
                if looks < 2 { continue }
            }
            missingLooks[requestID] = nil
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
        unsentReplies[request.id] = RequestReply(requestID: request.id, from: me, answer: answer, at: Date())
        poll()
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

    static func relaunch(completion: ((Bool) -> Void)? = nil) {
        guard isSandboxed else { completion?(false); return }     // tests and harnesses run unsandboxed
        UserDefaults.standard.synchronize()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            // Only quit once the new copy is running — never leave the person with no Bin Watch.
            let launched = app != nil && error == nil
            DispatchQueue.main.async {
                completion?(launched)
                if launched { NSApp.terminate(nil) }
            }
        }
    }
}
