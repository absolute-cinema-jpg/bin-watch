import AppKit

/// End to end: this app (as "you") and a simulated colleague, Sam, sharing a mailbox folder.
enum RequestFlowTests {
    static func run(_ store: AppStore, dir: String) {
        let requests = RequestCenter.shared
        let alerts = AlertCenter.shared.model
        let fm = FileManager.default
        let box = URL(fileURLWithPath: dir).appendingPathComponent("Mailbox")
        try? fm.removeItem(at: box)
        try! fm.createDirectory(at: box, withIntermediateDirectories: true)
        let reel2 = "Documentary S1/3 Cuts/Reel 2.avb"
        let lock = URL(fileURLWithPath: dir).appendingPathComponent("Avid Projects/Documentary S1/3 Cuts/Reel 2.lck")
        for bin in store.watched { store.unwatch(bin) }

        print("Bin requests — setup")
        check(MailboxClient.validate(box, monitoredRoot: store.root) == nil, "mailbox folder passes the safety check")
        check(requests.connect(to: box), "connects to the mailbox")
        let sam = Person(id: UUID(), name: "Sam", computer: "Edit 2")
        let samBox = MailboxClient(folder: box, me: sam)
        try! samBox.setUp(); try! samBox.publishPresence()
        pump(4)
        check(requests.people.map(\.person.name) == ["Sam"] && requests.people.first?.isOnline == true, "you can see Sam is online")
        check(samBox.people().contains { $0.person.id == requests.me.id }, "Sam can see you")

        print("Bin requests — Sam asks you")
        let ask = BinRequest(id: UUID(), from: sam, to: nil, binName: "Music", binLocation: "Documentary S1",
                             binPath: "Documentary S1/Music.avb", message: "Need to add the score", created: Date(), status: .open)
        try! samBox.post(ask)
        pump(4)
        let card = alerts.items.first { if case .request = $0.kind { return true } else { return false } }
        check(card?.title == "Sam would like “Music”", "a request card appears: \(card?.title ?? "none")")
        check(samBox.replies(to: [ask.id]).first?.answer == .seen, "Sam sees you've seen it")
        if let card { AlertCenter.shared.respond(card.id, .primary) }
        pump(1)
        check(samBox.replies(to: [ask.id]).first?.answer == .closing, "“I'll close it” tells Sam you're closing it")
        check(!alerts.items.contains { $0.id == card?.id }, "the card goes away")

        let ask2 = BinRequest(id: UUID(), from: sam, to: requests.me.id, binName: "B-Roll", binLocation: "Documentary S1 › 2 Selects",
                              binPath: "Documentary S1/2 Selects/B-Roll.avb", message: nil, created: Date(), status: .open)
        try! samBox.post(ask2)
        pump(4)
        check(alerts.items.contains { $0.title == "Sam would like “B-Roll”" }, "a second, personal request appears")
        var resolved = ask2; resolved.status = .resolved
        try! samBox.post(resolved)
        pump(4)
        check(!alerts.items.contains { $0.title == "Sam would like “B-Roll”" }, "it disappears by itself once the bin is free")

        print("Bin requests — you ask Sam")
        check(fm.fileExists(atPath: lock.path), "Reel 2 is locked")
        requests.ask(binPath: reel2, binName: "Reel 2", to: sam.id, message: "Trailer conform")
        pump(3)
        check(store.isWatched(reel2), "asking also watches the bin")
        let mine = samBox.requests().first { $0.binPath == reel2 }
        check(mine?.to == sam.id && mine?.message == "Trailer conform" && mine?.status == .open, "Sam receives your request")
        try! samBox.send(RequestReply(requestID: mine!.id, from: sam, answer: .notNow, at: Date()))
        pump(4)
        check(alerts.items.contains { $0.title == "Sam can't close it yet" && $0.detail.hasPrefix("Reel 2 · ") }, "Sam's reply pops up")
        check(requests.replies[mine!.id]?.first?.answer == .notNow, "…and shows on the Watching page")
        try! samBox.send(RequestReply(requestID: mine!.id, from: sam, answer: .closing, at: Date()))
        pump(4)
        check(alerts.items.contains { $0.title == "Sam is closing it" }, "Sam changes his mind: closing it")

        print("Bin requests — Sam closes the bin")
        try! fm.removeItem(at: lock)                       // Sam's Avid releases the bin
        pump(8)
        check(alerts.items.contains { $0.kind == .available && $0.title == "Reel 2" }, "you get the “bin available” alert")
        check(!alerts.items.contains { if case .reply = $0.kind { return true } else { return false } }, "the reply cards are cleared")
        check(samBox.requests().first { $0.id == mine!.id }?.status == .resolved, "Sam's Bin Watch learns the request is done")
        check(requests.openRequest(for: reel2) == nil, "no open request left")
        if let available = alerts.items.first(where: { $0.kind == .available }) { AlertCenter.shared.acknowledge(available.id) }
        pump(0.5)
        check(!store.isWatched(reel2), "“Got it” stops watching")
        fm.createFile(atPath: lock.path, contents: Data())
        requests.turnOff()
    }
}
