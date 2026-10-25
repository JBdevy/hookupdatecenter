import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers
import AVFoundation

@MainActor final class VinhetasController: ObservableObject {
    static let shared = VinhetasController()
    @Published private(set) var library = VinhetasLibrary()
    @Published private(set) var voices: [UUID: VinhetasTriggers.Voice] = [:]
    @Published var learningPad: Int?
    @Published var learningPreset: Int?
    @Published var error = ""
    var startVoice: ((VinhetasTriggers.Voice, URL, Double) -> Void)?
    var stopVoice: ((UUID) -> Void)?
    var changeVolume: ((Int, Int, Double) -> Void)?
    private var triggers = VinhetasTriggers()
    private var remotePresses: [UUID] = []
    private weak var show: ShowController?
    private weak var audio: StemAudioPlayback?
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var loadingGeneration = 0
    private let persistence = DispatchQueue(label: "CatLive.Vinhetas.persistence", qos: .utility)
    private var voiceEngines: [UUID: StemAudioPlayback] = [:]
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
            guard let buffer = self.buffers[url.lastPathComponent], let audio = self.audio else {
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
                        guard file.length > 0, file.length <= Int64(UInt32.max),
                              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
                        try file.read(into: buffer); result[path] = buffer
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
    func select(_ index: Int) { update { $0.select(index) }; preload() }
    func volume(preset: Int, pad: Int, value: Double) {
        update { $0.presets[preset].pads[pad].volume = value }
        changeVolume?(preset, pad, value)
    }
    func gate(preset: Int, pad: Int, enabled: Bool) {
        if enabled && !library.presets[preset].pads[pad].gate {
            let ids = voices.values.filter { $0.preset == preset && $0.pad == pad }.map(\.id)
            for id in ids { stopVoice?(id); finished(id) }
        }
        update { $0.presets[preset].pads[pad].gate = enabled }
    }
    func panic() {
        for id in Array(voices.keys) { stopVoice?(id); finished(id) }
    }
    var remoteState: DAWRemoteVinhetas {
        .init(selectedPreset: library.selectedPreset,
            available: show?.current?.tracks.contains { $0.role.rawValue == "vinhetas" } == true,
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
            guard remoteState.available, let id = command.target, voices[id] == nil,
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
    func down(_ pad: Int) { dispatch(triggers.mouseDown(pad: pad, library: library)) }
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
            case .stop(let id): stopVoice?(id); finished(id)
            case .start(let voice):
                guard let path = library.presets[voice.preset].pads[voice.pad].audioFile else { continue }
                voices[voice.id] = voice
                startVoice?(voice, directory.appendingPathComponent(path), library.presets[voice.preset].pads[voice.pad].volume)
            }
        }
    }
    func importAudio(_ source: URL, preset: Int, pad: Int) {
        guard VinhetasPad.accepts(source), library.presets.indices.contains(preset),
              library.presets[preset].pads.indices.contains(pad) else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            let name = UUID().uuidString + "." + source.pathExtension.lowercased()
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            do { _ = try AVAudioFile(forReading: destination) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            update { $0.presets[preset].pads[pad].audioFile = name }; preload()
        } catch { self.error = error.localizedDescription }
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
                    down: { model.down(index) }, up: { model.up(index) })
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contextMenu {
                        Button("Edit") { edit = Edit(preset: preset, pad: index) }
                        Button("Insert audio") { model.insert(preset: preset, pad: index) }
                        Button("Learn MIDI") { model.learningPreset = nil; model.learningPad = index }
                    }
                #else
                VinhetasPadSurface(name: item.name, color: item.color, active: active,
                    down: { model.down(index) }, up: { model.up(index) }, touchMenusEnabled: touchMenusEnabled,
                    edit: { edit = Edit(preset: preset, pad: index) },
                    insert: { importTarget = (preset, index); importing = true },
                    learn: { model.learningPreset = nil; model.learningPad = index })
                    .frame(maxWidth: .infinity, minHeight: 58)
                #endif
            }
            HStack(spacing: 6) {
                Text(item.volume <= 0 ? "−∞" : String(format: "%+.1f", 20 * log10(item.volume)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit().frame(width: 34, alignment: .leading)
                VinhetasFader(value: Binding(get: { model.library.presets[preset].pads[index].volume }, set: { model.volume(preset: preset, pad: index, value: $0) }))
            }.frame(height: 20)
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
        override func mouseDown(with event: NSEvent) { move(event) }
        override func mouseDragged(with event: NSEvent) { move(event) }
        private func move(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            value = min(2, max(0, Double((point.x - 7) / max(1, bounds.width - 14)) * 2))
            changed?(value); needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.5, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 7, y: (bounds.height - 4) / 2, width: max(0, bounds.width - 14), height: 4), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: max(0, bounds.width - 14) * value / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)).fill()
        }
    }
}
private struct VinhetasPadSurface: NSViewRepresentable {
    let name: String; let color: UInt32; let active: Bool
    let down: () -> Void; let up: () -> Void
    func makeNSView(context: Context) -> Pad { Pad() }
    func updateNSView(_ view: Pad, context: Context) {
        view.name = name; view.color = NSColor(Color(hex: color)); view.active = active
        view.down = down; view.up = up; view.needsDisplay = true
    }
    final class Pad: NSView {
        var name = "", color = NSColor.gray
        var active = false, pressed = false
        var down: (() -> Void)?, up: (() -> Void)?
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
        if let window { window.makeKeyAndOrderFront(nil); visible = true; UserDefaults.standard.set(true, forKey: "jaras.layout.vinhetas.visible"); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 260), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "CatLive · Vinhetas"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.minSize = NSSize(width: 850, height: 260)
        panel.contentView = NSHostingView(rootView: VinhetasPanel(createTrack: { _ = show.createVinhetasTrack() }).interfaceScaled())
        if !panel.setFrameUsingName("CatLiveVinhetas", force: true) { panel.center() }
        panel.setFrameAutosaveName("CatLiveVinhetas"); window = panel; detached = true; visible = true
        panel.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "jaras.layout.vinhetas.detached")
        UserDefaults.standard.set(true, forKey: "jaras.layout.vinhetas.visible")
    }
    func toggle(show: ShowController) { if visible { hide() } else { open(show: show) } }
    func hide(preserveState: Bool = false) { window?.orderOut(nil); visible = false; if !preserveState { UserDefaults.standard.set(false, forKey: "jaras.layout.vinhetas.visible") } }
    func dock() { window?.delegate = nil; window?.close(); window = nil; detached = false; visible = false; UserDefaults.standard.set(false, forKey: "jaras.layout.vinhetas.detached") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}
