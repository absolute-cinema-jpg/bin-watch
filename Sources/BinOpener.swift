import AppKit

/// "Show Bin": opens a bin in Media Composer if it's already running, otherwise shows it
/// in Finder. Bin Watch never launches Avid itself, and never touches the bin file —
/// it only asks macOS to hand the file to Avid, or to Finder.
enum BinOpener {
    static let avidBundleID = "com.avid.mediacomposer"

    /// Tests set this to see what would have been shown, without opening anything.
    static var testHook: (([URL]) -> Void)?

    static var runningAvid: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == avidBundleID }
    }

    /// One bin opens in Avid (if running). Several bins, or no Avid, are revealed in Finder.
    static func show(_ bins: [URL]) {
        guard !bins.isEmpty else { return }
        if let testHook { testHook(bins); return }
        if bins.count == 1, let avid = runningAvid, let avidURL = avid.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(bins, withApplicationAt: avidURL, configuration: config) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(bins) } }
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(bins)
        }
    }

    static var showLabel: String { runningAvid == nil ? "Show in Finder" : "Open in Avid" }
}
