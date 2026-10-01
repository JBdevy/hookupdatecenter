import SwiftUI
enum JarasTheme {
    static let background = Color(hex: 0x11151b)
    static let panelHex: UInt32 = 0x1b212a
    static let panel = Color(hex: panelHex)
    static let line = Color(hex: 0x303944)
    static let text = Color(hex: 0xffffff)
    static let secondary = Color(hex: 0x9aa8b9)
    static let grid = Color(hex: 0x181818)
    static let mixerHex: UInt32 = 0x202630
    static let mixer = Color(hex: mixerHex)
    static let display = Color(hex: 0x0c1117)
    static let titlebar = Color(hex: 0x272e38)
    static let accent = Color(hex: 0xd8fb66)
    static let green = Color(hex: 0x54ff93)
    static let yellow = Color(hex: 0xffdc52)
    static func track(_ track: Track, emphasized: Bool = false) -> Color {
        let hex = track.color ?? roleHex(track.role)
        let color = TrackNameContrast.components(hex, emphasized: emphasized)
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
    static func trackNameHex(_ track: Track, emphasized: Bool, silenced: Bool) -> UInt32 {
        TrackNameContrast.foreground(track.color ?? roleHex(track.role), opacity: emphasized ? 0.65 : 0.5,
                                     background: mixerHex, emphasized: emphasized, desaturated: silenced)
    }
    static func masterNameHex(_ color: UInt32) -> UInt32 {
        TrackNameContrast.foreground(color, opacity: 0.5, background: panelHex)
    }
    static func role(_ role: TrackRole) -> Color { Color(hex: roleHex(role)) }
    static func roleHex(_ role: TrackRole) -> UInt32 {
        if let color = TrackKind(rawValue: role.rawValue)?.defaultColor { return color }
        switch role.rawValue {
        case "click": return 0x8ca4b0
        case "guide": return 0x8ed2e1
        case "drums": return 0xd37365
        case "bass": return 0xe9994d
        case "guitar": return 0x80b760
        case "keys": return 0xb48acb
        case "accordion": return 0xd9b45b
        case "backingVocal": return 0x6fb4d5
        case "fx": return 0xc79e60
        default: return 0x969ed7
        }
    }
}

/// Choose the more legible of pure black and white over the displayed track
/// color, including its translucency and selection/mute appearance.
enum TrackNameContrast {
    static func components(_ hex: UInt32, emphasized: Bool = false) -> (red: Double, green: Double, blue: Double) {
        let r = Double(hex >> 16 & 255) / 255, g = Double(hex >> 8 & 255) / 255, b = Double(hex & 255) / 255
        guard emphasized else { return (r, g, b) }
        let peak = max(r, max(g, b))
        func channel(_ value: Double) -> Double { min(1, max(0, (peak - (peak - value) * 1.45) * 1.15)) }
        return (channel(r), channel(g), channel(b))
    }
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    static func foreground(_ hex: UInt32, opacity: Double, background: UInt32, emphasized: Bool = false, desaturated: Bool = false) -> UInt32 {
        var color = components(hex, emphasized: emphasized)
        if desaturated {
            let gray = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
            color = (gray, gray, gray)
        }
        let base = components(background), alpha = min(1, max(0, opacity))
        let brightness = luminance(red: color.red * alpha + base.red * (1 - alpha),
                                   green: color.green * alpha + base.green * (1 - alpha),
                                   blue: color.blue * alpha + base.blue * (1 - alpha))
        let blackContrast = (brightness + 0.05) / 0.05
        let whiteContrast = 1.05 / (brightness + 0.05)
        return blackContrast >= whiteContrast ? 0x000000 : 0xffffff
    }
}
extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
}
struct StageButtonStyle: ButtonStyle {
    var color = JarasTheme.panel
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 13).frame(minHeight: 40)
            .foregroundStyle(active ? Color.black : JarasTheme.text)
            .background(active ? color : color.opacity(configuration.isPressed ? 0.7 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(active ? 1 : 0.65)))
    }
}

struct InputValidationShake: GeometryEffect {
    var animatableData: Double
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// Blink only at the requested transitions; an idle button must not schedule
/// whole-window animation/layout work at the display refresh rate.
struct JarasBlink: ViewModifier {
    let active: Bool
    var interval = 0.5
    var lowOpacity = 0.4
    @State private var bright = true
    func body(content: Content) -> some View {
        content.opacity(!active || bright ? 1 : lowOpacity)
            .task(id: active) {
                bright = true
                guard active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.05, interval) * 1_000_000_000)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    bright.toggle()
                }
            }
    }
}

/// A color drag publishes only to the views that paint that color. Persistence
/// happens on confirmation, rather than broadcasting UserDefaults on every pixel.
@MainActor final class AppearanceColor: ObservableObject {
    private static var colors: [String: AppearanceColor] = [:]
    static func shared(_ key: String, default fallback: Int) -> AppearanceColor {
        if let color = colors[key] { return color }
        let color = AppearanceColor(key: key, fallback: fallback)
        colors[key] = color
        return color
    }
    let key: String
    @Published var value: Int
    private init(key: String, fallback: Int) {
        self.key = key
        self.value = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.intValue ?? fallback
    }
    func save(_ color: Int) {
        if value != color { value = color }
        UserDefaults.standard.set(color, forKey: key)
    }
}

/// Factory timeline colors captured from the approved appearance.
enum TimelineAppearanceDefaults {
    static let background = 0x25211F
    static let primaryGrid = 0x829C9C
    static let secondaryGrid = 0x5F4163
    static let playCursor = 0xF44336
    static let editCursor = 0x00CFA0
    static let subPlayCursor = 0xFF6F00
}
