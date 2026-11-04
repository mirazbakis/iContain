import CoreLocation
import Foundation
import iContainFFI
import UIKit
import UserNotifications

/// An app imported into iContain. Paths are stored relative to Application Support,
/// because iOS moves the app's container when iContain is reinstalled or updated.
struct Guest: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleID: String
    var version: String
    var build: String
    /// "ios", "simulator" or "unknown": what the import was built for.
    var builtFor: String
    var minimumOS: String
    var appFolder: String
    var iconFile: String?
    var importedAt: Date
    var signedExpires: Date?
    var lastLaunched: Date?
    /// Simulated location for this app, or nil for its real location.
    var location: SpoofedLocation?
    var sizeBytes: Int64?

    var isSimulatorBuild: Bool { builtFor == "simulator" }
}

struct SpoofedLocation: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitude: Double = 0
    var label: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

@MainActor
final class GuestStore: ObservableObject {
    static let shared = GuestStore()

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var guests: [Guest] = []
    @Published var phase: Phase = .idle
    /// A guest that needs an Apple ID sign-in before it can be signed.
    @Published var awaitingSignIn: Guest?
    /// Shown once after a launch that fell back to iContain.
    @Published var launchError: String?
    /// Importable files dropped into iContain's folder in the Files app.
    @Published private(set) var inbox: [URL] = []

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: - Folders

    static var support: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iContain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { support.appendingPathComponent("guests.json") }
    static func guestFolder(_ id: String) -> URL { support.appendingPathComponent("Guests/\(id)", isDirectory: true) }
    static func dataFolder(_ id: String) -> URL { support.appendingPathComponent("Data/\(id)", isDirectory: true) }

    func appURL(_ guest: Guest) -> URL { Self.support.appendingPathComponent(guest.appFolder, isDirectory: true) }

    func iconImage(_ guest: Guest) -> UIImage? {
        guard let icon = guest.iconFile else { return nil }
        return UIImage(contentsOfFile: Self.support.appendingPathComponent(icon).path)
    }

