import Foundation
import CoreFoundation

/// VS Hook stores display preferences in REAPER's global ExtState, outside the RPP.
/// Read only its teleprompter section and never restore a previously active notice.
public enum VSHookTeleprompterMigration {
    public static let importedKey = "catlive.migration.vshook.teleprompter.v1"
    public struct Profiles: Sendable {
        public var selected: TeleprompterPreset
        public var night: TeleprompterSettings
        public var day: TeleprompterSettings
    }
    public struct Payload: Sendable {
        public var first: Profiles?
        public var second: Profiles?
        public var noticeAppearance: Data?
        public var templates: [String]?
        public var images: [Data?]?
        public var isEmpty: Bool { first == nil && second == nil && noticeAppearance == nil && templates == nil && images == nil }
    }

    public static func read(for project: URL) -> Payload? {
        var candidates: [URL] = []
        var folder = project.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(folder.appendingPathComponent("reaper-extstate.ini"))
            let parent = folder.deletingLastPathComponent()
            if parent == folder { break }; folder = parent
        }
        #if os(Windows)
        if let appData = ProcessInfo.processInfo.environment["APPDATA"] {
            candidates.append(URL(fileURLWithPath: appData).appendingPathComponent("REAPER/reaper-extstate.ini"))
        }
        #else
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/REAPER/reaper-extstate.ini"))
        #endif
        for url in candidates {
            if let payload = read(resourceFile: url) { return payload }
        }
        return nil
    }

    public static func read(resourceFile: URL) -> Payload? {
        guard let size = try? resourceFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
              let text = try? String(contentsOf: resourceFile, encoding: .utf8) else { return nil }
        var section = false, values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line == "[VS_HOOK_NATIVE_TELEPROMPT]"; continue
            }
            guard section, let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            values[key] = String(line[line.index(after: equal)...])
        }
        var payload = Payload(first: profiles(1, values), second: profiles(2, values))
        let notice = object(values["TECHNICAL_NOTICE_SETTINGS_V1"])
        if let notice {
            // These are the on-disk CatLive appearance field names.
            var appearance: [String: Any] = ["window1": true, "window2": true, "emojiEnabled": true, "cleanDisplay": false,
                "emoji": "⚠️", "font": "Arial", "scale": 100.0, "text": 0xffea00, "background": 0, "flash": 0xff0000]
            var changed = false
            for (source, target) in [("textColor", "text"), ("backgroundColor", "background"), ("flashColor", "flash")] {
                if let color = color(notice[source]) { appearance[target] = color; changed = true }
            }
            for (source, target) in [("window1Enabled", "window1"), ("window2Enabled", "window2"), ("emojiEnabled", "emojiEnabled"), ("cleanDisplay", "cleanDisplay")] {
                if let flag = boolean(notice[source]) { appearance[target] = flag; changed = true }
            }
            if let font = notice["fontFamily"] as? String, !font.isEmpty { appearance["font"] = font; changed = true }
            if let emoji = notice["emoji"] as? String { appearance["emoji"] = String(emoji.prefix(8)); changed = true }
            if let scale = number(notice["textScale"]) { appearance["scale"] = min(100, max(50, scale * 100)); changed = true }
            if changed { payload.noticeAppearance = try? JSONSerialization.data(withJSONObject: appearance) }
        }
        let templates = notice?["recadosTemplates"] as? [String]
        let paths = notice?["recadosImages"] as? [String]
        if templates != nil || (1...3).contains(where: { values["RECADOS_TEMPLATE_\($0)_V1"] != nil }) {
            payload.templates = (0..<3).map { index in
                String((values["RECADOS_TEMPLATE_\(index + 1)_V1"] ?? (templates?.indices.contains(index) == true ? templates![index] : "")).prefix(500))
            }
        }
        if paths != nil || (1...3).contains(where: { values["RECADOS_IMAGE_\($0)_V1"] != nil }) {
            payload.images = (0..<3).map { index in
                let path = values["RECADOS_IMAGE_\(index + 1)_V1"] ?? (paths?.indices.contains(index) == true ? paths![index] : "")
                guard !path.isEmpty else { return nil }
                let url = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path, relativeTo: resourceFile.deletingLastPathComponent())
                guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 16 * 1024 * 1024 else { return nil }
                return try? Data(contentsOf: url)
            }
        }
        return payload.isEmpty ? nil : payload
    }

    /// Called after a successful REAPER project conversion. Absence of VS Hook leaves
    /// both the user's preferences and this one-time gate untouched.
    @discardableResult public static func applyOnce(_ payload: Payload?, defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: importedKey), let payload, !payload.isEmpty else { return false }
        for (profiles, key) in [(payload.first, TeleprompterSettingsStore.preferenceKey), (payload.second, "jaras.teleprompter2.settings")] {
            if let profiles {
                TeleprompterSettingsStore(defaults: defaults, key: key).importProfiles(selected: profiles.selected, night: profiles.night, day: profiles.day)
            }
        }
        if let appearance = payload.noticeAppearance { defaults.set(appearance, forKey: "jaras.notices.appearance") }
        if let templates = payload.templates { defaults.set(templates, forKey: "jaras.notices.templates") }
        if let images = payload.images {
            for (index, image) in images.enumerated() { defaults.set(image, forKey: "jaras.notices.image.\(index)") }
        }
        defaults.set(true, forKey: importedKey)
        return true
    }

    private static func profiles(_ slot: Int, _ values: [String: String]) -> Profiles? {
        let active = object(values["TP\(slot)_SETTINGS_V1"])
        let selected = TeleprompterPreset(rawValue: active?["preset"] as? String ?? "night") ?? .night
        let night = object(values["TP\(slot)_NIGHT_SETTINGS_V1"]), day = object(values["TP\(slot)_DAY_SETTINGS_V1"])
        let activeSettings = active.flatMap { settings($0, preset: selected, slot: slot) }
        let nightSettings = night.flatMap { settings($0, preset: .night, slot: slot) }
        let daySettings = day.flatMap { settings($0, preset: .day, slot: slot) }
        guard activeSettings != nil || nightSettings != nil || daySettings != nil else { return nil }
        func fallback(_ preset: TeleprompterPreset) -> TeleprompterSettings {
            var settings = TeleprompterSettings(preset: preset)
            if slot == 2 { settings.previewEnabled = false }
            return settings
        }
        return Profiles(selected: selected,
            night: selected == .night ? activeSettings ?? nightSettings ?? fallback(.night) : nightSettings ?? fallback(.night),
            day: selected == .day ? activeSettings ?? daySettings ?? fallback(.day) : daySettings ?? fallback(.day))
    }

    private static func settings(_ source: [String: Any], preset: TeleprompterPreset, slot: Int) -> TeleprompterSettings? {
        var base = TeleprompterSettings(preset: preset)
        if slot == 2 { base.previewEnabled = false }
        guard let data = try? JSONEncoder().encode(base), var merged = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var source = source, changed = false
        for (alias, key) in [("borderEnabled", "windowBorderEnabled"), ("showChords", "chordsEnabled"), ("rgbBorderEnabled", "rgbWindowBorderEnabled"), ("previewDurationEnabled", "previewSongDurationEnabled"), ("previewDurationEnabled", "previewBlockDurationEnabled")] {
            if source[key] == nil { source[key] = source[alias] }
        }
        if let depth = number(source["localClockDepth"]) { source["localClockScale"] = depth > 3 ? 1.0 : depth }
        // Optional fields are omitted by JSONEncoder when nil.
        merged["clearMode"] = false; merged["mediaStretch"] = false
        for key in Array(merged.keys) {
            guard let value = source[key] else { continue }
            if key.hasSuffix("Color"), let color = color(value) { merged[key] = color; changed = true }
            else if key.hasSuffix("Scale"), let number = number(value) { merged[key] = number * 100; changed = true }
            else if key == "fontFamily" || key.hasSuffix("FontFamily"), let name = value as? String { merged[key] = fontCode(name); changed = true }
            else if let old = merged[key] as? NSNumber, CFGetTypeID(old) == CFBooleanGetTypeID(), let flag = boolean(value) { merged[key] = flag; changed = true }
            else if merged[key] is String, let string = value as? String {
                merged[key] = key == "clockPosition" && ["top", "bottom"].contains(string) ? "center-" + string : string
                changed = true
            }
        }
        guard changed, let encoded = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return (try? JSONDecoder().decode(TeleprompterSettings.self, from: encoded))?.sanitized()
    }
    private static func object(_ value: String?) -> [String: Any]? {
        guard let value else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
    }
    private static func color(_ value: Any?) -> UInt32? {
        if let string = value as? String {
            let hex = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard hex.count == 6 else { return nil }; return UInt32(hex, radix: 16)
        }
        guard let number = number(value), (0...0xffffff).contains(number), number.rounded() == number else { return nil }
        return UInt32(number)
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }; return value.doubleValue
    }
    private static func fontCode(_ name: String) -> String {
        let name = name.lowercased().replacingOccurrences(of: " ", with: "")
        if name.hasPrefix("segoe") { return "segoe" }
        if name.hasPrefix("trebuchet") { return "trebuchet" }
        if ["menlo", "courier", "couriernew", "monospace", "mono"].contains(name) { return "mono" }
        return ["arial", "bahnschrift", "verdana", "tahoma", "georgia", "impact"].contains(name) ? name : "system"
    }
}
