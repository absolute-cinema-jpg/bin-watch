import SwiftUI

/// A Finder-style browser with icon, list and column views, back/forward, a clickable
/// path bar you can also type or paste a path into, and search.
struct BrowseView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var browser = BrowserModel.shared

    @State private var query = ""
    @State private var searchIndex: (folder: String, built: Date, items: FolderListing)?
    @State private var searching = false

    @State private var editingPath = false
    @State private var pathText = ""
    @State private var pathError: String?
    @FocusState private var pathFieldFocused: Bool

    var body: some View {
        if store.rootPath == nil {
            EmptyState(symbol: "folder.badge.questionmark",
                       title: "Choose a folder to monitor",
                       message: "Pick an Avid project folder, or a folder that holds all your projects. You can change it at any time.",
                       actionTitle: "Choose Folder…",
                       action: { store.chooseRootViaPanel() })
        } else {
            VStack(spacing: 0) {
                navigationBar
                if let pathError { errorBanner(pathError) }
                Divider()
                FolderLoader(relative: browser.relativePath) { listing, unreachable in
                    VStack(spacing: 0) {
                        content(listing, unreachable)
                        Divider()
                        statusBar(listing)
                    }
                }
            }
            .background(shortcuts)
            .task(id: "\(query)|\(browser.relativePath)") { await search() }
            .onAppear { BrowseKeys.install(); browser.isSearching = !query.isEmpty }
            .onChange(of: query) { browser.isSearching = !$0.isEmpty }
            .onDisappear { BrowseKeys.remove() }
        }
    }

    // MARK: Navigation bar

    private var navigationBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                navButton("chevron.left", enabled: !browser.backStack.isEmpty, help: "Back (⌘[)") { browser.back() }
                navButton("chevron.right", enabled: !browser.forwardStack.isEmpty, help: "Forward (⌘])") { browser.forward() }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            if editingPath { pathEditor } else { pathBar }

            NewBinsToggleButton(folder: browser.relativePath)

            Picker("View", selection: $store.settings.browseMode) {
                ForEach(BrowseMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.symbol).help("View \(mode.title)").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)

            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Keyboard shortcuts, like Finder's.
    private var shortcuts: some View {
        ZStack {
            Button("") { browser.back() }.keyboardShortcut("[", modifiers: .command)
            Button("") { browser.forward() }.keyboardShortcut("]", modifiers: .command)
            Button("") { browser.up() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { beginEditingPath() }.keyboardShortcut("l", modifiers: .command)
            Button("") { beginEditingPath() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("") { store.settings.browseMode = .icons }.keyboardShortcut("1", modifiers: .command)
            Button("") { store.settings.browseMode = .list }.keyboardShortcut("2", modifiers: .command)
            Button("") { store.settings.browseMode = .columns }.keyboardShortcut("3", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .help(help)
    }

    /// Finder-style path bar. Click a folder to jump there; click the empty space
    /// (or press ⌘L) to type or paste a path instead.
    private var pathBar: some View {
        HStack(spacing: 2) {
            crumb(store.rootName, symbol: "folder.fill", path: [], isLast: browser.path.isEmpty)
                .layoutPriority(browser.path.isEmpty ? 2 : 0.5)
            ForEach(Array(browser.path.enumerated()), id: \.offset) { i, _ in
                let isLast = i == browser.path.count - 1
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                crumb(browser.path[i], symbol: nil, path: Array(browser.path.prefix(i + 1)), isLast: isLast)
                    .layoutPriority(isLast ? 2 : 0)
            }
            Spacer(minLength: 6)
                .contentShape(Rectangle())
                .onTapGesture { beginEditingPath() }
            Button { beginEditingPath() } label: {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Type or paste a path (⌘L)")
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private var pathEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            TextField("Type or paste a folder, bin or script path", text: $pathText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($pathFieldFocused)
                .onSubmit { submitPath() }
                .onExitCommand { cancelEditingPath() }
                .onChange(of: pathText) { _ in pathError = nil }
            Text("⏎ to go · esc to cancel")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
        .onChange(of: pathFieldFocused) { focused in
            if !focused && pathError == nil { editingPath = false }
        }
    }

    private func crumb(_ title: String, symbol: String?, path: [String], isLast: Bool) -> some View {
        Button {
            browser.go(to: path)
        } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.blue) }
                // A minimum width so a squeezed folder shows as "D…" rather than vanishing.
                Text(title).lineLimit(1).truncationMode(.tail).frame(minWidth: 26)
            }
            .font(.system(size: 13, weight: isLast ? .semibold : .regular))
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightStyle())
        .help(title)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            Button { pathError = nil; cancelEditingPath() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
            if searching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(width: 150)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .help("Search “\(browser.path.last ?? store.rootName)” and the folders inside it")
    }

    // MARK: Path editing

    private func beginEditingPath() {
        guard let rootPath = store.rootPath else { return }
        pathText = browser.relativePath.isEmpty ? rootPath : rootPath + "/" + browser.relativePath
        pathError = nil
        editingPath = true
        DispatchQueue.main.async { pathFieldFocused = true }
    }

    private func cancelEditingPath() {
        editingPath = false
        pathError = nil
    }

    private func submitPath() {
        guard let rootPath = store.rootPath, let root = store.root else { return }
        switch PathInput.resolve(pathText, rootPath: rootPath) {
        case .failure(.empty):
            cancelEditingPath()
        case .failure(.outsideRoot):
            pathError = "That path isn't inside “\(store.rootName)”, the folder Bin Watch is monitoring. You can change the monitored folder in the sidebar."
        case .success(let target):
            Task { @MainActor in
                let url = target.folder.isEmpty ? root : root.appendingPathComponent(target.folder)
                let folder = target.folder
                let listing = await Task.detached(priority: .userInitiated) {
                    ReadOnlyFS.listFolder(url, relative: folder, detectProjects: false)
                }.value
                guard let listing else {
                    pathError = "Couldn't find “\(displayPath(target.folder, root: store.rootName))” in \(store.rootName)."
                    return
                }
                var selected: String?
                if let bin = target.bin {
                    guard let match = listing.bins.first(where: { ReadOnlyFS.key($0.relativePath) == ReadOnlyFS.key(bin) }) else {
                        pathError = "Couldn't find the \(AvidItem.noun(bin)) “\(((bin as NSString).lastPathComponent as NSString).deletingPathExtension)” in that folder."
                        return
                    }
                    selected = match.relativePath
                }
                browser.listingCache[target.folder] = listing
                browser.go(toRelative: target.folder, select: selected)
                pathError = nil
                editingPath = false
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ listing: FolderListing?, _ unreachable: Bool) -> some View {
        if unreachable {
            EmptyState(symbol: "externaldrive.badge.xmark",
                       title: "Can't open this folder",
                       message: "Make sure the workspace is mounted. Bin Watch will keep trying.",
                       actionTitle: browser.path.isEmpty ? nil : "Go to Top",
                       action: { browser.go(to: []) })
        } else if let results = searchResults {
            SearchResultsView(results: results, base: browser.relativePath, query: query)
        } else if store.settings.browseMode == .columns {
            ColumnBrowser(currentListing: listing)
        } else if let listing {
            if listing.folders.isEmpty && listing.bins.isEmpty {
                EmptyState(symbol: "folder", title: "This folder is empty",
                           message: "There are no folders, bins or scripts in here.", actionTitle: nil, action: {})
            } else if store.settings.browseMode == .icons {
                IconGridView(listing: listing)
            } else {
                ListModeView(listing: listing)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusBar(_ listing: FolderListing?) -> some View {
        HStack {
            Text(statusText(listing))
            Spacer()
            if store.rootOnline == false {
                Label("Folder offline", systemImage: "externaldrive.badge.xmark")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func statusText(_ listing: FolderListing?) -> String {
        let selected = browser.selectedBins
        if !selected.isEmpty {
            let allWatched = selected.allSatisfy { store.isWatched($0.relativePath) }
            let what = selected.count == 1 ? "“\(selected[0].name)” selected" : "\(AvidItem.count(selected.map(\.relativePath))) selected"
            let open = selected.count == 1
                ? "double-click or ⌘O to \(BinOpener.runningAvid != nil ? "open in Avid" : "show in Finder")"
                : "⌘O to show them in Finder"
            return "\(what) — Return to \(allWatched ? "stop watching" : "watch") · \(open)"
        }
        if let results = searchResults {
            let n = results.folders.count + results.bins.count
            return "\(n) result\(n == 1 ? "" : "s")"
        }
        guard let listing else { return "" }
        let f = listing.folders.count, b = listing.bins.count
        let locked = listing.bins.filter(\.isLocked).count
        var parts: [String] = []
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        let scripts = listing.bins.filter(\.isScript).count, bins = b - scripts
        if bins > 0 { parts.append("\(bins) bin\(bins == 1 ? "" : "s")") }
        if scripts > 0 { parts.append("\(scripts) script\(scripts == 1 ? "" : "s")") }
        if locked > 0 { parts.append("\(locked) locked") }
        return parts.isEmpty ? "Empty folder" : parts.joined(separator: " · ")
    }

    private var searchResults: FolderListing? {
        guard !query.isEmpty, let index = searchIndex?.items else { return nil }
        let q = query
        return FolderListing(
            folders: index.folders.filter { $0.name.localizedCaseInsensitiveContains(q) },
            bins: index.bins.filter { $0.name.localizedCaseInsensitiveContains(q) })
    }

    /// Builds an index of everything below the current folder once, then filters it as you type.
    @MainActor
    private func search() async {
        guard !query.isEmpty, let root = store.root else { return }
        let relative = browser.relativePath
        if let index = searchIndex, index.folder == relative, Date().timeIntervalSince(index.built) < 30 { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        searching = true
        let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
        let items = await Task.detached(priority: .userInitiated) {
            ReadOnlyFS.index(url, prefix: relative)
        }.value
        searching = false
        if Task.isCancelled { return }
        searchIndex = (relative, Date(), items ?? FolderListing())
    }
}

// MARK: - Loading

/// Lists a folder (instantly from cache if visited before), marks Avid projects in the
/// background, and refreshes every few seconds so lock states stay live.
struct FolderLoader<Content: View>: View {
    let relative: String
    @ViewBuilder var content: (FolderListing?, Bool) -> Content

    @EnvironmentObject private var store: AppStore
    @State private var listing: FolderListing?
    @State private var unreachable = false

    var body: some View {
        content(listing, unreachable)
            .task(id: "\(store.rootPath ?? "")|\(relative)") { await run() }
    }

    @MainActor
    private func run() async {
        let browser = BrowserModel.shared
        listing = browser.listingCache[relative].map(withProjects)
        unreachable = false
        var detected = false
        while !Task.isCancelled {
            guard let root = store.root else {
                unreachable = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            let relative = self.relative
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let result = await Task.detached(priority: .userInitiated) {
                ReadOnlyFS.listFolder(url, relative: relative, detectProjects: false)
            }.value
            if Task.isCancelled { return }
            if let result {
                browser.listingCache[relative] = result
                listing = withProjects(result)
                unreachable = false
                if !detected {
                    detected = true
                    let unchecked = result.folders.filter { !browser.checkedForProject.contains($0.relativePath) }
                    if !unchecked.isEmpty {
                        let found = await Task.detached(priority: .utility) {
                            ReadOnlyFS.projectFolders(among: unchecked, in: url)
                        }.value
                        browser.checkedForProject.formUnion(unchecked.map(\.relativePath))
                        browser.projectFolders.formUnion(found)
                        if Task.isCancelled { return }
                        listing = withProjects(result)
                    }
                }
            } else {
                unreachable = true
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func withProjects(_ listing: FolderListing) -> FolderListing {
        var copy = listing
        let projects = BrowserModel.shared.projectFolders
        for i in copy.folders.indices {
            copy.folders[i].isProject = projects.contains(copy.folders[i].relativePath)
        }
        return copy
    }
}

// MARK: - List view

struct ListModeView: View {
    let listing: FolderListing
    var body: some View {
        BinScrollList(folders: listing.folders, bins: listing.bins)
    }
}

/// Finder-like list on a plain scroll view: click a bin to select it, click empty space
/// to deselect. (SwiftUI's List is a table underneath and swallows some clicks.)
struct BinScrollList: View {
    let folders: [FolderItem]
    let bins: [ScannedBin]
    var subtitle: ((String) -> String)? = nil

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders) { folder in
                            FolderRow(folder: folder, subtitle: subtitle?(folder.relativePath))
                                .padding(.horizontal, 20)
                                .id(folder.relativePath)
                        }
                        ForEach(bins) { bin in
                            SelectableBinRow(bin: bin, subtitle: subtitle?(bin.relativePath))
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .background(EmptySpaceTap { BrowserModel.shared.clickedEmptySpace() })
                }
                .tracksVisibleBins(bins)
                .scrollsToSelection(proxy)
            }
        }
    }
}

/// A bin row you can click to select (⌘/⇧ for several); its Watch button still works.
struct SelectableBinRow: View {
    let bin: ScannedBin
    let subtitle: String?
    @ObservedObject private var browser = BrowserModel.shared
    @State private var hover = false

    var body: some View {
        let selected = browser.selection.contains(bin.relativePath)
        BinRow(bin: bin, subtitle: subtitle)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(hover ? 0.05 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { browser.click(bin.relativePath) }
            .onHover { hover = $0 }
            .contextMenu { BinContextMenu(bin: bin) }
            .padding(.horizontal, 8)
            .id(bin.relativePath)
    }
}

/// Sits *behind* rows and tiles, so it only gets clicks that miss them. (A tap gesture on
/// the container itself would win over the rows' own clicks.)
struct EmptySpaceTap: View {
    let action: () -> Void
    var body: some View {
        Color.clear.contentShape(Rectangle()).onTapGesture {
            // The second click of a double-click isn't "clicking empty space": otherwise
            // double-clicking a folder would open it, then close it again.
            guard (NSApp.currentEvent?.clickCount ?? 1) < 2 else { return }
            action()
        }
    }
}

extension View {
    /// Tells the browser which bins are on screen, in order (for ⇧-click, ⌘A and arrow keys).
    func tracksVisibleBins(_ bins: [ScannedBin]) -> some View {
        onAppear { BrowserModel.shared.visibleBins = bins }
            .onChange(of: bins) { BrowserModel.shared.visibleBins = $0 }
    }

    func scrollsToSelection(_ proxy: ScrollViewProxy) -> some View {
        modifier(ScrollToSelection(proxy: proxy))
    }
}

private struct ScrollToSelection: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var browser = BrowserModel.shared

    func body(content: Content) -> some View {
        content
            .onAppear { scroll() }
            .onChange(of: browser.scrollTarget) { _ in scroll() }
    }

    private func scroll() {
        guard let target = browser.scrollTarget else { return }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) } }
    }
}

struct SearchResultsView: View {
    let results: FolderListing
    let base: String
    let query: String

    var body: some View {
        if results.folders.isEmpty && results.bins.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches",
                       message: "Nothing called “\(query)” in this folder or the folders inside it.",
                       actionTitle: nil, action: {})
        } else {
            BinScrollList(folders: results.folders, bins: results.bins, subtitle: subtitle(for:))
        }
    }

    /// Where a result lives, relative to the folder being searched.
    private func subtitle(for relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        var shown = parent
        if !base.isEmpty, parent.hasPrefix(base) { shown = String(parent.dropFirst(base.count)) }
        shown = shown.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return shown.isEmpty ? "In this folder" : displayPath(shown)
    }
}

struct FolderRow: View {
    let folder: FolderItem
    let subtitle: String?
    @State private var hover = false
    @ObservedObject private var watcher = NewBinWatcher.shared

    var body: some View {
        Button {
            BrowserModel.shared.go(toRelative: folder.relativePath)
        } label: {
            HStack(spacing: 12) {
                FolderGlyph(isProject: folder.isProject, size: 15)
                    .frame(width: 28, height: 28)
                    .background((folder.isProject ? Color.purple : Color.blue).opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        NewBinsBadge(coverage: watcher.coverage(of: folder.relativePath)).offset(x: 5, y: 5)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if watcher.coverage(of: folder.relativePath) == .direct {
                    Label("New bin alerts", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(newBinBlue)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(newBinBlue.opacity(0.13), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? .secondary : .tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open “\(folder.name)”")
        .contextMenu { FolderContextMenu(folder: folder) }
    }
}

struct BinRow: View {
    @EnvironmentObject var store: AppStore
    let bin: ScannedBin
    let subtitle: String?

    var body: some View {
        let watching = store.isWatched(bin.relativePath)
        HStack(spacing: 12) {
            BinIcon(state: bin.isLocked ? .locked : .available, isScript: bin.isScript)
            VStack(alignment: .leading, spacing: 1) {
                Text(bin.name).font(.body.weight(watching ? .semibold : .regular))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if bin.isLocked {
                LockedLabel(holder: bin.lockedBy)
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: 220, alignment: .trailing)
                AskButton(relativePath: bin.relativePath, name: bin.name, holder: bin.lockedBy, compact: true)
            }
            WatchToggle(bin: bin)
        }
        .padding(.vertical, 3)
    }
}

struct WatchToggle: View {
    @EnvironmentObject var store: AppStore
    let bin: ScannedBin
    var compact = false

    var body: some View {
        let watching = store.isWatched(bin.relativePath)
        Button {
            store.toggleWatch(bin)
        } label: {
            Label(watching ? "Watching" : "Watch", systemImage: watching ? "bell.fill" : "bell")
                .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                .frame(width: compact ? 78 : 92)
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .tint(watching ? Color.accentColor : nil)
        .help(watching ? "Stop watching" : "Alert me when this \(AvidItem.noun(bin.relativePath)) is unlocked")
    }
}

struct FolderGlyph: View {
    let isProject: Bool
    let size: CGFloat
    var body: some View {
        Image(systemName: isProject ? "film.stack.fill" : "folder.fill")
            .font(.system(size: size))
            .foregroundStyle(isProject ? Color.purple : Color.blue)
    }
}

// MARK: - Icon view

struct IconGridView: View {
    let listing: FolderListing

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 132), spacing: 6)], spacing: 12) {
                        ForEach(listing.folders) { FolderTile(folder: $0) }
                        ForEach(listing.bins) { BinTile(bin: $0).id($0.relativePath) }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .background(EmptySpaceTap { BrowserModel.shared.clickedEmptySpace() })
                }
                .tracksVisibleBins(listing.bins)
                .scrollsToSelection(proxy)
            }
        }
    }
}

private struct FolderTile: View {
    let folder: FolderItem
    @State private var hover = false
    @ObservedObject private var watcher = NewBinWatcher.shared

    var body: some View {
        Button {
            BrowserModel.shared.go(toRelative: folder.relativePath)
        } label: {
            VStack(spacing: 6) {
                FolderGlyph(isProject: folder.isProject, size: folder.isProject ? 38 : 46)
                    .frame(height: 54)
                    .overlay(alignment: .bottomTrailing) {
                        NewBinsBadge(coverage: watcher.coverage(of: folder.relativePath), size: 20).offset(x: 6, y: -2)
                    }
                Text(folder.name)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 30, alignment: .top)
                Color.clear.frame(height: 22)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(hover ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open “\(folder.name)”")
        .contextMenu { FolderContextMenu(folder: folder) }
    }
}

private struct BinTile: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var browser = BrowserModel.shared
    let bin: ScannedBin
    @State private var hover = false

    var body: some View {
        let watching = store.isWatched(bin.relativePath)
        let tint: Color = bin.isLocked ? .orange : .green
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 56, height: 50)
                    .overlay(Image(systemName: itemSymbol(locked: bin.isLocked, script: bin.isScript))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint))
                if watching {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 7, y: -7)
                }
            }
            .frame(height: 54)
            Text(bin.name)
                .font(.system(size: 12, weight: watching ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)
            WatchToggle(bin: bin, compact: true)
                .frame(height: 22)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(browser.selection.contains(bin.relativePath) ? Color.accentColor.opacity(0.28)
                    : Color.primary.opacity(hover ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor.opacity(browser.selection.contains(bin.relativePath) ? 0.6 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { browser.click(bin.relativePath) }
        .onHover { hover = $0 }
        .contextMenu { BinContextMenu(bin: bin) }
        .help(bin.isLocked ? "\(bin.name) — locked" + (bin.lockedBy.map { " by \(RequestCenter.shared.describe(holder: $0))" } ?? "") : bin.name)
    }
}

/// Right-click menu for a folder, in every view.
struct FolderContextMenu: View {
    let folder: FolderItem
    @ObservedObject private var watcher = NewBinWatcher.shared

    var body: some View {
        Button("Open") { BrowserModel.shared.go(toRelative: folder.relativePath) }
        Button(watcher.watch(for: folder.relativePath) == nil ? "Alert Me About New Bins" : "Stop Alerting Me About New Bins") {
            watcher.toggle(folder: folder.relativePath)
        }
    }
}

/// Right-click menu for a bin, in every view.
struct BinContextMenu: View {
    let bin: ScannedBin
    @EnvironmentObject var store: AppStore

    var body: some View {
        let watching = store.isWatched(bin.relativePath)
        Button(watching ? "Stop Watching" : "Watch") { store.toggleWatch(bin) }
        Button(BinOpener.showLabel) {
            if let root = store.root { BinOpener.show([root.appendingPathComponent(bin.relativePath)]) }
        }
        if bin.isLocked {
            Button(bin.isScript ? "Ask for This Script…" : "Ask for This Bin…") { Navigation.shared.ask(relativePath: bin.relativePath, name: bin.name, holder: bin.lockedBy) }
        }
    }
}

// MARK: - Column view

struct ColumnBrowser: View {
    let currentListing: FolderListing?
    @ObservedObject private var browser = BrowserModel.shared
    /// Widths the user set by dragging a column's divider, keyed by the column's folder.
    @State private var customWidths: [String: CGFloat] = [:]

    var body: some View {
        let path = browser.path
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0...path.count, id: \.self) { level in
                        let relative = path.prefix(level).joined(separator: "/")
                        Group {
                            if level == path.count {
                                FinderColumn(level: level, listing: currentListing, customWidth: $customWidths[relative])
                            } else {
                                FolderLoader(relative: relative) { listing, _ in
                                    FinderColumn(level: level, listing: listing, customWidth: $customWidths[relative])
                                }
                                .id(relative)
                            }
                        }
                        Divider()
                    }
                    if selectedBins.count == 1 {
                        BinPreview(bin: selectedBins[0])
                    } else if selectedBins.count > 1 {
                        MultiBinPreview(bins: selectedBins)
                    }
                    Color.clear.frame(width: 1).id("end")
                }
            }
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: browser.path) { _ in scrollToEnd(proxy) }
            .onChange(of: browser.selection.isEmpty) { _ in scrollToEnd(proxy) }
            .tracksVisibleBins(currentListing?.bins ?? [])
        }
    }

    private var selectedBins: [ScannedBin] {
        (currentListing?.bins ?? []).filter { browser.selection.contains($0.relativePath) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .trailing) } }
    }
}

private struct FinderColumn: View {
    let level: Int
    let listing: FolderListing?
    /// Set by dragging the column's right edge; nil means "fit the longest name".
    @Binding var customWidth: CGFloat?
    @State private var dragStart: CGFloat?

    /// Wide enough for the longest name: text plus icon, badges, chevron and padding.
    private var fitWidth: CGFloat {
        guard let listing else { return 230 }
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let names = listing.folders.map(\.name) + listing.bins.map(\.name)
        let longest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(max(ceil(longest) + 92, 180), 420)
    }

    private var width: CGFloat { customWidth ?? fitWidth }
    @EnvironmentObject var store: AppStore
    @ObservedObject private var browser = BrowserModel.shared
    @ObservedObject private var watcher = NewBinWatcher.shared

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if let listing {
                            if listing.folders.isEmpty && listing.bins.isEmpty {
                                Text("Empty").foregroundStyle(.tertiary).padding(.top, 40)
                            } else {
                                LazyVStack(spacing: 1) {
                                    ForEach(listing.folders) { folderRow($0).id($0.relativePath) }
                                    ForEach(listing.bins) { binRow($0).id($0.relativePath) }
                                }
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(.top, 40)
                        }
                    }
                    .padding(6)
                    .frame(width: width)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    // Like Finder: clicking empty space in a column deselects in that column.
                    .background(EmptySpaceTap {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        browser.go(to: Array(browser.path.prefix(level)))
                    })
                }
                .scrollsToSelection(proxy)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { resizeHandle }
    }

    /// Drag the right edge to resize the column; double-click it to fit the names again.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? width
                    if dragStart == nil { dragStart = start }
                    customWidth = min(max(start + value.translation.width, 180), 600)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { customWidth = nil }
            .help("Drag to resize. Double-click to fit the names.")
    }

    private var isDeepest: Bool { level == browser.path.count - 1 && browser.selection.isEmpty }

    private func folderRow(_ folder: FolderItem) -> some View {
        let selected = level < browser.path.count && browser.path[level] == folder.name
        let active = selected && isDeepest
        return Button {
            browser.go(to: Array(browser.path.prefix(level)) + [folder.name])
        } label: {
            HStack(spacing: 7) {
                Image(systemName: folder.isProject ? "film.stack.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(active ? Color.white : folder.isProject ? Color.purple : Color.blue)
                    .frame(width: 18)
                Text(folder.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if case let coverage = watcher.coverage(of: folder.relativePath), coverage != .none {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(active ? Color.white : newBinBlue.opacity(coverage == .direct ? 1 : 0.5))
                        .help(coverage == .direct ? "New bin alerts are on for this folder" : "Covered by new bin alerts on a parent folder")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(active ? Color.white.opacity(0.8) : Color.secondary)
            }
            .font(.system(size: 13))
            .foregroundStyle(active ? Color.white : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? Color.accentColor : selected ? Color.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.name)
        .contextMenu { FolderContextMenu(folder: folder) }
    }

    private func binRow(_ bin: ScannedBin) -> some View {
        let selected = browser.selection.contains(bin.relativePath)
        let watching = store.isWatched(bin.relativePath)
        return Button {
            if level == browser.path.count {
                browser.click(bin.relativePath)
            } else {
                browser.go(to: Array(browser.path.prefix(level)), select: bin.relativePath)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: itemSymbol(locked: bin.isLocked, script: bin.isScript))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white : bin.isLocked ? Color.orange : Color.green)
                    .frame(width: 18)
                Text(bin.name).lineLimit(1).truncationMode(.middle)
                    .fontWeight(watching ? .semibold : .regular)
                Spacer(minLength: 4)
                if watching {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { BinContextMenu(bin: bin) }
        .help(bin.isLocked ? "\(bin.name) — locked" + (bin.lockedBy.map { " by \(RequestCenter.shared.describe(holder: $0))" } ?? "") : bin.name)
    }
}

/// The last column, like Finder's preview: details of the selected bin and a big Watch button.
private struct BinPreview: View {
    let bin: ScannedBin
    @EnvironmentObject var store: AppStore
    @ObservedObject private var requests = RequestCenter.shared

    var body: some View {
        let watched = store.watched.first { ReadOnlyFS.key($0.relativePath) == ReadOnlyFS.key(bin.relativePath) }
        let state = watched.flatMap { store.states[$0.id] } ?? (bin.isLocked ? .locked : .available)
        let tint: Color = state == .locked ? .orange : .green
        VStack(spacing: 12) {
            Spacer()
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: 84, height: 76)
                .overlay(Image(systemName: itemSymbol(locked: state == .locked, script: bin.isScript))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint))
            Text(bin.name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(displayPath(bin.folder))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            StatePill(state: state)
            if state == .locked, let holder = bin.lockedBy ?? watched.flatMap({ store.holders[$0.id] }) {
                LockedLabel(holder: holder).font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if state == .locked {
                if let request = requests.openRequest(for: bin.relativePath) {
                    RequestStatusChip(request: request)
                } else {
                    Button { Navigation.shared.ask(relativePath: bin.relativePath, name: bin.name,
                                                   holder: bin.lockedBy ?? watched.flatMap({ store.holders[$0.id] })) } label: {
                        Label(bin.isScript ? "Ask for This Script…" : "Ask for This Bin…", systemImage: "hand.raised").frame(minWidth: 130)
                    }
                    .controlSize(.large)
                }
            }
            if watched != nil {
                Button { store.toggleWatch(bin) } label: {
                    Label("Stop Watching", systemImage: "bell.slash").frame(minWidth: 130)
                }
                .controlSize(.large)
            } else {
                Button { store.toggleWatch(bin) } label: {
                    Label(bin.isScript ? "Watch This Script" : "Watch This Bin", systemImage: "bell.fill").frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 260)
        .frame(maxHeight: .infinity)
    }
}

/// Preview column when several bins are selected.
private struct MultiBinPreview: View {
    let bins: [ScannedBin]
    @EnvironmentObject var store: AppStore

    var body: some View {
        let allWatched = bins.allSatisfy { store.isWatched($0.relativePath) }
        let locked = bins.filter(\.isLocked).count
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10 + Double(i) * 0.06))
                        .frame(width: 76, height: 68)
                        .offset(x: CGFloat(i - 1) * 8, y: CGFloat(1 - i) * 8)
                }
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 90)
            Text("\(AvidItem.count(bins.map(\.relativePath))) selected").font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(locked == 0 ? "None are locked" : "\(locked) locked")
                .font(.caption).foregroundStyle(.secondary)
            Button { store.toggleWatch(bins) } label: {
                Label(allWatched ? "Stop Watching All" : "Watch All", systemImage: allWatched ? "bell.slash" : "bell.fill")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .tint(allWatched ? .gray : .accentColor)
            .controlSize(.large)
            Text("or press Return").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(20)
        .frame(width: 260)
        .frame(maxHeight: .infinity)
    }
}

/// Keyboard control while Browse is on screen: Return toggles watching, ⌘O / ⌘↓ open,
/// ⌘A selects all, ↑/↓ move (⇧ to extend), ←/→ step out of / into folders in column
/// view, Esc clears.
/// Keys typed into a text field (search, path) are left alone.
enum BrowseKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    static func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.identifier == ManageWindow.identifier,
              Navigation.shared.selection == .browse,
              !(window.firstResponder is NSText)       // typing in a text field
        else { return false }
        let browser = BrowserModel.shared
        let mode = browser.isSearching ? .list : AppStore.shared.settings.browseMode
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let plain = modifiers.isEmpty
        let shift = modifiers == [.shift]

        switch event.keyCode {
        case 36 where plain, 76 where plain:            // Return / Enter
            let bins = browser.selectedBins
            guard !bins.isEmpty else { return false }
            AppStore.shared.toggleWatch(bins)
            return true
        case 31 where modifiers == [.command],          // ⌘O
             125 where modifiers == [.command]:         // ⌘↓ (Finder's "open")
            guard !browser.selection.isEmpty else { return false }
            browser.openSelection()
            return true
        case 0 where modifiers == [.command]:           // ⌘A
            browser.selectAll()
            return true
        case 126 where plain || shift:                  // ↑
            if mode == .columns { browser.columnMove(by: -1, extend: shift) }
            else { browser.moveSelection(by: -1, extend: shift) }
            return true
        case 125 where plain || shift:                  // ↓
            if mode == .columns { browser.columnMove(by: 1, extend: shift) }
            else { browser.moveSelection(by: 1, extend: shift) }
            return true
        case 123 where plain || shift:                  // ←
            switch mode {
            case .columns: if plain { browser.columnLeft() }
            case .icons:   browser.moveSelection(by: -1, extend: shift)
            case .list:    return false
            }
            return true
        case 124 where plain || shift:                  // →
            switch mode {
            case .columns: if plain { browser.columnRight() }
            case .icons:   browser.moveSelection(by: 1, extend: shift)
            case .list:    return false
            }
            return true
        case 53 where plain:                            // Esc
            guard !browser.selection.isEmpty else { return false }
            browser.clearSelection()
            return true
        default:
            return false
        }
    }
}

struct HoverHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct HoverHighlight<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false

        var body: some View {
            label
                .background(Color.primary.opacity(pressed ? 0.12 : hover ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .onHover { hover = $0 }
        }
    }
}
