import SwiftUI
import UniformTypeIdentifiers
import Combine
enum SidebarWidthLimits {
    static let trackMixer: CGFloat = 230
    static let setlist: CGFloat = 277
}
struct MainView: View {
    @ObservedObject private var recording = TrackRecording.shared
    @ObservedObject private var mappings = ControlMappings.shared
    let show: ShowController
    @ObservedObject var auth: AuthService
    let backend: MockBackendClient
    @ObservedObject var documents: ProjectDocuments
    private enum Panel: String, Identifiable { case projects, settings; var id: String { rawValue } }
    @State private var panel: Panel?
    @State private var trackEdit: TrackDetailsEditRequest?
    private struct FXTarget: Identifiable { let track: UUID?; let effect: String; var id: String { (track.map { "track:" + $0.uuidString } ?? "master") + effect } }
    @State private var fxTargets: [FXTarget] = []
    @State private var clipFXTargets: [UUID] = []
    @State private var textItemTarget: UUID?
    @State private var lastObservedProjectID: UUID?
    @AppStorage("jaras.language") private var language = "en"
    @State private var navigationOpen = false
    @State private var footerMixerOpen = false
    @State private var keyboardOpen = false
    @State private var keyboardSettings = false
    @State private var workspaceHeight: CGFloat = 900
    @AppStorage("jaras.trackColumnWidth") private var mixerWidth = Double(SidebarWidthLimits.trackMixer)
    @AppStorage("jaras.trackColumnRestoreWidth") private var mixerRestoreWidth = 248.0
    #if os(macOS)
    @State private var setlistScrollController = SidebarScrollController()
    #endif
    @AppStorage("jaras.setlistWidth") private var setlistWidth = Double(SidebarWidthLimits.setlist)
    @AppStorage("jaras.setlistRestoreWidth") private var setlistRestoreWidth = 240.0
    private func toggleMixer() {
        Self.togglePanel(width: $mixerWidth, restore: $mixerRestoreWidth, minimum: SidebarWidthLimits.trackMixer)
    }
    private func toggleSetlist() {
        Self.togglePanel(width: $setlistWidth, restore: $setlistRestoreWidth, minimum: SidebarWidthLimits.setlist)
    }
    private static func togglePanel(width: Binding<Double>, restore: Binding<Double>, minimum: CGFloat) {
        if width.wrappedValue > 0 { restore.wrappedValue = width.wrappedValue; width.wrappedValue = 0 }
        else { width.wrappedValue = max(Double(minimum), restore.wrappedValue) }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TransportView(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), toggleNavigation: { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } }, openSettings: { navigationOpen = false; panel = .settings }, mixerCollapsed: mixerWidth <= 0, setlistCollapsed: setlistWidth <= 0, toggleMixer: toggleMixer, toggleSetlist: toggleSetlist)
                    #if os(macOS)
                    GeometryReader { geometry in
                        NativeWorkspaceSplit(width: CGFloat(setlistWidth), restoreWidth: CGFloat(setlistRestoreWidth),
                            minimum: SidebarWidthLimits.setlist, scrollController: setlistScrollController,
                            onToggle: toggleSetlist, onEnd: { finalWidth in
                                if finalWidth > 0 { setlistRestoreWidth = finalWidth }
                                setlistWidth = finalWidth
                            }) {
                            TimelineGridView(show: show, documents: documents, toggleMixer: toggleMixer)
                                .foregroundStyle(JarasTheme.text)
                        } trailing: {
                            SongListView(show: show, sidebarScrollController: setlistScrollController)
                                .foregroundStyle(JarasTheme.text)
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #else
                    HStack(spacing: 1) {
                        TimelineGridView(show: show, documents: documents, toggleMixer: toggleMixer)
                        SongListView(show: show).frame(width: 220)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #endif
                FooterMixerPanel(show: show, active: footerMixerOpen, maximumHeight: max(180, workspaceHeight - 240 - (keyboardOpen ? 108 : 0)))
                FooterPianoKeyboard(active: keyboardOpen).frame(height: 108)
                    .frame(height: keyboardOpen ? 108 : 0, alignment: .top).clipped().allowsHitTesting(keyboardOpen).accessibilityHidden(!keyboardOpen)
                GeometryReader { geometry in
                    let displayWidth = min(300, max(0, geometry.size.width - 320))
                    let sideWidth = max(0, (geometry.size.width - displayWidth) / 2)
                    HStack(spacing: 0) {
                        HStack(spacing: 10) {
                            ResourceUsageView().fixedSize()
                            Button { footerMixerOpen.toggle() } label: { Image(systemName: "slider.vertical.3").font(.system(size: 16, weight: .semibold)).frame(width: 32, height: 25).contentShape(Rectangle()) }
                                .foregroundStyle(footerMixerOpen ? JarasTheme.green : JarasTheme.text).jarasHelp("Barra Mixer").accessibilityLabel("Barra Mixer")
                            Button { keyboardOpen.toggle() } label: { Image(systemName: "pianokeys").font(.system(size: 16, weight: .semibold)).frame(width: 32, height: 25).contentShape(Rectangle()) }
                                .foregroundStyle(keyboardOpen ? JarasTheme.green : JarasTheme.text).jarasHelp("Keyboard").accessibilityLabel("Keyboard")
                                .immediateRightClick { keyboardSettings = true }
                                .sheet(isPresented: $keyboardSettings) { KeyboardSettingsView() }
                        }.buttonStyle(.plain).frame(width: sideWidth, alignment: .leading).clipped()
                        FooterInformationDisplay(show: show, status: documents.importingAudio ? documents.status : "").frame(width: displayWidth)
                        AudioStatusView().frame(width: sideWidth, alignment: .trailing)
                    }.frame(height: 27)
                }.font(.system(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).frame(height: 27).background(JarasTheme.panel)

            }
        }.background(JarasTheme.background).foregroundStyle(JarasTheme.text).scrollIndicators(.hidden)
            .background { GeometryReader { geometry in Color.clear.preference(key: MixerWorkspaceHeightKey.self, value: geometry.size.height) } }
            .onPreferenceChange(MixerWorkspaceHeightKey.self) { workspaceHeight = $0 }
            .overlay(alignment: .top) {
                if documents.importingAudio {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(LocalizedStringKey(documents.status)).font(.caption).lineLimit(1) }
                        .padding(10).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.top, 88)
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $documents.pendingAudioDrop) { drop in
                AudioDropOptions { layout, gap in
                    documents.pendingAudioDrop = nil
                    guard show.snapshot.project.id == drop.project else { return }
                    _ = documents.importAudio(drop.providers, start: drop.start, track: drop.track, song: drop.song, layout: layout, gap: gap)
                }
            }
            .alert(Text(verbatim: documents.audioImportError.isEmpty ? "" : JarasLocalization.string("Import audio")), isPresented: Binding(get: { !documents.audioImportError.isEmpty }, set: { if !$0 { documents.audioImportError = "" } })) {
                Button("OK") { documents.audioImportError = "" }
            } message: { Text(LocalizedStringKey(documents.audioImportError)) }

            .environment(\.openFX, { track, effect in
                #if os(macOS)
                FXWindows.shared.open(show: show, track: track, effect: effect, language: language)
                #else
                let target = FXTarget(track: track, effect: effect)
                if !fxTargets.contains(where: { $0.id == target.id }) { fxTargets.append(target) }
                #endif
            })
            .environment(\.openClipFXChain, { clip in
                #if os(macOS)
                FXWindows.shared.openClipChain(show: show, clip: clip)
                #else
                if !clipFXTargets.contains(clip) { clipFXTargets.append(clip) }
                #endif
            })
            .onReceive(show.$snapshot.map { $0.project.id }.removeDuplicates()) { projectID in
                // A recreated publisher immediately emits its current ID. Only
                // a different project dismisses an existing editing panel.
                if let lastObservedProjectID, lastObservedProjectID != projectID {
                    clipFXTargets = []; fxTargets = []; textItemTarget = nil; trackEdit = nil
                }
                if lastObservedProjectID != projectID { lastObservedProjectID = projectID }
            }
            .environment(\.editTextItem, { textItemTarget = $0 })
            #if os(macOS)
            .background(NativeTimelineModalGate(blocked: navigationOpen || textItemTarget != nil || trackEdit != nil || mappings.editing != nil))
            #else
            .environment(\.gridInteractionBlocked, navigationOpen || textItemTarget != nil || trackEdit != nil || mappings.editing != nil)
            #endif
            .environment(\.editTrackDetails, { request in
                guard request.project == show.snapshot.project.id, !request.tracks.isEmpty else { return }
                trackEdit = request
            })
            .onChange(of: show.snapshot.project.id) { _ in trackEdit = nil }
            .overlay {
                if let edit = trackEdit {
                    ZStack {
                        Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { trackEdit = nil }
                        NameColorEditor(title: "Editar pista", initialName: edit.name, initialColor: edit.color, save: { name, color in
                            guard edit.project == show.snapshot.project.id else { return }
                            if edit.nameEditable, let track = edit.tracks.first {
                                show.editTrack(track, name: name, color: color)
                            } else {
                                show.editTrackColors(edit.tracks, color: color, project: edit.project)
                            }
                        }, close: { trackEdit = nil }, nameEditable: edit.nameEditable, showsName: edit.nameEditable)
                        .background(JarasTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.4), radius: 18)
                        .id(edit.id)
                    }
                }
            }
            .overlay {
                #if !os(macOS)
                ForEach(fxTargets) { target in
                    MovableFXPanel {
                        FXEditor(show: show, track: target.track, effect: target.effect, close: { fxTargets.removeAll { $0.id == target.id } })
                    }
                }
                ForEach(clipFXTargets, id: \.self) { clip in
                    MovableFXPanel {
                        TabbedClipFXEditor(show: show, clip: clip, close: { clipFXTargets.removeAll { $0 == clip } })
                    }
                }
                #endif
            }
            .onAppear {
                mappings.bind(show)
                show.toggleTracksPanel = { [width = $mixerWidth, restore = $mixerRestoreWidth] in
                    Self.togglePanel(width: width, restore: restore, minimum: SidebarWidthLimits.trackMixer)
                }
                show.toggleSetlistPanel = { [width = $setlistWidth, restore = $setlistRestoreWidth] in
                    Self.togglePanel(width: width, restore: restore, minimum: SidebarWidthLimits.setlist)
                }
            }
            .onChange(of: textItemTarget != nil || trackEdit != nil || mappings.editing != nil) { blocked in
                #if os(macOS)
                RightClickRouter.shared.interactionBlocked = blocked
                #endif
            }
            .onDisappear {
                show.toggleTracksPanel = {}; show.toggleSetlistPanel = {}
                #if os(macOS)
                FXWindows.shared.closeAll()
                RightClickRouter.shared.interactionBlocked = false
                #endif
            }
            .alert(Text(verbatim: recording.error.isEmpty ? "" : JarasLocalization.string("Recording")), isPresented: Binding(get: { !recording.error.isEmpty }, set: { if !$0 { recording.error = "" } })) { Button("OK") { recording.error = "" } } message: { Text(LocalizedStringKey(recording.error)) }
            .overlay {
                if mappings.editing != nil && mappings.editing?.fxParameter == nil && panel == nil {
                    ZStack { Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { mappings.editing = nil }; ControlMappingEditor() }
                }
            }
            .overlay {
                if let id = textItemTarget,
                   let track = show.current?.tracks.first(where: { $0.kind.isText && $0.clips.contains { $0.id == id } }),
                   let item = track.clips.first(where: { $0.id == id }) {
                    ZStack {
                        Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { textItemTarget = nil }
                        TextItemEditor(text: item.text ?? "", maximumLength: track.kind.maximumTextLength ?? AudioClip.maximumTextLength, apply: { show.updateTextItem(id, text: $0) }, close: { textItemTarget = nil })
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.4), radius: 18)
                            .id(id)
                    }
                }
            }
            .sheet(item: $panel) { selected in
                VStack(spacing: 0) {
                    HStack {
                        Text(LocalizedStringKey(selected == .settings ? "Configurações" : "Projetos")).font(.headline)
                        Spacer()
                        Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Fechar").keyboardShortcut(.cancelAction)
                    }.padding(16)
                    Divider()
                    if selected == .settings {
                        SettingsView(auth: auth, show: show, backend: backend)
                    } else {
                        ProjectBrowserView(documents: documents, completed: { panel = nil })
                    }
                }
                .frame(width: selected == .settings ? 660 : documents.folderReview == nil ? 560 : 840, height: selected == .settings ? 540 : 500)
                .background(JarasTheme.background).foregroundStyle(JarasTheme.text)
                .environment(\.locale, Locale(identifier: language))
            }
    }
    private var navigationLayer: some View {
        Group {
            if navigationOpen {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.16).contentShape(Rectangle())
                        .onTapGesture { navigationOpen = false }
                    SidebarView(close: { navigationOpen = false }, openProjects: { panel = .projects })
                        .frame(width: 210).frame(maxHeight: .infinity)
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 4)
                }
            }
        }
    }
}
struct MainPreview: PreviewProvider { static var previews: some View { let container = try! AppContainer(preview: true); MainView(show: container.show, auth: container.auth, backend: container.backend, documents: container.documents).frame(width: 1360, height: 800) } }

