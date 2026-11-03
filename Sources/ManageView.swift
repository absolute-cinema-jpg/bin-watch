import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case watching, locked, browse, newBins, settings
}

final class Navigation: ObservableObject {
    static let shared = Navigation()
    @Published var selection: SidebarItem? = .browse
    /// The bin the "Ask for this bin" sheet is open for.
    @Published var askTarget: AskTarget?

    func ask(relativePath: String, name: String, holder: String? = nil) {
        askTarget = AskTarget(relativePath: relativePath, name: name, holder: holder)
    }

    /// Jump the browser to a folder (e.g. "show me where this watched bin lives").
    func reveal(folder: String, select bin: String? = nil) {
        BrowserModel.shared.go(toRelative: folder, select: bin)
        selection = .browse
    }
}

struct ManageView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var newBins = NewBinWatcher.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 540)
        .sheet(item: $nav.askTarget) { target in
            AskSheet(target: target).environmentObject(store)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $nav.selection) {
                Label {
                    HStack {
                        Text("Watching")
                        Spacer()
                        if !store.watched.isEmpty { CountBadge(count: store.watched.count) }
                    }
                } icon: {
                    Image(systemName: "bell.badge").foregroundStyle(Color.accentColor)
                }
                .tag(SidebarItem.watching)

                Label {
                    Text("Locked")
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                .tag(SidebarItem.locked)

                Label {
                    HStack {
                        Text("New Bins")
                        Spacer()
                        if !newBins.watches.isEmpty { CountBadge(count: newBins.watches.count) }
                    }
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Color(red: 0.22, green: 0.72, blue: 0.92))
                }
                .tag(SidebarItem.newBins)

                Label {
                    Text("Browse")
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.blue)
                }
                .tag(SidebarItem.browse)

                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
            .listStyle(.sidebar)

            MonitoredFolderCard()
                .padding(12)
        }
        .background(VisualEffectBackground(material: .sidebar))
    }

    @ViewBuilder
    private var detail: some View {
        switch nav.selection {
        case .watching: WatchingView()
        case .settings: SettingsView()
        case .newBins:  NewBinsView()
        case .locked:   LockedView()
        default:        BrowseView()
        }
    }
}

/// Shows which folder is being monitored, with a button to change it.
struct MonitoredFolderCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MONITORED FOLDER")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(store.rootPath == nil ? "None chosen" : store.rootName)
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if store.rootPath != nil {
                    Circle()
                        .fill(store.rootOnline == false ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                        .help(store.rootOnline == false ? "Can't reach this folder right now" : "Connected")
                }
            }
            Button(store.rootPath == nil ? "Choose Folder…" : "Change…") { store.chooseRootViaPanel() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(store.rootPath ?? "")
    }
}

// MARK: - Watching

struct WatchingView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Watching", subtitle: subtitle, symbol: "bell.badge.fill", tint: .accentColor)
                .overlay(alignment: .trailing) {
                    if !store.watched.isEmpty {
                        Button("Clear All") { confirmClearAll() }
                            .padding(.trailing, 20)
                    }
                }
            Divider()
            if store.watched.isEmpty {
                EmptyState(
                    symbol: "bell.slash",
                    title: "You're not watching any bins or scripts",
                    message: "Browse to any bin or script you're waiting for and click Watch. You'll be alerted the moment it's unlocked.",
                    actionTitle: "Browse",
                    action: { Navigation.shared.selection = .browse })
            } else {
                List {
                    ForEach(folders, id: \.self) { folder in
                        Section {
                            ForEach(store.watched.filter { $0.folder == folder }) { WatchedRow(bin: $0) }
                        } header: {
                            Button {
                                Navigation.shared.reveal(folder: folder)
                            } label: {
                                Label(displayPath(folder, root: store.rootName), systemImage: "folder")
                            }
                            .buttonStyle(.plain)
                            .help("Show this folder")
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
    }

    /// A standard macOS sheet. (A SwiftUI confirmation dialog inside the header didn't
    /// appear until the page next redrew, so the first click seemed to do nothing.)
    private func confirmClearAll() {
        let count = store.watched.count
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Stop watching \(AvidItem.count(store.watched.map(\.relativePath)))?"
                                       : "Stop watching all \(AvidItem.count(store.watched.map(\.relativePath)))?"
        alert.informativeText = "You won't be alerted when they're unlocked. Nothing in your project is changed."
        alert.addButton(withTitle: "Stop Watching All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { AppStore.shared.unwatchAll() }
        }
        if let window = ManageWindow.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    private var folders: [String] {
        var seen: [String] = []
        for bin in store.watched where !seen.contains(bin.folder) { seen.append(bin.folder) }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var subtitle: String {
        let n = store.watched.count
        guard n > 0 else { return "You'll get an alert the moment a watched bin or script is unlocked." }
        let locked = store.lockedCount
        let scripts = store.watched.filter(\.isScript).count, bins = n - scripts
        let what = [bins > 0 ? "\(bins) bin\(bins == 1 ? "" : "s")" : nil,
                    scripts > 0 ? "\(scripts) script\(scripts == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
        return "\(what) · \(locked) still locked"
    }
}

struct WatchedRow: View {
    @EnvironmentObject var store: AppStore
    let bin: WatchedBin

    @ObservedObject private var requests = RequestCenter.shared

    var body: some View {
        let state = store.states[bin.id] ?? .checking
        HStack(spacing: 12) {
            BinIcon(state: state, isScript: bin.isScript)
            VStack(alignment: .leading, spacing: 1) {
                Text(bin.name).font(.body.weight(.medium))
                if state == .locked, let holder = store.holders[bin.id] {
                    LockedLabel(holder: holder).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let request = requests.openRequest(for: bin.relativePath) {
                RequestStatusChip(request: request)
            } else if state == .locked {
                AskButton(relativePath: bin.relativePath, name: bin.name, holder: store.holders[bin.id])
            }
            StatePill(state: state)
            Button {
                store.unwatch(bin)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Stop watching this \(AvidItem.noun(bin.relativePath))")
        }
        .padding(.vertical, 5)
    }
}
