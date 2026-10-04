import SwiftUI
import UniformTypeIdentifiers
import Combine
enum SidebarWidthLimits {
    static let trackMixer: CGFloat = 230
    static let setlistDefault: CGFloat = 335.63671875
    #if os(macOS)
    static let setlist: CGFloat = setlistDefault - 30
    #else
    static let setlist: CGFloat = setlistDefault
    #endif
}
private struct WorkspaceProjectIdentity: Hashable {
    let project: UUID
    let document: URL?
    let missingAudioPaths: Set<String>
    let remotePresentation: Bool
}
struct MainView: View {
    @ObservedObject private var recording = TrackRecording.shared
    @ObservedObject private var mappings = ControlMappings.shared
    let show: ShowController
    var remotePresentation = false
    let auth: AuthService
    let backend: any BackendClient
    @ObservedObject var documents: ProjectDocuments
    private var desktopExtras: Bool {
        #if os(macOS)
        return !remotePresentation
        #else
        return false
        #endif
    }
    private enum Panel: String, Identifiable {
        case projects, settings, audioSettings
        var id: String { rawValue }
        var isSettings: Bool { self != .projects }
    }
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
    @State private var sectionsOpen = false
    @AppStorage("catlive.sections.displayMode") private var sectionDisplayMode = "horizontal"
    private var horizontalSectionsVisible: Bool { sectionsOpen && sectionDisplayMode != "vertical" && setlistWidth > 0 }
    @State private var keyboardSettings = false
    @State private var workspaceHeight: CGFloat = 900
    @AppStorage("catlive.footerDisplayHeight") private var storedFooterHeight = 27.0
    @AppStorage("jaras.footerMixerHeight") private var footerMixerHeight = 232.0
    @State private var draggedFooterHeight: CGFloat?
    private var maximumFooterHeight: CGFloat {
        min(161.046875, max(27, workspaceHeight - 150 - (keyboardOpen ? 108 : 0)
            - (horizontalSectionsVisible ? SmoothSeekPanelLayout.height : 0)
            - (footerMixerOpen ? min(723.55859375, max(232, footerMixerHeight)) : 0)))
    }
    private var footerHeight: CGFloat {
        #if os(macOS)
        return min(maximumFooterHeight, max(27, draggedFooterHeight ?? storedFooterHeight))
        #else
        return 27
        #endif
    }
    @AppStorage("jaras.trackColumnWidth") private var mixerWidth = Double(SidebarWidthLimits.trackMixer)
    @AppStorage("jaras.trackColumnRestoreWidth") private var mixerRestoreWidth = 248.0
    #if os(macOS)
    @State private var setlistScrollController = SidebarScrollController()
    #endif
    @AppStorage("jaras.setlistWidth") private var setlistWidth = Double(SidebarWidthLimits.setlistDefault)
    @AppStorage("jaras.setlistRestoreWidth") private var setlistRestoreWidth = 240.0
    init(show: ShowController, remotePresentation: Bool = false, auth: AuthService, backend: any BackendClient, documents: ProjectDocuments) {
        self.show = show; self.remotePresentation = remotePresentation
        self.auth = auth; self.backend = backend; self.documents = documents
        let prefix = remotePresentation ? "jaras.remote." : "jaras."
        _mixerWidth = AppStorage(wrappedValue: remotePresentation ? 280 : Double(SidebarWidthLimits.trackMixer), prefix + "trackColumnWidth")
        _mixerRestoreWidth = AppStorage(wrappedValue: remotePresentation ? 280 : 248, prefix + "trackColumnRestoreWidth")
        _setlistWidth = AppStorage(wrappedValue: remotePresentation ? 370 : Double(SidebarWidthLimits.setlistDefault), prefix + "setlistWidth")
        _setlistRestoreWidth = AppStorage(wrappedValue: remotePresentation ? 370 : 240, prefix + "setlistRestoreWidth")
    }
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
            #if os(macOS)
            leftToolRail
            #endif
            VStack(spacing: 0) {
                TransportView(show: show, documents: documents, remotePresentation: remotePresentation, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), toggleNavigation: { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } }, openSettings: { navigationOpen = false; panel = .settings }, mixerCollapsed: mixerWidth <= 0, setlistCollapsed: setlistWidth <= 0, toggleMixer: toggleMixer, toggleSetlist: toggleSetlist)
                    #if os(macOS)
                    GeometryReader { geometry in
                        SectionListDock(visible: sectionsOpen && sectionDisplayMode == "vertical" && setlistWidth > 0, storageKey: "catlive.sections.width", minimumPrimaryWidth: 620, defaultFraction: 0.22) {
                        NativeWorkspaceSplit(width: CGFloat(setlistWidth), restoreWidth: CGFloat(setlistRestoreWidth),
                            minimum: SidebarWidthLimits.setlist, scrollController: setlistScrollController,
                            contentIdentity: WorkspaceProjectIdentity(project: show.snapshot.project.id, document: documents.currentURL,
                                missingAudioPaths: documents.missingAudioPaths, remotePresentation: remotePresentation),
                            onToggle: toggleSetlist, onEnd: { finalWidth in
                                if finalWidth > 0 { setlistRestoreWidth = finalWidth }
                                setlistWidth = finalWidth
                            }) {
                            TimelineGridView(show: show, documents: documents, remotePresentation: remotePresentation, toggleMixer: toggleMixer)
                                .foregroundStyle(JarasTheme.text)
                        } trailing: {
                            SongListView(show: show, sidebarScrollController: setlistScrollController)
                                .foregroundStyle(JarasTheme.text)
                        }
                        } sections: { SmoothSeekPanel(show: show, verticalList: true) }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #else
                    HStack(spacing: 1) {
                        TimelineGridView(show: show, documents: documents, remotePresentation: remotePresentation, toggleMixer: toggleMixer)
                        SongListView(show: show).frame(width: 220)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #endif
                // Preserve the mixer's established expansion range while leaving
                // space for the transport and the top of the timeline/Setlist.
                if desktopExtras {
                FooterMixerPanel(show: show, active: footerMixerOpen,
                    maximumHeight: max(180, workspaceHeight - 240 - (keyboardOpen ? 108 : 0) - (horizontalSectionsVisible ? SmoothSeekPanelLayout.height : 0)))
                if horizontalSectionsVisible { SmoothSeekPanel(show: show).frame(height: SmoothSeekPanelLayout.height) }
                FooterPianoKeyboard(active: keyboardOpen).frame(height: 108)
                    .frame(height: keyboardOpen ? 108 : 0, alignment: .top).clipped().allowsHitTesting(keyboardOpen).accessibilityHidden(!keyboardOpen)
                }
                GeometryReader { geometry in
                    #if os(macOS)
                    HStack(spacing: 14) {
                        ResourceUsageView().fixedSize(horizontal: true, vertical: false)
                        FooterPlaylistDisplay(show: show, height: footerHeight - 2).frame(maxWidth: .infinity)
                            .overlay(FooterDisplayResizeInput(height: footerHeight, maximum: maximumFooterHeight,
                                changed: { draggedFooterHeight = $0 }, ended: { value in
                                    storedFooterHeight = value; draggedFooterHeight = nil
                                }))
                        AudioStatusView { navigationOpen = false; panel = .audioSettings }.fixedSize(horizontal: true, vertical: false)
                    }.buttonStyle(.plain).frame(height: footerHeight)
                    #else
                    let displayWidth = min(300, max(0, geometry.size.width - 320))
                    let sideWidth = max(0, (geometry.size.width - displayWidth) / 2)
                    let audioWidth = min(230, max(100, sideWidth * 0.4))
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            ResourceUsageView().frame(width: 114, alignment: .leading)
                            #if os(macOS)
                            Text(verbatim: "|").foregroundStyle(JarasTheme.secondary)
                            AudioStatusView { navigationOpen = false; panel = .audioSettings }.frame(width: audioWidth, alignment: .leading)
                            #endif
                            FooterProjectNameDisplay(show: show, documents: documents)
                                #if os(macOS)
                                .frame(width: min(315, max(0, sideWidth - audioWidth - 154)), alignment: .leading)
                                #else
                                .frame(maxWidth: .infinity)
                                #endif
                        }.buttonStyle(.plain).padding(.trailing, 14).frame(width: sideWidth, alignment: .leading).clipped()
                        FooterInformationDisplay(show: show).frame(width: displayWidth)
                        #if os(macOS)
                        Color.clear.frame(width: sideWidth)
                        #else
                        AudioStatusView { navigationOpen = false; panel = .audioSettings }.frame(width: sideWidth, alignment: .trailing)
                        #endif
                    }.frame(height: 27)
                    #endif
                }.font(.system(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).frame(height: footerHeight).background(JarasTheme.panel)

            }
        }.background(JarasTheme.background).foregroundStyle(JarasTheme.text).jarasHideScrollIndicators()
            #if os(macOS)
            .background(ProjectTitlebarContent {
                FooterProjectNameDisplay(show: show, documents: documents, titlebar: true)
                    .foregroundStyle(JarasTheme.text)
                    .environment(\.locale, Locale(identifier: language))
                    .preferredColorScheme(.dark)
            })
            #endif
            .overlay { ProjectNoticePresenter(show: show) }
            .background {
                GeometryReader { geometry in
                    // Only the workspace size controls the footer's limit. A
                    // preference on the whole workspace made every track resize
                    // traverse the complete descendant layout to collect it.
                    Color.clear
                        .onAppear { workspaceHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { workspaceHeight = $0 }
                }
            }
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
                FXWindows.shared.documents = documents
                FXWindows.shared.open(show: show, track: track, effect: effect, language: language)
                #else
                let target = FXTarget(track: track, effect: effect)
                if !fxTargets.contains(where: { $0.id == target.id }) { fxTargets.append(target) }
                #endif
            })
            .environment(\.openClipFXChain, { clip in
                #if os(macOS)
                FXWindows.shared.documents = documents
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
                guard !remotePresentation else { return }
                #if os(macOS)
                DAWRemoteHostBridge.bind(show)
                #endif
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
                if !remotePresentation { RightClickRouter.shared.interactionBlocked = blocked }
                #endif
            }
            .onDisappear {
                guard !remotePresentation else { return }
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
                        Text(LocalizedStringKey(selected.isSettings ? "Configurações" : "Projetos")).font(.headline)
                        Spacer()
                        Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Fechar").keyboardShortcut(.cancelAction)
                    }.padding(16)
                    Divider()
                    if selected.isSettings {
                        SettingsView(auth: auth, show: show, backend: backend, initialSection: selected == .audioSettings ? .audio : .general)
                    } else {
                        ProjectBrowserView(documents: documents, completed: { panel = nil })
                    }
                }
                .frame(width: selected.isSettings ? 660 : documents.folderReview == nil ? 560 : 840, height: selected.isSettings ? 540 : 500)
                .background(JarasTheme.background).foregroundStyle(JarasTheme.text)
                .environment(\.locale, Locale(identifier: language))
            }
    }
    #if os(macOS)
    private var leftToolRail: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Menu")
            .jarasHelp("Menu")
            Button(action: toggleMixer) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mixerWidth <= 0 ? Color(hex: 0xc44545) : JarasTheme.green)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(mixerWidth <= 0 ? "Expandir Track-Mixer" : "Recolher Track-Mixer")
            .jarasHelp(mixerWidth <= 0 ? "Restaurar largura anterior do Track-Mixer" : "Ocultar Track-Mixer")
            MacProjectionRail(show: show)
            DesktopMultiLoopBypassButton(show: show)
            Spacer(minLength: 0)
            if desktopExtras {
            Button { footerMixerOpen.toggle() } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(footerMixerOpen ? JarasTheme.green : JarasTheme.text)
            .accessibilityLabel("Barra Mixer")
            .jarasHelp("Barra Mixer")
            Button { keyboardOpen.toggle() } label: {
                Image(systemName: "pianokeys")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(keyboardOpen ? JarasTheme.green : JarasTheme.text)
            .accessibilityLabel("Keyboard")
            .jarasHelp("Keyboard")
            .immediateRightClick { keyboardSettings = true }
            .sheet(isPresented: $keyboardSettings) { KeyboardSettingsView() }
            Button { sectionsOpen.toggle() } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 16, weight: .semibold)).frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }.foregroundStyle(sectionsOpen ? JarasTheme.green : JarasTheme.text)
                .accessibilityLabel("Smooth Seek").jarasHelp("Smooth Seek")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 7)
        .frame(width: 32)
        .frame(maxHeight: .infinity)
        .background(JarasTheme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(JarasTheme.secondary.opacity(0.2)).frame(width: 1) }
    }
    #endif
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
    let openSettings: () -> Void
    @State private var hovering = false
    private var status: String { "\(audio.deviceName) · \(audio.bufferFrames) · \(Int(audio.sampleRate)) Hz" }
    var body: some View {
        Button(action: openSettings) {
            Text(verbatim: status)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(hovering ? JarasTheme.green : JarasTheme.secondary)
                .scaleEffect(hovering ? 1.04 : 1, anchor: .trailing)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .frame(maxWidth: 370, maxHeight: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel("Open audio settings").accessibilityValue(Text(verbatim: status))
            .jarasHelp("Open audio settings")
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
        show.setRegionPitch(region.id, semitones: min(12, max(-12, region.semitones + delta)), tracks: targets.tracks, groups: targets.groups)
    }
    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "Tuner").font(.system(size: 9, weight: .semibold)).foregroundStyle(JarasTheme.text)
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 20, height: 25).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) <= -12).jarasHelp("Lower song pitch")
            Text(String(format: "%dst", show.pitchRegion?.semitones ?? 0))
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .frame(width: 34, height: 23).background(JarasTheme.display).cornerRadius(4)
                .immediateRightClick { editing = show.pitchRegion }
                .accessibilityLabel("Song pitch").accessibilityValue(String(show.pitchRegion?.semitones ?? 0) + "st")
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 20, height: 25).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) >= 12).jarasHelp("Raise song pitch")
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
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleTracks) { track in
                        Toggle(track.name, isOn: Binding(get: { isSelected(track) }, set: { setSelected(track, $0) }))
                            .toggleStyle(.automatic).tint(JarasTheme.green)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: 245)
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