#if os(macOS)
import AppKit

/// Hover redraws only the divider, without publishing changes to the timeline.
class ResizeHoverIndicatorView: NSView {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor(calibratedRed: 0.22, green: 1, blue: 0.55, alpha: 1).setFill()
        NSRect(x: bounds.midX - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
    }
}
#endif

private struct AudioStatusView: View {
    @ObservedObject private var audio = AudioDeviceSettings.shared
    var body: some View {
        Text("\(audio.deviceName) · \(audio.bufferFrames) · \(Int(audio.sampleRate)) Hz")
            .lineLimit(1).truncationMode(.middle).foregroundStyle(JarasTheme.secondary)
            .frame(maxWidth: 370, alignment: .trailing)
    }
}

private struct AudioDropOptions: View {
    let apply: (AudioDropLayout, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var layout = AudioDropLayout.separateTracks
    @State private var gap = 0.0
    @State private var gapDraft = "0"
    @State private var invalidGap = false
    @State private var gapShake = 0.0
    @FocusState private var gapFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import audio").font(.headline)
            Picker("Placement", selection: $layout) {
                Text("One track per item").tag(AudioDropLayout.separateTracks)
                Text("All items on the same track").tag(AudioDropLayout.sameTrack)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #endif
            if layout == .sameTrack {
                HStack {
                    Text("Interval between items")
                    Spacer()
                    TextField("Seconds", text: $gapDraft).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 64).focused($gapFocused)
                        .accessibilityLabel("Interval seconds")
                        .onSubmit { _ = validateGap() }
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalidGap ? Color.red : .clear, lineWidth: 1.5))
                        .modifier(InputValidationShake(animatableData: gapShake))
                    Text("s").foregroundStyle(JarasTheme.secondary)
                }
                Slider(value: gapBinding, in: 0...60, step: 1)
                Stepper("\(Int(gap)) s", value: gapBinding, in: 0...60, step: 1)
            }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import") { if layout != .sameTrack || validateGap() { apply(layout, gap) } }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360).background(JarasTheme.panel)
    }
    private var gapBinding: Binding<Double> {
        Binding(get: { gap }, set: { gap = $0; gapDraft = String(format: "%g", $0); invalidGap = false })
    }
    @discardableResult private func validateGap() -> Bool {
        let value = Double(gapDraft.replacingOccurrences(of: ",", with: "."))
        let valid = value?.isFinite == true
        let limited = valid ? min(60, max(0, value!)) : gap
        gap = limited; gapDraft = String(format: "%g", limited)
        invalidGap = !valid || value != limited
        if invalidGap {
            gapFocused = true
            withAnimation(.linear(duration: 0.35)) { gapShake += 1 }
        }
        return !invalidGap
    }

}

