import SwiftUI
import UniformTypeIdentifiers
import Combine
#if os(iOS)
import UIKit
#endif
enum SidebarWidthLimits {
    #if os(macOS)
    static let trackMixer: CGFloat = 283.3671875
    static let trackMixerDefault = trackMixer
    #else
    static let trackMixer: CGFloat = 277.921875
    static let nativeTrackMixer: CGFloat = 327.921875
    static let nativeTrackMixerMinimum: CGFloat = nativeTrackMixer - 69
    static let nativeTrackMixerPatchThreshold: CGFloat = nativeTrackMixer - 14
    static let nativeTrackMixerEnvelopeThreshold: CGFloat = nativeTrackMixer - 28
    static let trackMixerDefault = trackMixer
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

    init(requestedWidth: CGFloat, maximum: CGFloat, showsIcons: Bool, extraWidth: CGFloat = 0) {
        bodyWidth = requestedWidth <= 0 ? 0 : min(maximum, max(SidebarWidthLimits.trackMixer, requestedWidth))
        iconExtension = (showsIcons ? Self.iconWidth + Self.spacing : 0) + extraWidth
    }

    func storedWidth(for total: CGFloat) -> CGFloat { max(0, total - iconExtension) }
}
private struct FooterDisplayIdentity: Hashable {
    let show: ObjectIdentifier
    let theme: JarasInterfaceTheme
    let showsSetlist: Bool
    let showsNotices: Bool
}
private struct WorkspaceProjectIdentity: Hashable {
    let project: UUID
    let document: URL?
    let missingAudioPaths: Set<String>
    let remotePresentation: Bool
    let midiPreviewDetached: Bool
    let padsDetached: Bool
    let setlistPlacement: SetlistPlacement
    let interfaceTheme: JarasInterfaceTheme
}
private struct WorkspaceSetlistIdentity: Hashable {
    let controller: ObjectIdentifier
    let project: UUID
    let document: URL?
    let theme: JarasInterfaceTheme
}
#if os(macOS)
private final class DesktopPerformanceDocks: ObservableObject {
    @Published var keyboardOpen = false
    let midiPreview = MIDIPreviewVisibility()
    @Published var focusOpen = false
}
private let desktopLibraryVisibilityKey = "jaras.layout.library.open"
#endif
#if os(macOS)
/// Commands read and write the saved dimension directly. Only the regions of
/// the window whose layout depends on it subscribe to the preference.
@MainActor @propertyWrapper private struct SidebarPreference<Value: Hashable> {
    let preference: WorkspacePreference<Value>
    init(wrappedValue: Double, _ key: String, store: UserDefaults) where Value == Double {
        preference = WorkspacePreference(wrappedValue: wrappedValue, key, store: store)
    }
    init(wrappedValue: Bool, _ key: String, store: UserDefaults) where Value == Bool {
        preference = WorkspacePreference(wrappedValue: wrappedValue, key, store: store)
    }
    var wrappedValue: Value {
        get { preference.wrappedValue }
        nonmutating set { preference.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { preference.projectedValue }
    func observing<Content: View>(@ViewBuilder _ content: @escaping (Value) -> Content) -> some View {
        SidebarPreferenceContent(preference, content: content)
    }
}

private struct SidebarPreferenceContent<Value: Hashable, Content: View>: View {
    @WorkspacePreference private var value: Value
    let content: (Value) -> Content
    init(_ preference: WorkspacePreference<Value>, @ViewBuilder content: @escaping (Value) -> Content) {
        _value = preference
        self.content = content
    }
    var body: some View { content(value) }
}
private final class DesktopRightPanelSelection: ObservableObject {
    enum Panel { case notes, samplers }
    @Published var panel: Panel?
    func toggle(_ requested: Panel) { panel = panel == requested ? nil : requested }
}
private struct DesktopRightPanelContent<Content: View>: View {
    @ObservedObject var selection: DesktopRightPanelSelection
    @ViewBuilder var content: (DesktopRightPanelSelection.Panel?) -> Content
    var body: some View { content(selection.panel) }
}
private struct DesktopSidebarWidths<Content: View>: View {
    @WorkspacePreference private var mixer: Double
    @WorkspacePreference private var setlist: Double
    @WorkspacePreference private var restore: Double
    @WorkspacePreference private var parts: Bool
    let content: (Double, Double, Double, Bool) -> Content

    init(mixer: SidebarPreference<Double>, setlist: SidebarPreference<Double>, restore: SidebarPreference<Double>,
         parts: SidebarPreference<Bool>,
         @ViewBuilder content: @escaping (Double, Double, Double, Bool) -> Content) {
        _mixer = mixer.preference
        _setlist = setlist.preference
        _restore = restore.preference
        _parts = parts.preference
        self.content = content
    }

    var body: some View { content(mixer, setlist, restore, parts) }
}
#else
private typealias SidebarPreference<Value> = AppStorage<Value>
#endif

struct MainView: View {
    @Environment(\.gridInteractionBlocked) private var workspaceInputBlocked
    @State private var recordingError = ""
    @ObservedObject private var mappings = ControlMappings.shared
    let show: ShowController
    var remotePresentation = false
    let auth: AuthService
    let backend: any BackendClient
    @ObservedObject var documents: ProjectDocuments
    private let showProjects: (Bool) -> Void
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
    @State private var fullLyricsTarget: FullLyricsTarget?
    @State private var lastObservedProjectID: UUID?
    @State private var presentedSessionID: UUID?
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @WorkspacePreference("jaras.language") private var language = "en"
    #if os(macOS)
    private var footerMixerPreferenceKey: String { remotePresentation ? "jaras.remote.layout.mixer.open" : "jaras.layout.mixer.open" }
    private var footerMixerOpen: Bool {
        get { WorkspaceLayoutPreferences.storage.bool(forKey: footerMixerPreferenceKey) }
        nonmutating set { WorkspaceLayoutPreferences.storage.set(newValue, forKey: footerMixerPreferenceKey) }
    }
    private var libraryOpen: Bool {
        get { WorkspaceLayoutPreferences.storage.bool(forKey: desktopLibraryVisibilityKey) }
        nonmutating set { WorkspaceLayoutPreferences.storage.set(newValue, forKey: desktopLibraryVisibilityKey) }
    }
    @State private var performanceDockState = DesktopPerformanceDocks()
    private var focusOpen: Bool {
        get { performanceDockState.focusOpen }
        nonmutating set { if newValue != focusOpen { performanceDockState.focusOpen = newValue } }
    }
    private var midiPreviewOpen: Bool {
        get { performanceDockState.midiPreview.active }
        nonmutating set { performanceDockState.midiPreview.setActive(newValue) }
    }
    @State private var rightPanel = DesktopRightPanelSelection()
    @State private var proNotesTab = WorkspaceNotesDock.Tab.notes
    @StateObject private var midiPreviewWindow = RecordingPianoWindow()
    @StateObject private var detachedMixer = DetachedMixerWindow()
    @StateObject private var detachedParts = DetachedPartsWindow()
    @StateObject private var detachedSetlist = DetachedSetlistWindow()
    @State private var toolWindows = WorkspaceToolWindows()
    @State private var timelineToolbar = DesktopTimelineToolbar()
    @State private var showingFileExport = false
    @State private var showingProjectShare = false
    #else
    @WorkspacePreference("jaras.layout.mixer.open", store: WorkspaceLayoutPreferences.storage) private var footerMixerOpen = false
    #endif
    #if os(macOS)
    private var keyboardOpen: Bool {
        get { performanceDockState.keyboardOpen }
        nonmutating set { if newValue != keyboardOpen { performanceDockState.keyboardOpen = newValue } }
    }
    #else
    @State private var keyboardOpen = false
    #endif
    #if os(macOS)
    private var vinhetasOpen: Bool {
        get { WorkspaceLayoutPreferences.storage.bool(forKey: "jaras.vinhetas.visible") }
        nonmutating set {
            if newValue != vinhetasOpen { WorkspaceLayoutPreferences.storage.set(newValue, forKey: "jaras.vinhetas.visible") }
        }
    }
    @StateObject private var vinhetasWindow = VinhetasWindow()
    #endif
    @WorkspacePreference("jaras.layout.parts.open", store: WorkspaceLayoutPreferences.storage) private var partsLeftOpen = false
    @WorkspacePreference("jaras.layout.parts.horizontal", store: WorkspaceLayoutPreferences.storage) private var partsLeftHorizontal = false
    @WorkspacePreference("jaras.layout.parts.heightScale", store: WorkspaceLayoutPreferences.storage) private var partsHeightScale = 1.0
    @SidebarPreference("jaras.layout.partsRight.open", store: WorkspaceLayoutPreferences.storage) private var partsRightOpen = false
    @WorkspacePreference("jaras.layout.setlist.placement", store: WorkspaceLayoutPreferences.storage) private var setlistPlacement: SetlistPlacement = .right
    @WorkspacePreference("jaras.layout.setlist.dockSide", store: WorkspaceLayoutPreferences.storage) private var setlistDockPlacement: SetlistPlacement = .right
    @State private var keyboardSettings = false
    @WorkspacePreference("jaras.footerMixerHeight", store: WorkspaceLayoutPreferences.storage) private var footerMixerHeight = Double(FooterHorizontalMixer.minimumDockHeight)
    @State private var footerResizeCoordinator = FooterVerticalResizeCoordinator()
    private func maximumFooterHeight(workspaceHeight: CGFloat) -> CGFloat {
        min(161.046875, max(27, workspaceHeight - 150 - (keyboardOpen ? 108 : 0)
            - (footerMixerOpen ? min(723.55859375, max(FooterHorizontalMixer.minimumDockHeight, footerMixerHeight)) : 0)))
    }
    @SidebarPreference("jaras.trackColumnWidth", store: WorkspaceLayoutPreferences.storage) private var mixerWidth = Double(SidebarWidthLimits.trackMixerDefault)
    @SidebarPreference("jaras.trackColumnRestoreWidth", store: WorkspaceLayoutPreferences.storage) private var mixerRestoreWidth = Double(SidebarWidthLimits.trackMixerDefault)
    #if os(macOS)
    @State private var setlistScrollController = SidebarScrollController()
    @WorkspacePreference(TrackMixerVU.preferenceKey) private var showsTrackVU = false
    #endif
    @SidebarPreference("jaras.setlistWidth", store: WorkspaceLayoutPreferences.storage) private var setlistWidth = Double(SidebarWidthLimits.setlistDefault)
    @SidebarPreference("jaras.setlistRestoreWidth", store: WorkspaceLayoutPreferences.storage) private var setlistRestoreWidth = 240.0
    init(show: ShowController, remotePresentation: Bool = false, auth: AuthService, backend: any BackendClient, documents: ProjectDocuments,
         showProjects: @escaping (Bool) -> Void = { _ in }) {
        self.show = show; self.remotePresentation = remotePresentation
        self.auth = auth; self.backend = backend; self.documents = documents; self.showProjects = showProjects
        let prefix = remotePresentation ? "jaras.remote." : "jaras."
        #if !os(macOS)
        _footerMixerOpen = WorkspacePreference(wrappedValue: false, prefix + "layout.mixer.open", store: WorkspaceLayoutPreferences.storage)
        #endif
        _partsLeftOpen = WorkspacePreference(wrappedValue: false, prefix + "layout.parts.open", store: WorkspaceLayoutPreferences.storage)
        _partsRightOpen = SidebarPreference(wrappedValue: false, prefix + "layout.partsRight.open", store: WorkspaceLayoutPreferences.storage)
        _setlistPlacement = WorkspacePreference(wrappedValue: .right, prefix + "layout.setlist.placement", store: WorkspaceLayoutPreferences.storage)
        _setlistDockPlacement = WorkspacePreference(wrappedValue: .right, prefix + "layout.setlist.dockSide", store: WorkspaceLayoutPreferences.storage)
        _mixerWidth = SidebarPreference(wrappedValue: remotePresentation ? 280 : Double(SidebarWidthLimits.trackMixerDefault), prefix + "trackColumnWidth", store: WorkspaceLayoutPreferences.storage)
        _mixerRestoreWidth = SidebarPreference(wrappedValue: remotePresentation ? 280 : Double(SidebarWidthLimits.trackMixerDefault), prefix + "trackColumnRestoreWidth", store: WorkspaceLayoutPreferences.storage)
        _setlistWidth = SidebarPreference(wrappedValue: remotePresentation ? 370 : Double(SidebarWidthLimits.setlistDefault), prefix + "setlistWidth", store: WorkspaceLayoutPreferences.storage)
        _setlistRestoreWidth = SidebarPreference(wrappedValue: remotePresentation ? 370 : 240, prefix + "setlistRestoreWidth", store: WorkspaceLayoutPreferences.storage)
    }
    private func toggleBarMixer() {
        #if os(macOS)
        if detachedMixer.isDetached {
            if detachedMixer.isVisible { detachedMixer.hide() }
            else { showDetachedMixer() }
            return
        }
        if !footerMixerOpen { activatePerformancePanel(.mixer) }
        #endif
        footerMixerOpen.toggle()
    }
    private func toggleMixer() {
        Self.togglePanel(width: $mixerWidth, restore: $mixerRestoreWidth, minimum: SidebarWidthLimits.trackMixer)
    }
    private func openSettings(_ section: SettingsView.Section? = nil) {
        #if os(macOS)
        toolWindows.openSettings(auth: auth, show: show, backend: backend, section: section)
        #else
        panel = section == .audio ? .audioSettings : .settings
        #endif
    }
    private func openAdvanced() {
        #if os(macOS)
        toolWindows.openAdvanced(show: show, documents: documents)
        #endif
    }
    private var setlistCollapsed: Bool { isSetlistCollapsed(at: setlistWidth) }
    private func isSetlistCollapsed(at width: Double) -> Bool {
        #if os(macOS)
        if setlistPlacement == .detached { return !detachedSetlist.isVisible }
        #endif
        return width <= 0
    }
    private func toggleSetlist() {
        #if os(macOS)
        if setlistCollapsed && rightPanel.panel == .notes { proNotesTab = .notes }
        #endif
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
        if rightPanel.panel == .notes { proNotesTab = .notes }
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
    private func setRightPartsOpen(_ visible: Bool) {
        if visible && partsLeftHorizontal { partsLeftOpen = false }
        partsRightOpen = visible
    }
    private func toggleRightParts() { setRightPartsOpen(!partsRightOpen) }
    private func setLeftPartsOpen(_ visible: Bool) {
        if visible && partsLeftHorizontal {
            #if os(macOS)
            activatePerformancePanel(.parts)
            #endif
            partsRightOpen = false
        }
        #if os(macOS)
        if visible && !partsLeftHorizontal { focusOpen = false }
        #endif
        partsLeftOpen = visible
    }
    #if os(macOS)
    private enum PerformancePanel {
        case parts, mixer, pads, midiPreview, keyboard
    }

    private func activatePerformancePanel(_ panel: PerformancePanel) {
        if panel != .parts && partsLeftHorizontal && partsLeftOpen { partsLeftOpen = false }
        if panel != .mixer {
            if footerMixerOpen { footerMixerOpen = false }
            if detachedMixer.isVisible { detachedMixer.hide() }
        }
        if panel != .pads { closePads() }
        if panel != .midiPreview && panel != .keyboard {
            midiPreviewOpen = false
            if midiPreviewWindow.visible { midiPreviewWindow.hide() }
            keyboardOpen = false
        }
    }

    private func closePads() {
        if vinhetasOpen { vinhetasOpen = false }
        if vinhetasWindow.visible { vinhetasWindow.hide() }
    }

    private func toggleFocus() {
        setFocusOpen(!focusOpen)
    }
    private func setFocusOpen(_ visible: Bool) {
        focusOpen = visible
        if visible && !partsLeftHorizontal {
            if partsLeftOpen { partsLeftOpen = false }
            if detachedParts.isVisible { detachedParts.hide() }
        }
    }
    private func showLeftDetachedParts() {
        focusOpen = false
        detachedParts.open(show: show)
    }
    private func restoreGlobalPanels() {
        guard !remotePresentation, DesktopProjectTabs.shared.isForeground(show) else { return }
        let defaults = WorkspaceLayoutPreferences.storage
        if partsLeftOpen && !partsLeftHorizontal { setLeftPartsOpen(true) }
        if defaults.bool(forKey: "jaras.layout.vinhetas.detached") {
            let visible = defaults.object(forKey: "jaras.layout.vinhetas.visible") as? Bool ?? true
            vinhetasOpen = false; vinhetasWindow.open(show: show)
            if !visible { vinhetasWindow.hide() }
        }
        if defaults.bool(forKey: "jaras.layout.mixer.detached") {
            let visible = defaults.object(forKey: "jaras.layout.mixer.visible") as? Bool ?? true
            showDetachedMixer(activate: false)
            if !visible { detachedMixer.hide() }
        }
        if footerMixerOpen || detachedMixer.isVisible { activatePerformancePanel(.mixer) }
        else if partsLeftHorizontal && partsLeftOpen { setLeftPartsOpen(true) }
        else if vinhetasOpen || vinhetasWindow.visible { activatePerformancePanel(.pads) }
        if !partsLeftHorizontal, defaults.bool(forKey: "jaras.layout.parts.detached") {
            let visible = defaults.object(forKey: "jaras.layout.parts.visible") as? Bool ?? true
            partsLeftOpen = false; detachedParts.open(show: show)
            if !visible || focusOpen { detachedParts.hide() }
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
                                   partsOpen: Binding(get: { partsRightOpen }, set: setRightPartsOpen))
                .environment(\.multitrackAction, documents.openMultitrackExport)
        }
    }
    private func showDetachedMixer(activate: Bool = true) {
        if activate { activatePerformancePanel(.mixer) }
        footerMixerOpen = false
        detachedMixer.open(show: show, openFX: openDesktopFX, editTrack: { request in
            guard request.project == show.snapshot.project.id else { return }
            trackEdit = request
        })
    }
    private func openDesktopFX(_ track: UUID?, _ effect: String) {
        if effect == "Chain" {
            if let track { show.setMixerTrackSelection([track], anchor: track) }
            setFocusOpen(true)
        } else if effect == "Library" {
            libraryOpen = true
        } else {
            FXWindows.shared.open(show: show, track: track, effect: effect, language: language)
        }
    }
    #endif
    private static func togglePanel(width: Binding<Double>, restore: Binding<Double>, minimum: CGFloat) {
        if width.wrappedValue > 0 {
            if restore.wrappedValue != width.wrappedValue { restore.wrappedValue = width.wrappedValue }
            width.wrappedValue = 0
        }
        else { width.wrappedValue = max(Double(minimum), restore.wrappedValue) }
    }
    var body: some View {
        // Window geometry changes the workspace's available height, not the
        // transport actions or tool rail. Keep those values outside the reader
        // so a resize does not recreate their closures and invalidate every
        // control. Their own layouts still receive the current proposed size.
        #if os(macOS)
        let share: (() -> Void)? = shareProject
        let notesAction = {
            if rightPanel.panel != .notes { proNotesTab = .notes }
            rightPanel.toggle(.notes)
        }
        let samplersAction = { rightPanel.toggle(.samplers) }
        #else
        let share: (() -> Void)? = nil
        let notesAction: () -> Void = {}, samplersAction: () -> Void = {}
        #endif
        #if os(macOS)
        let masterWorkspaceButtons: AnyView? = desktopExtras ? AnyView(desktopFileButton.buttonStyle(.plain)) : nil
        let masterFooterButtons: AnyView? = desktopExtras ? AnyView(desktopMasterFooterButtons) : nil
        let timerReadout: AnyView? = desktopExtras ? AnyView(desktopTimerReadout) : nil
        let statusControls: AnyView? = desktopExtras ? AnyView(desktopStatusControls) : nil
        #else
        let masterWorkspaceButtons: AnyView? = nil
        let masterFooterButtons: AnyView? = nil
        let timerReadout: AnyView? = nil
        let statusControls: AnyView? = nil
        #endif
        func makeTransport(mixerCollapsed: Bool, setlistCollapsed: Bool, notesOpen: Bool = false, samplersOpen: Bool = false) -> TransportView {
            TransportView(show: show, documents: documents, remotePresentation: remotePresentation,
            mediaDirectory: documents.currentURL?.deletingLastPathComponent(),
            toggleNavigation: openProjects,
            mixerCollapsed: mixerCollapsed, setlistCollapsed: setlistCollapsed,
            toggleMixer: toggleMixer, toggleSetlist: toggleSetlist,
            setlistPlacement: setlistPlacement, placeSetlist: placeSetlist,
            shareProject: share, proNotesOpen: notesOpen, proSamplersOpen: samplersOpen,
            toggleProNotes: notesAction, toggleProSamplers: samplersAction,
            masterWorkspaceButtons: masterWorkspaceButtons, masterFooterButtons: masterFooterButtons,
            timerReadout: timerReadout, statusControls: statusControls)
        }
        #if os(macOS)
        let transport = _mixerWidth.observing { width in
            _setlistWidth.observing { setlist in
                DesktopRightPanelContent(selection: rightPanel) { panel in
                    makeTransport(mixerCollapsed: width <= 0, setlistCollapsed: isSetlistCollapsed(at: setlist),
                                  notesOpen: panel == .notes, samplersOpen: panel == .samplers)
                }
            }
        }
        #else
        let transport = makeTransport(mixerCollapsed: mixerWidth <= 0, setlistCollapsed: setlistCollapsed)
        #endif
        let editor = VStack(spacing: 0) {
            #if os(macOS)
            if desktopExtras && documents.projectTabCount > 1 { DesktopProjectTabBar().frame(height: 24) }
            if remotePresentation { desktopToolBar.fixedSize(horizontal: false, vertical: true) }
            #endif
            GeometryReader { geometry in
                workspace(width: geometry.size.width, height: geometry.size.height, transport: transport)
            }
        }
        #if os(macOS)
        return presentWorkspace(editor.environment(\.desktopTimelineToolbar, timelineToolbar))
            .workspaceEditor("Export", isPresented: $showingFileExport) {
                AudioExportView(project: show.snapshot.project, song: show.current, mediaDirectory: documents.currentURL?.deletingLastPathComponent())
            }
            .sheet(isPresented: $showingProjectShare) { PortableProjectExportView(documents: documents) }
            .background(RegionBPMHost(show: show, documents: documents))
        #else
        return presentWorkspace(editor)
        #endif
    }
    #if os(macOS)
    private func shareProject() {
        guard documents.ready, !documents.busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        showingProjectShare = true
    }
    @ViewBuilder private func timelineDocks(mixerLimit: CGFloat, horizontalPartsVisible: Bool) -> some View {
        if desktopExtras {
            if horizontalPartsVisible {
                HorizontalPartsDock(heightScale: $partsHeightScale) {
                    SmoothSeekPanel(show: show, placement: .left, horizontal: true)
                }
            }
            DesktopHozMixerDock(show: show, maximumHeight: mixerLimit, resizeCoordinator: footerResizeCoordinator)
        }
    }
    @ViewBuilder private func performanceDocks(keyboardOpen: Bool, padsOpen: Bool) -> some View {
        if desktopExtras {
            if keyboardOpen { FooterPianoKeyboard().frame(height: 108) }
            FooterNativeHeightHost(storedHeight: 240, minimum: 240, maximum: 240,
                active: padsOpen,
                identity: AnyHashable(ObjectIdentifier(show)), role: .auxiliary) {
                VinhetasPanel(createTrack: { _ = show.createVinhetasTrack() })
                    .onAppear { VinhetasController.shared.bind(show: show) }
            }
        }
    }
    #endif
    private func workspace<Transport: View>(width workspaceWidth: CGFloat, height workspaceHeight: CGFloat, transport: Transport) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                #if os(macOS)
                transport.frame(height: TransportView.desktopHeight(width: workspaceWidth, remote: remotePresentation,
                                                                     multipleProjects: documents.projectTabCount > 1))
                if !remotePresentation {
                    DesktopTimelineEditingBar(show: show, mixerButtons: AnyView(desktopMixerButtons),
                        workspaceButtons: AnyView(desktopEditingWorkspaceButtons), liveButtons: AnyView(desktopEditingLiveButtons))
                }
                #else
                transport
                #endif
                    #if os(macOS)
                    GeometryReader { geometry in
                        DesktopSidebarWidths(mixer: _mixerWidth, setlist: _setlistWidth, restore: _setlistRestoreWidth, parts: _partsRightOpen) {
                            trackColumnWidth, listWidth, restoreWidth, rightPartsVisible in
                        DesktopRightPanelContent(selection: rightPanel) { panel in
                        let vuWidth = showsTrackVU && desktopExtras ? TrackMixerVU.columnWidth : 0
                        let preferredMixer = TrackMixerColumnGeometry(requestedWidth: CGFloat(trackColumnWidth),
                            maximum: 486.5 - vuWidth, showsIcons: false, extraWidth: vuWidth).totalWidth
                        let minimumGridWidth: CGFloat = desktopExtras ? 84 : 260
                        let gridReserve = minimumGridWidth + TimelineVerticalBar.width + 6
                        DesktopRightDockEditorWidth(enabled: desktopExtras, show: show, docks: performanceDockState,
                            baseWidth: preferredMixer + gridReserve) { minimumEditorWidth in
                        SectionListDock(visible: panel != nil, storageKey: "catlive.proDock.width",
                                        minimumPrimaryWidth: max(700, minimumEditorWidth + (listWidth > 0 ? SidebarWidthLimits.setlist : 0)),
                                        defaultFraction: 0.22, enforcesMinimumPrimaryWidth: true,
                                        maximumSidebarWidth: 558.80078125,
                                        usesNativeResizeHandle: true, retainsTrailingPane: true) {
                        SectionListDock(visible: rightPartsVisible && listWidth > 0 && setlistPlacement != .detached,
                            storageKey: "catlive.sections.width", minimumPrimaryWidth: max(620, minimumEditorWidth + SidebarWidthLimits.setlist),
                            defaultFraction: 0.22, enforcesMinimumPrimaryWidth: true, retainedSectionID: ObjectIdentifier(show)) {
                        NativeWorkspaceSplit(width: CGFloat(listWidth), restoreWidth: CGFloat(restoreWidth),
                            minimum: SidebarWidthLimits.setlist, minimumTimelineWidth: max(420, minimumEditorWidth),
                            scrollController: setlistScrollController,
                            sidebarLeading: setlistPlacement == .left, sidebarDetached: setlistPlacement == .detached,
                            contentIdentity: WorkspaceProjectIdentity(project: show.snapshot.project.id, document: documents.currentURL,
                                missingAudioPaths: documents.missingAudioPaths, remotePresentation: remotePresentation,
                                midiPreviewDetached: midiPreviewWindow.detached, padsDetached: vinhetasWindow.detached,
                                setlistPlacement: setlistPlacement,
                                interfaceTheme: interfaceTheme),
                            trailingContentIdentity: WorkspaceSetlistIdentity(controller: ObjectIdentifier(show),
                                project: show.snapshot.project.id, document: documents.currentURL,
                                theme: interfaceTheme),
                            onToggle: toggleSetlist, onEnd: { finalWidth in
                                if finalWidth > 0 {
                                    setlistRestoreWidth = finalWidth
                                    if rightPanel.panel == .notes { proNotesTab = .notes }
                                }
                                setlistWidth = finalWidth
                            }) {
                            DesktopPartsLayout(remote: remotePresentation, detached: detachedParts) { leftParts, bottomParts, partsHeight in
                            GeometryReader { editing in
                                DesktopWorkspaceDocks(show: show, desktopExtras: desktopExtras,
                                    availableHeight: editing.size.height,
                                    performanceDockState: performanceDockState,
                                    midiPreviewDetached: midiPreviewWindow.detached, padsDetached: vinhetasWindow.detached,
                                    partsHeight: partsHeight,
                                    resizeCoordinator: footerResizeCoordinator
                                ) { panels, preview in
                                    HStack(alignment: .top, spacing: 0) {
                                        if desktopExtras {
                                            let available = max(0, editing.size.width - panels.focusWidth - preferredMixer - gridReserve)
                                            DesktopLibraryDock(theme: interfaceTheme, show: show, available: available)
                                            RetainedWorkspacePane(width: panels.focusWidth, visible: panels.focusWidth > 0,
                                                identity: AnyHashable(ObjectIdentifier(show))) {
                                                FooterHorizontalMixer(show: show, focused: true)
                                            }
                                            .frame(width: panels.focusWidth, alignment: .leading)
                                            .accessibilityHidden(panels.focusWidth == 0)
                                        }
                                        VStack(spacing: 0) {
                                            VStack(spacing: 0) {
                                                SectionListDock(visible: leftParts, storageKey: "catlive.parts.left.width",
                                                                minimumPrimaryWidth: preferredMixer + gridReserve,
                                                                defaultFraction: 0.24, leading: true, enforcesMinimumPrimaryWidth: true, retainedSectionID: ObjectIdentifier(show)) {
                                                    VStack(spacing: 0) {
                                                        TimelineGridView(show: show, documents: documents, remotePresentation: remotePresentation,
                                                                         isSetlistVisible: { !setlistCollapsed }, toggleMixer: toggleMixer).equatable()
                                                            .environment(\.minimumTimelineBodyWidth, minimumGridWidth)
                                                            .foregroundStyle(JarasTheme.text)
                                                        timelineDocks(mixerLimit: panels.spareHeight, horizontalPartsVisible: bottomParts)
                                                    }
                                                } sections: { SmoothSeekPanel(show: show, placement: .left) }
                                            }.frame(maxHeight: .infinity, alignment: .top).clipped()
                                            preview
                                        }
                                    }
                                } lowerDocks: { keyboardOpen, padsOpen in
                                    performanceDocks(keyboardOpen: keyboardOpen, padsOpen: padsOpen)
                                }
                            }
                            }
                        } trailing: {
                            _partsRightOpen.observing { visible in
                                SongListView(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(),
                                    sidebarScrollController: setlistScrollController, partsOpen: visible, toggleParts: toggleRightParts)
                                    .environment(\.multitrackAction, documents.openMultitrackExport)
                                    .foregroundStyle(JarasTheme.text)
                            }
                        }
                        } sections: { SmoothSeekPanel(show: show) }
                        } sections: {
                            ZStack {
                                DesktopSamplerPane(theme: interfaceTheme, show: show, visible: panel == .samplers)
                                GeometryReader { geometry in
                                    RetainedWorkspacePane(width: geometry.size.width, visible: panel == .notes,
                                        identity: AnyHashable(WorkspaceDockContentIdentity(project: show.snapshot.project.id,
                                            controller: ObjectIdentifier(show), theme: interfaceTheme))) {
                                        WorkspaceNotesDock(theme: interfaceTheme, show: show, tab: $proNotesTab) {
                                            if !setlistCollapsed { toggleSetlist() }
                                        }
                                    }
                                }.allowsHitTesting(panel == .notes).accessibilityHidden(panel != .notes)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                        }
                        }
                    }
                    #else
                    SectionListDock(visible: partsRightOpen, storageKey: "catlive.local.sections.width",
                                    minimumPrimaryWidth: 480, defaultFraction: 0.22) {
                        HStack(spacing: 1) {
                            TimelineGridView(show: show, documents: documents, remotePresentation: remotePresentation, toggleMixer: toggleMixer).equatable()
                            SongListView(show: show, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), partsOpen: partsRightOpen,
                                toggleParts: toggleRightParts).frame(width: 220)
                        }
                    } sections: {
                        SmoothSeekPanel(show: show)
                    }
                    #endif
                #if os(macOS)
                _setlistWidth.observing { width in
                let showsFooterSetlist = !isSetlistCollapsed(at: width)
                DesktopFooterDockInputs(docks: performanceDockState, mixerKey: footerMixerPreferenceKey) { keyboardOpen, mixerOpen, footerHeight in
                FooterNativeHeightHost(storedHeight: showsFooterSetlist ? CGFloat(footerHeight.wrappedValue) : 27,
                    minimum: 27, maximum: showsFooterSetlist ? 161.046875 : 27,
                    active: true, identity: AnyHashable(FooterDisplayIdentity(show: ObjectIdentifier(show), theme: interfaceTheme,
                        showsSetlist: showsFooterSetlist, showsNotices: !remotePresentation)), role: .display,
                    resizeCoordinator: footerResizeCoordinator,
                    displayAvailableHeight: workspaceHeight - 150 - (keyboardOpen ? 108 : 0),
                    fallbackMixerHeight: mixerOpen ? min(723.55859375, max(FooterHorizontalMixer.minimumDockHeight, footerMixerHeight)) : 0) {
                    GeometryReader { geometry in
                        HStack(spacing: 14) {
                            if showsFooterSetlist {
                                FooterPlaylistDisplay(show: show, scalesToAvailableHeight: true, showsNotices: !remotePresentation)
                                    .frame(maxWidth: .infinity)
                                    .overlay(FooterDisplayResizeInput(height: geometry.size.height, maximum: maximumFooterHeight(workspaceHeight: workspaceHeight),
                                        changed: { _ in }, ended: { footerHeight.wrappedValue = $0 }))
                            }
                        }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).frame(height: geometry.size.height)
                        .overlay {
                            if !showsFooterSetlist && !remotePresentation {
                                FooterInformationDisplay(show: show, embedded: true, alignment: .center)
                                    .padding(.horizontal, 140)
                            }
                        }
                    }.font(.jarasSystem(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).background(interfaceTheme.panel)
                }
                }
                }
                #else
                GeometryReader { geometry in
                    let displayWidth = min(300, max(0, geometry.size.width - 320))
                    let sideWidth = max(0, (geometry.size.width - displayWidth) / 2)
                    let audioWidth = min(230, max(100, sideWidth * 0.4))
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
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
                        FooterInformationDisplay(show: show, embedded: true, alignment: .center)
                            .frame(width: displayWidth)
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
        #if os(macOS)
        toolWindows.updateItemActions(show: show, library: Binding(get: { libraryOpen }, set: { libraryOpen = $0 }))
        #endif
        return content.background(interfaceTheme.background).foregroundStyle(JarasTheme.text).jarasHideScrollIndicators()
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
                        ProgressView(value: documents.audioImportProgress).progressViewStyle(JarasProgressBarStyle()).tint(JarasTheme.green)
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

            .environment(\.multitrackAction, documents.openMultitrackExport)
            .modifier(MultitrackSheet(presentation: documents.multitrack))
            .environment(\.openFX, { track, effect in
                #if os(macOS)
                openDesktopFX(track, effect)
                #else
                let target = FXTarget(track: track, effect: effect)
                if !fxTargets.contains(where: { $0.id == target.id }) { fxTargets.append(target) }
                #endif
            })
            #if os(macOS)
            .environment(\.openClipFXChain, toolWindows.clipFXAction)
            #else
            .environment(\.openClipFXChain, { clip in
                if !clipFXTargets.contains(clip) { clipFXTargets.append(clip) }
            })
            #endif
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .catLiveOpenPluginSettings, object: show)) { _ in
                openSettings(.plugins)
            }
            #endif
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
            #if os(macOS)
            .environment(\.editTextItem, toolWindows.editTextAction)
            .environment(\.addFullLyrics, toolWindows.fullLyricsAction)
            #else
            .environment(\.editTextItem, { id in
                textItemTarget = id
            })
            .environment(\.addFullLyrics, { track in
                do { fullLyricsTarget = try FullLyricsTarget(show: show, track: track) }
                catch { show.message = error.localizedDescription }
            })
            #endif
            #if os(macOS)
            .background(NativeTimelineModalGate(blocked: workspaceInputBlocked || panel != nil || textItemTarget != nil || trackEdit != nil || mappings.editing != nil))
            #else
            .environment(\.gridInteractionBlocked, panel != nil || textItemTarget != nil || trackEdit != nil || mappings.editing != nil)
            #endif
            .environment(\.editTrackDetails, { request in
                guard request.project == show.snapshot.project.id, !request.tracks.isEmpty else { return }
                trackEdit = request
            })
            #if os(macOS)
            .onReceive(_partsRightOpen.preference.values) { visible in detachedSetlist.setPartsVisible(visible) }
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
                                    save: { _, color in
                                        show.editTrackColors(edit.tracks, color: color, project: edit.project)
                                    }, close: { trackEdit = nil }, nameEditable: false, showsName: false)
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
                // MIDI/SMK/Remote pads must be ready before their UI is opened.
                if DesktopProjectTabs.shared.isForeground(show) {
                    VinhetasController.shared.bind(show: show)
                    mappings.bind(show)
                }
                DAWRemoteHostBridge.bind(show)
                ResolumeController.shared.bind(show)
                #else
                mappings.bind(show)
                #endif
                #if os(macOS)
                show.smkPartsVisibility = { (partsLeftOpen || detachedParts.isVisible, partsRightOpen) }
                #else
                show.smkPartsVisibility = { (false, partsRightOpen) }
                #endif
                show.smkRecord = { TrackRecording.shared.toggle(show: show) }
                show.togglePartsPanel = toggleRightParts
                show.showPartsPanel = {
                    #if os(macOS)
                    if detachedParts.isDetached { showLeftDetachedParts() }
                    else if !partsLeftOpen {
                        setRightPartsOpen(true)
                        if setlistCollapsed { toggleSetlist() }
                    }
                    #else
                    setRightPartsOpen(true)
                    #endif
                }
                #if os(macOS)
                show.toggleFocusPanel = { toggleFocus() }
                show.toggleLibraryPanel = { libraryOpen.toggle() }
                #endif
                show.toggleTracksPanel = { toggleMixer() }
                #if os(macOS)
                show.showTrackFocus = { openDesktopFX($0, "Chain") }
                #endif
                show.toggleBarMixerPanel = { toggleBarMixer() }
                show.toggleSetlistPanel = { toggleSetlist() }
            }
            #if os(macOS)
            .onChange(of: documents.projectTabIndex) { _ in
                if !DesktopProjectTabs.shared.isForeground(show) {
                    detachedMixer.close(preserveState: true); detachedSetlist.close(preserveState: true); detachedParts.close(preserveState: true); vinhetasWindow.hide(preserveState: true)
                    toolWindows.closeAll()
                    WorkspaceToolWindows.closePatch(for: show)
                } else { restoreGlobalPanels(); VinhetasController.shared.bind(show: show) }
            }
            #endif
            .onDisappear {
                #if os(macOS)
                toolWindows.closeAll(); midiPreviewWindow.dock()
                WorkspaceToolWindows.closePatch(for: show)
                #endif
                guard !remotePresentation else { return }
                #if os(macOS)
                detachedMixer.close(preserveState: true); detachedSetlist.close(preserveState: true); detachedParts.close(preserveState: true); vinhetasWindow.hide(preserveState: true)
                guard DesktopProjectTabs.shared.isForeground(show) else { return }
                #endif
                // SwiftUI presents the replacement .id before removing the old
                // workspace. The old view must not erase the new callbacks.
                guard presentedSessionID == show.projectSessionID else { return }
                show.toggleFocusPanel = {}; show.toggleLibraryPanel = {}
                show.toggleTracksPanel = {}; show.toggleBarMixerPanel = {}; show.toggleSetlistPanel = {}; show.togglePartsPanel = {}; show.showPartsPanel = {}
                show.showTrackFocus = { _ in }
                #if os(macOS)
                ResolumeController.shared.stop()
                FXWindows.shared.closeAll()
                #endif
            }
            .onReceive(TrackRecording.shared.$error.removeDuplicates()) { recordingError = $0 }
            .alert(Text(verbatim: JarasLocalization.string("Recording")), isPresented: Binding(
                get: { !recordingError.isEmpty },
                set: { if !$0 { TrackRecording.shared.error = "" } }
            )) { Button("OK") { TrackRecording.shared.error = "" } } message: { Text(LocalizedStringKey(recordingError)) }
            .overlay {
                if mappings.editing != nil && mappings.editing?.presentedInline != true && mappings.editing?.fxParameter == nil && panel == nil {
                    #if os(macOS)
                    WorkspaceToolStateView(windows: toolWindows) { windows in
                        if !windows.settingsOpen { mappingOverlay }
                    }
                    #else
                    mappingOverlay
                    #endif
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
            .sheet(item: $fullLyricsTarget) { target in
                FullLyricsEditor(show: show, target: target, close: { fullLyricsTarget = nil })
            }
            #if !os(macOS)
            .sheet(item: $panel) { selected in
                VStack(spacing: 0) {
                    HStack {
                        Text(LocalizedStringKey(selected.isSettings ? "Configurações" : "Home")).font(.jarasHeadline)
                        Spacer()
                        Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Fechar").keyboardShortcut(.cancelAction)
                    }.padding(16)
                    Divider()
                    if selected.isSettings {
                        SettingsView(auth: auth, show: show, backend: backend, initialSection: selected == .audioSettings ? .audio : .general)
                    } else {
                        ProjectBrowserView(documents: documents, completed: { panel = nil }, homeModal: true)
                    }
                }
                .frame(width: selected.isSettings ? 940 : documents.folderReview == nil ? 560 : 840, height: selected.isSettings ? 540 : 500)
                .background(selected.isSettings ? interfaceTheme.background : interfaceTheme.homeBackground).foregroundStyle(JarasTheme.text)
                .environment(\.locale, Locale(identifier: language))
            }
            #endif
    }
    private var mappingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { mappings.editing = nil }
            ControlMappingEditor()
        }
    }
    private func openProjects() {
        #if os(macOS)
        showProjects(false)
        #else
        panel = .projects
        #endif
    }
    #if os(macOS)
    private var desktopToolBar: some View {
        DesktopToolbarDockInputs(docks: performanceDockState, detachedPreview: midiPreviewWindow.visibility, mixerKey: footerMixerPreferenceKey,
            content: desktopToolBarContent)
    }
    private func desktopToolBarContent(_ indicators: DesktopDockIndicators) -> some View {
        Group {
            if #available(macOS 13, *) {
                ViewThatFits(in: .horizontal) {
                    desktopToolbarRow(compact: false, indicators: indicators)
                    desktopToolbarRow(compact: true, indicators: indicators)
                    VStack(spacing: 0) {
                        HStack(spacing: 3) { desktopToolButtons; Spacer(minLength: 0) }
                            .frame(height: 28)
                        HStack(spacing: 3) {
                            TeleprompterTimerToolbarReadout().fixedSize()
                            Spacer(minLength: 0)
                            desktopLiveButtons
                            desktopToolbarSettings
                        }.frame(height: 28)
                    }.padding(.horizontal, 4)
                        .environment(\.compactDesktopToolbar, true)
                }
            } else {
                desktopToolbarRow(compact: true, indicators: indicators)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .background(interfaceTheme.titlebar)
        .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.secondary.opacity(0.2)).frame(height: 1) }
    }
    private func desktopToolbarRow(compact: Bool, indicators: DesktopDockIndicators) -> some View {
        HStack(spacing: compact ? 3 : 6) {
            desktopToolButtons
            Spacer(minLength: 0)
            TeleprompterTimerToolbarReadout().fixedSize()
            desktopLiveButtons
            desktopToolbarSettings
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .environment(\.compactDesktopToolbar, compact)
    }

    @ViewBuilder private var desktopLiveButtons: some View {
        if desktopExtras {
            DesktopTeleprompterSelector(show: show, directory: documents.currentURL?.deletingLastPathComponent())
            TeleprompterPreviewButton()
            VideoToggleButton()
            RemoteToggleButton(show: show)
        }
    }

    @ViewBuilder private var desktopToolbarSettings: some View {
        AudioStatusView(showsDeviceName: false) { openSettings(.audio) }
            .font(.jarasSystem(size: 9, weight: .medium, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false).frame(height: 24)
        WorkspaceToolStateView(windows: toolWindows) { windows in
            Button { openSettings() } label: {
                toolbarLabel("Settings", "gearshape", active: windows.settingsOpen)
            }.accessibilityLabel("Configurações")
        }
    }

    private var desktopFileButton: some View {
        DesktopFileMenu(show: show, documents: documents, session: openProjects,
                        label: { toolbarLabel("File", "line.3.horizontal") }, export: { showingFileExport = true },
                        share: shareProject)
    }
    private var desktopTimerReadout: some View {
        TeleprompterTimerToolbarReadout().fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var desktopStatusControls: some View {
        HStack(spacing: 6) { desktopToolbarSettings }.buttonStyle(.plain)
    }
    private func desktopTrackMixerButton(showsTitle: Bool = false) -> some View {
        _mixerWidth.observing { width in
            Button(action: toggleMixer) {
                toolbarLabel("Track Mixer", "trackMixer", active: width > 0, showsTitle: showsTitle)
            }
            .accessibilityLabel(width <= 0 ? "Expandir Track-Mixer" : "Recolher Track-Mixer").help(Text("Track Mixer"))
        }
    }
    private var desktopMasterFooterButtons: some View {
        DesktopToolbarDockInputs(docks: performanceDockState, detachedPreview: midiPreviewWindow.visibility, mixerKey: footerMixerPreferenceKey) { indicators in
            HStack(spacing: 4) {
                Button { libraryOpen.toggle() } label: {
                    toolbarLabel("Library", "books.vertical", active: indicators.library, showsTitle: true)
                }.accessibilityIdentifier("workspace-library")
                Button(action: toggleFocus) {
                    toolbarLabel("Track - I", "trackInspector", active: indicators.focus, showsTitle: true)
                }.accessibilityIdentifier("workspace-focus")
                WorkspaceToolStateView(windows: toolWindows) { windows in
                    Menu {
                        Button { windows.openGrandMA2(show: show) } label: {
                            workspaceMenuItem("grandMA2", active: windows.grandMA2Open)
                        }
                        Button { windows.openResolume(show: show) } label: {
                            workspaceMenuItem("Resolume", active: windows.resolumeOpen)
                        }
                    } label: {
                        workspaceSelectorLabel("Integration", active: windows.grandMA2Open || windows.resolumeOpen)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityIdentifier("workspace-integration")
                }
            }.buttonStyle(.plain)
        }
    }

    private var desktopMixerButtons: some View {
        DesktopToolbarDockInputs(docks: performanceDockState, detachedPreview: midiPreviewWindow.visibility, mixerKey: footerMixerPreferenceKey) { indicators in
            HStack(spacing: 6) {
                desktopTrackMixerButton(showsTitle: true)
                Button(action: toggleBarMixer) {
                    toolbarLabel("Hoz Mixer", "hozMixer", active: indicators.mixer || detachedMixer.isVisible, showsTitle: true)
                }.accessibilityLabel("Hoz-Mixer").help(Text("Hoz Mixer"))
                    .contextMenu {
                        Button(LocalizedStringKey(detachedMixer.isDetached ? "Dock mixer" : "Undock mixer")) {
                            if detachedMixer.isDetached {
                                activatePerformancePanel(.mixer)
                                detachedMixer.close(); footerMixerOpen = true
                            } else { showDetachedMixer() }
                        }
                    }
                WorkspaceToolStateView(windows: toolWindows) { windows in
                    desktopPanelSelector(indicators: indicators, windows: windows)
                }
            }.buttonStyle(.plain)
        }
    }

    private func desktopPanelSelector(indicators: DesktopDockIndicators, windows: WorkspaceToolWindows) -> some View {
        let partsActive = partsLeftOpen || detachedParts.isVisible
        let padsActive = indicators.pads || vinhetasWindow.visible
        return Menu {
            workspacePanelToggle("Parts Vert", active: partsActive && !partsLeftHorizontal) {
                if detachedParts.isDetached {
                    if detachedParts.isVisible { detachedParts.hide() }
                    else { showLeftDetachedParts() }
                } else {
                    let opening = !partsLeftOpen || partsLeftHorizontal
                    partsLeftHorizontal = false
                    setLeftPartsOpen(opening)
                }
            }
            workspacePanelToggle("Parts Hoz", active: partsLeftOpen && partsLeftHorizontal) {
                let opening = !partsLeftOpen || !partsLeftHorizontal
                partsLeftHorizontal = true
                setLeftPartsOpen(opening)
            }.disabled(detachedParts.isDetached)
            workspacePanelToggle("Pads", active: padsActive) {
                VinhetasController.shared.bind(show: show)
                if !(vinhetasWindow.detached ? vinhetasWindow.visible : vinhetasOpen) { activatePerformancePanel(.pads) }
                if vinhetasWindow.detached { vinhetasWindow.toggle(show: show) }
                else { vinhetasOpen.toggle() }
            }
            workspacePanelToggle("Keyboard", active: indicators.keyboard) {
                if !keyboardOpen { activatePerformancePanel(.keyboard) }
                keyboardOpen.toggle()
            }
            workspacePanelToggle("Matrix Control", active: windows.matrixPatchOpen) { windows.openMatrixPatch(show: show) }
            workspacePanelToggle("MIDI Preview", active: indicators.midiPreview) {
                if !(midiPreviewWindow.detached ? midiPreviewWindow.visible : midiPreviewOpen) { activatePerformancePanel(.midiPreview) }
                if midiPreviewWindow.detached {
                    if midiPreviewWindow.visible { midiPreviewWindow.hide() } else { midiPreviewWindow.present(show) }
                } else { midiPreviewOpen.toggle() }
            }
            Divider()
            Button(midiPreviewWindow.detached ? "Dock MIDI Preview" : "Undock MIDI Preview") {
                activatePerformancePanel(.midiPreview)
                if midiPreviewWindow.detached { midiPreviewWindow.dock(); midiPreviewOpen = true }
                else { midiPreviewOpen = false; midiPreviewWindow.present(show) }
            }
            Button("Keyboard Settings") { keyboardSettings = true }
            Button(LocalizedStringKey(detachedParts.isDetached ? "Dock Parts" : "Undock Parts")) {
                if detachedParts.isDetached { detachedParts.close(); setLeftPartsOpen(true) }
                else { partsLeftOpen = false; showLeftDetachedParts() }
            }.disabled(partsLeftHorizontal)
            Button(vinhetasWindow.detached ? "Dock Pads" : "Undock Pads") {
                activatePerformancePanel(.pads)
                if vinhetasWindow.detached { vinhetasWindow.dock(); vinhetasOpen = true }
                else { vinhetasOpen = false; vinhetasWindow.open(show: show) }
            }
        } label: {
            workspaceSelectorLabel("Panel", active: partsActive || padsActive || indicators.keyboard || windows.matrixPatchOpen || indicators.midiPreview)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityIdentifier("workspace-panel-selector")
            .sheet(isPresented: $keyboardSettings) { KeyboardSettingsView() }
    }

    private func workspacePanelToggle(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { active }, set: { _ in action() })) { Text(verbatim: title) }
    }

    private func workspaceSelectorLabel(_ title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: title).font(.jarasSystem(size: TimelineEditingBarMetrics.labelSize, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }.modifier(DesktopToolbarChrome(tone: active ? .selected : .neutral))
    }

    @ViewBuilder private func workspaceMenuItem(_ title: String, active: Bool) -> some View {
        if active { Label { Text(verbatim: title) } icon: { Image(systemName: "checkmark") } }
        else { Text(verbatim: title) }
    }

    private var desktopEditingWorkspaceButtons: some View {
        HStack(spacing: 6) { desktopWorkspaceToolButtons }.buttonStyle(.plain)
    }
    private var desktopEditingLiveButtons: some View {
        HStack(spacing: 6) {
            TimelineLockSelector(show: show)
            desktopLiveButtons
        }.buttonStyle(.plain)
    }
    private var desktopToolButtons: some View {
        Group {
            desktopFileButton
            desktopTrackMixerButton()
        }
    }
    @ViewBuilder private var desktopWorkspaceToolButtons: some View {
        if desktopExtras {
            WorkspaceToolStateView(windows: toolWindows) { windows in
                Button(action: openAdvanced) { toolbarLabel("Advanced", "a.circle", active: windows.advancedOpen, showsTitle: true) }
                    .help(Text(verbatim: "Advanced"))
            }

        }
    }
    private func toolbarLabel(_ title: String, _ symbol: String, active: Bool = false, showsTitle: Bool = false) -> some View {
        DesktopToolbarLabel(title: title, systemImage: symbol, active: active, showsTitle: showsTitle)
    }
    #endif
}
struct MainPreview: PreviewProvider { static var previews: some View { let container = try! AppContainer(preview: true); MainView(show: container.show, auth: container.auth, backend: container.backend, documents: container.documents).frame(width: 1360, height: 800) } }

#if os(macOS)
import AppKit

private struct WorkspaceToolStateView<Content: View>: View {
    @ObservedObject var windows: WorkspaceToolWindows
    @ViewBuilder let content: (WorkspaceToolWindows) -> Content
    var body: some View { content(windows) }
}

private struct DesktopDockIndicators {
    let pads: Bool
    let library: Bool
    let mixer: Bool
    let focus: Bool
    let keyboard: Bool
    let midiPreview: Bool
}

/// Dock toggles update their indicators and layout consumers independently of MainView.
private struct DesktopToolbarDockInputs<Content: View>: View {
    @ObservedObject var docks: DesktopPerformanceDocks
    @ObservedObject private var midiPreview: MIDIPreviewVisibility
    @ObservedObject private var detachedPreview: MIDIPreviewVisibility
    @WorkspacePreference(desktopLibraryVisibilityKey, store: WorkspaceLayoutPreferences.storage) private var libraryOpen = false
    @WorkspacePreference("jaras.vinhetas.visible", store: WorkspaceLayoutPreferences.storage) private var padsOpen = false
    @WorkspacePreference private var mixerOpen: Bool
    let content: (DesktopDockIndicators) -> Content

    init(docks: DesktopPerformanceDocks, detachedPreview: MIDIPreviewVisibility, mixerKey: String, content: @escaping (DesktopDockIndicators) -> Content) {
        self.docks = docks; self.content = content
        _midiPreview = ObservedObject(wrappedValue: docks.midiPreview)
        _detachedPreview = ObservedObject(wrappedValue: detachedPreview)
        _mixerOpen = WorkspacePreference(wrappedValue: false, mixerKey, store: WorkspaceLayoutPreferences.storage)
    }

    var body: some View {
        content(DesktopDockIndicators(pads: padsOpen, library: libraryOpen, mixer: mixerOpen, focus: docks.focusOpen,
            keyboard: docks.keyboardOpen, midiPreview: midiPreview.active || detachedPreview.active))
    }
}

private struct DesktopFooterDockInputs<Content: View>: View {
    let docks: DesktopPerformanceDocks
    @WorkspacePreference private var mixerOpen: Bool
    @WorkspacePreference("catlive.footerDisplayHeight", store: WorkspaceLayoutPreferences.storage) private var storedFooterHeight = 27.0
    @State private var keyboardOpen: Bool?
    @ViewBuilder let content: (Bool, Bool, Binding<Double>) -> Content

    init(docks: DesktopPerformanceDocks, mixerKey: String, @ViewBuilder content: @escaping (Bool, Bool, Binding<Double>) -> Content) {
        self.docks = docks; self.content = content
        _mixerOpen = WorkspacePreference(wrappedValue: false, mixerKey, store: WorkspaceLayoutPreferences.storage)
    }

    var body: some View {
        content(keyboardOpen ?? docks.keyboardOpen, mixerOpen, $storedFooterHeight)
            .onReceive(docks.$keyboardOpen.removeDuplicates()) { if keyboardOpen != $0 { keyboardOpen = $0 } }
    }
}

private struct DesktopRightDockEditorWidth<Content: View>: View {
    let enabled: Bool
    let show: ShowController
    let docks: DesktopPerformanceDocks
    let baseWidth: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content
    @WorkspacePreference(desktopLibraryVisibilityKey, store: WorkspaceLayoutPreferences.storage) private var libraryOpen = false
    @WorkspacePreference("jaras.layout.library.width", store: WorkspaceLayoutPreferences.storage) private var libraryWidth = 344.0
    @WorkspacePreference(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage)
    private var libraryFolders = WorkspaceLibrary.defaultFolderWidth
    @State private var focusWidth: CGFloat?

    private var updates: AnyPublisher<CGFloat, Never> {
        guard enabled else { return Empty().eraseToAnyPublisher() }
        let selection = show.projectPresentation.objectWillChange
            .merge(with: show.trackSelectionPresentation.objectWillChange)
            .map { FooterHorizontalMixer.hasFocusSelection(in: show) }
            .prepend(FooterHorizontalMixer.hasFocusSelection(in: show))
            .removeDuplicates()
        return docks.$focusOpen.removeDuplicates().combineLatest(selection)
            .map { open, selected in open ? FooterHorizontalMixer.focusWidth(hasSelectedTrack: selected) : 0 }
            .removeDuplicates().eraseToAnyPublisher()
    }

    var body: some View {
        let library = enabled && libraryOpen ? WorkspaceLibrary.maximumWidth(folders: libraryFolders,
            available: max(WorkspaceLibrary.minimumPanelWidth, libraryWidth)) : 0
        let focus = enabled ? (focusWidth ?? (docks.focusOpen
            ? FooterHorizontalMixer.focusWidth(hasSelectedTrack: FooterHorizontalMixer.hasFocusSelection(in: show)) : 0)) : 0
        content(baseWidth + focus + library)
            .onReceive(updates) { if focusWidth != $0 { focusWidth = $0 } }
            .onChange(of: enabled) { if !$0 { focusWidth = nil } }
    }
}

private struct DetachedSetlistContent: View {
    let show: ShowController
    let mediaDirectory: URL?
    @Binding var partsOpen: Bool
    @WorkspacePreference("jaras.language") private var language = "en"
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
    var showsDeviceName = true
    let openSettings: () -> Void
    @State private var hovering = false
    private var status: String {
        guard audio.channels > 0, audio.devices.contains(where: { $0.id == audio.selectedUID }) else { return "No Device" }
        let format = "\(audio.bufferFrames) · \(Int(audio.sampleRate)) Hz"
        return showsDeviceName ? "\(audio.deviceName) · \(format)" : format
    }
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
    let panelWidth: CGFloat?
    let panelHeight: CGFloat
    @StateObject private var updates: ShowPresentationObserver
    init(show: ShowController, panelWidth: CGFloat? = nil, panelHeight: CGFloat = TransportControlMetrics.detailHeight) {
        self.show = show; self.panelWidth = panelWidth; self.panelHeight = panelHeight
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    @State private var editing: Part?
    @State private var hoveredStep: Int?
    private func step(_ delta: Int) {
        guard show.tunerInputAllowed, let song = show.current, let region = show.pitchRegion else { return }
        let targets = song.pitchTargets(region)
        show.setRegionPitch(region.id, semitones: min(12, max(-12, region.semitones + delta)), tracks: targets.tracks, groups: targets.groups)
    }
    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "Tuner").font(.jarasSystem(size: 9, weight: .semibold)).foregroundStyle(JarasTheme.text)
                .fixedSize(horizontal: true, vertical: false)
            Button { step(-1) } label: { tunerStepLabel("minus", step: -1) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) <= -12).jarasHelp("Lower song pitch")
                .onHover { updateHover(-1, inside: $0) }
            Text(String(format: "%dst", show.pitchRegion?.semitones ?? 0))
                .font(.jarasSystem(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .frame(width: 34, height: 23)
                #if os(macOS)
                .immediateRightClick { if show.tunerInputAllowed { editing = show.pitchRegion } }
                #else
                .modifier(NativeTunerTargets(show: show))
                #endif
                .accessibilityLabel("Song pitch").accessibilityValue(String(show.pitchRegion?.semitones ?? 0) + "st")
            Button { step(1) } label: { tunerStepLabel("plus", step: 1) }
                .disabled(show.pitchRegion == nil || (show.pitchRegion?.semitones ?? 0) >= 12).jarasHelp("Raise song pitch")
                .onHover { updateHover(1, inside: $0) }
        }.buttonStyle(.plain).foregroundStyle(JarasTheme.green)
        .padding(.horizontal, 6).frame(width: panelWidth, height: panelHeight)
        .background(TransportDetailSurface())
        .disabled(!show.tunerInputAllowed)
        .opacity(show.tunerInputAllowed ? 1 : 0.45)
        .onChange(of: show.tunerInputAllowed) { if !$0 { editing = nil } }
        .sheet(item: $editing) { region in
            if let song = show.current {
                RegionPitchTargets(show: show, song: song, region: region, close: { editing = nil })
            }
        }
    }
    private func tunerStepLabel(_ symbol: String, step: Int) -> some View {
        Image(systemName: symbol).font(.jarasSystem(size: TransportControlMetrics.stepSymbolSize, weight: .medium))
            .frame(width: 20, height: 23)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(hoveredStep == step ? JarasTheme.secondary.opacity(0.65) : .clear)
                .allowsHitTesting(false))
            .contentShape(Rectangle())
    }
    private func updateHover(_ step: Int, inside: Bool) {
        if inside { hoveredStep = step }
        else if hoveredStep == step { hoveredStep = nil }
    }
}
struct RegionPitchTargets: View {
    @ObservedObject var show: ShowController
    private let individualTracks: [Track]
    private let folders: [Track]
    let region: Part
    let close: () -> Void
    @State private var tab = 0
    @State private var tracks: Set<UUID>
    private let groupTracks: [UUID: Set<UUID>]
    init(show: ShowController, song: Song, region: Part, close: @escaping () -> Void) {
        self.show = show; self.region = region; self.close = close
        let folders = song.pitchGroups
        let folderIDs = Set(folders.map(\.id))
        let individuals = song.tracks.filter { $0.kind == .standard && !folderIDs.contains($0.id) }
        self.folders = folders
        self.individualTracks = individuals
        let hierarchy = TrackHierarchy(song.tracks)
        var contents: [UUID: Set<UUID>] = [:]
        for track in individuals {
            for parent in hierarchy.ancestors(of: track.id) {
                contents[parent, default: []].insert(track.id)
            }
        }
        groupTracks = contents
        let selection = Set(region.pitchTrackIDs ?? individuals.map(\.id))
        let groups = region.pitchGroupIDs.map(Set.init) ?? folderIDs
        _tracks = State(initialValue: groups.reduce(into: selection) { result, group in
            result.formUnion(contents[group] ?? [])
        })
    }
    private var visibleTracks: [Track] { tab == 0 ? individualTracks : folders }
    private var allSelected: Bool { !visibleTracks.isEmpty && visibleTracks.allSatisfy(isSelected) }
    private func targetIDs(_ track: Track) -> Set<UUID> {
        tab == 0 ? [track.id] : groupTracks[track.id] ?? []
    }
    private func isSelected(_ track: Track) -> Bool {
        let targets = targetIDs(track)
        return !targets.isEmpty && targets.isSubset(of: tracks)
    }
    private func setSelected(_ track: Track, _ selected: Bool) {
        let targets = targetIDs(track)
        if selected { tracks.formUnion(targets) } else { tracks.subtract(targets) }
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text("Pitch · " + region.displayName).font(.jarasHeadline).lineLimit(1); Spacer(); Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Close").keyboardShortcut(.cancelAction) }
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
                            .disabled(targetIDs(track).isEmpty)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: 245)
            HStack { Spacer(); Button("Apply") {
                if let current = show.current?.parts.first(where: { $0.id == region.id }),
                   current.pitchTrackIDs.map(Set.init) != tracks || current.pitchGroupIDs != [] {
                    show.setRegionPitch(region.id, semitones: current.semitones, tracks: tracks, groups: [])
                }
                close()
            }.keyboardShortcut(.defaultAction).disabled(!show.tunerInputAllowed) }
        }.padding(20).frame(width: 410).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}

