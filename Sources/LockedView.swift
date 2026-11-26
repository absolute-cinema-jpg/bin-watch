import SwiftUI

/// Finds every locked bin and script in the monitored folder, for the Locked page.
/// Read-only like everything else: it only lists folders (and, if that's turned on, reads
/// the name in each lock file once). It only looks while the Locked page is showing, since
/// listing a whole project tree is far more work than checking a few watched bins.
final class LockedScanner: ObservableObject {
    static let shared = LockedScanner()

    @Published private(set) var items: [ScannedBin] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanning = false
    /// nil = not looked yet, false = couldn't read the monitored folder last time.
    @Published private(set) var reachable: Bool?

    static let interval: TimeInterval = 15
    private var timer: Timer?
    private let queue = DispatchQueue(label: "binwatch.locked", qos: .utility)

    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !scanning, let root = AppStore.shared.root else { return }
        scanning = true
        queue.async { [weak self] in
            let found = ReadOnlyFS.lockedItems(under: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.lastScan = Date()
                if self.reachable != (found != nil) { self.reachable = found != nil }
                // Offline: keep showing the last list rather than claiming nothing's locked.
                if let found, found != self.items { self.items = found }
            }
        }
    }
}

/// The "Locked" tab: everything that's open right now, grouped by who has it.
struct LockedView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var scanner = LockedScanner.shared
    @ObservedObject private var requests = RequestCenter.shared
    @State private var filter: LockOwner?
    @State private var search = ""

    var body: some View {
        let groups = LockedBins.group(scanner.items, me: requests.me, people: requests.people.map(\.person))
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Locked", subtitle: subtitle(groups), symbol: "lock.fill", tint: .orange) {
                HStack(spacing: 10) {
                    if scanner.scanning {
                        ProgressView().controlSize(.small)
                    } else if scanner.reachable == false {
                        Label("Can't reach the folder", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button { scanner.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(scanner.scanning)
                        .help("Check again now (it checks every \(Int(LockedScanner.interval)) seconds while this page is open)")
                }
            }
            Divider()
            content(groups)
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    @ViewBuilder
    private func content(_ groups: [LockedBins.Group]) -> some View {
        if store.root == nil {
            EmptyState(symbol: "folder.badge.questionmark", title: "No folder chosen",
                       message: "Choose the folder with your Avid projects to see which bins are open.",
                       actionTitle: "Choose Folder…", action: { store.chooseRootViaPanel() })
        } else if scanner.lastScan == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for locked bins and scripts…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scanner.items.isEmpty {
            EmptyState(symbol: "lock.open", title: "Nothing is locked",
                       message: "Nobody has a bin or script open in “\(store.rootName)” right now.",
                       actionTitle: nil, action: {})
        } else {
            VStack(spacing: 0) {
                filterBar(groups)
                if !store.settings.showLockHolders { holdersOffNote }
                Divider()
                list(groups)
            }
        }
    }

    // MARK: Filter

    private func filterBar(_ groups: [LockedBins.Group]) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    OwnerChip(title: "Everyone", symbol: "person.3.fill", count: scanner.items.count,
                              selected: filter == nil) { filter = nil }
                    ForEach(groups) { group in
                        OwnerChip(title: group.owner.name, symbol: symbol(for: group.owner), count: group.items.count,
                                  selected: filter?.id == group.id) { filter = group.owner }
                    }
                }
                .padding(.vertical, 1)
            }
            TextField("Filter by name", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var holdersOffNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("Names are hidden: “Show who has a locked bin or script open” is off.")
            Spacer()
            Button("Turn On") {
                store.settings.showLockHolders = true
                scanner.refresh()
            }
            .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: List

    @ViewBuilder
    private func list(_ groups: [LockedBins.Group]) -> some View {
        let shown = groups
            .filter { filter == nil || $0.id == filter?.id }
            .map { LockedBins.Group(owner: $0.owner, items: $0.items.filter { LockedBins.matches($0, search: search) }) }
            .filter { !$0.items.isEmpty }
        if let filter, !groups.contains(where: { $0.id == filter.id }) {
            EmptyState(symbol: "lock.open",
                       title: filter.kind == .me ? "You have nothing open" : "\(filter.name) has nothing open",
                       message: "Everything they had locked has been closed.",
                       actionTitle: "Show Everyone", action: { self.filter = nil })
        } else if shown.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches",
                       message: "Nothing locked matches “\(search)”.",
                       actionTitle: "Clear Filter", action: { search = "" })
        } else {
            List {
                ForEach(shown) { group in
                    Section {
                        ForEach(group.items) { LockedRow(bin: $0, owner: group.owner) }
                    } header: {
                        GroupHeader(group: group, symbol: symbol(for: group.owner)) { filter = group.owner }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
    }

    private func symbol(for owner: LockOwner) -> String {
        switch owner.kind {
        case .me: return "person.crop.circle.fill"
        case .colleague: return "person.fill"
        case .computer: return "desktopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }

    private func subtitle(_ groups: [LockedBins.Group]) -> String {
        guard scanner.lastScan != nil, !scanner.items.isEmpty else { return "Every bin and script someone has open, and who has it." }
        let people = groups.filter { $0.owner.kind != .unknown }.count
        let who = people == 0 ? "" : " by \(people) \(people == 1 ? "person" : "people")"
        return "\(AvidItem.count(scanner.items.map(\.relativePath))) open\(who) in \(store.rootName)"
    }
}

private struct OwnerChip: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 0.5)
                    .background((selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)), in: Capsule())
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(selected ? AnyShapeStyle(Color.orange.gradient)
                                                : AnyShapeStyle(Color.primary.opacity(hover ? 0.1 : 0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(selected ? "Showing \(title == "Everyone" ? "everyone" : title)" : "Show only \(title == "Everyone" ? "everyone" : title)")
    }
}

private struct GroupHeader: View {
    let group: LockedBins.Group
    let symbol: String
    let showOnly: () -> Void
    @EnvironmentObject var store: AppStore

    var body: some View {
        let paths = group.items.map(\.relativePath)
        let allWatched = group.items.allSatisfy { store.isWatched($0.relativePath) }
        HStack(spacing: 6) {
            Button(action: showOnly) {
                Label(group.owner.name, systemImage: symbol).font(.headline)
            }
            .buttonStyle(.plain)
            .help(group.owner.kind == .computer ? "Avid's lock files say these are open on “\(group.owner.name)”"
                                                : "Show only \(group.owner.name)")
            Text("· \(AvidItem.count(paths))").foregroundStyle(.secondary)
            Spacer()
            if group.owner.kind != .me {
                Button(allWatched ? "Stop Watching All" : "Watch All") { store.toggleWatch(group.items) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(allWatched ? "Stop watching these" : "Alert me as each of these is unlocked")
            }
        }
        .padding(.top, 4)
    }
}

private struct LockedRow: View {
    let bin: ScannedBin
    let owner: LockOwner
    @EnvironmentObject var store: AppStore
    @ObservedObject private var requests = RequestCenter.shared

    var body: some View {
        HStack(spacing: 12) {
            BinIcon(state: .locked, isScript: bin.isScript)
            VStack(alignment: .leading, spacing: 1) {
                Text(bin.name).font(.body.weight(store.isWatched(bin.relativePath) ? .semibold : .regular))
                Text(displayPath(bin.folder, root: store.rootName))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if owner.kind != .me {
                if let request = requests.openRequest(for: bin.relativePath) {
                    RequestStatusChip(request: request)
                } else {
                    AskButton(relativePath: bin.relativePath, name: bin.name, holder: bin.lockedBy, compact: true)
                }
                WatchToggle(bin: bin, compact: true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .help(bin.lockedBy.map { "Open on “\($0)” · double-click to open" } ?? "Double-click to open")
        .contextMenu {
            BinContextMenu(bin: bin)
            Divider()
            Button("Show in Browse") { Navigation.shared.reveal(folder: bin.folder, select: bin.relativePath) }
        }
    }

    private func open() {
        if let root = store.root { BinOpener.show([root.appendingPathComponent(bin.relativePath)]) }
    }
}
