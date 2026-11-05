import SwiftUI

/// A device an app in iContain can be told it's running on (Test mode).
/// Sizes are in points, portrait; safe areas are for portrait.
struct DeviceProfile: Identifiable, Hashable {
    enum Kind: String { case phone, pad }

    let id: String
    let name: String
    let kind: Kind
    let width: Double
    let height: Double
    let scale: Double
    let safeTop: Double
    let safeBottom: Double
    /// Screen corner radius, used for the frame. 0 for devices with a Home button.
    let corner: Double
    let symbol: String

    static let native = "native"

    static let all: [DeviceProfile] = [
        DeviceProfile(id: "iphone-se", name: "iPhone SE", kind: .phone, width: 375, height: 667, scale: 2, safeTop: 20, safeBottom: 0, corner: 0, symbol: "iphone.gen1"),
        DeviceProfile(id: "iphone-mini", name: "iPhone 13 mini", kind: .phone, width: 375, height: 812, scale: 3, safeTop: 50, safeBottom: 34, corner: 44, symbol: "iphone.gen2"),
        DeviceProfile(id: "iphone-16e", name: "iPhone 16e", kind: .phone, width: 390, height: 844, scale: 3, safeTop: 47, safeBottom: 34, corner: 47, symbol: "iphone.gen2"),
        DeviceProfile(id: "iphone-17", name: "iPhone 17", kind: .phone, width: 402, height: 874, scale: 3, safeTop: 62, safeBottom: 34, corner: 55, symbol: "iphone.gen3"),
        DeviceProfile(id: "iphone-air", name: "iPhone Air", kind: .phone, width: 420, height: 912, scale: 3, safeTop: 68, safeBottom: 34, corner: 58, symbol: "iphone.gen3"),
        DeviceProfile(id: "iphone-17-pro-max", name: "iPhone 17 Pro Max", kind: .phone, width: 440, height: 956, scale: 3, safeTop: 62, safeBottom: 34, corner: 60, symbol: "iphone.gen3"),
        DeviceProfile(id: "ipad-mini", name: "iPad mini", kind: .pad, width: 744, height: 1133, scale: 2, safeTop: 24, safeBottom: 20, corner: 22, symbol: "ipad"),
        DeviceProfile(id: "ipad-air-11", name: "iPad Air 11-inch", kind: .pad, width: 820, height: 1180, scale: 2, safeTop: 24, safeBottom: 20, corner: 18, symbol: "ipad"),
        DeviceProfile(id: "ipad-pro-13", name: "iPad Pro 13-inch", kind: .pad, width: 1032, height: 1376, scale: 2, safeTop: 24, safeBottom: 20, corner: 30, symbol: "ipad"),
    ]

    static func find(_ id: String?) -> DeviceProfile? {
        all.first { $0.id == id }
    }

    /// What the loader reads from the launch request.
    var request: [String: Any] {
        ["name": name, "idiom": kind.rawValue, "width": width, "height": height, "scale": scale,
         "safeTop": safeTop, "safeBottom": safeBottom, "corner": corner,
         "model": kind == .pad ? "iPad" : "iPhone"]
    }

    var sizeText: String { "\(Int(width)) × \(Int(height)) pt @\(Int(scale))x" }
}

/// Light or dark mode forced on an app in Test mode.
enum TestAppearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
