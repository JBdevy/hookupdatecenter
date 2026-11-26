import Foundation

public enum TeleprompterPreset: String, Codable, CaseIterable, Sendable { case night, day }

public struct TeleprompterPreviewSlots: Codable, Equatable, Sendable {
    public static let preferenceKey = "jaras.teleprompter.previewSlots"
    public static let slotCount = 6
    private static let stepsPerSlot = 10
    public var selected = 0
    public private(set) var steps = Array(repeating: -1, count: slotCount)

    public init() {}

    public func blocks(_ slot: Int) -> Range<Int> {
        let slot = min(Self.slotCount - 1, max(0, slot))
        let start = slot * 4
        let step = steps.indices.contains(slot) ? steps[slot] : -1
        guard (0..<Self.stepsPerSlot).contains(step) else { return start..<(start + 4) }
        let first = start + step / 3
        switch step % 3 {
        case 0: return first..<(first + 1)
        case 1: return (first + 1)..<(first + 2)
        default: return first..<(first + 2)
        }
    }

    public func label(_ slot: Int) -> String {
        let range = blocks(slot)
        return range.count == 1 ? "\(range.lowerBound + 1)" : "\(range.lowerBound + 1)–\(range.upperBound)"
    }

    public mutating func advance(_ slot: Int) {
        guard (0..<Self.slotCount).contains(slot) else { return }
        if steps.count != Self.slotCount { steps = Self().steps }
        let step = steps[slot]
        steps[slot] = (0..<(Self.stepsPerSlot - 1)).contains(step) ? step + 1
            : step == Self.stepsPerSlot - 1 ? -1 : 0
        selected = slot
    }

    public var visibleBlocks: Range<Int> { blocks(selected) }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              var slots = try? JSONDecoder().decode(Self.self, from: data),
              slots.steps.count == slotCount else { return Self() }
        slots.steps = slots.steps.map { (-1..<stepsPerSlot).contains($0) ? $0 : -1 }
        slots.selected = min(slotCount - 1, max(0, slots.selected))
        return slots
    }
    public func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}

