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
    private struct TrackEdit { let id: UUID; let name: String; let color: UInt32 }
    @State private var trackEdit: TrackEdit?
    private struct FXTarget: Identifiable { let track: UUID?; let effect: String; var id: String { (track.map { "track:" + $0.uuidString } ?? "master") + effect } }
    @State private var fxTargets: [FXTarget] = []
    @State private var clipFXTargets: [UUID] = []
    @State private var textItemTarget: UUID?
    @State private var lastObservedProjectID: UUID?
    @AppStorage("jaras.language") private var language = "en"
    @State private var navigationOpen = false
    @AppStorage("jaras.trackColumnWidth") private var mixerWidth = Double(SidebarWidthLimits.trackMixer)
    @AppStorage("jaras.trackColumnRestoreWidth") private var mixerRestoreWidth = 248.0
    @State private var liveSetlistWidth: CGFloat?
    @AppStorage("jaras.setlistWidth") private var setlistWidth = Double(SidebarWidthLimits.setlist)
    @AppStorage("jaras.setlistRestoreWidth") private var setlistRestoreWidth = 240.0
    private func toggleMixer() {
        if mixerWidth > 0 { mixerRestoreWidth = mixerWidth; mixerWidth = 0 }
        else { mixerWidth = max(Double(SidebarWidthLimits.trackMixer), mixerRestoreWidth) }
    }
    private func toggleSetlist() {
        if setlistWidth > 0 { setlistRestoreWidth = setlistWidth; setlistWidth = 0 }
        else { setlistWidth = max(Double(SidebarWidthLimits.setlist), setlistRestoreWidth) }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TransportView(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), toggleNavigation: { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } }, openSettings: { navigationOpen = false; panel = .settings }, mixerCollapsed: mixerWidth <= 0, setlistCollapsed: setlistWidth <= 0, toggleMixer: toggleMixer, toggleSetlist: toggleSetlist)
                    #if os(macOS)
                    GeometryReader { geometry in
                        let maximum = max(0, min(486.5, geometry.size.width - 420))
                        let requested = liveSetlistWidth ?? setlistWidth
                        let width = requested <= 0 ? 0 : min(maximum, max(SidebarWidthLimits.setlist, requested))
                        HStack(spacing: 0) {
                            TimelineGridView(show: show, documents: documents, toggleMixer: toggleMixer)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            MixerResizeHandle(width: width, maximum: maximum, minimum: SidebarWidthLimits.setlist, direction: -1, onStart: {
                                if width > 0 { setlistRestoreWidth = width }
                            }, onToggle: toggleSetlist, onEnd: { finalWidth in
                                setlistWidth = finalWidth
                                liveSetlistWidth = nil
                            }) { liveSetlistWidth = $0 }
                                .frame(width: 6)
                            SongListView(show: show)
                                .frame(width: width > 0 ? width : min(maximum, max(Double(SidebarWidthLimits.setlist), setlistRestoreWidth)))
                                .frame(width: width, alignment: .trailing).clipped().allowsHitTesting(width > 0)
                        }
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #else
                    HStack(spacing: 1) {
                        TimelineGridView(show: show, documents: documents, toggleMixer: toggleMixer)
                        SongListView(show: show).frame(width: 220)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #endif
                HStack {
                    ResourceUsageView()
                    Spacer()
                    AudioStatusView()
                }.overlay { RegionPitchControl(show: show) }.font(.system(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).frame(height: 27).background(JarasTheme.panel)

            }
        }.background(JarasTheme.background).foregroundStyle(JarasTheme.text).scrollIndicators(.hidden)
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
            .alert("Import audio", isPresented: Binding(get: { !documents.audioImportError.isEmpty }, set: { if !$0 { documents.audioImportError = "" } })) {
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
            .environment(\.editTrackDetails, { id, name, color in
                trackEdit = TrackEdit(id: id, name: name, color: color)
            })
            .overlay {
                if let edit = trackEdit {
                    ZStack {
                        Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { trackEdit = nil }
                        NameColorEditor(title: "Editar pista", initialName: edit.name, initialColor: edit.color, save: { name, color in
                            show.editTrack(edit.id, name: name, color: color)
                        }, close: { trackEdit = nil }, nameEditable: show.current?.tracks.first(where: { $0.id == edit.id })?.kind == .standard)
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
            .onAppear { mappings.bind(show) }
            .onChange(of: textItemTarget != nil || trackEdit != nil || mappings.editing != nil) { blocked in
                #if os(macOS)
                RightClickRouter.shared.interactionBlocked = blocked
                #endif
            }
            .onDisappear {
                #if os(macOS)
                FXWindows.shared.closeAll()
                RightClickRouter.shared.interactionBlocked = false
                #endif
            }
            .alert("Recording", isPresented: Binding(get: { !recording.error.isEmpty }, set: { if !$0 { recording.error = "" } })) { Button("OK") { recording.error = "" } } message: { Text(LocalizedStringKey(recording.error)) }
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
                        Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Fechar")
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

/// This small observer keeps playback changes confined to the footer control.
private struct RegionPitchControl: View {
    @ObservedObject var show: ShowController
    @State private var editing: Part?
    private func step(_ delta: Int) {
        guard let song = show.current, let region = show.pitchRegion else { return }
        let targets = song.pitchTargets(region)
        show.setRegionPitch(region.id, semitones: min(6, max(-6, region.semitones + delta)), tracks: targets.tracks, groups: targets.groups)
    }
    var body: some View {
        HStack(spacing: 3) {
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) <= -6).jarasHelp("Lower song pitch")
            Text(String(format: "%dst", show.pitchRegion?.semitones ?? 0))
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .frame(width: 45, height: 22).background(JarasTheme.display).cornerRadius(4)
                .immediateRightClick { editing = show.pitchRegion }
                .accessibilityLabel("Song pitch").accessibilityValue(String(show.pitchRegion?.semitones ?? 0) + "st")
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) >= 6).jarasHelp("Raise song pitch")
        }.buttonStyle(.plain).foregroundStyle(JarasTheme.green)
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