#endif

#if os(iOS)
private struct VinhetasFader: View {
    @Binding var value: Double
    var body: some View {
        RemoteNativeSlider(value: value, range: 0...2, height: 20, resetValue: 1) { value = $0 }
            .accessibilityLabel("Volume do pad")
    }
}
struct VinhetasPadSurface: UIViewRepresentable {
    let name: String; let color: UInt32; let active: Bool
    let down: () -> Void; let up: () -> Void
    let touchMenusEnabled: Bool
    var contextMenusEnabled = true
    let edit: () -> Void; let insert: () -> Void; let learn: () -> Void
    func makeUIView(context: Context) -> Pad { Pad() }
    func updateUIView(_ view: Pad, context: Context) {
        view.name = name; view.color = UIColor(Color(hex: color)); view.active = active
        view.down = down; view.up = up; view.accessibilityLabel = name
        view.touchMenusEnabled = touchMenusEnabled; view.contextMenusEnabled = contextMenusEnabled
        view.edit = edit; view.insert = insert; view.learn = learn
        view.accessibilityValue = active ? "Tocando" : "Parado"; view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: Pad, coordinator: ()) { view.release() }
    final class Pad: UIView, UIContextMenuInteractionDelegate {
        var name = "", color = UIColor.gray, active = false, pressed = false
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
                UIMenu(children: [
                    UIAction(title: JarasLocalization.string("Edit")) { [weak self] _ in self?.edit?() },
                    UIAction(title: JarasLocalization.string("Insert audio")) { [weak self] _ in self?.insert?() },
                    UIAction(title: "Learn MIDI") { [weak self] _ in self?.learn?() }
                ])
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

/// The bank keeps the desktop 8×2 arrangement; smaller windows can scroll it.
struct IpadVinhetasPanel: View {
    let touchMenusEnabled: Bool
    let createTrack: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                VinhetasPanel(createTrack: createTrack, touchMenusEnabled: touchMenusEnabled).frame(width: max(1000, geometry.size.width), alignment: .topLeading)
            }
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