    private init() {
        load()
        let errorFile = URL(fileURLWithPath: ICLaunchRequestPath())
            .deletingLastPathComponent().appendingPathComponent("last-error.txt")
        if let text = try? String(contentsOf: errorFile, encoding: .utf8), !text.isEmpty {
            launchError = text
            try? FileManager.default.removeItem(at: errorFile)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([Guest].self, from: data) else { return }
        guests = decoded.filter { FileManager.default.fileExists(atPath: appURL($0).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(guests) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    func update(_ guest: Guest) {
        guard let index = guests.firstIndex(where: { $0.id == guest.id }) else { return }
        guests[index] = guest
        save()
    }

    // MARK: - Import

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func refreshInbox() {
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: nil)) ?? []
        inbox = items
            .filter { ["ipa", "zip", "xcarchive", "app"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Imports a file from iContain's folder, then removes it from there.
    func importFromInbox(_ url: URL) async {
        await importItem(at: url)
        if case .failed = phase {} else { try? FileManager.default.removeItem(at: url) }
        refreshInbox()
    }

    /// Imports an .ipa, .zip, .app or .xcarchive, then signs it.
    func importItem(at source: URL) async {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        phase = .working(String(localized: "Unpacking \(source.lastPathComponent)…"))
        let id = UUID().uuidString
        let folder = Self.guestFolder(id)
        let platform: UInt32 = Self.isSimulator ? 7 : 2

        let (code, output): (Int32, String) = await Task.detached(priority: .userInitiated) {
            var out: UnsafeMutablePointer<CChar>?
            let rc = icontain_prepare_guest(source.path, folder.path, platform, &out)
            let text = out.map { String(cString: $0) } ?? ""
            if let out { icontain_string_free(out) }
            return (rc, text)
        }.value

        guard code == 0,
              let info = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let appPath = info["appPath"] as? String else {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed(output.isEmpty ? String(localized: "Import failed.") : output)
            return
        }

        let appURL = URL(fileURLWithPath: appPath)
        let relative = "Guests/\(id)/\(appURL.lastPathComponent)"
        var guest = Guest(
            id: id,
            name: info["name"] as? String ?? appURL.deletingPathExtension().lastPathComponent,
            bundleID: info["bundleId"] as? String ?? "",
            version: info["version"] as? String ?? "",
            build: info["build"] as? String ?? "",
            builtFor: info["platform"] as? String ?? "unknown",
            minimumOS: info["minimumOS"] as? String ?? "",
            appFolder: relative,
            iconFile: Self.copyIcon(from: appURL, into: folder, relativeTo: "Guests/\(id)"),
            importedAt: .now,
            sizeBytes: Self.folderSize(appURL))
        guests.insert(guest, at: 0)
        save()

        await sign(&guest)
    }

    /// Signs (or re-signs) a guest so iOS will load it.
    func resign(_ guest: Guest, refreshingCertificate: Bool = false) async {
        var guest = guest
        await sign(&guest, mode: refreshingCertificate ? .refresh : .cached)
    }

    private func sign(_ guest: inout Guest, mode: AppleAccount.SignMode = .cached, credentials: AppleIDCredentials? = nil) async {
        phase = .working(String(localized: "Signing \(guest.name)…"))
        let effectiveMode: AppleAccount.SignMode = Self.isSimulator ? .adHoc : mode
        do {
            try await AppleAccount.shared.sign(appPath: appURL(guest).path, mode: effectiveMode, credentials: credentials)
            guest.signedExpires = Self.isSimulator ? nil : AppleAccount.shared.identity?.expiryDate
            update(guest)
            phase = .idle
        } catch AppleAccount.AccountError.needsSignIn {
            awaitingSignIn = guest
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Called by the sign-in sheet for `awaitingSignIn`.
    func continueSigning(with credentials: AppleIDCredentials) async {
        guard var guest = awaitingSignIn else { return }
        awaitingSignIn = nil
        await sign(&guest, mode: .cached, credentials: credentials)
    }

    func delete(_ guest: Guest, keepData: Bool = false) {
        try? FileManager.default.removeItem(at: Self.guestFolder(guest.id))
        if !keepData { try? FileManager.default.removeItem(at: Self.dataFolder(guest.id)) }
        guests.removeAll { $0.id == guest.id }
        save()
    }

    func resetData(_ guest: Guest) {
        try? FileManager.default.removeItem(at: Self.dataFolder(guest.id))
    }

    func dataSize(_ guest: Guest) -> Int64 { Self.folderSize(Self.dataFolder(guest.id)) ?? 0 }

    // MARK: - Launch

    /// Writes the launch request, then relaunches iContain into the guest: opening our
    /// own URL while exiting makes iOS start iContain again to deliver it, and main()
    /// finds the request before any UI starts.
    func launch(_ guest: Guest) {
        if !Self.isSimulator, let expires = guest.signedExpires, expires < .now {
            phase = .failed(String(localized: "\(guest.name)'s signature has expired. Re-sign it first."))
            return
        }
        var request: [String: Any] = [
            "appPath": "Library/Application Support/iContain/\(guest.appFolder)",
            "dataPath": "Library/Application Support/iContain/Data/\(guest.id)",
            "bundleId": guest.bundleID,
        ]
        if let location = guest.location {
            request["location"] = ["latitude": location.latitude, "longitude": location.longitude, "altitude": location.altitude]
        }
        let requestURL = URL(fileURLWithPath: ICLaunchRequestPath())
        try? FileManager.default.createDirectory(at: requestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (request as NSDictionary).write(to: requestURL, atomically: true) else {
            phase = .failed(String(localized: "Couldn't prepare the launch."))
            return
        }
        var updated = guest
        updated.lastLaunched = .now
        update(updated)

        // iOS won't restart an app that exits, so iContain steps aside and a
        // notification (or the Home Screen icon) starts it again, straight into the app.
        phase = .working(String(localized: "Opening \(guest.name)…"))
        let name = guest.name
        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "\(name) is ready")
                content.body = String(localized: "Tap to open it in iContain.")
                content.threadIdentifier = "icontain.launch"
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "icontain.launch", content: content, trigger: trigger))
            }
            UIControl().sendAction(NSSelectorFromString("suspend"), to: UIApplication.shared, for: nil)
            try? await Task.sleep(for: .milliseconds(400))
            exit(0)
        }
    }

    // MARK: - Helpers

    /// Copies the biggest app icon PNG next to the app so the library can show it.
    private static func copyIcon(from app: URL, into folder: URL, relativeTo base: String) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any] else { return nil }
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += primary["CFBundleIconFiles"] as? [String] ?? []
                if let name = primary["CFBundleIconName"] as? String { names.append(name) }
            }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        let candidates = files.filter { file in
            file.lowercased().hasSuffix(".png") && names.contains { !$0.isEmpty && file.hasPrefix($0) }
        }
        let best = candidates.max { a, b in
            let sa = (try? FileManager.default.attributesOfItem(atPath: app.appendingPathComponent(a).path)[.size] as? Int) ?? 0
            let sb = (try? FileManager.default.attributesOfItem(atPath: app.appendingPathComponent(b).path)[.size] as? Int) ?? 0
            return sa < sb
        }
        guard let best,
              let image = UIImage(contentsOfFile: app.appendingPathComponent(best).path),
              let png = image.pngData() else { return nil }
        let destination = folder.appendingPathComponent("icon.png")
        guard (try? png.write(to: destination)) != nil else { return nil }
        return "\(base)/icon.png"
    }

    static func folderSize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
