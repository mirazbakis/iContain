import SwiftUI

/// One App ID on the team, for the More RAM list.
struct TeamAppID: Identifiable, Hashable {
    let identifier: String
    let name: String
    let features: [String: Any]
    var id: String { identifier }

    static func == (a: TeamAppID, b: TeamAppID) -> Bool { a.identifier == b.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}

/// GetMoreRam's capabilities: the two a free account can switch on to let apps use
/// more memory.
enum MemoryCapability: String, CaseIterable, Identifiable {
    case increasedMemory = "INCREASED_MEMORY_LIMIT"
    case extendedAddressing = "EXTENDED_VIRTUAL_ADDRESSING"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .increasedMemory: "More RAM"
        case .extendedAddressing: "Extended addressing"
        }
    }

    /// Words Apple's App ID feature keys use for this capability.
    fileprivate var featureHints: [String] {
        switch self {
        case .increasedMemory: ["increasedmemory", "increased-memory", "memorylimit"]
        case .extendedAddressing: ["extendedvirtual", "extended-virtual", "virtualaddressing"]
        }
    }
}

@MainActor
final class MoreRAM: ObservableObject {
    static let shared = MoreRAM()

    @Published var appIDs: [TeamAppID] = []
    @Published var busy: String?
    @Published var error: String?
    @Published var teamName: String?

    /// What iContain switched on, by App ID. Apple's own App ID listing doesn't name
    /// these capabilities consistently, so this is the fallback.
    @Published private var switched: [String: [String]] = UserDefaults.standard.dictionary(forKey: "moreRAM.switched") as? [String: [String]] ?? [:] {
        didSet { UserDefaults.standard.set(switched, forKey: "moreRAM.switched") }
    }

    func isOn(_ capability: MemoryCapability, for appID: TeamAppID) -> Bool {
        if let mine = switched[appID.identifier] { return mine.contains(capability.rawValue) }
        return appID.features.contains { key, value in
            let k = key.lowercased()
            return capability.featureHints.contains { k.contains($0) } && ((value as? Bool) == true || (value as? Int) == 1)
        }
    }

    func load(credentials: AppleIDCredentials? = nil) async {
        await run(["op": "overview"], stage: String(localized: "Loading App IDs…"), credentials: credentials)
    }

    func set(_ capability: MemoryCapability, on: Bool, for appID: TeamAppID) async {
        let ok = await run(["op": "set_capability", "identifiers": [appID.identifier], "capability": capability.rawValue, "enabled": on],
                           stage: String(localized: "Updating \(appID.name)…"))
        if ok {
            var list = Set(switched[appID.identifier] ?? MemoryCapability.allCases.filter { isOn($0, for: appID) }.map(\.rawValue))
            if on { list.insert(capability.rawValue) } else { list.remove(capability.rawValue) }
            switched[appID.identifier] = Array(list)
        }
    }

