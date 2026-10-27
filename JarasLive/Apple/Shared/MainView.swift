import SwiftUI
import UniformTypeIdentifiers
import Combine
enum SidebarWidthLimits {
    #if os(macOS)
    static let trackMixer: CGFloat = 280.7578125
    #else
    static let trackMixer: CGFloat = 230
    #endif
    static let setlistDefault: CGFloat = 335.63671875
    #if os(macOS)
    static let setlist: CGFloat = (setlistDefault - 30) * 0.70
    #else
    static let setlist: CGFloat = setlistDefault
    #endif
}
struct TrackMixerColumnGeometry {
    static let iconWidth: CGFloat = 40
    static let spacing: CGFloat = 4
    let bodyWidth: CGFloat
    let iconExtension: CGFloat
    var totalWidth: CGFloat { bodyWidth > 0 ? bodyWidth + iconExtension : 0 }

    init(requestedWidth: CGFloat, maximum: CGFloat, showsIcons: Bool) {
        bodyWidth = requestedWidth <= 0 ? 0 : min(maximum, max(SidebarWidthLimits.trackMixer, requestedWidth))
        iconExtension = showsIcons ? Self.iconWidth + Self.spacing : 0
    }

    func storedWidth(for total: CGFloat) -> CGFloat { max(0, total - iconExtension) }
}
private struct WorkspaceProjectIdentity: Hashable {
    let project: UUID
    let document: URL?
    let missingAudioPaths: Set<String>
    let remotePresentation: Bool
    let partsLeftOpen: Bool
    let partsRightOpen: Bool
    let setlistPlacement: SetlistPlacement
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
    #if !os(macOS)
    private struct FXTarget: Identifiable { let track: UUID?; let effect: String; var id: String { (track.map { "track:" + $0.uuidString } ?? "master") + effect } }
    @State private var fxTargets: [FXTarget] = []
    @State private var clipFXTargets: [UUID] = []
    #endif
    @State private var textItemTarget: UUID?
    @State private var lastObservedProjectID: UUID?
    @State private var presentedSessionID: UUID?
    @AppStorage("jaras.language") private var language = "en"
    @State private var navigationOpen = false
    @AppStorage("jaras.layout.mixer.open") private var footerMixerOpen = false
    #if os(macOS)
    @StateObject private var detachedMixer = DetachedMixerWindow()
    @StateObject private var detachedParts = DetachedPartsWindow()
    @StateObject private var detachedSetlist = DetachedSetlistWindow()
    @StateObject private var toolWindows = WorkspaceToolWindows()
    #endif
    @State private var keyboardOpen = false
    #if os(macOS)
    @AppStorage("jaras.vinhetas.visible") private var vinhetasOpen = false
    @StateObject private var vinhetasWindow = VinhetasWindow()
    #endif
    @AppStorage("jaras.layout.parts.open") private var partsLeftOpen = false
    @AppStorage("jaras.layout.partsRight.open") private var partsRightOpen = false
    @AppStorage("jaras.layout.setlist.placement") private var setlistPlacement: SetlistPlacement = .right
    @AppStorage("jaras.layout.setlist.dockSide") private var setlistDockPlacement: SetlistPlacement = .right
    @State private var keyboardSettings = false
    @AppStorage("catlive.footerDisplayHeight") private var storedFooterHeight = 27.0
    @AppStorage("jaras.footerMixerHeight") private var footerMixerHeight = 273.0
    @State private var footerResizeCoordinator = FooterVerticalResizeCoordinator()
    private func maximumFooterHeight(workspaceHeight: CGFloat) -> CGFloat {
        min(161.046875, max(27, workspaceHeight - 150 - (keyboardOpen ? 108 : 0)
            - (footerMixerOpen ? min(723.55859375, max(273, footerMixerHeight)) : 0)))
    }
    @AppStorage("jaras.trackColumnWidth") private var mixerWidth = Double(SidebarWidthLimits.trackMixer)
    @AppStorage("jaras.trackColumnRestoreWidth") private var mixerRestoreWidth = Double(SidebarWidthLimits.trackMixer)
    #if os(macOS)
    @State private var setlistScrollController = SidebarScrollController()
    #endif
    @AppStorage("jaras.setlistWidth") private var setlistWidth = Double(SidebarWidthLimits.setlistDefault)
    @AppStorage("jaras.setlistRestoreWidth") private var setlistRestoreWidth = 240.0
    init(show: ShowController, remotePresentation: Bool = false, auth: AuthService, backend: any BackendClient, documents: ProjectDocuments) {
        self.show = show; self.remotePresentation = remotePresentation
        self.auth = auth; self.backend = backend; self.documents = documents
        let prefix = remotePresentation ? "jaras.remote." : "jaras."
        _footerMixerOpen = AppStorage(wrappedValue: false, prefix + "layout.mixer.open")
        _partsLeftOpen = AppStorage(wrappedValue: false, prefix + "layout.parts.open")
        _partsRightOpen = AppStorage(wrappedValue: false, prefix + "layout.partsRight.open")
        _setlistPlacement = AppStorage(wrappedValue: .right, prefix + "layout.setlist.placement")
        _setlistDockPlacement = AppStorage(wrappedValue: .right, prefix + "layout.setlist.dockSide")
        _mixerWidth = AppStorage(wrappedValue: remotePresentation ? 280 : Double(SidebarWidthLimits.trackMixer), prefix + "trackColumnWidth")
        _mixerRestoreWidth = AppStorage(wrappedValue: remotePresentation ? 280 : Double(SidebarWidthLimits.trackMixer), prefix + "trackColumnRestoreWidth")
        _setlistWidth = AppStorage(wrappedValue: remotePresentation ? 370 : Double(SidebarWidthLimits.setlistDefault), prefix + "setlistWidth")
        _setlistRestoreWidth = AppStorage(wrappedValue: remotePresentation ? 370 : 240, prefix + "setlistRestoreWidth")
    }
    private func toggleBarMixer() {
        #if os(macOS)
        if detachedMixer.isDetached {
            if detachedMixer.isVisible { detachedMixer.hide() }
            else { showDetachedMixer() }
            return
        }
        #endif
        footerMixerOpen.toggle()
    }
    private func toggleMixer() {
        Self.togglePanel(width: $mixerWidth, restore: $mixerRestoreWidth, minimum: SidebarWidthLimits.trackMixer)
    }
    private func openSettings(_ section: SettingsView.Section? = nil) {
        navigationOpen = false
        #if os(macOS)
        toolWindows.openSettings(auth: auth, show: show, backend: backend, section: section)
        #else
        panel = section == .audio ? .audioSettings : .settings
        #endif
    }
    private func openAdvanced() {
        #if os(macOS)
        navigationOpen = false
        toolWindows.openAdvanced(show: show, documents: documents)
        #endif
    }
    private var setlistCollapsed: Bool {
        #if os(macOS)
        if setlistPlacement == .detached { return !detachedSetlist.isVisible }
        #endif
        return setlistWidth <= 0
    }
    private func toggleSetlist() {
        #if os(macOS)
        if setlistPlacement == .detached {
            if detachedSetlist.isVisible { detachedSetlist.hide() }
            else { openDetachedSetlist() }
            return
        }
        #endif
        Self.togglePanel(width: $setlistWidth, restore: $setlistRestoreWidth, minimum: SidebarWidthLimits.setlist)
    }
    private func placeSetlist(_ placement: SetlistPlacement) {
        #if os(macOS)
        if placement == .left { partsLeftOpen = false }
        if placement == .detached {
            setlistPlacement = .detached
            openDetachedSetlist()
        } else {
            detachedSetlist.close()
            setlistPlacement = placement; setlistDockPlacement = placement
            if setlistWidth <= 0 { setlistWidth = max(Double(SidebarWidthLimits.setlist), setlistRestoreWidth) }
        }
        #endif
    }
    #if os(macOS)
    private func restoreGlobalPanels() {
        guard !remotePresentation, DesktopProjectTabs.shared.isForeground(show) else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "jaras.layout.vinhetas.detached") {
            let visible = defaults.object(forKey: "jaras.layout.vinhetas.visible") as? Bool ?? true
            vinhetasOpen = false; vinhetasWindow.open(show: show)
            if !visible { vinhetasWindow.hide() }
        }
        if defaults.bool(forKey: "jaras.layout.mixer.detached") {
            let visible = defaults.object(forKey: "jaras.layout.mixer.visible") as? Bool ?? true
            showDetachedMixer()
            if !visible { detachedMixer.hide() }
        }
        if defaults.bool(forKey: "jaras.layout.parts.detached") {
            let visible = defaults.object(forKey: "jaras.layout.parts.visible") as? Bool ?? true
            partsLeftOpen = false; detachedParts.open(show: show)
            if !visible { detachedParts.hide() }
        }
        if setlistPlacement == .detached {
            let visible = defaults.object(forKey: "jaras.layout.setlist.visible") as? Bool ?? true
            openDetachedSetlist()
            if !visible { detachedSetlist.hide() }
        }
    }
    private func openDetachedSetlist() {
        detachedSetlist.setPartsVisible(partsRightOpen)
        detachedSetlist.open(onDock: { placeSetlist(setlistDockPlacement) }) {
            DetachedSetlistContent(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(),
                                   partsOpen: $partsRightOpen)
        }
    }
    private func showDetachedMixer() {
        footerMixerOpen = false
        detachedMixer.open(show: show, openFX: { track, effect in
            FXWindows.shared.open(show: show, track: track, effect: effect, language: language)
        }, editTrack: { request in
            guard request.project == show.snapshot.project.id else { return }
            trackEdit = request
        })
    }
    #endif
    private static func togglePanel(width: Binding<Double>, restore: Binding<Double>, minimum: CGFloat) {
        if width.wrappedValue > 0 { restore.wrappedValue = width.wrappedValue; width.wrappedValue = 0 }
        else { width.wrappedValue = max(Double(minimum), restore.wrappedValue) }
    }
    var body: some View {
        // Window geometry changes the workspace's available height, not the
        // transport actions or tool rail. Keep those values outside the reader
        // so a resize does not recreate their closures and invalidate every
        // control. Their own layouts still receive the current proposed size.
        let transport = TransportView(show: show, documents: documents, remotePresentation: remotePresentation,
            mediaDirectory: documents.currentURL?.deletingLastPathComponent(),
            toggleNavigation: { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } },
            openSettings: { openSettings() }, openAdvanced: openAdvanced,
            mixerCollapsed: mixerWidth <= 0, setlistCollapsed: setlistCollapsed,
            toggleMixer: toggleMixer, toggleSetlist: toggleSetlist,
            setlistPlacement: setlistPlacement, placeSetlist: placeSetlist)
        #if os(macOS)
        let tools = leftToolRail
        #else
        let tools = EmptyView()
        #endif
        return presentWorkspace(GeometryReader { geometry in
            VStack(spacing: 0) {
                #if os(macOS)
                if desktopExtras && documents.projectTabCount > 1 { DesktopProjectTabBar().frame(height: 24) }
                #endif
                workspace(height: max(0, geometry.size.height - (desktopExtras && documents.projectTabCount > 1 ? 24 : 0)), transport: transport, tools: tools)
            }
        })
    }
    private func workspace<Transport: View, Tools: View>(height workspaceHeight: CGFloat,
                                                       transport: Transport, tools: Tools) -> some View {
        HStack(spacing: 0) {
            #if os(macOS)
            tools
            #endif
            VStack(spacing: 0) {
                transport
                    #if os(macOS)
                    GeometryReader { geometry in
                        SectionListDock(visible: partsRightOpen && setlistWidth > 0 && setlistPlacement != .detached, storageKey: "catlive.sections.width", minimumPrimaryWidth: 620, defaultFraction: 0.22) {
                        NativeWorkspaceSplit(width: CGFloat(setlistWidth), restoreWidth: CGFloat(setlistRestoreWidth),
                            minimum: SidebarWidthLimits.setlist, scrollController: setlistScrollController,
                            sidebarLeading: setlistPlacement == .left, sidebarDetached: setlistPlacement == .detached,
                            contentIdentity: WorkspaceProjectIdentity(project: show.snapshot.project.id, document: documents.currentURL,
                                missingAudioPaths: documents.missingAudioPaths, remotePresentation: remotePresentation,
                                partsLeftOpen: partsLeftOpen, partsRightOpen: partsRightOpen, setlistPlacement: setlistPlacement),
                            onToggle: toggleSetlist, onEnd: { finalWidth in
                                if finalWidth > 0 { setlistRestoreWidth = finalWidth }
                                setlistWidth = finalWidth
                            }) {
                            SectionListDock(visible: partsLeftOpen, storageKey: "catlive.parts.left.width",
                                            minimumPrimaryWidth: 260 + max(0, CGFloat(mixerWidth)), defaultFraction: 0.24, leading: true) {
                                TimelineGridView(show: show, documents: documents, remotePresentation: remotePresentation,
                                                 toggleMixer: toggleMixer)
                                    .foregroundStyle(JarasTheme.text)
                            } sections: { SmoothSeekPanel(show: show) }
                        } trailing: {
                            SongListView(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), sidebarScrollController: setlistScrollController,
                                partsOpen: partsRightOpen, toggleParts: { partsRightOpen.toggle() })
                                .foregroundStyle(JarasTheme.text)
                        }
                        } sections: { SmoothSeekPanel(show: show) }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #else
                    SectionListDock(visible: partsRightOpen, storageKey: "catlive.local.sections.width",
                                    minimumPrimaryWidth: 480, defaultFraction: 0.22) {
                        HStack(spacing: 1) {
                            TimelineGridView(show: show, documents: documents, remotePresentation: remotePresentation, toggleMixer: toggleMixer)
                            SongListView(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), partsOpen: partsRightOpen,
                                toggleParts: { partsRightOpen.toggle() }).frame(width: 220)
                        }
                    } sections: {
                        SmoothSeekPanel(show: show)
                    }.overlay(alignment: .topLeading) { navigationLayer }
                    #endif
                // Preserve the mixer's established expansion range while leaving
                // space for the transport and the top of the timeline/Setlist.
                if desktopExtras {
                FooterMixerPanel(show: show, active: footerMixerOpen,
                    maximumHeight: max(180, workspaceHeight - 240 - (keyboardOpen ? 108 : 0)),
                    resizeCoordinator: footerResizeCoordinator)
                if keyboardOpen { FooterPianoKeyboard().frame(height: 108) }
                #if os(macOS)
                FooterNativeHeightHost(storedHeight: 240, minimum: 240, maximum: 240,
                    active: vinhetasOpen && !vinhetasWindow.detached,
                    identity: AnyHashable(ObjectIdentifier(show)), role: .auxiliary) {
                    VinhetasPanel(createTrack: { _ = show.createVinhetasTrack() })
                        .onAppear { VinhetasController.shared.bind(show: show) }
                }
                #endif
                }
                #if os(macOS)
                FooterNativeHeightHost(storedHeight: CGFloat(storedFooterHeight), minimum: 27, maximum: 161.046875,
                    active: true, identity: AnyHashable(ObjectIdentifier(show)), role: .display,
                    resizeCoordinator: footerResizeCoordinator,
                    displayAvailableHeight: workspaceHeight - 150 - (keyboardOpen ? 108 : 0),
                    fallbackMixerHeight: footerMixerOpen ? min(723.55859375, max(273, footerMixerHeight)) : 0) {
                    GeometryReader { geometry in
                        HStack(spacing: 14) {
                            ResourceUsageView().fixedSize(horizontal: true, vertical: false)
                            FooterPlaylistDisplay(show: show, scalesToAvailableHeight: true).frame(maxWidth: .infinity)
                                .overlay(FooterDisplayResizeInput(height: geometry.size.height, maximum: maximumFooterHeight(workspaceHeight: workspaceHeight),
                                    changed: { _ in }, ended: { storedFooterHeight = $0 }))
                            AudioStatusView { openSettings(.audio) }.fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain).frame(height: geometry.size.height)
                    }.font(.jarasSystem(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).background(JarasTheme.panel)
                }
                #else
                GeometryReader { geometry in
                    let displayWidth = min(300, max(0, geometry.size.width - 320))
                    let sideWidth = max(0, (geometry.size.width - displayWidth) / 2)
                    let audioWidth = min(230, max(100, sideWidth * 0.4))
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            ResourceUsageView().fixedSize(horizontal: true, vertical: false)
                            #if os(macOS)
                            Text(verbatim: "|").foregroundStyle(JarasTheme.secondary)
                            AudioStatusView { openSettings(.audio) }.frame(width: audioWidth, alignment: .leading)
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
                        AudioStatusView { openSettings(.audio) }.frame(width: sideWidth, alignment: .trailing)
                        #endif
                    }.frame(height: 27)
                }.font(.jarasSystem(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).frame(height: 27).background(JarasTheme.panel)
                #endif

            }
        }
    }
    // Presentation and environment actions belong to the window, not its
    // changing geometry. Rebuilding these modifiers inside GeometryReader
    // publishes new action closures through every nested hosting boundary.
    private func presentWorkspace<Content: View>(_ content: Content) -> some View {
        content.background(JarasTheme.background).foregroundStyle(JarasTheme.text).jarasHideScrollIndicators()
            #if os(macOS)
            .background(ProjectTitlebarContent {
                FooterProjectNameDisplay(show: show, documents: documents, titlebar: true)
                    .foregroundStyle(JarasTheme.text)
                    .environment(\.locale, Locale(identifier: language))
                    .preferredColorScheme(.dark)
            })
            #endif
            .overlay { ProjectNoticePresenter(show: show) }
            .overlay(alignment: .center) {
                if documents.importingAudio {
                    VStack(spacing: 14) {
                        Text(LocalizedStringKey(documents.status))
                            .font(.jarasCallout).multilineTextAlignment(.center).lineLimit(3)
                        ProgressView(value: documents.audioImportProgress).progressViewStyle(.linear).tint(JarasTheme.green)
                    }
                    .padding(24).frame(width: 360)
                    .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.35), radius: 16)
                    .allowsHitTesting(false)
                }
            }
            .sheet(item: $documents.pendingAudioDrop) { drop in
                AudioDropOptions { layout, gap in
                    guard show.snapshot.project.id == drop.project, show.projectSessionID == drop.session else { return }
                    documents.pendingAudioDrop = nil
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
                    #if !os(macOS)
                    clipFXTargets = []; fxTargets = []
                    #endif
                    textItemTarget = nil; trackEdit = nil
                }
                if lastObservedProjectID != projectID { lastObservedProjectID = projectID }
            }
            .environment(\.editTextItem, { id in
                #if os(macOS)
                toolWindows.openTextItem(show: show, id: id)
                #else
                textItemTarget = id
                #endif
            })
            #if os(macOS)
            .background(NativeTimelineModalGate(blocked: navigationOpen || textItemTarget != nil || trackEdit != nil || mappings.editing != nil))
            #else
            .environment(\.gridInteractionBlocked, navigationOpen || textItemTarget != nil || trackEdit != nil || mappings.editing != nil)
            #endif
            .environment(\.editTrackDetails, { request in
                guard request.project == show.snapshot.project.id, !request.tracks.isEmpty else { return }
                trackEdit = request
            })
            #if os(macOS)
            .onChange(of: partsRightOpen) { visible in detachedSetlist.setPartsVisible(visible) }
            #endif
            .onChange(of: show.snapshot.project.id) { _ in
                trackEdit = nil
                #if os(macOS)
                detachedMixer.close(preserveState: true); detachedSetlist.close(preserveState: true); detachedParts.close(preserveState: true); vinhetasWindow.hide(preserveState: true)
                toolWindows.closeAll()
                restoreGlobalPanels()
                VinhetasController.shared.bind(show: show)
                #endif
            }
            .overlay {
                if let edit = trackEdit {
                    ZStack {
                        Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { trackEdit = nil }
                        Group {
                            if edit.iconOnly {
                                TrackInstrumentPickerModal(show: show, request: edit, close: { trackEdit = nil })
                            } else {
                                NameColorEditor(title: "Editar pista", initialName: edit.name, initialColor: edit.color,
                                    save: { name, color in
                                        guard edit.project == show.snapshot.project.id else { return }
                                        if edit.nameEditable, let track = edit.tracks.first {
                                            show.editTrack(track, name: name, color: color)
                                        } else {
                                            show.editTrackColors(edit.tracks, color: color, project: edit.project)
                                        }
                                    }, close: { trackEdit = nil }, nameEditable: edit.nameEditable, showsName: edit.nameEditable)
                            }
                        }
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
                        ClipFXChainEditor(show: show, clip: clip, close: { clipFXTargets.removeAll { $0 == clip } })
                    }
                }
                #endif
            }
            .onAppear {
                guard !remotePresentation else { return }
                presentedSessionID = show.projectSessionID
                #if os(macOS)
                restoreGlobalPanels()
                DAWRemoteHostBridge.bind(show)
                ResolumeController.shared.bind(show)
                #endif
                mappings.bind(show)
                show.togglePartsPanel = { partsRightOpen.toggle() }
                show.toggleTracksPanel = { toggleMixer() }
                show.toggleBarMixerPanel = { toggleBarMixer() }
                show.toggleSetlistPanel = { toggleSetlist() }
            }
            #if os(macOS)
            .onChange(of: documents.projectTabIndex) { _ in
                if !DesktopProjectTabs.shared.isForeground(show) {
                    detachedMixer.close(preserveState: true); detachedSetlist.close(preserveState: true); detachedParts.close(preserveState: true); vinhetasWindow.hide(preserveState: true)
                    toolWindows.closeAll()
                } else { restoreGlobalPanels(); VinhetasController.shared.bind(show: show) }
            }
            #endif
            .onChange(of: textItemTarget != nil || trackEdit != nil || mappings.editing != nil) { blocked in
                #if os(macOS)
                if !remotePresentation { RightClickRouter.shared.interactionBlocked = blocked }
                #endif
            }
            .onDisappear {
                #if os(macOS)
                toolWindows.closeAll()
                #endif
                guard !remotePresentation else { return }
                #if os(macOS)
                detachedMixer.close(preserveState: true); detachedSetlist.close(preserveState: true); detachedParts.close(preserveState: true); vinhetasWindow.hide(preserveState: true)
                guard DesktopProjectTabs.shared.isForeground(show) else { return }
                #endif
                // SwiftUI presents the replacement .id before removing the old
                // workspace. The old view must not erase the new callbacks.
                guard presentedSessionID == show.projectSessionID else { return }
                show.toggleTracksPanel = {}; show.toggleBarMixerPanel = {}; show.toggleSetlistPanel = {}; show.togglePartsPanel = {}
                #if os(macOS)
                ResolumeController.shared.stop()
                FXWindows.shared.closeAll()
                RightClickRouter.shared.interactionBlocked = false
                #endif
            }
            .alert(Text(verbatim: recording.error.isEmpty ? "" : JarasLocalization.string("Recording")), isPresented: Binding(get: { !recording.error.isEmpty }, set: { if !$0 { recording.error = "" } })) { Button("OK") { recording.error = "" } } message: { Text(LocalizedStringKey(recording.error)) }
            .overlay {
                #if os(macOS)
                let settingsOpen = toolWindows.settingsOpen
                #else
                let settingsOpen = false
                #endif
                if mappings.editing != nil && mappings.editing?.presentedInline != true && mappings.editing?.fxParameter == nil && panel == nil && !settingsOpen {
                    ZStack { Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { mappings.editing = nil }; ControlMappingEditor() }
                }
            }
            .overlay {
                if let id = textItemTarget,
                   let track = show.current?.tracks.first(where: { $0.kind.isText && $0.clips.contains { $0.id == id } }),
                   let item = track.clips.first(where: { $0.id == id }) {
                    ZStack {
                        Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { textItemTarget = nil }
                        TextItemEditor(text: item.text ?? "", apply: { show.updateTextItem(id, text: $0) }, close: { textItemTarget = nil })
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.4), radius: 18)
                            .id(id)
                    }
                }
            }
            .sheet(item: $panel) { selected in
                VStack(spacing: 0) {
                    HStack {
                        #if os(macOS)
                        Text("Projetos").font(.jarasHeadline)
                        #else
                        Text(LocalizedStringKey(selected.isSettings ? "Configurações" : "Projetos")).font(.jarasHeadline)
                        #endif
                        Spacer()
                        Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Fechar").keyboardShortcut(.cancelAction)
                    }.padding(16)
                    Divider()
                    #if os(macOS)
                    ProjectBrowserView(documents: documents, completed: { panel = nil })
                    #else
                    if selected.isSettings {
                        SettingsView(auth: auth, show: show, backend: backend, initialSection: selected == .audioSettings ? .audio : .general)
                    } else {
                        ProjectBrowserView(documents: documents, completed: { panel = nil })
                    }
                    #endif
                }
                #if os(macOS)
                .interfaceScaledFrame(width: documents.folderReview == nil ? 560 : 840, height: 500)
                #else
                .frame(width: selected.isSettings ? 940 : documents.folderReview == nil ? 560 : 840, height: selected.isSettings ? 540 : 500)
                #endif
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
                    .font(.jarasSystem(size: 16))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Menu")
            .jarasHelp("Menu")
            Button(action: toggleMixer) {
                Image(systemName: "slider.horizontal.3")
                    .font(.jarasSystem(size: 15, weight: .semibold))
                    .foregroundStyle(mixerWidth <= 0 ? Color(hex: 0xc44545) : JarasTheme.green)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(mixerWidth <= 0 ? "Expandir Track-Mixer" : "Recolher Track-Mixer")
            .jarasHelp(mixerWidth <= 0 ? "Restaurar largura anterior do Track-Mixer" : "Ocultar Track-Mixer")
            MacProjectionRail(show: show)
            Spacer(minLength: 0)
            if desktopExtras {
            Button(action: toggleBarMixer) {
                Image(systemName: "slider.vertical.3")
                    .font(.jarasSystem(size: 16, weight: .semibold))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle((footerMixerOpen || detachedMixer.isVisible) ? JarasTheme.green : JarasTheme.text)
            .accessibilityLabel("Hoz-Mixer")
            .jarasHelp("Hoz-Mixer")
            .contextMenu {
                Button(LocalizedStringKey(detachedMixer.isDetached ? "Dock mixer" : "Undock mixer")) {
                    if detachedMixer.isDetached {
                        detachedMixer.close(); footerMixerOpen = true
                    } else { showDetachedMixer() }
                }
            }
            Button { keyboardOpen.toggle() } label: {
                Image(systemName: "pianokeys")
                    .font(.jarasSystem(size: 16, weight: .semibold))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(keyboardOpen ? JarasTheme.green : JarasTheme.text)
            .accessibilityLabel("Keyboard")
            .jarasHelp("Keyboard")
            .immediateRightClick { keyboardSettings = true }
            .sheet(isPresented: $keyboardSettings) { KeyboardSettingsView() }
            Button {
                VinhetasController.shared.bind(show: show)
                if vinhetasWindow.detached { vinhetasWindow.toggle(show: show) }
                else { vinhetasOpen.toggle() }
            } label: {
                Image(systemName: "square.grid.4x3.fill")
                    .font(.jarasSystem(size: 16, weight: .semibold))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }.foregroundStyle((vinhetasOpen || vinhetasWindow.visible) ? JarasTheme.green : JarasTheme.text)
                .accessibilityLabel("Vinhetas").contextMenu {
                    Button(vinhetasWindow.detached ? "Indexar" : "Desindexar") {
                        if vinhetasWindow.detached { vinhetasWindow.dock(); vinhetasOpen = true }
                        else { vinhetasOpen = false; vinhetasWindow.open(show: show) }
                    }
                }

            Button {
                if detachedParts.isDetached {
                    if detachedParts.isVisible { detachedParts.hide() }
                    else { detachedParts.open(show: show) }
                } else { partsLeftOpen.toggle() }
            } label: {
                PartsListIcon()
                    .font(.jarasSystem(size: 16, weight: .semibold)).frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }.foregroundStyle((partsLeftOpen || detachedParts.isVisible) ? JarasTheme.green : JarasTheme.text)
                .accessibilityLabel("Parts à esquerda").jarasHelp("Parts à esquerda")
                .contextMenu {
                    Button(LocalizedStringKey(detachedParts.isDetached ? "Dock Parts" : "Undock Parts")) {
                        if detachedParts.isDetached { detachedParts.close(); partsLeftOpen = true }
                        else { partsLeftOpen = false; detachedParts.open(show: show) }
                    }
                }
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

private struct DetachedSetlistContent: View {
    let show: ShowController
    let mediaDirectory: URL?
    @Binding var partsOpen: Bool
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        SectionListDock(visible: partsOpen, storageKey: "catlive.parts.detached.width",
                        minimumPrimaryWidth: SidebarWidthLimits.setlist, defaultFraction: 0.42) {
            SongListView(show: show, mediaDirectory: mediaDirectory, partsOpen: partsOpen,
                         toggleParts: { partsOpen.toggle() })
        } sections: { SmoothSeekPanel(show: show) }
            .environment(\.locale, Locale(identifier: language))
            .preferredColorScheme(.dark).foregroundStyle(JarasTheme.text).background(JarasTheme.panel)
    }
}

/// Hover redraws only the divider, without publishing changes to the timeline.
class ResizeHoverIndicatorView: NSView {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
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
            Text("Import audio").font(.jarasHeadline)
            Picker("Placement", selection: $layout) {
                Text("One track per item").tag(AudioDropLayout.separateTracks)
                Text("Same track, in sequence").tag(AudioDropLayout.sameTrack)
                Text("Same track, same start time").tag(AudioDropLayout.stacked)
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
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    init(show: ShowController) {
        self.show = show
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    @State private var editing: Part?
    private func step(_ delta: Int) {
        guard let song = show.current, let region = show.pitchRegion else { return }
        let targets = song.pitchTargets(region)
        show.setRegionPitch(region.id, semitones: min(12, max(-12, region.semitones + delta)), tracks: targets.tracks, groups: targets.groups)
    }
    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "Tuner").font(.jarasSystem(size: 9, weight: .semibold)).foregroundStyle(JarasTheme.text)
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 20, height: 25).contentShape(Rectangle()) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) <= -12).jarasHelp("Lower song pitch")
            Text(String(format: "%dst", show.pitchRegion?.semitones ?? 0))
                .font(.jarasSystem(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
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
            HStack { Text("Pitch · " + region.displayName).font(.jarasHeadline).lineLimit(1); Spacer(); Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain) }
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
    @AppStorage("jaras.keyboard.style") private var style = "default"
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
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(active ? Color(hex: UInt32(black ? blackColor : whiteColor)) : ((black != (style == "black")) ? Color(white: 0.08) : Color(white: 0.89))))
                        if note == 21 || note % 12 == 0 {
                            let label = note == 21 ? "A-1" : "C\(note / 12 - 2)"
                            context.draw(Text(verbatim: label).font(.jarasSystem(size: 9, weight: .medium)).foregroundColor(style == "black" && !active ? .white : .black), at: CGPoint(x: rect.midX, y: rect.maxY - 11))
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
            Text("Keyboard").font(.jarasHeadline)
            ColorPicker("White key highlight", selection: color($whiteColor), supportsOpacity: false)
            ColorPicker("Black key highlight", selection: color($blackColor), supportsOpacity: false)
            AdvancedKeyboardSettings()
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }.font(.jarasBody).padding(24).frame(width: 340).background(JarasTheme.panel)
            #if os(macOS)
            .onExitCommand { dismiss() }
            #endif
    }
}

/// Observes transient modal notices without rebuilding the workspace for them.
private struct ProjectNoticePresenter: View {
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    init(show: ShowController) {
        self.show = show
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    var body: some View {
        Color.clear.allowsHitTesting(false)
            .alert(Text(verbatim: show.modalNotice.map { JarasLocalization.string($0) } ?? ""), isPresented: Binding(
                get: { show.modalNotice != nil }, set: { if !$0 { show.modalNotice = nil } })) {
                Button("OK") { show.modalNotice = nil }.keyboardShortcut(.defaultAction)
            }
    }
}

private struct FooterProjectNameDisplay: View {
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    @ObservedObject var documents: ProjectDocuments
    var titlebar = false
    init(show: ShowController, documents: ProjectDocuments, titlebar: Bool = false) {
        self.show = show; self.documents = documents; self.titlebar = titlebar
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
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
            Text("Recent backups").font(.jarasHeadline)
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
                                    Text(verbatim: Self.displayDate.string(from: backup.date)).font(.jarasCaption).monospacedDigit().foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(documents.busy || TrackRecording.shared.recording || TrackRecording.shared.busy)
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
        }.font(.jarasSystem(size: titlebar ? 11 : 10, weight: titlebar ? .medium : .bold)).lineLimit(1)
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
enum FooterHeightRole { case display, mixer, auxiliary }

/// Shares only native geometry. No publications, project edits or preferences
/// are emitted while a divider is moving.
final class FooterVerticalResizeCoordinator {
    private weak var display: FooterHeightContainerView?
    private weak var mixer: FooterHeightContainerView?
    private var availableHeight: CGFloat = 900
    private var fallbackMixerHeight: CGFloat = 0
    func configure(availableHeight: CGFloat, mixerHeight: CGFloat) {
        self.availableHeight = availableHeight; fallbackMixerHeight = mixerHeight
        display?.refreshHeight()
    }
    func register(_ view: FooterHeightContainerView, role: FooterHeightRole) {
        if role == .display { display = view } else { mixer = view }
        display?.refreshHeight()
    }
    var displayMaximum: CGFloat {
        let mixerHeight = mixer.map { $0.active ? max(273, $0.effectiveHeight) : 0 } ?? fallbackMixerHeight
        return min(161.046875, max(27, availableHeight - mixerHeight))
    }
    func heightChanged(role: FooterHeightRole) { if role == .mixer { display?.refreshHeight() } }
}

struct FooterNativeHeightHost<Content: View>: NSViewRepresentable {
    let storedHeight: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let active: Bool
    let identity: AnyHashable
    let role: FooterHeightRole
    var resizeCoordinator: FooterVerticalResizeCoordinator? = nil
    var displayAvailableHeight: CGFloat? = nil
    var fallbackMixerHeight: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.font) private var font
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openFX) private var openFX
    @Environment(\.editTrackDetails) private var editTrackDetails
    // The native footer needs presentation values, not the containing
    // window's changing placement/safe-area environment on every resize.
    private var environment: EnvironmentValues {
        var value = EnvironmentValues()
        value.locale = locale; value.colorScheme = colorScheme
        value.font = font
        value.controlSize = controlSize; value.isEnabled = isEnabled
        value.layoutDirection = layoutDirection; value.dynamicTypeSize = dynamicTypeSize
        value.displayScale = displayScale
        return value
    }
    func makeNSView(context: Context) -> FooterHeightContainerView { FooterHeightContainerView() }
    func updateNSView(_ view: FooterHeightContainerView, context: Context) {
        if let displayAvailableHeight {
            resizeCoordinator?.configure(availableHeight: displayAvailableHeight, mixerHeight: fallbackMixerHeight)
        }
        view.configure(storedHeight: storedHeight, minimum: minimum, maximum: maximum, active: active,
                       role: role, coordinator: resizeCoordinator)
        view.openFX = openFX; view.editTrackDetails = editTrackDetails
        let environment = self.environment
        view.setContent(identity: identity, environment: environment) {
            // Copying the entire environment hides this nested host's accessible
            // descendants. Forward presentation and actions explicitly instead.
            AnyView(content().environment(\.locale, environment.locale)
                    .environment(\.colorScheme, environment.colorScheme)
                .environment(\.font, environment.font)
                .environment(\.controlSize, environment.controlSize).environment(\.isEnabled, environment.isEnabled)
                .environment(\.layoutDirection, environment.layoutDirection).environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.displayScale, environment.displayScale)
                .environment(\.openFX, { [weak view] in view?.openFX($0, $1) })
                .environment(\.editTrackDetails, { [weak view] in view?.editTrackDetails($0) }))
        }
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterHeightContainerView, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 0), height: nsView.effectiveHeight)
    }
}

