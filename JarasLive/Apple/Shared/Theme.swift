import SwiftUI

extension View {
    /// Native timeline scrollers and individual ScrollViews configure their own
    /// indicators on Monterey; newer systems also inherit this root preference.
    @ViewBuilder func jarasHideScrollIndicators() -> some View {
        if #available(macOS 13, iOS 16, *) { scrollIndicators(.hidden) }
        else { self }
    }
    /// Used for content that already fits its viewport. On Monterey it cannot
    /// scroll, while its contained buttons must remain interactive.
    @ViewBuilder func jarasScrollDisabled(_ disabled: Bool) -> some View {
        if #available(macOS 13, iOS 16, *) { scrollDisabled(disabled) }
        else { self }
    }
}
enum JarasTheme {
    static let background = Color(hex: 0x1e1e1e)
    static let panelHex: UInt32 = 0x252525
    static let panel = Color(hex: panelHex)
    static let line = Color(hex: 0x444444)
    static let text = Color(hex: 0xffffff)
    static let secondary = Color(hex: 0xb9b9b9)
    static let grid = Color(hex: 0x1e1e1e)
    static let mixerHex: UInt32 = 0x252525
    static let mixer = Color(hex: mixerHex)
    static let display = Color(hex: 0x141414)
    static let titlebar = Color(hex: 0x2b2b2b)
    static let accent = Color(hex: 0x79f59a)
    static let green = Color(hex: 0x69ed91)
    static let purple = Color(hex: 0xb8b8b8)
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
    #if os(macOS)
    @Environment(\.self) private var environment
    #else
    @State private var bright = true
    #endif
    private var blinkInterval: Double {
        #if os(iOS)
        return max(0.10, min(0.25, interval * 0.6))
        #else
        return interval
        #endif
    }
    private var dimOpacity: Double {
        #if os(iOS)
        return min(0.06, lowOpacity)
        #else
        return lowOpacity
        #endif
    }
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if active {
            NativeJarasBlink(content: AnyView(content.environment(\.self, environment)), active: true,
                interval: blinkInterval, lowOpacity: dimOpacity)
                // These controls have an explicit or natural size. The native
                // host must keep it while flashing, rather than absorb spare
                // stack space and move its neighboring controls.
                .fixedSize(horizontal: true, vertical: true)
        } else { content }
        #else
        content.opacity(!active || bright ? 1 : dimOpacity)
            .task(id: active) {
                bright = true
                guard active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.05, blinkInterval) * 1_000_000_000)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    bright.toggle()
                }
            }
        #endif
    }
}

#if os(macOS)
/// The compositor owns the discrete flash. Its hosted controls keep their
/// normal hit testing, while opacity transitions leave SwiftUI layout alone.
private struct NativeJarasBlink: NSViewRepresentable {
    let content: AnyView
    let active: Bool
    let interval: Double
    let lowOpacity: Double
    func makeNSView(context: Context) -> NativeJarasBlinkHost {
        let host = NativeJarasBlinkHost(rootView: content)
        host.setBlink(active: active, interval: interval, lowOpacity: lowOpacity)
        return host
    }
    func updateNSView(_ host: NativeJarasBlinkHost, context: Context) {
        host.rootView = content
        host.setBlink(active: active, interval: interval, lowOpacity: lowOpacity)
    }
    static func dismantleNSView(_ host: NativeJarasBlinkHost, coordinator: ()) { host.stop() }
}
private final class NativeJarasBlinkHost: NSHostingView<AnyView> {
    private var active = false
    private var interval = 0.5, lowOpacity = 0.4
    private var startedAt = 0.0
    private var revision = 0, appliedRevision = -1
    private weak var installedLayer: CALayer?
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var layer: CALayer? { didSet { applyBlink() } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyBlink() }
    override func viewDidHide() { super.viewDidHide(); applyBlink() }
    override func viewDidUnhide() { super.viewDidUnhide(); applyBlink() }
    func setBlink(active: Bool, interval: Double, lowOpacity: Double) {
        let interval = max(0.05, interval)
        if self.active != active || self.interval != interval || self.lowOpacity != lowOpacity {
            self.active = active; self.interval = interval; self.lowOpacity = lowOpacity
            startedAt = CACurrentMediaTime(); revision += 1
        }
        applyBlink()
    }
    private func applyBlink() {
        guard let layer else {
            installedLayer?.removeAnimation(forKey: "jarasBlink")
            installedLayer = nil; appliedRevision = -1
            return
        }
        if installedLayer !== layer {
            installedLayer?.removeAnimation(forKey: "jarasBlink")
            installedLayer = layer; appliedRevision = -1
            var actions = layer.actions ?? [:]; actions["opacity"] = NSNull(); layer.actions = actions
        }
        if layer.opacity != 1 { layer.opacity = 1 }
        guard active, window != nil, !isHiddenOrHasHiddenAncestor else {
            layer.removeAnimation(forKey: "jarasBlink"); appliedRevision = -1
            return
        }
        guard appliedRevision != revision || layer.animation(forKey: "jarasBlink") == nil else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, lowOpacity, 1]; blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete; blink.duration = interval * 2
        blink.repeatCount = .infinity
        // Retain the phase if AppKit replaces the backing surface or hides
        // the view temporarily, rather than restarting each flash cycle.
        blink.beginTime = layer.convertTime(startedAt, from: nil)
        layer.add(blink, forKey: "jarasBlink"); appliedRevision = revision
    }
    func stop() { active = false; applyBlink() }
}
#endif

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

/// CatLive factory colors. Explicit user timeline choices remain intact.
enum TimelineAppearanceDefaults {
    static let background = 0x1E1E1E
    static let primaryGrid = 0x414141
    static let secondaryGrid = 0x282828
    static let playCursor = 0x7548DD
    static let editCursor = 0xB9E229
    static let subPlayCursor = 0xFF6F00
}
