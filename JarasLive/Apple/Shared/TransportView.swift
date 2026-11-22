import SwiftUI
import UniformTypeIdentifiers
import Combine

enum SetlistPlacement: String { case left, right, detached }

enum TimelineEditPreferences {
    static let desktop = "jaras.timeline.editMode"
    static let native = "jaras.ipad.transport.edit"
    static func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

#if os(macOS)
final class DesktopTimelineToolbar: ObservableObject {
    struct Limits: Equatable {
        var zoom = 0.001...TimelineZoomLimits.maximum
        var tracks = Double(TimelineTrackHeightLimits.minimum)...Double(TimelineTrackHeightLimits.maximum)
    }

    @Published var limits = Limits()
    @Published var zoom = TimelineViewportPreferences.zoom {
        didSet { if zoomMemory != nil && abs(zoom - limits.zoom.lowerBound) > 0.000001 { zoomMemory = nil } }
    }
    @Published var trackHeight = Double(TimelineTrackHeightLimits.defaultHeight) {
        didSet { if trackHeightMemory != nil && trackHeight > limits.tracks.lowerBound { trackHeightMemory = nil } }
    }
    @Published private(set) var zoomMemory: Double?
    @Published private(set) var trackHeightMemory: Double?
    @Published var movingRegion = false
    var changeZoom: ((Double) -> Void)?
    var changeTrackHeight: ((Double) -> Void)?

    func toggleMinimumZoom() {
        guard let changeZoom else { return }
        if let previous = zoomMemory {
            zoomMemory = nil
            changeZoom(previous)
        } else if zoom > limits.zoom.lowerBound + 0.000001 {
            zoomMemory = zoom
            changeZoom(limits.zoom.lowerBound)
        }
    }

