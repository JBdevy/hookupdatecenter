import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers
import AVFoundation

enum LibrarySamplerTransfer {
    static let type = UTType(exportedAs: "com.catlive.library-sampler", conformingTo: .data)
    static func provider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(url.absoluteString.utf8), nil)
            return nil
        }
        return provider
    }
    static func url(_ data: Data?) -> URL? {
        guard let data, let path = String(data: data, encoding: .utf8),
              let url = URL(string: path), url.isFileURL else { return nil }
        return url
    }
}

enum PadAudioBuffer {
    static func read(_ file: AVAudioFile, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = file.processingFormat
        guard frames > 0,
              let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let destination = audio.floatChannelData, let source = chunk.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var written = 0
        while written < Int(frames), file.framePosition < file.length {
            guard try AudioFileRead.read(file, into: chunk) else { break }
            let count = min(Int(chunk.frameLength), Int(frames) - written)
            for channel in 0..<Int(format.channelCount) {
                destination[channel].advanced(by: written).update(from: source[channel], count: count)
            }
            written += count
        }
        guard written > 0 else { throw CocoaError(.fileReadCorruptFile) }
        audio.frameLength = AVAudioFrameCount(written)
        return audio
    }
}

@MainActor final class VinhetasController: ObservableObject {
    static let shared = VinhetasController()
    static let padSamplesChanged = Notification.Name("CatLive.PadSamplesChanged")
    enum AudioOrigin { case picker, fileDrop, library }
    @Published private(set) var library = VinhetasLibrary()
    @Published private(set) var voices: [UUID: VinhetasTriggers.Voice] = [:]
    @Published var learningPad: Int?
    @Published var learningPreset: Int?
    @Published var error = ""
    @Published var droppedAudioError: String?
    @Published private(set) var transferring = false
    var startVoice: ((VinhetasTriggers.Voice, URL, Double) -> Void)?
    var stopVoice: ((UUID) -> Void)?
    var releaseVoice: ((UUID) -> Void)?
    var changeVolume: ((Int, Int, Double) -> Void)?
    private var triggers = VinhetasTriggers()
    private var remotePresses: [UUID] = []
    private weak var show: ShowController?
    private weak var audio: StemAudioPlayback?
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var loadingGeneration = 0
    private let persistence = DispatchQueue(label: "CatLive.Vinhetas.persistence", qos: .utility)
    private var voiceEngines: [UUID: StemAudioPlayback] = [:]
    private var audioImports: [Int: UUID] = [:]
    private var padSampleGeneration = 0
    func bind(show: ShowController) {
        self.show = show
        #if os(macOS)
        self.audio = DesktopProjectTabs.shared.audio(for: show)
        #else
        self.audio = StemAudioPlayback.shared
        #endif
        startVoice = { [weak self] voice, url, volume in
            guard let self else { return }
            guard let track = self.show?.current?.tracks.first(where: { $0.role.rawValue == "vinhetas" }) else {
                self.finished(voice.id); return
            }
            guard let path = self.library.presets[voice.preset].pads[voice.pad].audioFile,
                  let buffer = self.buffers[path], let audio = self.audio else {
                self.error = "Aguarde o carregamento do áudio do pad."; self.finished(voice.id); return
            }
            do {
                self.voiceEngines[voice.id] = audio
                try audio.playPad(voice.id, buffer: buffer, gain: Float(volume),
                    track: track.id,
                    finished: { [weak self] in self?.finished(voice.id) })
            } catch { self.error = error.localizedDescription; self.finished(voice.id) }
        }
        stopVoice = { [weak self] id in self?.voiceEngines[id]?.stopPad(id) }
        releaseVoice = { [weak self] id in self?.voiceEngines[id]?.releasePad(id) }
        changeVolume = { [weak self] preset, pad, volume in
            guard let self else { return }
            for voice in self.voices.values where voice.preset == preset && voice.pad == pad {
                self.voiceEngines[voice.id]?.setPadGain(voice.id, gain: Float(volume))
            }
        }
        preload()
    }
    func unbind() {
        panic(); learningPad = nil; learningPreset = nil; show = nil; audio = nil
    }
    private func preload() {
        loadingGeneration += 1; let generation = loadingGeneration
        #if os(iOS)
        // Keep the selected bank and sounding voices resident on memory-limited iPads.
        let resident = Set(library.presets[library.selectedPreset].pads.compactMap(\.audioFile))
            .union(voices.values.compactMap { library.presets[$0.preset].pads[$0.pad].audioFile })
        buffers = buffers.filter { resident.contains($0.key) }
        let files = resident.subtracting(buffers.keys)
        #else
        let files = Set(library.presets.flatMap(\.pads).compactMap(\.audioFile)).subtracting(buffers.keys)
        #endif
        guard !files.isEmpty else { return }
        let directory = directory
        Task { [weak self] in
            let (decoded, failures) = await Task.detached(priority: .userInitiated) {
                var result: [String: AVAudioPCMBuffer] = [:], failures: [String] = []
                for path in files {
                    do {
                        let file = try AVAudioFile(forReading: directory.appendingPathComponent(path))
                        guard VinhetasPad.acceptsDuration(frames: file.length, sampleRate: file.processingFormat.sampleRate) else {
                            throw ProjectError.invalid("Os pads aceitam áudios de até 60 segundos.")
                        }
                        guard file.length <= Int64(UInt32.max) else { throw CocoaError(.fileReadCorruptFile) }
                        result[path] = try PadAudioBuffer.read(file, frames: AVAudioFrameCount(file.length))
                    } catch { failures.append(error.localizedDescription) }
                }
                return (result, failures)
            }.value
            guard let self, self.loadingGeneration == generation else { return }
            self.buffers.merge(decoded) { _, fresh in fresh }
            self.error = failures.first ?? ""
        }
    }
    let directory: URL
    var padSampleDirectory: URL { directory.appendingPathComponent(VinhetasPad.sampleFolder, isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("Vinhetas.json") }
    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatLive/Vinhetas", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                var stored = try JSONDecoder().decode(VinhetasLibrary.self, from: Data(contentsOf: file))
                try stored.validate(); stored.upgradeDefaultColors(); library = stored
                try JSONEncoder().encode(stored).write(to: file, options: .atomic)
            } else {
                try JSONEncoder().encode(library).write(to: file, options: .atomic)
            }
        } catch { self.error = error.localizedDescription }
    }
    func update(_ edit: (inout VinhetasLibrary) -> Void) {
        guard !transferring else { return }
        var next = library; edit(&next)
        do {
            try next.validate(); library = next
            let snapshot = next, destination = file
            persistence.async { [weak self] in
                do { try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic) }
                catch { let message = error.localizedDescription; Task { @MainActor in self?.error = message } }
            }
        }
        catch { self.error = error.localizedDescription }
    }
    func exportPresets(to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !transferring else { throw ProjectError.invalid("Aguarde a transferência atual.") }
        transferring = true; defer { transferring = false }
        let snapshot = library, folder = directory
        try await Task.detached(priority: .userInitiated) {
            try VinhetasPackage.export(snapshot, directory: folder, to: url, progress: progress)
        }.value
    }
    func importPresets(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !transferring else { throw ProjectError.invalid("Aguarde a transferência atual.") }
        transferring = true; defer { transferring = false }
        let folder = directory, destination = file, old = library
        let staging = directory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let next = try await Task.detached(priority: .userInitiated) {
            let next = try VinhetasPackage.prepareImport(url, into: staging, progress: progress)
            for name in Set(next.presets.flatMap(\.pads).compactMap(\.audioFile)) {
                let audio = try AVAudioFile(forReading: staging.appendingPathComponent(name))
                guard VinhetasPad.acceptsDuration(frames: audio.length, sampleRate: audio.processingFormat.sampleRate) else {
                    throw ProjectError.invalid("Os pads aceitam áudios de até 60 segundos.")
                }
            }
            return next
        }.value
        // Serialize behind pending slider/name saves. Publish the new library
        // only when media and the durable JSON are both committed.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            persistence.async {
                var moved: [URL] = []
                do {
                    for name in Set(next.presets.flatMap(\.pads).compactMap(\.audioFile)) {
                        let target = folder.appendingPathComponent(name)
                        try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: target); moved.append(target)
                    }
                    try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("Vinhetas-before-import.json"), options: .atomic)
                    try JSONEncoder().encode(next).write(to: destination, options: .atomic)
                    continuation.resume()
                } catch { for file in moved { try? FileManager.default.removeItem(at: file) }; continuation.resume(throwing: error) }
            }
        }
        panic(); learningPad = nil; learningPreset = nil
        library = next; buffers.removeAll(); preload()
    }
    func unlearnPad(_ index: Int) {
        guard library.padMappings.indices.contains(index) else { return }
        if learningPad == index { learningPad = nil }
        update { $0.padMappings[index] = nil }
    }
    func select(_ index: Int) { update { $0.select(index) }; preload() }
    func volume(preset: Int, pad: Int, value: Double) {
        guard !transferring else { return }
        update { $0.presets[preset].pads[pad].volume = value }
        changeVolume?(preset, pad, value)
    }
    func gate(preset: Int, pad: Int, enabled: Bool) {
        guard !transferring else { return }
        if enabled && !library.presets[preset].pads[pad].gate {
            let ids = voices.values.filter { $0.preset == preset && $0.pad == pad }.map(\.id)
            for id in ids { (releaseVoice ?? stopVoice)?(id); finished(id) }
        }
        update { $0.presets[preset].pads[pad].gate = enabled }
    }
    func panic() {
        for id in Array(voices.keys) { stopVoice?(id); finished(id) }
    }
    private var available: Bool { show?.current?.tracks.contains { $0.role.rawValue == "vinhetas" } == true }
    var remoteState: DAWRemoteVinhetas {
        .init(selectedPreset: library.selectedPreset,
            available: available,
            presets: library.presets.enumerated().map { p, preset in
                .init(name: preset.name, color: preset.color, pads: preset.pads.enumerated().map { n, pad in
                    .init(name: pad.name, color: pad.color, volume: min(2, pad.volume), gate: pad.gate,
                        loaded: pad.audioFile.map { buffers[$0] != nil } ?? false,
                        active: voices.values.contains { $0.preset == p && $0.pad == n })
                })
            }, receivedPresses: remotePresses)
    }
    func applyRemote(_ command: DAWRemoteCommand) {
        guard command.valid else { return }
        switch command.action {
        case .vinhetasDown:
            guard available, let id = command.target, voices[id] == nil,
                  let p = command.preset, let n = command.pad else { return }
            guard !remotePresses.contains(id) else { return }
            remotePresses.append(id)
            if remotePresses.count > 256 { remotePresses.removeFirst(remotePresses.count - 256) }
            dispatch(triggers.remoteDown(id: id, preset: p, pad: n, library: library))
        case .vinhetasUp:
            if let id = command.target { dispatch(triggers.remoteUp(id: id)) }
        case .vinhetasPreset: select(Int(command.value))
        case .vinhetasVolume:
            if let p = command.preset, let n = command.pad { volume(preset: p, pad: n, value: command.value) }
        case .vinhetasGate:
            if let p = command.preset, let n = command.pad, let enabled = command.enabled { gate(preset: p, pad: n, enabled: enabled) }
        case .vinhetasPanic: panic()
        default: break
        }
    }
    func controllerDown(token: UUID, preset: Int, pad: Int) {
        guard available else { return }
        dispatch(triggers.remoteDown(id: token, preset: preset, pad: pad, library: library))
    }
    func controllerUp(token: UUID) { dispatch(triggers.remoteUp(id: token)) }
    func down(_ pad: Int) { SMK37Link.shared.padSelected(pad); dispatch(triggers.mouseDown(pad: pad, library: library)) }
    func up(_ pad: Int) { dispatch(triggers.mouseUp(pad: pad)) }
    func finished(_ id: UUID) { triggers.finished(id); voices[id] = nil; voiceEngines[id] = nil }
    /// A block shortcut must not be saved behind a pad/preset that consumes it.
    /// Match the effective Vinhetas channel, just like its MIDI receive path.
    func setlistBlockConflicts(_ input: ControlInput) -> [String] {
        guard input.kind == "midi" else { return [] }
        let pads = library.padMappings.indices.filter { library.matches(library.padMappings[$0], input: input) }
        let presets = library.presetMappings.indices.filter { library.matches(library.presetMappings[$0], input: input) }
        return pads.map { "Vinhetas · Pad \($0 + 1)" } + presets.map { "Vinhetas · Preset \($0 + 1)" }
    }
    func removeSetlistBlockConflicts(_ input: ControlInput) {
        guard !setlistBlockConflicts(input).isEmpty else { return }
        update { library in
            for index in library.padMappings.indices where library.matches(library.padMappings[index], input: input) {
                library.padMappings[index] = nil
            }
            for index in library.presetMappings.indices where library.matches(library.presetMappings[index], input: input) {
                library.presetMappings[index] = nil
            }
        }
    }
    func receive(input: ControlInput, value: UInt8) -> Bool {
        guard show != nil, audio != nil, let status = input.status, [0x80, 0x90, 0xb0].contains(status & 0xf0) else { return false }
        if library.acceptsChannel(input), let pad = learningPad, value > 0, status & 0xf0 != 0x80 {
            update { $0.padMappings[pad] = input }; learningPad = nil; return true
        }
        if library.acceptsChannel(input), let preset = learningPreset, value > 0, status & 0xf0 != 0x80 {
            update { $0.presetMappings[preset] = input }; learningPreset = nil; return true
        }
        let events = triggers.midi(input: input, value: value, library: library)
        dispatch(events)
        return !events.isEmpty || library.handles(input)
    }
    private func dispatch(_ events: [VinhetasTriggers.Event]) {
        for event in events {
            switch event {
            case .select(let index): select(index)
            case .stop(let id): (releaseVoice ?? stopVoice)?(id); finished(id)
            case .start(let voice):
                guard let path = library.presets[voice.preset].pads[voice.pad].audioFile else { continue }
                startVoice?(voice, directory.appendingPathComponent(path), library.presets[voice.preset].pads[voice.pad].volume)
                // Publish the visual state only after the audio source has
                // accepted the press. SwiftUI may synchronously refresh every
                // pad when this property changes.
                if voiceEngines[voice.id] != nil { voices[voice.id] = voice }
            }
        }
    }
    func importAudio(_ source: URL, preset: Int, pad: Int, origin: AudioOrigin = .picker) {
        guard !transferring, source.isFileURL, library.presets.indices.contains(preset),
              library.presets[preset].pads.indices.contains(pad) else { return }
        let key = preset * 16 + pad, request = UUID(), directory = directory
        let item = library.presets[preset].pads[pad]
        let name = source.deletingPathExtension().lastPathComponent
        let previous = item.audioFile
        if let previous, item.name.caseInsensitiveCompare(name) == .orderedSame ||
            previous.hasPrefix(VinhetasPad.sampleFolder + "/") &&
            URL(fileURLWithPath: previous).deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame { return }
        let managed = origin != .library || source.deletingLastPathComponent().standardizedFileURL == padSampleDirectory.standardizedFileURL
        let existing = managed ? padSample(named: name) : nil
        let generation = padSampleGeneration
        audioImports[key] = request
        Task {
            defer { if audioImports[key] == request { audioImports[key] = nil } }
            do {
                let (prepared, buffer) = try await Task.detached(priority: .userInitiated) {
                    if let existing { return (existing, try Self.readPadAudio(existing)) }
                    return try Self.prepareAudio(source, directory: directory)
                }.value
                var keepPrepared = false
                defer {
                    if existing == nil && !keepPrepared { try? FileManager.default.removeItem(at: prepared) }
                }
                guard audioImports[key] == request, !transferring, library.presets[preset].pads[pad].audioFile == previous else {
                    return
                }
                let path: String
                if managed {
                    guard generation == padSampleGeneration else { return }
                    let destination: URL
                    if let shared = padSample(named: name) { destination = shared }
                    else {
                        try FileManager.default.createDirectory(at: padSampleDirectory, withIntermediateDirectories: true)
                        destination = padSampleDirectory.appendingPathComponent(name).appendingPathExtension(prepared.pathExtension)
                        try FileManager.default.moveItem(at: prepared, to: destination)
                    }
                    path = VinhetasPad.sampleFolder + "/" + destination.lastPathComponent
                    if existing == destination || !FileManager.default.fileExists(atPath: prepared.path) { buffers[path] = buffer }
                } else {
                    path = prepared.lastPathComponent
                    buffers[path] = buffer
                    keepPrepared = true
                }
                error = ""
                update {
                    $0.presets[preset].pads[pad].audioFile = path
                    $0.presets[preset].pads[pad].name = name
                }
                if managed { NotificationCenter.default.post(name: Self.padSamplesChanged, object: nil) }
                preload()
            } catch {
                if audioImports[key] == request {
                    if origin != .picker { droppedAudioError = error.localizedDescription }
                    else { self.error = error.localizedDescription }
                }
            }
        }
    }
    private func padSample(named name: String) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: padSampleDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))?
            .first { VinhetasPad.accepts($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    func deletePadSamples() throws {
        guard !transferring else { throw ProjectError.invalid("Aguarde a transferência atual.") }
        let folder = padSampleDirectory
        if FileManager.default.fileExists(atPath: folder.path) {
            #if os(macOS)
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            #else
            try FileManager.default.removeItem(at: folder)
            #endif
        }
        padSampleGeneration += 1
        let prefix = VinhetasPad.sampleFolder + "/"
        let affectedVoices = voices.values.filter {
            library.presets[$0.preset].pads[$0.pad].audioFile?.hasPrefix(prefix) == true
        }
        for voice in affectedVoices { stopVoice?(voice.id); finished(voice.id) }
        buffers = buffers.filter { !$0.key.hasPrefix(prefix) }
        update { next in
            for p in next.presets.indices {
                for n in next.presets[p].pads.indices where next.presets[p].pads[n].audioFile?.hasPrefix(prefix) == true {
                    next.presets[p].pads[n].audioFile = nil
                }
            }
        }
        preload()
        NotificationCenter.default.post(name: Self.padSamplesChanged, object: nil)
    }

    nonisolated private static func readPadAudio(_ source: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: source)
        guard VinhetasPad.acceptsDuration(frames: file.length, sampleRate: file.processingFormat.sampleRate) else {
            throw ProjectError.invalid(JarasLocalization.string("Pads accept audio up to 60 seconds."))
        }
        guard file.length <= Int64(UInt32.max) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try PadAudioBuffer.read(file, frames: AVAudioFrameCount(file.length))
    }

    nonisolated private static func prepareAudio(_ source: URL, directory: URL) throws -> (URL, AVAudioPCMBuffer) {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let buffer = try readPadAudio(source)
        let direct = VinhetasPad.accepts(source)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(direct ? source.pathExtension.lowercased() : "wav")
        do {
            if direct {
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                let format = buffer.format
                let output = try AVAudioFile(forWriting: destination, settings: format.settings,
                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                try output.write(from: buffer)
            }
            return (destination, buffer)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    #if os(macOS)
    func insert(preset: Int, pad: Int) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.wav, .aiff, .mp3]
        panel.begin { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            self?.importAudio(source, preset: preset, pad: pad)
        }
    }
    #endif
}

struct VinhetasPanel: View {
    @ObservedObject var model: VinhetasController = .shared
    let createTrack: () -> Void
    var touchMenusEnabled = false
    @State private var edit: Edit?
    @State private var samplerDropTarget: Int?
    #if os(iOS)
    @State private var importing = false
    @State private var importTarget: (preset: Int, pad: Int)?
    #endif
    private struct Edit: Identifiable { let id = UUID(); let preset: Int; let pad: Int? }
    private var selected: Int { model.library.selectedPreset }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<6) { index in
                    Button { model.select(index) } label: {
                        Text(model.library.presets[index].name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(Color(hex: model.library.presets[index].color).opacity(selected == index ? 1 : 0.45))
                            .cornerRadius(5)
                    }.buttonStyle(.plain).contextMenu {
                        Button("Edit") { edit = Edit(preset: index, pad: nil) }
                        Button("Learn MIDI") { model.learningPad = nil; model.learningPreset = index }
                    }
                }
                Button { model.select(selected - 1) } label: { Image(systemName: "chevron.left") }.disabled(selected == 0)
                Button { model.select(selected + 1) } label: { Image(systemName: "chevron.right") }.disabled(selected == 5)
                Picker("MIDI", selection: Binding(get: { model.library.midiChannel ?? 0 }, set: { value in
                    model.update { $0.midiChannel = value == 0 ? nil : value }
                })) {
                    Text("Omni").tag(0)
                    ForEach(1...16, id: \.self) { Text(String($0)).tag($0) }
                }.frame(width: 112)
                Button(action: createTrack) {
                    Text("Create Track").font(.system(size: 12, weight: .semibold)).frame(width: 100, height: 30)
                        .foregroundStyle(Color.black).background(JarasTheme.green).cornerRadius(5)
                }.buttonStyle(.plain)
                Button(action: { model.panic() }) {
                    Text("Panic").font(.system(size: 12, weight: .semibold)).frame(width: 60, height: 30)
                        .foregroundStyle(Color.white).background(Color(hex: 0x8D2845)).cornerRadius(5)
                }.buttonStyle(.plain)
            }
            ForEach(0..<2) { row in
                HStack(spacing: 8) { ForEach(0..<8) { column in pad(row * 8 + column) } }
            }
            if model.learningPad != nil || model.learningPreset != nil {
                HStack { Text("Learn MIDI — aguardando controlador…"); Button("Cancel") { model.learningPad = nil; model.learningPreset = nil } }
            }
            if !model.error.isEmpty { Text(verbatim: model.error).foregroundStyle(.red).font(.caption) }
        }.padding(10).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .alert("Pads", isPresented: Binding(get: { model.droppedAudioError != nil }, set: {
                if !$0 { model.droppedAudioError = nil }
            })) {
                Button("OK") { model.droppedAudioError = nil }
            } message: {
                Text(verbatim: model.droppedAudioError ?? "")
            }
            #if os(macOS)
            .sheet(item: $edit) { editor($0) }
            #else
            .popover(item: $edit) { request in
                ScrollView { editor(request) }.frame(idealWidth: 340, idealHeight: 480).preferredColorScheme(.dark)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.wav, .aiff, .mp3]) { result in
                defer { importTarget = nil }
                guard let target = importTarget else { return }
                switch result {
                case .success(let url): model.importAudio(url, preset: target.preset, pad: target.pad)
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            #endif
    }
    private func editor(_ request: Edit) -> some View {
        let preset = model.library.presets[request.preset]
        return NameColorEditor(title: "Edit", initialName: request.pad.map { preset.pads[$0].name } ?? preset.name,
            initialColor: request.pad.map { preset.pads[$0].color } ?? preset.color,
            save: { name, color in
                model.update { state in
                    if let pad = request.pad { state.presets[request.preset].pads[pad].name = name; state.presets[request.preset].pads[pad].color = color }
                    else { state.presets[request.preset].name = name; state.presets[request.preset].color = color }
                }; edit = nil
            }, close: { edit = nil })
    }
    private func pad(_ index: Int) -> some View {
        let preset = selected, item = model.library.presets[preset].pads[index]
        let active = model.voices.values.contains { $0.preset == preset && $0.pad == index }
        let unlearnTitle = "Unlearn " + model.library.padMappingLabel(index)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button { model.gate(preset: preset, pad: index, enabled: !item.gate) } label: {
                    VStack(spacing: 1) { Text("Gate"); Text(verbatim: item.gate ? "On" : "Off") }
                        .font(.system(size: 10, weight: .semibold)).frame(width: 34, height: 40)
                }.buttonStyle(.plain)
                    .foregroundStyle(item.gate ? Color.black : JarasTheme.secondary)
                    .background(item.gate ? JarasTheme.yellow : Color.clear).cornerRadius(4)
                #if os(macOS)
                VinhetasPadSurface(name: item.name, color: item.color, active: active,
                    down: { model.down(index) }, up: { model.up(index) },
                    importSample: { url, origin in model.importAudio(url, preset: preset, pad: index, origin: origin) })
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contextMenu {
                        Button("Edit") { edit = Edit(preset: preset, pad: index) }
                        Button("Insert audio") { model.insert(preset: preset, pad: index) }
                        Button("Learn MIDI") { model.learningPreset = nil; model.learningPad = index }
                        if model.library.padMappings[index] != nil {
                            Button { model.unlearnPad(index) } label: { Text(verbatim: unlearnTitle) }
                        }
                    }
                #else
                VinhetasPadSurface(name: item.name, color: item.color, active: active,
                    down: { model.down(index) }, up: { model.up(index) }, touchMenusEnabled: touchMenusEnabled,
                    edit: { edit = Edit(preset: preset, pad: index) },
                    insert: { importTarget = (preset, index); importing = true },
                    learn: { model.learningPreset = nil; model.learningPad = index },
                    unlearnTitle: unlearnTitle,
                    unlearn: model.library.padMappings[index] == nil ? nil : { model.unlearnPad(index) })
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .onDrop(of: [LibrarySamplerTransfer.type], isTargeted: Binding(
                        get: { samplerDropTarget == index }, set: { active in
                            if active { samplerDropTarget = index }
                            else if samplerDropTarget == index { samplerDropTarget = nil }
                        })) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadDataRepresentation(forTypeIdentifier: LibrarySamplerTransfer.type.identifier) { data, _ in
                                guard let url = LibrarySamplerTransfer.url(data) else { return }
                                Task { @MainActor in model.importAudio(url, preset: preset, pad: index, origin: .library) }
                            }
                            return true
                        }
                    .overlay {
                        if samplerDropTarget == index {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(JarasTheme.green, lineWidth: 2).allowsHitTesting(false)
                        }
                    }
                #endif
            }
            HStack(spacing: 6) {
                Text(item.volume <= 0 ? "−∞" : String(format: "%+.1f", 20 * log10(item.volume)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit().frame(width: 34, alignment: .leading)
                VinhetasFader(value: Binding(get: { model.library.presets[preset].pads[index].volume }, set: { model.volume(preset: preset, pad: index, value: $0) }))
            }
            #if os(macOS)
            .frame(height: 20)
            #else
            .frame(height: 44)
            #endif
        }.frame(maxWidth: .infinity)
    }
}
#if os(macOS)
private struct VinhetasFader: NSViewRepresentable {
    @Binding var value: Double
    func makeNSView(context: Context) -> Fader { Fader() }
    func updateNSView(_ view: Fader, context: Context) {
        view.value = value; view.changed = { value = $0 }; view.needsDisplay = true
    }
    final class Fader: NSView {
        var value = 1.0; var changed: ((Double) -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { value = 1; changed?(value); needsDisplay = true }
            else { move(event) }
        }
        override func mouseDragged(with event: NSEvent) { move(event) }
        private func move(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            value = min(2, max(0, Double((point.x - 6) / max(1, bounds.width - 12)) * 2))
            changed?(value); needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: bounds.midY - 3, width: max(0, bounds.width - 12), height: 6), xRadius: 3, yRadius: 3).fill()
            let x = 6 + max(0, bounds.width - 12) * min(1, max(0, value / 2))
            NSColor(white: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 6, y: bounds.midY - 9, width: 12, height: 18), xRadius: 2, yRadius: 2).fill()
            NSColor.darkGray.setFill()
            NSRect(x: x - 0.5, y: bounds.midY - 6, width: 1, height: 12).fill()
        }
    }
}
private struct VinhetasPadSurface: NSViewRepresentable {
    let name: String; let color: UInt32; let active: Bool
    let down: () -> Void; let up: () -> Void
    let importSample: (URL, VinhetasController.AudioOrigin) -> Void
    func makeNSView(context: Context) -> Pad { Pad() }
    func updateNSView(_ view: Pad, context: Context) {
        view.name = name; view.color = NSColor(Color(hex: color)); view.active = active
        view.down = down; view.up = up; view.importSample = importSample; view.needsDisplay = true
    }
    final class Pad: NSView {
        var name = "", color = NSColor.gray
        var active = false, pressed = false
        var down: (() -> Void)?, up: (() -> Void)?
        var importSample: ((URL, VinhetasController.AudioOrigin) -> Void)?
        private var receiving = false
        private static let sampleType = NSPasteboard.PasteboardType(LibrarySamplerTransfer.type.identifier)
        override init(frame: CGRect) {
            super.init(frame: frame)
            registerForDraggedTypes([Self.sampleType, .fileURL])
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            receiving = dropAudio(sender.draggingPasteboard) != nil && sender.draggingSourceOperationMask.contains(.copy)
            needsDisplay = true
            return receiving ? .copy : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { receiving = false; needsDisplay = true }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            receiving = false; needsDisplay = true
            guard let (url, origin) = dropAudio(sender.draggingPasteboard) else { return false }
            importSample?(url, origin)
            return true
        }
        private func dropAudio(_ pasteboard: NSPasteboard) -> (URL, VinhetasController.AudioOrigin)? {
            if let url = LibrarySamplerTransfer.url(pasteboard.data(forType: Self.sampleType)) { return (url, .library) }
            guard let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  files.count == 1, let url = files.first,
                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return (url, .fileDrop)
        }
        override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true; down?() }
        override func mouseUp(with event: NSEvent) { pressed = false; needsDisplay = true; up?() }
        override func draw(_ dirtyRect: NSRect) {
            let lit = active || pressed
            let fill = lit ? color.blended(withFraction: 0.18, of: .white) ?? color : color.withAlphaComponent(0.45)
            fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            if lit {
                (color.blended(withFraction: 0.6, of: .white) ?? .white).setStroke()
                let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                edge.lineWidth = 2; edge.stroke()
            }
            if receiving {
                NSColor(JarasTheme.green).setStroke()
                let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                edge.lineWidth = 2; edge.stroke()
            }
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (name as NSString).draw(in: NSRect(x: 3, y: (bounds.height - 16) / 2, width: bounds.width - 6, height: 18), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white, .paragraphStyle: style])
        }
    }
}

