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
                    if url.isFileURL { Task { await store.importItem(at: url) } }
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