struct FooterPianoKeyboard: View {
    var active = true
    @ObservedObject private var state = KeyboardMIDIMonitor.shared
    @WorkspacePreference("jaras.keyboard.whiteColor") private var whiteColor = 0x54ff93
    @WorkspacePreference("jaras.keyboard.blackColor") private var blackColor = 0x54ff93
    @WorkspacePreference("jaras.keyboard.style") private var style = "default"
    @State private var pressed: Set<UInt8> = []
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
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
    private func setPressed(_ next: Set<UInt8>) {
        guard next != pressed else { return }
        for note in pressed.subtracting(next) { StemAudioPlayback.shared.releaseKeyboardNote(note) }
        for note in next.subtracting(pressed) { StemAudioPlayback.shared.playKeyboardNote(note) }
        pressed = next
    }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for black in [false, true] {
                    for note in 21...108 where (!whiteNotes.contains(note)) == black {
                        let rect = keyRect(note, size: size).insetBy(dx: 0.5, dy: 0)
                        let active = state.notes.contains(UInt8(note)) || pressed.contains(UInt8(note))
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(active ? Color(hex: UInt32(black ? blackColor : whiteColor)) : ((black != (style == "black")) ? Color(white: 0.08) : Color(white: 0.89))))
                        if note == 21 || note % 12 == 0 {
                            let label = note == 21 ? "A-1" : "C\(note / 12 - 2)"
                            context.draw(Text(verbatim: label).font(.jarasSystem(size: 9, weight: .medium)).foregroundColor(style == "black" && !active ? .white : .black), at: CGPoint(x: rect.midX, y: rect.maxY - 11))
                        }
                    }
                }
            }.contentShape(Rectangle())
                #if os(iOS)
                .overlay {
                    FooterKeyboardTouchInput { points in
                        setPressed(active && scenePhase == .active ? Set(points.compactMap { note(at: $0, size: geometry.size) }) : [])
                    }
                }
                #else
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    setPressed(note(at: event.location, size: geometry.size).map { [$0] } ?? [])
                }.onEnded { _ in setPressed([]) })
                #endif
        }.padding(.horizontal, 6).padding(.vertical, 4).background(JarasTheme.panel)
            .onDisappear { setPressed([]); StemAudioPlayback.shared.releaseKeyboardNotes() }
            .onChange(of: active) { if !$0 { setPressed([]); StemAudioPlayback.shared.releaseKeyboardNotes() } }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in setPressed([]); StemAudioPlayback.shared.releaseKeyboardNotes() }
            #else
            .onChange(of: scenePhase) { if $0 != .active { setPressed([]) } }
            #endif
            .accessibilityLabel("88-key keyboard")
    }
}

