import SwiftUI
enum JarasTheme {
    static let background = Color(hex: 0x11151b)
    static let panel = Color(hex: 0x1b212a)
    static let line = Color(hex: 0x303944)
    static let text = Color(hex: 0xffffff)
    static let secondary = Color(hex: 0x9aa8b9)
    static let grid = Color(hex: 0x1a2029)
    static let mixer = Color(hex: 0x202630)
    static let display = Color(hex: 0x0c1117)
    static let titlebar = Color(hex: 0x272e38)
    static let accent = Color(hex: 0xd8fb66)
    static let green = Color(hex: 0x54ff93)
    static let yellow = Color(hex: 0xffdc52)
    static func track(_ track: Track, emphasized: Bool = false) -> Color {
        let hex = track.color ?? roleHex(track.role)
        guard emphasized else { return Color(hex: hex) }
        let r = Double(hex >> 16 & 255) / 255, g = Double(hex >> 8 & 255) / 255, b = Double(hex & 255) / 255
        let peak = max(r, max(g, b))
        func channel(_ value: Double) -> Double { min(1, max(0, (peak - (peak - value) * 1.45) * 1.15)) }
        return Color(red: channel(r), green: channel(g), blue: channel(b))
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