@MainActor final class VinhetasWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var detached = false
    @Published private(set) var visible = false
    private var window: NSWindow?
    func open(show: ShowController) {
        VinhetasController.shared.bind(show: show)
        if let window { window.makeKeyAndOrderFront(nil); visible = true; WorkspaceLayoutPreferences.storage.set(true, forKey: "jaras.layout.vinhetas.visible"); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 260), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "CatLive · Vinhetas"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.minSize = NSSize(width: 850, height: 260)
        panel.contentView = NSHostingView(rootView: VinhetasPanel(createTrack: { _ = show.createVinhetasTrack() }).interfaceScaled())
        if !panel.setFrameUsingName("CatLiveVinhetas", force: true) { panel.center() }
        panel.setFrameAutosaveName("CatLiveVinhetas"); window = panel; detached = true; visible = true
        panel.makeKeyAndOrderFront(nil)
        WorkspaceLayoutPreferences.storage.set(true, forKey: "jaras.layout.vinhetas.detached")
        WorkspaceLayoutPreferences.storage.set(true, forKey: "jaras.layout.vinhetas.visible")
    }
    func toggle(show: ShowController) { if visible { hide() } else { open(show: show) } }
    func hide(preserveState: Bool = false) { window?.orderOut(nil); visible = false; if !preserveState { WorkspaceLayoutPreferences.storage.set(false, forKey: "jaras.layout.vinhetas.visible") } }
    func dock() { window?.delegate = nil; window?.close(); window = nil; detached = false; visible = false; WorkspaceLayoutPreferences.storage.set(false, forKey: "jaras.layout.vinhetas.detached") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}