/// Reuses the per-song pitch state and target editor in the transport.
struct RegionTunerControl: View {
    @ObservedObject var show: ShowController
    @State private var editing: Part?
    private func step(_ delta: Int) {
        guard let song = show.current, let region = show.pitchRegion else { return }
        let targets = song.pitchTargets(region)
        show.setRegionPitch(region.id, semitones: min(6, max(-6, region.semitones + delta)), tracks: targets.tracks, groups: targets.groups)
    }
    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "Tuner").font(.system(size: 9, weight: .semibold)).foregroundStyle(JarasTheme.text)
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 20, height: 25).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) <= -6).jarasHelp("Lower song pitch")
            Text(String(format: "%dst", show.pitchRegion?.semitones ?? 0))
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .frame(width: 34, height: 23).background(JarasTheme.display).cornerRadius(4)
                .immediateRightClick { editing = show.pitchRegion }
                .accessibilityLabel("Song pitch").accessibilityValue(String(show.pitchRegion?.semitones ?? 0) + "st")
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 20, height: 25).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) >= 6).jarasHelp("Raise song pitch")
        }.buttonStyle(.plain).foregroundStyle(JarasTheme.green)
        .padding(.horizontal, 6).frame(height: 25)
        .background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false))
        .sheet(item: $editing) { region in
            if let song = show.current {
                RegionPitchTargets(show: show, song: song, region: region, close: { editing = nil })
            }
        }
    }
}
private struct RegionPitchTargets: View {
    let show: ShowController
    let song: Song
    let region: Part
    let close: () -> Void
    @State private var tab = 0
    @State private var tracks: Set<UUID>
    @State private var groups: Set<UUID>
    init(show: ShowController, song: Song, region: Part, close: @escaping () -> Void) {
        self.show = show; self.song = song; self.region = region; self.close = close
        let selection = song.pitchTargets(region)
        _tracks = State(initialValue: selection.tracks); _groups = State(initialValue: selection.groups)
    }
    private var visibleTracks: [Track] { tab == 0 ? song.pitchTracks : song.pitchGroups }
    private var allSelected: Bool { !visibleTracks.isEmpty && visibleTracks.allSatisfy(isSelected) }
    private func isSelected(_ track: Track) -> Bool {
        if tab == 0 { return tracks.contains(track.id) || track.parentTrackID.map(groups.contains) == true }
        let members = song.tracks.filter { $0.parentTrackID == track.id }
        return groups.contains(track.id) || (!members.isEmpty && members.allSatisfy { tracks.contains($0.id) })
    }
    private func setSelected(_ track: Track, _ selected: Bool) {
        if tab == 0 {
            // Deselecting one child keeps its siblings selected.
            if !selected, let parent = track.parentTrackID, groups.remove(parent) != nil {
                tracks.insert(parent)
                tracks.formUnion(song.tracks.filter { $0.parentTrackID == parent && $0.id != track.id }.map(\.id))
            }
            if selected { tracks.insert(track.id) } else { tracks.remove(track.id) }
        } else {
            tracks.subtract(song.tracks.filter { $0.parentTrackID == track.id || $0.id == track.id }.map(\.id))
            if selected { groups.insert(track.id) } else { groups.remove(track.id) }
        }
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text("Pitch · " + region.displayName).font(.headline).lineLimit(1); Spacer(); Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain) }
            Picker("", selection: $tab) { Text("Tracks").tag(0); Text("Groups").tag(1) }.pickerStyle(.segmented).labelsHidden()
            HStack {
                Spacer()
                Button(allSelected ? "Deselect all" : "Select all") {
                    let selected = !allSelected
                    for track in visibleTracks { setSelected(track, selected) }
                }.disabled(visibleTracks.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleTracks) { track in
                        Toggle(track.name, isOn: Binding(get: { isSelected(track) }, set: { setSelected(track, $0) }))
                            .toggleStyle(.automatic).tint(JarasTheme.green)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: 245).scrollIndicators(.hidden)
            HStack { Spacer(); Button("Cancel", action: close).keyboardShortcut(.cancelAction); Button("Apply") {
                let current = show.current?.parts.first { $0.id == region.id } ?? region
                show.setRegionPitch(region.id, semitones: current.semitones, tracks: tracks, groups: groups); close()
            }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 410).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}