#if os(iOS)
private struct FooterKeyboardTouchInput: UIViewRepresentable {
    let changed: ([CGPoint]) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) { view.changed = changed }

    final class TouchView: UIView {
        var changed: (([CGPoint]) -> Void)?
        private var points: [ObjectIdentifier: CGPoint] = [:]

        private func update(_ touches: Set<UITouch>, finished: Bool = false) {
            for touch in touches {
                points[ObjectIdentifier(touch)] = finished ? nil : touch.location(in: self)
            }
            changed?(Array(points.values))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, finished: true) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, finished: true) }
    }
}
#endif

private struct KeyboardSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @WorkspacePreference("jaras.keyboard.whiteColor") private var whiteColor = 0x54ff93
    @WorkspacePreference("jaras.keyboard.blackColor") private var blackColor = 0x54ff93
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
    @State private var savedDate = ""
    private var timestamp: String { show.lastSavedAt ?? show.snapshot.project.updatedAt }
    private var label: String { "\(show.snapshot.project.name) - \(savedDate)" }
    fileprivate static func formatted(_ timestamp: String, withSeconds: Bool = false) -> String {
        guard let date = iso.date(from: timestamp) ?? fractional.date(from: timestamp) else { return "—" }
        return (withSeconds ? backupDate : displayDate).string(from: date)
    }
    private static let iso = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private static let displayDate: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "dd/MM/yyyy HH:mm"; return value
    }()
    fileprivate static let backupDate: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "dd/MM/yy, HH:mm:ss"; return value
    }()
    private func updateDate() { savedDate = Self.formatted(timestamp) }
    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: show.snapshot.project.name).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "- \(savedDate)").fixedSize()
        }.font(.jarasSystem(size: titlebar ? 11 : 10, weight: titlebar ? .medium : .bold)).lineLimit(1)
            .padding(.horizontal, titlebar ? 0 : 7).frame(maxWidth: .infinity, alignment: .leading).frame(height: 21)
            .background(titlebar ? Color.clear : JarasTheme.display, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(titlebar ? Color.clear : JarasTheme.line))
            .accessibilityElement(children: .ignore).accessibilityLabel("Project name").accessibilityValue(label)
            .onAppear(perform: updateDate).onChange(of: timestamp) { _ in updateDate() }
    }
}

