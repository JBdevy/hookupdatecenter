import SwiftUI
import ImageIO

private struct JarasNativePaletteKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    /// The standalone iPad workspace shares the desktop palette. The Wi-Fi
    /// Remote keeps its existing raised surfaces and gradients.
    var jarasNativePalette: Bool {
        get { self[JarasNativePaletteKey.self] }
        set { self[JarasNativePaletteKey.self] = newValue }
    }
}
struct JarasNativePaletteSurface<Remote: View>: View {
    @Environment(\.jarasNativePalette) private var native
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    let color: (JarasInterfaceTheme) -> Color
    let remote: Remote
    var body: some View {
        if native { color(interfaceTheme) } else { remote }
    }
}

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
enum JarasInterfaceTheme: String {
    case dark, lightDark

    static let preferenceKey = "jaras.interface.theme"
    static let defaultTheme: Self = .lightDark
    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? defaultTheme
    }

    var background: Color { Color(hex: self == .dark ? JarasTheme.displayHex : JarasTheme.lightDarkBackgroundHex) }
    var homeBackground: Color { self == .dark ? Color(hex: 0x0f0f0f) : background }
    var panelHex: UInt32 { self == .dark ? JarasTheme.displayHex : 0x2b2b2b }
    var panel: Color { Color(hex: panelHex) }
    var display: Color { Color(hex: self == .dark ? JarasTheme.displayHex : 0x202020) }
    var mixerPanelBackground: Color { self == .dark ? Color(hex: 0x181818) : panel }
    var libraryEntriesBackground: Color { self == .dark ? Color(hex: 0x121212) : display }
    var scrollRailHex: UInt32 { self == .dark ? 0x1f1f1f : 0x1c1c1c }
    var titlebar: Color { self == .dark ? background : JarasTheme.workspaceToolbar }
    var line: Color { Color(hex: self == .dark ? 0x444444 : 0x494949) }
    var secondary: Color { Color(hex: self == .dark ? 0xb9b9b9 : 0xd7d7d7) }
    #if !os(macOS)
    var transportGradient: [Color] {
        self == .dark ? [Color(hex: 0x0e182c), Color(hex: 0x050b17)]
                      : [Color(hex: 0x15213a), Color(hex: 0x091121)]
    }
    #endif
    var transportBorder: Color { Color(hex: self == .dark ? 0x3d3d3d : 0x505050) }
}