final class FooterHeightContainerView: NSView {
    private var storedHeight: CGFloat = 27
    private var minimum: CGFloat = 27
    private var maximum: CGFloat = 161.046875
    private(set) var active = true
    private var role: FooterHeightRole = .display
    private var coordinator: FooterVerticalResizeCoordinator?
    private var preview: CGFloat?
    private var pendingCommit: (previous: CGFloat, value: CGFloat)?
    private var identity: AnyHashable?
    private var environmentKey: String?
    var openFX: (UUID?, String) -> Void = { _, _ in }
    var editTrackDetails: (TrackDetailsEditRequest) -> Void = { _ in }
    private(set) var contentAssignments = 0
    private(set) var effectiveHeight: CGFloat = 27
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        // Keep the retained content at its last real size while this container is hidden.
        // Autoresizing it to height zero reflows every mixer control on close and again on open.
        host.autoresizingMask = []; addSubview(host)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: effectiveHeight) }
    var heightMaximum: CGFloat { role == .display ? min(maximum, coordinator?.displayMaximum ?? maximum) : maximum }
    var heightMinimum: CGFloat { min(minimum, heightMaximum) }
    func configure(storedHeight: CGFloat, minimum: CGFloat, maximum: CGFloat, active: Bool,
                   role: FooterHeightRole, coordinator: FooterVerticalResizeCoordinator?) {
        if let pendingCommit, storedHeight != pendingCommit.previous || !active { self.pendingCommit = nil }
        self.storedHeight = storedHeight; self.minimum = minimum; self.maximum = maximum
        self.active = active; self.role = role; self.coordinator = coordinator
        // A zero-height frame still leaves the complete mixer in AppKit's
        // tracking/layout traversal. Hide the retained native root as well.
        host.isHidden = !active
        if !active { FooterVerticalResizeView.cancelDrags(in: self); preview = nil }
        refreshHeight(); coordinator?.register(self, role: role)
    }
    func setContent(identity: AnyHashable, environment: EnvironmentValues, make: () -> AnyView) {
        // Do not instantiate hundreds of controls before the mixer is opened.
        // An already-mounted root retains its scroll/FX state while hidden.
        guard active else { return }
        // Actions update through the native view without replacing its root.
        let key = "\(environment.locale.identifier)|\(environment.colorScheme)|\(String(describing: environment.font))|\(environment.controlSize)|\(environment.layoutDirection)|\(environment.dynamicTypeSize)|\(environment.isEnabled)|\(environment.displayScale)"
        guard self.identity != identity || environmentKey != key else { return }
        self.identity = identity; environmentKey = key
        host.rootView = make(); contentAssignments += 1
    }
    func refreshHeight() {
        let value = active ? min(heightMaximum, max(heightMinimum, preview ?? pendingCommit?.value ?? storedHeight)) : 0
        guard value != effectiveHeight else { return }
        effectiveHeight = value; invalidateIntrinsicContentSize(); needsLayout = true
        coordinator?.heightChanged(role: role)
    }
    func previewHeight(_ height: CGFloat) { preview = height; refreshHeight() }
    func finishHeight(commit: Bool) {
        if commit { pendingCommit = (storedHeight, effectiveHeight) }
        preview = nil; refreshHeight()
    }
    override func layout() {
        super.layout()
        guard active else { return }
        if host.frame != bounds { host.frame = bounds }
        // AppKit visits this dirty child immediately after the container.
        // Forcing a nested layout here repeats the SwiftUI preference pass
        // during native window resizing.
    }
}