private struct FooterPianoKeyboard: View {
    var active = true
    @ObservedObject private var state = KeyboardMIDIMonitor.shared
    @AppStorage("jaras.keyboard.whiteColor") private var whiteColor = 0x54ff93
    @AppStorage("jaras.keyboard.blackColor") private var blackColor = 0x54ff93
    @State private var pressed: UInt8?
    private let whiteNotes = (21...108).filter { ![1,3,6,8,10].contains($0 % 12) }
    private func keyRect(_ note: Int, size: CGSize) -> CGRect {
        let width = size.width / CGFloat(whiteNotes.count)
        if let index = whiteNotes.firstIndex(of: note) { return CGRect(x: CGFloat(index) * width, y: 0, width: width, height: size.height) }
        let preceding = whiteNotes.filter { $0 < note }.count
        return CGRect(x: CGFloat(preceding) * width - width * 0.3, y: 0, width: width * 0.6, height: size.height * 0.63)
    }
    private func note(at point: CGPoint, size: CGSize) -> UInt8? {
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        for note in 21...108 where !whiteNotes.contains(note) {
            if keyRect(note, size: size).contains(point) { return UInt8(note) }
        }
        return whiteNotes.first(where: { keyRect($0, size: size).contains(point) }).map(UInt8.init)
    }
    private func release() { if let pressed { StemAudioPlayback.shared.releaseKeyboardNote(pressed) }; pressed = nil }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for black in [false, true] {
                    for note in 21...108 where (!whiteNotes.contains(note)) == black {
                        let rect = keyRect(note, size: size).insetBy(dx: 0.5, dy: 0)
                        let active = state.notes.contains(UInt8(note)) || pressed == UInt8(note)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(active ? Color(hex: UInt32(black ? blackColor : whiteColor)) : (black ? Color(white: 0.08) : Color(white: 0.89))))
                        if note == 21 || note % 12 == 0 {
                            let label = note == 21 ? "A-1" : "C\(note / 12 - 2)"
                            context.draw(Text(verbatim: label).font(.system(size: 9, weight: .medium)).foregroundColor(.black), at: CGPoint(x: rect.midX, y: rect.maxY - 11))
                        }
                    }
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let next = note(at: event.location, size: geometry.size)
                    guard pressed != next else { return }
                    release(); pressed = next
                    if let next { StemAudioPlayback.shared.playKeyboardNote(next) }
                }.onEnded { _ in release() })
        }.padding(.horizontal, 6).padding(.vertical, 4).background(JarasTheme.panel)
            .onDisappear { release(); StemAudioPlayback.shared.releaseKeyboardNotes() }
            .onChange(of: active) { if !$0 { release(); StemAudioPlayback.shared.releaseKeyboardNotes() } }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in release(); StemAudioPlayback.shared.releaseKeyboardNotes() }
            #endif
            .accessibilityLabel("88-key keyboard")
    }
}

