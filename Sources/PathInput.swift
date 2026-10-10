import Foundation

/// Turns a typed or pasted path into a location inside the monitored folder.
enum PathInput {
    struct Target: Equatable {
        let folder: String        // relative to the monitored folder ("" = the folder itself)
        let bin: String?          // relative path of a bin, if the path pointed at one
    }

    enum Problem: Error, Equatable {
        case empty
        case outsideRoot
    }

    /// `rootPath` is the monitored folder's absolute path, e.g. "/Volumes/Project".
    static func resolve(_ input: String, rootPath: String) -> Result<Target, Problem> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip quotes added by "Copy as Pathname" in some apps, or by hand.
        for quote in ["\"", "'"] where text.hasPrefix(quote) && text.hasSuffix(quote) && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.lowercased().hasPrefix("file://"), let url = URL(string: text) { text = url.path }
        text = text.replacingOccurrences(of: "\\ ", with: " ")   // paths dragged into Terminal
        text = text.replacingOccurrences(of: "\\", with: "/")     // Windows-style separators
        guard !text.isEmpty else { return .failure(.empty) }

        var parts = components(text)
        let rootParts = components(rootPath)

        if text.hasPrefix("/") {
            guard parts.count >= rootParts.count,
                  zip(parts, rootParts).enumerated().allSatisfy({ same($1.0, $1.1, isVolume: $0 == 1 && rootParts.first == "Volumes") })
            else { return .failure(.outsideRoot) }
            parts.removeFirst(rootParts.count)
        } else if let first = parts.first, let rootName = rootParts.last, same(first, rootName, isVolume: false) {
            parts.removeFirst()      // "Avid Projects/Doc S1" when the root is ".../Avid Projects"
        }

        if let last = parts.last, ["avb", "avp", "lck", "avs"].contains((last as NSString).pathExtension.lowercased()) {
            let file = parts.removeLast()
            let folder = parts.joined(separator: "/")
            let isBin = (file as NSString).pathExtension.lowercased() == "avb"
            return .success(Target(folder: folder, bin: isBin ? (folder.isEmpty ? file : folder + "/" + file) : nil))
        }
        return .success(Target(folder: parts.joined(separator: "/"), bin: nil))
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
    }

    /// Case-insensitive, Unicode-normalised. Volume names also match their "-1"
    /// remount twins ("Project" vs "Project-1").
    private static func same(_ a: String, _ b: String, isVolume: Bool) -> Bool {
        func norm(_ s: String) -> String {
            var s = s.precomposedStringWithCanonicalMapping.lowercased()
            if isVolume, let r = s.range(of: #"-\d+$"#, options: .regularExpression) { s.removeSubrange(r) }
            return s
        }
        return norm(a) == norm(b)
    }
}