#endif

#if os(iOS)
private struct VinhetasFader: View {
    @Binding var value: Double
    var body: some View {
        RemoteNativeSlider(value: value, range: 0...2, height: 44, resetValue: 1, locksScrolling: true) { value = $0 }
            .accessibilityLabel("Volume do pad")
    }
}
struct VinhetasPadSurface: UIViewRepresentable {
    let name: String; let color: UInt32; let active: Bool
    let down: () -> Void; let up: () -> Void
    let touchMenusEnabled: Bool
    var contextMenusEnabled = true
    let edit: () -> Void; let insert: () -> Void; let learn: () -> Void
    var unlearnTitle = "Unlearn CC"
    var unlearn: (() -> Void)? = nil
    func makeUIView(context: Context) -> Pad { Pad() }
    func updateUIView(_ view: Pad, context: Context) {
        view.name = name; view.unlearnTitle = unlearnTitle; view.unlearn = unlearn; view.color = UIColor(Color(hex: color)); view.active = active
        view.down = down; view.up = up; view.accessibilityLabel = name
        view.touchMenusEnabled = touchMenusEnabled; view.contextMenusEnabled = contextMenusEnabled
        view.edit = edit; view.insert = insert; view.learn = learn
        view.accessibilityValue = active ? "Tocando" : "Parado"; view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: Pad, coordinator: ()) { view.release() }
    final class Pad: UIView, UIContextMenuInteractionDelegate {
        var name = "", unlearnTitle = "Unlearn CC", color = UIColor.gray, active = false, pressed = false
        var unlearn: (() -> Void)?
        var down: (() -> Void)?, up: (() -> Void)?
        var touchMenusEnabled = false, secondaryMenu = false, contextMenusEnabled = true
        var edit: (() -> Void)?, insert: (() -> Void)?, learn: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame); isOpaque = false; isAccessibilityElement = true; accessibilityTraits = .button
            addInteraction(UIContextMenuInteraction(delegate: self))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        // Record the secondary press before UIKit's menu recognizer consumes it.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if let event, event.type == .touches {
                if event.buttonMask.contains(.secondary) { secondaryMenu = true }
                else if event.allTouches?.contains(where: { $0.phase == .began }) == true { secondaryMenu = false }
            }
            return super.hitTest(point, with: event)
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard contextMenusEnabled && (touchMenusEnabled || secondaryMenu) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var actions: [UIMenuElement] = [
                    UIAction(title: JarasLocalization.string("Edit")) { [weak self] _ in self?.edit?() },
                    UIAction(title: JarasLocalization.string("Insert audio")) { [weak self] _ in self?.insert?() },
                    UIAction(title: "Learn MIDI") { [weak self] _ in self?.learn?() }
                ]
                if let self, self.unlearn != nil {
                    actions.append(UIAction(title: self.unlearnTitle) { [weak self] _ in self?.unlearn?() })
                }
                return UIMenu(children: actions)
            }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            secondaryMenu = event?.buttonMask.contains(.secondary) == true
            guard !secondaryMenu, !pressed else { return }
            pressed = true; setNeedsDisplay(); down?()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
        func release() { guard pressed else { return }; pressed = false; setNeedsDisplay(); up?() }
        override func accessibilityActivate() -> Bool { down?(); up?(); return true }
        override func draw(_ rect: CGRect) {
            let lit = active || pressed
            color.withAlphaComponent(lit ? 1 : 0.45).setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: 5).fill()
            if lit {
                UIColor.white.withAlphaComponent(0.25).setFill(); UIBezierPath(roundedRect: bounds, cornerRadius: 5).fill()
                UIColor.white.withAlphaComponent(0.7).setStroke()
                let border = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 5)
                border.lineWidth = 2; border.stroke()
            }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            (name as NSString).draw(in: CGRect(x: 3, y: (bounds.height - 18) / 2, width: bounds.width - 6, height: 18),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.white, .paragraphStyle: style])
        }
    }
}

