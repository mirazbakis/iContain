import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: GuestStore
    @State private var confirmEraseAll = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        Image("AppIconPreview")
                            .resizable()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Text("iContain").font(.title2.weight(.bold)).foregroundStyle(.white)
                        Text("Version \(version)").font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 8)

                    Panel(title: "How it works", symbol: "shippingbox") {
                        Text("iContain loads an imported app's code into its own process, with its own data folder, instead of installing it on iOS. Builds made for the iOS Simulator are converted to run on the device first. Apps are signed with your Apple ID's development certificate, so they don't use up App IDs.")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                        Text("Some things don't work inside iContain yet: app extensions and widgets, the Keychain for some apps, push notifications, and running two apps at once.")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                    }

                    Panel(title: "Storage", symbol: "internaldrive") {
                        DetailRow(title: "Apps", value: "\(store.guests.count)")
                        DetailRow(title: "Used", value: (GuestStore.folderSize(GuestStore.support) ?? 0).byteString)
                        Button("Delete All Apps and Data") { confirmEraseAll = true }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .foregroundStyle(Theme.danger)
                            .disabled(store.guests.isEmpty)
                    }

                    Panel(title: "Device link", symbol: "network") {
                        Button("Delete Pairing File") { PairingFile.remove() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .disabled(!PairingFile.exists)
                        Button("Delete Developer Disk Image") { DeveloperDiskImage.remove() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }

                    Panel(title: "Open source", symbol: "chevron.left.forwardslash.chevron.right") {
                        Text("iContain is MIT-licensed. It's built with idevice by Jackson Coxson and isideload by nab138 (both MIT), and apple-codesign-quick (LGPL-2.1-or-later).")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete every app in iContain and everything they saved?", isPresented: $confirmEraseAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    for guest in store.guests { store.delete(guest) }
                }
            }
            .slateScreen()
        }
    }
}