    @discardableResult
    private func run(_ request: [String: Any], stage: String, credentials: AppleIDCredentials? = nil) async -> Bool {
        busy = stage
        error = nil
        defer { busy = nil }
        do {
            let overview = try await AppleAccount.shared.account(request, credentials: credentials)
            teamName = (overview["team"] as? [String: Any])?["name"] as? String
            let items = ((overview["appIds"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            appIDs = items.compactMap { row in
                guard let identifier = row["identifier"] as? String else { return nil }
                return TeamAppID(identifier: identifier,
                                 name: row["name"] as? String ?? identifier,
                                 features: row["features"] as? [String: Any] ?? [:])
            }
            .sorted { lhs, rhs in
                // iContain's own App ID first: it decides how much memory every app inside gets.
                let mine = Bundle.main.bundleIdentifier ?? "~"
                if lhs.identifier.hasPrefix(mine) != rhs.identifier.hasPrefix(mine) { return lhs.identifier.hasPrefix(mine) }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var account: AppleAccount
    @EnvironmentObject private var store: GuestStore
    @StateObject private var anisette = AnisetteServers.shared
    @StateObject private var ram = MoreRAM.shared
    @State private var signingIn = false
    @State private var afterSignIn: ((AppleIDCredentials) -> Void)?
    @State private var customAnisette = ""
    @State private var anisetteMenu = ""
    @State private var anisetteReset = false
    private static let customTag = "custom"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    appleIDPanel
                    certificatePanel
                    moreRAMPanel
                    anisettePanel
                }
                .padding(16)
            }
            .navigationTitle("Account")
            .task {
                await anisette.refresh()
                syncAnisetteMenu()
            }
            .sheet(isPresented: $signingIn) {
                SignInSheet { credentials in afterSignIn?(credentials) }
            }
            .slateScreen()
        }
    }

    private func signIn(then action: @escaping (AppleIDCredentials) -> Void) {
        afterSignIn = action
        signingIn = true
    }

    // MARK: Apple ID

    private var appleIDPanel: some View {
        Panel(title: "Apple ID", symbol: "person.crop.circle") {
            if account.email.isEmpty {
                Text("Sign in so iContain can get a development certificate for the apps you import. A free Apple ID works.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
                Button("Sign In") { signIn { _ in Task { await ram.load() } } }
                    .buttonStyle(PillButtonStyle())
            } else {
                DetailRow(title: "Apple ID", value: account.email)
                DetailRow(title: "Password", value: account.hasSavedPassword ? String(localized: "Saved in Keychain") : String(localized: "Not saved"))
                if let team = ram.teamName { DetailRow(title: "Team", value: team) }
                HStack(spacing: 10) {
                    if !account.hasSavedPassword {
                        Button("Sign In Again") { signIn { _ in Task { await ram.load() } } }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    Button("Sign Out") { account.signOut(); ram.appIDs = [] }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            if let stage = account.stage {
                HStack(spacing: 8) { ProgressView(); Text(stage).font(.caption).foregroundStyle(Theme.secondary) }
            }
        }
    }

    // MARK: Certificate

    private var certificatePanel: some View {
        Panel(title: "Signing Certificate", symbol: "signature") {
            if GuestStore.isSimulator {
                Text("In the Simulator, apps are signed ad hoc and no certificate is needed.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            } else if let identity = account.identity {
                DetailRow(title: "Team ID", value: identity.teamId, monospaced: true)
                DetailRow(title: "Expires", value: identity.expiryDate.formatted(date: .abbreviated, time: .omitted))
                DetailRow(title: "Serial", value: identity.serial, monospaced: true)
                Text("Apps in iContain are signed with this certificate, which must belong to the same team as iContain itself.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    Button("Re-sign All Apps") {
                        Task { for guest in store.guests { await store.resign(guest) } }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    Button("Forget") { account.forgetIdentity() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            } else {
                Text("No certificate yet. iContain gets one from your Apple ID the first time it signs an app.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: GetMoreRam

    private var moreRAMPanel: some View {
        Panel(title: "More RAM", symbol: "memorychip") {
            Text("Switch on the Increased Memory Limit for your App IDs, so iOS lets those apps use more RAM before closing them. Turn it on for iContain to give every app inside it more memory. Afterwards, refresh the app with the tool that installed it (AltLoad, AltStore or SideStore) so its new profile includes it.")
                .font(.footnote).foregroundStyle(Theme.secondary)

            if let busy = ram.busy {
                HStack(spacing: 8) { ProgressView(); Text(busy).font(.subheadline).foregroundStyle(.white) }
            }
            if let error = ram.error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger).textSelection(.enabled)
            }

            if ram.appIDs.isEmpty {
                Button("Load My App IDs") {
                    if account.hasSavedPassword {
                        Task { await ram.load() }
                    } else {
                        signIn { credentials in Task { await ram.load(credentials: credentials) } }
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(ram.busy != nil)
            } else {
                ForEach(ram.appIDs) { appID in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(appID.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Text(appID.identifier).font(.caption2.monospaced()).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                            if appID.identifier.hasPrefix(Bundle.main.bundleIdentifier ?? "~") {
                                Text("iContain").font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .glassSurface(Capsule(), tint: Theme.accent)
                            }
                        }
                        ForEach(MemoryCapability.allCases) { capability in
                            Toggle(isOn: Binding(
                                get: { ram.isOn(capability, for: appID) },
                                set: { on in Task { await ram.set(capability, on: on, for: appID) } })) {
                                Text(capability.title).font(.subheadline).foregroundStyle(.white)
                            }
                            .disabled(ram.busy != nil)
                        }
                    }
                    .padding(12)
                    .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Button("Reload") { Task { await ram.load() } }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .disabled(ram.busy != nil)
            }
        }
    }

    // MARK: Anisette

    private var anisettePanel: some View {
        Panel(title: "Anisette", symbol: "server.rack") {
            HStack {
                Text("Server").foregroundStyle(Theme.secondary)
                if anisette.isLoading { ProgressView() }
                Spacer()
                Picker("Server", selection: $anisetteMenu) {
                    Text("Automatic").tag(AnisetteServers.automatic)
                    Divider()
                    ForEach(anisette.servers) { server in
                        Text(server.name).tag(server.address)
                    }
                    Text("Custom…").tag(Self.customTag)
                }
                .pickerStyle(.menu)
            }
            .onChange(of: anisetteMenu) { _, choice in
                if choice != Self.customTag && !choice.isEmpty { account.anisetteChoice = choice }
            }

            if anisetteMenu == Self.customTag {
                TextField("https://…", text: $customAnisette)
                    .font(.footnote.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        let value = customAnisette.trimmingCharacters(in: .whitespaces)
                        if value.lowercased().hasPrefix("https://") { account.anisetteChoice = value }
                    }
                    .padding(12)
                    .glassSurface(Capsule(), interactive: true)
            } else if anisetteMenu != AnisetteServers.automatic {
                DetailRow(title: "Address", value: account.anisetteChoice, monospaced: true)
            }

            Text(anisetteMenu == AnisetteServers.automatic
                 ? String(localized: "Automatic checks which servers answer and tries them in order, moving on when Apple refuses one. The same list AltLoad uses.")
                 : String(localized: "This server is tried first. Others are tried if Apple refuses its data."))
                .font(.caption).foregroundStyle(Theme.secondary)

            Button(anisetteReset ? "Anisette Data Reset" : "Reset Anisette Data") {
                AnisetteServers.resetProvisioning()
                anisetteReset = true
            }
            .buttonStyle(PillButtonStyle(prominent: false))
            .disabled(anisetteReset)
        }
    }

    private func syncAnisetteMenu() {
        let choice = account.anisetteChoice
        if choice == AnisetteServers.automatic || anisette.servers.contains(where: { $0.address == choice }) {
            anisetteMenu = choice
        } else {
            customAnisette = choice
            anisetteMenu = Self.customTag
        }
    }
}
