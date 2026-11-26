import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var launchAtLogin = LoginItem.isOn
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var soundError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Settings", subtitle: "Where Bin Watch looks, and how it lets you know",
                   symbol: "gearshape.fill", tint: .gray)
            Divider()
            Form {
                Section("Monitored Folder") {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").font(.title2).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.rootPath == nil ? "No folder chosen" : store.rootName)
                                .font(.body.weight(.medium))
                            if let path = store.rootPath {
                                Text(path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button(store.rootPath == nil ? "Choose…" : "Change…") { store.chooseRootViaPanel() }
                    }
                }

                Section("Alert Sound") {
                    HStack {
                        Picker("Sound", selection: $store.settings.soundName) {
                            Section("Built-in") {
                                ForEach(SoundLibrary.builtIn, id: \.self) { Text($0).tag($0) }
                            }
                            if !store.customSounds.isEmpty {
                                Section("Your Sounds") {
                                    ForEach(store.customSounds, id: \.self) {
                                        Text(SoundLibrary.displayName($0)).tag($0)
                                    }
                                }
                            }
                        }
                        .onChange(of: store.settings.soundName) { _ in AlertCenter.shared.playChime() }

                        Button {
                            AlertCenter.shared.playChime()
                        } label: { Image(systemName: "play.fill") }
                        .help("Play")
                        Button {
                            AlertCenter.shared.stopChime()
                        } label: { Image(systemName: "stop.fill") }
                        .help("Stop")
                    }

                    HStack(spacing: 10) {
                        Text("Volume")
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $store.settings.volume, in: 0.05...1) { editing in
                            if !editing { AlertCenter.shared.playChime() }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            do { try store.addSounds(); soundError = nil }
                            catch { soundError = error.localizedDescription }
                        } label: {
                            // An HStack, not a Label: macOS 13 truncates Labels inside bordered buttons.
                            HStack(spacing: 4) { Image(systemName: "plus"); Text("Add Sound") }
                        }
                        if SoundLibrary.isCustom(store.settings.soundName) {
                            Button(role: .destructive) {
                                store.removeSound(store.settings.soundName)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                    Text("Remove “\(SoundLibrary.displayName(store.settings.soundName))”")
                                }
                            }
                        }
                        Spacer()
                    }
                    if let soundError {
                        Text(soundError).font(.caption).foregroundStyle(.red)
                    }
                    Text("Any audio file works: AIFF, WAV, MP3, M4A… Bin Watch keeps its own copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Alerts") {
                    Toggle("Chime again every minute until I dismiss the alert", isOn: $store.settings.repeatChime)
                    Toggle("Stop watching a bin or script once I've clicked Show or Dismiss on its alert", isOn: $store.settings.stopWatchingAfterAlert)
                    HStack {
                        Spacer()
                        Button("Show Test Alert") { store.showTestAlert() }
                        Button("Test Several") { store.showTestAlert(count: 4) }
                    }
                }

                BinRequestsSettings()

                Section("App") {
                    Picker("Check every", selection: $store.settings.pollInterval) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                    }
                    Toggle("Show icon in the menu bar", isOn: $store.settings.showMenuBarIcon)
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Show who has a locked bin or script open", isOn: $store.settings.showLockHolders)
                        Text("Reads the name Avid writes in the lock file — once per lock, read-only. Turn off and Bin Watch never opens lock files, only checks they exist.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Picker("Flag locks older than", selection: $store.settings.leftoverLockDays) {
                            Text("2 days").tag(2)
                            Text("3 days").tag(3)
                            Text("1 week").tag(7)
                            Text("2 weeks").tag(14)
                            Text("4 weeks").tag(28)
                            Text("Never").tag(0)
                        }
                        Text("Marks them “May be left over”, e.g. after Avid crashed. Also marked: locks by this Mac when Avid isn't running, and ones whose owner says they don't have it open. Bin Watch never removes locks.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Open Bin Watch when I log in", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                    if launchAtLogin, let problem = AppLocation.current.loginProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if launchAtLogin, loginStatus == .requiresApproval {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Bin Watch is switched off in System Settings → General → Login Items, so it won't open when you log in.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .controlSize(.small)
                        }
                    }
                }

                UpdatesSettings()

                BugReportSection(report: { Navigation.shared.showBugReport = true })

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Read-only by design").font(.headline)
                            Text("Bin Watch only looks at which files exist in your monitored folder (and, if you allow it, reads the name inside a lock file). macOS grants it read-only access, so it can't create, change, move or delete anything there — even by accident. The only shared folder it writes to is the request mailbox, which can't be inside an Avid project.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
        // The person may change it in System Settings while Bin Watch is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginItem() }
        .onAppear(perform: refreshLoginItem)
    }

    private func refreshLoginItem() {
        loginStatus = SMAppService.mainApp.status
        if launchAtLogin != LoginItem.isOn { launchAtLogin = LoginItem.isOn }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
        if launchAtLogin != LoginItem.isOn { launchAtLogin = LoginItem.isOn }
    }
}

/// "Open Bin Watch when I log in", as macOS has it.
enum LoginItem {
    /// On, including when the person has switched it off in System Settings' Login Items
    /// (macOS then says it "requires approval"): they asked for it, so the switch stays on and
    /// Settings explains what's stopping it.
    static var isOn: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Why it won't actually happen at the next login, or nil if it will (or it's off).
    static var problem: String? {
        guard isOn else { return nil }
        if let problem = AppLocation.current.loginProblem { return problem }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Bin Watch is switched off in System Settings → General → Login Items."
        }
        return nil
    }
}

/// In the sidebar, when Bin Watch is set to open at login but can't, so it's noticed before
/// the next restart rather than after.
struct LoginItemSidebarCard: View {
    @State private var problem = LoginItem.problem

    var body: some View {
        Group {
            if problem != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WON'T OPEN AT LOGIN")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.orange)
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(AppLocation.current.loginProblem == nil ? "Switched off in Login Items" : "Move Bin Watch to Applications")
                            .font(.callout.weight(.medium)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    Button("Details…") { Navigation.shared.selection = .settings }
                        .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .help(problem ?? "")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            problem = LoginItem.problem
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if problem != LoginItem.problem { problem = LoginItem.problem }
        }
    }
}
