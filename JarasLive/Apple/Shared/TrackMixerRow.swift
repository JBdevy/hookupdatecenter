import SwiftUI
import UniformTypeIdentifiers

private struct TrackPanelTarget: Identifiable {
    let project: UUID
    let track: UUID
    let targets: [UUID?]
    var id: UUID { track }
}

private struct TrackControlIdentity: Equatable {
    let project: UUID
    let track: UUID?
}

struct TrackMixerRow: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.show === rhs.show && lhs.projectID == rhs.projectID && lhs.trackSelection == rhs.trackSelection && lhs.track == rhs.track && lhs.nextTrack == rhs.nextTrack && lhs.number == rhs.number && lhs.selected == rhs.selected && lhs.silenced == rhs.silenced && lhs.showsMeterScale == rhs.showsMeterScale && lhs.showsFader == rhs.showsFader && lhs.isFolder == rhs.isFolder && lhs.lastChild == rhs.lastChild && (lhs.groupSelection != nil) == (rhs.groupSelection != nil)
    }
    @Environment(\.openFX) private var openFX
    @Environment(\.editTextItem) private var editTextItem
    let show: ShowController
    let projectID: UUID
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
    @State private var patchTarget: TrackPanelTarget?
    @State private var fxTarget: TrackPanelTarget?
    private var targets: [UUID?] {
        guard track.kind == .standard, trackSelection.contains(track.id) else { return [track.id] }
        return (show.current?.tracks ?? []).filter { $0.kind == .standard && trackSelection.contains($0.id) }.map { Optional($0.id) }
    }
    @Environment(\.editTrackDetails) private var editTrackDetails
    @ObservedObject private var dragState = TrackReorderState.shared
    private var dropSide: Bool? { dragState.target == track.id ? dragState.after : nil }
    private func editorTarget(project: UUID) -> TrackPanelTarget? {
        guard show.snapshot.project.id == project else { return nil }
        return TrackPanelTarget(project: project, track: track.id, targets: targets)
    }
    private var canLink: Bool { trackSelection.contains(track.id) && show.current?.linkableTracks(trackSelection) != nil }
    private func linkSelectedTracks() {
        guard let song = show.current, let indices = song.linkableTracks(trackSelection) else { return }
        let top = song.tracks[indices[0]]
        show.linkTracks(trackSelection, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel, color: top.color ?? JarasTheme.roleHex(top.role))
    }
    var body: some View {
        let project = projectID
        let editTargets = Set(targets.compactMap { $0 })
        let details = TrackDetailsEditRequest(project: project, tracks: editTargets,
            name: track.name, color: track.color ?? JarasTheme.roleHex(track.role),
            nameEditable: editTargets.count == 1 && track.kind == .standard)
        let title = (number < 10 ? "0" : "") + String(number) + "  " + track.name
        let titleColor = JarasTheme.trackNameHex(track, emphasized: selected && track.kind == .standard, silenced: silenced)
        HStack(spacing: 4) {
            if track.parentTrackID != nil {
                GroupTrackConnector(last: lastChild).stroke(JarasTheme.green.opacity(0.7), lineWidth: 1)
                    .frame(width: 12).allowsHitTesting(false)
            }
            VerticalTrackMeter(meter: StemAudioPlayback.shared.meter(for: track.id), showScale: showsMeterScale)
                .frame(width: showsMeterScale ? 40 : 12).padding(.vertical, 4)
            if track.kind == .standard {
                TrackMIDIIndicator(state: InstrumentKeyboardState.shared.activity(track.id))
                    .frame(width: 4).padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if track.kind != .standard && track.kind != .video && track.kind != .timecode {
                        Text(title).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: titleColor))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if isFolder { Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(JarasTheme.green) }
                        Spacer(minLength: 0)
                    }
                HStack(spacing: 3) {
                    if track.kind == .standard {
                    if showsFader {
                        Button("FX") {
                            openFX(track.id, track.fx?.effectKeys.first ?? "Chain")
                        }.foregroundStyle(track.fx?.inserted.isEmpty == false ? JarasTheme.green : JarasTheme.text).jarasHelp("Insert effect")
                    }
                    TrackRecordButton(show: show, track: track).buttonStyle(CompactTrackButtonStyle())
                    TrackPanFader(show: show, track: track.id, pan: track.pan).frame(width: 42, height: 24)
                    Button("M") { show.send(.mute, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "mute")).buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil))
                    Button("S") { show.send(.solo, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "solo")).buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
                    } else if track.kind == .timecode {
                        HStack(spacing: 3) {
                            Button { patchTarget = editorTarget(project: project) } label: { Image(systemName: "gearshape") }
                            ForEach(["mtc","ltc"], id: \.self) { mode in
                                let active = (track.timecode?.mode ?? "mtc") == mode
                                Button(mode.uppercased()) { var settings = track.timecode ?? TimecodeSettings(); settings.mode = mode; show.setTimecode(track.id, settings: settings) }
                                    .foregroundStyle(active ? .black : .white)
                                    .buttonStyle(TrackControlButtonStyle(activeColor: active ? JarasTheme.green : nil))
                            }
                        }.buttonStyle(TrackControlButtonStyle()).fixedSize(horizontal: true, vertical: false)
                        Button("M") { show.send(.mute, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil))
                    } else if track.kind == .video {
                        Button("Add media", action: importVideo).buttonStyle(TrackControlButtonStyle())
                        Button("M") { show.send(.mute, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil))
                        Button("S") { show.send(.solo, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
                    } else if track.kind.isText {
                        Button("Add text") {
                            if let item = show.addTextItem(track: track.id) { editTextItem(item) }
                        }.buttonStyle(TrackControlButtonStyle())
                    }
                }.buttonStyle(CompactTrackButtonStyle())
                }.frame(height: 24)
                if track.kind.isTeleprompter {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Add media", action: importVideo).buttonStyle(TrackControlButtonStyle())
                    }.frame(height: 24).padding(.top, 5)
                }
                if track.kind == .standard || track.kind == .video || track.kind == .timecode {
                    HStack(spacing: 4) {
                        #if os(macOS)
                        if track.kind == .standard {
                        TrackDragTitle(title: title, foreground: titleColor, project: project, track: track.id, state: dragState, select: select)
                            .frame(maxWidth: .infinity).frame(height: 16)
                        } else { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: titleColor)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                        #else
                        Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(Color(hex: titleColor))
                            .contentShape(Rectangle()).onDrag { dragState.begin(); select(); return NSItemProvider(object: ("jaras-track:" + track.id.uuidString) as NSString) }
                        #endif
                    }.frame(height: 16)
                }
                HStack(spacing: 3) {
                    if showsFader && (track.kind == .standard || track.kind == .video || track.kind == .timecode) {
                        TrackVolumeFader(show: show, track: track.id, volume: track.volume, compact: true)
                    }
                }.buttonStyle(TrackControlButtonStyle()).frame(height: track.kind == .standard || track.kind == .video || track.kind == .timecode ? 20 : 4)
                Spacer(minLength: 1)
            }.padding(.top, 3).padding(.trailing, 4)
        }.frame(maxHeight: .infinity).clipped()
            .background { HStack(spacing: 0) {
                if track.parentTrackID != nil { JarasTheme.mixer.frame(width: 16) }
                JarasTheme.track(track, emphasized: selected && track.kind == .standard).opacity(selected && track.kind == .standard ? 0.95 : 0.50).saturation(silenced ? 0 : 1)
            }.allowsHitTesting(false) }
            .overlay { Rectangle().stroke(selected && track.kind == .standard ? Color.white : .clear, lineWidth: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16).allowsHitTesting(false) }
            .overlay { if track.stereoLink != nil { LinkedTrackBorder().allowsHitTesting(false) } }
            .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16) }
            .background { GeometryReader { geometry in
                if track.kind == .standard { Color.clear.onDrop(of: [UTType.text], delegate: TrackInsertionDrop(show: show, track: track.id, nextTrack: nextTrack, height: geometry.size.height, state: dragState)) }
            } }
            .overlay(alignment: dropSide == true ? .bottom : .top) {
                if dropSide != nil { Rectangle().fill(JarasTheme.green).frame(height: 3).shadow(color: JarasTheme.green, radius: 4).allowsHitTesting(false) }
            }
            #if os(macOS)
            .overlay(TrackRightClickInput(project: project, track: track.id, kind: track.kind, select: select, patch: { patchTarget = editorTarget(project: project) }, fx: { fxTarget = editorTarget(project: project) }, edit: { editTrackDetails(details) }, group: show.current?.tracks.contains(where: { trackSelection.contains($0.id) && $0.stereoLink != nil }) == true ? nil : groupSelection, ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil, link: canLink ? { linkSelectedTracks() } : nil, unlink: track.stereoLink != nil ? { show.unlinkTracks(track.id) } : nil))
            #else
            .onTapGesture(perform: select)
            .contextMenu {
                Button("Patch") { patchTarget = editorTarget(project: project) }
                Button("FX") { fxTarget = editorTarget(project: project) }
                Button("Editar pista") { editTrackDetails(details) }
                if canLink { Button("Link tracks") { linkSelectedTracks() } }
                if track.stereoLink != nil { Button("Unlink tracks") { show.unlinkTracks(track.id) } }
            }
            #endif
            .sheet(item: $patchTarget) { target in
                VStack { PatchEditor(show: show, track: target.track, targets: target.targets); Button("Close") { patchTarget = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .sheet(item: $fxTarget) { target in
                FXInsertEditor(show: show, track: target.track, targets: target.targets) { fxTarget = nil }
            }
            .onChange(of: projectID) { _ in patchTarget = nil; fxTarget = nil }

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
    @State private var patchPresented = false
    @State private var fxPresented = false
    @State private var colorPresented = false
    var body: some View {
        HStack(spacing: 4) {
            VerticalTrackMeter(meter: StemAudioPlayback.shared.masterMeter, showScale: false)
                .frame(width: 12).padding(.vertical, 4)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button(show.snapshot.project.masterMono == true ? "Mono" : "Stereo") { show.send(.masterMono) }
                        .foregroundStyle(show.snapshot.project.masterMono == true ? JarasTheme.green : JarasTheme.text)
                        .jarasHelp("Toggle Master Stereo/Mono").accessibilityLabel("Master Stereo/Mono")
                    Spacer(minLength: 2)
                    Button("FX") { openFX(nil, show.snapshot.project.masterFX?.effectKeys.first ?? "Chain") }
                        .foregroundStyle(show.snapshot.project.masterFX?.inserted.isEmpty == false ? JarasTheme.green : JarasTheme.text).jarasHelp("Insert effect")
                    Button("M") { show.send(.mute) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "mute")).buttonStyle(CompactTrackButtonStyle(activeColor: show.snapshot.project.masterMute == true ? .red : nil))
                    Button("S") { show.send(.solo) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "solo")).buttonStyle(CompactTrackButtonStyle(activeColor: show.snapshot.project.masterSolo == true ? JarasTheme.yellow : nil))
                }.font(.system(size: 10, weight: .semibold)).buttonStyle(.bordered).controlSize(.small).frame(height: 24)
                    Text("Master").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: JarasTheme.masterNameHex(show.snapshot.project.masterColor ?? 0xffdc52)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                TrackVolumeFader(show: show, track: nil, volume: show.snapshot.project.masterVolume ?? 1, compact: true)
                    .frame(height: 20)
            }.padding(.vertical, 4)
        }.padding(.horizontal, 6).frame(minWidth: 190, maxWidth: .infinity).frame(height: 70)
            .background(Color(hex: show.snapshot.project.masterColor ?? 0xffdc52).opacity(0.5)).cornerRadius(6)
            .contextMenu {
                Button("Patch") { patchPresented = true }
                Button("FX") { fxPresented = true }
                Button("Editar pista") { colorPresented = true }
            }
            .sheet(isPresented: $patchPresented) {
                VStack { PatchEditor(show: show, track: nil, targets: [nil]); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .sheet(isPresented: $fxPresented) {
                FXInsertEditor(show: show, track: nil, targets: [nil]) { fxPresented = false }
            }
            .sheet(isPresented: $colorPresented) {
                NameColorEditor(title: "Editar pista", initialName: "Master", initialColor: show.snapshot.project.masterColor ?? 0xffdc52,
                    save: { _, color in show.editMasterColor(color) }, nameEditable: false, showsName: false)
            }
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
                        let choices = OutputPatch.choices(channels: TrackRecording.shared.inputChannels, includeMaster: false).filter { choice in
                            guard let link = settings.stereoLink else { return true }
                            return choice.channelCount == 1 && (link.left ? choice.firstChannel < TrackRecording.shared.inputChannels : choice.firstChannel > 1)
                        }
                        Picker("Input", selection: Binding(get: { input }, set: { applyInput($0) })) {
                            if !choices.contains(input) { Text(input.title + " — " + JarasLocalization.string("Unavailable")).tag(input) }
                            ForEach(choices, id: \.self) { choice in Text(choice.title).tag(choice) }
                        }.disabled(TrackRecording.shared.recording)
                    }
                    if let track, let settings = show.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == track }), settings.kind == .standard {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MIDI input")
                                Picker("MIDI input", selection: Binding(get: { settings.midiInput ?? 0 }, set: { applyMIDI($0) })) {
                                    Text("None").tag(0)
                                    ForEach(0..<3, id: \.self) { slot in Text(audio.midiSlotTitle(slot)).tag(slot + 1) }
                                }.labelsHidden()
                            }.frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MIDI channel")
                                Picker("MIDI channel", selection: Binding(get: { settings.midiChannel ?? 0 }, set: { channel in
                                    for id in targets.compactMap({ $0 }) { show.setMIDIChannel(id, channel: channel) }
                                })) {
                                    Text("All channels").tag(0)
                                    ForEach(1...16, id: \.self) { Text(String($0)).tag($0) }
                                }.labelsHidden()
                            }.frame(width: 90)
                        }.frame(width: 290)

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
    var activeColor: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if activeColor != nil { configuration.label.foregroundStyle(Color.black) }
            else { configuration.label }
        }.font(.system(size: 10, weight: .semibold))
            .frame(width: 22, height: 21)
            .background(activeColor.map { $0.opacity(configuration.isPressed ? 0.75 : 1) } ?? JarasTheme.text.opacity(configuration.isPressed ? 0.24 : 0.12))
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
    @State private var editingIdentity: TrackControlIdentity?
    @State private var editingSession: UUID?
    private var controlIdentity: TrackControlIdentity { TrackControlIdentity(project: show.snapshot.project.id, track: track) }
    private var valueLabel: String {
        let value = dragging && editingIdentity == controlIdentity ? dragValue : pan
        let percent = Int((min(1, abs(value)) * 100).rounded())
        return percent == 0 ? "Center" : "\(percent)% \(value < 0 ? "L" : "R")"
    }
    var body: some View {
        let identity = controlIdentity
        let session = UUID()
        VStack(spacing: 0) {
            #if os(macOS)
            DirectVolumeSlider(identity: identity, value: pan, minimum: -1, maximum: 1, mini: true, linkedTrack: show.current?.tracks.first(where: { $0.id == track })?.stereoLink?.partner, changed: { value in
                guard show.snapshot.project.id == identity.project else { return }
                if editingSession == session { dragValue = value }
                show.previewTrackPan(track, pan: value)
            }, editingChanged: { editing, value in
                guard show.snapshot.project.id == identity.project else { return }
                if editing {
                    editingIdentity = identity; editingSession = session
                    dragValue = value; dragging = true
                } else {
                    if editingSession == session { dragValue = value; dragging = false; editingSession = nil }
                    show.send(.pan, target: track, value: value)
                }
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
    @State private var editingIdentity: TrackControlIdentity?
    @State private var editingSession: UUID?
    private var controlIdentity: TrackControlIdentity { TrackControlIdentity(project: show.snapshot.project.id, track: track) }
    private var gain: Double { decibels <= -60 ? 0 : pow(10, decibels / 20) }
    var body: some View {
        let displayedDB = dragging && editingIdentity == controlIdentity ? decibels : (volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))))
        return HStack(spacing: compact ? 3 : 6) {
            Text(displayedDB <= -60 ? "−∞" : String(format: "%+.1f", displayedDB))
                .font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                .foregroundStyle(JarasTheme.text).frame(width: compact ? 34 : 40, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(count: 2) { decibels = 0; show.send(.volume, target: track, value: 1) }
                .jarasHelp("Double-click to reset to 0 dB")
            volumeControl
                .frame(height: compact ? 20 : 27)
                .modifier(MappingRightClick(track: track, command: "volume", hitHeight: 16))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(track == nil ? "Master volume" : "Track volume")
                .accessibilityValue(displayedDB <= -60 ? "−∞ dB" : String(format: "%.1f dB", displayedDB))
        }.frame(height: compact ? 20 : 27).padding(.horizontal, 4)
            .onAppear { synchronize() }
            .onChange(of: volume) { _ in if !dragging { synchronize() } }
            .onChange(of: controlIdentity) { identity in
                if editingIdentity != identity { dragging = false; editingSession = nil; synchronize() }
            }
    }
    private var volumeBinding: Binding<Double> {
        Binding(get: { decibels }, set: {
            decibels = $0
            show.previewTrackVolume(track, gain: gain)
            if !dragging { show.send(.volume, target: track, value: gain) }
        })
    }
    private func editingChanged(_ editing: Bool) {
        editingIdentity = controlIdentity
        dragging = editing
        if !editing { show.send(.volume, target: track, value: gain) }
    }
    @ViewBuilder private var volumeControl: some View {
        #if os(macOS)
        let identity = controlIdentity
        let session = UUID()
        DirectVolumeSlider(identity: identity, value: volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))), linkedTrack: show.current?.tracks.first(where: { $0.id == track })?.stereoLink?.partner, changed: { value in
            guard show.snapshot.project.id == identity.project else { return }
            if editingSession == session { decibels = value }
            show.previewTrackVolume(track, gain: value <= -60 ? 0 : pow(10, value / 20))
        }, editingChanged: { editing, value in
            guard show.snapshot.project.id == identity.project else { return }
            if editing {
                editingIdentity = identity; editingSession = session
                decibels = value; dragging = true
            } else {
                if editingSession == session { decibels = value; dragging = false; editingSession = nil }
                show.send(.volume, target: track, value: value <= -60 ? 0 : pow(10, value / 20))
            }
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
    let identity: TrackControlIdentity
    let value: Double
    var minimum = -60.0
    var maximum = 12.0
    var mini = false
    var vertical = false
    var rotary = false
    var linkedTrack: UUID? = nil
    let changed: (Double) -> Void
    let editingChanged: (Bool, Double) -> Void
    func makeNSView(context: Context) -> DirectVolumeSliderView {
        let slider = DirectVolumeSliderView()
        slider.minValue = minimum; slider.maxValue = maximum
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: DirectVolumeSliderView, context: Context) {
        slider.rebind(project: identity.project, track: identity.track)
        slider.minValue = minimum; slider.maxValue = maximum; slider.mini = mini
        slider.vertical = vertical; slider.rotary = rotary
        slider.linkedTrack = linkedTrack
        slider.synchronizeModel(value)
        slider.changed = changed
        slider.editingChanged = editingChanged
    }
    static func dismantleNSView(_ slider: DirectVolumeSliderView, coordinator: ()) {
        slider.finishPointerEditing(deferred: true)
    }
}
private final class DirectVolumeSliderView: NSView {
    var mini = false { didSet { updatePanTooltip() } }
    var vertical = false
    var rotary = false
    private var rotaryOrigin = NSPoint.zero
    private var rotaryValue = 0.0
    var minValue = -60.0
    var maxValue = 12.0
    var isEnabled = true
    private var lastModelValue: Double?
    fileprivate var boundProject: UUID?
    fileprivate var boundTrack: UUID?
    var linkedTrack: UUID?
    fileprivate weak var mirroredSource: DirectVolumeSliderView?
    func rebind(project: UUID, track: UUID?) {
        guard boundProject != project || boundTrack != track else { return }
        finishPointerEditing(deferred: true)
        boundProject = project; boundTrack = track
        lastModelValue = nil; mirroredSource = nil
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    // A SwiftUI redraw carrying the same committed value is not a new volume
    // command. Preserve the pointer value until a genuinely new model arrives.
    func synchronizeModel(_ value: Double) {
        guard value != lastModelValue else { return }
        guard !trackingPointer, mirroredSource?.trackingPointer != true else { return }
        lastModelValue = value
        doubleValue = value
    }
    var doubleValue = 0.0 { didSet { needsDisplay = true; updatePanTooltip() } }
    private func updatePanTooltip() {
        guard mini else { toolTip = nil; return }
        let percent = Int((min(1, abs(doubleValue)) * 100).rounded())
        toolTip = "Pan · " + (percent == 0 ? "Center" : "\(percent)% \(doubleValue < 0 ? "L" : "R")")
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: vertical ? NSView.noIntrinsicMetric : (rotary ? 24 : 27)) }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let normalized = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
        if rotary {
            let diameter = max(1, min(bounds.width, bounds.height) - 6)
            let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            NSColor(white: 0.18, alpha: 1).setFill(); NSBezierPath(ovalIn: circle).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke(); NSBezierPath(ovalIn: circle).stroke()
            let angle = (normalized * 270 - 225) * Double.pi / 180
            let radius = min(circle.width, circle.height) * 0.4
            let path = NSBezierPath(); path.move(to: NSPoint(x: bounds.midX, y: bounds.midY))
            path.line(to: NSPoint(x: bounds.midX + cos(angle) * radius, y: bounds.midY + sin(angle) * radius))
            NSColor.systemGreen.setStroke(); path.lineWidth = 2; path.stroke(); return
        }
        if vertical {
            let rail = NSRect(x: bounds.midX - 3, y: 8, width: 6, height: max(1, bounds.height - 16))
            NSColor.white.withAlphaComponent(0.22).setFill(); NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
            let y = 8 + (1 - normalized) * max(1, bounds.height - 16)
            NSColor(white: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 11, y: y - 6, width: 22, height: 12), xRadius: 2, yRadius: 2).fill()
            NSColor.darkGray.setFill(); NSRect(x: bounds.midX - 8, y: y - 0.5, width: 16, height: 1).fill(); return
        }
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
        if mini {
            NSBezierPath(roundedRect: NSRect(x: x - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2), xRadius: radius - 1, yRadius: radius - 1).fill()
        } else {
            NSBezierPath(roundedRect: NSRect(x: x - 6, y: bounds.midY - 9, width: 12, height: 18), xRadius: 2, yRadius: 2).fill()
            NSColor.darkGray.setFill(); NSRect(x: x - 0.5, y: bounds.midY - 6, width: 1, height: 12).fill()
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            beginPointerEditing()
            doubleValue = min(maxValue, max(minValue, doubleValue + (event.keyCode == 124 ? 1 : -1) * (mini ? 0.05 : 0.5)))
            publishPointerValue(); finishPointerEditing()
        } else { super.keyDown(with: event) }
    }
    var changed: ((Double) -> Void)?
    var editingChanged: ((Bool, Double) -> Void)?
    private var pointerChanged: ((Double) -> Void)?
    private var pointerEditingChanged: ((Bool, Double) -> Void)?
    private(set) var trackingPointer = false
    private func beginPointerEditing() {
        guard !trackingPointer else { return }
        trackingPointer = true
        pointerChanged = changed
        pointerEditingChanged = editingChanged
        pointerEditingChanged?(true, doubleValue)
    }
    func finishPointerEditing(deferred: Bool = false) {
        guard trackingPointer else { return }
        // Capture the original target and actual pointer value before SwiftUI
        // dismantles or reuses the view. Never publish during its layout pass.
        let completion = pointerEditingChanged, value = doubleValue
        trackingPointer = false
        pointerChanged = nil; pointerEditingChanged = nil
        if deferred { DispatchQueue.main.async { completion?(false, value) } }
        else { completion?(false, value) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow !== window { finishPointerEditing(deferred: true) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { VolumeDoubleClickRouter.shared.add(self) }
    }
    func resetToUnity() {
        beginPointerEditing()
        doubleValue = 0
        publishPointerValue()
        finishPointerEditing()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            resetToUnity()
        } else {
            beginPointerEditing()
            rotaryOrigin = convert(event.locationInWindow, from: nil); rotaryValue = doubleValue
            move(to: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if trackingPointer { move(to: event) }
    }
    override func mouseUp(with event: NSEvent) {
        finishPointerEditing()
    }
    private func publishPointerValue() {
        pointerChanged?(doubleValue)
        VolumeDoubleClickRouter.shared.mirror(self)
    }
    private func move(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let knobWidth: CGFloat = mini ? 8 : 16
        let inset = knobWidth / 2
        if rotary {
            doubleValue = min(maxValue, max(minValue, rotaryValue + Double(rotaryOrigin.y - point.y + point.x - rotaryOrigin.x) * (maxValue - minValue) / 160))
            publishPointerValue(); return
        }
        let fraction = vertical
            ? min(1, max(0, 1 - (point.y - inset) / max(1, bounds.height - knobWidth)))
            : min(1, max(0, (point.x - inset) / max(1, bounds.width - knobWidth)))
        doubleValue = minValue + Double(fraction) * (maxValue - minValue)
        publishPointerValue()
        needsDisplay = true
    }
}
@MainActor private final class VolumeDoubleClickRouter {
    static let shared = VolumeDoubleClickRouter()
    private let sliders = NSHashTable<DirectVolumeSliderView>.weakObjects()
    private var monitor: Any?
    func mirror(_ source: DirectVolumeSliderView) {
        for target in sliders.allObjects where target !== source && target.window != nil &&
            target.boundProject == source.boundProject && target.mini == source.mini && !target.trackingPointer {
            let same = target.boundTrack == source.boundTrack
            let partner = source.linkedTrack != nil && target.boundTrack == source.linkedTrack && target.linkedTrack == source.boundTrack
            guard same || partner else { continue }
            target.mirroredSource = source
            target.doubleValue = partner && source.mini ? -source.doubleValue : source.doubleValue
            target.displayIfNeeded()
        }
    }

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
    let project: UUID
    let track: UUID
    let kind: TrackKind
    let select: () -> Void
    let patch: () -> Void
    let fx: () -> Void
    let edit: () -> Void
    let group: (() -> Void)?
    let ungroup: (() -> Void)?
    var link: (() -> Void)? = nil
    var unlink: (() -> Void)? = nil
    func makeNSView(context: Context) -> TrackRightClickView { TrackRightClickView() }
    func updateNSView(_ view: TrackRightClickView, context: Context) { view.interactionBlocked = interactionBlocked; view.project = project; view.track = track; view.kind = kind; view.select = select; view.patch = patch; view.fx = fx; view.edit = edit; view.group = group; view.ungroup = ungroup; view.link = link; view.unlink = unlink; view.action = { [weak view] in view?.openMenu() } }
}
/// Resolve one row per click, including after native scroll hosting recycles rows.
/// The title also calls this route directly, so selecting it never relies solely
/// on a passive event monitor. Both paths share the event to avoid double toggles.
struct TrackRecordSelectionExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackRecordSelectionExclusionView { TrackRecordSelectionExclusionView() }
    func updateNSView(_ view: TrackRecordSelectionExclusionView, context: Context) {}
}
final class TrackRecordSelectionExclusionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TrackSelectionRouter.shared.addRecordButton(self) }
    }
}
@MainActor final class TrackSelectionRouter {
    static let shared = TrackSelectionRouter()
    private let rows = NSHashTable<TrackRightClickView>.weakObjects()
    private let recordButtons = NSHashTable<NSView>.weakObjects()
    private var monitor: Any?
    private var lastEventTime: TimeInterval?
    private var pressedTrack: UUID?
    private var menuTracks = Set<UUID>()
    /// A reused row must retain the track that owns an in-flight button press.
    var pinnedTracks: Set<UUID> { menuTracks.union(pressedTrack.map { [$0] } ?? []) }
    private(set) var selectionModifiers: NSEvent.ModifierFlags?
    func addRecordButton(_ view: NSView) { recordButtons.add(view) }
    fileprivate func add(_ row: TrackRightClickView) {
        rows.add(row)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }
    func handle(_ event: NSEvent) {
        if event.type == .leftMouseUp { pressedTrack = nil; return }
        guard event.type == .leftMouseDown else { return }
        pressedTrack = nil
        guard !RightClickRouter.shared.handlesModifiedLeftClick(event) else { return }
        guard let window = event.window, window.attachedSheet == nil,
              !RightClickRouter.shared.interactionBlocked,
              !event.modifierFlags.contains(.control), ControlMappings.shared.editing == nil else { return }
        let matches = rows.allObjects.filter { row in
            let point = row.convert(event.locationInWindow, from: nil)
            return !row.interactionBlocked && row.window === window && !row.isHiddenOrHasHiddenAncestor &&
                row.bounds.contains(point) && row.visibleRect.contains(point)
        }
        guard let row = matches.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return }
        pressedTrack = row.track
        if recordButtons.allObjects.contains(where: { button in
            let point = button.convert(event.locationInWindow, from: nil)
            return button.window === window && !button.isHiddenOrHasHiddenAncestor &&
                button.bounds.contains(point) && button.visibleRect.contains(point)
        }) { return }
        guard row.kind == .standard else { return }
        // A recycled slot may target another row before this callback runs.
        // Preserve the click's original track/action and project generation.
        let track = row.track, project = row.project, select = row.select
        DispatchQueue.main.async { [weak self, weak row] in
            guard let self, let row, row.window === window, row.project == project else { return }
            self.perform(track: track, event: event) { select?() }
        }
    }
    func withPinnedTrack<T>(_ track: UUID, _ action: () -> T) -> T {
        let inserted = menuTracks.insert(track).inserted
        defer { if inserted { menuTracks.remove(track) } }
        return action()
    }
    func perform(track: UUID, event: NSEvent, action: () -> Void) {
        guard lastEventTime != event.timestamp else { return }
        lastEventTime = event.timestamp
        selectionModifiers = event.modifierFlags
        defer { selectionModifiers = nil }
        action()
    }
}
private final class TrackRightClickView: RightClickTargetView {
    var kind = TrackKind.standard
    var project = UUID()
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
    var link: (() -> Void)?
    var unlink: (() -> Void)?
    func makeMenu() -> (menu: NSMenu, actions: [TrackMenuAction]) {
        let menu = NSMenu()
        var actions: [TrackMenuAction] = []
        func append(_ title: String, _ action: (() -> Void)?) {
            guard let action else { return }
            let target = TrackMenuAction(action)
            actions.append(target)
            let item = NSMenuItem(title: title, action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
            item.target = target; menu.addItem(item)
        }
        if kind == .standard || kind == .timecode || kind == .video { append("Patch", patch) }
        if kind == .standard { append("FX", fx); append(JarasLocalization.string("Create group"), group) }
        append(JarasLocalization.string("Ungroup"), ungroup)
        append(JarasLocalization.string("Link tracks"), link)
        append(JarasLocalization.string("Unlink tracks"), unlink)
        append(JarasLocalization.string("Editar pista"), edit)
        return (menu, actions)
    }
    func openMenu() {
        guard let event = NSApp.currentEvent else { return }
        let snapshot = makeMenu()
        TrackSelectionRouter.shared.withPinnedTrack(track) {
            withExtendedLifetime(snapshot.actions) { NSMenu.popUpContextMenu(snapshot.menu, with: event, for: self) }
        }
    }
}
private final class TrackMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }

}