enum JarasTheme {
    static let displayHex: UInt32 = 0x0f0f0f
    static let lightDarkBackgroundHex: UInt32 = 0x242424
    static var homeBackground: Color { JarasInterfaceTheme.current.homeBackground }
    static var display: Color { JarasInterfaceTheme.current.display }
    static var background: Color { JarasInterfaceTheme.current.background }
    static var panelHex: UInt32 { JarasInterfaceTheme.current.panelHex }
    static var panel: Color { JarasInterfaceTheme.current.panel }
    static let trackButton = Color(hex: 0x414141)
    static var line: Color { JarasInterfaceTheme.current.line }
    static var timelineHeaderLine: Color { line.opacity(0.65) }
    static let text = Color(hex: 0xffffff)
    static var secondary: Color { JarasInterfaceTheme.current.secondary }
    static var grid: Color { background }
    static var mixerHex: UInt32 { panelHex }
    static var mixer: Color { panel }
    static var titlebar: Color { JarasInterfaceTheme.current.titlebar }
    static let accent = Color(hex: 0x79f59a)
    static let green = Color(hex: 0x69ed91)
    static let workspaceToolbar = Color(hex: 0x2a2a2a)
    static let workspaceTransportGradient = [Color(hex: 0x10291c), Color(hex: 0x07100b)]
    static let licenseTitleGreen = Color(hex: 0x54ff93)
    static let transportPlay = Color(hex: 0x24f06a)
    static let liveOffRed = Color(hex: 0xff3030)
    static let transportRed = Color(hex: 0x8f2847)
    static let purple = Color(hex: 0xb8b8b8)
    static let toolbarInactive = Color(hex: 0xc8c8c8)
    static func toolbarTint(active: Bool) -> Color { active ? green : toolbarInactive }
    static let yellow = Color(hex: 0xffdc52)
    static func pauseBackground(_ paused: Bool) -> Color { paused ? yellow : Color(hex: 0x454545) }
    static let setlistQueuedYellow: UInt32 = 0x807219
    static let setlistQueuedGradient = [Color(hex: setlistQueuedYellow), Color(hex: 0x4d440c)]
    static func track(_ track: Track, emphasized: Bool = false) -> Color {
        let hex = track.color ?? roleHex(track.role)
        let color = TrackNameContrast.components(hex, emphasized: emphasized)
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
    static func trackNameHex(_ track: Track, emphasized: Bool, silenced: Bool) -> UInt32 {
        TrackNameContrast.foreground(track.color ?? roleHex(track.role), opacity: emphasized ? 0.65 : 0.5,
                                     background: mixerHex, emphasized: emphasized, desaturated: silenced)
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

enum MixerTrackStyle: String {
    case standard = "default"
    case stripeOnly

    static let trackMixerKey = "jaras.trackMixer.trackStyle"
    static let hozMixerKey = "jaras.hozMixer.trackStyle"
    static let trackStripeWidth: CGFloat = 5
    static let hozStripeHeight: CGFloat = 2
    static let darkSurfaceHex: UInt32 = 0x262626
    static let surfaceTextHex: UInt32 = 0xffffff
    static let surfaceText = Color(hex: surfaceTextHex)

    static func surfaceHex(for theme: JarasInterfaceTheme) -> UInt32 {
        theme == .dark ? darkSurfaceHex : Project.defaultMasterColor
    }
}

struct MixerTrackSurface: View {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme
    var selected = false
    var body: some View {
        Color(hex: MixerTrackStyle.surfaceHex(for: theme))
            .overlay { if selected { Color.white.opacity(0.11) } }
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
#if os(macOS)
enum DesktopToolbarTone {
    case neutral, selected, live

    var foreground: Color { JarasTheme.toolbarTint(active: self != .neutral) }
}

private struct CompactDesktopToolbarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactDesktopToolbar: Bool {
        get { self[CompactDesktopToolbarKey.self] }
        set { self[CompactDesktopToolbarKey.self] = newValue }
    }
}

struct DesktopToolbarChrome: ViewModifier {
    @Environment(\.compactDesktopToolbar) private var compact
    var tone: DesktopToolbarTone

    func body(content: Content) -> some View {
        content.font(.jarasSystem(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .lineLimit(1).fixedSize().padding(.horizontal, compact ? 2 : 6).frame(height: 24)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.14), lineWidth: 0.7).allowsHitTesting(false) }
            .contentShape(Rectangle())
    }
}

struct DesktopToolbarLabel: View {
    let title: String
    let systemImage: String
    var active = false
    @Environment(\.compactDesktopToolbar) private var compact
    var tone: DesktopToolbarTone? = nil

    var body: some View {
        ControlIcon(name: systemImage, active: (tone ?? (active ? .selected : .neutral)) != .neutral, size: compact ? 16 : 18, toolbar: true)
            .accessibilityElement(children: .ignore)
            .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
            .modifier(DesktopToolbarChrome(tone: tone ?? (active ? .selected : .neutral)))
            .accessibilityLabel(Text(LocalizedStringKey(title)))
            .desktopIconTooltip(title == "File" ? nil : title)
    }
}

#endif

private struct ToolbarIconSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var toolbarIconSurface: Bool {
        get { self[ToolbarIconSurfaceKey.self] }
        set { self[ToolbarIconSurfaceKey.self] = newValue }
    }
}

/// The desktop and iPad controls use the same sRGB artwork as the Windows build.
struct ControlIcon: View {
    let name: String
    var active = false
    var size: CGFloat = 18
    var toolbar = false
    @Environment(\.toolbarIconSurface) private var toolbarSurface

    private static func load(_ state: String) -> [String: CGImage] {
        guard let url = Bundle.main.url(forResource: state, withExtension: "png", subdirectory: "ControlIcons"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let list = Bundle.main.url(forResource: "controlNames", withExtension: "txt", subdirectory: "ControlIcons"),
              let names = try? String(contentsOf: list, encoding: .utf8) else { return [:] }
        let tile = sheet.width / 8
        var result = [String: CGImage]()
        for (i, name) in names.split(separator: "\n").enumerated() {
            result[String(name)] = sheet.cropping(to: CGRect(x: (i % 8) * tile, y: (i / 8) * tile, width: tile, height: tile))
        }
        return result
    }
    private static let off = load("controlsOff"), on = load("controlsOn"), toolbarOff = load("controlsToolbarOff")

    var body: some View {
        Group {
            let artwork = active ? Self.on[name] :
                (toolbar || toolbarSurface ? Self.toolbarOff[name] ?? Self.off[name] : Self.off[name])
            if let icon = artwork {
                Image(decorative: icon, scale: CGFloat(icon.width) / size).renderingMode(.original).resizable().interpolation(.high)
            } else {
                DesktopToolbarSymbol(name: name)
            }
        }.aspectRatio(1, contentMode: .fit).frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DesktopToolbarSymbol: View {
    let name: String
    var decorative = true

    private struct Artwork {
        let outline: Path
        let interior: Path
    }

    // The Windows renderer uses the same path definitions at its display DPI.
    private static let symbols: [String: Artwork] = {
        guard let url = Bundle.main.url(forResource: "DesktopToolbarSymbols", withExtension: "def"),
              let definitions = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return Dictionary(uniqueKeysWithValues: definitions.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "\"", omittingEmptySubsequences: false)
            guard fields.count == 7 else { return nil }
            return (String(fields[1]), Artwork(outline: path(fields[3]), interior: path(fields[5])))
        })
    }()

    private static func path(_ source: Substring) -> Path {
        var pieces = source.split(separator: " ").makeIterator()
        func point() -> CGPoint? {
            guard let x = pieces.next().flatMap({ Double($0) }),
                  let y = pieces.next().flatMap({ Double($0) }) else { return nil }
            return CGPoint(x: x, y: y)
        }
        var result = Path()
        while let command = pieces.next() {
            switch command {
            case "m": if let end = point() { result.move(to: end) }
            case "l": if let end = point() { result.addLine(to: end) }
            case "q":
                if let control = point(), let end = point() { result.addQuadCurve(to: end, control: control) }
            case "c":
                if let first = point(), let second = point(), let end = point() {
                    result.addCurve(to: end, control1: first, control2: second)
                }
            case "z": result.closeSubpath()
            default: return Path()
            }
        }
        return result
    }

    var body: some View {
        Group {
            if name == "info.circle" {
                Image(systemName: name).resizable().scaledToFit().font(.system(size: 17, weight: .semibold))
            } else if let icon = Self.symbols[name] {
                Canvas { context, layout in
                    let size = min(layout.width, layout.height)
                    let scale = size / 24
                    let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                        tx: (layout.width - size) / 2, ty: (layout.height - size) / 2)
                    context.fill(icon.interior.applying(transform), with: .foreground, style: FillStyle(eoFill: true))
                    context.stroke(icon.outline.applying(transform), with: .foreground,
                        style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round, lineJoin: .round))
                }
            } else {
                Image(systemName: name).resizable().scaledToFit()
            }
        }.accessibilityHidden(decorative)
    }
}

struct TransportControlIcon: View {
    let name: String
    var size: CGFloat = 18
    var color: Color? = nil
    var body: some View {
        let icon = DesktopToolbarSymbol(name: name).frame(width: size, height: size)
        if let color { icon.foregroundStyle(color) } else { icon }
    }
}

struct TransportDetailSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color(hex: 0x1f1f1f), Color(hex: 0x1a1a1a)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0x3b3b3b)))
            .allowsHitTesting(false)
    }
}

