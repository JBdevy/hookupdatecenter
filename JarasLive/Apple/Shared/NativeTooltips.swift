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
    func jarasHelp(_ text: String) -> some View {
        modifier(LocalizedAccessibilityHint(text: text))
    }
}
/// Keep control descriptions available to accessibility without hover popovers
/// or extra AppKit views participating in layout and tracking.
private struct LocalizedAccessibilityHint: ViewModifier {
    let text: String
    @Environment(\.locale) private var locale
    func body(content: Content) -> some View {
        let localized = JarasLocalization.string(text, language: locale.identifier)
        content.accessibilityHint(Text(verbatim: localized))
    }
}