/// Current VS Hook display settings, with one independent profile per preset.
public struct TeleprompterSettings: Codable, Equatable, Sendable {
    public var textColor: UInt32 = 0xffea00
    public var highlightColor: UInt32 = 0x00ff55
    public var textBoxColor: UInt32 = 0xffea00
    public var clockColor: UInt32 = 0x00ff55
    public var clockExpiredColor: UInt32 = 0xff3131
    public var clockBorderColor: UInt32 = 0x00ff55
    public var localClockColor: UInt32 = 0x00ff55
    public var localClockBorderColor: UInt32 = 0x00ff55
    public var borderColor: UInt32 = 0x00ff55
    public var songNameColor: UInt32 = 0x00ff55
    public var queueNameColor: UInt32 = 0xffea00
    public var progressColor: UInt32 = 0xffea00
    public var chordColor: UInt32 = 0xfb923c
    public var fontFamily: String = "system"
    public var previewFontFamily: String = "system"
    public var songNameFontFamily: String = "system"
    public var queueNameFontFamily: String = "system"
    public var chordFontFamily: String = "system"
    public var textCase: String = "uppercase"
    public var textAlignment: String = "center"
    public var clockPosition: String = "center-top"
    public var localClockPosition: String = "right"
    public var songNamePosition: String = "top"
    public var queueNamePosition: String = "top"
    public var progressPosition: String = "bottom"
    public var chordPosition: String = "top"
    public var progressMode: String = "lyrics"
    public var textScale: Double = 100
    public var clockScale: Double = 100
    public var songNameScale: Double = 100
    public var queueNameScale: Double = 100
    public var mediaStretch: Bool? = nil
    public var stretchesMedia: Bool {
        get { mediaStretch ?? false }
        set { mediaStretch = newValue }
    }
    public var mediaScale: Double = 100
    public var previewScale: Double = 100
    // Optional storage preserves profiles and Remote payloads from older versions.
    public var previewRegionColorSource: String? = nil
    public var previewRegionColor: UInt32? = nil
    public var previewBlockScale: Double? = nil
    public var previewRegionDurationScale: Double? = nil
    public var previewBlockDurationScale: Double? = nil
    public var previewLyricsEnabled: Bool? = nil
    public var chordScale: Double = 50
    public var localClockScale: Double = 100
    public var windowBorderEnabled: Bool = true
    public var clockBorderEnabled: Bool = true
    public var localClockBorderEnabled: Bool = true
    public var textBoxEnabled: Bool = true
    public var clockEnabled: Bool = true
    public var localClockEnabled: Bool = true
    public var songNameEnabled: Bool = false
    public var queueNameEnabled: Bool = true
    public var progressEnabled: Bool = false
    public var previewEnabled: Bool = true
    public var ignorePreview: Bool? = nil
    public var ignoresPreview: Bool {
        get { ignorePreview ?? false }
        set { ignorePreview = newValue }
    }
    public func displaysPreview(_ active: Bool) -> Bool { active && previewEnabled && !ignoresPreview }
    public var previewSongDurationEnabled: Bool = true
    public var previewBlockDurationEnabled: Bool = true
    public var previewUnderlineEnabled: Bool = true
    public var previewColorMode: String {
        get { previewRegionColorSource ?? "region" }
        set { previewRegionColorSource = newValue }
    }
    public var previewUserColor: UInt32 {
        get { previewRegionColor ?? 0xffffff }
        set { previewRegionColor = newValue }
    }
    public var previewBlockNameScale: Double {
        get { previewBlockScale ?? 100 }
        set { previewBlockScale = newValue }
    }
    public var previewRegionTimeScale: Double {
        get { previewRegionDurationScale ?? 100 }
        set { previewRegionDurationScale = newValue }
    }
    public var previewBlockTimeScale: Double {
        get { previewBlockDurationScale ?? 100 }
        set { previewBlockDurationScale = newValue }
    }
    public var showsLyricsWithPreview: Bool {
        get { previewLyricsEnabled ?? false }
        set { previewLyricsEnabled = newValue }
    }
    public func previewNameColor(region: UInt32, setlist: UInt32) -> UInt32 {
        switch previewColorMode {
        case "setlist": return setlist
        case "user": return previewUserColor
        default: return region
        }
    }
    public var chordsEnabled: Bool = true
    public var hideTransport: Bool = false
    public var clearMode: Bool? = nil
    public var isClear: Bool {
        get { clearMode ?? false }
        set { clearMode = newValue }
    }
    public var rgbWindowBorderEnabled: Bool = false
    public var rgbClockBorderEnabled: Bool = false
    public var rgbTextBoxBorderEnabled: Bool = false
    public var rgbChordBorderEnabled: Bool = false
    public init(preset: TeleprompterPreset = .night) {
        if preset == .day {
            textColor = 0xffffff
            highlightColor = 0xd97706
            textBoxColor = 0xffffff
            clockColor = 0xffffff
            clockExpiredColor = 0xd60000
            clockBorderColor = 0xffffff
            localClockColor = 0xffffff
            localClockBorderColor = 0xffffff
            borderColor = 0xffffff
            songNameColor = 0xffffff
            queueNameColor = 0xffffff
            progressColor = 0xffffff
            chordColor = 0xd97706
        }
    }
    public func sanitized() -> Self {
        var result = self
        result.textScale = textScale.isFinite ? min(150, max(35, textScale)) : Self().textScale
        result.clockScale = clockScale.isFinite ? min(150, max(35, clockScale)) : Self().clockScale
        result.songNameScale = songNameScale.isFinite ? min(200, max(35, songNameScale)) : Self().songNameScale
        result.queueNameScale = queueNameScale.isFinite ? min(200, max(35, queueNameScale)) : Self().queueNameScale
        result.mediaScale = mediaScale.isFinite ? min(150, max(25, mediaScale)) : Self().mediaScale
        result.previewScale = previewScale.isFinite ? min(300, max(35, previewScale)) : Self().previewScale
        let previewTextScale: (Double) -> Double = { $0.isFinite ? min(300, max(35, $0)) : 100 }
        result.previewBlockScale = previewBlockScale.map(previewTextScale)
        result.previewRegionDurationScale = previewRegionDurationScale.map(previewTextScale)
        result.previewBlockDurationScale = previewBlockDurationScale.map(previewTextScale)
        if let previewRegionColorSource, !["region", "setlist", "user"].contains(previewRegionColorSource) { result.previewRegionColorSource = nil }
        result.previewRegionColor = previewRegionColor.map { $0 & 0xffffff }
        result.localClockScale = localClockScale.isFinite ? min(200, max(50, localClockScale)) : Self().localClockScale
        result.chordScale = chordScale.isFinite ? min(100, max(10, chordScale)) : Self().chordScale
        if !["original", "uppercase", "lowercase"].contains(textCase) { result.textCase = Self().textCase }
        if !["system", "arial", "segoe", "bahnschrift", "verdana", "tahoma", "georgia", "trebuchet", "impact", "mono"].contains(fontFamily) { result.fontFamily = Self().fontFamily }
        if !["system", "arial", "segoe", "bahnschrift", "verdana", "tahoma", "georgia", "trebuchet", "impact", "mono"].contains(previewFontFamily) { result.previewFontFamily = Self().previewFontFamily }
        if !["system", "arial", "segoe", "bahnschrift", "verdana", "tahoma", "georgia", "trebuchet", "impact", "mono"].contains(songNameFontFamily) { result.songNameFontFamily = Self().songNameFontFamily }
        if !["system", "arial", "segoe", "bahnschrift", "verdana", "tahoma", "georgia", "trebuchet", "impact", "mono"].contains(queueNameFontFamily) { result.queueNameFontFamily = Self().queueNameFontFamily }
        if !["system", "arial", "segoe", "bahnschrift", "verdana", "tahoma", "georgia", "trebuchet", "impact", "mono"].contains(chordFontFamily) { result.chordFontFamily = Self().chordFontFamily }
        if !["left", "center", "right"].contains(textAlignment) { result.textAlignment = Self().textAlignment }
        if !["left-top", "left-bottom", "right-top", "right-bottom", "center-top", "center-bottom"].contains(clockPosition) { result.clockPosition = Self().clockPosition }
        if !["left", "right"].contains(localClockPosition) { result.localClockPosition = Self().localClockPosition }
        if !["top", "bottom"].contains(songNamePosition) { result.songNamePosition = Self().songNamePosition }
        if !["top", "bottom"].contains(queueNamePosition) { result.queueNamePosition = Self().queueNamePosition }
        if !["top", "bottom"].contains(progressPosition) { result.progressPosition = Self().progressPosition }
        if !["lyrics", "chords"].contains(progressMode) { result.progressMode = Self().progressMode }
        if !["top", "bottom"].contains(chordPosition) { result.chordPosition = Self().chordPosition }
        result.textColor &= 0xffffff
        result.highlightColor &= 0xffffff
        result.textBoxColor &= 0xffffff
        result.clockColor &= 0xffffff
        result.clockExpiredColor &= 0xffffff
        result.clockBorderColor &= 0xffffff
        result.localClockColor &= 0xffffff
        result.localClockBorderColor &= 0xffffff
        result.borderColor &= 0xffffff
        result.songNameColor &= 0xffffff
        result.queueNameColor &= 0xffffff
        result.progressColor &= 0xffffff
        result.chordColor &= 0xffffff
        return result
    }
    public func display(_ text: String) -> String {
        textCase == "uppercase" ? text.uppercased() : textCase == "lowercase" ? text.lowercased() : text
    }
}