    func toggleMinimumTrackHeight() {
        guard let changeTrackHeight else { return }
        if let previous = trackHeightMemory {
            trackHeightMemory = nil
            changeTrackHeight(previous)
        } else if trackHeight > limits.tracks.lowerBound {
            trackHeightMemory = trackHeight
            changeTrackHeight(limits.tracks.lowerBound)
        }
    }
}

private struct DesktopTimelineToolbarKey: EnvironmentKey {
    static let defaultValue: DesktopTimelineToolbar? = nil
}

extension EnvironmentValues {
    var desktopTimelineToolbar: DesktopTimelineToolbar? {
        get { self[DesktopTimelineToolbarKey.self] }
        set { self[DesktopTimelineToolbarKey.self] = newValue }
    }
}
#endif

struct TransportView: View {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @State private var showingReduction = false
    #if !os(macOS)
    @State private var showingExport = false
    #endif
    @State private var showingFadeout = false
    #if os(macOS)
    @AppStorage("jaras.transport.proMode", store: WorkspaceLayoutPreferences.storage) private var proMode = false
    @State private var showingClockPosition = false
    @AppStorage("jaras.timeline.proTool") private var proTool = ProGridTool.select
    #endif
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    var documents: ProjectDocuments? = nil
    var remotePresentation = false
    var mediaDirectory: URL? = nil
    var toggleNavigation: () -> Void = {}
    var mixerCollapsed = false
    var setlistCollapsed = false
    var toggleMixer: () -> Void = {}
    var toggleSetlist: () -> Void = {}
    var setlistPlacement: SetlistPlacement = .right
    var placeSetlist: (SetlistPlacement) -> Void = { _ in }
    var shareProject: (() -> Void)?
    var proNotesOpen = false
    var proSamplersOpen = false
    var toggleProNotes: () -> Void = {}
    var toggleProSamplers: () -> Void = {}
    var closeProDocks: () -> Void = {}
    init(show: ShowController, documents: ProjectDocuments? = nil, remotePresentation: Bool = false,
         mediaDirectory: URL? = nil, toggleNavigation: @escaping () -> Void = {},
         mixerCollapsed: Bool = false, setlistCollapsed: Bool = false,
         toggleMixer: @escaping () -> Void = {}, toggleSetlist: @escaping () -> Void = {},
         setlistPlacement: SetlistPlacement = .right, placeSetlist: @escaping (SetlistPlacement) -> Void = { _ in },
         shareProject: (() -> Void)? = nil, proNotesOpen: Bool = false, proSamplersOpen: Bool = false,
         toggleProNotes: @escaping () -> Void = {}, toggleProSamplers: @escaping () -> Void = {},
         closeProDocks: @escaping () -> Void = {}) {
        self.show = show; self.documents = documents; self.remotePresentation = remotePresentation
        self.mediaDirectory = mediaDirectory; self.toggleNavigation = toggleNavigation
        self.mixerCollapsed = mixerCollapsed; self.setlistCollapsed = setlistCollapsed
        self.toggleMixer = toggleMixer; self.toggleSetlist = toggleSetlist
        self.setlistPlacement = setlistPlacement; self.placeSetlist = placeSetlist
        self.shareProject = shareProject
        self.proNotesOpen = proNotesOpen; self.proSamplersOpen = proSamplersOpen
        self.toggleProNotes = toggleProNotes; self.toggleProSamplers = toggleProSamplers
        self.closeProDocks = closeProDocks
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    @ViewBuilder private func setlistPositionOption(_ title: String, _ placement: SetlistPlacement) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { setlistPlacement == placement },
            set: { selected in if selected { placeSetlist(placement) } }))
    }
    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            let width = geometry.size.width
            let buttonWidth = remotePresentation ? TransportControlMetrics.width : TransportControlMetrics.desktopWidth(for: width)
            #else
            let width = geometry.size.width
            let buttonWidth = TransportControlMetrics.width
            #endif
            let spacing = min(6, max(3, (width - 1296) / 43))
            transportContent(width: width, spacing: spacing, buttonWidth: buttonWidth)
                .environment(\.transportControlWidth, buttonWidth)
                .frame(width: width, height: 86, alignment: .leading)
        }.frame(height: 86).clipped()
            #if !os(macOS)
            .workspaceEditor("Export", isPresented: $showingExport) { AudioExportView(project: show.snapshot.project, song: show.current, mediaDirectory: mediaDirectory) }
            #endif
            .workspaceEditor("Fadeout", isPresented: $showingFadeout) { TransportFadeoutSettings(show: show) }
            #if os(macOS)
            .background { if !remotePresentation { TransportFadeoutPresenter(show: show).frame(width: 0, height: 0) } }
            .workspaceEditor(ProTimelinePosition.clockTitle, isPresented: $showingClockPosition, scrolls: false,
                             size: CGSize(width: 530, height: 112), minimumSize: CGSize(width: 240, height: 60),
                             activates: false) {
                ProTimelinePosition(show: show, clockOnly: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(isPresented: $showingReduction) {
                if let documents { ProjectReductionView(documents: documents) }
            }
            #endif
    }
    private func transportContent(width: CGFloat, spacing: CGFloat, buttonWidth: CGFloat) -> some View {
        let groupSpacing = max(6, spacing)
        let playbackSpacing: CGFloat = 3
        let preferredWidth = TransportControlMetrics.playbackWidth
        #if os(macOS)
        let mainWidth: CGFloat = remotePresentation ? 266 : 222
        let statusWidth = width - 16 - groupSpacing - mainWidth
        let detailWidth = TransportControlMetrics.desktopDetailsWidth
        let activeProMode = proMode && !remotePresentation
        let actionsHeight = activeProMode ? TransportControlMetrics.proHeight : TransportControlMetrics.height
        let modeWidth: CGFloat = remotePresentation ? 0 : 74
        let actionWidth = 2 * TransportControlMetrics.iconWidth + 6 + modeWidth + ((documents?.projectTabCount ?? 0) > 1 ? 62 : 0)
        let automationWidth = TransportEditingButtons.controlWidth
        let editGroupSpacing: CGFloat = 8
        let playbackRoom = statusWidth - detailWidth - actionWidth - automationWidth - playbackSpacing - editGroupSpacing - 30
        let compactWidth = max(43, floor((playbackRoom - 5 * playbackSpacing) / 6))
        let playbackWidth = remotePresentation ? preferredWidth : min(preferredWidth, compactWidth)
        let playbackSpan: CGFloat? = remotePresentation ? nil : 5 * playbackWidth + 4 * playbackSpacing
        let titleInset: CGFloat = 282
        #else
        let mainWidth: CGFloat = 230
        let playbackWidth = preferredWidth
        let playbackSpan: CGFloat? = nil
        let titleInset: CGFloat = 202
        let activeProMode = false
        #endif
        let transport = show.snapshot.transport
        let running = transport.playing || show.preparingAudio
        let paused = transport.paused == true
        let playbackTitle = running ? Text(verbatim: "Stop") : Text("Play")
        return HStack(spacing: groupSpacing) {
            #if !os(macOS)
            VStack(spacing: 5) {
                Button(action: toggleNavigation) {
                    Image(systemName: "line.3.horizontal").frame(width: 32, height: 25).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Menu")
                PanelCollapseButton(collapsed: mixerCollapsed, title: "Tracks", label: "Track Mixer",
                    tooltip: "Track Mixer", action: toggleMixer).frame(width: buttonWidth)
            }
            #endif
            MasterStrip(show: show).frame(width: mainWidth)

            TransportDisplaysLive(show: show, displaysTuner: !remotePresentation, titleInset: titleInset,
                                  desktopPlaybackSpan: playbackSpan, proMode: activeProMode) {
                #if os(macOS)
                HStack(spacing: 6) {
                    if let documents, documents.projectTabCount > 1 { projectTabControls(documents) }
                    if activeProMode {
                        ProGridToolPicker(selection: $proTool)
                        proPanelButton("Clock", icon: "timer", active: showingClockPosition) { showingClockPosition.toggle() }
                        proPanelButton("Notes", icon: "note.text", active: proNotesOpen, action: toggleProNotes)
                        proPanelButton("Samplers", icon: "library.samplers", active: proSamplersOpen, action: toggleProSamplers)
                    }
                    if !remotePresentation {
                        Button {
                            proMode.toggle()
                            if !proMode {
                                showingClockPosition = false
                                closeProDocks()
                            }
                        } label: {
                            Text(verbatim: proMode ? "Simple Mode" : "Pro Mode")
                        }.buttonStyle(TransportButtonStyle(color: proMode ? JarasTheme.green : Color(hex: 0x454545),
                            active: proMode, inactiveOpacity: 1, fontSize: 10, width: 68,
                            height: actionsHeight, bordered: false))
                            .accessibilityAddTraits(proMode ? .isSelected : [])
                    }
                    saveButton(width: TransportControlMetrics.iconWidth, height: actionsHeight)
                    setlistButton(width: TransportControlMetrics.iconWidth, height: actionsHeight)
                }.fixedSize(horizontal: true, vertical: false)
                #endif
            } playback: {
                #if os(macOS)
                if activeProMode {
                    ProTransportButtons(show: show, configureFadeout: { showingFadeout = true })
                } else {
                    standardPlayback(running: running, paused: paused, title: playbackTitle,
                        width: playbackWidth, spacing: playbackSpacing, playing: transport.playing, repeatEnabled: transport.loop.enabled)
                }
                #else
                standardPlayback(running: running, paused: paused, title: playbackTitle,
                    width: playbackWidth, spacing: playbackSpacing, playing: transport.playing, repeatEnabled: transport.loop.enabled)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            #if !os(macOS)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    saveButton(width: buttonWidth)
                    exportButton(width: buttonWidth)
                }
                setlistButton(width: buttonWidth * 2 + 6)
            }.fixedSize(horizontal: true, vertical: false)
            #endif
        }
        .padding(.horizontal, 8)
    }

    private func standardPlayback(running: Bool, paused: Bool, title: Text, width: CGFloat, spacing: CGFloat,
                                  playing: Bool, repeatEnabled: Bool) -> some View {
        HStack(spacing: spacing) {
            Button { show.send(running ? .stop : .play) } label: {
                Label { title } icon: { TransportControlIcon(name: running ? "stopall" : "play", size: 14) }
            }.buttonStyle(TransportButtonStyle(color: JarasTheme.transportPlay, active: playing,
                width: width, height: TransportControlMetrics.playbackHeight, bordered: false))
                .accessibilityLabel(title).jarasHelp(ControlMappings.shared.shortcutHelp(.playStop))
                #if !os(macOS)
                .contextMenu { Button("Fadeout…") { showingFadeout = true } }
                #endif
            #if os(macOS)
            if !remotePresentation {
                Button { show.triggerTransportFadeout() } label: {
                    HStack(spacing: 2) {
                        TransportControlIcon(name: "fadeout", size: 13)
                        Text(verbatim: "Fadeout")
                    }
                }.buttonStyle(TransportButtonStyle(color: JarasTheme.yellow, inactiveOpacity: 1, inactiveForeground: .black, fontSize: 10,
                    width: width, height: TransportControlMetrics.playbackHeight, bordered: false))
                    .accessibilityLabel("Fadeout").jarasHelp("Fadeout")
                    .immediateRightClick { showingFadeout = true }
            }
            #endif
            Button { show.send(.pause) } label: { TransportControlIcon(name: "pause", size: 14) }
                .buttonStyle(TransportButtonStyle(color: JarasTheme.pauseBackground(paused), active: paused, inactiveOpacity: 1,
                    width: width, height: TransportControlMetrics.playbackHeight, bordered: false))
                .accessibilityLabel("Pause").jarasHelp("Pause").disabled(!playing)
            RepeatControl(active: repeatEnabled, width: width) { show.send(.toggleLoop) }
            TransportRecordButton(show: show, width: width)
        }.fixedSize(horizontal: true, vertical: false)
    }

    #if os(macOS)
    private func proPanelButton(_ label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { TransportControlIcon(name: icon, size: 16) }
            .buttonStyle(TransportButtonStyle(color: active ? JarasTheme.green : Color(hex: 0x454545),
                active: active, inactiveOpacity: 1, width: 30, height: TransportControlMetrics.proHeight, bordered: false))
            .accessibilityLabel(LocalizedStringKey(label)).jarasHelp(label)
    }
    #endif

    private func saveButton(width: CGFloat, height: CGFloat = TransportControlMetrics.height) -> some View {
        ProjectSaveButton(buttonWidth: width, buttonHeight: height, pending: show.needsSave, saving: show.saving, message: show.message,
            projectName: documents?.currentURL?.deletingPathExtension().lastPathComponent ?? show.snapshot.project.name,
            rename: documents.map { documents in { name in try await documents.renameProject(name) } },
            share: shareProject,
            reduceProject: documents == nil ? nil : { showingReduction = true }) { Task { await show.save() } }
    }
    #if !os(macOS)
    private func exportButton(width: CGFloat) -> some View {
        Button { showingExport = true } label: {
            Text(verbatim: "Export").font(.jarasSystem(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: width, height: TransportControlMetrics.height)
                .background(Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: "Export"))
    }
    #endif
    private func setlistButton(width: CGFloat, height: CGFloat = TransportControlMetrics.height) -> some View {
        PanelCollapseButton(collapsed: setlistCollapsed, title: "Setlist", icon: "setlist",
            label: setlistCollapsed ? "Expandir Setlist" : "Recolher Setlist",
            tooltip: setlistCollapsed ? "Restaurar largura anterior do Setlist" : "Ocultar Setlist", action: toggleSetlist)
            .frame(width: width, height: height)
            #if os(macOS)
            .contextMenu {
                if !remotePresentation {
                    setlistPositionOption("Destacar Setlist", .detached)
                    setlistPositionOption("Setlist à direita", .right)
                    setlistPositionOption("Setlist à esquerda", .left)
                }
            }
            #endif
    }

    #if os(macOS)
    private func projectTabControls(_ documents: ProjectDocuments) -> some View {
        HStack(spacing: 6) {
            tabButton(documents, direction: -1, enabled: documents.projectTabIndex > 0, label: "Previous project tab", identifier: "previousProjectTab")
            tabButton(documents, direction: 1, enabled: documents.projectTabIndex + 1 < documents.projectTabCount, label: "Next project tab", identifier: "nextProjectTab")
        }.disabled(documents.busy || TrackRecording.shared.recording || TrackRecording.shared.busy)
    }

    private func tabButton(_ documents: ProjectDocuments, direction: Int, enabled: Bool, label: String, identifier: String) -> some View {
        Button { documents.navigateProjectTab?(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
        }.buttonStyle(TransportButtonStyle(width: 25, height: 20))
            .disabled(!enabled).opacity(enabled ? 1 : 0.35)
            .accessibilityLabel(LocalizedStringKey(label)).accessibilityIdentifier(identifier)
            .jarasHelp(JarasLocalization.string(label))
    }
    #endif
}

struct TimelineNavigationControls: View {
    let show: ShowController
    var width: CGFloat = 29
    var body: some View {
        HStack(spacing: 3) {
            step(.projectStart)
            step(.previousTimelinePoint)
            step(.nextTimelinePoint)
            step(.projectEnd)
        }.fixedSize()
    }
    private func step(_ action: DAWAction) -> some View {
        Button { show.performAction(action) } label: { TransportControlIcon(name: action.rawValue, size: 16) }
            .buttonStyle(TransportButtonStyle(color: Color(hex: 0x454545), inactiveOpacity: 1,
                fontSize: 10, width: width, height: 23, bordered: false))
            .accessibilityLabel(LocalizedStringKey(action.title)).accessibilityIdentifier(action.rawValue)
            .jarasHelp(JarasLocalization.string(action.title))
    }
}

struct SongProgressBar: View {
    let position: Double?
    let start: Double?
    let end: Double?

    var body: some View {
        GeometryReader { geometry in
            if let position, let start, let end, position.isFinite, start.isFinite, end.isFinite, end > start {
                let fraction = min(1, max(0, (position - start) / (end - start)))
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.12))
                    Rectangle().fill(JarasTheme.green).frame(width: geometry.size.width * fraction)
                }
            }
        }.frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct LiveSongProgressBar: View {
    let show: ShowController
    let region: Part?
    @State private var position: Double?

    var body: some View {
        SongProgressBar(position: position, start: region?.startTime, end: region?.endTime)
            .onReceive(show.$snapshot.map { snapshot -> Double? in
                let transport = snapshot.transport
                return transport.playing || transport.paused == true ? transport.position : nil
            }.removeDuplicates()) { position = $0 }
    }
}

private struct TransportDisplaysLive<Actions: View, Playback: View>: View {
    let show: ShowController
    let displaysTuner: Bool
    let titleInset: CGFloat
    let actions: Actions
    let playback: Playback
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    let desktopPlaybackSpan: CGFloat?
    let proMode: Bool
    #if os(macOS)
    @Environment(\.desktopTimelineToolbar) private var timelineToolbar
    #endif
    @StateObject private var updates: ShowPresentationObserver

    init(show: ShowController, displaysTuner: Bool, titleInset: CGFloat, desktopPlaybackSpan: CGFloat?,
         proMode: Bool, @ViewBuilder actions: () -> Actions,
         @ViewBuilder playback: () -> Playback) {
        self.show = show
        self.displaysTuner = displaysTuner
        self.titleInset = titleInset
        self.desktopPlaybackSpan = desktopPlaybackSpan
        self.proMode = proMode
        self.actions = actions()
        self.playback = playback()
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }

    #if os(macOS)
    private var desktopEditControls: TransportEditingButtons {
        TransportEditingButtons(show: show, key: TimelineEditPreferences.desktop)
    }
    #endif
    var body: some View {
        let transport = show.snapshot.transport
        let displays = TransportSongDisplays(song: show.current, transport: transport,
            focusedRegion: show.focusedRegion.map(show.playlistRegionSourceID))
        let name = displays.current?.displayName ?? "—"
        GeometryReader { geometry in
            let sideWidth = max(132, titleInset)
            let noticeWidth = min(210, max(0, geometry.size.width / 2 - 224))
            let title = ZStack(alignment: .leading) {
                Text(verbatim: name)
                    .font(.jarasSystem(size: TransportControlMetrics.readoutSize, weight: .semibold))
                    .foregroundStyle(transport.playing ? JarasTheme.green : JarasTheme.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: max(0, geometry.size.width - 2 * sideWidth - 16), height: 27)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Current song").accessibilityValue(name)
                HStack(spacing: 9) {
                    #if os(macOS)
                    if desktopPlaybackSpan != nil { TimelineNavigationControls(show: show) }
                    #endif
                    TransportTimeDisplay(show: show)
                }
                    .frame(width: sideWidth - 8, alignment: .leading)
                    #if os(macOS)
                    .foregroundStyle(JarasTheme.licenseTitleGreen)
                    #else
                    .foregroundStyle(JarasTheme.text)
                    #endif
                    .padding(.leading, 8)
            }.frame(height: 27)
            let details = HStack(spacing: 8) {
                TempoControl(show: show)
                if displaysTuner { RegionTunerControl(show: show) }
            }.fixedSize(horizontal: true, vertical: false)
            let noticeView = FooterInformationDisplay(show: show, embedded: true)
            #if os(macOS)
            let halfHeight = geometry.size.height / 2
            VStack(spacing: 0) {
                if proMode {
                    proLayout(width: geometry.size.width, regionName: name, playing: transport.playing)
                } else {
                    title.frame(height: halfHeight)
                        .overlay(alignment: .trailing) { noticeView.frame(width: noticeWidth).padding(.trailing, 8) }
                    if let desktopPlaybackSpan {
                        let bottomInset: CGFloat = 4
                        HStack(alignment: .bottom, spacing: 8) {
                            playback.padding(.bottom, bottomInset)
                            GeometryReader { room in
                                let detailsWidth = TransportControlMetrics.desktopDetailsWidth
                                let toolsWidth = timelineToolbar == nil ? 0 : TransportControlMetrics.desktopToolsWidth
                                let toolsSpan = toolsWidth > 0 ? toolsWidth + 10 : 0
                                let editSpan = TransportEditingButtons.span
                                let detailStart = editSpan + 8
                                let scale = min(1, max(1, room.size.width - detailStart) / (detailsWidth + toolsSpan))
                                let detailsHalf = detailsWidth * scale / 2
                                // The room excludes playback and actions. Translate the
                                // panel's midpoint into this space before fitting the controls.
                                let panelCenter = geometry.size.width / 2 - (6 + desktopPlaybackSpan + 8)
                                let rightLimit = room.size.width - toolsSpan * scale - detailsHalf
                                let center = max(detailStart + detailsHalf, min(panelCenter, rightLimit))
                                let bottom = room.size.height - bottomInset
                                // REC ends eight points before this room; BPM starts at center - detailsHalf.
                                desktopEditControls
                                    .position(x: (center - detailsHalf - 8) / 2,
                                              y: bottom - TransportControlMetrics.playbackHeight / 2)
                                details.frame(width: detailsWidth)
                                    .scaleEffect(scale)
                                    .position(x: center, y: bottom - TransportControlMetrics.detailHeight * scale / 2)
                                if let timelineToolbar {
                                    let toolbarStart = center + detailsHalf
                                    let toolbarSpan = room.size.width - toolbarStart
                                    DesktopTimelineToolbarView(show: show, controls: timelineToolbar)
                                        .frame(width: max(toolsWidth, toolbarSpan / scale))
                                        .scaleEffect(scale)
                                        .position(x: toolbarStart + toolbarSpan / 2, y: bottom - 12 * scale)
                                }
                            }
                            .frame(minWidth: min(max(0, geometry.size.width - desktopPlaybackSpan - 230), 200))
                            actions.padding(.bottom, bottomInset)
                        }.padding(.leading, 6).padding(.trailing, 8).frame(height: halfHeight)
                    } else {
                        details.offset(y: -4).frame(maxWidth: .infinity).frame(height: halfHeight)
                            .overlay(alignment: .leading) { playback.padding(.leading, 6) }
                            .overlay(alignment: .trailing) { actions.padding(.trailing, 8) }
                    }
                }
            }
            #else
            VStack(spacing: 0) {
                title
                details
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { playback.padding(.leading, 6).padding(.bottom, 4) }
                .overlay(alignment: .bottomTrailing) { noticeView.frame(width: noticeWidth).padding(.trailing, 8).padding(.bottom, 4) }
            #endif
        }
        .background {
            #if os(macOS)
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: proMode || desktopPlaybackSpan == nil
                    ? JarasTheme.workspaceTransportGradient : JarasTheme.desktopTransportGradient,
                    startPoint: .top, endPoint: .bottom))
            #else
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: interfaceTheme.transportGradient,
                                     startPoint: .top, endPoint: .bottom))
            #endif
        }
        .overlay(alignment: proMode ? .bottom : .center) {
            LiveSongProgressBar(show: show, region: displays.current).padding(.horizontal, 3)
        }
        .overlay {
            #if os(macOS)
            RoundedRectangle(cornerRadius: 7).strokeBorder(JarasInterfaceTheme.lightDark.transportBorder).allowsHitTesting(false)
            #else
            RoundedRectangle(cornerRadius: 7).strokeBorder(interfaceTheme.transportBorder).allowsHitTesting(false)
            #endif
        }
    }
    #if os(macOS)
    @ViewBuilder private func proLayout(width: CGFloat, regionName: String, playing: Bool) -> some View {
        let controlsHeight = TransportControlMetrics.proHeight
        let compact = width < 1220
        let detailSpacing: CGFloat = 8
        let editSpan = TransportEditingButtons.span + 2 * detailSpacing
        let switchesSpan: CGFloat = timelineToolbar == nil ? 0 : 53 + detailSpacing
        let zoomControls = Group {
            if let timelineToolbar {
                DesktopTimelineToolbarView(show: show, controls: timelineToolbar, section: .zoom)
                    .fixedSize().frame(height: controlsHeight)
            }
        }
        let name = Text(verbatim: regionName)
            .font(.jarasSystem(size: TransportControlMetrics.readoutSize, weight: .semibold))
            .foregroundStyle(playing ? JarasTheme.green : JarasTheme.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Current song").accessibilityValue(regionName)
        let editing = desktopEditControls
        let details = HStack(spacing: detailSpacing) {
            TempoControl(show: show)
            if displaysTuner { RegionTunerControl(show: show) }
        }.fixedSize()
        let switches = Group {
            if let timelineToolbar {
                DesktopTimelineToolbarView(show: show, controls: timelineToolbar, section: .switches)
                    .fixedSize()
            }
        }
        if compact {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ProTimelinePosition(show: show)
                        .frame(maxHeight: .infinity, alignment: .center)
                    playback
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(width: max(315, width - TransportControlMetrics.desktopDetailsWidth - editSpan - switchesSpan - 24))
                VStack(spacing: 0) {
                    name
                        .padding(.leading, editSpan)
                        .padding(.trailing, switchesSpan)
                        .padding(.top, 24)
                    HStack(alignment: .bottom, spacing: detailSpacing) {
                        editing
                        details
                        switches
                    }.fixedSize()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(alignment: .topTrailing) {
                    zoomControls.padding(.trailing, 8).padding(.top, 2)
                }
        } else {
            HStack(alignment: .bottom, spacing: detailSpacing) {
                VStack(alignment: .leading, spacing: 0) {
                    ProTimelinePosition(show: show)
                        .frame(maxHeight: .infinity, alignment: .center)
                    playback
                }.fixedSize(horizontal: true, vertical: false)
                editing.frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    name
                    details
                }.frame(width: TransportControlMetrics.desktopDetailsWidth)
                switches.frame(maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 0) {
                    zoomControls
                    Spacer(minLength: 0)
                    actions
                }.fixedSize(horizontal: true, vertical: false)
            }.padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
    #endif
}

struct ProTimelinePosition: View {
    static let clockTitle = "Clock Position"
    let show: ShowController
    var clockOnly = false
    @State private var position = ["001", "1", "1", "001", "00", "00", "00", "00", "00"]
    @State private var map: (song: UUID, revision: UInt64, sections: [TimelineTempoSection], labels: TimelineTimeRuler.MusicalLabels)?

    var body: some View {
        Group {
            if clockOnly {
                GeometryReader { size in
                    let scale = min(size.size.width / 530, size.size.height / 112)
                    Text(verbatim: position[4..<8].joined(separator: ":") + "." + position[8])
                        .font(.jarasSystem(size: max(1, 62 * scale), weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color(hex: 0x8bbaff))
                        .lineLimit(1).minimumScaleFactor(0.4).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 8) {
                    fields(["BAR", "BEAT", "DIV", "TICK"], range: 0..<4)
                    Divider().frame(height: 22)
                    fields(["HR", "MIN", "SEC", "FR", "SUB"], range: 4..<9)
                }.fixedSize()
            }
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline position")
            .onReceive(show.$snapshot) { update($0) }
    }

    private func fields(_ names: [String], range: Range<Int>) -> some View {
        HStack(spacing: 5) {
            ForEach(range, id: \.self) { index in
                VStack(spacing: 0) {
                    Text(verbatim: position[index])
                        .font(.jarasSystem(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(JarasTheme.licenseTitleGreen)
                    Text(verbatim: names[index - range.lowerBound])
                        .font(.jarasSystem(size: 7, weight: .medium)).foregroundStyle(JarasTheme.secondary)
                }.frame(minWidth: index == 0 ? 30 : 21)
            }
        }
    }

    private func update(_ snapshot: ShowSnapshot) {
        let transport = snapshot.transport
        let needle = transport.playing || transport.paused == true
            ? transport.position : transport.editPosition ?? transport.position
        let seconds = needle.isFinite ? min(1e9, max(0, needle)) : 0
        var next = ["001", "1", "1", "001"]
        if !clockOnly, let song = snapshot.project.songs.first(where: { $0.id == transport.songId }) {
            if map?.song != song.id || map?.revision != show.projectRevision || (map?.sections.last?.end ?? 0) <= seconds {
                let sections = song.tempoSections(until: max(song.timelineScrollEnd, seconds + 1))
                map = (song.id, show.projectRevision, sections, TimelineTimeRuler.MusicalLabels(sections: sections))
            }
            if let map {
                let value = map.labels.position(at: seconds, sections: map.sections, divisions: song.projectTime.divisions)
                next = [String(format: "%03lld", Int64(value.bar)), String(value.beat), String(value.division),
                        String(format: "%03lld", Int64(value.tick))]
            }
        } else { map = nil }
        let subframes = Int64(floor(seconds * 3000 + 1e-7))
        let elapsed = subframes / 3000
        next += [elapsed / 3600, elapsed / 60 % 60, elapsed % 60, subframes / 100 % 30, subframes % 100]
            .map { String(format: "%02lld", $0) }
        if next != position { position = next }
    }
}

#if os(iOS)
struct NativeClockPosition: View {
    let show: ShowController
    let close: () -> Void
    @State private var preferredSize = CGSize(width: 440, height: 138)
    @GestureState private var resize = CGSize.zero

    var body: some View {
        GeometryReader { viewport in
            let left = max(0, (viewport.size.width - 440) / 2)
            let top = min(45, max(0, viewport.size.height - 94))
            let limit = CGSize(width: viewport.size.width - left, height: viewport.size.height - top)
            let size = resized(by: resize, limit: limit)
            VStack(spacing: 0) {
                HStack {
                    Text(verbatim: ProTimelinePosition.clockTitle).font(.jarasSystem(size: 14, weight: .semibold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 30) }
                        .accessibilityLabel("Close")
                }.padding(.leading, 12)
                ProTimelinePosition(show: show, clockOnly: true)
            }
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(JarasTheme.panel)
            }
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(JarasTheme.line).allowsHitTesting(false) }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(JarasTheme.secondary)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($resize) { drag, value, _ in value = drag.translation }
                        .onEnded { drag in preferredSize = resized(by: drag.translation, limit: limit) })
                    .accessibilityLabel("Resize Clock Position")
            }
            .shadow(radius: 14)
            .position(x: left + size.width / 2, y: top + size.height / 2)
        }
    }

    private func resized(by drag: CGSize, limit: CGSize) -> CGSize {
        CGSize(width: min(limit.width, max(240, preferredSize.width + drag.width)),
               height: min(limit.height, max(94, preferredSize.height + drag.height)))
    }
}
#endif

enum ProGridTool: String, CaseIterable {
    case select = "Select", cut = "Cut", mute = "Mute", solo = "Solo"
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .cut: return "scissors"
        case .mute: return "M"
        case .solo: return "S"
        }
    }
    var letter: Bool { self == .mute || self == .solo }
    static var current: ProGridTool {
        UserDefaults.standard.string(forKey: "jaras.timeline.proTool").flatMap(ProGridTool.init(rawValue:)) ?? .select
    }
}

