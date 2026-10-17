import Foundation

/// A preset contains one processor's parameters, never its track, slot or bypass state.
public struct FXPreset: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var plugin: String
    public var name: String
    public var native: NativeFXSettings?
    public var componentState: String?
    public var controllerState: String?

    public static func identity(_ settings: NativeFXSettings, effect: String) -> String {
        if let plugin = settings.externalPlugins?.first(where: { $0.effectKey == effect }) {
            return "vst3:" + plugin.classID.uppercased()
        }
        let kind = settings.kind(of: effect)
        return "native:" + kind + (kind == "Instruments" ? ":" + (settings.settings(for: effect).instrumentID ?? "") : "")
    }
    public init(name: String, settings: NativeFXSettings, effect: String) throws {
        guard settings.inserted.contains(effect) else { throw ProjectError.invalid("Effect no longer exists") }
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.name.isEmpty, self.name.count <= 80, self.name.lowercased() != "default" else {
            throw ProjectError.invalid("Choose a preset name other than Default (1–80 characters)")
        }
        plugin = Self.identity(settings, effect: effect)
        if let external = settings.externalPlugins?.first(where: { $0.effectKey == effect }) {
            guard external.componentState != nil || external.controllerState != nil else {
                throw ProjectError.invalid("Could not read the plugin state")
            }
            componentState = external.componentState; controllerState = external.controllerState
        } else {
            let kind = settings.kind(of: effect)
            var isolated = NativeFXSettings().merging(effect: kind, from: settings.settings(for: effect))
            isolated.inserted = [kind]; isolated.setEnabled(kind, enabled: true)
            try isolated.validate()
            native = isolated
        }
    }
    public func applying(to settings: NativeFXSettings, effect: String) throws -> NativeFXSettings {
        guard settings.inserted.contains(effect), Self.identity(settings, effect: effect) == plugin else {
            throw ProjectError.invalid("This preset belongs to another plugin")
        }
        var result = settings
        if let index = result.externalPlugins?.firstIndex(where: { $0.effectKey == effect }) {
            guard componentState != nil || controllerState != nil else { throw ProjectError.invalid("Empty plugin preset") }
            result.externalPlugins?[index].componentState = componentState
            result.externalPlugins?[index].controllerState = controllerState
        } else {
            guard let native else { throw ProjectError.invalid("Empty effect preset") }
            try native.validate()
            let enabled = settings.isEnabled(effect)
            result = settings.merging(effect: effect, from: native)
            result.setEnabled(effect, enabled: enabled)
        }
        try result.validate()
        return result
    }
    public func matches(_ settings: NativeFXSettings, effect: String) -> Bool {
        guard let current = try? FXPreset(name: name, settings: settings, effect: effect), current.plugin == plugin else { return false }
        if var a = native, var b = current.native {
            // Band UUIDs identify automation targets, not audible preset settings.
            for i in a.bands.indices { a.bands[i].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
            for i in b.bands.indices { b.bands[i].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
            return a == b
        }
        return native == nil && current.native == nil && componentState == current.componentState && controllerState == current.controllerState
    }
}

public struct FXPresetLibrary: Codable {
    public var version = 1
    public var presets: [FXPreset] = []
    public var defaults: [String: String] = [:]
    public init() {}
    public func entries(for plugin: String) -> [FXPreset] {
        presets.filter { $0.plugin == plugin }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public mutating func save(_ preset: FXPreset) throws {
        guard !presets.contains(where: { $0.plugin == preset.plugin && $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) else {
            throw ProjectError.invalid("A preset with this name already exists")
        }
        presets.append(preset)
    }
    public mutating func setDefault(_ preset: String?, plugin: String) throws {
        guard preset == nil || presets.contains(where: { $0.id == preset && $0.plugin == plugin }) else {
            throw ProjectError.invalid("Preset not found for this plugin")
        }
        defaults[plugin] = preset
    }
    public func applyingDefault(to settings: NativeFXSettings, effect: String) throws -> NativeFXSettings {
        let plugin = FXPreset.identity(settings, effect: effect)
        guard let id = defaults[plugin] else { return settings }
        guard let preset = presets.first(where: { $0.id == id && $0.plugin == plugin }) else { throw ProjectError.invalid("Default preset not found") }
        return try preset.applying(to: settings, effect: effect)
    }
}

public struct FXPresetStore {
    public static let didChange = Notification.Name("CatLive.FXPresets.changed")
    public static let shared = FXPresetStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CatLive/FXPresets.json"))
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read() throws -> FXPresetLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return FXPresetLibrary() }
        let library = try JSONDecoder().decode(FXPresetLibrary.self, from: Data(contentsOf: url))
        guard library.version == 1 else { throw ProjectError.invalid("Unsupported preset library version") }
        return library
    }
    public func write(_ library: FXPresetLibrary) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }
    public func applyingDefault(to settings: NativeFXSettings, effect: String) throws -> NativeFXSettings {
        try read().applyingDefault(to: settings, effect: effect)
    }
    public func applyingDefault(to plugin: ExternalPlugin) throws -> ExternalPlugin {
        var settings = NativeFXSettings(); settings.externalPlugins = [plugin]; settings.inserted = [plugin.effectKey]
        return try applyingDefault(to: settings, effect: plugin.effectKey).externalPlugins![0]
    }
}