/// Window coordinates preserve the exact drag distance as the footer moves.
struct FooterDisplayResizeInput: NSViewRepresentable {
    let height: CGFloat
    let maximum: CGFloat
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    func makeNSView(context: Context) -> FooterDisplayResizeView { FooterDisplayResizeView() }
    func updateNSView(_ view: FooterDisplayResizeView, context: Context) {
        view.height = height; view.maximum = maximum; view.changed = changed; view.ended = ended
    }
}
class FooterVerticalResizeView: NSView, NativeTimelineInputObserver {
    var height: CGFloat = 27
    var minimum: CGFloat = 27
    var maximum: CGFloat = 900
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat) -> Void)?
    private var origin: (y: CGFloat, height: CGFloat)?
    private weak var dragBoundary: FooterHeightContainerView?
    private var lastHeight: CGFloat?
    private var keyMonitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private(set) var cursorPushed = false
    private static let owners = NSHashTable<FooterVerticalResizeView>.weakObjects()
    var isDragging: Bool { origin != nil }
    private var boundary: FooterHeightContainerView? {
        if let dragBoundary { return dragBoundary }
        var ancestor = superview
        while let view = ancestor {
            if let view = view as? FooterHeightContainerView { return view }
            ancestor = view.superview
        }
        return nil
    }
    @discardableResult static func cancelActiveDrag(in window: NSWindow?) -> Bool {
        guard let view = owners.allObjects.first(where: { $0.window === window && $0.isDragging }) else { return false }
        view.cancelDrag(); return true
    }
    static func cancelDrags(in container: FooterHeightContainerView) {
        for view in owners.allObjects where view.dragBoundary === container { view.cancelDrag() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        if !NativeTimelineInputGate.shared.isBlocked(window), !isHiddenOrHasHiddenAncestor {
            addCursorRect(visibleRect, cursor: .resizeUpDown)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, !isHiddenOrHasHiddenAncestor,
              !NativeTimelineInputGate.shared.isBlocked(window), boundary?.active != false else { return }
        dragBoundary = boundary
        origin = (event.locationInWindow.y, boundary?.effectiveHeight ?? height)
        lastHeight = origin?.height
        NotificationCenter.default.post(name: Notification.Name("CatLiveFooterResizeBegan"), object: window)
        NSCursor.resizeUpDown.push(); cursorPushed = true
        if let window, !(window.firstResponder is TimelineGridKeyboardTarget) { window.makeFirstResponder(self) }
    }
    private func resizedHeight(_ event: NSEvent) -> CGFloat? {
        guard let origin else { return nil }
        let upper = boundary?.heightMaximum ?? max(minimum, maximum)
        let lower = boundary?.heightMinimum ?? minimum
        return min(upper, max(lower, origin.height + (event.locationInWindow.y - origin.y) / max(0.01, abs(convert(NSSize(width: 1, height: 1), to: nil).height))))
    }
    private func apply(_ value: CGFloat) {
        guard lastHeight != value else { return }
        lastHeight = value
        CATransaction.begin(); CATransaction.setDisableActions(true)
        boundary?.previewHeight(value); changed?(value)
        window?.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let value = resizedHeight(event) else { return }
        apply(value)
    }
    override func mouseUp(with event: NSEvent) {
        guard let value = resizedHeight(event) else { return }
        apply(value); origin = nil
        boundary?.finishHeight(commit: true); dragBoundary = nil; finishCursor(); ended?(value)
    }
    func cancelDrag() {
        guard origin != nil else { return }
        origin = nil; lastHeight = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let container = boundary
        container?.finishHeight(commit: false)
        (container?.window ?? window)?.contentView?.layoutSubtreeIfNeeded(); dragBoundary = nil
        CATransaction.commit(); finishCursor()
    }
    private func finishCursor() {
        NotificationCenter.default.post(name: Notification.Name("CatLiveFooterResizeEnded"), object: window)
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        window?.invalidateCursorRects(for: self)
    }
    func timelineInputGateChanged(blocked: Bool) { if blocked { cancelDrag() }; window?.invalidateCursorRects(for: self) }
    func timelineActiveResizeCancelled() -> Bool {
        guard isDragging else { return false }
        cancelDrag(); return true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if window !== newWindow { cancelDrag() }; super.viewWillMove(toWindow: newWindow) }
    override func viewDidHide() { super.viewDidHide(); cancelDrag() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        Self.owners.remove(self)
        guard let window else { return }
        Self.owners.add(self); NativeTimelineInputGate.shared.add(self)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, self.isDragging else { return event }
            self.cancelDrag(); return nil
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.cancelDrag() })
        }
    }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        if cursorPushed { NSCursor.pop() }
    }
}
final class FooterDisplayResizeView: FooterVerticalResizeView {}

struct FooterMixerResizeInput: NSViewRepresentable {
    let height: CGFloat
    let maximum: CGFloat
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    func makeNSView(context: Context) -> FooterMixerResizeView { FooterMixerResizeView() }
    func updateNSView(_ view: FooterMixerResizeView, context: Context) {
        view.height = height; view.minimum = 273; view.maximum = maximum; view.changed = changed; view.ended = ended
    }
}
final class FooterMixerResizeView: FooterVerticalResizeView {
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(hovered ? 0.12 : 0.04).setFill(); bounds.fill()
        (hovered ? NSColor(srgbRed: 105/255, green: 237/255, blue: 145/255, alpha: 1) : NSColor(srgbRed: 185/255, green: 185/255, blue: 185/255, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: (bounds.width - 48) / 2, y: (bounds.height - 2) / 2, width: 48, height: 2), xRadius: 1, yRadius: 1).fill()
    }
}
#else
final class FooterVerticalResizeCoordinator {}
#endif
