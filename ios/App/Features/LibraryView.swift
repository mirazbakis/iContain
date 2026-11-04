import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: GuestStore
    @State private var importing = false
    @State private var selected: Guest?

    private static let importTypes: [UTType] = [
        UTType(filenameExtension: "ipa") ?? .zip,
        .zip,
        UTType(filenameExtension: "xcarchive") ?? .package,
        .applicationBundle,
        .folder,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusPanel
                    inboxPanel
                    if store.guests.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                            ForEach(store.guests) { guest in
                                GuestTile(guest: guest)
                                    .onTapGesture { selected = guest }
                                    .contextMenu { tileMenu(guest) }
                            }
                        }
                        .glassGroup(spacing: 14)
                    }
                }
                .padding(16)
            }
            .navigationTitle("iContain")
            .onAppear { store.refreshInbox() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                store.refreshInbox()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import", systemImage: "plus") }
                        .disabled(isBusy)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
                if case .success(let url) = result {
                    Task { await store.importItem(at: url) }
                }
            }
            .sheet(item: $selected) { guest in
                GuestDetailView(guestID: guest.id)
            }
            .slateScreen()
        }
    }

    private var isBusy: Bool {
        if case .working = store.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusPanel: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .working(let stage):
            Panel {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(AppleAccount.shared.stage ?? stage).font(.subheadline).foregroundStyle(.white)
                }
            }
        case .failed(let message):
            Panel(title: "Something went wrong", symbol: "exclamationmark.triangle.fill") {
                Text(message).font(.footnote).foregroundStyle(Theme.secondary).textSelection(.enabled)
                Button("Dismiss") { store.phase = .idle }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    @ViewBuilder
    private var inboxPanel: some View {
        if !store.inbox.isEmpty {
            Panel(title: "In iContain's folder", symbol: "folder") {
                ForEach(store.inbox, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc.zipper").foregroundStyle(Theme.secondary)
                        Text(url.lastPathComponent).font(.subheadline).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Button("Import") { Task { await store.importFromInbox(url) } }
                            .font(.subheadline.weight(.semibold))
                            .disabled(isBusy)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Panel {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Run apps inside iContain")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Import an .ipa, an .xcarchive, or a zipped .app from Xcode, including builds made for the iOS Simulator. iContain converts and signs it, and it opens without being installed on your iPhone. You can also drop files into the iContain folder in the Files app.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondary)
                Button { importing = true } label: { Label("Import an App", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PillButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func tileMenu(_ guest: Guest) -> some View {
        Button { store.launch(guest) } label: { Label("Open", systemImage: "play.fill") }
        Button { Task { await store.resign(guest) } } label: { Label("Re-sign", systemImage: "signature") }
        Button(role: .destructive) { store.delete(guest) } label: { Label("Delete", systemImage: "trash") }
    }
}

struct GuestTile: View {
    @EnvironmentObject private var store: GuestStore
    let guest: Guest

    var body: some View {
        VStack(spacing: 10) {
            GuestIcon(image: store.iconImage(guest), size: 64)
                .overlay(alignment: .topTrailing) {
                    if guest.location != nil {
                        Image(systemName: "location.fill")
                            .font(.caption2.weight(.bold))
                            .padding(5)
                            .glassSurface(Circle(), tint: Theme.accent)
                            .offset(x: 6, y: -6)
                    }
                }
            VStack(spacing: 2) {
                Text(guest.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .foregroundStyle(.white)
            Button { store.launch(guest) } label: { Text("Open") }
                .buttonStyle(PillButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var subtitle: String {
        if guest.isSimulatorBuild { return String(localized: "Simulator build") }
        return guest.version.isEmpty ? guest.bundleID : String(localized: "Version \(guest.version)")
    }
}

struct GuestDetailView: View {
    @EnvironmentObject private var store: GuestStore
    @Environment(\.dismiss) private var dismiss
    let guestID: String
    @State private var confirmDelete = false
    @State private var confirmReset = false

    private var guest: Guest? { store.guests.first { $0.id == guestID } }

    var body: some View {
        NavigationStack {
            if let guest {
                ScrollView {
                    VStack(spacing: 16) {
                        header(guest)
                        Panel(title: "Details", symbol: "info.circle") {
                            DetailRow(title: "Bundle ID", value: guest.bundleID, monospaced: true)
                            DetailRow(title: "Version", value: [guest.version, guest.build.isEmpty ? nil : "(\(guest.build))"].compactMap { $0 }.joined(separator: " "))
                            DetailRow(title: "Built for", value: builtFor(guest))
                            if !guest.minimumOS.isEmpty { DetailRow(title: "Requires", value: "iOS \(guest.minimumOS)") }
                            if let size = guest.sizeBytes { DetailRow(title: "App size", value: size.byteString) }
                            DetailRow(title: "Data", value: store.dataSize(guest).byteString)
                            if let expires = guest.signedExpires {
                                DetailRow(title: "Signature", value: expires < .now
                                          ? String(localized: "Expired")
                                          : String(localized: "Valid until \(expires.formatted(date: .abbreviated, time: .omitted))"))
                            }
                        }
                        locationPanel(guest)
                        Panel(title: "Manage", symbol: "wrench.and.screwdriver") {
                            Button { Task { await store.resign(guest) } } label: { Label("Re-sign", systemImage: "signature") }
                                .buttonStyle(PillButtonStyle(prominent: false))
                            Button { confirmReset = true } label: { Label("Reset Data", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(PillButtonStyle(prominent: false))
                            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                                .buttonStyle(PillButtonStyle(prominent: false))
                                .foregroundStyle(Theme.danger)
                        }
                        Text("Opening an app takes you to the Home Screen for a moment: tap the notification, or the iContain icon, and the app starts. To get back to iContain, close the app from the app switcher and open iContain again.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(16)
                }
                .navigationTitle(guest.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
                .confirmationDialog("Delete \(guest.name) and its data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { store.delete(guest); dismiss() }
                }
                .confirmationDialog("Erase everything \(guest.name) saved?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset Data", role: .destructive) { store.resetData(guest) }
                }
                .slateScreen()
            }
        }
    }

    private func header(_ guest: Guest) -> some View {
        VStack(spacing: 12) {
            GuestIcon(image: store.iconImage(guest), size: 96)
            Text(guest.name).font(.title2.weight(.bold)).foregroundStyle(.white)
            Button { dismiss(); store.launch(guest) } label: { Label("Open", systemImage: "play.fill") }
                .buttonStyle(PillButtonStyle())
                .frame(maxWidth: 220)
        }
        .padding(.vertical, 8)
    }

    private func locationPanel(_ guest: Guest) -> some View {
        Panel(title: "Location", symbol: "location") {
            Toggle(isOn: Binding(
                get: { guest.location != nil },
                set: { on in
                    var updated = guest
                    updated.location = on ? LocationSettings.shared.pick : nil
                    store.update(updated)
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate location").foregroundStyle(.white)
                    Text(guest.location.map { LocationSettings.describe($0) } ?? String(localized: "Uses your real location"))
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if guest.location != nil {
                Button("Use the Location tab's pin") {
                    var updated = guest
                    updated.location = LocationSettings.shared.pick
                    store.update(updated)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    private func builtFor(_ guest: Guest) -> String {
        switch guest.builtFor {
        case "simulator": String(localized: "iOS Simulator (converted)")
        case "ios": String(localized: "iPhone and iPad")
        default: String(localized: "Unknown")
        }
    }
}