/// The entire 8×2 bank fits its panel and stays fixed, including empty areas.
struct IpadVinhetasPanel: View {
    let touchMenusEnabled: Bool
    let createTrack: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let scale = max(0.01, min(1, min(geometry.size.width / 1000, geometry.size.height / 260)))
            VinhetasPanel(createTrack: createTrack, touchMenusEnabled: touchMenusEnabled)
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }.background(JarasTheme.panel)
    }
}

/// An independent panel inside the workspace, without a blocking modal backdrop.
struct IpadVinhetasFloatingPanel: View {
    let touchMenusEnabled: Bool
    let createTrack: () -> Void
    var remoteContent: AnyView? = nil
    let dock: () -> Void
    let close: () -> Void
    @AppStorage("jaras.ipad.vinhetas.x") private var savedX = 24.0
    @AppStorage("jaras.ipad.vinhetas.y") private var savedY = 80.0
    @AppStorage("jaras.ipad.vinhetas.width") private var savedWidth = 1040.0
    @AppStorage("jaras.ipad.vinhetas.height") private var savedHeight = 280.0
    @GestureState private var movement = CGSize.zero
    @GestureState private var sizing = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, max(min(480, geometry.size.width), savedWidth + sizing.width))
            let height = min(geometry.size.height, max(min(240, geometry.size.height), savedHeight + sizing.height))
            let x = min(max(0, savedX + movement.width), max(0, geometry.size.width - width))
            let y = min(max(0, savedY + movement.height), max(0, geometry.size.height - height))
            VStack(spacing: 0) {
                HStack {
                    Text("Vinhetas").font(.jarasHeadline)
                    Spacer()
                    Button(action: dock) { Image(systemName: "pin.fill").frame(width: 36, height: 36) }.accessibilityLabel("Indexar")
                    Button(action: close) { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("Close")
                }.padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 5).updating($movement) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            savedX = min(max(0, savedX + value.translation.width), max(0, geometry.size.width - width))
                            savedY = min(max(0, savedY + value.translation.height), max(0, geometry.size.height - height))
                        })
                Divider()
                if let remoteContent { remoteContent }
                else { IpadVinhetasPanel(touchMenusEnabled: touchMenusEnabled, createTrack: createTrack) }
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12))
                        .frame(width: 32, height: 24).contentShape(Rectangle())
                        .gesture(DragGesture().updating($sizing) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                savedWidth = min(geometry.size.width, max(min(480, geometry.size.width), savedWidth + value.translation.width))
                                savedHeight = min(geometry.size.height, max(min(240, geometry.size.height), savedHeight + value.translation.height))
                            }).accessibilityLabel("Resize Vinhetas")
                }
            }.frame(width: width, height: height).background(JarasTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(JarasTheme.line))
                .shadow(color: .black.opacity(0.4), radius: 10)
                .foregroundStyle(JarasTheme.text).buttonStyle(.plain).offset(x: x, y: y)
        }
    }
}
#endif

