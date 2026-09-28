import SwiftUI
import UniformTypeIdentifiers

struct TrackMixerRow: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.show === rhs.show && lhs.trackSelection == rhs.trackSelection && lhs.track == rhs.track && lhs.nextTrack == rhs.nextTrack && lhs.number == rhs.number && lhs.selected == rhs.selected && lhs.silenced == rhs.silenced && lhs.showsMeterScale == rhs.showsMeterScale && lhs.showsFader == rhs.showsFader && lhs.isFolder == rhs.isFolder && lhs.lastChild == rhs.lastChild && (lhs.groupSelection != nil) == (rhs.groupSelection != nil)
    }
    @Environment(\.openFX) private var openFX
    @Environment(\.editTextItem) private var editTextItem
    let show: ShowController
    let track: Track
    let trackSelection: Set<UUID>
    let nextTrack: UUID?
    let number: Int
    let selected: Bool
    let silenced: Bool
    let showsMeterScale: Bool
    let showsFader: Bool
    let isFolder: Bool
    let lastChild: Bool
    let groupSelection: (() -> Void)?
    let select: () -> Void
    var importVideo: () -> Void = {}
    @State private var patchPresented = false
    @State private var fxPresented = false
    private var targets: [UUID?] {
        guard track.kind == .standard, trackSelection.contains(track.id) else { return [track.id] }
        return (show.current?.tracks ?? []).filter { $0.kind == .standard && trackSelection.contains($0.id) }.map { Optional($0.id) }
    }
    @Environment(\.editTrackDetails) private var editTrackDetails
    @ObservedObject private var dragState = TrackReorderState.shared
    private var dropSide: Bool? { dragState.target == track.id ? dragState.after : nil }
    var body: some View {
        HStack(spacing: 4) {
            if track.parentTrackID != nil {
                GroupTrackConnector(last: lastChild).stroke(JarasTheme.green.opacity(0.7), lineWidth: 1)
                    .frame(width: 12).allowsHitTesting(false)
            }
            VerticalTrackMeter(meter: StemAudioPlayback.shared.meter(for: track.id), showScale: showsMeterScale)
                .frame(width: showsMeterScale ? 32 : 12).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if track.kind != .standard {
                        Text(String(format: "%02d  %@", number, track.name)).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    } else { Spacer(minLength: 0) }
                HStack(spacing: 3) {
                    if track.kind == .standard {
                    if showsFader {
                        Button("FX") {
                            openFX(track.id, track.fx?.effectKeys.first ?? "Chain")
                        }.foregroundStyle(track.fx?.inserted.isEmpty == false ? JarasTheme.green : JarasTheme.text).jarasHelp("Insert effect")
                    }
                    TrackRecordButton(show: show, track: track).buttonStyle(CompactTrackButtonStyle())
                    TrackPanFader(show: show, track: track.id, pan: track.pan).frame(width: 42, height: 24)
                    Button("M") { show.send(.mute, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "mute")).foregroundStyle(track.mute ? .orange : JarasTheme.text)
                    Button("S") { show.send(.solo, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "solo")).foregroundStyle(track.solo ? JarasTheme.yellow : JarasTheme.text)
                    } else if track.kind == .timecode {
                        HStack(spacing: 3) {
                            Button { patchPresented = true } label: { Image(systemName: "gearshape") }
                            ForEach(["mtc","ltc"], id: \.self) { mode in
                                let active = (track.timecode?.mode ?? "mtc") == mode
                                Button(mode.uppercased()) { var settings = track.timecode ?? TimecodeSettings(); settings.mode = mode; show.setTimecode(track.id, settings: settings) }
                                    .foregroundStyle(active ? .black : .white)
                                    .buttonStyle(TrackControlButtonStyle(activeColor: active ? JarasTheme.green : nil))
                            }
                        }.buttonStyle(TrackControlButtonStyle()).fixedSize(horizontal: true, vertical: false)
                        Button("M") { show.send(.mute, target: track.id) }.foregroundStyle(track.mute ? .orange : JarasTheme.text)
                    } else if track.kind == .video {
                        Button("Add video", action: importVideo).buttonStyle(TrackControlButtonStyle())
                    } else if track.kind.isText {
                        Button("Add text") {
                            if let item = show.addTextItem(track: track.id) { editTextItem(item) }
                        }.buttonStyle(TrackControlButtonStyle())
                    }
                }.buttonStyle(CompactTrackButtonStyle())
                }.frame(height: 24)
                if track.kind == .teleprompt {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Add media", action: importVideo).buttonStyle(TrackControlButtonStyle())
                    }.frame(height: 24)
                }
                if track.kind == .standard {
                    HStack(spacing: 4) {
                        if isFolder { Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(JarasTheme.green) }
                        #if os(macOS)
                        TrackDragTitle(title: String(format: "%02d  %@", number, track.name), track: track.id, state: dragState, select: select)
                            .frame(maxWidth: .infinity).frame(height: 16)
                        #else
                        Text(String(format: "%02d  %@", number, track.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle()).onDrag { dragState.begin(); select(); return NSItemProvider(object: ("jaras-track:" + track.id.uuidString) as NSString) }
                        #endif
                    }.frame(height: 16)
                }
                HStack(spacing: 3) {
                    if showsFader && track.kind == .standard {
                        TrackVolumeFader(show: show, track: track.id, volume: track.volume, compact: true)
                    }
                }.buttonStyle(TrackControlButtonStyle()).frame(height: track.kind == .standard ? 20 : 4)
                Spacer(minLength: 1)
            }.padding(.top, 3).padding(.trailing, 4)
        }.frame(maxHeight: .infinity).clipped()
            .background { HStack(spacing: 0) {
                if track.parentTrackID != nil { JarasTheme.mixer.frame(width: 16) }
                JarasTheme.track(track, emphasized: selected && track.kind == .standard).opacity(selected && track.kind == .standard ? 0.95 : 0.50)
            }.allowsHitTesting(false) }
            .saturation(silenced ? 0 : 1)
            .overlay { Rectangle().stroke(selected && track.kind == .standard ? Color.white : .clear, lineWidth: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16).allowsHitTesting(false) }
            .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16) }
            .background { GeometryReader { geometry in
                if track.kind == .standard { Color.clear.onDrop(of: [UTType.text], delegate: TrackInsertionDrop(show: show, track: track.id, nextTrack: nextTrack, height: geometry.size.height, state: dragState)) }
            } }
            .overlay(alignment: dropSide == true ? .bottom : .top) {
                if dropSide != nil { Rectangle().fill(JarasTheme.green).frame(height: 3).shadow(color: JarasTheme.green, radius: 4).allowsHitTesting(false) }
            }
            #if os(macOS)
            .overlay(TrackRightClickInput(track: track.id, kind: track.kind, select: select, patch: { patchPresented = true }, fx: { fxPresented = true }, edit: { editTrackDetails(track.id, track.name, track.color ?? JarasTheme.roleHex(track.role)) }, group: groupSelection, ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil))
            #else
            .onTapGesture(perform: select)
            .contextMenu {
                Button("Patch") { patchPresented = true }
                Button("FX") { fxPresented = true }
                Button("Editar pista") { editTrackDetails(track.id, track.name, track.color ?? JarasTheme.roleHex(track.role)) }
            }
            #endif
            .sheet(isPresented: $patchPresented) {
                VStack { PatchEditor(show: show, track: track.id, targets: targets); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .sheet(isPresented: $fxPresented) {
                FXInsertEditor(show: show, track: track.id, targets: targets) { fxPresented = false }
            }

    }
}
private struct GroupTrackConnector: Shape {
    let last: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 5, y: 0))
        path.addLine(to: CGPoint(x: 5, y: last ? 17 : rect.height))
        path.move(to: CGPoint(x: 5, y: 17)); path.addLine(to: CGPoint(x: rect.maxX, y: 17))
        return path
    }
}
struct MasterStrip: View {
    @Environment(\.openFX) private var openFX
    @ObservedObject var show: ShowController
    var body: some View {
        HStack(spacing: 4) {
            VerticalTrackMeter(meter: StemAudioPlayback.shared.masterMeter, showScale: false)
                .frame(width: 12).padding(.vertical, 4)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("Master").font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 2)
                    Button("FX") { openFX(nil, show.snapshot.project.masterFX?.effectKeys.first ?? "Chain") }
                        .foregroundStyle(show.snapshot.project.masterFX?.inserted.isEmpty == false ? JarasTheme.green : JarasTheme.text).jarasHelp("Insert effect")
                    PatchButton(show: show, track: nil, patch: show.snapshot.project.masterPatch ?? .stereo)
                    Button("M") { show.send(.mute) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "mute")).foregroundStyle(show.snapshot.project.masterMute == true ? .orange : JarasTheme.text)
                }.font(.system(size: 10, weight: .semibold)).buttonStyle(.bordered).controlSize(.small)
                TrackVolumeFader(show: show, track: nil, volume: show.snapshot.project.masterVolume ?? 1, compact: true)
            }
        }.padding(.horizontal, 6).frame(minWidth: 190, maxWidth: .infinity).frame(height: 54).background(JarasTheme.yellow.opacity(0.5)).cornerRadius(6)
    }
}
struct PatchButton: View {
    let show: ShowController
    let track: UUID?
    let patch: OutputPatch
    var label = "Patch"
    @State private var presented = false
    var body: some View {
        Button(LocalizedStringKey(label)) { presented = true }.jarasHelp("Audio input and output")
            .popover(isPresented: $presented) {
                PatchEditor(show: show, track: track, targets: [track])
            }
    }
}
struct PatchEditor: View {
    @ObservedObject var show: ShowController
    let track: UUID?
    let targets: [UUID?]
    @ObservedObject private var audio = AudioDeviceSettings.shared
    private var settings: Track? { track.flatMap { id in show.current?.tracks.first { $0.id == id } } }
    private var outputs: [OutputPatch] { settings?.outputPatches ?? show.snapshot.project.masterOutputPatches }
    private func routes(_ receive: Bool) -> [UUID?] { receive ? settings?.routing?.receives ?? [] : settings?.routing?.transmitters ?? [] }
    private var outputChoices: [OutputPatch] {
        let allInGroup = !targets.isEmpty && targets.allSatisfy { id in
            id.flatMap { track in show.current?.tracks.first { $0.id == track }?.parentTrackID } != nil
        }
        return OutputPatch.choices(channels: audio.channels, includeMaster: track != nil && settings?.kind == .standard, includeGroup: allInGroup, includeNone: true)
    }
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(settings?.kind == .timecode ? "Timecode" : "Patch").font(.headline)
                    if let settings, settings.kind == .timecode { TimecodeOptions(show: show, track: settings) }
                    Text(audio.deviceName).font(.caption).foregroundStyle(JarasTheme.secondary)
                    if let track, let settings = show.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == track }), settings.kind == .standard {
                        let input = settings.inputPatch ?? TrackRecording.shared.defaultInputPatch
                        let choices = OutputPatch.choices(channels: TrackRecording.shared.inputChannels, includeMaster: false)
                        Picker("Input", selection: Binding(get: { input }, set: { applyInput($0) })) {
                            if !choices.contains(input) { Text(input.title + " — " + JarasLocalization.string("Unavailable")).tag(input) }
                            ForEach(choices, id: \.self) { choice in Text(choice.title).tag(choice) }
                        }.disabled(TrackRecording.shared.recording)
                    }
                    if let track, let settings = show.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == track }), settings.kind == .standard {
                        Picker("MIDI input", selection: Binding(get: { settings.midiInput ?? 0 }, set: { applyMIDI($0) })) {
                            Text("None").tag(0)
                            ForEach(0..<3, id: \.self) { slot in Text(audio.midiSlotTitle(slot)).tag(slot + 1) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Output").font(.subheadline.bold())
                            Spacer()
                            Button { editOutputs { $0.append(.none) } } label: { Image(systemName: "plus") }
                                .help("Add output").accessibilityLabel("Add output")
                        }
                        ForEach(Array(outputs.enumerated()), id: \.offset) { entry in
                            let slot = entry.offset
                            HStack {
                                Picker("Output", selection: Binding(get: { outputs.indices.contains(slot) ? outputs[slot] : .none }, set: { value in editOutputs { if $0.indices.contains(slot) { $0[slot] = value } } })) {
                                    if !outputChoices.contains(entry.element) { Text(entry.element.title + " — " + JarasLocalization.string("Unavailable")).tag(entry.element) }
                                    ForEach(outputChoices, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden()
                                Button { editOutputs { if $0.indices.contains(slot) { $0.remove(at: slot) } } } label: { Image(systemName: "minus.circle") }
                                    .help("Remove output").accessibilityLabel("Remove output")
                            }
                        }
                        if settings?.kind == .standard {
                            ForEach([true, false], id: \.self) { receive in
                                Divider()
                                HStack {
                                    Text(receive ? "Receive" : "Transmitter").font(.subheadline.bold())
                                    Spacer()
                                    Button { show.addTrackRoute(Set(targets.compactMap { $0 }), receive: receive) } label: { Image(systemName: "plus") }
                                        .help(receive ? "Add receive" : "Add transmitter").accessibilityLabel(receive ? "Add receive" : "Add transmitter")
                                }
                                ForEach(routes(receive).indices, id: \.self) { slot in
                                    HStack {
                                        Picker(receive ? "Receive" : "Transmitter", selection: Binding<UUID?>(
                                            get: { routes(receive).indices.contains(slot) ? routes(receive)[slot] : nil },
                                            set: { show.setTrackRouting(Set(targets.compactMap { $0 }), receive: receive, slot: slot, other: $0) })) {
                                            Text("None").tag(Optional<UUID>.none)
                                            ForEach(show.current?.tracks.filter { $0.kind == .standard && !targets.contains($0.id) } ?? []) { candidate in
                                                Text(verbatim: candidate.name).tag(Optional(candidate.id))
                                            }
                                        }.labelsHidden()
                                        Button { show.removeTrackRoute(Set(targets.compactMap { $0 }), receive: receive, slot: slot) } label: { Image(systemName: "minus.circle") }
                                            .help(receive ? "Remove receive" : "Remove transmitter").accessibilityLabel(receive ? "Remove receive" : "Remove transmitter")
                                    }
                                }
                            }
                        }
                    }.frame(width: 290)

                }.padding(18).foregroundStyle(JarasTheme.text)
        }.scrollIndicators(.hidden).frame(maxHeight: 560)
    }
    private func applyInput(_ input: OutputPatch) {
        for id in targets.compactMap({ $0 }) {
            let settings = show.snapshot.project.songs.flatMap(\.tracks).first { $0.id == id }
            show.setRecording(id, input: input, format: settings?.recordingFormat ?? "wav")
        }
    }
    private func applyMIDI(_ slot: Int) { for id in targets.compactMap({ $0 }) { show.setMIDIInput(id, slot: slot) } }
    private func editOutputs(_ change: (inout [OutputPatch]) -> Void) {
        for id in targets {
            var values = id.flatMap { id in show.current?.tracks.first { $0.id == id }?.outputPatches } ?? show.snapshot.project.masterOutputPatches
            change(&values); show.setOutputPatches(track: id, patches: values)
        }
    }
}