#endif

#if os(macOS)
private struct TrackDragTitle: NSViewRepresentable {
    let title: String
    let foreground: UInt32
    let project: UUID
    let track: UUID
    let state: TrackReorderState
    let select: () -> Void
    func makeNSView(context: Context) -> TrackDragTitleView { TrackDragTitleView() }
    func updateNSView(_ view: TrackDragTitleView, context: Context) {
        view.title = title; view.foreground = foreground; view.project = project; view.track = track; view.state = state; view.select = select
    }
}
private final class TrackDragSource: NSObject, NSDraggingSource {
    weak var state: TrackReorderState?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { state?.finish() }
}
private final class TrackDragTitleView: NSView {
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            cachedLabel = nil
            needsDisplay = true
        }
    }
    var foreground: UInt32 = 0xffffff {
        didSet {
            guard foreground != oldValue else { return }
            cachedLabel = nil
            needsDisplay = true
        }
    }
    var project = UUID() { didSet { if project != oldValue { down = nil } } }
    var track = UUID() { didSet { if track != oldValue { down = nil } } }
    weak var state: TrackReorderState?
    var select: (() -> Void)?
    private var down: NSPoint?
    private var cachedLabel: NSAttributedString?
    private static let labelAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph.copy() as! NSParagraphStyle]
    }()
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    private func label() -> NSAttributedString {
        if let cachedLabel { return cachedLabel }
        var attributes = Self.labelAttributes
        attributes[.foregroundColor] = foreground == 0 ? NSColor.black : NSColor.white
        let label = NSAttributedString(string: title, attributes: attributes)
        cachedLabel = label
        return label
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
        // The drag preview has its own native background rather than the
        // track's color, so retain its matching system label color.
        let text = NSAttributedString(string: title, attributes: Self.labelAttributes)
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

private struct LinkedTrackBorder: View {
    @State private var bright = false
    var body: some View {
        Rectangle().stroke(JarasTheme.yellow.opacity(bright ? 1 : 0.35), lineWidth: 2)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { bright = true } }
    }
}

