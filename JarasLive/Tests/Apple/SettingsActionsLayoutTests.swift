import AppKit
import SwiftUI

// UI-only dependencies. The action list and its six-category model are the
// production sources; no audio hardware, account or saved mappings are used.
final class ShowController: ObservableObject {
    struct Track { var name: String }
    func actionTrack(number: Int) -> Track? { Track(name: "Track \(number)") }
}
final class ControlMappings: ObservableObject {
    static let shared = ControlMappings()
    var actions = DAWActionBindings(), error = ""
    func setActionTrack(_ action: DAWAction, number: Int?) {}
    func resetAction(_ action: DAWAction, kind: String) {}
    func beginAction(_ action: DAWAction, kind: String) {}
    func removeActionInput(_ action: DAWAction, kind: String) {}
}
enum JarasLocalization { static func string(_ key: String) -> String { key } }
enum JarasTheme {
    static let accent = Color.green, panel = Color(white: 0.145), text = Color.white
    static let display = Color(white: 0.08), secondary = Color(white: 0.72)
}
struct CategoryFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}
final class LayoutProbe { var frames: [String: CGRect] = [:] }

Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    for language in ["en", "pt-BR"] {
        for width: CGFloat in [940, 660, 520] {
            let probe = LayoutProbe()
            let root = HStack(spacing: 0) {
                Color(white: 0.145).frame(width: 144)
                Divider()
                GeometryReader { viewport in
                    ScrollView {
                        DAWActionsList(show: ShowController())
                            .coordinateSpace(name: "actions")
                            .onPreferenceChange(CategoryFrames.self) { probe.frames = $0 }
                            .padding(24).frame(width: viewport.size.width, alignment: .leading)
                    }
                }
            }.frame(width: width, height: 540).background(Color(white: 0.115))
                .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while probe.frames.count < 6 && ProcessInfo.processInfo.systemUptime < deadline {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(probe.frames.count == 6, "All six categories must be laid out")
            let available = width - 144 - 1 - 48
            for (name, frame) in probe.frames {
                precondition(frame.minX >= -0.5 && frame.maxX <= available + 0.5, "\(name) extends outside the \(language) viewport at \(width): \(frame)")
                precondition(frame.width >= 100 && frame.height >= 29)
            }
            if width == 940 {
                precondition(Set(probe.frames.values.map { Int($0.minY.rounded()) }).count == 1, "All tabs fit on one row in the wider settings window")
            } else {
                precondition(Set(probe.frames.values.map { Int($0.minY.rounded()) }).count > 1, "Narrow settings must wrap tabs instead of clipping")
            }
            if width == 940, language == "pt-BR", let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/catlive-settings-actions-layout.png"))
            }
            window.close()
            print("SETTINGS_ACTIONS_SIX_CATEGORIES_WITHIN_VIEWPORT_OK \(language) width=\(width)")
        }
    }
    exit(0)
}
RunLoop.main.run()