struct ProGridToolPicker: View {
    @Binding var selection: ProGridTool
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                icon(selection).frame(width: 16, height: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xa9a9a9))
                    .frame(width: 9)
            }.frame(width: 42, height: TransportControlMetrics.proHeight)
                .background(Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Grid tool").accessibilityValue(selection.rawValue)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(ProGridTool.allCases, id: \.self) { tool in
                    Button {
                        selection = tool
                        open = false
                    } label: {
                        HStack {
                            icon(tool).frame(width: 22)
                            Text(LocalizedStringKey(tool.rawValue))
                            Spacer(minLength: 10)
                            if tool == selection { Image(systemName: "checkmark") }
                        }.frame(height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.frame(width: 140).padding(8)
        }
    }
    @ViewBuilder private func icon(_ tool: ProGridTool) -> some View {
        if tool.letter { Text(verbatim: tool.symbol).font(.system(size: 12, weight: .bold)) }
        else { Image(systemName: tool.symbol).font(.system(size: 13, weight: .semibold)) }
    }
}

struct ProTransportButtons: View {
    let show: ShowController
    let configureFadeout: () -> Void
    @ObservedObject private var recorder = TrackRecording.shared

    var body: some View {
        let transport = show.snapshot.transport
        let running = transport.playing || show.preparingAudio
        let recording = recorder.recording || recorder.countingIn
        HStack(spacing: 0) {
            navigation(.projectStart)
            navigation(.previousTimelinePoint)
            navigation(.nextTimelinePoint)
            navigation(.projectEnd)
            control(running ? "Stop" : "Play", icon: running ? "stopall" : "play",
                tint: running ? JarasTheme.green : .white) { show.send(running ? .stop : .play) }
            control("Pause", icon: "pause", tint: transport.paused == true ? JarasTheme.yellow : .white,
                enabled: transport.playing || transport.paused == true) { show.send(.pause) }
            control("Fadeout", icon: "fadeout", tint: JarasTheme.yellow) { show.triggerTransportFadeout() }
                .immediateRightClick { configureFadeout() }
            control("Record", icon: "record", tint: recording ? .white : JarasTheme.liveOffRed,
                selectedColor: recording ? JarasTheme.liveOffRed : nil, enabled: !recorder.busy || recorder.countingIn) {
                recorder.toggle(show: show)
            }
            control("Repeat", icon: "loop", tint: transport.loop.enabled ? JarasTheme.yellow : .white) {
                show.send(.toggleLoop)
            }
        }
        .padding(.horizontal, 2)
        .background(Color(hex: 0x343434), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.22)).allowsHitTesting(false) }
        .fixedSize()
    }

    private func navigation(_ action: DAWAction) -> some View {
        control(action.title, icon: action.rawValue) { show.performAction(action) }
    }

    private func control(_ title: String, icon: String, tint: Color = .white,
                         selectedColor: Color? = nil, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TransportControlIcon(name: icon, size: 18, color: tint)
                .frame(width: 31, height: TransportControlMetrics.proHeight).contentShape(Rectangle())
                .background(selectedColor ?? .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.36)
            .accessibilityLabel(LocalizedStringKey(title)).jarasHelp(title)
    }
}
#if os(macOS)
private struct DesktopTimelineToolbarView: View {
    enum Section { case all, switches, zoom }
    let show: ShowController
    @ObservedObject var controls: DesktopTimelineToolbar
    var section = Section.all
    @AppStorage(TimelineSnapPreference.key) private var snapEnabled = true
    @State private var pendingTimebase: (project: UUID, song: UUID, relative: Bool)?
    @State private var confirmingTimebase = false

