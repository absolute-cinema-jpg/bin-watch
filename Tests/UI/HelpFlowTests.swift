import AppKit
import SwiftUI

/// Updates (with GitHub replaced by a canned answer) and the bug report sheet.
enum HelpFlowTests {
    static func run(_ store: AppStore, dir: String) {
        let updater = Updater.shared
        let snaps = ProcessInfo.processInfo.environment["SNAP_DIR"]
        let release = try! JSONDecoder().decode(GitHubRelease.self, from: Data("""
        {"tag_name": "v99.0", "name": "Bin Watch 99.0", "draft": false, "prerelease": false,
         "html_url": "https://github.com/\(UpdateLogic.repo)/releases/tag/v99.0",
         "body": "## What's new in 99.0\\n\\n**One-click updates.** Bin Watch updates itself.\\n- **Bug reports:** straight to GitHub.\\n\\n## Install or update\\n1. Download",
         "assets": [{"name": "Bin-Watch-99.0.zip", "size": 2000000, "digest": "sha256:\(String(repeating: "cd", count: 32))",
                     "browser_download_url": "https://github.com/\(UpdateLogic.repo)/releases/download/v99.0/Bin-Watch-99.0.zip"}]}
        """.utf8))
        var installing: AvailableUpdate?
        updater.installHook = { installing = $0 }

        print("Updates")
        updater.fetchRelease = { $0(.failure(.rateLimited)) }
        updater.check()
        pump(0.5)
        check(updater.phase == .failed(UpdateError.rateLimited.localizedDescription) && updater.update == nil,
              "a failed check says why, and offers nothing to install")

        updater.fetchRelease = { $0(.success(release)) }
        Navigation.shared.selection = .watching
        updater.check()
        pump(1)
        check(updater.phase == .available && updater.update?.version == "99.0", "a newer version on GitHub is noticed")
        check(updater.statusText == "Version 99.0 is available", "…and described: \(updater.statusText)")
        if let snaps { snapshot(snaps + "/update-available.png") }
        // The sidebar card's Update Now button, just above the monitored folder card.
        click(62, 473)
        pump(0.5)
        check(installing?.version == "99.0", "one click on Update Now starts installing it")

        if let snaps {
            // The Updates and Help sections on their own (they're below the fold in Settings).
            let panel = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 470),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = NSColor(white: 0.16, alpha: 1)
            panel.contentView = NSHostingView(rootView: Form { UpdatesSettings(); HelpSettings() }
                .formStyle(.grouped).environmentObject(store))
            panel.orderFrontRegardless()
            pump(1)
            snapshot(snaps + "/settings-updates.png", of: panel)
            updater.fetchRelease = { $0(.failure(.network("The Internet connection appears to be offline."))) }
            updater.check(); pump(1)
            snapshot(snaps + "/settings-check-failed.png", of: panel)
            check(!updater.installFailed, "a failed check isn't mistaken for a failed install")
            panel.orderOut(nil)
            updater.fetchRelease = { $0(.success(release)) }
            updater.check(); pump(0.5)
        }

        updater.fetchRelease = { $0(.success(try! JSONDecoder().decode(GitHubRelease.self, from: Data("""
            {"tag_name": "v0", "draft": false, "prerelease": false, "html_url": "https://github.com", "assets": []}
            """.utf8)))) }
        updater.check()
        pump(0.5)
        check(updater.phase == .upToDate && updater.update == nil, "nothing newer: up to date")

        print("Bug reports")
        let details = Diagnostics.collect()
        check(details.contains("Bin Watch ") && details.contains("macOS ") && details.contains("Monitored folder: chosen"),
              "technical details say which version and how it's set up")
        let secrets = ["Documentary", "Avid Projects", "Reel", dir, "Sam", "Edit 2", "EDIT-2", ProcessInfo.processInfo.hostName,
                       RequestCenter.shared.myName].filter { !$0.isEmpty }
        let leaked = secrets.filter { details.contains($0) }
        check(leaked.isEmpty, "…but never names of projects, bins, folders, people or computers: \(leaked)")

        var opened: [URL] = []
        LinkOpener.testHook = { opened.append($0) }
        Navigation.shared.showBugReport = true
        pump(1.5)
        let sheet = window.attachedSheet
        check(sheet != nil, "Report a Bug opens a sheet")
        if let snaps, let sheet { snapshot(snaps + "/bug-report.png", of: sheet) }
        Navigation.shared.showBugReport = false
        pump(1)
        check(window.attachedSheet == nil && opened.isEmpty, "cancelling sends nothing")

        LinkOpener.testHook = nil
        updater.installHook = nil
        updater.fetchRelease = nil
        Navigation.shared.selection = .browse
        pump(0.5)
    }
}