struct StageButtonStyle: ButtonStyle {
    var color = JarasTheme.panel
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.jarasSystem(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 13).frame(minHeight: 40)
            .foregroundStyle(active || color == JarasTheme.green ? Color.black : JarasTheme.text)
            .background(active || color == JarasTheme.green ? color.opacity(configuration.isPressed ? 0.8 : 1) : color.opacity(configuration.isPressed ? 0.7 : 0.45))
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

/// The overlay owns the blink clock, so muting Master does not rebuild its
/// faders, FX controls or audio graph every half second.
struct MasterMuteIndicator: ViewModifier {
    let muted: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if muted {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let bright = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(bright ? 0.28 : 0.04))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.red.opacity(bright ? 1 : 0.25), lineWidth: 2) }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
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
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if active {
            NativeJarasBlink(content: AnyView(content.environment(\.self, environment)), active: true,
                interval: interval, lowOpacity: lowOpacity)
                // These controls have an explicit or natural size. The native
                // host must keep it while flashing, rather than absorb spare
                // stack space and move its neighboring controls.
                .fixedSize(horizontal: true, vertical: true)
        } else { content }
        #else
        // Native iPad and Remote use the same bright/dim phases as the Mac.
        // Do not rescale the interval or darken the requested low opacity.
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
    static func timeline(_ swatch: TimelineThemeColor) -> AppearanceColor {
        if let color = colors[swatch.key] { return color }
        let legacy = UserDefaults.standard.object(forKey: "jaras.timeline." + swatch.rawValue) as? NSNumber
        let previous = legacy?.intValue ?? -1
        return shared(swatch.key, default: swatch.previousDefaults.contains(previous) ? -1 : previous)
    }

    func resolved(default fallback: Int) -> Int { value >= 0 ? value : fallback }

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
    static let leadingSpace: CGFloat = 6
    static let secondaryGrid = 0x333235
    static let playCursor = 0xF44336
    static let editCursor = 0x00A65A
    static let subPlayCursor = Int(JarasTheme.setlistQueuedYellow)
}