private struct TrackMIDIIndicator: View {
    @ObservedObject var state: TrackMIDIActivity
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(Color.black.opacity(0.4))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(JarasTheme.green).frame(height: geometry.size.height * state.level)
                }
        }.allowsHitTesting(false).accessibilityLabel("MIDI activity")
    }
}

struct FooterMixerPanel: View {
    let show: ShowController
    let active: Bool
    let maximumHeight: CGFloat
    @AppStorage("jaras.footerMixerHeight") private var storedHeight = 232.0
    @State private var resizeStart: CGFloat?
    @State private var resizeHeight: CGFloat?
    @State private var hovering = false
    private var heightLimit: CGFloat { min(394, maximumHeight) }
    private var height: CGFloat { min(heightLimit, max(232, resizeHeight ?? storedHeight)) }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white.opacity(hovering ? 0.12 : 0.04)
                Capsule().fill(hovering ? JarasTheme.green : JarasTheme.secondary).frame(width: 48, height: 2)
            }.frame(height: 8).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                    if resizeStart == nil { resizeStart = height }
                    resizeHeight = min(heightLimit, max(232, (resizeStart ?? height) - value.translation.height))
                }.onEnded { _ in
                    if let resizeHeight { storedHeight = resizeHeight }
                    resizeHeight = nil; resizeStart = nil
                })
                .onHover { inside in
                    hovering = inside
                    #if os(macOS)
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    #endif
                }
                .jarasHelp("Drag to resize mixer")
            FooterHorizontalMixer(show: show, active: active).frame(maxHeight: .infinity)
        }.frame(height: height)
            .frame(height: active ? height : 0, alignment: .top).clipped()
            .allowsHitTesting(active).accessibilityHidden(!active)
    }
}

