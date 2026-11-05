import SwiftUI

struct iContainApp: App {
    @StateObject private var store = GuestStore.shared
    @StateObject private var account = AppleAccount.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(account)
                .onOpenURL { url in
                    // "Open in iContain" from Files or Safari hands over the file.
                    if url.isFileURL { Task { await store.importItem(at: url) }; return }
                    Task { await store.handle(url) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: GuestStore
    @EnvironmentObject private var account: AppleAccount

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
            LocationView()
                .tabItem { Label("Location", systemImage: "location.fill") }
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task {
            // Same as the icontain:// links, for scripted testing:
            //   --import-inbox, --open <app name or id>
            let args = CommandLine.arguments
            if args.contains("--import-inbox") { await store.handle(URL(string: "icontain://import-inbox")!) }
            if let i = args.firstIndex(of: "--open"), i + 1 < args.count,
               let url = URL(string: "icontain://open?app=\(args[i + 1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                await store.handle(url)
            }
        }
        .sheet(item: $account.twoFactor) { prompt in
            TwoFactorSheet(prompt: prompt)
        }
        .sheet(item: $account.revoke) { prompt in
            RevokeSheet(prompt: prompt)
        }
        .sheet(item: $store.awaitingSignIn) { guest in
            SignInSheet(reason: "\(guest.name) needs to be signed. Sign in with your Apple ID so iContain can get a certificate.") { credentials in
                Task { await store.continueSigning(with: credentials) }
            }
        }
        .alert("Couldn't open the app", isPresented: Binding(get: { store.launchError != nil }, set: { if !$0 { store.launchError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.launchError ?? "")
        }
    }
}
