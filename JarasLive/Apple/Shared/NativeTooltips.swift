import SwiftUI

/// AppKit menus use the app preference, independently of the system language.
enum JarasLocalization {
    // Language resources are immutable for the lifetime of the app. Keep the
    // resolved bundles while still reading the current language on each call.
    private static let englishBundle = localizedBundle("en")
    private static let portugueseBundle = localizedBundle("pt-BR")
    private static func localizedBundle(_ identifier: String) -> Bundle {
        Bundle.main.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
    static func bundle(language: String? = nil) -> Bundle {
        let selected = (language ?? UserDefaults.standard.string(forKey: "jaras.language") ?? "en").replacingOccurrences(of: "_", with: "-")
        return selected.lowercased().hasPrefix("pt") ? portugueseBundle : englishBundle
    }
    static func string(_ key: String, language: String? = nil) -> String {
        bundle(language: language).localizedString(forKey: key, value: key, table: nil)
    }
}
extension View {
    @ViewBuilder func jarasHelp(_ text: String) -> some View {
        #if os(macOS)
        modifier(LocalizedTooltip(text: text))
        #else
        help(LocalizedStringKey(text))
        #endif
    }
}
#if os(macOS)
/// AppKit manages tooltip timing and dismissal without adding an NSView or
/// tracking area per control to the timeline and mixer layouts.
private struct LocalizedTooltip: ViewModifier {
    let text: String
    @Environment(\.locale) private var locale
    func body(content: Content) -> some View {
        let localized = JarasLocalization.string(text, language: locale.identifier)
        content.help(Text(verbatim: localized)).accessibilityHint(Text(verbatim: localized))
    }
}
#endif