enum TimelineThemeColor: String {
    case background, verticalGrid = "primaryGrid", horizontalGrid

    var key: String {
        "jaras.timeline." + rawValue + (self == .horizontalGrid ? "" : "Override")
    }
    var previousDefaults: [Int] {
        switch self {
        case .background: return [0x0f0f0f, 0x222222]
        case .verticalGrid: return [0xbdbdbd]
        case .horizontalGrid: return []
        }
    }
    func defaultColor(for theme: JarasInterfaceTheme) -> Int {
        switch self {
        case .background: return theme == .dark ? Int(JarasTheme.displayHex) : 0x222222
        case .verticalGrid: return theme == .dark ? 0x5c5c5c : 0x828282
        case .horizontalGrid: return 0x000000
        }
    }
    @MainActor func current() -> UInt32 {
        UInt32(AppearanceColor.timeline(self).resolved(default: defaultColor(for: .current)))
    }
}

@MainActor @propertyWrapper struct TimelineColor: DynamicProperty {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme
    @ObservedObject private var settings: AppearanceColor
    private let swatch: TimelineThemeColor

    init(_ swatch: TimelineThemeColor) {
        self.swatch = swatch
        settings = AppearanceColor.timeline(swatch)
    }
    var wrappedValue: Int { settings.resolved(default: swatch.defaultColor(for: theme)) }
}

/// Shared operation progress: the same slim green bar used by audio separation.
struct BPMDetectionProgress: View {
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detecting BPM…").font(.jarasHeadline)
            ProgressView(value: fraction)
                .progressViewStyle(JarasProgressBarStyle())
                .accessibilityLabel("Detecting BPM…")
        }
    }
}

struct JarasProgressBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x121212))
                if let fraction = configuration.fractionCompleted {
                    Capsule().fill(JarasTheme.green).frame(width: width * min(1, max(0, fraction)))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(JarasTheme.green).frame(width: width * 0.3)
                            .offset(x: width * (phase * 1.3 - 0.3))
                    }
                }
            }.clipShape(Capsule())
        }.frame(height: 6)
    }
}

