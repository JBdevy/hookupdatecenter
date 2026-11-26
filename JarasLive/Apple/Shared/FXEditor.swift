import SwiftUI
import UniformTypeIdentifiers
import Combine

private struct OpenFXKey: EnvironmentKey { static let defaultValue: (UUID?, String) -> Void = { _, _ in } }
private struct OpenClipFXChainKey: EnvironmentKey { static let defaultValue: (UUID) -> Void = { _ in } }
extension EnvironmentValues {
    var openFX: (UUID?, String) -> Void { get { self[OpenFXKey.self] } set { self[OpenFXKey.self] = newValue } }
    var openClipFXChain: (UUID) -> Void { get { self[OpenClipFXChainKey.self] } set { self[OpenClipFXChainKey.self] = newValue } }
}
enum FXModelLookup {
    static func clip(_ id: UUID, in project: Project) -> AudioClip? {
        for song in project.songs { for track in song.tracks { if let clip = track.clips.first(where: { $0.id == id }) { return clip } } }
        return nil
    }
    static func track(_ id: UUID, in project: Project) -> Track? {
        for song in project.songs { if let track = song.tracks.first(where: { $0.id == id }) { return track } }
        return nil
    }
}
struct FXEditor: View {
    let show: ShowController
    let track: UUID?
    let clip: UUID?
    let clipChainEditor: Bool
    let close: () -> Void
    @State private var settings: NativeFXSettings
    let page: String
    let effectKey: String
    private let project: UUID
    private let fallbackSettings: NativeFXSettings
    @State private var selected: UUID?
    @State private var changed = false
    @State private var choosingSample = false
    @State private var sampleBusy = false
    @State private var sampleError = ""
    init(show: ShowController, track: UUID?, clip: UUID? = nil, clipChainEditor: Bool = false, effect: String, close: @escaping () -> Void) {
        self.show = show; self.track = track; self.clip = clip; self.clipChainEditor = clipChainEditor; self.close = close; effectKey = effect; project = show.snapshot.project.id
        let chain = clip.map { show.clipFXSettings($0) } ?? show.fxSettings(track)
        page = chain.kind(of: effect)
        let initial = chain.settings(for: effect)
        fallbackSettings = initial
        _settings = State(initialValue: initial); _selected = State(initialValue: initial.bands.first?.id)
    }
    private var title: String {
        if let clip { return FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—" }
        return track.flatMap { id in FXModelLookup.track(id, in: show.snapshot.project)?.name } ?? "Main"
    }
    private var editorBackground: LinearGradient {
        LinearGradient(colors: NativeFXAppearance.chassis,
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var currentSettings: NativeFXSettings {
        if let clip { return (FXModelLookup.clip(clip, in: show.snapshot.project)?.fx ?? fallbackSettings).settings(for: effectKey) }
        return show.fxSettings(track).settings(for: effectKey)
    }
    private let enabledTitle = "Enabled"
    private var drumAudio: StemAudioPlayback {
        #if os(macOS)
        DesktopProjectTabs.shared.audio(for: show)
        #else
        StemAudioPlayback.shared
        #endif
    }
    private var audioTarget: UUID? { clip ?? track }
    private var compactControls: Bool { page == "Delay" || page == "Reverb" || NativeCreativeEffect(rawValue: page) != nil }
    private func remove() {
        if let clip { show.removeClipFX(clip, effect: effectKey) }
        else { show.removeFX(track, effect: effectKey) }
        close()
    }
    var body: some View {
        VStack(spacing: 16) {
            if !clipChainEditor {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(.jarasCaption).foregroundStyle(Color.white.opacity(0.70)).lineLimit(1)
                        Text(verbatim: EffectPresentation.title(page)).font(.jarasSystem(size: 23, weight: .semibold))
                    }
                    Spacer()
                    Button("Remove effect", action: remove).controlSize(.small)
                    Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                        .buttonStyle(.plain).jarasHelp("Close")
                }
            }
            switch page {
            case "CatSynth":
                CatSynthEditor(bank: Binding(get: { settings.catSynth ?? CatSynthBank() }, set: { settings.catSynth = $0 }),
                               enabled: Binding(get: { settings.catSynthEnabled == true }, set: { settings.catSynthEnabled = $0 }),
                               audio: drumAudio, track: audioTarget, effect: effectKey)
            case "Drummer Pad 16", "Drummer Pad 48":
                if let kind = DrummerPadKind(rawValue: page) {
                    DrummerPadEditor(kind: kind, kit: Binding(get: { settings.drumKit(kind) }, set: { settings.setDrumKit($0, for: kind) }), audio: drumAudio, track: audioTarget, effect: effectKey)
                }
            case "Instruments": InstrumentParameterEditor(name: InstrumentLibrary.displayName(settings.instrumentID), category: InstrumentLibrary.category(settings.instrumentID), parameters: Binding(get: { settings.instrumentParameters ?? InstrumentLibrary.parameters(settings.instrumentID) }, set: { settings.instrumentParameters = $0 }))
            case "CatLive Trigger": triggerEditor
            case "Cat Gate": gateEditor
            case "EQ": equalizer
            case "Compressor":
                HStack {
                    Toggle(enabledTitle, isOn: $settings.compressorEnabled).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                    Spacer()
                    channelControls("Compressor")
                }
                HStack(spacing: 30) {
                    DynamicsThresholdMeter(track: audioTarget, effect: effectKey, threshold: $settings.threshold, compressor: true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 22) {
                        FXKnob("Ratio", value: $settings.ratio, range: 1...20, unit: ":1", reset: 4, parameter: .ratio)
                        FXKnob("Gain", value: $settings.makeup, range: -12...24, unit: "dB", reset: 0, parameter: .makeup)
                        FXKnob("Attack", value: $settings.attack, range: 0.0001...0.2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.005, parameter: .attack)
                        FXKnob("Release", value: $settings.release, range: 0.01...3, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.1, parameter: .release)
                    }
                }.padding(18).nativeFXRack()
            case "Limiter":
                Toggle(enabledTitle, isOn: Binding(get: { settings.limiterEnabled == true }, set: { settings.limiterEnabled = $0 })).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                HStack(spacing: 26) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    FXKnob("Gain", value: $settings.limiterParameters.inputGain, range: -24...24, unit: "dB", reset: 0, parameter: .limiterGain)
                    FXKnob("Ceiling", value: $settings.limiterParameters.ceiling, range: -24...0, unit: "dB", reset: -0.1, parameter: .limiterCeiling)
                    FXKnob("Release", value: $settings.limiterParameters.release, range: 0.01...3, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.1, parameter: .limiterRelease)
                }.padding(18).nativeFXRack()
            case "Pitch":
                Toggle(enabledTitle, isOn: Binding(get: { settings.pitchEnabled == true }, set: { settings.pitchEnabled = $0 })).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                HStack(spacing: 24) {
                    FXKnob("Semitones", value: Binding(get: { settings.semitones }, set: { settings.pitchSemitones = $0.rounded() }),
                           range: -12...12, unit: "st", reset: 0, parameter: .pitchSemitones)
                    FXKnob("Formant", value: Binding(get: { settings.formantSemitones }, set: { settings.pitchFormant = ($0 * 10).rounded() / 10 }),
                           range: -12...12, unit: "st", reset: 0, parameter: .pitchFormant)
                }.padding(24).nativeFXRack()
            case "Delay":
                HStack {
                    Toggle(enabledTitle, isOn: $settings.delayEnabled).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                    Spacer()
                    channelControls("Delay")
                }
                HStack(spacing: 26) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    FXKnob("Time", value: $settings.delayTime, range: 0.01...2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.25, parameter: .delayTime)
                    FXKnob("Feedback", value: $settings.feedback, range: 0...90, unit: "%", reset: 25, parameter: .feedback)
                    FXKnob("Mix", value: $settings.delayMix, range: 0...100, unit: "%", reset: 20, parameter: .delayMix)
                }.padding(18).nativeFXRack()
            case "Arpeggiator":
                Toggle(enabledTitle, isOn: Binding(get: { settings.arpeggiatorEnabled == true },
                                                set: { settings.arpeggiatorEnabled = $0 }))
                    .toggleStyle(.switch).tint(JarasTheme.green)
                ArpeggiatorControls(parameters: Binding(
                    get: { settings.arpeggiator ?? NativeArpeggiatorSettings() },
                    set: { settings.arpeggiator = $0 }))
            case "Chorus", "Phaser", "Amp", "Gate Divisor", "Soft Clipper":
                if let effect = NativeCreativeEffect(rawValue: page) { creativeEditor(effect) }
            default:
                HStack {
                    Toggle(enabledTitle, isOn: $settings.reverbEnabled).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                    Picker(String("Space"), selection: $settings.reverbRoom) {
                        Text(verbatim: "Room").tag(0); Text(verbatim: "Hall").tag(1); Text(verbatim: "Plate").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280).mapFXMIDI(.reverbRoom, name: "Space", range: 0...2)
                    Spacer()
                    channelControls("Reverb")
                }
                HStack(spacing: 14) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    FXKnob("Mix", value: $settings.reverbMix, range: 0...100, unit: "%", reset: 20, parameter: .reverbMix)
                    FXKnob("Decay", value: $settings.reverbDecay, range: 0.1...20, unit: "s", logarithmic: true, reset: 2, parameter: .reverbDecay)
                    FXKnob("Low Cut", value: $settings.reverbLowCut, range: 20...2000, unit: "Hz", logarithmic: true, reset: 80, parameter: .reverbLowCut)
                    FXKnob("High Cut", value: $settings.reverbHighCut, range: 2000...20000, unit: "Hz", logarithmic: true, reset: 12000, parameter: .reverbHighCut)
                }.padding(18).nativeFXRack()

            }
        }.fileImporter(isPresented: $choosingSample, allowedContentTypes: ["wav","mp3"].compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case .success(let url): importSample(url)
            case .failure(let error): sampleError = error.localizedDescription
            }
        }.environment(\.fxDialAccent, NativeFXAppearance.accent(page))
        .environment(\.fxMIDIScope, FXMIDIScope(track: track, clip: clip, effect: effectKey))
        #if os(iOS)
        .padding(12).frame(maxWidth: .infinity, minHeight: compactControls ? 260 : 410)
        .background { editorBackground }.foregroundStyle(JarasTheme.text)
        #else
        .padding(clipChainEditor ? 0 : 20).frame(minWidth: clipChainEditor ? 600 : 640, idealWidth: clipChainEditor ? 700 : 740, maxWidth: .infinity, minHeight: compactControls ? (clipChainEditor ? 260 : 340) : (clipChainEditor ? 410 : 540), idealHeight: compactControls ? (clipChainEditor ? 280 : 360) : (clipChainEditor ? 440 : 560), maxHeight: .infinity).background { editorBackground }.foregroundStyle(JarasTheme.text).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(radius: clipChainEditor ? 0 : 20)
        #endif
            .onChange(of: settings) { value in
                guard show.snapshot.project.id == project else { return }
                let current = currentSettings
                guard current.merging(effect: page, from: value) != current else { return }
                changed = true
                if let clip { show.updateClipFX(clip, effect: effectKey, settings: value) }
                else { show.updateFX(track, effect: effectKey, settings: value) }
            }
            .onReceive(show.$snapshot.map { snapshot in
                if let clip { return FXModelLookup.clip(clip, in: snapshot.project)?.fx ?? fallbackSettings }
                return track.flatMap { id in FXModelLookup.track(id, in: snapshot.project)?.fx } ?? (track == nil ? snapshot.project.masterFX : nil) ?? NativeFXSettings()
            }.removeDuplicates()) { current in
                settings = settings.merging(effect: page, from: current.settings(for: effectKey))
            }
            .onAppear { StemAudioPlayback.shared.observeEffect(audioTarget, effect: effectKey, active: true) }
            .onDisappear {
                StemAudioPlayback.shared.observeEffect(audioTarget, effect: effectKey, active: false)
                if changed && show.snapshot.project.id == project { show.commitFX() }
            }
            #if os(macOS)
            .onExitCommand(perform: close)
            #endif
    }
    private func channelControls(_ effect: String) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "Channel -").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                .fixedSize()
            ForEach(0..<2, id: \.self) { index in
                let bit = 1 << index
                Toggle(String(index + 1), isOn: Binding(
                    get: { settings.channels(for: effect) & bit != 0 },
                    set: { checked in
                        let mask = settings.channels(for: effect)
                        settings.setChannels(checked ? mask | bit : mask & ~bit, for: effect)
                    }))
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    .toggleStyle(FXChannelCheckboxStyle())
                    #endif
                    .tint(JarasTheme.green)
                    .accessibilityLabel(Text(verbatim: "Channel \(index + 1)"))
            }
        }
    }

    #if os(iOS)
    private struct FXChannelCheckboxStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                        .foregroundStyle(configuration.isOn ? JarasTheme.green : JarasTheme.secondary)
                    configuration.label
                }.frame(minWidth: 34, minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        }
    }
    #endif

    private func creativeValue(_ effect: NativeCreativeEffect, _ parameter: NativeCreativeEffect.Parameter) -> Binding<Double> {
        Binding(get: { settings.creativeParameters(effect)?[parameter.key] ?? parameter.initial }, set: { value in
            var parameters = settings.creativeParameters(effect) ?? [:]
            parameters[parameter.key] = parameter.key == "division" || parameter.key == "steps" ? value.rounded() : value
            settings.setCreativeParameters(parameters, for: effect)
        })
    }

    private func creativeEditor(_ effect: NativeCreativeEffect) -> some View {
        let gated = effect == .divisionGate
        return VStack(spacing: 14) {
            HStack {
                Toggle(enabledTitle, isOn: Binding(get: { settings.isEnabled(effect.rawValue) },
                    set: { settings.setEnabled(effect.rawValue, enabled: $0) }))
                    .toggleStyle(.switch).tint(JarasTheme.green)
                Spacer()
                if gated { Text(verbatim: "BPM Sync").foregroundStyle(JarasTheme.secondary) }
            }
            if gated {
                let steps = creativeValue(effect, effect.parameters[3])
                HStack(spacing: 4) {
                    ForEach(0..<16, id: \.self) { step in
                        let bit = 1 << step
                        let active = Int(steps.wrappedValue) & bit != 0
                        Button {
                            steps.wrappedValue = Double(Int(steps.wrappedValue) ^ bit)
                        } label: {
                            Text(String(step + 1)).font(.jarasSystem(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .background(active ? JarasTheme.green : JarasTheme.panel, in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(active ? .black : JarasTheme.text)
                        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 14) {
                ForEach(effect.parameters.filter { $0.key != "steps" }, id: \.key) { parameter in
                    if parameter.key == "division" {
                        Picker(String("Division"), selection: creativeValue(effect, parameter)) {
                            ForEach([2, 4, 8, 12, 16, 24, 32], id: \.self) { division in
                                Text("1/\(division)").tag(Double(division))
                            }
                        }.frame(maxWidth: .infinity)
                    } else {
                        FXKnob(parameter.title, value: creativeValue(effect, parameter), range: parameter.range,
                            unit: parameter.unit, reset: parameter.initial)
                    }
                }
            }.padding(18).nativeFXRack()
        }
    }

    private var triggerEditor: some View {
        VStack(spacing: 14) {
            HStack {
                Toggle(enabledTitle, isOn: Binding(get: { settings.triggerEnabled == true }, set: { settings.triggerEnabled = $0 }))
                    .toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                Spacer()
                Button("Load sample…") { choosingSample = true }.disabled(sampleBusy)
                if sampleBusy { ProgressView().controlSize(.small) }
            }
            Text(settings.trigger?.samplePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "No sample loaded"))
                .font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).nativeFXRack()
            if !sampleError.isEmpty { Text(LocalizedStringKey(sampleError)).font(.jarasCaption).foregroundStyle(.red) }
            TriggerSampleStatus(target: audioTarget, effect: effectKey)
            Text("WAV / MP3 · Mono / Stereo · 60 s max").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            HStack(spacing: 12) {
            EffectVerticalMeters(track: audioTarget, effect: effectKey)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 18) {
                FXKnob("Threshold", value: $settings.triggerParameters.threshold, range: -80...0, unit: "dB", reset: -30, parameter: .triggerThreshold)
                FXKnob("Retrigger", value: $settings.triggerParameters.retrigger, range: 0.005...2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.08, parameter: .triggerRetrigger)
                FXKnob("Gain", value: $settings.triggerParameters.gain, range: -24...24, unit: "dB", reset: 0, parameter: .triggerGain)
                Color.clear.frame(height: 1).accessibilityHidden(true)
                FXKnob("Attack", value: $settings.triggerParameters.attack, range: 0...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0, parameter: .triggerAttack)
                FXKnob("Decay", value: $settings.triggerParameters.decay, range: 0...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.1, parameter: .triggerDecay)
                FXKnob("Sustain", value: $settings.triggerParameters.sustain, range: 0...1, unit: "%", multiplier: 100, reset: 1, parameter: .triggerSustain)
                FXKnob("Release", value: $settings.triggerParameters.release, range: 0...20, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.02, parameter: .triggerRelease)
            }
            }.padding(14).nativeFXRack()
        }
    }
    private var gateEditor: some View {
        VStack(spacing: 16) {
            Toggle(enabledTitle, isOn: Binding(get: { settings.gateEnabled == true }, set: { settings.gateEnabled = $0 }))
                .toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
            HStack(spacing: 12) {
            DynamicsThresholdMeter(track: audioTarget, effect: effectKey, threshold: $settings.gateParameters.threshold, compressor: false)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 22) {
                FXKnob("Attack", value: $settings.gateParameters.attack, range: 0...2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.001, parameter: .gateAttack)
                FXKnob("Decay", value: $settings.gateParameters.decay, range: 0...2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.02, parameter: .gateDecay)
                FXKnob("Hold", value: $settings.gateParameters.hold, range: 0...2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.05, parameter: .gateHold)
                FXKnob("Release", value: $settings.gateParameters.release, range: 0...5, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.1, parameter: .gateRelease)
                FXKnob("High-pass", value: Binding(get: { settings.gateParameters.highPass }, set: { settings.gateParameters.highPass = min($0, settings.gateParameters.lowPass) }), range: 20...20000, unit: "Hz", logarithmic: true, reset: 20, parameter: .gateHighPass)
                FXKnob("Low-pass", value: Binding(get: { settings.gateParameters.lowPass }, set: { settings.gateParameters.lowPass = max($0, settings.gateParameters.highPass) }), range: 20...20000, unit: "Hz", logarithmic: true, reset: 20000, parameter: .gateLowPass)
            }
            }.padding(18).nativeFXRack()
        }
    }
    private func importSample(_ source: URL) {
        guard show.canControl(), let directory = StemAudioPlayback.shared.mediaDirectory else {
            sampleError = String(localized: "Save the project before loading a sample."); return
        }
        sampleBusy = true; sampleError = ""
        Task {
            defer { sampleBusy = false }
            do {
                let path = try await Task.detached(priority: .userInitiated) { try TriggerSampleImport.copy(source, to: directory) }.value
                let chain = clip.map { show.clipFXSettings($0) } ?? show.fxSettings(track)
                guard show.snapshot.project.id == project, chain.inserted.contains(effectKey) else {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(path)); return
                }
                settings.triggerParameters.samplePath = path
            } catch { sampleError = error.localizedDescription }
        }
    }
    private var equalizer: some View {
        VStack(spacing: 10) {
            HStack { Toggle(enabledTitle, isOn: $settings.eqEnabled).mapFXMIDI(.enabled, name: "Enabled", range: 0...1); Spacer(); channelControls("EQ"); Text("\(settings.bands.count)/10").font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
            GeometryReader { geometry in
                ZStack {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(Gradient(colors: NativeFXAppearance.plum.reversed()),
                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                        for hz in [Double](arrayLiteral: 20,50,100,200,500,1000,2000,5000,10000,20000) {
                            let x = log(hz / 20) / log(1000) * size.width
                            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line, with: .color(JarasTheme.line), lineWidth: 0.5)
                            context.draw(Text(hz >= 1000 ? "\(Int(hz/1000))k" : "\(Int(hz))").font(.jarasSystem(size: 9)).foregroundColor(JarasTheme.secondary), at: CGPoint(x: min(size.width-14,max(14,x)), y: size.height-8))
                        }
                        for gain in stride(from: -24, through: 24, by: 6) {
                            let y = (24 - Double(gain)) / 48 * size.height
                            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(line, with: .color(gain == 0 ? JarasTheme.secondary : JarasTheme.line), lineWidth: gain == 0 ? 1 : 0.5)
                        }
                    }
                    EQRTAOverlay(target: audioTarget, effect: effectKey)
                    EQResponsePlot(bands: settings.bands, enabled: settings.eqEnabled,
                                   sampleRate: StemAudioPlayback.shared.processingSampleRate).equatable()
                    #if os(macOS)
                    EQAddBandInput { x, y in
                        if abs(y - geometry.size.height / 2) < 18 { addBand(frequency: 20 * pow(1000.0, Double(min(1,max(0,x / geometry.size.width))))) }
                    }
                    #endif
                    ForEach(settings.bands) { band in
                        let x = log(band.frequency / 20) / log(1000) * geometry.size.width
                        let y = (24 - band.gain) / 48 * geometry.size.height
                        Circle().fill(selected == band.id ? Color.white : NativeFXAppearance.violet).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1)).frame(width: 26, height: 26).contentShape(Circle())
                            #if os(iOS)
                            .overlay(FXTouchDrag(began: { _ in selected = band.id }, changed: { point, _ in
                                guard let index = settings.bands.firstIndex(where: { $0.id == band.id }) else { return }
                                let current = settings.bands[index]
                                let px = log(current.frequency / 20) / log(1000) * geometry.size.width + point.x - 13
                                let py = (24 - current.gain) / 48 * geometry.size.height + point.y - 13
                                settings.bands[index].frequency = min(20000, max(20, 20 * pow(1000, Double(px / geometry.size.width))))
                                if !band.type.hasSuffix("Cut") { settings.bands[index].gain = min(24, max(-24, 24 - py / geometry.size.height * 48)) }
                            }, ended: {}))
                            .position(x: x, y: y)
                            #else
                            .position(x: x, y: y)
                            .onTapGesture(count: 2) {
                                guard let index = settings.bands.firstIndex(where: { $0.id == band.id }) else { return }
                                selected = band.id
                                settings.bands[index].gain = 0
                            }
                            .onTapGesture { selected = band.id }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("eqPlot")).onChanged { event in
                                guard let index = settings.bands.firstIndex(where: { $0.id == band.id }) else { return }
                                selected = band.id
                                settings.bands[index].frequency = min(20000,max(20,20 * pow(1000.0, Double(event.location.x / geometry.size.width))))
                                if !band.type.hasSuffix("Cut") { settings.bands[index].gain = min(24,max(-24,24 - event.location.y / geometry.size.height * 48)) }
                            })
                            #endif
                            .jarasHelp(String(format: "%.0f Hz · %.1f dB", band.frequency, band.gain))
                    }
                }.coordinateSpace(name: "eqPlot").clipped().cornerRadius(6)
                #if os(macOS)
                .background(EQBandWheelInput(bands: settings.bands) { id, steps in
                    guard let index = settings.bands.firstIndex(where: { $0.id == id }) else { return }
                    selected = id
                    if settings.bands[index].type.hasSuffix("Cut") {
                        let slopes = [6, 12, 24, 36, 48, 72, 96, 192]
                        let current = slopes.firstIndex(of: settings.bands[index].slope) ?? 1
                        settings.bands[index].slope = slopes[min(slopes.count - 1, max(0, current + steps))]
                    } else {
                        settings.bands[index].q = min(18, max(0.1, settings.bands[index].q * pow(1.12, Double(steps))))
                    }
                })
                #endif
            }
            Text("Right-click the zero line to add a band.").font(.jarasCaption2).foregroundStyle(JarasTheme.secondary)
            if let selected, let index = settings.bands.firstIndex(where: { $0.id == selected }) {
                let sorted = settings.bands.sorted { $0.frequency < $1.frequency }
                HStack {
                    Picker(String("Band"), selection: self.$selected) { ForEach(Array(settings.bands.enumerated()), id: \.element.id) { index, band in Text("\(index+1)").tag(Optional(band.id)) } }.frame(width: 90)
                    Picker(String("Type"), selection: $settings.bands[index].type) {
                        Text(verbatim: "Bell").tag("bell")
                        if sorted.first?.id == selected { Text(verbatim: "Low Cut").tag("lowCut"); Text(verbatim: "Low Shelf").tag("lowShelf") }
                        if sorted.last?.id == selected { Text(verbatim: "High Cut").tag("highCut"); Text(verbatim: "High Shelf").tag("highShelf") }
                        if sorted.first?.id != selected && sorted.last?.id != selected && settings.bands[index].type != "bell" { Text(settings.bands[index].type).tag(settings.bands[index].type) }
                    }.frame(width: 150).mapFXMIDI(.bandType, name: "Type", range: 0...Double(bandTypes(sorted, selected: selected).count - 1), band: selected, choices: bandTypes(sorted, selected: selected))
                    if settings.bands[index].type.hasSuffix("Cut") {
                        Picker(String("Slope"), selection: $settings.bands[index].slope) { ForEach([6,12,24,36,48,72,96,192], id: \.self) { slope in Text(verbatim: slope == 192 ? "Brickwall" : "\(slope) dB/oct").tag(slope) } }.jarasHelp("Brickwall uses a 192 dB/oct low-latency filter.").mapFXMIDI(.bandSlope, name: "Slope", range: 0...7, band: selected)
                    }
                    Spacer()
                    Button { settings.bands.remove(at: index); self.selected = settings.bands.first?.id } label: { Image(systemName: "trash") }.jarasHelp("Remove band")
                }
                HStack {
                    control("Frequency", parameter: .bandFrequency, band: selected, value: $settings.bands[index].frequency, range: 20...20000, suffix: "Hz")
                    control("Gain", parameter: .bandGain, band: selected, value: $settings.bands[index].gain, range: -24...24, suffix: "dB").disabled(settings.bands[index].type.hasSuffix("Cut"))
                    control("Q", parameter: .bandQ, band: selected, value: $settings.bands[index].q, range: 0.1...18, suffix: "").disabled(settings.bands[index].type.hasSuffix("Cut"))
                }
            }
        }
    }
    private func addBand(frequency: Double) {
        guard settings.bands.count < 10 else { return }
        let band = EQBand(frequency: frequency)
        settings.bands.append(band); selected = band.id
    }
    private func bandTypes(_ sorted: [EQBand], selected: UUID) -> [String] {
        var types = ["bell"]
        if sorted.first?.id == selected { types += ["lowCut", "lowShelf"] }
        if sorted.last?.id == selected { types += ["highCut", "highShelf"] }
        if let current = sorted.first(where: { $0.id == selected })?.type, !types.contains(current) { types.append(current) }
        return types
    }
    private func control(_ label: String, parameter: NativeFXParameter.Key, band: UUID, value: Binding<Double>, range: ClosedRange<Double>, scale: Double = 1, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(verbatim: label).font(.jarasCaption); Spacer(); Text(String(format: "%.1f %@", value.wrappedValue * scale, suffix)).font(.jarasSystem(size: 10, design: .monospaced)) }
            Slider(value: value, in: range).tint(JarasTheme.green)
        }.mapFXMIDI(parameter, name: label, range: range, band: band)
    }
}