private struct CompactTrackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .frame(width: 22, height: 21)
            .background(JarasTheme.text.opacity(configuration.isPressed ? 0.24 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3)).contentShape(Rectangle())
    }
}
private struct TrackControlButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(minWidth: 30, minHeight: 24)
            .background(activeColor.map { $0.opacity(configuration.isPressed ? 0.75 : 1) } ?? JarasTheme.text.opacity(configuration.isPressed ? 0.24 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(JarasTheme.text.opacity(0.18)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct TrackPanFader: View {
    let show: ShowController
    let track: UUID
    let pan: Double
    @State private var dragging = false
    @State private var dragValue = 0.0
    private var valueLabel: String {
        let value = dragging ? dragValue : pan
        let percent = Int((min(1, abs(value)) * 100).rounded())
        return percent == 0 ? "Center" : "\(percent)% \(value < 0 ? "L" : "R")"
    }
    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DirectVolumeSlider(value: pan, minimum: -1, maximum: 1, mini: true, changed: { value in
                dragValue = value
                show.previewTrackPan(track, pan: value)
            }, editingChanged: { editing, value in
                dragValue = value; dragging = editing
                if !editing { show.send(.pan, target: track, value: value) }
            }).frame(height: 13)
                .accessibilityLabel("Pan").accessibilityValue(valueLabel)
                .jarasHelp("Pan · Double-click to center")
            #else
            Slider(value: Binding(get: { pan }, set: { show.send(.pan, target: track, value: $0) }), in: -1...1)
                .frame(height: 13)
                .simultaneousGesture(TapGesture(count: 2).onEnded { show.send(.pan, target: track, value: 0) })
            #endif
            Text(verbatim: valueLabel).font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(JarasTheme.text).lineLimit(1).frame(height: 10).allowsHitTesting(false)
        }
    }
}

private struct TrackVolumeFader: View {
    let show: ShowController
    let track: UUID?
    let volume: Double
    var compact = false
    @State private var decibels = 0.0
    @State private var dragging = false
    private var gain: Double { decibels <= -60 ? 0 : pow(10, decibels / 20) }
    var body: some View {
        let displayedDB = dragging ? decibels : (volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))))
        return HStack(spacing: compact ? 3 : 6) {
            Text(displayedDB <= -60 ? "−∞" : String(format: "%+.1f", displayedDB))
                .font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                .foregroundStyle(JarasTheme.text).frame(width: compact ? 34 : 40, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(count: 2) { decibels = 0; show.send(.volume, target: track, value: 1) }
                .jarasHelp("Double-click to reset to 0 dB")
            volumeControl
                .modifier(MappingRightClick(track: track, command: "volume"))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(track == nil ? "Master volume" : "Track volume")
                .accessibilityValue(displayedDB <= -60 ? "−∞ dB" : String(format: "%.1f dB", displayedDB))
        }.frame(height: compact ? 20 : 27).padding(.horizontal, 4)
            .onAppear { synchronize() }
            .onChange(of: volume) { _ in if !dragging { synchronize() } }
            .onChange(of: show.snapshot.project.id) { _ in dragging = false; synchronize() }
    }
    private var volumeBinding: Binding<Double> {
        Binding(get: { decibels }, set: {
            decibels = $0
            show.previewTrackVolume(track, gain: gain)
            if !dragging { show.send(.volume, target: track, value: gain) }
        })
    }
    private func editingChanged(_ editing: Bool) {
        dragging = editing
        if !editing { show.send(.volume, target: track, value: gain) }
    }
    @ViewBuilder private var volumeControl: some View {
        #if os(macOS)
        DirectVolumeSlider(value: volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))), changed: { value in
            decibels = value
            show.previewTrackVolume(track, gain: value <= -60 ? 0 : pow(10, value / 20))
        }, editingChanged: { editing, value in
            decibels = value
            dragging = editing
            if !editing { show.send(.volume, target: track, value: value <= -60 ? 0 : pow(10, value / 20)) }
        })
        #else
        Slider(value: volumeBinding, in: -60...12, onEditingChanged: editingChanged)
            .tint(JarasTheme.green)
            .simultaneousGesture(TapGesture(count: 2).onEnded { decibels = 0; show.send(.volume, target: track, value: 1) })
        #endif
    }
    private func synchronize() { decibels = volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))) }
}

