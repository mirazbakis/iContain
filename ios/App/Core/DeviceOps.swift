import iContainFFI
import Foundation

/// Runs one device operation (install an app, manage provisioning profiles,
/// list apps, copy a file into an app) through the LocalDevVPN tunnel, with no
/// Apple ID involved. Backs the on-device AltServer and Tools (Pairing File to Apps,
/// JIT, Location). Operations run one at a time, except a location session, which
/// holds its tunnel open and so runs on its own queue.
enum DeviceOps {
    enum OpError: LocalizedError {
        case noPairing
        case vpnOff
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noPairing: String(localized: "There's no pairing file for this iPhone yet. Import one in Location › Whole device.")
            case .vpnOff: String(localized: "LocalDevVPN is off. Turn it on so iContain can reach this iPhone.")
            case .failed(let message): message
            }
        }
    }

    static let queue = DispatchQueue(label: "icontain.device-ops", qos: .userInitiated)
    static let longRunningQueue = DispatchQueue(label: "icontain.device-ops.long", qos: .userInitiated)

    /// `progress(stage, fraction)`; fraction is nil when indeterminate. Called on the main actor.
    @discardableResult
    static func run(
        _ request: [String: Any],
        on queue: DispatchQueue = DeviceOps.queue,
        progress: @escaping @MainActor (String, Double?) -> Void = { _, _ in }
    ) async throws -> Any {
        let pairingPath: String? = PairingFile.exists ? PairingFile.url.path : nil
        guard let pairingPath else { throw OpError.noPairing }
        guard LocalDevVPN.isActive else { throw OpError.vpnOff }

        let host = LocalDevVPN.targetIP
        let port = LocalDevVPN.remotePairingPort
        // Never take iContain's own provisioning profile off the device: AltStore's
        // list of active apps doesn't include it, and iContain would stop opening.
        var request = request
        request["protect"] = [Bundle.main.bundleIdentifier].compactMap { $0 }
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8) ?? "{}"
        let box = ProgressBox(progress)

        let (code, output): (Int32, String) = await withCheckedContinuation { continuation in
            queue.async {
                var owned: [UnsafeMutablePointer<CChar>] = []
                func c(_ s: String) -> UnsafePointer<CChar>? {
                    guard let p = strdup(s) else { return nil }
                    owned.append(p)
                    return UnsafePointer(p)
                }
                var endpoint = ICEndpoint(host: c(host), port: UInt16(clamping: port), identifier: nil, auth_tag: nil)
                var out: UnsafeMutablePointer<CChar>?
                let rc: Int32 = withUnsafePointer(to: &endpoint) { endpointPointer in
                    var config = ICInstallConfig(
                        apple_id: nil, password: nil, anisette_url: nil,
                        pairing_file_path: c(pairingPath),
                        host_name: c("iContain"),
                        endpoints: endpointPointer,
                        endpoint_count: 1,
                        ipa_path: nil, device_name: nil, machine_name: nil, server_id: nil,
                        capabilities: nil, extensions_mode: 0)
                    let ctx = Unmanaged.passUnretained(box).toOpaque()
                    return icontain_device_run(&config, json, deviceProgressCallback, ctx, &out)
                }
                let text = out.map { String(cString: $0) } ?? ""
                if let out { icontain_string_free(out) }
                owned.forEach { free($0) }
                continuation.resume(returning: (rc, text))
            }
        }
        withExtendedLifetime(box) {}

        guard code == 0 else {
            throw OpError.failed(output.isEmpty ? String(localized: "The device operation failed (code \(code)).") : output)
        }
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8), options: [.fragmentsAllowed])) ?? [:]
    }

    // MARK: - Convenience

    struct DeviceApp: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let version: String
        let fileSharing: Bool
        let debuggable: Bool
        var id: String { bundleID }
    }

    static func listApps(progress: @escaping @MainActor (String, Double?) -> Void = { _, _ in }) async throws -> [DeviceApp] {
        let result = try await run(["op": "list_apps"], progress: progress)
        let rows = result as? [[String: Any]] ?? []
        return rows.map {
            DeviceApp(
                bundleID: $0["bundleId"] as? String ?? "",
                name: ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ($0["bundleId"] as? String ?? "App"),
                version: $0["version"] as? String ?? "",
                fileSharing: $0["fileSharing"] as? Bool ?? false,
                debuggable: $0["debuggable"] as? Bool ?? false)
        }
    }

    /// Launches `bundleID` under debugserver and detaches, which leaves it able to JIT.
    /// Mounts the Developer Disk Image first if needed. Returns the app's pid.
    @discardableResult
    static func enableJIT(_ bundleID: String,
                          progress: @escaping @MainActor (String, Double?) -> Void = { _, _ in }) async throws -> Int {
        let dir = try await DeveloperDiskImage.ensureDownloaded(progress: progress)
        let result = try await run(["op": "enable_jit", "bundleId": bundleID, "ddiDir": dir.path], progress: progress)
        return (result as? [String: Any])?["pid"] as? Int ?? 0
    }

    /// Copies a local file into an installed app's container at `name`
    /// (e.g. "Documents/PairingFile_RemoteRP.plist").
    static func placeFile(_ source: URL, in bundleID: String, as name: String,
                          progress: @escaping @MainActor (String, Double?) -> Void = { _, _ in }) async throws {
        try await run(["op": "place_file", "bundleId": bundleID, "source": source.path, "name": name], progress: progress)
    }
}

extension DeviceOps {
    /// Sets keys in a plist inside an app's container and keeps the rest of it.
    static func mergePreferences(_ values: [String: Any], in bundleID: String, at path: String) async throws {
        try await run(["op": "merge_plist", "bundleId": bundleID, "name": path, "values": values])
    }

    /// This iPhone's UDID, as it reports it over the tunnel.
    static func deviceUDID() async throws -> String {
        let result = try await run(["op": "device_udid"])
        guard let udid = (result as? [String: Any])?["udid"] as? String, !udid.isEmpty else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return udid
    }
}

private final class ProgressBox: @unchecked Sendable {
    let handler: @MainActor (String, Double?) -> Void
    init(_ handler: @escaping @MainActor (String, Double?) -> Void) { self.handler = handler }
}

private let deviceProgressCallback: ICProgressCb = { ctx, stage, fraction in
    guard let ctx, let stage else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
    let text = String(cString: stage)
    let value: Double? = fraction < 0 ? nil : fraction
    DispatchQueue.main.async {
        MainActor.assumeIsolated { box.handler(text, value) }
    }
}
