import AppKit
import SwiftUI

enum ManageWindow {
    private(set) static var window: NSWindow?
    static let identifier = NSUserInterfaceItemIdentifier("BinWatchMain")

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Bin Watch"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            // Accepts the first click even while another app (Avid) is in front.
            w.contentView = FirstClickHostingView(
                rootView: ManageView().environmentObject(AppStore.shared))
            w.tabbingMode = .disallowed
            w.identifier = identifier
            w.setContentSize(NSSize(width: 860, height: 580))
            w.center()
            w.setFrameAutosaveName("BinWatchMain")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "lock.rectangle.stack.fill").foregroundStyle(Color.accentColor)
                Text("Bin Watch").font(.headline)
                Spacer()
                if !store.watched.isEmpty {
                    Text("\(store.lockedCount) of \(store.watched.count) locked")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Divider()

            if store.watched.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.title2).foregroundStyle(.tertiary)
                    Text("Not watching anything").font(.callout.weight(.medium))
                    Text("Choose bins or scripts to watch and you'll be alerted when they unlock.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.watched) { bin in
                            MenuBinRow(bin: bin)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(spacing: 0) {
                if updater.phase == .available, let version = updater.update?.version {
                    MenuButton(title: "Update to Bin Watch \(version)", symbol: "arrow.down.circle") {
                        ManageWindow.show()
                        updater.installAsking()
                    }
                }
                MenuButton(title: "Open Bin Watch", symbol: "macwindow") { ManageWindow.show() }
                MenuButton(title: "Quit Bin Watch", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 310)
    }
}

private struct MenuBinRow: View {
    @EnvironmentObject var store: AppStore
    let bin: WatchedBin
    @State private var hover = false

    var body: some View {
        let state = store.states[bin.id] ?? .checking
        HStack(spacing: 10) {
            BinIcon(state: state, isScript: bin.isScript)
            VStack(alignment: .leading, spacing: 1) {
                Text(bin.name).font(.callout.weight(.medium)).lineLimit(1)
                if state == .locked, let holder = store.holders[bin.id] {
                    LockedLabel(holder: holder).font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(displayPath(bin.folder, root: store.rootName))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if hover {
                Button { store.unwatch(bin) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop watching")
            } else {
                Text(state.title).font(.caption.weight(.semibold)).foregroundStyle(state.color)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
    }
}

private struct MenuButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hover ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(hover ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