#if os(macOS)
import AppKit
private struct DirectVolumeSlider: NSViewRepresentable {
    let value: Double
    var minimum = -60.0
    var maximum = 12.0
    var mini = false
    let changed: (Double) -> Void
    let editingChanged: (Bool, Double) -> Void
    func makeNSView(context: Context) -> DirectVolumeSliderView {
        let slider = DirectVolumeSliderView()
        slider.minValue = minimum; slider.maxValue = maximum
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: DirectVolumeSliderView, context: Context) {
        slider.mini = mini
        slider.synchronizeModel(value)
        slider.changed = changed
        slider.editingChanged = { [weak slider] editing in if let slider { editingChanged(editing, slider.doubleValue) } }
    }
}
private final class DirectVolumeSliderView: NSView {
    var mini = false
    var minValue = -60.0
    var maxValue = 12.0
    var isEnabled = true
    private var lastModelValue: Double?
    // A SwiftUI redraw carrying the same committed value is not a new volume
    // command. Preserve the pointer value until a genuinely new model arrives.
    func synchronizeModel(_ value: Double) {
        guard value != lastModelValue else { return }
        guard !trackingPointer else { return }
        lastModelValue = value
        doubleValue = value
    }
    var doubleValue = 0.0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 27) }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let radius: CGFloat = mini ? 4 : 8
        let railHeight: CGFloat = mini ? 3 : 6
        let rail = NSRect(x: radius, y: bounds.midY - railHeight / 2, width: max(1, bounds.width - radius * 2), height: railHeight)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
        let fraction = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
        let x = radius + CGFloat(fraction) * max(1, bounds.width - radius * 2)
        if mini {
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSRect(x: bounds.midX - 0.5, y: bounds.midY - 5, width: 1, height: 10).fill()
        }
        NSColor(white: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2), xRadius: radius - 1, yRadius: radius - 1).fill()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            editingChanged?(true)
            doubleValue = min(maxValue, max(minValue, doubleValue + (event.keyCode == 124 ? 1 : -1) * (mini ? 0.05 : 0.5)))
            changed?(doubleValue); editingChanged?(false)
        } else { super.keyDown(with: event) }
    }
    var changed: ((Double) -> Void)?
    var editingChanged: ((Bool) -> Void)?
    private(set) var trackingPointer = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { VolumeDoubleClickRouter.shared.add(self) }
    }
    func resetToUnity() {
        trackingPointer = true
        editingChanged?(true)
        doubleValue = 0
        changed?(0)
        editingChanged?(false)
        trackingPointer = false
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        trackingPointer = true
        editingChanged?(true)
        if event.clickCount >= 2 {
            resetToUnity()
        } else {
            trackingPointer = true
            move(to: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if trackingPointer { move(to: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard trackingPointer else { return }
        editingChanged?(false)
        trackingPointer = false
    }
    private func move(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let knobWidth: CGFloat = mini ? 8 : 16
        let inset = knobWidth / 2
        let fraction = min(1, max(0, (point.x - inset) / max(1, bounds.width - knobWidth)))
        doubleValue = minValue + Double(fraction) * (maxValue - minValue)
        changed?(doubleValue)
        needsDisplay = true
    }
}
@MainActor private final class VolumeDoubleClickRouter {
    static let shared = VolumeDoubleClickRouter()
    private let sliders = NSHashTable<DirectVolumeSliderView>.weakObjects()
    private var monitor: Any?
    func add(_ slider: DirectVolumeSliderView) {
        sliders.add(slider)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount >= 2, !event.modifierFlags.contains(.control),
                  let window = event.window, window.attachedSheet == nil,
                  let slider = self?.sliders.allObjects.first(where: {
                      $0.window === window && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor &&
                      $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) &&
                      $0.visibleRect.contains($0.convert(event.locationInWindow, from: nil))
                  }) else { return event }
            slider.resetToUnity()
            return nil
        }
    }
}

#endif

/// One insertion indicator for the entire drag, including cancellation outside a row.
private final class TrackReorderState: ObservableObject {
    static let shared = TrackReorderState()
    @Published var target: UUID?
    @Published var after = false
    private(set) var active = false
    #if os(macOS)
    var source: TrackDragSource?
    #endif
    func begin() { finish(); active = true }
    func indicate(_ id: UUID, after: Bool) {
        guard active else { return }
        target = id; self.after = after
    }
    func finish() {
        active = false; target = nil
        #if os(macOS)
        source = nil
        #endif
    }
}

private struct TrackInsertionDrop: DropDelegate {
    let show: ShowController
    let track: UUID
    let nextTrack: UUID?
    let height: CGFloat
    let state: TrackReorderState
    func dropEntered(info: DropInfo) { state.indicate(track, after: info.location.y > height / 2) }
    func dropUpdated(info: DropInfo) -> DropProposal? { state.indicate(track, after: info.location.y > height / 2); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if state.target == track { state.target = nil } }
    func performDrop(info: DropInfo) -> Bool {
        let before = info.location.y > height / 2 ? nextTrack : track
        state.finish()
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value, value.hasPrefix("jaras-track:"), let id = UUID(uuidString: String(value.dropFirst(12))) else { return }
            Task { @MainActor in show.reorderTrack(id, before: before) }
        }
        return true
    }
}
#if os(macOS)
private struct TrackRightClickInput: NSViewRepresentable {
    @Environment(\.gridInteractionBlocked) private var interactionBlocked
    let track: UUID
    let kind: TrackKind
    let select: () -> Void
    let patch: () -> Void
    let fx: () -> Void
    let edit: () -> Void
    let group: (() -> Void)?
    let ungroup: (() -> Void)?
    func makeNSView(context: Context) -> TrackRightClickView { TrackRightClickView() }
    func updateNSView(_ view: TrackRightClickView, context: Context) { view.interactionBlocked = interactionBlocked; view.track = track; view.kind = kind; view.select = select; view.patch = patch; view.fx = fx; view.edit = edit; view.group = group; view.ungroup = ungroup; view.action = { [weak view] in view?.openMenu() } }
}
/// Resolve one row per click, including after native scroll hosting recycles rows.
/// The title also calls this route directly, so selecting it never relies solely
/// on a passive event monitor. Both paths share the event to avoid double toggles.
@MainActor private final class TrackSelectionRouter {
    static let shared = TrackSelectionRouter()
    private let rows = NSHashTable<TrackRightClickView>.weakObjects()
    private var monitor: Any?
    private var lastEventTime: TimeInterval?
    func add(_ row: TrackRightClickView) {
        rows.add(row)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, window.attachedSheet == nil,
                  !RightClickRouter.shared.interactionBlocked,
                  !event.modifierFlags.contains(.control), ControlMappings.shared.editing == nil else { return event }
            let matches = self.rows.allObjects.filter { row in
                let point = row.convert(event.locationInWindow, from: nil)
                return row.kind == .standard && !row.interactionBlocked && row.window === window && !row.isHiddenOrHasHiddenAncestor &&
                    row.bounds.contains(point) && row.visibleRect.contains(point)
            }
            if let row = matches.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                // Let a native title receive mouseDown first. Its direct route
                // wins over a stale hosted row frame during scroll/layout updates.
                DispatchQueue.main.async { [weak self, weak row] in
                    guard let self, let row, row.window === window else { return }
                    self.perform(track: row.track, event: event) { row.select?() }
                }
            }
            return event
        }
    }
    func perform(track: UUID, event: NSEvent, action: () -> Void) {
        guard lastEventTime != event.timestamp else { return }
        lastEventTime = event.timestamp
        action()
    }
}
private final class TrackRightClickView: RightClickTargetView {
    var kind = TrackKind.standard
    var track = UUID()
    var select: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TrackSelectionRouter.shared.add(self) }
    }
    var patch: (() -> Void)?
    var fx: (() -> Void)?
    var edit: (() -> Void)?
    var group: (() -> Void)?
    var ungroup: (() -> Void)?
    func openMenu() {
        guard let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        if kind == .standard || kind == .timecode {
        let routing = NSMenuItem(title: "Patch", action: #selector(openPatch), keyEquivalent: "")
        routing.target = self; menu.addItem(routing)
        }
        if kind == .standard {
        let effects = NSMenuItem(title: "FX", action: #selector(openEffects), keyEquivalent: "")
        effects.target = self; menu.addItem(effects)
        }
        if group != nil && kind == .standard {
        let create = NSMenuItem(title: JarasLocalization.string("Create group"), action: #selector(createGroup), keyEquivalent: "")
        create.target = self; menu.addItem(create)
        }
        if ungroup != nil {
            let item = NSMenuItem(title: JarasLocalization.string("Ungroup"), action: #selector(ungroupTracks), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        let details = NSMenuItem(title: JarasLocalization.string("Editar pista"), action: #selector(editDetails), keyEquivalent: "")
        details.target = self; menu.addItem(details)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func openPatch() { patch?() }
    @objc private func openEffects() { fx?() }
    @objc private func ungroupTracks() { ungroup?() }
    @objc private func createGroup() { group?() }
    @objc private func editDetails() { edit?() }
}

#endif

#if os(macOS)
private struct TrackDragTitle: NSViewRepresentable {
    let title: String
    let track: UUID
    let state: TrackReorderState
    let select: () -> Void
    func makeNSView(context: Context) -> TrackDragTitleView { TrackDragTitleView() }
    func updateNSView(_ view: TrackDragTitleView, context: Context) {
        view.title = title; view.track = track; view.state = state; view.select = select
        view.needsDisplay = true
    }
}
private final class TrackDragSource: NSObject, NSDraggingSource {
    weak var state: TrackReorderState?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { state?.finish() }
}
private final class TrackDragTitleView: NSView {
    var title = ""
    var track = UUID()
    weak var state: TrackReorderState?
    var select: (() -> Void)?
    private var down: NSPoint?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    private func label() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
    override func draw(_ dirtyRect: NSRect) { label().draw(in: NSRect(x: 0, y: (bounds.height - 14) / 2, width: bounds.width, height: 14)) }
    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        TrackSelectionRouter.shared.perform(track: track, event: event) { self.select?() }
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let state, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4 else { return }
        self.down = nil
        state.begin()
        let source = TrackDragSource(); source.state = state; state.source = source
        let item = NSDraggingItem(pasteboardWriter: ("jaras-track:" + track.uuidString) as NSString)
        let size = NSSize(width: max(1, bounds.width), height: 28)
        let text = label()
        let preview = NSImage(size: size, flipped: true) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            text.draw(in: rect.insetBy(dx: 4, dy: 7)); return true
        }
        item.setDraggingFrame(bounds, contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
}
#endif
