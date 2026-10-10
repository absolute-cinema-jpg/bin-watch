import Foundation
import SwiftUI

struct WatchedBin: Codable, Identifiable, Hashable {
    var id = UUID()
    var relativePath: String  // relative to the monitored folder, e.g. "Doc S1/Reels/Reel 1.avb"

    var fileName: String { (relativePath as NSString).lastPathComponent }
    var name: String { (fileName as NSString).deletingPathExtension }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

/// Turns "Doc S1/Reels" into "Doc S1 › Reels".
func displayPath(_ relative: String, root: String = "") -> String {
    let parts = relative.split(separator: "/").map(String.init)
    if parts.isEmpty { return root }
    return parts.joined(separator: "  ›  ")
}

enum BrowseMode: String, Codable, CaseIterable {
    case icons, list, columns

    var symbol: String {
        switch self {
        case .icons:   return "square.grid.2x2"
        case .list:    return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        }
    }

    var title: String {
        switch self {
        case .icons:   return "as Icons"
        case .list:    return "as List"
        case .columns: return "in Columns"
        }
    }
}

struct AppSettings: Codable, Equatable {
    static let currentVersion = 2

    var version = AppSettings.currentVersion
    var soundName = "Glass"
    var volume: Double = 0.8
    var repeatChime = true
    var stopWatchingAfterAlert = true
    var pollInterval: Double = 2
    var showMenuBarIcon = true
    var browseMode = BrowseMode.list

    init() {}

    // Tolerant decoding, so adding settings in future versions never resets yours.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        let savedVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? d.soundName
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        repeatChime = try c.decodeIfPresent(Bool.self, forKey: .repeatChime) ?? d.repeatChime
        stopWatchingAfterAlert = try c.decodeIfPresent(Bool.self, forKey: .stopWatchingAfterAlert) ?? d.stopWatchingAfterAlert
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? d.pollInterval
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
        browseMode = try c.decodeIfPresent(BrowseMode.self, forKey: .browseMode) ?? d.browseMode
        // Version 2: "Got it" also stops watching, by default.
        if savedVersion < 2 { stopWatchingAfterAlert = true }
        version = AppSettings.currentVersion
    }
}

extension BinState {
    var title: String {
        switch self {
        case .checking:  return "Checking…"
        case .locked:    return "Locked"
        case .available: return "Available"
        case .missing:   return "Not found"
        case .offline:   return "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .checking:  return "ellipsis.circle"
        case .locked:    return "lock.fill"
        case .available: return "lock.open.fill"
        case .missing:   return "questionmark.folder"
        case .offline:   return "externaldrive.badge.xmark"
        }
    }

    var color: Color {
        switch self {
        case .locked:    return .orange
        case .available: return .green
        default:         return .secondary
        }
    }
}
