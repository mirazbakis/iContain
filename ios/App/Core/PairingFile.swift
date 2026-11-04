import Foundation

/// This iPhone's RemotePairing file (rp_pairing_file.plist), made once on a computer
/// with idevice_pair or iloader, or exported from AltLoad. Device-wide location
/// simulation uses it to reach the iPhone's own services through LocalDevVPN.
enum PairingFile {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iContain/pairing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rp_pairing_file.plist")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Copies a picked file in after checking it's a property list.
    static func importFile(at source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        try data.write(to: url, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