#if os(macOS)
private struct DesktopFileMenu<Label: View>: View {
    let show: ShowController
    @ObservedObject var documents: ProjectDocuments
    @ObservedObject private var recording = TrackRecording.shared
    let session: () -> Void
    @ViewBuilder let label: () -> Label
    let export: () -> Void
    let share: () -> Void
    @State private var backups: [(url: URL, date: Date)] = []
    @State private var backupError: String?
    @State private var savedAt: String?
    @State private var saveAsNotice = false
    @State private var confirmingBackup = false
    @State private var pendingBackup: URL?

    var body: some View {
        Menu {
            Button(action: session) { Text("Home") }
            Button { documents.browse(onlyCatLiveProject: true) } label: { Text(verbatim: "Open") }
            Button { documents.createTemporary(fromFileMenu: true) } label: { Text(verbatim: "New Session") }
                .disabled(documents.busy || show.saving || recording.recording || recording.busy)
            Menu {
                if documents.recent.isEmpty { Text("No recent projects found.") }
                ForEach(documents.recent, id: \.self) { url in
                    Button { documents.open(url, fromFileRecents: true) } label: { Text(verbatim: url.deletingPathExtension().lastPathComponent) }
                }
            } label: { Text(verbatim: "Project Recents") }
                .disabled(documents.busy || recording.recording || recording.busy)
            Button {
                documents.chooseStems(adding: true)
                if documents.folderReview != nil { session() }
            } label: { Text(verbatim: "Add Stems") }
                .disabled(!documents.ready || documents.currentURL == nil || documents.busy || recording.recording || recording.busy)
            Divider()
            Button { Task { await show.save() } } label: { Text(verbatim: "Save") }
                .disabled(!documents.ready || documents.busy)
            Button { saveAsNotice = true } label: { Text(verbatim: "Save As") }
                .disabled(!documents.ready || documents.busy)
            Menu {
                Text(verbatim: "Saved     " + FooterProjectNameDisplay.formatted(savedAt ?? show.snapshot.project.updatedAt, withSeconds: true))
                Divider()
                if let backupError { Text(verbatim: backupError) }
                else if backups.isEmpty { Text("No backups found") }
                else {
                    ForEach(backups.indices, id: \.self) { index in
                        Button {
                            pendingBackup = backups[index].url
                            confirmingBackup = true
                        } label: {
                            Text(verbatim: "Backup \(index + 1)     " + FooterProjectNameDisplay.backupDate.string(from: backups[index].date))
                        }.disabled(documents.busy || recording.recording || recording.busy)
                    }
                }
            } label: { Text(verbatim: "Backups") }
            Divider()
            Menu {
                Button { documents.importTimelineFile(.audio) } label: { Text(verbatim: "Audio to File") }
                Button { documents.importTimelineFile(.movie) } label: { Text(verbatim: "Movie to File") }
                Button { documents.importTimelineFile(.midi) } label: { Text(verbatim: "MIDI to File") }
            } label: { Text(verbatim: "Import") }
            Button(action: export) { Text(verbatim: "Export") }.disabled(!documents.ready)
            Button(action: share) { Text(verbatim: "Share") }
                .disabled(!documents.ready || documents.busy || recording.recording || recording.busy)
            Divider()
            Button { (NSApp.mainWindow ?? NSApp.keyWindow)?.performClose(nil) } label: { Text(verbatim: "Quit") }
        } label: { label().fixedSize().contentShape(Rectangle()) }
        .menuStyle(.borderlessButton)
        .modifier(DesktopFileMenuIndicator())
        .accessibilityLabel(Text(verbatim: "File"))
        .accessibilityIdentifier("workspace-file")
        .task(id: documents.currentURL) { await loadBackups() }
        .onReceive(show.$lastSavedAt) { value in
            savedAt = value
            if value != nil { Task { await loadBackups() } }
        }
        .alert(Text(verbatim: "Save As"), isPresented: $saveAsNotice) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { Task { await documents.saveAs() } }.keyboardShortcut(.defaultAction)
        } message: {
            Text("The .jl project and all its media files will be copied to a different folder.")
        }
        .alert("Open backup?", isPresented: $confirmingBackup, presenting: pendingBackup) { url in
            Button("Cancel", role: .cancel) { pendingBackup = nil }
            Button("Open") { pendingBackup = nil; documents.open(url) }
        } message: { url in
            Text("Open this backup as a recovered project?") + Text(verbatim: "\n\n" + url.lastPathComponent)
        }
    }

    private func loadBackups() async {
        guard let document = documents.currentURL else { backups = []; backupError = nil; return }
        do {
            let entries = try await Task.detached(priority: .utility) {
                try ProjectBackups.migrateLegacyNames(for: document)
                let folder = ProjectBackups.mediaDirectory(for: document).appendingPathComponent("backups", isDirectory: true)
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: folder.path) else { return [(url: URL, date: Date)]() }
                let urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
                return try urls.filter { $0.pathExtension.lowercased() == "bkjl" }.compactMap { url -> (url: URL, date: Date)? in
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                    return (url, ProjectBackups.date(for: url))
                }.sorted {
                    $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date
                }.prefix(10).map { $0 }
            }.value
            guard documents.currentURL == document else { return }
            backups = entries
            backupError = nil
        } catch {
            guard documents.currentURL == document else { return }
            backups = []
            backupError = error.localizedDescription
        }
    }
}