/// Local display preferences never change the project or start an audio edit.
public final class TeleprompterSettingsStore {
    private struct Profiles: Codable {
        var selected = TeleprompterPreset.night
        var night = TeleprompterSettings()
        var day = TeleprompterSettings(preset: .day)
    }
    public static let preferenceKey = "jaras.teleprompter.settings"
    private let defaults: UserDefaults
    private let key: String
    private var profiles: Profiles
    public var selected: TeleprompterPreset { profiles.selected }
    public var current: TeleprompterSettings { selected == .day ? profiles.day : profiles.night }
    public init(defaults: UserDefaults = .standard, key: String = TeleprompterSettingsStore.preferenceKey) {
        self.defaults = defaults
        self.key = key
        profiles = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Profiles.self, from: $0) } ?? Profiles()
        profiles.night = profiles.night.sanitized(); profiles.day = profiles.day.sanitized()
    }
    @discardableResult public func select(_ preset: TeleprompterPreset) -> Bool {
        guard profiles.selected != preset else { return false }
        profiles.selected = preset; persist(); return true
    }
    @discardableResult public func update(_ settings: TeleprompterSettings) -> Bool {
        let next = settings.sanitized()
        guard next != current else { return false }
        if selected == .day { profiles.day = next } else { profiles.night = next }
        persist(); return true
    }
    public func importProfiles(selected: TeleprompterPreset, night: TeleprompterSettings, day: TeleprompterSettings) {
        profiles.selected = selected
        profiles.night = night.sanitized(); profiles.day = day.sanitized()
        persist()
    }
    public func reload() {
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Profiles.self, from: data) else { return }
        profiles = saved
        profiles.night = profiles.night.sanitized(); profiles.day = profiles.day.sanitized()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: key) }
    }
}
