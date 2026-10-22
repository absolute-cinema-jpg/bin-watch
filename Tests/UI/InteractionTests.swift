import AppKit

enum InteractionTests {
    static func run(_ bm: BrowserModel, _ store: AppStore) {
        let base = "Documentary S1/3 Cuts/"
        let r = (1...4).map { base + "Reel \($0).avb" }
        let rowY: [CGFloat] = [112, 150, 188, 232]
        let x: CGFloat = 350

        print("List view — mouse")
        click(x, rowY[0]);            check(bm.selection == [r[0]], "click selects one bin")
        click(x, rowY[2], .command);  check(bm.selection == [r[0], r[2]], "⌘-click adds a bin")
        click(x, rowY[0], .command);  check(bm.selection == [r[2]], "⌘-click again removes it")
        click(x, rowY[1]);            check(bm.selection == [r[1]], "plain click replaces the selection")
        click(x, rowY[3], .shift);    check(bm.selection == Set(r[1...3]), "⇧-click selects a range")
        click(700, 450);              check(bm.selection.isEmpty, "clicking empty space deselects")

        print("List view — keyboard")
        key(125);                     check(bm.selection == [r[0]], "↓ selects the first bin")
        key(125, .shift);             check(bm.selection == Set(r[0...1]), "⇧↓ extends the selection")
        key(125, .shift);             check(bm.selection == Set(r[0...2]), "⇧↓ again")
        key(126, .shift);             check(bm.selection == Set(r[0...1]), "⇧↑ shrinks it back")
        key(36);                      check(r[0...1].allSatisfy(store.isWatched), "Return watches the selection")
        key(36);                      check(store.watched.isEmpty, "Return again stops watching")
        key(0, .command);             check(bm.selection == Set(r), "⌘A selects all bins")
        key(53);                      check(bm.selection.isEmpty, "Esc clears")
        click(885, rowY[0]);          check(store.isWatched(r[0]) && bm.selection.isEmpty, "Watch button still works and doesn't select")
        click(885, rowY[0]);          check(!store.isWatched(r[0]), "…and toggles off")

        click(x, 90); pump(0.5);      check(bm.path.last == "Old", "clicking a folder opens it")
        bm.go(to: ["Documentary S1", "3 Cuts"]); pump(0.6)

        print("Opening bins (double-click, ⌘O)")
        var opened: [String] = []
        BinOpener.testHook = { opened = $0.map(\.lastPathComponent) }
        click(x, rowY[1]);                 check(opened.isEmpty, "a single click only selects")
        doubleClick(x, rowY[1]);           check(opened == ["Reel 2.avb"] && bm.selection == [r[1]], "double-clicking a bin opens it")
        opened = []
        doubleClick(x, rowY[2], .command); check(opened.isEmpty, "⌘-double-click doesn't open")
        bm.clearSelection(); opened = []
        doubleClick(x, 90); pump(0.5)
        check(bm.path.last == "Old" && opened.isEmpty, "double-clicking a folder opens the folder, never a bin in it")
        bm.go(to: ["Documentary S1", "3 Cuts"]); pump(0.6)
        click(x, rowY[0]); key(31, .command)
        check(opened == ["Reel 1.avb"], "⌘O opens the selected bin")
        opened = []
        click(x, rowY[3], .command); key(125, .command)
        check(Set(opened) == ["Reel 1.avb", "Reel 4.avb"], "⌘↓ opens a multiple selection (shown in Finder)")
        opened = []; key(53); key(31, .command)
        check(opened.isEmpty, "⌘O with nothing selected does nothing")
        BinOpener.testHook = { _ in }

        print("Icon view — mouse")
        store.settings.browseMode = .icons; pump(0.8)
        let tileX: [CGFloat] = [457, 595, 733, 871]
        click(tileX[0], 104);              check(bm.selection == [r[0]], "click a tile selects it")
        click(tileX[2], 104, .command);    check(bm.selection == [r[0], r[2]], "⌘-click adds a tile")
        click(tileX[3], 104, .shift);      check(bm.selection == Set(r[2...3]), "⇧-click selects a range")
        click(600, 450);                   check(bm.selection.isEmpty, "clicking empty space deselects")
        var tileOpened: [String] = []
        BinOpener.testHook = { tileOpened = $0.map(\.lastPathComponent) }
        doubleClick(tileX[1], 104);        check(tileOpened == ["Reel 2.avb"], "double-clicking a tile opens it")
        BinOpener.testHook = { _ in }
        key(53)

        print("Icon view — keyboard")
        key(124);                     check(bm.selection == [r[0]], "→ selects the first bin")
        key(124);                     check(bm.selection == [r[1]], "→ moves to the next")
        key(123, .shift);             check(bm.selection == Set(r[0...1]), "⇧← extends backwards")
        key(53)

        print("Column view — keyboard")
        store.settings.browseMode = .columns
        bm.go(to: ["Documentary S1"]); pump(1)
        key(124); pump(0.4);          check(bm.path == ["Documentary S1", "1 Dailies"], "→ steps into the folder (first item)")
        key(125); pump(0.4);          check(bm.path == ["Documentary S1", "2 Selects"], "↓ moves to the next folder")
        key(125); pump(0.4);          check(bm.path == ["Documentary S1", "3 Cuts"], "↓ again")
        key(125); pump(0.4);          check(bm.path == ["Documentary S1"] && bm.selection == ["Documentary S1/Music.avb"], "↓ onto a bin selects it")
        key(126); pump(0.4);          check(bm.path == ["Documentary S1", "3 Cuts"] && bm.selection.isEmpty, "↑ back onto the folder")
        key(124); pump(0.4);          check(bm.path == ["Documentary S1", "3 Cuts", "Old"], "→ into 3 Cuts lands on its first item (Old)")
        key(123); pump(0.4);          check(bm.path == ["Documentary S1", "3 Cuts"], "← steps back out")
        key(124); pump(0.4); key(125); pump(0.4)
        check(bm.path == ["Documentary S1", "3 Cuts"] && bm.selection == [r[0]], "→ then ↓ selects Reel 1 in the last column")
        key(125, .shift); pump(0.3);  check(bm.selection == Set(r[0...1]), "⇧↓ extends in column view")
        key(123); pump(0.3);          check(bm.selection.isEmpty && bm.path == ["Documentary S1", "3 Cuts"], "← from bins returns to their folder")
        key(123); pump(0.3);          check(bm.path == ["Documentary S1"], "← again goes up a level")
        key(123); pump(0.3);          check(bm.path == ["Documentary S1"], "← in the first column stays put")

        print("Column view — mouse")
        window.setContentSize(NSSize(width: 1500, height: 600))   // room for the preview column, so nothing scrolls
        bm.go(to: ["Documentary S1", "3 Cuts"]); pump(1)
        click(800, 96);                    check(bm.selection == [r[0]], "click a bin in the last column selects it")
        click(800, 146, .command);         check(bm.selection == [r[0], r[2]], "⌘-click adds")
        click(800, 171, .shift);           check(bm.selection == Set(r[2...3]), "⇧-click selects a range")
        click(800, 450);                   check(bm.selection.isEmpty && bm.path == ["Documentary S1", "3 Cuts"], "clicking empty space in the column deselects")
        click(580, 450); pump(0.3);        check(bm.path == ["Documentary S1"], "clicking empty space in an earlier column closes the columns after it")
        click(580, 121); pump(0.5);        check(bm.path == ["Documentary S1", "3 Cuts"], "clicking a folder in a column opens it")
        var columnOpened: [String] = []
        BinOpener.testHook = { columnOpened = $0.map(\.lastPathComponent) }
        doubleClick(800, 96);              check(columnOpened == ["Reel 1.avb"], "double-clicking a bin in a column opens it")
        columnOpened = []
        click(580, 400); pump(0.3)         // back to Documentary S1's column
        doubleClick(580, 121); pump(0.5)   // double-click the "3 Cuts" folder
        check(columnOpened.isEmpty && bm.path == ["Documentary S1", "3 Cuts"],
              "double-clicking a folder in a column opens it and leaves it open")
        BinOpener.testHook = { _ in }
    }
}
