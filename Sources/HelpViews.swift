import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Technical details for feedback

/// Bin Watch's own lines in a report's technical details (BugReportConfig.appDetails): how
/// it's set up and how it's doing. Never names of projects, bins, folders, people or computers.
enum Diagnostics {
    /// Called at launch (and by the UI tests).
    static func install() { BugReportConfig.appDetails = appDetails }

    static func appDetails() -> [String] {
        let store = AppStore.shared, requests = RequestCenter.shared, updater = Updater.shared
        var lines: [String] = []
        lines.append("Running from: \(AppLocation.current.summary)")

        if let path = store.rootPath {
            let reach = store.rootOnline.map { $0 ? "reachable" : "not reachable" } ?? "not checked yet"
            lines.append("Monitored folder: chosen · \(reach) · \(BugReportDiagnostics.storageKind(path))")
        } else {
            lines.append("Monitored folder: none chosen")
        }
        let locked = store.watched.filter { store.states[$0.id] == .locked }.count
        lines.append("Watching: \(store.watched.count) (\(locked) locked) · Waiting alerts: \(store.pendingAlerts.count) · New-bin folders: \(NewBinWatcher.shared.watches.count)")

        if let path = requests.mailboxPath {
            let online = requests.people.filter(\.isOnline).count
            let open = requests.outgoing.filter { $0.status == .open }
            let unsent = open.filter { !requests.delivered.contains($0.id) }.count
            lines.append("Bin requests: \(requests.status) · \(BugReportDiagnostics.storageKind(path)) · \(requests.people.count) people (\(online) online) · \(open.count) open requests (\(unsent) not sent)")
            if let check = requests.lastCheck {
                let clock = check.clockOffset.map { String(format: "%+.0fs", $0) } ?? "?"
                lines.append("Connection check: \(check.problem.map(BugReport.redact) ?? "OK") · storage clock \(clock)")
            }
        } else {
            lines.append("Bin requests: off")
        }

        let s = store.settings
        let onOff = { (b: Bool) in b ? "on" : "off" }
        lines.append("Settings: check every \(Int(s.pollInterval))s · lock names \(onOff(s.showLockHolders)) · repeat chime \(onOff(s.repeatChime)) · stop after alert \(onOff(s.stopWatchingAfterAlert)) · menu bar icon \(onOff(s.showMenuBarIcon)) · open at login \(LoginItem.isOn ? (LoginItem.problem == nil ? "on" : "on, but won't work") : "off") · update checks \(onOff(s.checkForUpdates)) · flag locks after \(s.leftoverLockDays == 0 ? "never" : "\(s.leftoverLockDays) days")")
        lines.append("Updates: \(BugReport.redact(updater.statusText))")

        return lines
    }
}

// MARK: - Settings: Updates

struct UpdatesSettings: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Bin Watch \(updater.currentVersion)").font(.body.weight(.medium))
                        + Text(" – made by Alex Stuart").font(.callout).foregroundColor(.secondary))
                    UpdateStatusLine()
                }
                Spacer()
                UpdateButtons()
            }
            if case .downloading(let fraction) = updater.phase {
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
            if let update = updater.update, updater.phase != .upToDate, !update.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's new in \(update.version)").font(.headline)
                    ReleaseNotes(markdown: update.notes)
                    Button("Full release notes on GitHub") { BugReportLinks.open(update.pageURL) }
                        .buttonStyle(.link)
                }
                .padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Check for updates automatically", isOn: $store.settings.checkForUpdates)
                Text("Once a day, Bin Watch asks GitHub whether there's a newer version. Nothing is installed until you click Update.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UpdateStatusLine: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .failed:
                Label(updater.statusText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .upToDate:
                Label(upToDateText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available:
                Label(updater.statusText, systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            default:
                Text(updater.justUpdated && updater.phase == .idle ? "Updated — you're on the latest version" : updater.statusText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var upToDateText: String {
        guard let checked = updater.lastChecked else { return "Up to date" }
        return "Up to date · checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

private struct UpdateButtons: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 8) {
            switch updater.phase {
            case .checking, .downloading, .installing, .restarting:
                ProgressView().controlSize(.small)
            case .available:
                Button("Update to \(updater.update?.version ?? "")") { updater.installAsking() }
                    .buttonStyle(.borderedProminent)
            case .failed:
                if updater.installFailed, updater.update != nil {
                    Button("Download from GitHub") { BugReportLinks.open(updater.update?.pageURL ?? UpdateLogic.releasesPage) }
                    Button("Try Again") { updater.installAsking() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Check Again") { updater.check() }
                }
            default:
                Button("Check Now") { updater.check() }
            }
        }
    }
}

/// Release notes as GitHub writes them: "**bold**" and "- " bullets, with headings dropped.
struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                    .padding(.leading, 6)
                } else {
                    inline(line)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var lines: [String] {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
    }
}

// MARK: - Sidebar card

/// Appears above the monitored folder when there's an update, while installing, and
/// once after updating.
struct UpdateSidebarCard: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(content.heading)
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(content.tint)
                    Spacer()
                    if updater.justUpdated && updater.update == nil {
                        Button { updater.justUpdated = false } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hide")
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: content.symbol).foregroundStyle(content.tint)
                    Text(content.title).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                if case .downloading(let fraction) = updater.phase {
                    ProgressView(value: fraction).controlSize(.small)
                }
                buttons
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(content.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("Update Now") { updater.installAsking() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed where updater.installFailed:
            Button("Details…") { Navigation.shared.selection = .settings }
                .controlSize(.small)
        case .idle, .upToDate:
            if updater.justUpdated {
                Button("What's New") { BugReportLinks.open(UpdateLogic.releasePage(for: updater.currentVersion)) }
                    .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    private struct Content { let heading: String; let title: String; let symbol: String; let tint: Color }

    private var content: Content? {
        let version = updater.update?.version ?? ""
        switch updater.phase {
        case .available:
            return Content(heading: "UPDATE AVAILABLE", title: "Bin Watch \(version)", symbol: "arrow.down.circle.fill", tint: .accentColor)
        case .downloading:
            return Content(heading: "UPDATING", title: "Downloading \(version)…", symbol: "arrow.down.circle", tint: .accentColor)
        case .installing, .restarting:
            return Content(heading: "UPDATING", title: updater.statusText, symbol: "arrow.triangle.2.circlepath", tint: .accentColor)
        case .failed where updater.installFailed:
            return Content(heading: "UPDATE", title: "Couldn't install \(version)", symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .idle, .upToDate:
            return updater.justUpdated
                ? Content(heading: "UPDATED", title: "Now on Bin Watch \(updater.currentVersion)", symbol: "checkmark.circle.fill", tint: .green)
                : nil
        default:
            return nil
        }
    }
}
