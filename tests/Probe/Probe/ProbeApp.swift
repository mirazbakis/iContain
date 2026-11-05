// Probe: a tiny app for testing iContain. It shows what it sees from inside the
// container (bundle ID, home folder, location, screen, device and safe area), so
// each iContain feature can be checked at a glance. Built for the iOS Simulator by
// scripts/test-sim.sh.

import CoreLocation
import SwiftUI
import UIKit

@main
struct ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    @Published var text = "waiting"
    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { text = String(format: "%.4f, %.4f", l.coordinate.latitude, l.coordinate.longitude) }
    }
}

struct ProbeView: View {
    @StateObject private var locator = Locator()
    @AppStorage("launches") private var launches = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe is running").font(.largeTitle.bold())
            Text("Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
            Text("Home: \(NSHomeDirectory())").font(.caption)
            Text("Launches: \(launches)")
            Text("Location: \(locator.text)")
            Text("Screen: \(Int(UIScreen.main.bounds.width)) × \(Int(UIScreen.main.bounds.height)) @\(Int(UIScreen.main.scale))x")
            Text("Device: \(UIDevice.current.model), idiom \(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")")
            GeometryReader { g in
                Text("Safe area: top \(Int(g.safeAreaInsets.top)), bottom \(Int(g.safeAreaInsets.bottom))")
            }.frame(height: 24)
            Text("Window: \(Int(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width ?? 0)) pt wide")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .onAppear { launches += 1 }
    }
}
