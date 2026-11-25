import Foundation

/// Where this copy of Bin Watch is running from. macOS opens login items from the place they
/// were turned on, so a copy on an external or network drive, or a temporary copy macOS made,
/// may not be there (or not yet) when you log in.
enum AppLocation: Equatable {
    /// /Applications or ~/Applications.
    case applications
    /// Somewhere else on this Mac's own disk (e.g. Downloads, once moved there by Finder).
    case otherFolder
    /// An external or network drive, by its name.
    case otherVolume(name: String, network: Bool)
    /// A hidden, read-only copy macOS runs when an app is opened straight from where it was
    /// downloaded or unzipped ("App Translocation"). It's gone after a restart.
    case temporaryCopy

    static func classify(path: String, home: String, volumeName: String?, onStartupDisk: Bool, isLocal: Bool) -> AppLocation {
        if path.contains("/AppTranslocation/") { return .temporaryCopy }
        if !onStartupDisk { return .otherVolume(name: volumeName ?? "another drive", network: !isLocal) }
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        return .otherFolder
    }

    /// Where the running copy is.
    static var current: AppLocation {
        let app = Bundle.main.bundleURL
        let values = try? app.resourceValues(forKeys: [.volumeURLKey, .volumeLocalizedNameKey, .volumeIsLocalKey])
        return classify(path: app.path, home: realHome,
                        volumeName: values?.volumeLocalizedName,
                        onStartupDisk: (values?.volume?.path ?? "/") == "/",
                        isLocal: values?.volumeIsLocal ?? true)
    }

    /// The person's real home folder (in the App Sandbox, NSHomeDirectory is the container).
    static var realHome: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    /// Why "Open Bin Watch when I log in" won't work from here, or nil if it should.
    var loginProblem: String? {
        switch self {
        case .applications, .otherFolder:
            return nil
        case .temporaryCopy:
            return "Bin Watch is running from a temporary copy that macOS made because it was opened straight from where it was downloaded or unzipped. That copy is gone after a restart, so it can't open when you log in. Quit Bin Watch, drag it into your Applications folder and open it from there, then turn this on again."
        case .otherVolume(let name, let network):
            return "Bin Watch is on “\(name)”, not this Mac's own disk. When you log in, that \(network ? "network volume" : "drive") usually isn't connected yet, so macOS can't open Bin Watch. Quit Bin Watch, drag it into your Applications folder and open it from there, then turn this on again."
        }
    }

    /// For bug reports: the kind of place, never its name.
    var summary: String {
        switch self {
        case .applications: return "Applications"
        case .otherFolder: return "a folder on this Mac"
        case .otherVolume(_, let network): return network ? "a network volume" : "an external drive"
        case .temporaryCopy: return "a temporary copy (not moved after downloading)"
        }
    }
}