// App-owned typography. Font files are registered only inside CatLive's process;
// switching this family does not change macOS or external plug-in editors.
import CoreText
enum CatLiveTypeface {
    static let register: Void = {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Inter") else { return }
        for weight in ["Regular", "Medium", "SemiBold", "Bold", "Italic", "BoldItalic"] {
            CTFontManagerRegisterFontsForURL(directory.appendingPathComponent("Inter-\(weight).ttf") as CFURL, .process, nil)
        }
        for style in SetlistTypeface.allCases where style.rawValue >= 3 {
            let url = directory.appendingPathComponent("Setlist").appendingPathComponent(style.face + ".ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func name(_ weight: Font.Weight?) -> String {
        _ = register
        switch weight {
        case .bold, .heavy, .black: return "Inter-Bold"
        case .semibold: return "Inter-SemiBold"
        case .medium: return "Inter-Medium"
        default: return "Inter-Regular"
        }
    }
}
// Raw values are stored in preferences and sent to connected Remotes.
enum SetlistTypeface: Int, CaseIterable {
    case regular, bold, boldItalic, extraBold, black, archivoBlack, bungee

    var face: String {
        switch self {
        case .regular: return "Inter-Regular"
        case .bold: return "Inter-Bold"
        case .boldItalic: return "Inter-BoldItalic"
        case .extraBold: return "Inter-ExtraBold"
        case .black: return "Inter-Black"
        case .archivoBlack: return "ArchivoBlack-Regular"
        case .bungee: return "Bungee-Regular"
        }
    }

    static func font(_ style: Int, size: CGFloat = 13) -> Font {
        let choice = Self(rawValue: style) ?? .regular
        switch choice {
        case .regular: return .jarasSystem(size: size)
        case .bold: return .jarasSystem(size: size, weight: .bold)
        case .boldItalic: return .jarasSystem(size: size, weight: .bold).italic()
        default:
            _ = CatLiveTypeface.register
            return .custom(choice.face, fixedSize: size)
        }
    }
}
#if os(macOS)
import AppKit
private enum CatLiveNativeFonts {
    // NSFont(name:size:) reparses Inter's variation data on Ventura. Native
    // meters and timeline labels request these same immutable fonts every
    // frame; keep a bounded, thread-safe cache shared by those drawing paths.
    static let cache: NSCache<NSString, NSFont> = {
        let cache = NSCache<NSString, NSFont>()
        cache.countLimit = 96
        return cache
    }()
}
extension NSFont {
    static func jarasSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        _ = CatLiveTypeface.register
        let name = weight.rawValue >= NSFont.Weight.bold.rawValue ? "Bold" : weight.rawValue >= NSFont.Weight.semibold.rawValue ? "SemiBold" : weight.rawValue >= NSFont.Weight.medium.rawValue ? "Medium" : "Regular"
        let key = "\(size):\(weight.rawValue)" as NSString
        if let font = CatLiveNativeFonts.cache.object(forKey: key) { return font }
        let font = NSFont(name: "Inter-" + name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        CatLiveNativeFonts.cache.setObject(font, forKey: key)
        return font
    }
    static func jarasMonospacedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont { jarasSystemFont(ofSize: size, weight: weight) }
    static func jarasBoldSystemFont(ofSize size: CGFloat) -> NSFont { jarasSystemFont(ofSize: size, weight: .bold) }
}

/// Keep custom AppKit drawing at Retina resolution before compositing it on a 1× screen.
@MainActor final class NativeScreenDrawing {
    private var bitmap: CGContext?

    func invalidate() { bitmap = nil }

    func draw(in view: NSView, _ render: () -> Void) {
        guard let target = NSGraphicsContext.current?.cgContext else { return }
        target.setAllowsAntialiasing(true)
        target.setShouldAntialias(true)
        guard (view.window?.backingScaleFactor ?? 1) < 2 else {
            invalidate(); render(); return
        }
        let area = view.backingAlignedRect(view.bounds, options: .alignAllEdgesOutward)
        guard area.width > 0, area.height > 0 else { return }
        let width = Int(ceil(area.width * 2)), height = Int(ceil(area.height * 2))
        if bitmap?.width != width || bitmap?.height != height {
            bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let bitmap else { render(); return }
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.saveGState()
        if view.isFlipped { bitmap.translateBy(x: 0, y: CGFloat(height)) }
        bitmap.scaleBy(x: CGFloat(width) / area.width, y: CGFloat(height) / area.height * (view.isFlipped ? -1 : 1))
        bitmap.translateBy(x: -area.minX, y: -area.minY)
        bitmap.setAllowsAntialiasing(true)
        bitmap.setShouldAntialias(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: view.isFlipped)
        render()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.restoreGState()
        guard let image = bitmap.makeImage() else { render(); return }

        target.saveGState()
        target.interpolationQuality = .high
        if view.isFlipped {
            target.translateBy(x: area.minX, y: area.maxY)
            target.scaleBy(x: 1, y: -1)
            target.draw(image, in: CGRect(origin: .zero, size: area.size))
        } else {
            target.draw(image, in: area)
        }
        target.restoreGState()
    }
}
#endif
extension Font {
    static func jarasSystem(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        #if os(macOS)
        return .custom(CatLiveTypeface.name(weight), fixedSize: size)
        #else
        return .system(size: size, weight: weight, design: design)
        #endif
    }
    static func jarasSystem(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        #if os(macOS)
        let size: CGFloat
        switch style { case .largeTitle: size = 26; case .title: size = 22; case .title2: size = 17; case .title3: size = 15; case .callout: size = 12; case .subheadline: size = 11; case .footnote, .caption, .caption2: size = 10; default: size = 13 }
        return jarasSystem(size: size, weight: weight ?? (style == .headline ? .bold : .regular))
        #else
        return .system(style, design: design, weight: weight)
        #endif
    }
    static var jarasBody: Font { jarasSystem(.body) }
    static var jarasHeadline: Font { jarasSystem(.headline) }
    static var jarasSubheadline: Font { jarasSystem(.subheadline) }
    static var jarasCallout: Font { jarasSystem(.callout) }
    static var jarasCaption: Font { jarasSystem(.caption) }
    static var jarasCaption2: Font { jarasSystem(.caption2) }
    static var jarasFootnote: Font { jarasSystem(.footnote) }
    static var jarasTitle: Font { jarasSystem(.title) }
    static var jarasTitle2: Font { jarasSystem(.title2) }
    static var jarasTitle3: Font { jarasSystem(.title3) }
    static var jarasLargeTitle: Font { jarasSystem(.largeTitle) }
}