    var body: some View {
        HStack(spacing: 5) {
            if section != .zoom { timelineToggles.frame(maxWidth: .infinity) }
            if section != .switches { zoomControls.fixedSize(horizontal: true, vertical: false) }
        }
        .controlSize(.small)
        .alert(Text(verbatim: JarasLocalization.string(pendingTimebase?.relative == true ? "Enable relative timebase?" : "Disable relative timebase?")), isPresented: $confirmingTimebase) {
            Button("Cancel", role: .cancel) { pendingTimebase = nil }
            Button(LocalizedStringKey(pendingTimebase?.relative == true ? "Enable" : "Disable")) { applyTimebase() }
        } message: {
            Text(LocalizedStringKey(pendingTimebase?.relative == true ? "Relative timebase: changing the project BPM adjusts item duration and playback speed to follow the tempo. With Free timebase, changing the project BPM preserves item duration and playback speed. Tempo markers with their own timebase keep their individual settings." : "Free timebase: changing the project BPM changes the grid without stretching or shortening items. Item duration and playback speed are preserved. Tempo markers with their own timebase keep their individual settings."))
        }
    }

    private var timelineToggles: some View {
        let relative = show.current?.projectTime.timebase == .relative
        return HStack(spacing: 5) {
            Button { snapEnabled.toggle() } label: {
                TransportControlIcon(name: "magnet")
                    .foregroundStyle(snapEnabled ? JarasTheme.green : JarasTheme.yellow)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(TimelineSwitchStyle())
                .accessibilityLabel("Timeline snapping").accessibilityIdentifier("timeline-snap")
                .accessibilityValue(snapEnabled ? "On" : "Off")
                .jarasHelp(snapEnabled ? "Snap on — Shift temporarily disables snapping" : "Snap off — free positioning")
            Button {
                if let song = show.current {
                    pendingTimebase = (show.snapshot.project.id, song.id, !relative)
                    confirmingTimebase = true
                }
            } label: {
                TransportControlIcon(name: "itemTimebase")
                    .font(.jarasSystem(size: 13, weight: .semibold))
                    .foregroundStyle(relative && !controls.movingRegion ? JarasTheme.green : JarasTheme.yellow)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(TimelineSwitchStyle())
                .accessibilityLabel("Relative timebase").accessibilityIdentifier("timeline-timebase")
                .accessibilityValue(relative && !controls.movingRegion ? "Enabled" : "Disabled")
                .disabled(show.current == nil || controls.movingRegion)
        }
    }

    private var zoomControls: some View {
        DesktopZoomControls(
            height: .init(label: "Track height", toggleLabel: "Toggle track height", id: "track-height",
                          value: Binding(get: { controls.trackHeight }, set: { controls.changeTrackHeight?($0) }),
                          range: controls.limits.tracks, active: controls.trackHeightMemory != nil,
                          toggle: controls.toggleMinimumTrackHeight),
            time: .init(label: "Timeline zoom", toggleLabel: "Toggle timeline zoom", id: "timeline-zoom",
                        value: Binding(get: { log(max(controls.limits.zoom.lowerBound, controls.zoom)) },
                                       set: { controls.changeZoom?(exp($0)) }),
                        range: log(controls.limits.zoom.lowerBound)...log(controls.limits.zoom.upperBound),
                        active: controls.zoomMemory != nil, toggle: controls.toggleMinimumZoom))
    }

    private func applyTimebase() {
        defer { pendingTimebase = nil }
        guard let pending = pendingTimebase, pending.project == show.snapshot.project.id,
              let song = show.current, song.id == pending.song else { return }
        var settings = song.projectTime
        settings.timebase = pending.relative ? .relative : .free
        if show.configureProjectTime(bpm: song.bpm, beats: song.meterBeats, unit: song.meterUnit, settings: settings) {
            GlobalProjectTiming(bpm: song.bpm, beats: song.meterBeats, unit: song.meterUnit, settings: settings).save()
        }
    }

    private struct TimelineSwitchStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 4)
            configuration.label
                .background(Color(hex: configuration.isPressed ? 0x525252 : 0x454545), in: shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.23)) }
        }
    }

}
#endif

struct DesktopZoomControls: View {
    struct Axis {
        let label: LocalizedStringKey
        let toggleLabel: LocalizedStringKey
        let id: String
        let value: Binding<Double>
        let range: ClosedRange<Double>
        let active: Bool
        let toggle: () -> Void
    }
    let height: Axis
    let time: Axis

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 0) {
                ZoomButton(symbol: "fitTracks", label: height.toggleLabel, id: height.id + "-memory",
                           active: height.active, action: height.toggle)
                Rectangle().fill(Color(hex: 0x393939)).frame(width: 1)
                ZoomButton(symbol: "fitTime", label: time.toggleLabel, id: time.id + "-memory",
                           active: time.active, action: time.toggle)
            }.frame(height: 24)
                .background(Color(hex: 0x4c4c4c), in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 0) {
                ZoomSlider(symbol: "trackHeightAxis", label: height.label, id: height.id + "-slider",
                           value: height.value, range: height.range)
                Rectangle().fill(Color(hex: 0x242424)).frame(width: 1)
                ZoomSlider(symbol: "timelineZoomAxis", label: time.label, id: time.id + "-slider",
                           value: time.value, range: time.range)
            }.frame(height: 24)
                .background(Color(hex: 0x343434), in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private struct ZoomButton: View {
        let symbol: String
        let label: LocalizedStringKey
        let id: String
        let active: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                TransportControlIcon(name: symbol, size: 15, color: active ? JarasTheme.green : Color(hex: 0xd5d5d5))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
                .accessibilityAddTraits(active ? .isSelected : [])
        }
    }

    private struct ZoomSlider: View {
        let symbol: String
        let label: LocalizedStringKey
        let id: String
        @Binding var value: Double
        let range: ClosedRange<Double>

        private var span: Double { range.upperBound - range.lowerBound }
        private var fraction: Double { span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0 }
        private func move(by offset: Double) {
            value = range.lowerBound + min(1, max(0, fraction + offset)) * span
        }

        var body: some View {
            if #available(macOS 14, iOS 17, *) {
                slider.focusable().focusEffectDisabled()
            } else {
                slider
            }
        }

        private var slider: some View {
            HStack(spacing: 2) {
                TransportControlIcon(name: symbol, size: 13, color: Color(hex: 0xc5c5c5))
                GeometryReader { geometry in
                    let travel = max(1, geometry.size.width - 10)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: 0x202020)).frame(height: 4).padding(.horizontal, 5)
                        Circle().fill(Color(hex: 0xa4a4a4)).frame(width: 10, height: 10)
                            .offset(x: travel * fraction)
                    }.frame(height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged {
                            let fraction = min(1, max(0, ($0.location.x - 5) / travel))
                            value = range.lowerBound + fraction * span
                        })
                }
            }.padding(.horizontal, 3).frame(width: 68, height: 24)
                #if os(macOS)
                .onMoveCommand { direction in
                    if direction == .left { move(by: -0.025) }
                    if direction == .right { move(by: 0.025) }
                }
                #endif
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label).accessibilityIdentifier(id)
                .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded()))%"))
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { move(by: 0.025) }
                    if direction == .decrement { move(by: -0.025) }
                }
        }
    }
}