private enum FooterMixerMetrics {
    static let width: CGFloat = 124
    static let stride: CGFloat = width + 3
}

private struct FooterMixerRenderState: Equatable {
    let project: UUID
    let tracks: [Track]
    let masterFX: NativeFXSettings?
    let masterVolume: Double
    let masterMute: Bool
    let masterSolo: Bool
    let masterColor: UInt32?
    let selection: Set<UUID>
}
struct FooterHorizontalMixer: View {
    @ObservedObject var show: ShowController
    var active = true
    var body: some View {
        let project = show.snapshot.project
        let tracks = (show.current?.tracks ?? []).filter { $0.kind == .standard }.map { track in
            var presentation = track; presentation.clips = []; return presentation
        }
        FooterMixerContent(show: show, active: active, state: FooterMixerRenderState(project: project.id, tracks: tracks,
            masterFX: project.masterFX, masterVolume: project.masterVolume ?? 1,
            masterMute: project.masterMute == true, masterSolo: project.masterSolo == true, masterColor: project.masterColor, selection: show.mixerTrackSelection)).equatable()
    }
}
private struct FooterMixerContent: View, Equatable {
    let show: ShowController
    let active: Bool
    let state: FooterMixerRenderState
    @Environment(\.openFX) private var openFX
    @Environment(\.locale) private var locale
    @Environment(\.editTrackDetails) private var editTrackDetails
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.show === rhs.show && lhs.active == rhs.active && lhs.state == rhs.state }
    private var count: Int { state.tracks.count }
    private func strips(_ range: Range<Int>) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(Array(range), id: \.self) { index in
                    FooterMixerStrip(show: show, track: state.tracks[index], selection: state.selection, active: active).equatable()
                        .id(state.tracks[index].id)
                }
            }
        }.padding(5)
            .environment(\.openFX, openFX).environment(\.locale, locale).environment(\.editTrackDetails, editTrackDetails)
    }
    var body: some View {
        Group {
            #if os(macOS)
            FooterMixerScroll(contentWidth: CGFloat(count) * FooterMixerMetrics.stride + 7, stride: FooterMixerMetrics.stride, count: count, active: active) { range in AnyView(strips(range)) }
            #else
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(state.tracks) { FooterMixerStrip(show: show, track: $0, selection: state.selection, active: active) }
                }.padding(5)
            }.scrollIndicators(.visible)
            #endif
        }.background(JarasTheme.panel).overlay(alignment: .top) { Divider() }
    }
}