private struct DesktopFileMenuIndicator: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 12, *) { content.menuIndicator(.hidden) }
        else { content }
    }
}
#endif

#if os(macOS)
/// Keep the live height inside the retained workspace root so a drag moves
/// the grid boundary without replacing the AppKit split view's hosted content.
private struct DesktopWorkspacePanels {
    let focusWidth: CGFloat
    let spareHeight: CGFloat
}
private struct DesktopHozMixerDock: View {
    let show: ShowController
    let maximumHeight: CGFloat
    let resizeCoordinator: FooterVerticalResizeCoordinator
    @WorkspacePreference("jaras.layout.mixer.open", store: WorkspaceLayoutPreferences.storage) private var visible = false

    var body: some View {
        FooterMixerPanel(show: show, active: visible, maximumHeight: maximumHeight, resizeCoordinator: resizeCoordinator)
    }
}
// Parts changes the available space, while the workspace and timeline keep their identities.
private struct DesktopPartsLayout<Content: View>: View {
    @WorkspacePreference private var open: Bool
    @WorkspacePreference("jaras.layout.parts.horizontal", store: WorkspaceLayoutPreferences.storage) private var horizontal = false
    @WorkspacePreference("jaras.layout.parts.heightScale", store: WorkspaceLayoutPreferences.storage) private var heightScale = 1.0
    @ObservedObject var detached: DetachedPartsWindow
    @ViewBuilder var content: (Bool, Bool, CGFloat) -> Content
    init(remote: Bool, detached: DetachedPartsWindow, @ViewBuilder content: @escaping (Bool, Bool, CGFloat) -> Content) {
        _open = WorkspacePreference(wrappedValue: false, (remote ? "jaras.remote." : "jaras.") + "layout.parts.open",
                           store: WorkspaceLayoutPreferences.storage)
        self.detached = detached
        self.content = content
    }
    var body: some View {
        let bottom = open && horizontal && !detached.isDetached
        content(open && !horizontal, bottom, bottom ? 192 * min(1.5, max(1, heightScale)) : 0)
    }
}
private struct DesktopWorkspaceDocks<Upper: View, Lower: View>: View {
    let show: ShowController
    let desktopExtras: Bool
    let availableHeight: CGFloat
    @ObservedObject var performanceDockState: DesktopPerformanceDocks
    let midiPreviewDetached: Bool
    let padsDetached: Bool
    let partsHeight: CGFloat
    let resizeCoordinator: FooterVerticalResizeCoordinator
    @ViewBuilder let upper: (DesktopWorkspacePanels, DesktopMIDIPreviewDock) -> Upper
    @ViewBuilder let lowerDocks: (Bool, Bool) -> Lower
    @AppStorage("jaras.vinhetas.visible", store: WorkspaceLayoutPreferences.storage) private var padsOpen = false
    @AppStorage("jaras.midiPreview.height", store: WorkspaceLayoutPreferences.storage) private var savedHeight = 273.0
    @State private var focusHasSelectedTrack: Bool?

