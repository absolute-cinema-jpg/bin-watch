import AppKit

/// End to end: "Show Bin" on available alerts, and alerts for new bins in a folder.
enum NewBinsFlowTests {
    static func run(_ store: AppStore, dir: String) {
        let alerts = AlertCenter.shared.model
        let watcher = NewBinWatcher.shared
        let fm = FileManager.default
        let cuts = URL(fileURLWithPath: dir).appendingPathComponent("Avid Projects/Documentary S1/3 Cuts")
        var shown: [URL] = []
        BinOpener.testHook = { shown = $0 }
        for w in watcher.watches { watcher.remove(w) }
        watcher.clearEvents()
        for item in alerts.items { AlertCenter.shared.respond(item.id, .dismissed) }

        print("Bin available — Show Bin / Dismiss")
        let lock = cuts.appendingPathComponent("Reel 2.lck")
        let reel2 = "Documentary S1/3 Cuts/Reel 2.avb"
        if !fm.fileExists(atPath: lock.path) { fm.createFile(atPath: lock.path, contents: Data()) }
        store.ensureWatched(relativePath: reel2)
        pump(3)
        try? fm.removeItem(at: lock)
        pump(7)
        let available = alerts.items.first { $0.kind == .available && $0.title == "Reel 2" }
        check(available != nil, "“bin available” alert appears")
        if let available { AlertCenter.shared.respond(available.id, .primary) }
        pump(0.5)
        check(shown.map { $0.resolvingSymlinksInPath().path } == [cuts.appendingPathComponent("Reel 2.avb").resolvingSymlinksInPath().path],
              "Show Bin opens the right bin file: \(shown.map(\.path))")
        check(!store.isWatched(reel2) && !alerts.items.contains { $0.id == available?.id }, "…and the alert goes, and the bin is no longer watched")
        fm.createFile(atPath: lock.path, contents: Data())
        store.ensureWatched(relativePath: reel2); pump(3)
        try? fm.removeItem(at: lock); pump(7)
        shown = []
        if let again = alerts.items.first(where: { $0.kind == .available }) { AlertCenter.shared.respond(again.id, .secondary) }
        pump(0.5)
        check(shown.isEmpty && !store.isWatched(reel2), "Dismiss closes it without opening anything")
        fm.createFile(atPath: lock.path, contents: Data())

        print("New bins")
        watcher.add(folder: "Documentary S1/3 Cuts")
        pump(1); watcher.scan(force: true); pump(1)
        check(watcher.reachable[watcher.watches[0].id] == true && alerts.items.isEmpty, "watching 3 Cuts: existing bins don't alert")
        fm.createFile(atPath: cuts.appendingPathComponent("Reel 5.avb").path, contents: Data())
        watcher.scan(force: true); pump(1)
        let one = alerts.items.first { if case .newBins = $0.kind { return true } else { return false } }
        check(one?.title == "Reel 5" && one?.kind == .newBins(count: 1), "a new bin alerts: \(one?.title ?? "none")")
        check(watcher.events.first?.name == "Reel 5", "…and is listed on the New Bins page")
        if let one { AlertCenter.shared.respond(one.id, .primary) }
        pump(0.3)
        check(shown.map(\.lastPathComponent) == ["Reel 5.avb"], "Show Bin opens the new bin")

        for name in ["Reel 6.avb", "Reel 7.avb", "Notes.txt"] {
            fm.createFile(atPath: cuts.appendingPathComponent(name).path, contents: Data())
        }
        watcher.scan(force: true); pump(1)
        let group = alerts.items.first { if case .newBins = $0.kind { return true } else { return false } }
        check(group?.kind == .newBins(count: 2) && group?.title == "2 new bins in 3 Cuts" && group?.detail == "Reel 6, Reel 7",
              "several new bins arrive as one alert (non-bin files ignored): \(group?.detail ?? "")")
        if let group { AlertCenter.shared.respond(group.id, .primary) }
        pump(0.3)
        check(shown.count == 2, "Show Bins reveals both")

        try! fm.moveItem(at: cuts.appendingPathComponent("Reel 7.avb"), to: cuts.appendingPathComponent("Old/Reel 7.avb"))
        watcher.setIncludeSubfolders(true, for: watcher.watches[0])
        pump(1); watcher.scan(force: true); pump(1)
        check(!alerts.items.contains { if case .newBins = $0.kind { return true } else { return false } },
              "turning on subfolders doesn't announce the bins already in them")
        fm.createFile(atPath: cuts.appendingPathComponent("Old/Reel 8.avb").path, contents: Data())
        watcher.scan(force: true); pump(1)
        check(alerts.items.contains { $0.title == "Reel 8" }, "with subfolders on, a bin added in a subfolder alerts")
        for item in alerts.items { AlertCenter.shared.respond(item.id, .dismissed) }

        print("Scripts")
        let scriptLock = cuts.appendingPathComponent("Opening.lck")
        fm.createFile(atPath: cuts.appendingPathComponent("Opening.avc").path, contents: Data())
        watcher.scan(force: true); pump(1)
        let newScript = alerts.items.first { $0.title == "Opening" }
        check(newScript?.noun == "script", "a new script is announced as a script")
        for item in alerts.items { AlertCenter.shared.respond(item.id, .dismissed) }
        fm.createFile(atPath: scriptLock.path, contents: Data())
        store.ensureWatched(relativePath: "Documentary S1/3 Cuts/Opening.avc")
        pump(3)
        try? fm.removeItem(at: scriptLock)
        pump(7)
        let freeScript = alerts.items.first { $0.kind == .available && $0.title == "Opening" }
        check(freeScript?.noun == "script", "a watched script's alert says it's a script")
        if let freeScript { AlertCenter.shared.respond(freeScript.id, .primary) }
        pump(0.3)
        check(shown.map(\.lastPathComponent) == ["Opening.avc"], "Show Script opens the script")

        print("Overlapping folders")
        watcher.add(folder: "Documentary S1/3 Cuts/Old")
        pump(1); watcher.scan(force: true); pump(1)
        check(watcher.coverage(of: "Documentary S1/3 Cuts/Old") == .direct, "a watched folder is marked as watched")
        check(watcher.coverage(of: "Documentary S1/3 Cuts/Old/Deeper") == .viaParent("Documentary S1/3 Cuts"),
              "a folder below one watched with subfolders is marked as covered by it")
        check(watcher.coverage(of: "Documentary S1/1 Dailies") == .none, "an unrelated folder isn't marked")
        fm.createFile(atPath: cuts.appendingPathComponent("Old/Reel 9.avb").path, contents: Data())
        watcher.scan(force: true); pump(1)
        let nine = alerts.items.filter { $0.title == "Reel 9" }
        check(nine.count == 1, "a bin in two watched folders is announced once (got \(nine.count))")
        for item in alerts.items { AlertCenter.shared.respond(item.id, .dismissed) }
        try? fm.removeItem(at: cuts.appendingPathComponent("Old/Reel 9.avb"))
        try? fm.removeItem(at: cuts.appendingPathComponent("Opening.avc"))
        if let extra = watcher.watch(for: "Documentary S1/3 Cuts/Old") { watcher.remove(extra) }

        let saved = watcher.watches
        watcher.remove(saved[0])
        check(watcher.watches.isEmpty, "removing the folder stops it")
        for name in ["Reel 5.avb", "Reel 6.avb", "Notes.txt", "Old/Reel 7.avb", "Old/Reel 8.avb"] {
            try? fm.removeItem(at: cuts.appendingPathComponent(name))
        }
        BinOpener.testHook = nil
    }
}
