import SwiftUI

let newBinBlue = Color(red: 0.22, green: 0.72, blue: 0.92)

/// The "New Bins" tab: folders you want to hear about, and what's appeared in them.
struct NewBinsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var watcher = NewBinWatcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "New Bins",
                   subtitle: "Get an alert when bins or scripts appear in folders you choose.",
                   symbol: "sparkles", tint: newBinBlue)
            Divider()
            if watcher.watches.isEmpty {
                EmptyState(
                    symbol: "sparkles.rectangle.stack",
                    title: "Not watching any folders for new bins",
                    message: "In Browse, open a folder (your project's top level, say) and click “New Bin Alerts” next to the path bar, or right-click a folder and choose “Alert Me About New Bins”. Scripts count too.",
                    actionTitle: "Browse",
                    action: { Navigation.shared.selection = .browse })
            } else {
                List {
                    Section("Folders") {
                        ForEach(watcher.watches) { FolderWatchRow(watch: $0) }
                    }
                    Section {
                        if watcher.events.isEmpty {
                            Text("Nothing new yet. New bins and scripts will be listed here, and you'll get an alert.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(watcher.events) { NewBinRow(event: $0) }
                        }
                    } header: {
                        HStack {
                            Text("Recently added")
                            Spacer()
                            if !watcher.events.isEmpty {
                                Button("Clear List") { watcher.clearEvents() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
    }
}

private struct FolderWatchRow: View {
    let watch: NewBinWatcher.FolderWatch
    @EnvironmentObject var store: AppStore
    @ObservedObject private var watcher = NewBinWatcher.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    Navigation.shared.reveal(folder: watch.folder)
                } label: {
                    Text(watch.folder.isEmpty ? store.rootName : displayPath(watch.folder))
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .help("Show this folder")
                Text(status).font(.caption).foregroundStyle(watcher.reachable[watch.id] == false ? .orange : .secondary)
            }
            Spacer()
            Toggle("Include subfolders", isOn: Binding(
                get: { watch.includeSubfolders },
                set: { watcher.setIncludeSubfolders($0, for: watch) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            Button { watcher.remove(watch) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Stop watching this folder for new bins")
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        switch watcher.reachable[watch.id] {
        case .some(false): return "Can't reach this folder right now"
        case .none: return "Checking…"
        default:
            return watch.includeSubfolders ? "Checking every \(Int(NewBinWatcher.subfolderInterval)) seconds, including subfolders"
                                           : "Checking every \(Int(NewBinWatcher.interval)) seconds"
        }
    }
}

private struct NewBinRow: View {
    let event: NewBinWatcher.Event
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AvidItem.isScript(event.binPath) ? "doc.text.fill" : "sparkles")
                .foregroundStyle(newBinBlue)
                .frame(width: 28, height: 28)
                .background(newBinBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(event.name).font(.body.weight(.medium))
                Text(displayPath(event.folder, root: store.rootName))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.detected.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary)
            Button(AvidItem.isScript(event.binPath) ? "Show Script" : "Show Bin") {
                if let root = store.root { BinOpener.show([root.appendingPathComponent(event.binPath)]) }
            }
            .controlSize(.small)
            .help(BinOpener.showLabel)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show in Browse") { Navigation.shared.reveal(folder: event.folder, select: event.binPath) }
        }
    }
}

/// "New Bin Alerts" next to Browse's path bar: turn alerts on/off for the folder you're in.
struct NewBinsToggleButton: View {
    let folder: String
    @ObservedObject private var watcher = NewBinWatcher.shared
    @State private var hover = false

    var body: some View {
        let coverage = watcher.coverage(of: folder)
        let on = coverage == .direct
        Button { watcher.toggle(folder: folder) } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Text("New Bin Alerts")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? Color.white : newBinBlue)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule().fill(on ? AnyShapeStyle(LinearGradient(colors: [newBinBlue, Color(red: 0.12, green: 0.5, blue: 0.85)],
                                                                 startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(newBinBlue.opacity(hover ? 0.22 : 0.13))))
            .overlay(Capsule().strokeBorder(newBinBlue.opacity(on ? 0 : 0.55), lineWidth: 1))
            .shadow(color: newBinBlue.opacity(on ? 0.45 : 0), radius: 6, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .help(help(coverage))
    }

    private func help(_ coverage: NewBinWatcher.Coverage) -> String {
        switch coverage {
        case .direct: return "You're alerted when bins or scripts appear in this folder. Click to stop."
        case .viaParent(let parent):
            return "Already covered: “\(parent.isEmpty ? AppStore.shared.rootName : (parent as NSString).lastPathComponent)” is watched including subfolders. Click to also check this folder every few seconds."
        case .none: return "Alert me when bins or scripts appear in this folder"
        }
    }
}

/// Marks a folder that's watched for new bins (solid) or covered by a parent (faint).
struct NewBinsBadge: View {
    let coverage: NewBinWatcher.Coverage
    var size: CGFloat = 15

    var body: some View {
        if coverage != .none {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(newBinBlue.opacity(coverage == .direct ? 1 : 0.5)))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .help(coverage == .direct ? "New bin alerts are on for this folder" : "Covered by new bin alerts on a parent folder")
        }
    }
}
