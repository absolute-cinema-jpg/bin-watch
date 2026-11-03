// Tests the read-only lock detection and alert logic against a fake Avid project.
// Run: ./Tests/run.sh
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ✓ \(msg)" : "  ✗ \(msg)")
    if !cond { failures += 1 }
}

@main enum CoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Fake Project")
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root.appendingPathComponent("Reels/Old"), withIntermediateDirectories: true)
        for f in ["Fake Project.avp", "Assembly.avb", "Reels/Reel 1.avb", "Reels/Reel 2.avb", "Reels/Old/Café.avb"] {
            fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data())
        }
        // Test fixtures only — this is the test harness, not the app.
        fm.createFile(atPath: root.appendingPathComponent("Reels/Reel 1.lck").path, contents: Data())
        // NFD-normalised lock name, as network volumes often report.
        fm.createFile(atPath: root.appendingPathComponent("Reels/Old/" + "Café.lck".decomposedStringWithCanonicalMapping).path, contents: Data())

        print("Browsing (one folder at a time)")
        let top = ReadOnlyFS.listFolder(root, relative: "", detectProjects: true)!
        check(top.folders.map(\.name) == ["Reels"], "top level shows the Reels folder: \(top.folders.map(\.name))")
        check(top.bins.map(\.name) == ["Assembly"], "top level shows the Assembly bin only (not .avp/.lck)")
        let reels = ReadOnlyFS.listFolder(root.appendingPathComponent("Reels"), relative: "Reels", detectProjects: false)!
        check(reels.folders.map(\.relativePath) == ["Reels/Old"], "subfolder paths are relative to the monitored folder")
        check(reels.bins.map(\.relativePath) == ["Reels/Reel 1.avb", "Reels/Reel 2.avb"], "bins sorted naturally")
        check(reels.bins.first { $0.name == "Reel 1" }?.isLocked == true, "Reel 1 is locked")
        check(reels.bins.first { $0.name == "Reel 2" }?.isLocked == false, "Reel 2 is free")
        let parent = ReadOnlyFS.listFolder(root.deletingLastPathComponent(), relative: "", detectProjects: true)!
        check(parent.folders.first { $0.name == "Fake Project" }?.isProject == true, "folder with an .avp is recognised as a project")
        check(ReadOnlyFS.listFolder(root.appendingPathComponent("nope"), relative: "", detectProjects: false) == nil, "unreachable folder → nil")

        print("Scripts (.avc)")
        fm.createFile(atPath: root.appendingPathComponent("Reels/Opening.avc").path, contents: Data())
        fm.createFile(atPath: root.appendingPathComponent("Reels/Closing.avc").path, contents: Data())
        fm.createFile(atPath: root.appendingPathComponent("Reels/Opening.lck").path, contents: Data())
        let withScripts = ReadOnlyFS.listFolder(root.appendingPathComponent("Reels"), relative: "Reels", detectProjects: false)!
        check(withScripts.bins.map(\.name) == ["Closing", "Opening", "Reel 1", "Reel 2"], "scripts are listed alongside bins: \(withScripts.bins.map(\.name))")
        check(withScripts.bins.first { $0.name == "Opening" }.map { $0.isScript && $0.isLocked } == true, "an open script (with a .lck) shows as locked")
        check(withScripts.bins.first { $0.name == "Closing" }.map { $0.isScript && !$0.isLocked } == true, "a closed script is free")
        let scriptJob = ProbeJob(id: UUID(), directory: root.appendingPathComponent("Reels"), binFileName: "Opening.avc")
        check(ReadOnlyFS.probe([scriptJob])[scriptJob.id] == .locked, "watching a script checks its lock file")
        check((try? PathInput.resolve("/Volumes/Project/Doc/Opening.avc", rootPath: "/Volumes/Project").get())?.bin == "Doc/Opening.avc",
              "a pasted script path selects the script")
        check(AvidItem.count(["a.avb", "b.avb", "c.avc"]) == "2 bins and 1 script", "mixed counts read naturally")
        check(AvidItem.count(["c.avc"]) == "1 script" && AvidItem.noun("x/y.avc") == "script" && AvidItem.noun("x/y.avb") == "bin",
              "single items are named correctly")
        for f in ["Opening.avc", "Closing.avc", "Opening.lck"] { try? fm.removeItem(at: root.appendingPathComponent("Reels/" + f)) }

        print("Who has it open (lock file contents)")
        func utf16(_ s: String) -> Data { var d = Data(); for u in s.utf16 { d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }; return d }
        check(LockHolders.parse(Data("EDIT-2".utf8) + Data(repeating: 0, count: 200)) == "EDIT-2", "plain text padded with zeros")
        check(LockHolders.parse(utf16("Sam's Mac Pro") + Data(repeating: 0, count: 64)) == "Sam's Mac Pro", "UTF-16 text")
        check(LockHolders.parse(Data("  ASSIST-1\r\n".utf8)) == "ASSIST-1", "trims spaces and line endings")
        check(LockHolders.parse(Data("EDIT-3".utf8) + Data([0, 0x13, 0x88, 0x01])) == "EDIT-3", "ignores binary after the name")
        check(LockHolders.parse(Data()) == nil && LockHolders.parse(Data([0, 0, 0, 0])) == nil, "empty or blank → no name")
        let reelsDir = root.appendingPathComponent("Reels")
        let lockURL = reelsDir.appendingPathComponent("Reel 1.lck")
        try Data("EDIT-2".utf8).write(to: lockURL)
        let before = LockHolders.reads
        let firstLook = ReadOnlyFS.listFolder(reelsDir, relative: "Reels", detectProjects: false)!
        check(firstLook.bins.first { $0.name == "Reel 1" }?.lockedBy == "EDIT-2", "the listing shows who has Reel 1 open")
        check(firstLook.bins.first { $0.name == "Reel 2" }?.lockedBy == nil, "…and nobody for a free bin")
        _ = ReadOnlyFS.listFolder(reelsDir, relative: "Reels", detectProjects: false)
        _ = ReadOnlyFS.listFolder(reelsDir, relative: "Reels", detectProjects: false)
        check(LockHolders.reads == before + 1, "a lock file is read once, not on every look (\(LockHolders.reads - before) reads)")
        try Data("EDIT-9".utf8).write(to: lockURL)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: lockURL.path)
        check(ReadOnlyFS.listFolder(reelsDir, relative: "Reels", detectProjects: false)!.bins.first { $0.name == "Reel 1" }?.lockedBy == "EDIT-9",
              "…and read again only when the lock file changes")
        var holders: [UUID: String] = [:]
        let lockedJob = ProbeJob(id: UUID(), directory: reelsDir, binFileName: "Reel 1.avb")
        _ = ReadOnlyFS.probe([lockedJob], holders: &holders)
        check(holders[lockedJob.id] == "EDIT-9", "watched bins report who has them open")
        LockHolders.enabled = false
        let readsWhenOff = LockHolders.reads
        let off = ReadOnlyFS.listFolder(reelsDir, relative: "Reels", detectProjects: false)!
        check(off.bins.first { $0.name == "Reel 1" }.map { $0.isLocked && $0.lockedBy == nil } == true && LockHolders.reads == readsWhenOff,
              "turned off: still shows locked, but never opens the lock file")
        LockHolders.enabled = true
        try Data().write(to: lockURL)

        print("Matching a lock to a Bin Watch user")
        let samMac = Person(id: UUID(), name: "Sam Okafor", computer: "Sam's Mac Pro", hostName: "Sams-Mac-Pro.local")
        check(samMac.matches(lockHolder: "SAMS-MAC-PRO"), "network name matches")
        check(samMac.matches(lockHolder: "Sam's Mac Pro"), "computer name matches")
        check(samMac.matches(lockHolder: "sam okafor"), "person's name matches")
        check(!samMac.matches(lockHolder: "EDIT-2") && !samMac.matches(lockHolder: ""), "other names don't")

        print("Locked page (everything open, by who has it)")
        let cafeLock = root.appendingPathComponent("Reels/Old/" + "Café.lck".decomposedStringWithCanonicalMapping)
        try Data("EDIT-2".utf8).write(to: lockURL)
        try Data("ASSIST-4".utf8).write(to: cafeLock)
        let openItems = ReadOnlyFS.lockedItems(under: root)!
        check(openItems.map(\.relativePath) == ["Reels/Old/Café.avb", "Reels/Reel 1.avb"],
              "finds every locked bin, in every subfolder, and nothing free: \(openItems.map(\.relativePath))")
        check(openItems.map(\.lockedBy) == ["ASSIST-4", "EDIT-2"], "…with who has each one open")
        check(ReadOnlyFS.lockedItems(under: root.appendingPathComponent("nope")) == nil, "unreachable folder → nil, not “nothing locked”")
        let alexMac = Person(id: UUID(), name: "Alex", computer: "Alex's MacBook Pro", hostName: "Alexs-MacBook-Pro.local")
        let samMac2 = Person(id: UUID(), name: "Sam", computer: "Edit 2", hostName: "EDIT-2.local")
        func item(_ name: String, _ holder: String?) -> ScannedBin {
            ScannedBin(relativePath: "Cuts/\(name).avb", name: name, folder: "Cuts", isLocked: true, lockedBy: holder)
        }
        let groups = LockedBins.group([item("Reel 1", "EDIT-2"), item("Reel 2", "edit-2.local"), item("Music", "ALEXS-MACBOOK-PRO"),
                                       item("VFX", "ASSIST-4"), item("Titles", "assist-4"), item("Old", nil)],
                                      me: alexMac, people: [samMac2])
        check(groups.map(\.owner.name) == ["You", "ASSIST-4", "Sam", "Unknown"],
              "grouped as you, then people and computers A–Z, then unknown: \(groups.map(\.owner.name))")
        check(groups.first { $0.owner.name == "Sam" }?.items.map(\.name) == ["Reel 1", "Reel 2"],
              "both spellings of Sam's Mac count as Sam")
        check(groups.first { $0.owner.name == "ASSIST-4" }.map { $0.owner.kind == .computer && $0.items.count == 2 } == true,
              "a Mac nobody's named is grouped by its computer name")
        check(LockedBins.owner(of: "  ", me: alexMac, people: []) == .unknown, "a blank name counts as unknown")
        check(LockedBins.matches(item("Café Scene", nil), search: "cafe") && LockedBins.matches(item("Reel 1", nil), search: "cuts")
              && !LockedBins.matches(item("Reel 1", nil), search: "music"), "filtering matches names and folders, ignoring accents")
        try Data().write(to: lockURL)
        try Data().write(to: cafeLock)

        print("Search index")
        let index = ReadOnlyFS.index(root.appendingPathComponent("Reels"), prefix: "Reels")!
        check(Set(index.bins.map(\.relativePath)) == ["Reels/Reel 1.avb", "Reels/Reel 2.avb", "Reels/Old/Café.avb"],
              "indexes bins in subfolders: \(index.bins.map(\.relativePath))")
        check(index.bins.first { $0.name == "Café" }?.isLocked == true, "Café locked despite Unicode normalisation difference")

        print("Probing")
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let jobs = [
            ProbeJob(id: a, directory: root.appendingPathComponent("Reels"), binFileName: "Reel 1.avb"),
            ProbeJob(id: b, directory: root.appendingPathComponent("Reels"), binFileName: "Reel 2.avb"),
            ProbeJob(id: c, directory: root.appendingPathComponent("Reels"), binFileName: "Gone.avb"),
            ProbeJob(id: d, directory: root.appendingPathComponent("Unmounted"), binFileName: "X.avb"),
        ]
        let r = ReadOnlyFS.probe(jobs)
        check(r[a] == .locked && r[b] == .available && r[c] == .missing && r[d] == .offline,
              "locked / available / missing / offline: \(r.values.map(\.rawValue))")

        print("Unlock detection")
        var det = UnlockDetector()
        check(det.update(a, with: .available) == (.available, false), "first reading never alerts")
        check(det.update(a, with: .locked) == (.locked, false), "locked")
        check(det.update(a, with: .available) == (.locked, false), "1st free reading: wait to confirm")
        check(det.update(a, with: .locked) == (.locked, false), "flicker back to locked: no alert")
        _ = det.update(a, with: .available)
        check(det.update(a, with: .available) == (.available, true), "2nd consecutive free reading → ALERT")
        check(det.update(a, with: .available) == (.available, false), "no repeat alert while still free")
        _ = det.update(a, with: .locked)
        _ = det.update(a, with: .available)
        check(det.update(a, with: .offline) == (.offline, false), "volume drops: no alert")
        _ = det.update(a, with: .available)
        check(det.update(a, with: .available) == (.available, true), "after reconnect, still-free bin alerts (it was locked)")
        _ = det.update(a, with: .locked)
        _ = det.update(a, with: .missing)
        check(det.update(a, with: .available).unlocked == false, "missing then single free reading: waits")

        print("Live file-system flow")
        var live = UnlockDetector()
        let job = [jobs[0]]
        func tick() -> (BinState, Bool) { let s = ReadOnlyFS.probe(job)[a]!; return live.update(a, with: s) }
        check(tick() == (.locked, false), "watching Reel 1 while locked")
        try fm.removeItem(at: root.appendingPathComponent("Reels/Reel 1.lck"))   // simulate the other editor closing it
        check(tick() == (.locked, false), "lock removed: first check waits")
        check(tick() == (.available, true), "lock removed: second check → ALERT")

        print("Typed / pasted paths")
        let rootPath = "/Volumes/Project"
        func t(_ input: String) -> PathInput.Target? { try? PathInput.resolve(input, rootPath: rootPath).get() }
        check(t("/Volumes/Project") == .init(folder: "", bin: nil), "the monitored folder itself")
        check(t("/Volumes/Project/VILLAGE/04__Sound/") == .init(folder: "VILLAGE/04__Sound", bin: nil), "absolute folder path, trailing slash")
        check(t("/Volumes/Project/VILLAGE/04__Sound/AudioSuite.avb") == .init(folder: "VILLAGE/04__Sound", bin: "VILLAGE/04__Sound/AudioSuite.avb"), "path to a bin selects it")
        check(t("'/Volumes/Project/VILLAGE'") == .init(folder: "VILLAGE", bin: nil), "quoted path")
        check(t("/Volumes/Project/My\\ Folder") == .init(folder: "My Folder", bin: nil), "Terminal-escaped spaces")
        check(t("file:///Volumes/Project/My%20Folder") == .init(folder: "My Folder", bin: nil), "file:// URL")
        check(t("/volumes/project/VILLAGE") == .init(folder: "VILLAGE", bin: nil), "case-insensitive")
        check(t("/Volumes/Project-1/VILLAGE") == .init(folder: "VILLAGE", bin: nil), "remounted volume (Project-1)")
        check(t("Project\\VILLAGE\\04__Sound") == .init(folder: "VILLAGE/04__Sound", bin: nil), "Windows-style relative path")
        check(t("VILLAGE/04__Sound") == .init(folder: "VILLAGE/04__Sound", bin: nil), "relative path")
        check(t("  /Volumes/Project/VILLAGE/Project.avp \n") == .init(folder: "VILLAGE", bin: nil), "an .avp opens its folder")
        check((try? PathInput.resolve("/Volumes/Imports/Foo", rootPath: rootPath).get()) == nil, "outside the monitored folder → refused")
        check((try? PathInput.resolve("/Volumes", rootPath: rootPath).get()) == nil, "parent of the monitored folder → refused")
        check((try? PathInput.resolve("   ", rootPath: rootPath).get()) == nil, "empty → nothing")

        print("New bins — detection")
        let t0 = Date()
        var look = NewBinDiff.compare(known: nil, current: ["P/101 SC01.avb", "P/101 SC02.avb"], now: t0)
        check(look.added.isEmpty, "first look: existing bins aren't “new”")
        look = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/101 SC02.avb", "P/101 SC03.avb"], now: t0 + 5)
        check(look.added == ["P/101 SC03.avb"], "a bin that appears is new")
        look = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/101 SC02.avb", "P/101 SC03.avb"], now: t0 + 10)
        check(look.added.isEmpty, "…and only reported once")
        look = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/101 SC03.avb"], now: t0 + 15)
        look = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/101 SC02.avb", "P/101 SC03.avb"], now: t0 + 20)
        check(look.added.isEmpty, "a bin that briefly vanishes (e.g. while saving) isn't new when it returns")
        look = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/Old/101 SC02.avb", "P/101 SC03.avb"], now: t0 + 25)
        check(look.added.isEmpty, "a bin moved to a subfolder isn't new")
        look = NewBinDiff.compare(known: look.known, current: ["p/101 sc01.AVB", "P/Old/101 SC02.avb", "P/101 SC03.avb"], now: t0 + 30)
        check(look.added.isEmpty, "a change of letter case isn't new")
        look = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/Old/101 SC02.avb", "P/101 SC03.avb", "P/102 SC01.avb", "P/102 SC02.avb"], now: t0 + 35)
        check(look.added == ["P/102 SC01.avb", "P/102 SC02.avb"], "several new bins at once are all reported")
        let gone = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb"], now: t0 + 40)
        let back = NewBinDiff.compare(known: gone.known, current: ["P/101 SC01.avb", "P/102 SC01.avb"], now: t0 + 40 + 7200)
        check(back.added == ["P/102 SC01.avb"], "a bin gone for over an hour counts as new when it comes back")
        let overnight = NewBinDiff.compare(known: look.known, current: ["P/101 SC01.avb", "P/Old/101 SC02.avb", "P/101 SC03.avb", "P/102 SC01.avb", "P/102 SC02.avb", "P/103 SC01.avb"], now: t0 + 14 * 3600)
        check(overnight.added == ["P/103 SC01.avb"], "after Bin Watch was closed overnight, only bins added meanwhile are new")

        print("Mailbox — folder safety")
        let shared = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Workspace")
        let projects = shared.appendingPathComponent("Avid Projects")
        let project = projects.appendingPathComponent("Doc S1")
        try? fm.removeItem(at: shared)
        for dir in [project.appendingPathComponent("Reels"), shared.appendingPathComponent("Mailbox"),
                    projects.appendingPathComponent("Bin Watch Mailbox"), shared.appendingPathComponent("Junk")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: project.appendingPathComponent("Doc S1.avp").path, contents: Data())
        fm.createFile(atPath: shared.appendingPathComponent("Junk/Old.avb").path, contents: Data())
        func refusal(_ url: URL, root: URL? = projects) -> MailboxClient.Refusal? { MailboxClient.validate(url, monitoredRoot: root) }
        check(refusal(projects) == .isMonitoredFolder, "the monitored folder itself is refused")
        check(refusal(shared) == .containsMonitoredFolder, "a folder containing the monitored folder is refused")
        check(refusal(project) == .insideAvidProject("Doc S1"), "an Avid project folder is refused")
        check(refusal(project.appendingPathComponent("Reels")) == .insideAvidProject("Doc S1"), "a folder inside a project is refused")
        check(refusal(project, root: project) == .isMonitoredFolder, "monitoring a single project: the project is refused")
        check(refusal(shared.appendingPathComponent("Junk")) == .containsProjectFiles, "a folder with bins in it is refused")
        check(refusal(shared.appendingPathComponent("Mailbox")) == nil, "a separate empty folder is fine")
        check(refusal(projects.appendingPathComponent("Bin Watch Mailbox")) == nil, "a folder beside the projects is fine")

        print("Mailbox — two people talking")
        let box = shared.appendingPathComponent("Mailbox")
        let alex = Person(id: UUID(), name: "Alex", computer: "Edit 1")
        let sam = Person(id: UUID(), name: "Sam", computer: "Edit 2")
        let alexBox = MailboxClient(folder: box, me: alex), samBox = MailboxClient(folder: box, me: sam)
        try alexBox.setUp(); try samBox.setUp()
        try alexBox.publishPresence(); try samBox.publishPresence()
        check(samBox.people().map(\.person.name) == ["Alex"] && alexBox.people().map(\.person.name) == ["Sam"], "each sees the other (not themselves)")
        var request = BinRequest(id: UUID(), from: alex, to: nil, binName: "Reel 3", binLocation: "Doc S1 › Reels",
                                 binPath: "Doc S1/Reels/Reel 3.avb", message: "Need it for the trailer", created: Date(), status: .open)
        try alexBox.post(request)
        let received = samBox.requests().first
        check(received?.id == request.id && received?.from == alex && received?.message == request.message
              && received?.status == .open && received?.isForEveryone == true, "Sam receives Alex's request")
        try samBox.send(RequestReply(requestID: request.id, from: sam, answer: .seen, at: Date()))
        check(alexBox.replies(to: [request.id]).first?.answer == .seen, "Alex sees “seen”")
        try samBox.send(RequestReply(requestID: request.id, from: sam, answer: .closing, at: Date()))
        check(alexBox.replies(to: [request.id]).map(\.answer) == [.closing], "Sam's answer replaces his earlier one")
        request.status = .resolved
        try alexBox.post(request)
        check(samBox.requests().first?.status == .resolved, "Sam sees it resolved")
        check((try? samBox.post(request)) == nil, "Sam can't write Alex's request")
        check((try? alexBox.send(RequestReply(requestID: request.id, from: sam, answer: .notNow, at: Date()))) == nil, "Alex can't reply as Sam")
        let old = BinRequest(id: UUID(), from: alex, to: sam.id, binName: "Old", binLocation: "", binPath: "x.avb",
                             message: nil, created: Date().addingTimeInterval(-13 * 3600), status: .open)
        try alexBox.post(old)
        check(!samBox.requests().contains { $0.id == old.id }, "expired requests are ignored")
        alexBox.cleanUp(now: Date().addingTimeInterval(2 * 3600))
        check(alexBox.requests(now: Date()).isEmpty, "Alex tidies up his finished and expired requests")
        check(alexBox.replies(to: [request.id]).count == 1, "…but never touches Sam's files")
        let written = Set((fm.enumerator(atPath: box.path)?.allObjects as? [String]) ?? [])
        check(written.allSatisfy { $0 == "About this folder.txt" || ["people", "requests", "replies"].contains($0.components(separatedBy: "/")[0]) },
              "everything written stays in the mailbox's own subfolders")
        try? fm.removeItem(at: shared)

        try? fm.removeItem(at: root)
        print(failures == 0 ? "\nAll tests passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
