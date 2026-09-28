import SwiftUI

/// AppKit menus use the app preference, independently of the system language.
enum JarasLocalization {
    static func bundle(language: String? = nil) -> Bundle {
        let selected = (language ?? UserDefaults.standard.string(forKey: "jaras.language") ?? "en").replacingOccurrences(of: "_", with: "-")
        let identifier = selected.lowercased().hasPrefix("pt") ? "pt-BR" : "en"
        return Bundle.main.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
    static func string(_ key: String, language: String? = nil) -> String {
        bundle(language: language).localizedString(forKey: key, value: key, table: nil)
    }
}
extension View {
    @ViewBuilder func jarasHelp(_ text: String) -> some View {
        #if os(macOS)
        overlay(NativeTooltip(text: text))
        #else
        help(LocalizedStringKey(text))
        #endif
    }
}
#if os(macOS)
import AppKit
private struct NativeTooltip: NSViewRepresentable {
    let text: String
    @Environment(\.locale) private var locale
    func makeNSView(context: Context) -> NativeTooltipView { NativeTooltipView() }
    func updateNSView(_ view: NativeTooltipView,context: Context) {
        let translated = JarasLocalization.string(text, language: locale.identifier)
        if view.toolTip != translated { view.toolTip = translated }
    }
}
private final class NativeTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
