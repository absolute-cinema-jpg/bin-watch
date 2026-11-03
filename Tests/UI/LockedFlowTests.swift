import AppKit

/// The Locked page: finds everything open across the monitored folder, grouped by who has it.
enum LockedFlowTests {
    static func run(_ store: AppStore, dir: String) {
        let fm = FileManager.default
        let project = URL(fileURLWithPath: dir).appendingPathComponent("Avid Projects/Documentary S1")
        let locks = ["3 Cuts/Reel 2.lck": "EDIT-2", "Music.lck": "EDIT-2", "3 Cuts/Old/Reel 1 v1.lck": "ASSIST-4"]
        for (path, holder) in locks { try! Data(holder.utf8).write(to: project.appendingPathComponent(path)) }
        let scanner = LockedScanner.shared
        for bin in store.watched { store.unwatch(bin) }

        print("Locked page")
        Navigation.shared.selection = .locked
        pump(3)
        check(scanner.items.map(\.name) == ["Reel 1 v1", "Reel 2", "Music"],
              "lists every locked bin in the monitored folder: \(scanner.items.map(\.name))")
        let groups = LockedBins.group(scanner.items, me: RequestCenter.shared.me, people: RequestCenter.shared.people.map(\.person))
        check(groups.map(\.owner.name) == ["ASSIST-4", "EDIT-2"] && groups.last?.items.count == 2,
              "grouped by who has them open: \(groups.map { "\($0.owner.name) (\($0.items.count))" })")
        if let path = ProcessInfo.processInfo.environment["SNAP_DIR"] { snapshot(path + "/locked-everyone.png") }

        // Click the "EDIT-2" chip, then double-click the top row: with the filter on, that's Reel 2.
        var opened: [URL] = []
        BinOpener.testHook = { opened += $0 }
        click(562, 103)
        if let path = ProcessInfo.processInfo.environment["SNAP_DIR"] { snapshot(path + "/locked-edit2.png") }
        doubleClick(300, 188)
        check(opened.map(\.lastPathComponent) == ["Reel 2.avb"],
              "filtering to EDIT-2 shows only their bins, and double-click opens one: \(opened.map(\.lastPathComponent))")
        BinOpener.testHook = { _ in }

        // Watch All on EDIT-2's group.
        store.toggleWatch(groups.last!.items)
        pump(0.5)
        check(store.isWatched("Documentary S1/3 Cuts/Reel 2.avb") && store.isWatched("Documentary S1/Music.avb")
              && !store.isWatched("Documentary S1/3 Cuts/Old/Reel 1 v1.avb"), "“Watch All” watches just that person's bins")

        // Someone closes a bin: it drops off the list on the next look.
        try! fm.removeItem(at: project.appendingPathComponent("3 Cuts/Old/Reel 1 v1.lck"))
        scanner.refresh()
        pump(1.5)
        check(scanner.items.map(\.name) == ["Reel 2", "Music"], "a bin that's been closed disappears from the list")

        Navigation.shared.selection = .browse
        pump(0.5)
        for bin in store.watched { store.unwatch(bin) }
        try! Data().write(to: project.appendingPathComponent("3 Cuts/Reel 2.lck"))
        try! fm.removeItem(at: project.appendingPathComponent("Music.lck"))
    }
}
