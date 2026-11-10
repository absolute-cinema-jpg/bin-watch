import CryptoKit
import Foundation

/// What Bin Watch asks its updater helper to do. The helper lives inside Bin Watch.app
/// (Contents/XPCServices/Updater.xpc) and only macOS lets Bin Watch talk to it.
@objc protocol UpdateInstalling {
    /// Checks `zip` matches `sha256`, unpacks it, makes sure it's a signed, sandboxed copy of
    /// Bin Watch at exactly `version`, then swaps it in for the running copy.
    /// Replies nil on success, or a message to show the person.
    func install(zip: FileHandle, sha256: String, version: String, reply: @escaping (String?) -> Void)
}

enum UpdateShared {
    /// The helper's XPC service name: the app's own identifier plus ".Updater".
    static func serviceName(forApp bundleID: String) -> String { bundleID + ".Updater" }

    /// SHA-256 of a file as lowercase hex, read in chunks so big downloads don't fill memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try sha256(of: handle)
    }

    static func sha256(of handle: FileHandle) throws -> String {
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True for a 64-character hex SHA-256.
    static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }
}
