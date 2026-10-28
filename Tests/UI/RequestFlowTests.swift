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

        print("Who has it open")
        let samsMac = Person(id: sam.id, name: "Sam", computer: "Edit 2", hostName: "EDIT-2.local")
        let samBox2 = MailboxClient(folder: box, me: samsMac)
        try! samBox2.publishPresence()
        try! Data("EDIT-2".utf8).write(to: lock)            // Sam's Avid has Reel 2 open
        store.ensureWatched(relativePath: reel2)
        pump(5)
        let watchedReel2 = store.watched.first { $0.relativePath == reel2 }
        check(watchedReel2.flatMap { store.holders[$0.id] } == "EDIT-2", "the Watching page knows who has Reel 2 open")
        check(requests.describe(holder: "EDIT-2") == "Sam", "…and recognises it's Sam's Mac")
        check(requests.person(holding: "EDIT-2")?.id == sam.id, "…so asking for it goes to Sam by default")
        check(requests.describe(holder: "SOMEONE-ELSE") == "SOMEONE-ELSE", "an unknown Mac is shown by its name")
        check(requests.describe(holder: ProcessInfo.processInfo.hostName) == "you", "your own Mac is shown as “you”")
        if let w = watchedReel2 { store.unwatch(w) }
        try! Data().write(to: lock)

        print("Bin requests — Sam asks you")
        let ask = BinRequest(id: UUID(), from: sam, to: nil, binName: "Music", binLocation: "Documentary S1",
                             binPath: "Documentary S1/Music.avb", message: "Need to add the score", created: Date(), status: .open)
        try! samBox.post(ask)
        pump(4)
        let card = alerts.items.first { if case .request = $0.kind { return true } else { return false } }
        check(card?.title == "Sam would like “Music”", "a request card appears: \(card?.title ?? "none")")
        check(card?.noun == "bin", "…labelled as a bin request")
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

        let scriptAsk = BinRequest(id: UUID(), from: sam, to: nil, binName: "Opening", binLocation: "Documentary S1 › Scripts",
                                   binPath: "Documentary S1/Scripts/Opening.avc", message: nil, created: Date(), status: .open)
        try! samBox.post(scriptAsk)
        pump(4)
        let scriptCard = alerts.items.first { $0.title == "Sam would like “Opening”" }
        check(scriptCard?.noun == "script", "a request for a script is labelled as a script request")
        if let scriptCard { AlertCenter.shared.respond(scriptCard.id, .dismissed) }

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
        if let available = alerts.items.first(where: { $0.kind == .available }) { AlertCenter.shared.respond(available.id, .secondary) }
        pump(0.5)
        check(!store.isWatched(reel2), "“Dismiss” stops watching")
        fm.createFile(atPath: lock.path, contents: Data())
        requests.turnOff()
    }
}