#if os(macOS)
private struct FooterMixerScroll: NSViewRepresentable {
    let contentWidth: CGFloat
    let stride: CGFloat
    let count: Int
    let active: Bool
    let makeContent: (Range<Int>) -> AnyView
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterMixerScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(1, nsView.frame.width), height: proposal.height ?? 242)
    }
    func makeNSView(context: Context) -> FooterMixerScrollView { FooterMixerScrollView() }
    func updateNSView(_ view: FooterMixerScrollView, context: Context) {
        view.isHidden = !active
        view.update(width: contentWidth, stride: stride, count: count, makeContent: makeContent)
    }
}
private final class FooterMixerGreenScroller: NSScroller {
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: slotRect.minX, y: bounds.midY - 3, width: slotRect.width, height: 6), xRadius: 3, yRadius: 3).fill()
    }
    override func drawKnob() {
        NSColor(calibratedRed: 84.0 / 255, green: 1, blue: 147.0 / 255, alpha: 1).setFill()
        let knob = rect(for: .knob)
        NSBezierPath(roundedRect: NSRect(x: knob.minX, y: bounds.midY - 3, width: knob.width, height: 6), xRadius: 3, yRadius: 3).fill()
    }
}
private final class FooterMixerDocumentView: NSView {
    override var isFlipped: Bool { true }
}
private final class FooterMixerHostingView: NSHostingView<AnyView> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}
private final class FooterMixerScrollView: NSView {
    private let scroll = NSScrollView()
    private let bar = FooterMixerGreenScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 14))
    private let host = FooterMixerDocumentView()
    private var strips: [Int: FooterMixerHostingView] = [:]
    private var contentWidth: CGFloat = 1
    private var makeContent: ((Range<Int>) -> AnyView)?
    private var preparedRange: Range<Int> = 0..<0
    private var trackCount = 1
    private var trackStride: CGFloat = 153
    private var preparing = false
    private var wheelMonitor: Any?
    private var coastTimer: Timer?
    private weak var coastTarget: NSScrollView?
    private var coastHorizontal = true
    private var coastRemaining: CGFloat = 0
    private var coastFrame = 0.0
    private var boundsObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 242) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        host.wantsLayer = true
        scroll.documentView = host; addSubview(scroll); addSubview(bar)
        bar.scrollerStyle = .legacy; bar.controlSize = .small; bar.target = self; bar.action = #selector(moveBar)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncBar() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        coastTimer?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
    func update(content: AnyView, width: CGFloat) {
        update(width: width, stride: width, count: 1, makeContent: { _ in content })
    }
    func update(width: CGFloat, stride: CGFloat, count: Int, makeContent: @escaping (Range<Int>) -> AnyView) {
        contentWidth = width; trackStride = stride; trackCount = count; self.makeContent = makeContent
        prepare(at: scroll.contentView.bounds.minX, force: true)
        needsLayout = true
    }
    private func prepare(at x: CGFloat, force: Bool = false) {
        guard !preparing, let makeContent else { return }
        let viewportWidth = max(1, scroll.contentSize.width, bounds.width)
        let first = max(0, min(trackCount - 1, Int(max(0, x) / trackStride)))
        let last = min(trackCount, Int(ceil((max(0, x) + viewportWidth) / trackStride)) + 1)
        if !force && preparedRange.lowerBound <= first && preparedRange.upperBound >= last { return }
        // Keep each channel's hosting tree stable. Scrolling must not diff and
        // relayout an entire screen of controls at every virtualization boundary.
        let margin = 2
        preparedRange = max(0, first - margin)..<min(trackCount, last + margin)
        preparing = true
        for index in Array(strips.keys) where !preparedRange.contains(index) {
            strips.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in preparedRange {
            let strip: FooterMixerHostingView
            if let cached = strips[index] {
                strip = cached
                if force { strip.rootView = makeContent(index..<(index + 1)) }
            } else {
                strip = FooterMixerHostingView(rootView: makeContent(index..<(index + 1)))
                strip.sizingOptions = []; strip.wantsLayer = true
                strips[index] = strip; host.addSubview(strip)
            }
            strip.frame = NSRect(x: CGFloat(index) * trackStride, y: 0,
                                 width: trackStride + 7, height: scroll.contentSize.height)
            strip.layoutSubtreeIfNeeded()
        }
        preparing = false
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 4, y: 1, width: max(0, bounds.width - 8), height: 14)
        scroll.frame = NSRect(x: 0, y: 16, width: bounds.width, height: max(0, bounds.height - 16))
        host.frame = NSRect(x: 0, y: 0, width: max(bounds.width, contentWidth), height: scroll.contentSize.height)
        for strip in strips.values { strip.frame.size.height = scroll.contentSize.height }
        move(to: scroll.contentView.bounds.minX)
    }
    private func syncBar() {
        let range = max(0, host.frame.width - scroll.contentSize.width)
        bar.isEnabled = range > 0
        bar.knobProportion = min(1, scroll.contentSize.width / max(1, host.frame.width))
        bar.doubleValue = range > 0 ? scroll.contentView.bounds.minX / range : 0
        prepare(at: scroll.contentView.bounds.minX)
    }

    private func move(to x: CGFloat) {
        let target = min(max(0, x), max(0, host.frame.width - scroll.contentSize.width))
        prepare(at: target)
        scroll.contentView.scroll(to: NSPoint(x: target, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView); syncBar()
    }
    @objc private func moveBar() {
        stopCoast()
        let range = max(0, host.frame.width - scroll.contentSize.width)
        switch bar.hitPart {
        case .decrementPage: move(to: scroll.contentView.bounds.minX - scroll.contentSize.width * 0.85)
        case .incrementPage: move(to: scroll.contentView.bounds.minX + scroll.contentSize.width * 0.85)
        case .decrementLine: move(to: scroll.contentView.bounds.minX - 40)
        case .incrementLine: move(to: scroll.contentView.bounds.minX + 40)
        default: move(to: bar.doubleValue * range)
        }
    }
    private func stopCoast() { coastTimer?.invalidate(); coastTimer = nil; coastRemaining = 0; coastTarget = nil }
    private func scrollBy(_ distance: CGFloat, target: NSScrollView, horizontal: Bool) {
        if horizontal { move(to: scroll.contentView.bounds.minX - distance); return }
        guard let document = target.documentView else { return }
        let clip = target.contentView
        let range = max(0, clip.documentRect.height - clip.bounds.height)
        let offset = clip.bounds.minY - clip.documentRect.minY
        let y = min(range, max(0, offset + (document.isFlipped ? -distance : distance))) + clip.documentRect.minY
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); target.reflectScrolledClipView(clip)
    }
    private func smoothWheel(_ distance: CGFloat, target: NSScrollView, horizontal: Bool) {
        if coastTarget !== target || coastHorizontal != horizontal || coastRemaining * distance < 0 { stopCoast() }
        coastTarget = target; coastHorizontal = horizontal
        // Respond immediately, then distribute the remaining part of this same
        // wheel step over frames. No extra travel is added after release.
        scrollBy(distance * 0.35, target: target, horizontal: horizontal)
        coastRemaining = min(180, max(-180, coastRemaining + distance * 0.65))
        guard coastTimer == nil else { return }
        coastFrame = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let target = self.coastTarget, self.window != nil, target.window === self.window,
                  self.window?.attachedSheet == nil, abs(self.coastRemaining) > 0.1 else { self?.stopCoast(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(0.05, max(0, now - self.coastFrame)); self.coastFrame = now
            let step = self.coastRemaining * (1 - exp(-elapsed / 0.055)); self.coastRemaining -= step
            self.scrollBy(step, target: target, horizontal: self.coastHorizontal)
        }
        coastTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        stopCoast()
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            let horizontal = event.modifierFlags.contains(.shift)
            if horizontal {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                if event.hasPreciseScrollingDeltas { self.stopCoast(); self.move(to: self.scroll.contentView.bounds.minX - delta) }
                else { self.smoothWheel(delta * 16, target: self.scroll, horizontal: true) }
                return nil
            }
            guard !event.hasPreciseScrollingDeltas, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { self.stopCoast(); return event }
            let local = self.convert(event.locationInWindow, from: nil)
            var view = self.hitTest(self.convert(local, to: self.superview))
            while let current = view, current !== self {
                if let target = current as? NSScrollView, target !== self.scroll {
                    self.smoothWheel(event.scrollingDeltaY * 16, target: target, horizontal: false); return nil
                }
                view = current.superview
            }
            return event
        }
    }

}
#endif