private struct MixerWorkspaceHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct KeyboardSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jaras.keyboard.whiteColor") private var whiteColor = 0x54ff93
    @AppStorage("jaras.keyboard.blackColor") private var blackColor = 0x54ff93
    @State private var channel = KeyboardMIDIMonitor.shared.channel
    private func color(_ value: Binding<Int>) -> Binding<Color> {
        Binding(get: { Color(hex: UInt32(value.wrappedValue)) }, set: { color in
            #if os(macOS)
            guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            value.wrappedValue = Int((rgb.redComponent * 255).rounded()) << 16 | Int((rgb.greenComponent * 255).rounded()) << 8 | Int((rgb.blueComponent * 255).rounded())
            #else
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            value.wrappedValue = Int((r * 255).rounded()) << 16 | Int((g * 255).rounded()) << 8 | Int((b * 255).rounded())
            #endif
        })
    }
    var body: some View {
        VStack(spacing: 18) {
            Text("Keyboard").font(.headline)
            ColorPicker("White key highlight", selection: color($whiteColor), supportsOpacity: false)
            ColorPicker("Black key highlight", selection: color($blackColor), supportsOpacity: false)
            Picker("MIDI channel", selection: $channel) {
                ForEach(1...16, id: \.self) { Text(String($0)).tag($0) }
            }.onChange(of: channel) { KeyboardMIDIMonitor.shared.channel = $0 }
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }.font(.body).padding(24).frame(width: 340).background(JarasTheme.panel)
            #if os(macOS)
            .onExitCommand { dismiss() }
            #endif
    }
}
