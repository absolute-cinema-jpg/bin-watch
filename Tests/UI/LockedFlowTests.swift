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

        // A bin open on this Mac: nothing to wait for, and no one to ask.
        print("Bins you have open yourself")
        try! Data(ProcessInfo.processInfo.hostName.utf8).write(to: project.appendingPathComponent("Music.lck"))
        scanner.refresh()
        pump(1.5)
        if let music = scanner.items.first(where: { $0.name == "Music" }),
           let reel = scanner.items.first(where: { $0.name == "Reel 2" }) {
            check(store.lockedByMe(music) && !store.lockedByMe(reel), "a bin whose lock file names this Mac counts as yours; EDIT-2's doesn't")
            store.toggleWatch(music)
            check(!store.isWatched(music.relativePath), "your own bin can't be watched")
            store.toggleWatch([music, reel])
            check(store.isWatched(reel.relativePath) && !store.isWatched(music.relativePath),
                  "watching a selection skips the ones you have open")
            store.toggleWatch([music, reel])
            check(store.watched.isEmpty, "…and pressing Return again stops watching the rest")
            Navigation.shared.reveal(folder: music.folder, select: music.relativePath)
            pump(1.5)
            if let path = ProcessInfo.processInfo.environment["SNAP_DIR"] { snapshot(path + "/own-lock.png") }
            Navigation.shared.reveal(folder: reel.folder, select: reel.relativePath)
            pump(1.5)
            if let path = ProcessInfo.processInfo.environment["SNAP_DIR"] { snapshot(path + "/own-lock-folder.png") }
        } else {
            check(false, "Music and Reel 2 show as locked: \(scanner.items.map(\.name))")
        }

        try! Data().write(to: project.appendingPathComponent("3 Cuts/Reel 2.lck"))
        try! fm.removeItem(at: project.appendingPathComponent("Music.lck"))
    }
}