    var body: some View {
        let showsPads = desktopExtras && padsOpen && !padsDetached
        let showsKeyboard = desktopExtras && performanceDockState.keyboardOpen
        let otherDocks: CGFloat = (showsPads ? 240 : 0) + (showsKeyboard ? 108 : 0)
        let spare = max(0, availableHeight - otherDocks - partsHeight - 128)
        let workspaceHeight = max(0, availableHeight - otherDocks)
        let focused = desktopExtras && performanceDockState.focusOpen
        let panels = DesktopWorkspacePanels(focusWidth: focused ? FooterHorizontalMixer.focusWidth(
                hasSelectedTrack: focusHasSelectedTrack ?? FooterHorizontalMixer.hasFocusSelection(in: show)) : 0,
            spareHeight: spare)
        VStack(spacing: 0) {
            upper(panels, DesktopMIDIPreviewDock(show: show, visibility: performanceDockState.midiPreview,
                enabled: desktopExtras && !midiPreviewDetached,
                storedHeight: $savedHeight, spareHeight: spare,
                resizeCoordinator: resizeCoordinator))
                .frame(height: workspaceHeight, alignment: .top).clipped()
            lowerDocks(showsKeyboard, showsPads)
        }
        .onReceive(show.projectPresentation.objectWillChange
            .merge(with: show.trackSelectionPresentation.objectWillChange)
                .map { FooterHorizontalMixer.hasFocusSelection(in: show) }.removeDuplicates()) { selected in
            if focusHasSelectedTrack != selected { focusHasSelectedTrack = selected }
        }
    }
}

