import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// The pin the Location tab points at, used for apps in iContain and for the device.
@MainActor
final class LocationSettings: ObservableObject {
    static let shared = LocationSettings()

    @Published var pick: SpoofedLocation {
        didSet {
            if let data = try? JSONEncoder().encode(pick) { UserDefaults.standard.set(data, forKey: "location.pick") }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "location.pick"),
           let saved = try? JSONDecoder().decode(SpoofedLocation.self, from: data) {
            pick = saved
        } else {
            pick = SpoofedLocation(latitude: 51.5007, longitude: -0.1246, label: "Westminster, London")
        }
    }

    static func describe(_ location: SpoofedLocation) -> String {
        if let label = location.label, !label.isEmpty { return label }
        return String(format: "%.5f, %.5f", location.latitude, location.longitude)
    }
}

struct LocationView: View {
    @EnvironmentObject private var store: GuestStore
    @StateObject private var settings = LocationSettings.shared
    @StateObject private var spoofer = LocationSpoofer.shared
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var importingPairing = false
    @State private var pairingMessage: String?
    @State private var vpnActive = LocalDevVPN.isActive

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    mapPanel
                    appsPanel
                    devicePanel
                }
                .padding(16)
            }
            .navigationTitle("Location")
            .onAppear {
                camera = .region(MKCoordinateRegion(center: settings.pick.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
                vpnActive = LocalDevVPN.isActive
            }
            .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
                guard case .success(let url) = result else { return }
                do {
                    try PairingFile.importFile(at: url)
                    pairingMessage = String(localized: "Pairing file imported.")
                } catch {
                    pairingMessage = String(localized: "That isn't a pairing file iContain can read.")
                }
            }
            .slateScreen()
        }
    }

    // MARK: - Map

    private var mapPanel: some View {
        Panel(title: "Pin", symbol: "mappin.and.ellipse") {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search for a place", text: $query)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .foregroundStyle(.white)
            }
            .padding(12)
            .glassSurface(Capsule(), interactive: true)

            ForEach(results, id: \.self) { item in
                Button {
                    choose(item.placemark.coordinate, label: item.name)
                    results = []
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "").foregroundStyle(.white)
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            MapReader { proxy in
                Map(position: $camera) {
                    Annotation(LocationSettings.describe(settings.pick), coordinate: settings.pick.coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, Theme.accent)
                            .shadow(radius: 3)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        choose(coordinate, label: nil)
                    }
                }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("Tap the map or search to move the pin.")
                .font(.caption).foregroundStyle(Theme.secondary)
            DetailRow(title: "Pin", value: LocationSettings.describe(settings.pick))
        }
    }

    private func search() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            results = Array((response?.mapItems ?? []).prefix(5))
        }
    }

    private func choose(_ coordinate: CLLocationCoordinate2D, label: String?) {
        settings.pick = SpoofedLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, label: label)
        camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
        if spoofer.isRunning { spoofer.simulate(coordinate) }
    }

    // MARK: - Apps in iContain

    private var appsPanel: some View {
        Panel(title: "Apps in iContain", symbol: "square.grid.2x2") {
            Text("Apps that run inside iContain see the pin instead of your real location. Nothing else is needed.")
                .font(.footnote).foregroundStyle(Theme.secondary)
            if store.guests.isEmpty {
                Text("No apps yet.").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            ForEach(store.guests) { guest in
                Toggle(isOn: Binding(
                    get: { guest.location != nil },
                    set: { on in
                        var updated = guest
                        updated.location = on ? settings.pick : nil
                        store.update(updated)
                    })) {
                    HStack(spacing: 10) {
                        GuestIcon(image: store.iconImage(guest), size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(guest.name).foregroundStyle(.white)
                            if let location = guest.location {
                                Text(LocationSettings.describe(location)).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            }
            if store.guests.contains(where: { $0.location != nil }) {
                Button("Move every app to the pin") {
                    for var guest in store.guests where guest.location != nil {
                        guest.location = settings.pick
                        store.update(guest)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    // MARK: - Whole device

    private var devicePanel: some View {
        Panel(title: "Whole device", symbol: "iphone.gen3.radiowaves.left.and.right") {
            Text("Moves this iPhone's location for every app, the way Xcode does. Needs Developer Mode, LocalDevVPN and this iPhone's pairing file (rp_pairing_file.plist from idevice_pair, iloader or AltLoad).")
                .font(.footnote).foregroundStyle(Theme.secondary)

            DetailRow(title: "Pairing file", value: PairingFile.exists ? String(localized: "Imported") : String(localized: "Missing"))
            DetailRow(title: "LocalDevVPN", value: vpnActive ? String(localized: "On") : String(localized: "Off"))
            if let pairingMessage {
                Text(pairingMessage).font(.caption).foregroundStyle(Theme.secondary)
            }

            HStack(spacing: 10) {
                Button(PairingFile.exists ? "Replace Pairing File" : "Import Pairing File") { importingPairing = true }
                    .buttonStyle(PillButtonStyle(prominent: false))
                if !vpnActive {
                    Button("Turn On VPN") { LocalDevVPN.turnOn() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            switch spoofer.state {
            case .idle:
                Button { spoofer.simulate(settings.pick.coordinate) } label: { Label("Simulate on This iPhone", systemImage: "location.fill") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!PairingFile.exists)
            case .starting(let stage):
                HStack(spacing: 10) {
                    ProgressView()
                    Text(stage).font(.subheadline).foregroundStyle(.white)
                }
                Button("Cancel") { spoofer.stop() }.buttonStyle(PillButtonStyle(prominent: false))
            case .active(let coordinate):
                Label(String(format: "Simulating %.5f, %.5f", coordinate.latitude, coordinate.longitude), systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline).foregroundStyle(Theme.accent)
                Button("Stop and Use Real Location") { spoofer.stop() }
                    .buttonStyle(PillButtonStyle(prominent: false))
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
                Button("Try Again") { spoofer.simulate(settings.pick.coordinate) }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vpnActive = LocalDevVPN.isActive
        }
    }
}
