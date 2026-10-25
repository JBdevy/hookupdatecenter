import Foundation

/// Global library: MIDI belongs to the sixteen positions, never to a preset.
public struct VinhetasLibrary: Codable, Equatable {
    public static let padCount = 16
    public static let presetCount = 6
    public var presets: [VinhetasPreset]
    public var padMappings: [ControlInput?]
    public var presetMappings: [ControlInput?]
    /// nil receives all channels; persisted values use the user-facing 1...16 range.
    public var midiChannel: Int?
    public var colorDefaultsVersion: Int?
    public var selectedPreset: Int
    public init() {
        let colors = VinhetasPad.palette.shuffled()
        presets = (0..<Self.presetCount).map { index in
            var preset = VinhetasPreset(index: index); preset.color = colors[index]; return preset
        }
        padMappings = Array(repeating: nil, count: Self.padCount)
        presetMappings = Array(repeating: nil, count: Self.presetCount)
        selectedPreset = 0; colorDefaultsVersion = 1
    }
    public mutating func upgradeDefaultColors() {
        guard colorDefaultsVersion == nil else { return }
        let presetColors = VinhetasPad.palette.shuffled()
        for p in presets.indices {
            if presets[p].color == 0x626262 { presets[p].color = presetColors[p] }
            let colors = VinhetasPad.palette.shuffled()
            for n in presets[p].pads.indices where presets[p].pads[n].color == 0x626262 {
                presets[p].pads[n].color = colors[n]
            }
        }
        colorDefaultsVersion = 1
    }
    public mutating func select(_ index: Int) { selectedPreset = min(Self.presetCount - 1, max(0, index)) }
    public func acceptsChannel(_ input: ControlInput) -> Bool {
        midiChannel == nil || Int(input.channel ?? 0) + 1 == midiChannel
    }
    public func matches(_ mapping: ControlInput?, input: ControlInput) -> Bool {
        guard acceptsChannel(input), var mapping else { return false }
        // The shared selector owns the channel. A learned CC/note stays mapped
        // when the user moves the controller to a different MIDI channel.
        mapping.channel = input.channel
        return mapping.matches(input)
    }
    public func handles(_ input: ControlInput) -> Bool {
        var normalized = input
        normalized.status = input.status.map { $0 & 0xf0 == 0xb0 ? 0xb0 : 0x90 }
        return padMappings.contains { matches($0, input: normalized) }
            || presetMappings.contains { matches($0, input: normalized) }
    }
    public mutating func validate() throws {
        guard presets.count == Self.presetCount, padMappings.count == Self.padCount,
              presetMappings.count == Self.presetCount, presets.allSatisfy({ $0.pads.count == Self.padCount }),
              (0..<Self.presetCount).contains(selectedPreset),
              midiChannel == nil || (1...16).contains(midiChannel!),
              presets.flatMap(\.pads).allSatisfy({ $0.volume.isFinite && (0...4).contains($0.volume) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
public struct VinhetasPreset: Codable, Equatable {
    public var name: String
    public var color: UInt32 = 0x626262
    public var pads: [VinhetasPad]
    public init(index: Int) {
        name = "Preset \(index + 1)"
        let colors = VinhetasPad.palette.shuffled()
        color = VinhetasPad.palette.randomElement()!
        pads = (0..<VinhetasLibrary.padCount).map { index in
            var pad = VinhetasPad(index: index); pad.color = colors[index]; return pad
        }
    }
}
public struct VinhetasPad: Codable, Equatable {
    public static let palette: [UInt32] = [0xE74C3C,0xE67E22,0xF1C40F,0x91C83E,0x2ECC71,0x1ABC9C,0x18A9BB,0x3498DB,0x5275EB,0x7861D9,0x9B59B6,0xC750B7,0xE86298,0xDC7770,0xC6A356,0x56A48E]
    public var name: String
    public var color: UInt32 = 0x626262
    public var volume: Double = 1
    public var gate = false
    /// Relative to the global Vinhetas media directory; never to a project.
    public var audioFile: String?
    public init(index: Int) { name = "Pad \(index + 1)" }
    public static func accepts(_ url: URL) -> Bool {
        ["wav", "wave", "aif", "aiff", "mp3"].contains(url.pathExtension.lowercased())
    }
}

/// Every press gets an independent voice. Releases retain the original preset,
/// so changing presets while holding a note cannot stop the wrong sample.
public struct VinhetasTriggers {
    public struct Voice: Equatable {
        public let id: UUID
        public let preset: Int
        public let pad: Int
    }
    public enum Event: Equatable { case start(Voice), stop(UUID), select(Int) }
    private var mouseVoices: [Int: UUID] = [:]
    private var remoteVoices: [UUID: Voice] = [:]
    private var noteVoices: [String: [UUID]] = [:]
    private var pressedCC: Set<String> = []
    public init() {}
    public mutating func mouseDown(pad: Int, library: VinhetasLibrary) -> [Event] {
        guard (0..<16).contains(pad) else { return [] }
        let preset = library.selectedPreset
        guard library.presets[preset].pads[pad].audioFile != nil else { return [] }
        let voice = Voice(id: UUID(), preset: preset, pad: pad)
        if library.presets[preset].pads[pad].gate { mouseVoices[pad] = voice.id }
        return [.start(voice)]
    }
    public mutating func remoteDown(id: UUID, preset: Int, pad: Int, library: VinhetasLibrary) -> [Event] {
        guard (0..<6).contains(preset), (0..<16).contains(pad), preset == library.selectedPreset,
              remoteVoices[id] == nil, remoteVoices.count < 128,
              library.presets[preset].pads[pad].audioFile != nil else { return [] }
        let voice = Voice(id: id, preset: preset, pad: pad)
        if library.presets[preset].pads[pad].gate { remoteVoices[id] = voice }
        return [.start(voice)]
    }
    public mutating func remoteUp(id: UUID) -> [Event] {
        remoteVoices.removeValue(forKey: id).map { [.stop($0.id)] } ?? []
    }
    public mutating func mouseUp(pad: Int) -> [Event] {
        mouseVoices.removeValue(forKey: pad).map { [.stop($0)] } ?? []
    }
    public mutating func midi(input: ControlInput, value: UInt8, library: VinhetasLibrary) -> [Event] {
        guard let status = input.status, [0x80, 0x90, 0xb0].contains(status & 0xf0) else { return [] }
        var normalized = input
        let cc = status & 0xf0 == 0xb0
        normalized.status = cc ? 0xb0 : 0x90
        let key = "\(input.device ?? 0):\(input.channel ?? 0):\(normalized.status!):\(input.number ?? 0)"
        let down = status & 0xf0 != 0x80 && value > 0
        if !down {
            pressedCC.remove(key)
            return (noteVoices.removeValue(forKey: key) ?? []).map(Event.stop)
        }
        guard library.acceptsChannel(input) else { return [] }
        if cc && !pressedCC.insert(key).inserted { return [] }
        if let preset = library.presetMappings.firstIndex(where: { library.matches($0, input: normalized) }) { return [.select(preset)] }
        guard let pad = library.padMappings.firstIndex(where: { library.matches($0, input: normalized) }),
              library.presets[library.selectedPreset].pads[pad].audioFile != nil else { return [] }
        let voice = Voice(id: UUID(), preset: library.selectedPreset, pad: pad)
        if !cc { noteVoices[key, default: []].append(voice.id) }
        return [.start(voice)]
    }
    public mutating func finished(_ id: UUID) {
        mouseVoices = mouseVoices.filter { $0.value != id }
        remoteVoices[id] = nil
        for key in Array(noteVoices.keys) {
            noteVoices[key]?.removeAll { $0 == id }
            if noteVoices[key]?.isEmpty == true { noteVoices[key] = nil }
        }
    }
}
