import Foundation
import iContainFFI
import SwiftUI

struct TwoFactorPrompt: Identifiable, Equatable {
    struct TrustedNumber: Identifiable, Equatable, Decodable {
        let id: UInt32
        let number: String
    }
    let id = UUID()
    let numbers: [TrustedNumber]
    let lastError: String?
    let sms: Bool
}

struct RevokePrompt: Identifiable, Equatable {
    struct Certificate: Identifiable, Equatable, Decodable {
        let serial: String
        let name: String
        let machine: String
        var id: String { serial }
    }
    let id = UUID()
    let certificates: [Certificate]
}

/// Talks to Apple through the Rust core: signing guests and account requests.
/// Prompts (2FA, certificate revocation) are published for the UI to answer.
@MainActor
final class AppleAccount: ObservableObject {
    static let shared = AppleAccount()

    enum AccountError: LocalizedError {
        case needsSignIn
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .needsSignIn: String(localized: "Sign in with your Apple ID so iContain can get a signing certificate.")
            case .failed(let message): message
            }
        }
    }

    struct Identity: Decodable, Equatable {
        let teamId: String
        let expires: Int64
        let serial: String
        var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expires)) }
    }

    @Published var twoFactor: TwoFactorPrompt?
    @Published var revoke: RevokePrompt?
    @Published var stage: String?
    @Published private(set) var identity: Identity?
    @Published var email: String = AppleIDStore.email

    /// "auto" (Automatic) or a server address, shared with AltLoad's choices.
    @Published var anisetteChoice: String = UserDefaults.standard.string(forKey: "anisette.url") ?? AnisetteServers.automatic {
        didSet { UserDefaults.standard.set(anisetteChoice, forKey: "anisette.url") }
    }

    private let session = icontain_install_session_new()

    private init() {
        reloadIdentity()
    }

    var hasSavedPassword: Bool {
        !email.isEmpty && AppleIDStore.password(for: email) != nil
    }

    func reloadIdentity() {
        guard let raw = icontain_identity_info() else { identity = nil; return }
        defer { icontain_string_free(raw) }
        identity = try? JSONDecoder().decode(Identity.self, from: Data(String(cString: raw).utf8))
    }

    func forgetIdentity() {
        icontain_identity_forget()
        reloadIdentity()
    }

    func signOut() {
        AppleIDStore.forgetAll()
        email = ""
        forgetIdentity()
    }

    func respond(_ response: String) {
        twoFactor = nil
        revoke = nil
        _ = response.withCString { icontain_install_session_respond(session, $0) }
    }

    func cancel() {
        icontain_install_session_cancel(session)
        if twoFactor != nil || revoke != nil { respond("abort") }
    }

    // MARK: - Signing

    enum SignMode: Int32 {
        case adHoc = 0
        case cached = 1
        case refresh = 2
    }

    /// Signs a prepared guest. With `.cached`, signs in only if there's no usable
    /// certificate, using `credentials` or the saved password.
    func sign(appPath: String, mode: SignMode, credentials: AppleIDCredentials? = nil) async throws {
        let creds = credentials ?? savedCredentials()
        let anisette = mode == .adHoc ? "" : await anisetteList()
        let (code, output) = await call { session, progress, prompt, ctx in
            var out: UnsafeMutablePointer<CChar>?
            let rc = icontain_sign_guest(session, appPath, mode.rawValue,
                                         creds?.email, creds?.password, anisette,
                                         progress, prompt, ctx, &out)
            return (rc, out)
        }
        switch code {
        case 0:
            if let creds { remember(creds) }
            reloadIdentity()
        case 3:
            throw AccountError.needsSignIn
        default:
            if let creds { AppleIDStore.forgetPasswordIfRejected(message: output, email: creds.email) }
            throw AccountError.failed(output.isEmpty ? String(localized: "Signing failed.") : output)
        }
    }

    // MARK: - Account requests

    /// Runs {"op":"overview"} / {"op":"set_capability",…} and returns the overview.
    func account(_ request: [String: Any], credentials: AppleIDCredentials? = nil) async throws -> [String: Any] {
        guard let creds = credentials ?? savedCredentials() else { throw AccountError.needsSignIn }
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8) ?? "{}"
        let anisette = await anisetteList()
        let (code, output) = await call { session, progress, prompt, ctx in
            var out: UnsafeMutablePointer<CChar>?
            let rc = icontain_account_session_run(session, creds.email, creds.password, anisette, json,
                                                  progress, prompt, ctx, &out)
            return (rc, out)
        }
        guard code == 0 else {
            AppleIDStore.forgetPasswordIfRejected(message: output, email: creds.email)
            throw AccountError.failed(output)
        }
        remember(creds)
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - Plumbing

    private var rememberPassword = true

    func use(_ credentials: AppleIDCredentials, remember: Bool) {
        rememberPassword = remember
        email = credentials.email
        AppleIDStore.email = credentials.email
    }

    private func remember(_ creds: AppleIDCredentials) {
        email = creds.email
        AppleIDStore.email = creds.email
        if rememberPassword { AppleIDStore.savePassword(creds.password, for: creds.email) }
    }

    private func savedCredentials() -> AppleIDCredentials? {
        guard !email.isEmpty, let password = AppleIDStore.password(for: email) else { return nil }
        return AppleIDCredentials(email: email, password: password)
    }

    private func anisetteList() async -> String {
        await AnisetteServers.shared.signInList(preferred: anisetteChoice)
    }

    private typealias Body = (OpaquePointer?, ICProgressCb, ICPromptCb, UnsafeMutableRawPointer?) -> (Int32, UnsafeMutablePointer<CChar>?)

    /// Runs a blocking FFI call off the main thread with progress and prompt callbacks.
    private func call(_ body: @escaping Body) async -> (Int32, String) {
        let box = CallbackBox(owner: self)
        let session = self.session
        let result: (Int32, String) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ctx = Unmanaged.passUnretained(box).toOpaque()
                let (rc, out) = body(session, accountProgressCallback, accountPromptCallback, ctx)
                let text = out.map { String(cString: $0) } ?? ""
                if let out { icontain_string_free(out) }
                continuation.resume(returning: (rc, text))
            }
        }
        withExtendedLifetime(box) {}
        stage = nil
        return result
    }

    fileprivate func present(kind: Int32, json: Data) {
        switch kind {
        case 1:
            let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
            let numbers = ((object["numbers"] as? [[String: Any]]) ?? []).compactMap { row -> TwoFactorPrompt.TrustedNumber? in
                guard let id = row["id"] as? Int, let number = row["number"] as? String else { return nil }
                return .init(id: UInt32(id), number: number)
            }
            twoFactor = TwoFactorPrompt(numbers: numbers,
                                        lastError: object["lastError"] as? String,
                                        sms: object["sms"] as? Bool ?? false)
        case 2:
            let certs = (try? JSONDecoder().decode([RevokePrompt.Certificate].self, from: json)) ?? []
            revoke = RevokePrompt(certificates: certs)
        default:
            respond("abort")
        }
    }
}

private final class CallbackBox: @unchecked Sendable {
    weak var owner: AppleAccount?
    init(owner: AppleAccount) { self.owner = owner }
}

private let accountProgressCallback: ICProgressCb = { ctx, stage, _ in
    guard let ctx, let stage else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    let text = String(cString: stage)
    DispatchQueue.main.async { MainActor.assumeIsolated { box.owner?.stage = text } }
}

private let accountPromptCallback: ICPromptCb = { ctx, kind, json in
    guard let ctx else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    let data = json.map { Data(String(cString: $0).utf8) } ?? Data()
    DispatchQueue.main.async { MainActor.assumeIsolated { box.owner?.present(kind: kind, json: data) } }
}