private struct FooterMixerStrip: View, Equatable {
    var masterState: FooterMixerRenderState? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.show === rhs.show && lhs.track == rhs.track && lhs.selection == rhs.selection && lhs.active == rhs.active && lhs.masterState == rhs.masterState
    }
    let show: ShowController
    let track: Track?
    let selection: Set<UUID>
    let active: Bool
    @Environment(\.editTrackDetails) private var editTrackDetails
    @State private var patchPresented = false
    @State private var fxPresented = false
    @State private var colorPresented = false
    private var selected: Bool { track?.kind == .standard && id.map { selection.contains($0) } == true }
    private var targets: [UUID?] {
        guard selected else { return [id] }
        return (show.current?.tracks ?? []).filter { selection.contains($0.id) && $0.kind == .standard }.map { Optional($0.id) }
    }
    private var canLink: Bool { selected && show.current?.linkableTracks(selection) != nil }
    private var isFolder: Bool { id.map { id in show.current?.tracks.contains(where: { $0.parentTrackID == id }) == true } == true }
    private var canGroup: Bool { selected && selection.count > 1 && show.current?.tracks.contains(where: { selection.contains($0.id) && $0.stereoLink != nil }) != true }
    private func select() {
        guard let track, track.kind == .standard, let song = show.current else { return }
        var ids = selection
        #if os(macOS)
        let flags = TrackSelectionRouter.shared.selectionModifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = show.selectedTrackForActions,
           let start = song.tracks.firstIndex(where: { $0.id == anchor }), let end = song.tracks.firstIndex(where: { $0.id == track.id }) {
            ids = Set(song.tracks[min(start, end)...max(start, end)].filter { $0.kind == .standard }.map(\.id))
            show.setMixerTrackSelection(ids, anchor: anchor); return
        }
        if flags.contains(.command) || flags.contains(.control) {
            if ids.contains(track.id) { ids.remove(track.id) } else { ids.insert(track.id) }
        } else { ids = [track.id] }
        #else
        ids = [track.id]
        #endif
        show.setMixerTrackSelection(ids, anchor: track.id)
    }
    private func edit() {
        guard let track else { colorPresented = true; return }
        let ids = Set(targets.compactMap { $0 })
        editTrackDetails(TrackDetailsEditRequest(project: show.snapshot.project.id, tracks: ids,
            name: track.name, color: track.color ?? JarasTheme.roleHex(track.role), nameEditable: ids.count == 1 && track.kind == .standard))
    }
    private func link() {
        guard let song = show.current, let indices = song.linkableTracks(selection) else { return }
        let top = song.tracks[indices[0]]
        show.linkTracks(selection, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel, color: top.color ?? JarasTheme.roleHex(top.role))
    }
    @Environment(\.openFX) private var openFX
    private var id: UUID? { track?.id }
    private var settings: NativeFXSettings { track?.fx ?? masterState?.masterFX ?? NativeFXSettings() }
    private var color: Color { Color(hex: track.map { $0.color ?? JarasTheme.roleHex($0.role) } ?? show.snapshot.project.masterColor ?? 0xffdc52) }
    private var buttons: some View {
        VStack(spacing: 5) {
            Button("FX") { openFX(id, "Chain") }
                .foregroundStyle(settings.inserted.isEmpty ? JarasTheme.text : JarasTheme.green).jarasHelp("FX Manager")
            Button("M") { show.send(.mute, target: id) }
                .buttonStyle(CompactTrackButtonStyle(activeColor: (track?.mute ?? (show.snapshot.project.masterMute == true)) ? .red : nil))
                .modifier(MappingRightClick(track: id, command: "mute")).jarasHelp("Mute")
            Button("S") { show.send(.solo, target: id) }
                .buttonStyle(CompactTrackButtonStyle(activeColor: (track?.solo ?? (show.snapshot.project.masterSolo == true)) ? JarasTheme.yellow : nil))
                .modifier(MappingRightClick(track: id, command: "solo")).jarasHelp("Solo")
            if let track, track.kind == .standard { TrackRecordButton(show: show, track: track) }
            Spacer(minLength: 0)
        }.frame(width: 22).buttonStyle(CompactTrackButtonStyle()).font(.system(size: 10, weight: .bold))
    }
    private var slots: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                ForEach(settings.effectKeys, id: \.self) { effect in
                    FooterEffectSlot(show: show, track: id, effect: effect, settings: settings)
                }
                ForEach(0..<max(1, 3 - settings.effectKeys.count), id: \.self) { _ in
                    FooterEffectSlot(show: show, track: id, effect: nil, settings: settings)
                }
            }
        }
    }
    private var panAndFader: some View {
        VStack(spacing: 1) {
            if let track {
                Text("Pan").font(.system(size: 8, weight: .medium)).foregroundStyle(JarasTheme.secondary)
                FooterMixerControl(show: show, track: track.id, value: track.pan, pan: true, linked: track.stereoLink?.partner)
                    .frame(width: 24, height: 24).jarasHelp("Pan · Double-click to center")
                    .overlay(alignment: .leading) {
                        TrackPeakReadout(peak: StemAudioPlayback.shared.meter(for: track.id).peakHold).offset(x: 28)
                    }
            } else { Color.clear.frame(height: 35) }
            HStack(spacing: 2) {
                FooterMixerControl(show: show, track: id, value: track?.volume ?? show.snapshot.project.masterVolume ?? 1, pan: false, linked: track?.stereoLink?.partner)
                    .frame(width: 27).jarasHelp("Double-click to reset to 0 dB")
                if active {
                    VerticalTrackMeter(meter: id.map { StemAudioPlayback.shared.meter(for: $0) } ?? StemAudioPlayback.shared.masterMeter, showScale: false).frame(width: 8)
                } else { Color.clear.frame(width: 8) }
                if active, let track, track.kind == .standard {
                    TrackMIDIIndicator(state: InstrumentKeyboardState.shared.activity(track.id)).frame(width: 3).padding(.vertical, 4)
                }
            }
        }.frame(width: 42)
    }
    var body: some View {
        GeometryReader { geometry in
            let innerHeight = max(0, geometry.size.height - 8)
            // 255 pt panel height is the user-selected threshold for FX slots.
            let controlsHeight = min(187, max(100, innerHeight - 26))
            let slotsHeight = max(0, innerHeight - controlsHeight - 26)
            VStack(spacing: 0) {
                slots.frame(height: slotsHeight).clipped().opacity(slotsHeight > 0 ? 1 : 0).allowsHitTesting(slotsHeight > 0)
                ZStack(alignment: .topLeading) {
                    panAndFader.frame(maxWidth: .infinity, maxHeight: .infinity)
                    buttons
                }.frame(height: controlsHeight)
                Text(verbatim: track?.name ?? "Master").font(.system(size: 10, weight: .semibold))
                    .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(height: 22).padding(.top, 4)
                    .foregroundStyle(.white).help(Text(verbatim: track?.name ?? "Master"))
            }.padding(4)
        }.frame(width: FooterMixerMetrics.width).frame(maxHeight: .infinity)
            .background(color.opacity(selected ? 0.58 : 0.24)).overlay(alignment: .top) { color.frame(height: 3) }
            .overlay { if selected { Rectangle().stroke(Color.white, lineWidth: 1).allowsHitTesting(false) } }
            .overlay { if active, track?.stereoLink != nil { LinkedTrackBorder().allowsHitTesting(false) } }
            #if os(macOS)
            .overlay {
                if let track {
                    TrackRightClickInput(project: show.snapshot.project.id, track: track.id, kind: track.kind, select: select,
                        patch: { patchPresented = true }, fx: { fxPresented = true }, edit: edit,
                        group: canGroup ? { show.groupTracks(selection) } : nil,
                        ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil,
                        link: canLink ? link : nil, unlink: track.stereoLink != nil ? { show.unlinkTracks(track.id) } : nil)
                }
            }
            #else
            .onTapGesture(perform: select)
            #endif
            .contextMenu {
                Button("Patch") { patchPresented = true }
                Button("FX") { fxPresented = true }
                Button("Editar pista", action: edit)
                if canGroup { Button("Create group") { show.groupTracks(selection) } }
                if let id, isFolder { Button("Ungroup") { show.ungroupTrack(id) } }
                if canLink { Button("Link tracks", action: link) }
                if let track, track.stereoLink != nil { Button("Unlink tracks") { show.unlinkTracks(track.id) } }
            }
            .sheet(isPresented: $patchPresented) {
                VStack { PatchEditor(show: show, track: id, targets: targets); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .sheet(isPresented: $fxPresented) {
                FXInsertEditor(show: show, track: id, targets: targets) { fxPresented = false }
            }
            .sheet(isPresented: $colorPresented) {
                NameColorEditor(title: "Editar pista", initialName: "Master", initialColor: show.snapshot.project.masterColor ?? 0xffdc52,
                    save: { _, color in show.editMasterColor(color) }, nameEditable: false, showsName: false)
            }
    }
}

private struct FooterEffectSlot: View {
    let show: ShowController
    let track: UUID?
    let effect: String?
    let settings: NativeFXSettings
    @Environment(\.openFX) private var openFX
    @State private var targeted = false
    private var scope: String { show.snapshot.project.id.uuidString + "|" + (track?.uuidString ?? "master") + "|" }
    private var title: String {
        guard let effect else { return "" }
        if settings.kind(of: effect) == "Instruments" { return InstrumentLibrary.displayName(settings.settings(for: effect).instrumentID) }
        return settings.externalPlugins?.first(where: { $0.effectKey == effect })?.name ?? settings.kind(of: effect)
    }
    var body: some View {
        Group {
            if let effect {
                Button { openFX(track, effect) } label: {
                    Text(verbatim: title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                    .foregroundStyle(Color.white)
                    .onDrag { NSItemProvider(object: (scope + effect) as NSString) }
                    #if os(macOS)
                    .overlay(FooterEffectContext(bypass: { show.toggleFXBypass(track, effect: effect) }, remove: { show.removeFX(track, effect: effect) }))
                    #else
                    .contextMenu {
                        Button("By") { show.toggleFXBypass(track, effect: effect) }
                        Button("Remove") { show.removeFX(track, effect: effect) }
                    }
                    #endif
            } else {
                Button { openFX(track, "Chain") } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("FX Manager")
            }
        }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).frame(height: 19)
            .background(effect.map { settings.isEnabled($0) ? Color.black.opacity(0.28) : Color.red.opacity(0.8) } ?? Color.black.opacity(0.28))
            .overlay(alignment: .top) { if targeted { JarasTheme.green.frame(height: 2) } }
            .contentShape(Rectangle())
            .jarasHelp(effect == nil ? "Click to open FX Manager" : "Click: open this plugin in FX Manager. Option/Alt + click: remove plugin. Shift + click: toggle bypass (red slot).")
            .onDrop(of: [UTType.text], isTargeted: $targeted) { providers in
                guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                let prefix = scope, project = show.snapshot.project.id
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, text.hasPrefix(prefix) else { return }
                    let source = String(text.dropFirst(prefix.count))
                    Task { @MainActor in
                        guard show.snapshot.project.id == project else { return }
                        show.reorderFX(track, effect: source, before: effect)
                    }
                }
                return true
            }
    }
}

private struct FooterMixerControl: View {
    let show: ShowController
    let track: UUID?
    let value: Double
    let pan: Bool
    let linked: UUID?
    private var position: Double { pan ? value : (value <= 0 ? -60 : min(12, max(-60, 20 * log10(value)))) }
    private func gain(_ value: Double) -> Double { value <= -60 ? 0 : pow(10, value / 20) }
    var body: some View {
        #if os(macOS)
        let identity = TrackControlIdentity(project: show.snapshot.project.id, track: track)
        DirectVolumeSlider(identity: identity, value: position, minimum: pan ? -1 : -60, maximum: pan ? 1 : 12,
            mini: pan, vertical: !pan, rotary: pan, linkedTrack: linked,
            changed: { newValue in
                guard show.snapshot.project.id == identity.project else { return }
                if pan, let track { show.previewTrackPan(track, pan: newValue) }
                else { show.previewTrackVolume(track, gain: gain(newValue)) }
            }, editingChanged: { editing, newValue in
                guard !editing, show.snapshot.project.id == identity.project else { return }
                show.send(pan ? .pan : .volume, target: track, value: pan ? newValue : gain(newValue))
            })
            .modifier(MappingRightClick(track: track, command: pan ? "pan" : "volume"))
            .accessibilityLabel(pan ? "Pan" : "Track volume")
        #else
        GeometryReader { geometry in
            let fraction = (position - (pan ? -1 : -60)) / (pan ? 2 : 72)
            ZStack {
                Capsule().fill(.white.opacity(0.2)).frame(width: 5)
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 24, height: 10)
                    .position(x: geometry.size.width / 2, y: (1 - fraction) * max(1, geometry.size.height - 10) + 5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let fraction = min(1, max(0, 1 - event.location.y / max(1, geometry.size.height)))
                    let next = (pan ? -1.0 : -60.0) + fraction * (pan ? 2 : 72)
                    show.send(pan ? .pan : .volume, target: track, value: pan ? next : gain(next))
                })
                .onTapGesture(count: 2) { show.send(pan ? .pan : .volume, target: track, value: pan ? 0 : 1) }
        }
        #endif
    }
}

#if os(macOS)
private struct FooterEffectContext: NSViewRepresentable {
    let bypass: () -> Void
    let remove: () -> Void
    func makeNSView(context: Context) -> FooterEffectContextView { FooterEffectContextView() }
    func updateNSView(_ view: FooterEffectContextView, context: Context) {
        view.bypass = bypass; view.remove = remove
        view.optionClick = remove; view.shiftClick = bypass; view.action = { [weak view] in view?.openMenu() }
    }
}
private final class FooterEffectContextView: RightClickTargetView {
    override var priority: Int { 2 }
    var bypass: (() -> Void)?
    var remove: (() -> Void)?
    func openMenu() {
        guard let event = NSApp.currentEvent else { return }
        if event.modifierFlags.contains(.option) { remove?(); return }
        let menu = NSMenu()
        let actions = [TrackMenuAction { [weak self] in self?.bypass?() }, TrackMenuAction { [weak self] in self?.remove?() }]
        for (index, title) in ["By", JarasLocalization.string("Remove")].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
            item.target = actions[index]; menu.addItem(item)
        }
        withExtendedLifetime(actions) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
#endif