/// Observes transient modal notices without rebuilding the workspace for them.
private struct ProjectNoticePresenter: View {
    @ObservedObject var show: ShowController
    var body: some View {
        Color.clear.allowsHitTesting(false)
            .alert(Text(verbatim: show.modalNotice.map { JarasLocalization.string($0) } ?? ""), isPresented: Binding(
                get: { show.modalNotice != nil }, set: { if !$0 { show.modalNotice = nil } })) {
                Button("OK") { show.modalNotice = nil }.keyboardShortcut(.defaultAction)
            }
    }
}

private struct FooterProjectNameDisplay: View {
    @ObservedObject var show: ShowController
    @ObservedObject var documents: ProjectDocuments
    var titlebar = false
    @State private var showingBackups = false
    @State private var backups: [(url: URL, date: Date)] = []
    @State private var loadingBackups = false
    @State private var backupError = ""
    @State private var savedDate = ""
    private var timestamp: String { show.lastSavedAt ?? show.snapshot.project.updatedAt }
    private var label: String { "\(JarasLocalization.string("Session")) - \(show.snapshot.project.name) - \(savedDate)" }
    private static let iso = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private static let displayDate: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "dd/MM/yyyy HH:mm"; return value
    }()
    private func updateDate() {
        savedDate = (Self.iso.date(from: timestamp) ?? Self.fractional.date(from: timestamp)).map { Self.displayDate.string(from: $0) } ?? "—"
    }
    private func loadBackups() async {
        guard let document = documents.currentURL else { backups = []; return }
        loadingBackups = true; backupError = ""
        defer { loadingBackups = false }
        do {
            backups = try await Task.detached(priority: .userInitiated) {
                try ProjectBackups.migrateLegacyNames(for: document)
                let folder = ProjectBackups.mediaDirectory(for: document).appendingPathComponent("backups", isDirectory: true)
                guard FileManager.default.fileExists(atPath: folder.path) else { return [(url: URL, date: Date)]() }
                let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                return try entries.filter { $0.pathExtension.lowercased() == "bkjl" }.compactMap { url -> (url: URL, date: Date)? in
                    let properties = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard properties.isRegularFile == true else { return nil }
                    return (url, ProjectBackups.date(for: url))
                }.sorted { $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date }.prefix(10).map { $0 }
            }.value
        } catch { backupError = error.localizedDescription }
    }
    private var backupList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent backups").font(.headline)
            if loadingBackups { ProgressView() }
            else if !backupError.isEmpty { Text(verbatim: backupError).foregroundStyle(.red) }
            else if backups.isEmpty { Text("No backups found").foregroundStyle(.secondary) }
            else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(backups, id: \.url) { backup in
                            Button {
                                showingBackups = false
                                documents.open(backup.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: backup.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(verbatim: Self.displayDate.string(from: backup.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(documents.busy || show.isPlaying || TrackRecording.shared.recording || TrackRecording.shared.busy)
                        }
                    }
                }.frame(height: min(410, CGFloat(backups.count) * 56))
            }
        }.padding(16).frame(width: 430).task { await loadBackups() }
    }
    var body: some View {
        Button { showingBackups.toggle() } label: {
        HStack(spacing: 3) {
            Text("Session").fixedSize()
            Text(verbatim: "-").fixedSize()
            Text(verbatim: show.snapshot.project.name).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "- \(savedDate)").fixedSize()
        }.font(.system(size: titlebar ? 11 : 10, weight: titlebar ? .medium : .bold)).lineLimit(1)
            .padding(.horizontal, titlebar ? 0 : 7).frame(maxWidth: .infinity, alignment: .leading).frame(height: 21)
            .background(titlebar ? Color.clear : JarasTheme.display, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(titlebar ? Color.clear : JarasTheme.line))
            .jarasHelp(label)
            .accessibilityElement(children: .ignore).accessibilityLabel("Project name").accessibilityValue(label)
            .onAppear(perform: updateDate).onChange(of: timestamp) { _ in updateDate() }
        }.buttonStyle(.plain)
            .popover(isPresented: $showingBackups, arrowEdge: titlebar ? .bottom : .top) { backupList }
    }
}

