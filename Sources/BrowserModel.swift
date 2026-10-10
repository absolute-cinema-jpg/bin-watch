import AppKit

/// Where the folder browser is, what's selected, and Finder-style back/forward history.
final class BrowserModel: ObservableObject {
    static let shared = BrowserModel()

    @Published private(set) var path: [String] = []
    @Published private(set) var backStack: [[String]] = []
    @Published private(set) var forwardStack: [[String]] = []

    var relativePath: String { path.joined(separator: "/") }

    /// Search results are showing (they're always a list, whatever the view mode).
    var isSearching = false

    // Session caches so revisiting a folder is instant and projects are only detected once.
    var listingCache: [String: FolderListing] = [:]
    var projectFolders: Set<String> = []
    var checkedForProject: Set<String> = []

    // MARK: Selection (bins only — folders open with a single click)

    /// Selected bins, by relative path.
    @Published private(set) var selection: Set<String> = []
    /// Something to scroll into view (a bin or, in column view, a folder).
    @Published private(set) var scrollTarget: String?
    /// Where ⇧-click and ⇧-arrow ranges start from.
    private var anchor: String?
    /// The moving end of the selection (what ↑/↓ move from).
    private var cursor: String?
    /// The bins on screen, in display order. Kept up to date by the views.
    var visibleBins: [ScannedBin] = []

    var selectedBins: [ScannedBin] { visibleBins.filter { selection.contains($0.relativePath) } }

    /// Finder-style clicking: plain click selects one, ⌘ adds/removes, ⇧ selects a range.
    func click(_ relativePath: String) {
        NSApp.keyWindow?.makeFirstResponder(nil)   // so Return goes to the selection, not a text field
        // The modifiers of the click being handled (falls back to the keyboard's current state).
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selection.contains(relativePath) { selection.remove(relativePath) } else { selection.insert(relativePath) }
            anchor = relativePath
            cursor = relativePath
        } else if modifiers.contains(.shift), let anchor, index(of: anchor) != nil {
            selectRange(from: anchor, to: relativePath)
            cursor = relativePath
        } else {
            selectOnly(relativePath)
        }
    }

    func selectAll() {
        selection = Set(visibleBins.map(\.relativePath))
    }

    func clearSelection() {
        selection = []
        anchor = nil
        cursor = nil
    }

    /// Clicking empty space: deselect everything.
    func clickedEmptySpace() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        clearSelection()
    }

    /// ↑/↓ through the bins on screen. With ⇧, the selection grows or shrinks from the anchor.
    func moveSelection(by delta: Int, extend: Bool = false) {
        guard !visibleBins.isEmpty else { return }
        let current = (cursor ?? anchor).flatMap(index(of:))
        let next = current.map { min(max($0 + delta, 0), visibleBins.count - 1) }
            ?? (delta > 0 ? 0 : visibleBins.count - 1)
        let target = visibleBins[next].relativePath
        if extend, let anchor, current != nil {
            selectRange(from: anchor, to: target)
            cursor = target
        } else {
            selectOnly(target)
        }
        scrollTarget = target
    }

    private func selectOnly(_ relativePath: String) {
        selection = [relativePath]
        anchor = relativePath
        cursor = relativePath
    }

    private func selectRange(from a: String, to b: String) {
        guard let i = index(of: a), let j = index(of: b) else { return }
        selection = Set(visibleBins[min(i, j)...max(i, j)].map(\.relativePath))
    }

    private func index(of relativePath: String) -> Int? {
        visibleBins.firstIndex { $0.relativePath == relativePath }
    }

    // MARK: Navigation

    /// Go to a folder, optionally selecting one bin in it.
    func go(to newPath: [String], select bin: String? = nil) {
        if let bin { selectOnly(bin) } else { clearSelection() }
        scrollTarget = bin
        guard newPath != path else { return }
        backStack.append(path)
        forwardStack.removeAll()
        path = newPath
    }

    func go(toRelative relative: String, select bin: String? = nil) {
        go(to: relative.split(separator: "/").map(String.init), select: bin)
    }

    func open(_ folder: String) { go(to: path + [folder]) }
    func up() { if !path.isEmpty { go(to: Array(path.dropLast())) } }

    func back() {
        guard let previous = backStack.popLast() else { return }
        clearSelection()
        forwardStack.append(path)
        path = previous
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        clearSelection()
        backStack.append(path)
        path = next
    }

    func reset() {
        path = []; backStack = []; forwardStack = []
        clearSelection()
        listingCache = [:]; projectFolders = []; checkedForProject = []
    }

    // MARK: Column view keyboard (Finder behaviour)
    //
    // The focused item is either the selected bin(s) in the last column, or — when no bin
    // is selected — the deepest open folder (shown highlighted in its column).

    private enum ColumnItem: Equatable {
        case folder(String)      // name
        case bin(String)         // relative path
    }

    private func columnItems(_ level: Int) -> [ColumnItem]? {
        guard let listing = listingCache[path.prefix(level).joined(separator: "/")] else { return nil }
        return listing.folders.map { .folder($0.name) } + listing.bins.map { .bin($0.relativePath) }
    }

    /// Change folder without adding to back/forward history (arrow keys move a lot).
    private func setPathQuietly(_ newPath: [String]) {
        if newPath != path { path = newPath }
    }

    private func focus(_ item: ColumnItem, at level: Int) {
        switch item {
        case .folder(let name):
            clearSelection()
            setPathQuietly(Array(path.prefix(level)) + [name])
            scrollTarget = path.joined(separator: "/")
        case .bin(let relativePath):
            setPathQuietly(Array(path.prefix(level)))
            selectOnly(relativePath)
            scrollTarget = relativePath
        }
    }

    /// ↑/↓ in column view: move within the focused column, opening folders as you land on them.
    func columnMove(by delta: Int, extend: Bool) {
        if !selection.isEmpty {
            // In the last column, among bins (⇧ extends), stepping up onto folders above them.
            if extend { moveSelection(by: delta, extend: true); return }
            guard let items = columnItems(path.count),
                  let cursor = cursor ?? anchor,
                  let i = items.firstIndex(of: .bin(cursor)) else { moveSelection(by: delta); return }
            focus(items[min(max(i + delta, 0), items.count - 1)], at: path.count)
        } else if let last = path.last {
            let level = path.count - 1
            guard let items = columnItems(level), let i = items.firstIndex(of: .folder(last)) else { return }
            focus(items[min(max(i + delta, 0), items.count - 1)], at: level)
        } else if let items = columnItems(0), let first = delta > 0 ? items.first : items.last {
            focus(first, at: 0)
        }
    }

    /// → in column view: step into the focused folder, selecting its first item.
    func columnRight() {
        guard selection.isEmpty else { return }          // a bin is focused: nothing to open
        guard let items = columnItems(path.count), let first = items.first else { return }
        focus(first, at: path.count)
    }

    /// ← in column view: step back out to the parent folder.
    func columnLeft() {
        if !selection.isEmpty {
            if !path.isEmpty { clearSelection(); scrollTarget = relativePath }
        } else if path.count >= 2 {
            setPathQuietly(Array(path.dropLast()))
            scrollTarget = relativePath
        }
    }
}
