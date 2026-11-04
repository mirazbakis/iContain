import SwiftUI

/// iContain's look: the icon's slate glass, with one blue accent for what's live.
enum Theme {
    static let accent = Color(red: 0.31, green: 0.50, blue: 0.94)
    static let slateTop = Color(red: 0.36, green: 0.39, blue: 0.52)
    static let slateBottom = Color(red: 0.13, green: 0.15, blue: 0.23)
    static let glass = Color.white.opacity(0.08)
    static let glassStroke = Color.white.opacity(0.14)
    static let secondary = Color.white.opacity(0.62)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
}

struct SlateBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.slateTop, Theme.slateBottom], startPoint: .top, endPoint: .bottom)
            .overlay(
                RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 420)
            )
            // Soft colour for Liquid Glass to bend: the icon's blue, and a little violet.
            .overlay(alignment: .topTrailing) {
                Circle().fill(Theme.accent.opacity(0.35)).frame(width: 320).blur(radius: 90).offset(x: 90, y: 60)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(Color(red: 0.55, green: 0.42, blue: 0.85).opacity(0.25)).frame(width: 360).blur(radius: 110).offset(x: -110, y: 40)
            }
            .ignoresSafeArea()
    }
}

/// Liquid Glass on iOS 26 and later; the frosted panel look before that.
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else if let tint {
            content
                .background(tint.opacity(0.9), in: shape)
                .overlay(shape.stroke(Theme.glassStroke, lineWidth: 1))
        } else {
            content
                .background(Theme.glass, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.glassStroke, lineWidth: 1))
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// Lets neighbouring glass shapes blend and morph into each other on iOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// A raised glass panel, like the container in the icon.
struct Panel<Content: View>: View {
    var title: LocalizedStringKey?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    if let symbol { Image(systemName: symbol).foregroundStyle(Theme.accent) }
                }
                .foregroundStyle(.white)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Capsule buttons: blue-tinted glass for the main action, clear glass otherwise.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .glassSurface(Capsule(), tint: prominent ? Theme.accent : nil, interactive: true)
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct DetailRow: View {
    let title: LocalizedStringKey
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// The app's icon in a squircle, or a tile like the icon's when it has none.
struct GuestIcon: View {
    let image: UIImage?
    var size: CGFloat = 60

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.78), Color(white: 0.6)], startPoint: .top, endPoint: .bottom)
                    Circle().fill(.white).frame(width: size * 0.36, height: size * 0.36).shadow(radius: 2, y: 1)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}

extension View {
    func slateScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(SlateBackground())
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