#if os(macOS)
/// The display itself is the resize surface; screen coordinates keep dragging
/// stable as the footer's top edge moves under the pointer.
private struct FooterDisplayResizeInput: NSViewRepresentable {
    let height: CGFloat
    let maximum: CGFloat
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    func makeNSView(context: Context) -> FooterDisplayResizeView { FooterDisplayResizeView() }
    func updateNSView(_ view: FooterDisplayResizeView, context: Context) {
        view.height = height; view.maximum = maximum; view.changed = changed; view.ended = ended
    }
}
private final class FooterDisplayResizeView: NSView {
    var height: CGFloat = 27
    var maximum: CGFloat = 900
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat) -> Void)?
    private var origin: (y: CGFloat, height: CGFloat)?
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        origin = (event.locationInWindow.y, height)
    }
    private func resizedHeight(_ event: NSEvent) -> CGFloat? {
        guard let origin else { return nil }
        return min(max(27, maximum), max(27, origin.height + event.locationInWindow.y - origin.y))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let value = resizedHeight(event) else { return }
        changed?(value)
    }
    override func mouseUp(with event: NSEvent) {
        guard let value = resizedHeight(event) else { return }
        origin = nil; ended?(value)
        window?.invalidateCursorRects(for: self)
    }
}
#endif
