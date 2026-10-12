import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
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
                    Toggle("Open Bin Watch when I log in", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Read-only by design").font(.headline)
                            Text("Bin Watch only looks at which files exist in your monitored folder. macOS grants it read-only access, so it can't create, change, move or delete anything there — even by accident. The only shared folder it writes to is the request mailbox, which can't be inside an Avid project.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
