import AppKit
import OSLog
import ServiceManagement
import SwiftUI

/// Opens web pages in the person's browser. Tests set the hook to see what would open.
enum LinkOpener {
    static var testHook: ((URL) -> Void)?
    static func open(_ url: URL) {
        if let testHook { testHook(url) } else { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Technical details for bug reports

/// A summary of how Bin Watch is set up and how it's doing, for bug reports. It never
/// includes names of projects, bins, folders, people or computers.
enum Diagnostics {
    static func collect() -> String {
        let store = AppStore.shared, requests = RequestCenter.shared, updater = Updater.shared
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = []
        lines.append("Bin Watch \(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))")
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(processor)")

        if let path = store.rootPath {
            let reach = store.rootOnline.map { $0 ? "reachable" : "not reachable" } ?? "not checked yet"
            lines.append("Monitored folder: chosen · \(reach) · \(storageKind(path))")
        } else {
            lines.append("Monitored folder: none chosen")
        }
        let locked = store.watched.filter { store.states[$0.id] == .locked }.count
        lines.append("Watching: \(store.watched.count) (\(locked) locked) · Waiting alerts: \(store.pendingAlerts.count) · New-bin folders: \(NewBinWatcher.shared.watches.count)")

        if let path = requests.mailboxPath {
            let online = requests.people.filter(\.isOnline).count
            let open = requests.outgoing.filter { $0.status == .open }
            let unsent = open.filter { !requests.delivered.contains($0.id) }.count
            lines.append("Bin requests: \(requests.status) · \(storageKind(path)) · \(requests.people.count) people (\(online) online) · \(open.count) open requests (\(unsent) not sent)")
            if let check = requests.lastCheck {
                let clock = check.clockOffset.map { String(format: "%+.0fs", $0) } ?? "?"
                lines.append("Connection check: \(check.problem.map(BugReport.redact) ?? "OK") · storage clock \(clock)")
            }
        } else {
            lines.append("Bin requests: off")
        }

        let s = store.settings
        let onOff = { (b: Bool) in b ? "on" : "off" }
        lines.append("Settings: check every \(Int(s.pollInterval))s · lock names \(onOff(s.showLockHolders)) · repeat chime \(onOff(s.repeatChime)) · stop after alert \(onOff(s.stopWatchingAfterAlert)) · menu bar icon \(onOff(s.showMenuBarIcon)) · open at login \(onOff(SMAppService.mainApp.status == .enabled)) · update checks \(onOff(s.checkForUpdates))")
        lines.append("Updates: \(BugReport.redact(updater.statusText))")

        let events = recentEvents()
        if !events.isEmpty {
            lines.append("")
            lines.append(BugReport.eventsHeading)
            lines += events
        }
        return lines.joined(separator: "\n")
    }

    private static var processor: String {
        var arm = 0, translated = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        size = MemoryLayout<Int>.size
        sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return arm == 1 ? (translated == 1 ? "Apple Silicon (running as Intel)" : "Apple Silicon") : "Intel"
    }

    /// The kind of storage, never its name: "SMB server", "AFP server", "this Mac's disk"…
    static func storageKind(_ path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "storage not mounted" }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        switch type {
        case "smbfs": return "SMB server"
        case "afpfs": return "AFP server"
        case "nfs": return "NFS server"
        case "webdav": return "WebDAV server"
        case "apfs", "hfs": return fs.f_flags & UInt32(MNT_LOCAL) != 0 ? "Mac disk (\(type))" : type
        default: return type.isEmpty ? "unknown storage" : type
        }
    }

    /// Bin Watch's own log messages about the mailbox and updates since it started, with
    /// anything that looks like a name or path taken out.
    static func recentEvents(limit: Int = 25) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(date: Date().addingTimeInterval(-24 * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", "local.binwatch.BinWatch")
        guard let entries = try? store.getEntries(at: since, matching: predicate) else { return [] }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .filter { ["mailbox", "update"].contains($0.category) }
            .map { "\(time.string(from: $0.date)) [\($0.category)] \(BugReport.redact($0.composedMessage))" }
        return Array(lines.suffix(limit))
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
                    Text("Bin Watch \(updater.currentVersion)").font(.body.weight(.medium))
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
                    Button("Full release notes on GitHub") { LinkOpener.open(update.pageURL) }
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
                    Button("Download from GitHub") { LinkOpener.open(updater.update?.pageURL ?? UpdateLogic.releasesPage) }
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
                Button("What's New") { LinkOpener.open(UpdateLogic.releasePage(for: updater.currentVersion)) }
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

// MARK: - Settings: Help

struct HelpSettings: View {
    var body: some View {
        Section("Help") {
            HStack(spacing: 10) {
                Image(systemName: "ladybug.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Something not working?").font(.body.weight(.medium))
                    Text("Send a bug report to Bin Watch's page on GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Known Issues") { LinkOpener.open(BugReport.issuesPage) }
                Button("Report a Bug…") { Navigation.shared.showBugReport = true }
            }
        }
    }
}

// MARK: - Bug report sheet

struct BugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = BugReport()
    @State private var includeDetails = true
    @State private var details = ""
    @State private var showDetails = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a Bug").font(.title3.weight(.semibold))
                    Text("Opens GitHub with your report filled in, for you to check and post.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            field("Summary") {
                TextField("", text: $report.title, prompt: Text("e.g. Alerts stop after the Mac wakes from sleep"))
                    .textFieldStyle(.roundedBorder)
            }
            field("What happened?") { editor($report.whatHappened, height: 80) }
            field("Steps to make it happen (optional)") { editor($report.steps, height: 56) }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Include technical details", isOn: $includeDetails)
                    Spacer()
                    Button(showDetails ? "Hide" : "Show What's Included") { showDetails.toggle() }
                        .buttonStyle(.link).disabled(!includeDetails)
                }
                if showDetails && includeDetails {
                    ScrollView {
                        Text(details).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 130)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Your version of Bin Watch and macOS, how it's set up and recent connection events. Never the names of projects, bins, folders, people or computers.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label {
                Text("Reports on GitHub are public, so please don't type real project, bin or people's names. You'll need a free GitHub account to post.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye").foregroundStyle(.orange)
            }
            .font(.caption)

            HStack {
                Button(copied ? "Copied" : "Copy Report") { copy() }
                    .disabled(!report.isReady)
                    .help("Copies the whole report, to paste into GitHub or an email")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue on GitHub…") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!report.isReady)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            details = Diagnostics.collect()
            report.details = details
        }
        .onChange(of: includeDetails) { report.details = $0 ? details : nil }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout.weight(.medium))
            content()
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(report.title)\n\n\(report.body)", forType: .string)
        copied = true
    }

    private func send() {
        LinkOpener.open(report.issueLink)
        dismiss()
    }
}
