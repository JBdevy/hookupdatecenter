import SwiftUI
import Combine
import UniformTypeIdentifiers
import AVFoundation

@MainActor enum DrummerMIDILearn {
    static var owner: UUID?
    static var pending: Bool { owner != nil }
}

struct DrummerPadEditor: View {
    let kind: DrummerPadKind
    @Binding var kit: DrummerPadKit
    let audio: StemAudioPlayback
    let track: UUID?
    let effect: String
    @State private var owner = UUID()
    @State private var learning: Int?
    @State private var glow: [Int: Date] = [:]
    @State private var dropIndex: Int?
    @State private var editing: Int?
    @State private var choosingAudio = false
    @State private var audioTarget: Int?
    @State private var imports: [Int: UUID] = [:]
    @State private var name = ""
    @State private var saveName = ""
    @State private var saving = false
    @State private var browsing = false
    @State private var library = FXPresetLibrary()
    @State private var selectedPreset: String?
    @State private var error = ""
    private let clock = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    private var entries: [FXPreset] { library.entries(for: "native:" + kind.rawValue) }
    private var selected: FXPreset? { entries.first { $0.id == selectedPreset } }
    private let accent = Color(red: 0.37, green: 0.91, blue: 0.68)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { browsing.toggle() } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Presets").popover(isPresented: $browsing) { presetList }
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.disabled(entries.isEmpty)
                Text(verbatim: selected?.name ?? (kit == DrummerPadKit(kind) ? "Default" : "Custom"))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(Color(red: 0.72, green: 0.89, blue: 0.83))
                    .frame(minWidth: 105, minHeight: 22)
                    .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 3))
                    .contextMenu { if let selected { Button("Delete preset") { remove(selected) } } }
                Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(entries.isEmpty)
                Spacer()
                Button { saveName = ""; saving = true } label: { Image(systemName: "plus") }.accessibilityLabel("Save preset")
            }.buttonStyle(.plain).foregroundStyle(Color(white: 0.91))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 4))
            GeometryReader { geometry in
                let columns = kind.columns
                let rows = kind.count / columns
                let gap: CGFloat = kind == .compact ? 9 : 5
                let knob: CGFloat = kind == .compact ? 25 : 19
                let legend: CGFloat = 16
                let side = max(1, min((geometry.size.width + gap) / CGFloat(columns) - gap - knob - 3,
                                      (geometry.size.height + gap) / CGFloat(rows) - gap - legend))
                let cellWidth = side + 3 + knob
                let tracks = Array(repeating: GridItem(.fixed(cellWidth), spacing: gap), count: columns)
                LazyVGrid(columns: tracks, spacing: gap) {
                    ForEach(kit.pads.indices, id: \.self) { index in
                        pad(index, side: side, knob: knob, legend: legend)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: kind == .compact ? 241 : 275, idealHeight: kind == .compact ? 360 : 386)
            HStack {
                Text("Volume").font(.caption.bold())
                Slider(value: $kit.volume, in: 0...1).tint(accent)
                Text(verbatim: db(kit.volume)).monospacedDigit().frame(width: 72)
            }.padding(.horizontal, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.10)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.12)).allowsHitTesting(false))
        .overlay {
            Canvas { context, size in
                for x in [CGFloat(6), size.width - 6] {
                    for y in [CGFloat(6), size.height - 6] {
                        let head = CGRect(x: x - 2.3, y: y - 2.3, width: 4.6, height: 4.6)
                        context.fill(Path(ellipseIn: head), with: .color(Color(white: 0.24)))
                        var slot = Path()
                        slot.move(to: CGPoint(x: x - 1.15, y: y + 0.9))
                        slot.addLine(to: CGPoint(x: x + 1.15, y: y - 0.9))
                        context.stroke(slot, with: .color(Color(white: 0.055)), lineWidth: 1)
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .onAppear { reload(); selectedPreset = entries.first { $0.native?.drumKit(kind) == kit }?.id }
        .onReceive(NotificationCenter.default.publisher(for: FXPresetStore.didChange)) { _ in reload() }
        .onReceive(clock) { now in
            var next = glow.filter { $0.value > now }
            let bits = audio.effects(for: track)?.drummerVoices[effect]?.source.flashes() ?? 0
            for i in kit.pads.indices where bits & (UInt64(1) << i) != 0 { next[i] = now.addingTimeInterval(0.14) }
            if next != glow { glow = next }
        }
        .onReceive(NotificationCenter.default.publisher(for: StemAudioPlayback.drumLearningNote, object: audio)) { event in
            guard DrummerMIDILearn.owner == owner, let i = learning, let note = event.userInfo?["note"] as? Int else { return }
            kit.map(note: note, to: i); stopLearning()
        }
        .onDisappear { stopLearning() }
        .fileImporter(isPresented: $choosingAudio, allowedContentTypes: [.wav, .aiff, .mp3]) { result in
            defer { audioTarget = nil }
            guard let i = audioTarget else { return }
            switch result {
            case .success(let url): insertAudio(url, at: i)
            case .failure(let failure):
                if (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
            }
        }
        .alert("Rename pad", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { if let i = editing { kit.pads[i].name = name }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .alert("Save preset", isPresented: $saving) {
            TextField("Name", text: $saveName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(Text(verbatim: error), isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
            Button("OK") { error = "" }
        }
    }
    private func db(_ v: Double) -> String { v <= 0 ? "−∞ dB" : String(format: "%.1f dB", 20 * log10(v)) }
    private static let padPalette: [UInt32] = [
        0xe1d49d, 0xe9acac, 0xbeb4ed, 0x96d9dc,
        0xe3b6cd, 0xaad9ae, 0x9ebfe8, 0xc1a1dc
    ]

    private func pad(_ i: Int, side: CGFloat, knob: CGFloat, legend: CGFloat) -> some View {
        let slot = kit.pads[i]
        let paletteIndex = (i / kind.columns % 2) * 4 + (i % kind.columns % 4)
        let rgb = Self.padPalette[paletteIndex]
        let tint = Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        let isLearning = learning == i && DrummerMIDILearn.owner == owner
        let active = glow[i] != nil
        let target = dropIndex == i
        let key = RoundedRectangle(cornerRadius: min(5, side * 0.065), style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Button {
                    audio.playDrumPad(track, effect: effect, index: i)
                } label: {
                    ZStack {
                        key.fill(Color(white: 0.045))
                        key.inset(by: 1.5).fill(tint)
                        key.inset(by: 1.5).fill(LinearGradient(
                            colors: [.white.opacity(active ? 0.82 : 0.14), .clear,
                                     .black.opacity(active ? 0 : (slot.sample == nil ? 0.20 : 0.12))],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        key.inset(by: 2).strokeBorder(Color.white.opacity(active ? 0.9 : 0.25))
                        if target || isLearning {
                            key.inset(by: 2).strokeBorder(target ? Color.white : .yellow, lineWidth: 2)
                        }
                    }
                    .shadow(color: active ? tint.opacity(0.85) : .clear, radius: 4)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).frame(width: side, height: side)
                    .accessibilityLabel(Text(verbatim: "Pad \(i + 1) \(slot.name)"))
                FXKnob("Volume", value: $kit.pads[i].volume, range: 0...1, unit: "%", multiplier: 100, reset: 1, dialOnly: true)
                    .environment(\.fxKnobDiameter, knob).environment(\.fxDialAccent, tint)
                    .accessibilityLabel("Volume")
            }
            HStack(spacing: 3) {
                Text(verbatim: String(format: "%02d", i + 1)).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.87))
                Text(verbatim: isLearning ? "Learn MIDI…" : slot.name).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isLearning ? Color.yellow : Color(white: 0.80)).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: legend, maxHeight: legend, alignment: .leading)
        }.contextMenu {
            Button("Insert audio") { audioTarget = i; choosingAudio = true }
            Button("Rename pad") { name = slot.name; editing = i }
            Button("Learn MIDI") { DrummerMIDILearn.owner = owner; learning = i }
            if let note = slot.note { Button("Unlearn Note \(note)") { kit.pads[i].note = nil; stopLearning() } }
        }.onDrop(of: [LibrarySamplerTransfer.type], isTargeted: Binding(get: { dropIndex == i },
            set: { value in if value { dropIndex = i } else if dropIndex == i { dropIndex = nil } })) { providers in
            guard let p = providers.first else { return false }
            p.loadDataRepresentation(forTypeIdentifier: LibrarySamplerTransfer.type.identifier) { data, _ in
                guard let url = LibrarySamplerTransfer.url(data), DrummerSamples.reference(url) != nil else { return }
                DispatchQueue.main.async { insertAudio(url, at: i) }
            }
            return true
        }
    }
    private func assign(_ reference: String, from source: URL, at index: Int) {
        guard kit.pads.indices.contains(index) else { return }
        imports[index] = nil
        kit.pads[index].sample = reference
        kit.pads[index].name = source.deletingPathExtension().lastPathComponent
    }
    private func insertAudio(_ source: URL, at index: Int) {
        let request = UUID()
        imports[index] = request
        let directory = VinhetasController.shared.padSampleDirectory
        Task { @MainActor in
            defer { if imports[index] == request { imports[index] = nil } }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    if DrummerSamples.reference(source) != nil {
                        let scoped = source.startAccessingSecurityScopedResource()
                        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                        let audio = try AVAudioFile(forReading: source)
                        guard VinhetasPad.acceptsDuration(frames: audio.length, sampleRate: audio.fileFormat.sampleRate) else {
                            throw ProjectError.invalid(JarasLocalization.string("Pads accept audio up to 60 seconds."))
                        }
                        return source
                    }
                    return try WorkspaceLibrary.copySampler(source, into: directory, forPad: true)
                }.value
                NotificationCenter.default.post(name: VinhetasController.padSamplesChanged, object: nil)
                guard imports[index] == request else { return }
                guard let reference = DrummerSamples.reference(file) else { throw CocoaError(.fileReadInvalidFileName) }
                assign(reference, from: source, at: index)
            } catch {
                if imports[index] == request { self.error = error.localizedDescription }
            }
        }
    }
    private var presetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Button("Default") { choose(nil) }
                ForEach(entries) { preset in
                    Button { choose(preset) } label: { Text(verbatim: preset.name).frame(maxWidth: .infinity, alignment: .leading) }
                        .contextMenu { Button("Delete preset") { remove(preset) } }
                }
            }.buttonStyle(.plain).padding()
        }.frame(width: 238, height: min(340, CGFloat(entries.count + 1) * 30 + 20))
    }
    private func choose(_ preset: FXPreset?) {
        imports.removeAll()
        selectedPreset = preset?.id
        kit = preset?.native?.drumKit(kind) ?? DrummerPadKit(kind)
        browsing = false
    }
    private func step(_ delta: Int) {
        let all: [FXPreset?] = [nil] + entries.map(Optional.some)
        let current = all.firstIndex { $0?.id == selectedPreset } ?? 0
        choose(all[(current + delta + all.count) % all.count])
    }
    private func reload() {
        do { library = try FXPresetStore.shared.read() } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            var s = NativeFXSettings(); s.appendNative(kind.rawValue); s.setDrumKit(kit, for: kind)
            let p = try FXPreset(name: saveName, settings: s, effect: kind.rawValue)
            var lib = try FXPresetStore.shared.read(); try lib.save(p); try FXPresetStore.shared.write(lib)
            library = lib; selectedPreset = p.id
        } catch { self.error = error.localizedDescription }
    }
    private func remove(_ preset: FXPreset) {
        do {
            var lib = try FXPresetStore.shared.read()
            lib.presets.removeAll { $0.id == preset.id }; lib.defaults = lib.defaults.filter { $0.value != preset.id }
            try FXPresetStore.shared.write(lib); library = lib
            if selectedPreset == preset.id { selectedPreset = nil }
        } catch { self.error = error.localizedDescription }
    }
    private func stopLearning() { if DrummerMIDILearn.owner == owner { DrummerMIDILearn.owner = nil }; learning = nil }
}
