import SwiftUI

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
        return track.flatMap { id in FXModelLookup.track(id, in: show.snapshot.project)?.name } ?? "Master"
    }
    private var currentSettings: NativeFXSettings {
        if let clip { return FXModelLookup.clip(clip, in: show.snapshot.project)?.fx ?? fallbackSettings }
        return show.fxSettings(track).settings(for: effectKey)
    }
    private var audioTarget: UUID? { clip ?? track }
    private func remove() {
        if let clip { show.removeClipFX(clip, effect: effectKey) }
        else { show.removeFX(track, effect: effectKey) }
        close()
    }
    var body: some View {
        VStack(spacing: 16) {
            if !clipChainEditor {
            HStack { Text(EffectPresentation.title(page) + " · " + title).font(.headline); Spacer(); Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain).jarasHelp("Close") }
            HStack {
                Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(JarasTheme.secondary)
                Spacer()
                Button("Remove effect", action: remove).controlSize(.small)
            }
            }
            switch page {
            case "Instruments": InstrumentParameterEditor(name: InstrumentLibrary.displayName(settings.instrumentID), category: InstrumentLibrary.category(settings.instrumentID), parameters: Binding(get: { settings.instrumentParameters ?? InstrumentLibrary.parameters(settings.instrumentID) }, set: { settings.instrumentParameters = $0 }))
            case "EQ": equalizer
            case "Compressor":
                Toggle("Enabled", isOn: $settings.compressorEnabled).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                HStack(spacing: 30) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 22) {
                        FXKnob("Threshold", value: $settings.threshold, range: -60...0, unit: "dB", reset: -20, parameter: .threshold)
                        FXKnob("Ratio", value: $settings.ratio, range: 1...20, unit: ":1", reset: 4, parameter: .ratio)
                        FXKnob("Gain", value: $settings.makeup, range: -12...24, unit: "dB", reset: 0, parameter: .makeup)
                        FXKnob("Attack", value: $settings.attack, range: 0.0001...0.2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.005, parameter: .attack)
                        FXKnob("Release", value: $settings.release, range: 0.01...3, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.1, parameter: .release)
                    }
                }.padding(18).background(JarasTheme.display).cornerRadius(10)
            case "Limiter":
                Toggle("Enabled", isOn: Binding(get: { settings.limiterEnabled == true }, set: { settings.limiterEnabled = $0 })).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                HStack(spacing: 26) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    FXKnob("Input gain", value: $settings.limiterParameters.inputGain, range: -24...24, unit: "dB", reset: 0, parameter: .limiterGain)
                    FXKnob("Ceiling", value: $settings.limiterParameters.ceiling, range: -24...0, unit: "dB", reset: -0.1, parameter: .limiterCeiling)
                    FXKnob("Release", value: $settings.limiterParameters.release, range: 0.01...3, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.1, parameter: .limiterRelease)
                }.padding(18).background(JarasTheme.display).cornerRadius(10)
            case "Pitch":
                Toggle("Enabled", isOn: Binding(get: { settings.pitchEnabled == true }, set: { settings.pitchEnabled = $0 })).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                FXKnob("Semitones", value: Binding(get: { settings.semitones }, set: { settings.pitchSemitones = $0.rounded() }), range: -12...12, unit: "st", reset: 0, parameter: .pitchSemitones)
                    .padding(24).background(JarasTheme.display).cornerRadius(10)
            case "Delay":
                Toggle("Enabled", isOn: $settings.delayEnabled).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                EffectSpectrogram(track: audioTarget, effect: effectKey)
                HStack(spacing: 26) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    FXKnob("Time", value: $settings.delayTime, range: 0.01...2, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.25, parameter: .delayTime)
                    FXKnob("Feedback", value: $settings.feedback, range: 0...90, unit: "%", reset: 25, parameter: .feedback)
                    FXKnob("Mix", value: $settings.delayMix, range: 0...100, unit: "%", reset: 20, parameter: .delayMix)
                }.padding(18).background(JarasTheme.display).cornerRadius(10)
            default:
                HStack {
                    Toggle("Enabled", isOn: $settings.reverbEnabled).toggleStyle(.switch).tint(JarasTheme.green).mapFXMIDI(.enabled, name: "Enabled", range: 0...1)
                    Picker("Space", selection: $settings.reverbRoom) {
                        Text("Room").tag(0); Text("Hall").tag(1); Text("Plate").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280).mapFXMIDI(.reverbRoom, name: "Space", range: 0...2)
                }
                EffectSpectrogram(track: audioTarget, effect: effectKey)
                HStack(spacing: 14) {
                    EffectVerticalMeters(track: audioTarget, effect: effectKey)
                    FXKnob("Mix", value: $settings.reverbMix, range: 0...100, unit: "%", reset: 20, parameter: .reverbMix)
                    FXKnob("Decay", value: $settings.reverbDecay, range: 0.1...20, unit: "s", logarithmic: true, reset: 2, parameter: .reverbDecay)
                    FXKnob("Low Cut", value: $settings.reverbLowCut, range: 20...2000, unit: "Hz", logarithmic: true, reset: 80, parameter: .reverbLowCut)
                    FXKnob("High Cut", value: $settings.reverbHighCut, range: 2000...20000, unit: "Hz", logarithmic: true, reset: 12000, parameter: .reverbHighCut)
                }.padding(18).background(JarasTheme.display).cornerRadius(10)

            }
        }.environment(\.fxMIDIScope, FXMIDIScope(track: track, clip: clip, effect: effectKey))
        .padding(clipChainEditor ? 0 : 20).frame(minWidth: clipChainEditor ? 600 : 640, idealWidth: clipChainEditor ? 700 : 740, maxWidth: .infinity, minHeight: clipChainEditor ? 410 : 540, idealHeight: clipChainEditor ? 440 : 560, maxHeight: .infinity).background(JarasTheme.panel).foregroundStyle(JarasTheme.text).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(radius: clipChainEditor ? 0 : 20)
            .onChange(of: settings) { value in
                guard show.snapshot.project.id == project else { return }
                guard currentSettings.merging(effect: page, from: value) != currentSettings else { return }
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
    private var equalizer: some View {
        VStack(spacing: 10) {
            HStack { Toggle("Enabled", isOn: $settings.eqEnabled).mapFXMIDI(.enabled, name: "Enabled", range: 0...1); Spacer(); Text("\(settings.bands.count)/10").font(.caption).foregroundStyle(JarasTheme.secondary) }
            GeometryReader { geometry in
                ZStack {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(JarasTheme.display))
                        for hz in [Double](arrayLiteral: 20,50,100,200,500,1000,2000,5000,10000,20000) {
                            let x = log(hz / 20) / log(1000) * size.width
                            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line, with: .color(JarasTheme.line), lineWidth: 0.5)
                            context.draw(Text(hz >= 1000 ? "\(Int(hz/1000))k" : "\(Int(hz))").font(.system(size: 9)).foregroundColor(JarasTheme.secondary), at: CGPoint(x: min(size.width-14,max(14,x)), y: size.height-8))
                        }
                        for gain in stride(from: -24, through: 24, by: 6) {
                            let y = (24 - Double(gain)) / 48 * size.height
                            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(line, with: .color(gain == 0 ? JarasTheme.secondary : JarasTheme.line), lineWidth: gain == 0 ? 1 : 0.5)
                        }
                    }
                    EQRTAOverlay(target: audioTarget, effect: effectKey)
                    Canvas { context, size in
                        var response = Path()
                        for pixel in stride(from: 0, through: Int(size.width), by: 2) {
                            let hz = 20 * pow(1000.0, Double(pixel) / Double(size.width))
                            let db = settings.bands.reduce(0) { $0 + $1.response(frequency: hz) }
                            let point = CGPoint(x: Double(pixel), y: (24 - min(30,max(-30,db))) / 48 * size.height)
                            if pixel == 0 { response.move(to: point) } else { response.addLine(to: point) }
                        }
                        context.stroke(response, with: .color(settings.eqEnabled ? JarasTheme.green : JarasTheme.secondary), lineWidth: 2)
                    }
                    #if os(macOS)
                    EQAddBandInput { x, y in
                        if abs(y - geometry.size.height / 2) < 18 { addBand(frequency: 20 * pow(1000.0, Double(min(1,max(0,x / geometry.size.width))))) }
                    }
                    #endif
                    ForEach(settings.bands) { band in
                        let x = log(band.frequency / 20) / log(1000) * geometry.size.width
                        let y = (24 - band.gain) / 48 * geometry.size.height
                        Circle().fill(selected == band.id ? JarasTheme.yellow : JarasTheme.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1)).frame(width: 26, height: 26).contentShape(Circle())
                            .position(x: x, y: y)
                            .onTapGesture { selected = band.id }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("eqPlot")).onChanged { event in
                                guard let index = settings.bands.firstIndex(where: { $0.id == band.id }) else { return }
                                selected = band.id
                                settings.bands[index].frequency = min(20000,max(20,20 * pow(1000.0, Double(event.location.x / geometry.size.width))))
                                if !band.type.hasSuffix("Cut") { settings.bands[index].gain = min(24,max(-24,24 - event.location.y / geometry.size.height * 48)) }
                            })
                            .jarasHelp(String(format: "%.0f Hz · %.1f dB", band.frequency, band.gain))
                    }
                }.coordinateSpace(name: "eqPlot").clipped().cornerRadius(6)
            }
            Text("Right-click the zero line to add a band.").font(.caption2).foregroundStyle(JarasTheme.secondary)
            if let selected, let index = settings.bands.firstIndex(where: { $0.id == selected }) {
                let sorted = settings.bands.sorted { $0.frequency < $1.frequency }
                HStack {
                    Picker("Band", selection: self.$selected) { ForEach(Array(settings.bands.enumerated()), id: \.element.id) { index, band in Text("\(index+1)").tag(Optional(band.id)) } }.frame(width: 90)
                    Picker("Type", selection: $settings.bands[index].type) {
                        Text("Bell").tag("bell")
                        if sorted.first?.id == selected { Text("Low Cut").tag("lowCut"); Text("Low Shelf").tag("lowShelf") }
                        if sorted.last?.id == selected { Text("High Cut").tag("highCut"); Text("High Shelf").tag("highShelf") }
                        if sorted.first?.id != selected && sorted.last?.id != selected && settings.bands[index].type != "bell" { Text(settings.bands[index].type).tag(settings.bands[index].type) }
                    }.frame(width: 150).mapFXMIDI(.bandType, name: "Type", range: 0...Double(bandTypes(sorted, selected: selected).count - 1), band: selected, choices: bandTypes(sorted, selected: selected))
                    if settings.bands[index].type.hasSuffix("Cut") {
                        Picker("Slope", selection: $settings.bands[index].slope) { ForEach([6,12,24,36,48,72,96,192], id: \.self) { slope in Text(slope == 192 ? "Brickwall" : "\(slope) dB/oct").tag(slope) } }.jarasHelp("Brickwall uses a 192 dB/oct low-latency filter.").mapFXMIDI(.bandSlope, name: "Slope", range: 0...7, band: selected)
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
            HStack { Text(LocalizedStringKey(label)).font(.caption); Spacer(); Text(String(format: "%.1f %@", value.wrappedValue * scale, suffix)).font(.system(size: 10, design: .monospaced)) }
            Slider(value: value, in: range).tint(JarasTheme.green)
        }.mapFXMIDI(parameter, name: label, range: range, band: band)
    }
}
/// Item FX share one window. Opening or changing pages only reads the project.
struct TabbedClipFXEditor: View {
    let show: ShowController
    let clip: UUID
    let close: () -> Void
    @State private var page = "EQ"
    @State private var enabledEffects: Set<String> = []
    private var pages: [String] {
        #if os(macOS)
        return ["EQ", "Compressor", "Pitch", "Delay", "Reverb", "Limiter", "CatStemSeparation 5"]
        #else
        return ["EQ", "Compressor", "Pitch", "Delay", "Reverb", "Limiter"]
        #endif
    }
    private func color(_ effect: String) -> Color {
        switch effect {
        case "EQ": return JarasTheme.green
        case "Compressor": return Color(hex: 0xffb547)
        case "Limiter": return Color(hex: 0xff625b)
        case "Pitch": return Color(hex: 0xc39aff)
        case "Delay": return Color(hex: 0x56bfff)
        default: return Color(hex: 0xca88ff)
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("CatLive FX · " + (FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—")).font(.headline).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).jarasHelp("Close")
            }
            HStack(spacing: 4) {
                ForEach(pages, id: \.self) { effect in
                    let active = effect == "CatStemSeparation 5" || enabledEffects.contains(effect)
                    let tint = color(effect)
                    Button { page = effect } label: {
                        Text(LocalizedStringKey(effect == "Limiter" ? "CatLive Limiter" : effect)).font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(tint.opacity(active ? 0.30 : 0.06))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(page == effect ? 0.95 : active ? 0.55 : 0.14), lineWidth: page == effect ? 1.5 : 1))
                            .cornerRadius(5).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(tint.opacity(active ? 1 : 0.38))
                        .accessibilityAddTraits(page == effect ? .isSelected : [])
                        .accessibilityValue(Text(active ? "Enabled" : "Disabled"))
                }
            }
            #if os(macOS)
            if page == "CatStemSeparation 5" {
                CatStemFXEditor(show: show, track: nil, clip: clip)
            } else {
                FXEditor(show: show, track: nil, clip: clip, clipChainEditor: true, effect: page, close: close).id(page)
            }
            #else
            FXEditor(show: show, track: nil, clip: clip, clipChainEditor: true, effect: page, close: close).id(page)
            #endif
        }.padding(20).frame(minWidth: 640, idealWidth: 740, maxWidth: .infinity, minHeight: 540, idealHeight: 560, maxHeight: .infinity)
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onReceive(show.$snapshot.map { snapshot -> Set<String> in
                guard let item = FXModelLookup.clip(clip, in: snapshot.project), item.fxBypassed != true,
                      let fx = item.fx else { return [] }
                return Set(pages.filter { fx.inserted.contains($0) && fx.isEnabled($0) })
            }.removeDuplicates()) { enabledEffects = $0 }
            #if os(macOS)
            .onExitCommand(perform: close)
            #endif
    }
}
#if os(macOS)
import AppKit
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
