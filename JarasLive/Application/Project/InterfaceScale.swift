import Foundation

/// Window layout changes must not invalidate every @AppStorage control in the
/// audio workspace. Preserve existing values when moving these keys out of the
/// application's general preferences; documents and audio settings stay there.
public enum WorkspaceLayoutPreferences {
    public static let storage: UserDefaults = {
        let store = UserDefaults(suiteName: "com.hookdeveloper.catlive.layout")!
        migrate(from: .standard, to: store)
        return store
    }()
    public static func migrate(from source: UserDefaults, to destination: UserDefaults) {
        var keys = ["jaras.vinhetas.visible", "jaras.footerMixerHeight", "catlive.footerDisplayHeight"]
        for prefix in ["jaras.", "jaras.remote."] {
            keys += ["trackColumnWidth", "trackColumnRestoreWidth", "setlistWidth", "setlistRestoreWidth",
                     "layout.mixer.open", "layout.parts.open", "layout.partsRight.open",
                     "layout.setlist.placement", "layout.setlist.dockSide"].map { prefix + $0 }
        }
        for panel in ["mixer", "setlist", "parts", "vinhetas"] {
            keys += ["detached", "visible"].map { "jaras.layout.\(panel)." + $0 }
        }
        for key in keys where destination.object(forKey: key) == nil {
            if let value = source.object(forKey: key) { destination.set(value, forKey: key) }
        }
    }
}

public enum InterfaceScale {
    public static let key = "jaras.interface.scale"
    // Retain compatibility with existing preferences, but never apply their
    // former custom zoom. System display scaling remains managed by the OS.
    public static let percentages = [100]
    public static func percent(_ value: Double) -> Int { 100 }
    public static func factor(_ value: Double) -> Double { 1 }
}
