import AppKit
import UniformTypeIdentifiers

/// Alert sounds: the macOS built-ins plus any audio files you add.
///
/// Added sounds are *copied* into Bin Watch's own private folder (inside its
/// sandbox container), so the original file is never touched. This is the only
/// place Bin Watch writes files, and it refuses to write anywhere else.
enum SoundLibrary {
    static let builtIn = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Pop", "Tink", "Bottle", "Blow", "Morse"]
    private static let customPrefix = "custom:"

    /// ~/Library/Containers/local.binwatch.BinWatch/Data/Library/Application Support/Sounds
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sounds", isDirectory: true)
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix(customPrefix) }

    static func displayName(_ id: String) -> String {
        guard isCustom(id) else { return id }
        return (String(id.dropFirst(customPrefix.count)) as NSString).deletingPathExtension
    }

    /// IDs of the sounds you've added, sorted by name.
    static func customSounds() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { customPrefix + $0 }
    }

    static func sound(_ id: String) -> NSSound? {
        if isCustom(id) {
            let url = folder.appendingPathComponent(String(id.dropFirst(customPrefix.count)))
            return NSSound(contentsOf: url, byReference: false)
        }
        return (NSSound(named: NSSound.Name(id))?.copy() as? NSSound)
    }

    enum ImportError: LocalizedError {
        case unplayable
        var errorDescription: String? { "That file isn't a sound macOS can play." }
    }

    /// Lets you pick audio files and copies them into the library. Returns the ID of the last one added.
    static func importViaPanel() throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "Add Alert Sounds"
        panel.message = "Choose audio files to use as alert sounds. Bin Watch keeps its own copy, so the originals aren't touched."
        panel.prompt = "Add Sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }

        var last: String?
        for url in panel.urls {
            guard NSSound(contentsOf: url, byReference: true) != nil else { throw ImportError.unplayable }
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: url.lastPathComponent)
            try ensureInsideLibrary(destination)
            try fm.copyItem(at: url, to: destination)
            last = customPrefix + destination.lastPathComponent
        }
        return last
    }

    /// Removes a sound you added (only ever from Bin Watch's own sound folder).
    static func remove(_ id: String) {
        guard isCustom(id) else { return }
        let url = folder.appendingPathComponent(String(id.dropFirst(customPrefix.count)))
        guard (try? ensureInsideLibrary(url)) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func uniqueDestination(for fileName: String) -> URL {
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }

    private struct OutsideLibrary: Error {}

    /// Hard guard: refuse any path that isn't directly inside our own sound folder.
    private static func ensureInsideLibrary(_ url: URL) throws {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        guard parent == folder.standardizedFileURL.path,
              !url.lastPathComponent.contains("/"), url.lastPathComponent != ".."
        else { throw OutsideLibrary() }
    }
}
