import SwiftUI
enum JarasTheme {
    static let background = Color(hex: 0x11151b), panel = Color(hex: 0x1b212a), line = Color(hex: 0x303944)
    static let accent = Color(hex: 0xd8fb66), green = Color(hex: 0x54ff93), yellow = Color(hex: 0xffdc52)
    static let secondary = Color(hex: 0x9aa8b9)
    static func role(_ role: TrackRole) -> Color {
        switch role.rawValue {
        case "click": return Color(hex: 0x8ca4b0)
        case "guide": return Color(hex: 0x8ed2e1)
        case "drums": return Color(hex: 0xd37365)
        case "bass": return Color(hex: 0xe9994d)
        case "guitar": return Color(hex: 0x80b760)
        case "keys": return Color(hex: 0xb48acb)
        case "accordion": return Color(hex: 0xd9b45b)
        case "backingVocal": return Color(hex: 0x6fb4d5)
        default: return Color(hex: 0x969ed7)
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
            .foregroundStyle(active ? Color.black : Color.white)
            .background(active ? color : color.opacity(configuration.isPressed ? 0.7 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(active ? 1 : 0.65)))
    }
}
func clockText(_ value: Double) -> String { let seconds = max(0, Int(value)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