#if os(macOS)
private final class PadsPickerWindowReference { weak var window: NSWindow? }
private struct PadsPickerWindowCapture: NSViewRepresentable {
    let reference: PadsPickerWindowReference
    final class CaptureView: NSView {
        var reference: PadsPickerWindowReference?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference?.window = window }
    }
    func makeNSView(context: Context) -> CaptureView { let view = CaptureView(); view.reference = reference; return view }
    func updateNSView(_ view: CaptureView, context: Context) { view.reference = reference; reference.window = view.window }
}
#endif

struct AdvancedPadsSettings: View {
    #if os(macOS)
    @State private var pickerWindow = PadsPickerWindowReference()
    @State private var choosingFile = false
    #endif
    @ObservedObject private var model = VinhetasController.shared
    @State private var progress = 0.0
    @State private var message = ""
    @State private var failed = false
    @State private var importing = false
    private struct Exported: Identifiable { let url: URL; var id: URL { url } }
    @State private var exported: Exported?
    @State private var temporary: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transfira os seis presets completos, com nomes, cores, volumes, Gate, mapeamentos MIDI e áudios, em um arquivo .zipfx.")
                .font(.jarasCallout).fixedSize(horizontal: false, vertical: true)
            Text("Import Presets substitui os seis presets atuais. Uma cópia da configuração anterior é guardada no dispositivo.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Export Preset", action: export).accessibilityIdentifier("pads-export-presets")
                Button("Import Presets", action: chooseImport).accessibilityIdentifier("pads-import-presets")
            }.disabled(model.transferring)
            if model.transferring { ProgressView(value: progress); Text("Transferindo…").font(.jarasCaption) }
            if !message.isEmpty { Text(verbatim: message).font(.jarasCaption).foregroundStyle(failed ? .red : JarasTheme.green) }
        }
        #if os(macOS)
        .background(PadsPickerWindowCapture(reference: pickerWindow).frame(width: 0, height: 0))
        .disabled(choosingFile)
        #else
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "zipfx") ?? .data]) { result in
            switch result { case .success(let url): run(url, importing: true); case .failure(let error): finish(error) }
        }
        .sheet(item: $exported, onDismiss: cleanup) { file in
            NativePackageExporter(url: file.url, finished: { exported = nil })
        }
        #endif
    }
    private func finish(_ error: Error?) { failed = error != nil; message = error?.localizedDescription ?? "Concluído." }
    private func cleanup() { if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil }
    private func export() {
        guard !model.transferring else { return }
        #if os(macOS)
        guard !choosingFile, let owner = pickerWindow.window else { return }
        let picker = NSSavePanel(); picker.allowedFileTypes = ["zipfx"]; picker.nameFieldStringValue = "CatLive-Pads.zipfx"
        choosingFile = true
        picker.beginSheetModal(for: owner) { response in
            choosingFile = false
            if response == .OK, let url = picker.url { run(url, importing: false) }
        }
        #else
        cleanup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatLive-Pads-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); temporary = directory }
        catch { finish(error); return }
        run(directory.appendingPathComponent("CatLive-Pads.zipfx"), importing: false)
        #endif
    }
    private func chooseImport() {
        guard !model.transferring else { return }
        #if os(macOS)
        guard !choosingFile, let owner = pickerWindow.window else { return }
        let picker = NSOpenPanel(); picker.allowedFileTypes = ["zipfx"]; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        choosingFile = true
        picker.beginSheetModal(for: owner) { response in
            choosingFile = false
            if response == .OK, let url = picker.url { run(url, importing: true) }
        }
        #else
        importing = true
        #endif
    }
    private func run(_ url: URL, importing: Bool) {
        message = ""; failed = false; progress = 0
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let report: @Sendable (Double) -> Void = { value in Task { @MainActor in progress = value } }
                if importing { try await model.importPresets(from: url, progress: report) }
                else { try await model.exportPresets(to: url, progress: report) }
                finish(nil)
                #if os(iOS)
                if !importing { exported = Exported(url: url) }
                #endif
            } catch { finish(error) }
        }
    }
}