private struct DesktopMIDIPreviewDock: View {
    let show: ShowController
    @ObservedObject var visibility: MIDIPreviewVisibility
    let enabled: Bool
    @Binding var storedHeight: Double
    let spareHeight: CGFloat
    let resizeCoordinator: FooterVerticalResizeCoordinator
    @AppStorage("jaras.layout.mixer.open", store: WorkspaceLayoutPreferences.storage) private var mixerVisible = false

    var body: some View {
        let active = enabled && visibility.active
        let mixerReserve = mixerVisible ? min(160, spareHeight / 2) : 0
        let maximum = min(723.55859375, spareHeight - mixerReserve)
        let minimum = min(273, maximum)
        return FooterNativeHeightHost(storedHeight: storedHeight, minimum: minimum, maximum: maximum,
            active: active, identity: AnyHashable(ObjectIdentifier(show)), role: .midiPreview,
            resizeCoordinator: resizeCoordinator, workspaceSpareHeight: spareHeight) {
            VStack(spacing: 0) {
                FooterMixerResizeInput(height: storedHeight, minimum: minimum, maximum: maximum,
                    changed: { _ in }, ended: { storedHeight = $0 })
                    .frame(height: 10)
                    .accessibilityLabel("Resize MIDI Preview")
                DesktopRecordingPianoPreview(show: show, visibility: visibility)
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
        }.clipped().allowsHitTesting(active).accessibilityHidden(!active)
    }
}

enum FooterHeightRole { case display, mixer, midiPreview, auxiliary }

/// Shares only native geometry. No publications, project edits or preferences
/// are emitted while a divider is moving.
final class FooterVerticalResizeCoordinator {
    private weak var display: FooterHeightContainerView?
    private weak var mixer: FooterHeightContainerView?
    private weak var midiPreview: FooterHeightContainerView?
    private var workspaceSpareHeight: CGFloat?
    private var availableHeight: CGFloat = 900
    private var fallbackMixerHeight: CGFloat = 0
    func configure(availableHeight: CGFloat, mixerHeight: CGFloat) {
        self.availableHeight = availableHeight; fallbackMixerHeight = mixerHeight
        display?.refreshHeight()
    }
    func register(_ view: FooterHeightContainerView, role: FooterHeightRole) {
        switch role {
        case .display: display = view
        case .mixer: mixer = view
        case .midiPreview: midiPreview = view; mixer?.refreshHeight()
        case .auxiliary: break
        }
        display?.refreshHeight()
    }
    func configureMixerBudget(_ height: CGFloat) {
        guard workspaceSpareHeight != height else { return }
        workspaceSpareHeight = height
        mixer?.refreshHeight()
    }
    var mixerMaximum: CGFloat? {
        workspaceSpareHeight.map { max(0, $0 - (midiPreview?.effectiveHeight ?? 0)) }
    }
    var displayMaximum: CGFloat {
        let mixerHeight = mixer.map { $0.active ? $0.effectiveHeight : 0 } ?? fallbackMixerHeight
        return min(161.046875, max(27, availableHeight - mixerHeight))
    }
    func heightChanged(role: FooterHeightRole) {
        if role == .midiPreview { mixer?.refreshHeight() }
        if role == .mixer { display?.refreshHeight() }
    }
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
    var workspaceSpareHeight: CGFloat? = nil
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
        if let workspaceSpareHeight { resizeCoordinator?.configureMixerBudget(workspaceSpareHeight) }
        view.configure(storedHeight: storedHeight, minimum: minimum, maximum: maximum, active: active,
                       role: role, coordinator: resizeCoordinator)
        view.openFX = openFX; view.editTrackDetails = editTrackDetails
        let environment = self.environment
        view.setContent(identity: identity, environment: environment) {
            // Copying the entire environment hides this nested host's accessible
            // descendants. Forward presentation and actions explicitly instead.
            AnyView(content().environment(\.locale, environment.locale)
                    .environment(\.colorScheme, environment.colorScheme)
                .workspaceControlsAppearActive()
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

private final class RetainedFooterHostingView: NSHostingView<AnyView> {
    override func layout() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        super.layout()
    }
    override func viewDidUnhide() { super.viewDidUnhide(); needsLayout = true }
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
    private let host = RetainedFooterHostingView(rootView: AnyView(EmptyView()))
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
    var heightMaximum: CGFloat {
        if role == .display { return min(maximum, coordinator?.displayMaximum ?? maximum) }
        if role == .mixer { return min(maximum, coordinator?.mixerMaximum ?? maximum) }
        return maximum
    }
    var heightMinimum: CGFloat { min(minimum, heightMaximum) }
    func configure(storedHeight: CGFloat, minimum: CGFloat, maximum: CGFloat, active: Bool,
                   role: FooterHeightRole, coordinator: FooterVerticalResizeCoordinator?) {
        if let pendingCommit, storedHeight != pendingCommit.previous || !active { self.pendingCommit = nil }
        self.storedHeight = storedHeight; self.minimum = minimum; self.maximum = maximum
        self.active = active; self.role = role; self.coordinator = coordinator
        // Once opened, keep the controls in their original window. Detaching
        // this hosting root tears down nested SwiftUI window environments on
        // close and forces cold preparation again on every reopen.
        if host.isHidden == active { host.isHidden = !active }
        if active {
            if host.superview !== self { addSubview(host) }
        } else {
            FooterVerticalResizeView.cancelDrags(in: self); preview = nil
            if contentAssignments == 0, host.superview === self { host.removeFromSuperview() }
        }
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
    var defersWindowLayoutDuringDrag: Bool { false }
    var height: CGFloat = 27
    var minimum: CGFloat = 27
    var maximum: CGFloat = 900
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat) -> Void)?
    var cancelled: (() -> Void)?
    private var origin: (y: CGFloat, height: CGFloat)?
    private weak var dragBoundary: FooterHeightContainerView?
    private var lastHeight: CGFloat?
    private var pendingHeight: CGFloat?
    private var resizeTimer: Timer?
    private var lastResizeTime: TimeInterval?
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
        cancelPendingHeight(); lastResizeTime = nil
        origin = (event.locationInWindow.y, boundary?.effectiveHeight ?? height)
        lastHeight = origin?.height
        if defersWindowLayoutDuringDrag { beginResize() }
    }
    private func beginResizeIfMoved(to value: CGFloat) -> Bool {
        if cursorPushed { return true }
        guard let origin, abs(value - origin.height) >= 1 else { return false }
        beginResize()
        return true
    }
    private func beginResize() {
        NativeSidebarResizeActivity.shared.begin(owner: self, retainsTimelineHeight: defersWindowLayoutDuringDrag)
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
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        boundary?.previewHeight(value); changed?(value)
        // Invalidate the real viewport now; AppKit presents it in its normal
        // display pass. Synchronously walking the whole project here repeats
        // that pass inside every pointer event, before the next event can run.
        if !defersWindowLayoutDuringDrag { window?.contentView?.layoutSubtreeIfNeeded() }
    }
    private func cancelPendingHeight() {
        resizeTimer?.invalidate(); resizeTimer = nil; pendingHeight = nil
    }
    private func commitPendingHeight() {
        resizeTimer?.invalidate(); resizeTimer = nil
        guard let value = pendingHeight, origin != nil else { pendingHeight = nil; return }
        pendingHeight = nil; lastResizeTime = ProcessInfo.processInfo.systemUptime
        apply(value)
    }
    private func scheduleHeight(_ value: CGFloat) {
        pendingHeight = value
        let interval = 1.0 / 60
        let elapsed = lastResizeTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        guard elapsed < interval else { commitPendingHeight(); return }
        guard resizeTimer == nil else { return }
        // A burst of pointer events has one newest destination. Reflow the
        // real viewport once per display frame rather than once per sample.
        let timer = Timer(timeInterval: interval - elapsed, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitPendingHeight() }
        }
        resizeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func mouseDragged(with event: NSEvent) {
        // scheduleHeight already retains the newest pointer destination. Reading
        // NSApplication's event queue here reenters Ventura's display/layout
        // cycle inside the drag callback, before the pending height is applied.
        guard let value = resizedHeight(event), beginResizeIfMoved(to: value) else { return }
        scheduleHeight(value)
    }
    override func mouseUp(with event: NSEvent) {
        guard let value = resizedHeight(event) else { return }
        guard beginResizeIfMoved(to: value) else {
            origin = nil; dragBoundary = nil
            return
        }
        let finalHeightChanged = value != lastHeight
        cancelPendingHeight()
        apply(value); origin = nil
        boundary?.finishHeight(commit: true); dragBoundary = nil; finishCursor()
        // A mixer release can arrive at a new position before its pending
        // drag frame. The display already applies its final geometry in apply.
        if finalHeightChanged && defersWindowLayoutDuringDrag { window?.contentView?.layoutSubtreeIfNeeded() }
        ended?(value)
    }
    func cancelDrag() {
        guard origin != nil else { return }
        cancelPendingHeight()
        origin = nil; lastHeight = nil
        guard cursorPushed else { dragBoundary = nil; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let container = boundary
        container?.finishHeight(commit: false)
        (container?.window ?? window)?.contentView?.layoutSubtreeIfNeeded(); dragBoundary = nil
        CATransaction.commit(); finishCursor(); cancelled?()
    }
    private func finishCursor() {
        NativeSidebarResizeActivity.shared.end(owner: self)
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
        resizeTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        if cursorPushed { NSCursor.pop() }
    }
}
final class FooterDisplayResizeView: FooterVerticalResizeView {}

struct FooterMixerResizeInput: NSViewRepresentable {
    let height: CGFloat
    var minimum: CGFloat = 273
    let maximum: CGFloat
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    var cancelled: (() -> Void)? = nil
    func makeNSView(context: Context) -> FooterMixerResizeView { FooterMixerResizeView() }
    func updateNSView(_ view: FooterMixerResizeView, context: Context) {
        view.height = height; view.minimum = minimum; view.maximum = maximum; view.changed = changed; view.ended = ended
        view.cancelled = cancelled
    }
}
final class FooterMixerResizeView: FooterVerticalResizeView {
    override var defersWindowLayoutDuringDrag: Bool { true }
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