private struct EQResponsePlot: View, Equatable {
    let bands: [EQBand]
    let enabled: Bool
    let sampleRate: Double
    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
            let curve = EQResponseCurve(coefficients: bands.flatMap { $0.coefficients(rate: rate) }, rate: rate)
            var response = Path()
            for pixel in stride(from: 0, through: Int(size.width), by: 2) {
                let hz = 20 * pow(1000.0, Double(pixel) / Double(size.width))
                let db = curve.response(frequency: hz)
                let point = CGPoint(x: Double(pixel), y: (24 - min(30, max(-30, db))) / 48 * size.height)
                if pixel == 0 { response.move(to: point) } else { response.addLine(to: point) }
            }
            let color = enabled ? NativeFXAppearance.violet : JarasTheme.secondary
            var fill = response
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.20), color.opacity(0.02)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(response, with: .color(color), lineWidth: 2)
        }.allowsHitTesting(false)
    }
}
#if !os(macOS)
/// Touch item manager. macOS uses TrackFXChainView for both tracks and items.
struct ClipFXChainEditor: View {
    @ObservedObject var show: ShowController
    let clip: UUID
    let close: () -> Void
    @State private var selected: String?
    @State private var adding = false
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme
    @State private var libraryWidth = 310.0
    private var settings: NativeFXSettings { show.clipFXSettings(clip) }
    private var effects: [String] { settings.clipEffectKeys }
    private func title(_ effect: String) -> String {
        settings.externalPlugins?.first(where: { $0.effectKey == effect })?.name
            ?? JarasLocalization.string(settings.kind(of: effect))
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(JarasLocalization.string("FX Manager") + " - " + (FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—"))
                    .font(.jarasHeadline).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).jarasHelp("Close")
            }
            HStack(spacing: 12) {
                if adding {
                    ResizableWorkspaceLibrary(theme: theme, show: show, width: libraryWidth, maximumWidth: 385,
                                     preferredWidth: $libraryWidth).frame(width: libraryWidth)
                }
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(effects, id: \.self) { effect in
                                HStack(spacing: 4) {
                                    Button { show.toggleClipFXBypass(clip, effect: effect) } label: {
                                        Text("By").font(.jarasSystem(size: 11, weight: .semibold)).frame(width: 34, height: 34)
                                            .background(settings.isEnabled(effect) ? Color.white.opacity(0.12) : Color.red.opacity(0.75))
                                            .cornerRadius(3).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel(Text("Bypass") + Text(" · " + title(effect)))
                                    Button { selected = effect } label: {
                                        HStack(spacing: 4) {
                                            Text(verbatim: title(effect)).font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Image(systemName: "line.3.horizontal").font(.jarasSystem(size: 11)).foregroundStyle(JarasTheme.secondary)
                                        }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .onDrag { ClipFXReorderPayload(project: show.snapshot.project.id, clip: clip, effect: effect).provider() }
                                }.padding(.horizontal, 4)
                                    .background(selected == effect ? JarasTheme.green.opacity(0.3) : Color.clear)
                                    .cornerRadius(4)
                                    .onDrop(of: [ClipFXReorderPayload.type], delegate: ClipFXReorderDrop(show: show, project: show.snapshot.project.id,
                                        clip: clip, target: effect, next: effects.drop(while: { $0 != effect }).dropFirst().first, selected: $selected))
                            }
                            Color.clear.frame(height: 24).contentShape(Rectangle())
                                .onDrop(of: [ClipFXReorderPayload.type], delegate: ClipFXReorderDrop(show: show, project: show.snapshot.project.id,
                                    clip: clip, target: nil, next: nil, selected: $selected))
                        }
                    }
                    HStack {
                        Button("Add") { adding = true }.frame(maxWidth: .infinity)
                        Button("Remove") {
                            if let selected { show.removeClipFX(clip, effect: selected) }
                        }.disabled(selected == nil).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }.frame(width: 180)
                    .modifier(LibraryItemEffectDrop(show: show, clip: clip, selected: $selected))
                Divider()
                Group {
                    if let selected, effects.contains(selected) {
                        FXEditor(show: show, track: nil, clip: clip, clipChainEditor: true, effect: selected, close: close).id(selected)
                    } else { Color.clear }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(20).frame(minWidth: 840, idealWidth: 940, maxWidth: .infinity, minHeight: 540, idealHeight: 560, maxHeight: .infinity)
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { if selected == nil { selected = effects.first } }
            .onChange(of: effects) { available in
                if selected.map({ !available.contains($0) }) ?? true { selected = available.last }
            }
    }
}
struct ClipFXReorderPayload: Codable {
    static let type = "com.catlive.item-fx-order"
    let project: UUID
    let clip: UUID
    let effect: String
    func provider() -> NSItemProvider {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.type, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    static func effect(from data: Data, project: UUID, clip: UUID) -> String? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.project == project, value.clip == clip else { return nil }
        return value.effect
    }
}
struct ClipFXReorderDrop: DropDelegate {
    let show: ShowController
    let project: UUID
    let clip: UUID?
    let target: String?
    let next: String?
    var rowHeight: CGFloat = 34
    @Binding var selected: String?
    func validateDrop(info: DropInfo) -> Bool {
        clip != nil && show.snapshot.project.id == project && info.hasItemsConforming(to: [ClipFXReorderPayload.type])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let clip, validateDrop(info: info), let provider = info.itemProviders(for: [ClipFXReorderPayload.type]).first else { return false }
        let before = target != nil && info.location.y > rowHeight / 2 ? next : target
        provider.loadDataRepresentation(forTypeIdentifier: ClipFXReorderPayload.type) { data, _ in
            guard let data, let effect = ClipFXReorderPayload.effect(from: data, project: project, clip: clip) else { return }
            Task { @MainActor in
                guard show.snapshot.project.id == project,
                      let moved = show.reorderClipFX(clip, effect: effect, before: before) else { return }
                selected = moved
            }
        }
        return true
    }
}

#endif

#if os(macOS)
import AppKit
private struct EQBandWheelInput: NSViewRepresentable {
    let bands: [EQBand]
    let adjust: (UUID, Int) -> Void
    func makeNSView(context: Context) -> EQBandWheelView { EQBandWheelView() }
    func updateNSView(_ view: EQBandWheelView, context: Context) { view.bands = bands; view.adjust = adjust }
}
private final class EQBandWheelView: NSView {
    var bands: [EQBand] = []
    var adjust: ((UUID, Int) -> Void)?
    private var held: UUID?
    private var remainder: CGFloat = 0
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        held = nil; remainder = 0
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp { self.held = nil; self.remainder = 0; return event }
            guard event.window === self.window, (event.type == .leftMouseDown || self.window?.isKeyWindow == true),
                  self.window?.attachedSheet == nil, !self.isHiddenOrHasHiddenAncestor else {
                self.held = nil; self.remainder = 0; return event
            }
            if event.type == .leftMouseDown {
                self.held = nil; self.remainder = 0
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), self.visibleRect.contains(point) else { return event }
                self.held = self.bands.reversed().first { band in
                    let x = log(band.frequency / 20) / log(1000) * self.bounds.width
                    let y = (24 - band.gain) / 48 * self.bounds.height
                    return hypot(point.x - x, point.y - y) <= 13
                }?.id
                return event // preserve the existing band click/drag gesture
            }
            guard let held = self.held, NSEvent.pressedMouseButtons & 1 != 0,
                  self.bands.contains(where: { $0.id == held }) else { return event }
            guard event.momentumPhase.isEmpty else { return nil }
            let delta = event.scrollingDeltaY
            guard delta.isFinite else { return nil }
            self.remainder += event.hasPreciseScrollingDeltas ? delta / 10 : (delta == 0 ? 0 : delta > 0 ? 1 : -1)
            let steps = Int(self.remainder.rounded(.towardZero))
            if steps != 0 { self.remainder -= CGFloat(steps); self.adjust?(held, steps) }
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
private struct EQAddBandInput: NSViewRepresentable {
    let add: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> EQAddBandView { EQAddBandView() }
    func updateNSView(_ view: EQAddBandView, context: Context) { view.add = add }
}
private final class EQAddBandView: NSView {
    var add: ((CGFloat, CGFloat) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil }
    override func rightMouseDown(with event: NSEvent) { let point = convert(event.locationInWindow, from: nil); add?(point.x,point.y) }
}
#endif

private struct TriggerSampleStatus: View {
    let target: UUID?
    let effect: String
    @State private var message: String?
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if let message { Text(LocalizedStringKey(message)).font(.jarasCaption).foregroundStyle(.red) }
        }.onAppear { refresh() }.onReceive(clock) { _ in refresh() }
    }
    private func refresh() { message = StemAudioPlayback.shared.effectSampleError(target, effect: effect) }
}