private struct TransportTimeDisplay: View {
    let show: ShowController
    @State private var seconds = 0

    var body: some View {
        let clock = String(format: "%02lld:%02lld", Int64(seconds / 60 % 60), Int64(seconds % 60))
        let hours = seconds >= 3600 ? String(format: "%02lld:", Int64(seconds / 3600)) : ""
        Text(verbatim: hours + clock)
            .fixedSize()
            .accessibilityLabel("Transport time").accessibilityValue(hours + clock)
            #if os(macOS)
            .font(.jarasSystem(size: TransportControlMetrics.readoutSize, weight: .semibold))
            #else
            .font(.custom("Georgia-Italic", size: TransportControlMetrics.readoutSize))
            #endif
            .monospacedDigit().lineLimit(1)
            .onReceive(show.$snapshot) { update($0) }
    }

    private func update(_ snapshot: ShowSnapshot) {
        let transport = snapshot.transport
        let needle = transport.playing || transport.paused == true ? transport.position : transport.editPosition ?? transport.position
        let position = needle.isFinite ? max(0, needle) : 0
        let nextSeconds = Int(min(position, Double(Int.max / 2)))
        if seconds != nextSeconds { seconds = nextSeconds }

    }
}

#if os(macOS)
struct FooterPlaylistDisplay: View {
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    var height: CGFloat = 25
    var scalesToAvailableHeight = false
    var showsNotices = false
    init(show: ShowController, height: CGFloat = 25, scalesToAvailableHeight: Bool = false, showsNotices: Bool = false) {
        self.show = show; self.height = height; self.scalesToAvailableHeight = scalesToAvailableHeight; self.showsNotices = showsNotices
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    private var duration: String {
        // listedRegions contains the selected playlist's root regions only;
        // children inside a special region already belong to its full span.
        let total = show.listedRegions.reduce(0.0) { sum, region in
            let seconds = region.endTime - region.startTime
            return sum + (seconds.isFinite ? max(0, seconds) : 0)
        }
        let seconds = Int(min(Double(Int.max / 2), total))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var body: some View {
        let transport = show.snapshot.transport
        let displays = TransportSongDisplays(song: show.current, transport: transport, focusedRegion: show.focusedRegion.map(show.playlistRegionSourceID))
        let total = duration
        if scalesToAvailableHeight {
            // Capture model strings before this local geometry scope. Resizing
            // changes fonts without sorting the playlist again for every pixel.
            GeometryReader { geometry in
                FooterSongDisplays(next: displays.next?.displayName, nextBPM: displays.nextBPM,
                    queued: displays.queued?.displayName, queuedBPM: displays.queuedBPM,
                    subPlaying: transport.subPlay.playing, duration: total, height: max(25, geometry.size.height - 2),
                    stackedSongNames: true, noticeShow: showsNotices ? show : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            FooterSongDisplays(next: displays.next?.displayName, nextBPM: displays.nextBPM,
                queued: displays.queued?.displayName, queuedBPM: displays.queuedBPM, subPlaying: transport.subPlay.playing, duration: total, height: height, stackedSongNames: true)
        }
    }
}
#endif

struct FooterInformationDisplay: View {
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    init(show: ShowController, documents: ProjectDocuments? = nil, embedded: Bool = false) {
        self.show = show; self.documents = documents; self.embedded = embedded
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    var documents: ProjectDocuments? = nil
    var embedded = false
    private var displayHeight: CGFloat { embedded ? 25 : 21 }
    private var hasMultiLoop: Bool {
        guard let song = show.current, show.snapshot.transport.multiLoopsBypassed != true else { return false }
        let transport = show.snapshot.transport
        let region = transport.playing ? show.pitchRegion : song.parts.first { $0.id == (show.focusedRegion.map(show.playlistRegionSourceID) ?? transport.regionId) }
        guard let region else { return false }
        if region.totalLoop == true || (region.multiLoops ?? []).contains(where: { $0.enabled != false }) { return true }
        if let parent = region.parentRegionID {
            return song.parts.contains { $0.id == parent && ($0.totalLoop == true || ($0.multiLoops ?? []).contains(where: { $0.enabled != false })) }
        }
        return song.parts.contains { $0.parentRegionID == region.id && ($0.totalLoop == true || ($0.multiLoops ?? []).contains(where: { $0.enabled != false })) }
    }
    private var information: String {
        if !show.capacityWarning.isEmpty { return JarasLocalization.string(show.capacityWarning) }
        if show.preparingAudio { return JarasLocalization.string("Preparing audio…") }
        if let notice = show.snapshot.transport.automaticSectionNotice { return notice }
        if show.snapshot.transport.loop.enabled { return "Loop Ativo" }
        if show.snapshot.transport.ignoreNextAfter != nil { return "Ignore Next" }
        if hasMultiLoop { return JarasLocalization.string("This song has an active multiloop") }
        return ""
    }
    // Read the transport clock for beat pulses through tempo changes,
    // seeks and loop wraps. Static notices do not subscribe to its samples.
    static func loopBeatPhase(transport: TransportState, song: Song?) -> Int? {
        guard transport.playing, transport.loop.enabled,
              let marker = song?.activeTempoMarker(at: transport.position), let bpm = marker.tempoBPM else { return nil }
        let beat = max(0, transport.position - marker.position) * bpm / 60
        let index = Int(beat)
        return beat - Double(index) < 0.45 ? 0 : (index.isMultiple(of: 2) ? 1 : 3)
    }
    var body: some View {
        let message = information
        Group {
            if embedded {
                Text(verbatim: message)
                    #if os(macOS)
                    .font(.jarasSystem(size: 13, weight: .bold))
                    #else
                    .font(.jarasSystem(size: 10, weight: .bold))
                    #endif
                    .lineLimit(1)
                    .foregroundStyle(JarasTheme.yellow)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 3).frame(height: displayHeight)
                    .allowsHitTesting(false)
            } else {
                #if os(macOS)
                NativeTransportInformation(show: show, message: message,
                    steady: hasMultiLoop && show.snapshot.transport.ignoreNextAfter == nil && !show.snapshot.transport.loop.enabled)
                    .frame(height: displayHeight)
                #else
                if show.snapshot.transport.playing && show.snapshot.transport.loop.enabled {
                    TimelineView(.periodic(from: .now, by: 0.05)) { _ in messageDisplay(message) }
                } else { messageDisplay(message) }
                #endif
            }
        }
        .overlay { if !embedded { RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false) } }
        .accessibilityLabel("Information").accessibilityValue(message)
        .accessibilityHidden(embedded && message.isEmpty)
    }
    private func messageDisplay(_ message: String) -> some View {
        TransportInformationMessage(message: message,
            beatPhase: Self.loopBeatPhase(transport: show.snapshot.transport, song: show.current),
            steady: hasMultiLoop && show.snapshot.transport.ignoreNextAfter == nil && !show.snapshot.transport.loop.enabled,
            height: displayHeight, cornerRadius: 4)
            .font(.jarasSystem(size: 10, weight: .bold)).lineLimit(1).truncationMode(.tail)
    }
}

#if os(macOS)
/// Pulse the retained notice layers without relaying each beat through SwiftUI
/// layout. The timing and colors remain shared with the remote presentation.
private struct NativeTransportInformation: NSViewRepresentable {
    let show: ShowController
    let message: String
    let steady: Bool
    func makeNSView(context: Context) -> NativeTransportInformationView { NativeTransportInformationView() }
    func updateNSView(_ view: NativeTransportInformationView, context: Context) {
        view.configure(message: message, steady: steady) { [weak show] in
            guard let show else { return nil }
            return FooterInformationDisplay.loopBeatPhase(transport: show.snapshot.transport, song: show.current)
        }
    }
    static func dismantleNSView(_ view: NativeTransportInformationView, coordinator: ()) { view.stop() }
}
private final class NativeTransportInformationView: NSView {
    private let text = CATextLayer()
    private var message = "", steady = false
    private var beat: () -> Int? = { nil }
    private var timer: Timer?
    private var interval = 0.0
    private var paintedPhase: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layerContentsRedrawPolicy = .never
        let actions = Dictionary(uniqueKeysWithValues: ["position", "bounds", "string", "foregroundColor", "backgroundColor", "cornerRadius", "contentsScale"].map { ($0, NSNull()) })
        layer?.actions = actions; layer?.masksToBounds = true; layer?.cornerRadius = 4
        text.actions = actions; text.alignmentMode = .center; text.truncationMode = .end
        text.font = NSFont.jarasSystemFont(ofSize: 10, weight: .bold); text.fontSize = 10
        layer?.addSublayer(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(message: String, steady: Bool, beat: @escaping () -> Int?) {
        if self.message != message { self.message = message; text.string = message; paintedPhase = nil }
        if self.steady != steady { self.steady = steady; paintedPhase = nil }
        self.beat = beat
        updateTimer(); paint()
    }
    override func layout() { super.layout(); updateGeometry(); paint() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateGeometry(); updateTimer(); paint() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
    private func updateGeometry() {
        text.contentsScale = window?.backingScaleFactor ?? 1
        let height = ceil(NSFont.jarasSystemFont(ofSize: 10, weight: .bold).ascender - NSFont.jarasSystemFont(ofSize: 10, weight: .bold).descender + 2)
        let frame = CGRect(x: 3, y: max(0, (bounds.height - height) / 2), width: max(0, bounds.width - 6), height: height)
        if text.frame != frame { text.frame = frame }
    }
    private func updateTimer() {
        let next = window == nil || message.isEmpty || steady ? 0 : beat() != nil ? 0.05 : 0.5
        guard next != interval else { return }
        stop(); interval = next
        guard next > 0 else { return }
        let clock = Timer(timeInterval: next, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.paint() }
        }
        timer = clock; RunLoop.main.add(clock, forMode: .common)
    }
    private func paint() {
        let beatPhase = beat()
        let phase = beatPhase ?? (steady || message.isEmpty ? nil : Int(Date.timeIntervalSinceReferenceDate * 2) % 4)
        let state = phase ?? -1
        guard state != paintedPhase else { return }
        paintedPhase = state
        let bright = phase == 0 || (beatPhase == nil && phase?.isMultiple(of: 2) == true)
        text.foregroundColor = NSColor(bright ? Color.red : phase == nil || phase == 1 ? JarasTheme.green : JarasTheme.yellow).cgColor
        layer?.backgroundColor = NSColor(bright ? JarasTheme.yellow : phase == nil ? JarasTheme.display : Color.black).cgColor
    }
    func stop() { timer?.invalidate(); timer = nil; interval = 0 }
    deinit { timer?.invalidate() }
}
#endif

/// Shared notice colors and pulse for the Mac, iPad and iPhone.
struct TransportInformationMessage: View {
    let message: String
    var beatPhase: Int? = nil
    var steady = false
    var height: CGFloat = 25
    var cornerRadius: CGFloat = 0
    var body: some View {
        Group {
            if let phase = beatPhase {
                pulse(bright: phase == 0, green: phase == 1)
            } else if steady || message.isEmpty {
                Text(verbatim: message.isEmpty ? " " : message).foregroundStyle(JarasTheme.green)
                    .frame(maxWidth: .infinity).frame(height: height)
                    .background(JarasTheme.display, in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { tick in
                    let phase = Int(tick.date.timeIntervalSinceReferenceDate * 2) % 4
                    pulse(bright: phase.isMultiple(of: 2), green: phase == 1)
                }
            }
        }
    }
    private func pulse(bright: Bool, green: Bool) -> some View {
        Text(verbatim: message)
            .foregroundStyle(bright ? Color.red : green ? JarasTheme.green : JarasTheme.yellow)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(bright ? JarasTheme.yellow : .black, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct SongNameDisplay: View {
    let title: String
    let name: String?
    let bpm: Double?
    var color: Color = JarasTheme.yellow
    var fontScale: CGFloat = 1
    var labelFontScale: CGFloat? = nil
    // Only the resizable desktop footer opts in. Transport and remote keep
    // their compact single-line presentation.
    var stackedHeight: CGFloat? = nil
    var body: some View {
        if let height = stackedHeight {
            let padding = min(6, max(0, (height - 25) * 0.05))
            let spacing = min(3, max(0, (height - 25) * 0.04))
            VStack(alignment: .leading, spacing: spacing) {
                HStack(spacing: 4 * (labelFontScale ?? fontScale)) {
                    Text(LocalizedStringKey(title))
                        .font(.jarasSystem(size: 8 * (labelFontScale ?? fontScale), weight: .bold, design: .rounded)).italic()
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.jarasSystem(size: 7 * (labelFontScale ?? fontScale), weight: .bold))
                }
                .foregroundStyle(JarasTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: songText)
                    .font(.jarasSystem(size: 12 * fontScale, weight: .semibold)).foregroundStyle(color)
                    .multilineTextAlignment(.leading).lineLimit(nil).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 8).padding(.vertical, padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            inlineDisplay
        }
    }
    private var songText: String {
        (name ?? "—") + (bpm.map { " - " + String(format: "%g", $0) + " bpm" } ?? "")
    }
    private var inlineDisplay: some View {
        HStack(spacing: 5 * fontScale) {
            Text(LocalizedStringKey(title)).font(.jarasSystem(size: 10 * (labelFontScale ?? fontScale), weight: .bold, design: .rounded)).italic()
                .foregroundStyle(JarasTheme.secondary).fixedSize()
            Image(systemName: "chevron.right").font(.jarasSystem(size: 9 * (labelFontScale ?? fontScale), weight: .bold)).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: songText)
                .font(.jarasSystem(size: 12 * fontScale, weight: .semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).clipped()
    }
}

struct FooterSongDisplays: View {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    let next: String?
    let nextBPM: Double?
    let queued: String?
    let queuedBPM: Double?
    let subPlaying: Bool
    let duration: String
    var height: CGFloat = 25
    var stackedSongNames = false
    var noticeShow: ShowController? = nil
    // Grow text continuously, keeping room for song names in each column.
    private var fontScale: CGFloat { max(1, sqrt(height / 25)) }
    private var labelFontScale: CGFloat { 1 + (fontScale - 1) * 0.35 }
    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 2)
            let noticeWidth = noticeShow == nil ? 0 : min(300, width * 0.25)
            let songWidth = (width * 0.9 - noticeWidth) / 2
            HStack(spacing: 0) {
                SongNameDisplay(title: "Next song label", name: next, bpm: nextBPM, fontScale: fontScale, labelFontScale: labelFontScale, stackedHeight: stackedSongNames ? height : nil).frame(width: songWidth)
                Rectangle().fill(JarasTheme.line).frame(width: 1)
                if let noticeShow {
                    FooterInformationDisplay(show: noticeShow, embedded: true)
                        .frame(width: max(0, noticeWidth - 1), height: height)
                    Rectangle().fill(JarasTheme.line).frame(width: 1)
                }
                SongNameDisplay(title: subPlaying ? "Sub Play" : "Queued", name: queued, bpm: queuedBPM, fontScale: fontScale, labelFontScale: labelFontScale, stackedHeight: stackedSongNames ? height : nil).frame(width: songWidth)
                Rectangle().fill(JarasTheme.line).frame(width: 1)
                Text(verbatim: duration).font(.jarasSystem(size: 12 * fontScale, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(JarasTheme.yellow).lineLimit(1).minimumScaleFactor(0.3)
                    .frame(width: width * 0.10, height: height).accessibilityLabel("Playlist duration")
            }
        }.frame(height: height).background(interfaceTheme.display).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false))
    }
}

private struct PanelCollapseButton: View {
    let collapsed: Bool
    let title: String
    var icon: String? = nil
    let label: String
    let tooltip: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let icon { TransportControlIcon(name: icon, size: 17) }
                else { Text(verbatim: title).font(.jarasSystem(size: 9, weight: .bold)) }
            }
                .foregroundStyle(collapsed ? Color.white : Color.black)
                .frame(maxWidth: .infinity).frame(height: TransportControlMetrics.height)
                .background(collapsed ? Color(hex: 0x454545) : JarasTheme.green)
                #if os(macOS)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                #else
                .clipShape(RoundedRectangle(cornerRadius: 4))
                #endif
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityValue(collapsed ? "Hidden" : "Shown").jarasHelp(tooltip)
    }
}

#if os(macOS)
/// Finish the time-signature edit even when the destination is not focusable.
private struct TempoFieldOutsideClick: NSViewRepresentable {
    let active: Bool
    let dismiss: () -> Void
    func makeNSView(context: Context) -> TempoFieldOutsideClickView { TempoFieldOutsideClickView() }
    func updateNSView(_ view: TempoFieldOutsideClickView, context: Context) {
        view.active = active; view.dismiss = dismiss
    }
}
private final class TempoFieldOutsideClickView: NSView {
    var active = false
    var dismiss: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }
    func handle(_ event: NSEvent) {
        guard active, let window, event.window === window,
              !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // Do this before forwarding the event so the destination receives its
        // usual click and may acquire focus itself (including the other field).
        window.makeFirstResponder(nil)
        active = false
        dismiss?()
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
#endif

struct TempoControl: View {
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    var documents: ProjectDocuments? = nil
    @State private var editing = false
    @State private var bpmDraft = "120"
    @State private var beats = "4"
    @State private var unit = "4"
    @State private var invalidBPM = false
    @State private var hoveredStep: Double?
    @State private var bpmShake = 0.0
    @FocusState private var meterFocus: Int?
    @FocusState private var bpmFocus: Bool
    let panelHeight: CGFloat
    init(show: ShowController, documents: ProjectDocuments? = nil, panelHeight: CGFloat = TransportControlMetrics.detailHeight) {
        self.show = show; self.documents = documents; self.panelHeight = panelHeight
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    private var bpmText: String {
        String(format: "%g", show.tempoControlBPM)
    }
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                MetronomeModeButton()
                MetronomeControl().environment(\.transportControlWidth, 32)
            }
            HStack(spacing: 2) {
                TextField("4", text: $beats).focused($meterFocus, equals: 0)
                    .frame(width: 24).accessibilityLabel("Beats per bar")
                    .disabled(!show.transportMeterEditingAllowed)
                    #if os(macOS)
                    .background(TempoFieldOutsideClick(active: meterFocus == 0) { meterFocus = nil })
                    .immediateRightClick {}
                    #endif
                    .onSubmit { commitMeter(); meterFocus = nil }
                Text(verbatim: "/").foregroundStyle(JarasTheme.text).frame(width: 6).fixedSize()
                TextField("4", text: $unit).focused($meterFocus, equals: 1)
                    .frame(width: 24).accessibilityLabel("Beat unit")
                    .disabled(!show.transportMeterEditingAllowed)
                    #if os(macOS)
                    .background(TempoFieldOutsideClick(active: meterFocus == 1) { meterFocus = nil })
                    .immediateRightClick {}
                    #endif
                    .onSubmit { commitMeter(); meterFocus = nil }
            }
            HStack(spacing: 2) {
                tempoStep(-1, symbol: "minus")
                Button {
                    show.tapTempo()
                } label: {
                    VStack(spacing: 0) {
                        Text(bpmText).font(.jarasSystem(size: 15, weight: .semibold, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(show.tempoControlNeedsRender ? JarasTheme.yellow : JarasTheme.text)
                        Text("BPM").font(.jarasSystem(size: 8))
                    }.frame(width: 54, height: min(35, TransportControlMetrics.detailHeight - 2))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("BPM · Tap tempo")
                    .jarasHelp("Tap tempo · Right-click to edit BPM")
                    .immediateRightClick { guard show.tempoInputAllowed else { return }; bpmDraft = bpmText; invalidBPM = false; editing = true }
                tempoStep(1, symbol: "plus")
            }
        }.textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            .font(.jarasSystem(size: 13, design: .monospaced))
            .padding(.horizontal, 4)
            .frame(height: panelHeight)
            .background(TransportDetailSurface())
            .onAppear(perform: refreshMeter)
            .onChange(of: meterFocus) { if $0 == nil { commitMeter() } }
            .onChange(of: show.tempoInputAllowed) { if !$0 { editing = false } }
            .onChange(of: show.transportMeter?.beats) { _ in if meterFocus == nil { refreshMeter() } }
            .onChange(of: show.transportMeter?.unit) { _ in if meterFocus == nil { refreshMeter() } }
            .onChange(of: show.transportMeterEditingAllowed) { if !$0 { meterFocus = nil; refreshMeter() } }
            .onChange(of: show.snapshot.project.id) { _ in show.resetTapTempo(); refreshMeter() }
            .workspaceEditor("Tempo", isPresented: $editing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("BPM").font(.jarasHeadline)
                    TextField("BPM", text: $bpmDraft).textFieldStyle(.roundedBorder).focused($bpmFocus).onSubmit(commitBPM)
                        .immediateRightClick {}
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalidBPM ? Color.red : .clear, lineWidth: 1.5))
                        .modifier(InputValidationShake(animatableData: bpmShake))
                    if invalidBPM { Text("Enter a BPM between 60 and 300.").font(.jarasCaption).foregroundStyle(.red) }
                    HStack {
                        Spacer()
                        Button("Apply", action: commitBPM).keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 260).background(JarasTheme.panel).onAppear { bpmFocus = true }
            }
    }
    private func tempoStep(_ delta: Double, symbol: String) -> some View {
        Button { show.resetTapTempo(); show.adjustTempo(delta) } label: {
            Image(systemName: symbol).font(.jarasSystem(size: TransportControlMetrics.stepSymbolSize, weight: .medium))
                .frame(width: 20, height: 23)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(hoveredStep == delta ? JarasTheme.secondary.opacity(0.65) : .clear)
                    .allowsHitTesting(false))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(delta > 0 ? "Increase BPM" : "Decrease BPM")
            #if os(macOS)
            .onHover { hovering in
                if hovering { hoveredStep = delta }
                else if hoveredStep == delta { hoveredStep = nil }
            }
            #endif
            .jarasHelp(delta > 0 ? "Increase BPM · Right-click to map" : "Decrease BPM · Right-click to map")
            .immediateRightClick { ControlMappings.shared.begin(track: nil, command: delta > 0 ? "tempoUp" : "tempoDown") }
    }
    private func refreshMeter() {
        let meter = show.transportMeter
        beats = String(meter?.beats ?? 4); unit = String(meter?.unit ?? 4)
    }
    private func commitMeter() {
        defer { refreshMeter() }
        guard show.transportMeterEditingAllowed, let beats = Int(beats), let unit = Int(unit) else { return }
        show.setTransportMeter(beats: beats, unit: unit)
    }
    private func commitBPM() {
        guard show.tempoInputAllowed else { editing = false; return }
        guard let value = Double(bpmDraft.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            rejectBPM(bpmText); return
        }
        let limited = min(300, max(60, value))
        guard limited == value else { rejectBPM(String(format: "%g", limited)); return }
        show.resetTapTempo(); show.setTypedTempo(value); editing = false
    }
    private func rejectBPM(_ replacement: String) {
        bpmDraft = replacement; invalidBPM = true; bpmFocus = true
        withAnimation(.linear(duration: 0.35)) { bpmShake += 1 }

    }
}
private struct ProjectSaveButton: View {
    let buttonWidth: CGFloat
    let buttonHeight: CGFloat
    let pending: Bool
    let saving: Bool
    let message: String
    var projectName = ""
    var rename: ((String) async throws -> Void)? = nil
    var share: (() -> Void)? = nil
    var reduceProject: (() -> Void)? = nil
    let action: () -> Void
    @State private var showingOptions = false
    @State private var draftName = ""
    @State private var renameError = ""
    @State private var renaming = false
    var body: some View {
        Button { if pending { action() } } label: {
            Label {
                Text(verbatim: "Save")
            } icon: {
                ControlIcon(name: pending ? "save" : "check", size: 17, tintable: pending)
            }
                .labelStyle(.iconOnly)
                .frame(width: buttonWidth, height: buttonHeight)
                .foregroundStyle(pending ? Color.black : .white)
                .background(RoundedRectangle(cornerRadius: 6).fill(pending ? JarasTheme.yellow : Color(hex: 0x454545)))
                .modifier(JarasSavePulse(active: pending && !saving))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(saving)
            .accessibilityValue(saving ? Text("Salvando…") : Text(""))
            #if os(macOS)
            .immediateRightClick { draftName = projectName; renameError = ""; showingOptions = true }
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Project name").font(.headline)
                    TextField("Project name", text: $draftName).textFieldStyle(.roundedBorder)
                        .onSubmit { saveName() }.disabled(renaming)
                    if !renameError.isEmpty { Text(verbatim: JarasLocalization.string(renameError)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    Button("Save") { saveName() }.disabled(rename == nil || renaming || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if share != nil || reduceProject != nil {
                        Divider()
                        HStack {
                            if let share {
                                Button { showingOptions = false; share() } label: { Text(verbatim: "Share") }
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if let reduceProject {
                                Button { showingOptions = false; reduceProject() } label: {
                                    Text("Reduzir projeto").frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }.padding(16).frame(width: 440)
            }
            #endif
            .jarasHelp(message.isEmpty ? "Save" : message)
    }
    private func saveName() {
        guard let rename, !renaming else { return }
        renaming = true; renameError = ""
        Task { @MainActor in
            defer { renaming = false }
            do { try await rename(draftName); showingOptions = false }
            catch { renameError = error.localizedDescription }
        }
    }
}
private struct JarasSavePulse: ViewModifier {
    let active: Bool
    @State private var bright = true
    func body(content: Content) -> some View {
        #if os(macOS)
        NativeSavePulse(content: content, active: active)
            .fixedSize(horizontal: true, vertical: true)
        #else
        content
            .opacity(active ? (bright ? 1 : 0.48) : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .none, value: bright)
            // Keep this status indicator alive when Native disables control transitions.
            .transaction { $0.disablesAnimations = false }
            .onAppear { bright = !active }
            .onChange(of: active) { bright = !$0 }
        #endif
    }
}
#if os(macOS)
/// The save pulse changes only a retained layer. SwiftUI does not need a new
/// display list and AppKit window layout for every frame of this idle animation.
private struct NativeSavePulse<Content: View>: NSViewRepresentable {
    let content: Content
    let active: Bool
    func makeNSView(context: Context) -> NativeSavePulseHost<Content> {
        NativeSavePulseHost(rootView: content)
    }
    func updateNSView(_ view: NativeSavePulseHost<Content>, context: Context) {
        view.rootView = content
        view.setPulse(active)
    }
}
private final class NativeSavePulseHost<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView); wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func setPulse(_ active: Bool) {
        guard let layer else { return }
        if active {
            guard layer.animation(forKey: "savePulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.48; pulse.duration = 0.9
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "savePulse")
        } else {
            layer.removeAnimation(forKey: "savePulse")
        }
    }
}
#endif
enum TransportControlMetrics {
    static let width: CGFloat = 60
    static let height: CGFloat = 26
    static let iconWidth: CGFloat = 34
    static let proHeight: CGFloat = 30
    static let playbackWidth: CGFloat = 60
    #if os(macOS)
    static let desktopDetailsWidth: CGFloat = 384
    static let desktopToolsWidth: CGFloat = 252
    static let playbackHeight: CGFloat = 24
    static let detailHeight: CGFloat = 35
    static let metronomeButtonHeight: CGFloat = 24
    #else
    static let playbackHeight: CGFloat = 28
    static let detailHeight: CGFloat = 43
    static let metronomeButtonHeight: CGFloat = 28
    #endif
    static let readoutSize: CGFloat = 18
    static let font: CGFloat = 10
    static let stepSymbolSize: CGFloat = 12
    static func desktopWidth(for availableWidth: CGFloat) -> CGFloat {
        // Share extra room with the controls, instead of leaving it all in
        // spacers. Keep enough room for the tempo, timer and group separation.
        max(52, (52 + (availableWidth - 1296) / 13).rounded(.down))
    }
}
private struct TransportControlWidthKey: EnvironmentKey {
    static let defaultValue = TransportControlMetrics.width
}
extension EnvironmentValues {
    var transportControlWidth: CGFloat {
        get { self[TransportControlWidthKey.self] }
        set { self[TransportControlWidthKey.self] = newValue }
    }
}
struct TransportEditingButtons: View {
    static let controlWidth: CGFloat = 28
    private static let spacing: CGFloat = 4
    static var span: CGFloat { 2 * controlWidth + spacing }

    let show: ShowController
    let key: String

    var body: some View {
        let height = TransportControlMetrics.playbackHeight
        HStack(spacing: Self.spacing) {
            TimelineEditButton(show: show, key: key, width: Self.controlWidth, height: height)
            TransportEnvelopeButton(show: show, width: Self.controlWidth, height: height)
        }.fixedSize()
    }
}

private struct TimelineEditButton: View {
    @AppStorage private var enabled: Bool
    let show: ShowController?
    let width: CGFloat
    let height: CGFloat

    init(show: ShowController?, key: String, width: CGFloat, height: CGFloat) {
        self.show = show; self.width = width; self.height = height
        _enabled = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        Button {
            enabled.toggle()
            if !enabled, let show, show.snapshot.transport.beatSeek != nil { show.send(.cancelBeatSeek) }
        } label: {
            TransportControlIcon(name: "editCursor", size: 17)
        }.buttonStyle(TransportButtonStyle(color: enabled ? JarasTheme.green : Color(hex: 0x454545),
            active: enabled, inactiveOpacity: 1, width: width, height: height, bordered: false))
            .accessibilityLabel("Edit").accessibilityIdentifier("editMode")
            .accessibilityAddTraits(enabled ? .isSelected : [])
    }
}

private struct TransportEnvelopeButton: View {
    @ObservedObject var show: ShowController
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let active = show.allTrackAutomationLanesVisible
        Button { show.toggleAllTrackAutomationLanes() } label: {
            TransportControlIcon(name: "automationLanes", size: 17)
        }.buttonStyle(TransportButtonStyle(color: active ? JarasTheme.green : Color(hex: 0x454545),
            active: active, inactiveOpacity: 1, width: width, height: height, bordered: false))
            .accessibilityLabel("Track envelopes").accessibilityIdentifier("track-envelopes")
            .accessibilityAddTraits(active ? .isSelected : [])
            .disabled(!show.canToggleAllTrackAutomationLanes)
    }
}

struct TransportButtonStyle: ButtonStyle {
    var color = JarasTheme.panel
    var active = false
    var inactiveOpacity: Double = 0.45
    var activeForeground = Color.black
    var inactiveForeground = JarasTheme.text
    var horizontalPadding: CGFloat = 9
    var fontSize: CGFloat = 12
    var width: CGFloat? = nil
    var height: CGFloat = 32
    var bordered = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.jarasSystem(size: fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.75)
            .fixedSize(horizontal: width == nil, vertical: false)
            .padding(.horizontal, width == nil ? horizontalPadding : 0)
            .frame(width: width, height: height)
            .foregroundStyle(active ? activeForeground : inactiveForeground)
            #if os(iOS)
            .background {
                RemoteSurface.fill(active ? color : color.opacity(configuration.isPressed ? max(0.7, inactiveOpacity) : inactiveOpacity))
            }
            #else
            .background(active ? color : color.opacity(configuration.isPressed ? max(0.7, inactiveOpacity) : inactiveOpacity))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if bordered { RoundedRectangle(cornerRadius: 6).stroke(active ? color : Color.white.opacity(0.45)) }
            }
            .contentShape(Rectangle())
    }
}
struct TransportPreview: PreviewProvider { static var previews: some View { TransportView(show: try! AppContainer(preview: true).show).frame(width: 980) } }

struct MetronomeModeButton: View {
    @ObservedObject private var settings = MetronomeSettings.shared
    let width: CGFloat
    private var mode: Int { min(2, max(0, settings.mode)) }
    private var label: String { ["A-B", "A", "B"][mode] }

    init(width: CGFloat = 32) { self.width = width }

    var body: some View {
        Button { settings.mode = (mode + 1) % 3 } label: { Text(verbatim: label) }
            .buttonStyle(TransportButtonStyle(color: Color(hex: 0x454545), inactiveOpacity: 1,
                fontSize: 10, width: width, height: TransportControlMetrics.metronomeButtonHeight, bordered: false))
            .accessibilityLabel("Click mode").accessibilityValue(label)
    }
}

private struct MetronomeControl: View {
    @Environment(\.transportControlWidth) private var buttonWidth
    @ObservedObject private var settings = MetronomeSettings.shared
    @State private var configuring = false
    var body: some View { control }
    private var control: some View {
        Button { settings.enabled.toggle() } label: {
            TransportControlIcon(name: "metronome", size: 17)
        }
            .buttonStyle(TransportButtonStyle(color: settings.enabled ? JarasTheme.yellow : Color(hex: 0x454545),
                active: settings.enabled, inactiveOpacity: 1, fontSize: TransportControlMetrics.font,
                width: max(30, (buttonWidth / 2).rounded()), height: TransportControlMetrics.metronomeButtonHeight, bordered: false))
            .accessibilityLabel("Metronome").accessibilityValue(settings.enabled ? "On" : "Off")
            .jarasHelp("Metronome · Right-click to configure")
            .immediateRightClick { configuring = true }
            .workspaceEditor("Metronome", isPresented: $configuring, scrolls: false, size: CGSize(width: 400, height: 440)) { MetronomeEditor() }
    }
}
struct MetronomeEditor: View {
    @ObservedObject private var settings = MetronomeSettings.shared
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceEditorDismiss) private var closeEditor
    @State private var importing = false
    @State private var importingA = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Metronome").font(.jarasTitle2.bold())
            Picker("Click sound", selection: $settings.preset) {
                Text("Digital").tag("Digital")
                Text("Wood").tag("Wood")
                Text("Clave").tag("Clave")
                Text(verbatim: "User").tag("User")
            }
            HStack(spacing: 12) {
                Text("Click mode").lineLimit(1).frame(width: 104, alignment: .leading)
                HStack(spacing: 1) {
                    ForEach(0..<3, id: \.self) { mode in
                        Button { settings.mode = mode } label: {
                            Text(LocalizedStringKey(["A–B", "Only A", "Only B"][mode]))
                                .font(.jarasSystem(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(width: 80, height: 24)
                                .foregroundStyle(settings.mode == mode ? Color.black : JarasTheme.text)
                                .background(settings.mode == mode ? JarasTheme.green : Color.white.opacity(0.12))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(settings.mode == mode ? .isSelected : [])
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5)).frame(width: 242, height: 24)
            }.frame(width: 358, height: 24)
            Picker("Output", selection: $settings.output) {
                let choices = OutputPatch.choices(channels: audio.channels, includeMaster: false)
                if !choices.contains(settings.output) {
                    Text(settings.output.title + " — " + JarasLocalization.string("Unavailable")).tag(settings.output)
                }
                ForEach(choices, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            if settings.preset == "User" {
                fileRow(a: true)
                fileRow(a: false)
            }
            volume("Click A", value: $settings.gainA)
            volume("Click B", value: $settings.gainB)
            Text("A: first beat · B: remaining beats").font(.jarasCaption).foregroundStyle(.secondary)
            if !settings.error.isEmpty { Text(verbatim: settings.error).foregroundStyle(.red).font(.jarasCaption) }
            HStack { Spacer(); Button("Close") { (closeEditor ?? { dismiss() })() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 400, height: 440, alignment: .topLeading)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let files): if let url = files.first { settings.importSound(url, a: importingA) }
                case .failure(let error): settings.error = error.localizedDescription
                }
            }
    }
    private func fileRow(a: Bool) -> some View {
        let path = a ? settings.pathA : settings.pathB
        return HStack {
            Text(verbatim: a ? "A" : "B").bold().frame(width: 20)
            TextField("Audio file", text: .constant(path.isEmpty ? "" : String(URL(fileURLWithPath: path).lastPathComponent.dropFirst(37))))
                .textFieldStyle(.roundedBorder).disabled(true)
            Button { importingA = a; importing = true } label: { Image(systemName: "plus") }
                .accessibilityLabel(a ? "Load click A" : "Load click B")
        }
    }
    private func volume(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title)).lineLimit(1).frame(width: 48, alignment: .leading)
            Slider(value: value, in: -60...6).frame(width: 216)
            Text(verbatim: value.wrappedValue <= -60 ? "−∞ dB" : String(format: "%+.2f dB", value.wrappedValue))
                .monospacedDigit().lineLimit(1).frame(width: 80, alignment: .trailing)
        }
    }
}

private struct RepeatControl: View {
    let active: Bool
    var width = TransportControlMetrics.playbackWidth
    let action: () -> Void
    var body: some View {
        Button(action: action) { TransportControlIcon(name: "loop", size: 14) }
            .buttonStyle(TransportButtonStyle(color: active ? JarasTheme.yellow : Color(hex: 0x454545),
                active: active, inactiveOpacity: 1, fontSize: TransportControlMetrics.font,
                width: width, height: TransportControlMetrics.playbackHeight, bordered: false))
            .accessibilityLabel("Repeat").jarasHelp("Repeat (R)")
    }
}

#if os(macOS)
struct VideoToggleButton: View {
    @ObservedObject private var video = VideoPlayback.shared
    var body: some View {
        Button { video.toggle() } label: {
            DesktopToolbarLabel(title: "Video", systemImage: "video", tone: video.visible ? .live : .neutral)
        }
            .buttonStyle(.plain)
            .overlay(VideoOptionsInput(controller: video))
            .accessibilityLabel("Video").help(Text("Video"))
    }
}
private struct VideoOptionsInput: NSViewRepresentable {
    let controller: VideoPlayback
    func makeNSView(context: Context) -> VideoOptionsTarget { VideoOptionsTarget() }
    func updateNSView(_ view: VideoOptionsTarget, context: Context) {
        view.controller = controller; view.action = { [weak view] in view?.openMenu() }
    }
}
private final class VideoOptionsTarget: RightClickTargetView {
    weak var controller: VideoPlayback?
    override var priority: Int { 20 }
    func openMenu() {
        guard let event = NSApp.currentEvent, let controller else { return }
        let menu = NSMenu()
        let stretch = NSMenuItem(title: "Stretch", action: #selector(toggleStretch), keyEquivalent: "")
        stretch.target = self; stretch.state = controller.stretch ? .on : .off
        menu.addItem(stretch)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func toggleStretch() { if let controller { controller.setStretch(!controller.stretch) } }
}
#endif

#if os(macOS)
struct RemoteToggleButton: View {
    let show: ShowController
    @ObservedObject private var remote = DAWRemoteSession.shared
    @State private var settings = false
    var body: some View {
        Button {
            if remote.enabled { remote.setHostEnabled(false); settings = false }
            else { DAWRemoteHostBridge.bind(show); remote.setHostEnabled(true) }
        } label: {
            DesktopToolbarLabel(title: "Remote", systemImage: "dot.radiowaves.left.and.right", tone: remote.enabled ? .live : .neutral)
        }.buttonStyle(.plain)
            .accessibilityLabel("Remote").accessibilityValue(remote.enabled ? "On" : "Off").help(Text("Remote"))
            .popover(isPresented: $settings) { DAWRemoteHostView() }
            .immediateRightClick { settings = true }
            .onChange(of: remote.connected) { if $0 { settings = false } }
    }
}
#endif

struct DesktopMultiLoopBypassButton: View {
    let show: ShowController
    @State private var active: Bool
    init(show: ShowController) {
        self.show = show
        _active = State(initialValue: show.snapshot.transport.multiLoopsBypassed == true)
    }
    var body: some View {
        MultiLoopBypassButton(active: active) {
            show.send(.toggleMultiLoopBypass)
        }
        .onReceive(show.$snapshot.map { $0.transport.multiLoopsBypassed == true }.removeDuplicates()) { active = $0 }
    }
}
struct MultiLoopBypassButton: View {
    let active: Bool
    let action: () -> Void
    private var buttonColor: Color {
        Color(hex: active ? 0xffd600 : 0xff3030)
    }
    var body: some View {
        Button(action: action) {
            Text(verbatim: "B\nY\nP\nA\nS\nS")
                .font(.jarasSystem(size: 10, weight: .heavy, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.black)
                .frame(width: 30, height: 82)
                .background(buttonColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .modifier(JarasBlink(active: active, interval: 0.15, lowOpacity: 0.2))
        }.buttonStyle(.plain)
            .accessibilityLabel("Bypass de todos os Multiloops")
            .accessibilityValue(active ? "Ligado" : "Desligado")
            .jarasHelp("Bypass de todos os Multiloops")
    }
}
