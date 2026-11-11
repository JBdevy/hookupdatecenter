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
    public func padMappingLabel(_ index: Int) -> String {
        guard padMappings.indices.contains(index), let mapping = padMappings[index], let number = mapping.number else { return "" }
        return "\(mapping.status.map { $0 & 0xf0 == 0xb0 } == true ? "CC" : "Note") \(number)"
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
    public static let maximumDuration: Double = 60
    public static func acceptsDuration(frames: Int64, sampleRate: Double) -> Bool {
        frames > 0 && sampleRate.isFinite && sampleRate > 0 && Double(frames) / sampleRate <= maximumDuration
    }
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

/// Portable six-bank library, shared with the desktop ZIP writer. Media is
/// streamed and verified before any installed pad configuration is replaced.
public enum VinhetasPackage {
    struct Manifest: Codable {
        var format = "catlive-zipfx"
        var version = 1
        var library: VinhetasLibrary
        var files: [PortableProjectPackage.FileRecord]
    }
    static var limits: PortableProjectPackage.Limits {
        var value = PortableProjectPackage.Limits()
        value.maximumFiles = 97; value.maximumBytes = 8 * 1024 * 1024 * 1024
        value.maximumManifestBytes = 2 * 1024 * 1024
        return value
    }
    static func invalid(_ message: String) -> Error { ProjectError.invalid(message) }
    public static func export(_ original: VinhetasLibrary, directory: URL, to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        var library = original; try library.validate()
        guard destination.pathExtension.lowercased() == "zipfx" else { throw invalid("Use a extensão .zipfx.") }
        var paths: [URL: String] = [:], sources: [String: URL] = [:], records: [PortableProjectPackage.FileRecord] = []
        for p in library.presets.indices { for n in library.presets[p].pads.indices {
            guard let name = library.presets[p].pads[n].audioFile, !name.isEmpty else { library.presets[p].pads[n].audioFile = nil; continue }
            let source = directory.appendingPathComponent(name).standardizedFileURL
            guard source.deletingLastPathComponent() == directory.standardizedFileURL, VinhetasPad.accepts(source) else { throw invalid("Arquivo de pad inválido: \(name)") }
            try PortableProjectPackage.validateRegularFile(source)
            if paths[source] == nil {
                var record = try PortableProjectPackage.fingerprint(source)
                record.path = "Audio/" + UUID().uuidString + "." + source.pathExtension.lowercased()
                paths[source] = record.path; sources[record.path] = source; records.append(record)
            }
            library.presets[p].pads[n].audioFile = paths[source]
        }}
        let total = records.reduce(UInt64(0)) { $0 + $1.bytes }
        guard total <= limits.maximumBytes else { throw invalid("O banco de pads excede o limite de 8 GB.") }
        let temp = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".zipfx")
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try StoredProjectZIPWriter(url: temp)
        let manifest = try JSONEncoder().encode(Manifest(library: library, files: records))
        guard manifest.count <= limits.maximumManifestBytes else { throw invalid("A configuração dos pads é muito grande.") }
        try writer.add(path: "manifest.json", data: manifest)
        var copied: UInt64 = 0
        for record in records {
            let base = copied
            try writer.add(path: record.path, source: sources[record.path]!, expected: record) { bytes in progress(Double(base + bytes) / Double(max(1, total))) }
            copied += record.bytes
        }
        try writer.finish()
        if FileManager.default.fileExists(atPath: destination.path) {
            try PortableProjectPackage.validateRegularFile(destination)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
        progress(1)
    }
    /// Extract into a new staging directory. The caller validates audio duration
    /// and commits the library only after every file has passed its hash check.
    public static func prepareImport(_ archive: URL, into staging: URL,
                                     progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> VinhetasLibrary {
        guard archive.pathExtension.lowercased() == "zipfx" else { throw invalid("Selecione um arquivo .zipfx.") }
        try PortableProjectPackage.validateRegularFile(archive)
        let zip = try StoredProjectZIPReader(url: archive, limits: limits)
        var manifest = try JSONDecoder().decode(Manifest.self, from: zip.data("manifest.json", maximum: limits.maximumManifestBytes))
        guard manifest.format == "catlive-zipfx", manifest.version == 1 else { throw invalid("Formato de presets não suportado.") }
        try manifest.library.validate()
        let names = manifest.files.map(\.path)
        let references = Set(manifest.library.presets.flatMap(\.pads).compactMap(\.audioFile))
        guard Set(names).count == names.count, Set(names) == references,
              Set(zip.entries.keys) == references.union(["manifest.json"]) else { throw invalid("O pacote de pads está incompleto.") }
        for record in manifest.files {
            let path = record.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 2, path[0] == "Audio", path[1] != ".", path[1] != "..",
                  VinhetasPad.accepts(URL(fileURLWithPath: record.path)), zip.entries[record.path]?.size == record.bytes else { throw invalid("Mídia inválida no pacote de pads.") }
        }
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw invalid("A pasta temporária já existe.") }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var mapped: [String: String] = [:], copied: UInt64 = 0
            for record in manifest.files {
                let name = UUID().uuidString + "." + URL(fileURLWithPath: record.path).pathExtension.lowercased()
                let base = copied
                try zip.extract(record.path, to: staging.appendingPathComponent(name), expected: record) { bytes in progress(Double(base + bytes) / Double(max(1, zip.totalBytes))) }
                mapped[record.path] = name; copied += record.bytes
            }
            for p in manifest.library.presets.indices { for n in manifest.library.presets[p].pads.indices {
                if let name = manifest.library.presets[p].pads[n].audioFile { manifest.library.presets[p].pads[n].audioFile = mapped[name] }
            }}
            progress(1); return manifest.library
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
}
