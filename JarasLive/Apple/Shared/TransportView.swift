import SwiftUI
import UniformTypeIdentifiers
import Combine

enum SetlistPlacement: String { case left, right, detached }

enum TimelineEditPreferences {
    static let desktop = "jaras.timeline.editMode"
    static let native = "jaras.ipad.transport.edit"
    static func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    enum Seek: String, CaseIterable {
        case bar, markers, parts
        var label: String {
            switch self {
            case .bar: return JarasLocalization.string("Next Bar")
            case .markers: return "Markers"
            case .parts: return "Markers-parts"
            }
        }
        var command: ShowCommand {
            switch self {
            case .bar: return .queueBarSeek
            case .markers: return .queueMarkerSeek
            case .parts: return .queuePartSeek
            }
        }
    }

    static func seekCommand(_ key: String) -> ShowCommand {
        guard enabled(key) else { return .editSeek }
        let mode = UserDefaults.standard.string(forKey: key + ".seek").flatMap(Seek.init(rawValue:)) ?? .bar
        return mode.command
    }
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
    @AppStorage(TransportPanelColor.key) private var panelColor = ""
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @State private var showingReduction = false
    #if !os(macOS)
    @State private var showingExport = false
    #endif
    @State private var showingFadeout = false
    #if os(macOS)
    @State private var showingClockPosition = false
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
    var masterWorkspaceButtons: AnyView?
    var masterFooterButtons: AnyView?
    var timerReadout: AnyView?
    var statusControls: AnyView?
    init(show: ShowController, documents: ProjectDocuments? = nil, remotePresentation: Bool = false,
         mediaDirectory: URL? = nil, toggleNavigation: @escaping () -> Void = {},
         mixerCollapsed: Bool = false, setlistCollapsed: Bool = false,
         toggleMixer: @escaping () -> Void = {}, toggleSetlist: @escaping () -> Void = {},
         setlistPlacement: SetlistPlacement = .right, placeSetlist: @escaping (SetlistPlacement) -> Void = { _ in },
         shareProject: (() -> Void)? = nil, proNotesOpen: Bool = false, proSamplersOpen: Bool = false,
         toggleProNotes: @escaping () -> Void = {}, toggleProSamplers: @escaping () -> Void = {},
         masterWorkspaceButtons: AnyView? = nil, masterFooterButtons: AnyView? = nil,
         timerReadout: AnyView? = nil, statusControls: AnyView? = nil) {
        self.show = show; self.documents = documents; self.remotePresentation = remotePresentation
        self.mediaDirectory = mediaDirectory; self.toggleNavigation = toggleNavigation
        self.mixerCollapsed = mixerCollapsed; self.setlistCollapsed = setlistCollapsed
        self.toggleMixer = toggleMixer; self.toggleSetlist = toggleSetlist
        self.setlistPlacement = setlistPlacement; self.placeSetlist = placeSetlist
        self.shareProject = shareProject
        self.proNotesOpen = proNotesOpen; self.proSamplersOpen = proSamplersOpen
        self.toggleProNotes = toggleProNotes; self.toggleProSamplers = toggleProSamplers
        self.masterWorkspaceButtons = masterWorkspaceButtons
        self.masterFooterButtons = masterFooterButtons
        self.timerReadout = timerReadout; self.statusControls = statusControls
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    @ViewBuilder private func setlistPositionOption(_ title: String, _ placement: SetlistPlacement) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { setlistPlacement == placement },
            set: { selected in if selected { placeSetlist(placement) } }))
    }
    #if os(macOS)
    static func desktopHeight(width: CGFloat, remote: Bool, multipleProjects: Bool) -> CGFloat {
        if remote { return 86 }
        let panelWidth = width - 16 - 6 - TransportControlMetrics.desktopMainWidth
        return DesktopTransportLayout(width: panelWidth, multipleProjects: multipleProjects).compact ? 121 : 91
    }

    #endif
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
                .frame(width: width, height: geometry.size.height, alignment: .leading)
        }
        #if !os(macOS)
        .frame(height: 86)
        #endif
        .clipped()
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
        let mainWidth: CGFloat = remotePresentation ? 266 : TransportControlMetrics.desktopMainWidth
        let statusWidth = width - 16 - groupSpacing - mainWidth
        let layout = DesktopTransportLayout(width: statusWidth, multipleProjects: (documents?.projectTabCount ?? 0) > 1)
        let activeProMode = !remotePresentation
        let actionsHeight = remotePresentation ? TransportControlMetrics.height : TransportControlMetrics.proHeight
        let playbackWidth = preferredWidth
        let desktopLayout = remotePresentation ? nil : layout
        let titleInset: CGFloat = 282
        #else
        let mainWidth: CGFloat = 230
        let playbackWidth = preferredWidth
        let desktopLayout: DesktopTransportLayout? = nil
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
                    tooltip: "Track Mixer", cornerRadius: 4, action: toggleMixer).frame(width: buttonWidth)
            }
            #endif
            MasterStrip(show: show, workspaceButtons: masterWorkspaceButtons, footerButtons: masterFooterButtons)
                .frame(width: mainWidth)
                .overlay(alignment: .trailing) {
                    if activeProMode {
                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1)
                            .padding(.vertical, 10).allowsHitTesting(false)
                    }
                }

            TransportDisplaysLive(show: show, displaysTuner: !remotePresentation, titleInset: titleInset,
                                  desktopLayout: desktopLayout, proMode: activeProMode,
                                  statusControls: statusControls, timerReadout: timerReadout) {
                #if os(macOS)
                HStack(spacing: TransportControlMetrics.groupSpacing) {
                    if let documents, documents.projectTabCount > 1 { projectTabControls(documents) }
                    if activeProMode {
                        proPanelButton("Clock", icon: "timer", active: showingClockPosition) { showingClockPosition.toggle() }
                        proPanelButton("Notes", icon: "note.text", active: proNotesOpen, action: toggleProNotes)
                        proPanelButton("Samplers", icon: "library.samplers", active: proSamplersOpen, action: toggleProSamplers)
                    }
                    saveButton(width: TransportControlMetrics.iconWidth, height: actionsHeight)
                    setlistButton(width: TransportControlMetrics.iconWidth, height: actionsHeight)
                }.fixedSize(horizontal: true, vertical: false)
                #endif
            } playback: {
                #if os(macOS)
                if activeProMode {
                    ProTransportButtons(show: show, configureFadeout: { showingFadeout = true }, buttonWidth: layout.buttonWidth, splitNavigation: true)
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
        #if os(macOS)
        .background {
            if activeProMode {
                LinearGradient(gradient: TransportPanelColor.resolved(panelColor).gradient, startPoint: .top, endPoint: .bottom)
            }
        }
        #endif
        .modifier(MasterMuteIndicator(muted: activeProMode && show.snapshot.project.masterMute == true))
    }

    private func standardPlayback(running: Bool, paused: Bool, title: Text, width: CGFloat, spacing: CGFloat,
                                  playing: Bool, repeatEnabled: Bool) -> some View {
        HStack(spacing: spacing) {
            Button { show.send(running ? .stop : .play) } label: {
                Label { title } icon: { TransportControlIcon(name: running ? "stopall" : "play", size: 14) }
            }.buttonStyle(TransportButtonStyle(color: running ? JarasTheme.liveOffRed : JarasTheme.transportPlay, active: running,
                activeForeground: .white, width: width, height: TransportControlMetrics.playbackHeight, bordered: false))
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
                    activeForeground: .white, width: width, height: TransportControlMetrics.playbackHeight, bordered: false))
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
            .accessibilityLabel(LocalizedStringKey(label))
            .accessibilityIdentifier("transport-panel-" + label.lowercased()).jarasHelp(label)
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
            tooltip: setlistCollapsed ? "Restaurar largura anterior do Setlist" : "Ocultar Setlist",
            height: height, action: toggleSetlist)
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
    static let panelHeight: CGFloat = 3.2
    static let remoteHeight: CGFloat = 2
    let position: Double?
    let start: Double?
    let end: Double?
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let position, let start, let end,
                  position.isFinite, start.isFinite, end.isFinite, end > start else { return }
            let fraction = min(1, max(0, (position - start) / (end - start)))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.12)))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)),
                         with: .color(JarasTheme.green))
        }.frame(height: height).allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct LiveSongProgressBar: View {
    let show: ShowController
    let region: Part?
    let height: CGFloat
    @State private var position: Double?

    var body: some View {
        SongProgressBar(position: position, start: region?.startTime, end: region?.endTime, height: height)
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
    @AppStorage(TransportTitleMode.preferenceKey) private var titleMode = TransportTitleMode.region
    @AppStorage("jaras.setlist.allRegionsOrder") private var setlistOrder = 0
    @State private var cursorTitle: String?
    let desktopLayout: DesktopTransportLayout?
    let statusControls: AnyView?
    let timerReadout: AnyView?
    let proMode: Bool
    @StateObject private var updates: ShowPresentationObserver

    init(show: ShowController, displaysTuner: Bool, titleInset: CGFloat, desktopLayout: DesktopTransportLayout?,
         proMode: Bool, statusControls: AnyView?, timerReadout: AnyView?, @ViewBuilder actions: () -> Actions,
         @ViewBuilder playback: () -> Playback) {
        self.show = show
        self.displaysTuner = displaysTuner
        self.titleInset = titleInset
        self.desktopLayout = desktopLayout
        self.proMode = proMode
        self.statusControls = statusControls
        self.timerReadout = timerReadout
        self.actions = actions()
        self.playback = playback()
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }

    var body: some View {
        let transport = show.snapshot.transport
        let displays = TransportSongDisplays(song: show.current, transport: transport,
            focusedRegion: show.focusedRegion.map(show.playlistRegionSourceID))
        let name = (titleMode.followsCursor ? cursorTitle : nil)
            ?? show.transportTitle(titleMode, regionName: displays.current?.displayName ?? "—", setlistOrder: setlistOrder)
        GeometryReader { geometry in
            let sideWidth = max(132, titleInset)
            let noticeWidth = min(210, max(0, geometry.size.width / 2 - 224))
            let centeredTitleWidth = max(0, geometry.size.width - 2 * sideWidth - 16)
            #if os(macOS)
            let titleFont = NSFont.jarasSystemFont(ofSize: TransportControlMetrics.readoutSize, weight: .semibold)
            let expandTitle = proMode && (name as NSString).size(withAttributes: [.font: titleFont]).width > centeredTitleWidth
            #else
            let expandTitle = false
            #endif
            let rightInset = TransportResourceMeters.width + 16
            let titleWidth = expandTitle ? max(0, geometry.size.width - sideWidth - rightInset) : centeredTitleWidth
            let songTitle = Text(verbatim: name)
                .font(.jarasSystem(size: TransportControlMetrics.readoutSize, weight: .semibold))
                .foregroundStyle(transport.playing ? JarasTheme.green : JarasTheme.text)
                .lineLimit(1).truncationMode(.tail)
            let title = ZStack(alignment: .leading) {
                songTitle.frame(width: titleWidth, height: 27)
                    .transportTitleMenu(selection: $titleMode)
                    .padding(.leading, expandTitle ? sideWidth : 0)
                    .padding(.trailing, expandTitle ? rightInset : 0)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text(verbatim: titleMode.rawValue)).accessibilityValue(name)
                HStack(spacing: 9) {
                    #if os(macOS)
                    if proMode {
                        VStack(alignment: .leading, spacing: 4) {
                            ProTimelinePosition(show: show)
                            if let timerReadout { timerReadout }
                        }
                    } else if desktopLayout != nil {
                        TimelineNavigationControls(show: show)
                        TransportTimeDisplay(show: show)
                    } else {
                        TransportTimeDisplay(show: show)
                    }
                    #else
                    TransportTimeDisplay(show: show)
                    #endif
                }
                    .frame(width: sideWidth - 8, alignment: .topLeading)
                    #if os(macOS)
                    .foregroundStyle(JarasTheme.licenseTitleGreen)
                    #else
                    .foregroundStyle(JarasTheme.text)
                    #endif
                    .padding(.leading, desktopLayout == nil ? 8 : 4)
            }.frame(height: statusControls == nil ? 27 : 47, alignment: .top)
                #if os(macOS)
                .overlay(alignment: .topTrailing) {
                    if proMode {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let statusControls { statusControls }
                            TransportResourceMeters()
                        }.padding(.trailing, 8)
                    }
                }
                #endif
            let details = HStack(spacing: TransportControlMetrics.groupSpacing) {
                MetronomeModeButton()
                MetronomeControl()
                TempoControl(show: show, panelWidth: desktopLayout == nil ? nil : TransportControlMetrics.desktopBPMWidth)
                if displaysTuner {
                    if desktopLayout != nil { TransportGroupDivider() }
                    RegionTunerControl(show: show, panelWidth: desktopLayout == nil ? nil : TransportControlMetrics.desktopTunerWidth)
                }
            }.fixedSize(horizontal: true, vertical: false)
            let noticeView = FooterInformationDisplay(show: show, embedded: true)
            #if os(macOS)
            if let layout = desktopLayout {
                title.frame(maxHeight: .infinity, alignment: .top).padding(.top, 4)
                Group {
                    if layout.compact {
                        VStack(spacing: 4) {
                            details
                            HStack(spacing: TransportControlMetrics.groupSpacing) {
                                playback
                                Spacer(minLength: 0)
                                actions
                            }
                        }
                    } else {
                        HStack(alignment: .bottom, spacing: TransportControlMetrics.groupSpacing) {
                            playback
                            details
                                .overlay(alignment: .leading) {
                                    TransportGroupDivider().offset(x: -TransportControlMetrics.groupSpacing)
                                }
                                .padding(.leading, TransportControlMetrics.groupSpacing)
                            Spacer(minLength: 1)
                                .frame(height: TransportControlMetrics.proHeight)
                                .overlay { TransportGroupDivider() }
                            actions
                        }
                    }
                }.padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
            } else {
                VStack(spacing: 0) {
                    title.frame(height: geometry.size.height / 2)
                        .overlay(alignment: .trailing) { noticeView.frame(width: noticeWidth).padding(.trailing, 8) }
                    details.offset(y: -4).frame(maxWidth: .infinity).frame(height: geometry.size.height / 2)
                        .overlay(alignment: .leading) { playback.padding(.leading, 6) }
                        .overlay(alignment: .trailing) { actions.padding(.trailing, 8) }
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
            if desktopLayout == nil {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: JarasTheme.workspaceTransportGradient, startPoint: .top, endPoint: .bottom))
            }
            #else
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: interfaceTheme.transportGradient,
                                     startPoint: .top, endPoint: .bottom))
            #endif
        }
        .overlay(alignment: desktopLayout != nil || proMode ? .bottom : .center) {
            LiveSongProgressBar(show: show, region: displays.current,
                height: desktopLayout == nil ? SongProgressBar.remoteHeight : SongProgressBar.panelHeight)
                .padding(.horizontal, 3)
        }
        .overlay {
            #if os(macOS)
            if desktopLayout == nil {
                RoundedRectangle(cornerRadius: 7).strokeBorder(JarasInterfaceTheme.lightDark.transportBorder)
                    .allowsHitTesting(false)
            }
            #else
            RoundedRectangle(cornerRadius: 7).strokeBorder(interfaceTheme.transportBorder).allowsHitTesting(false)
            #endif
        }
        .onChange(of: titleMode) { _ in cursorTitle = nil }
        .onReceive(show.$snapshot) { snapshot in
            guard titleMode.followsCursor else { return }
            let song = snapshot.project.songs.first { $0.id == snapshot.transport.songId }
            let name = titleMode.cursorTitle(in: song, transport: snapshot.transport) ?? "—"
            if cursorTitle != name { cursorTitle = name }
        }
    }

}

private struct TransportGroupDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.19)).frame(width: 1, height: TransportControlMetrics.proHeight - 8)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func transportTitleMenu(selection: Binding<TransportTitleMode>) -> some View {
        contentShape(Rectangle()).contextMenu {
            Picker(selection: selection) {
                ForEach(TransportTitleMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.rawValue).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        }
    }
}

private struct DesktopTransportLayout {
    let compact: Bool
    let buttonWidth: CGFloat

    init(width: CGFloat, multipleProjects: Bool) {
        let standardActions = 2 * TransportControlMetrics.iconWidth + (multipleProjects ? 62 : 0)
        let proActions = standardActions + 114
        let gap = TransportControlMetrics.groupSpacing
        let detailsWidth = 2 * TransportControlMetrics.iconWidth + TransportControlMetrics.desktopBPMWidth
            + TransportControlMetrics.desktopTunerWidth + 4 * gap + 1
        let available = width - 16 - proActions
        let controls = ProTransportButtons.controlCount
        let minimumButtonWidth: CGFloat = 30
        let minimumPlayback = controls * minimumButtonWidth + ProTransportButtons.splitHorizontalInset
        let inlineSpace = detailsWidth + 5 * gap + 1
        compact = available - inlineSpace < minimumPlayback
        let playbackWidth = available - (compact ? gap : inlineSpace)
        buttonWidth = min(compact ? 66 : 96, max(minimumButtonWidth,
            (playbackWidth - ProTransportButtons.splitHorizontalInset) / controls))
    }
}

struct ProTimelinePosition: View {
    static let clockTitle = "Clock Position"
    let show: ShowController
    var clockOnly = false
    @State private var position = ["001", "1", "1", "001", "00", "00", "00"]
    @State private var running = false
    @State private var clockTime = "00:00:00:00.00"
    @State private var map: (song: UUID, revision: UInt64, sections: [TimelineTempoSection], labels: TimelineTimeRuler.MusicalLabels)?

    var body: some View {
        Group {
            if clockOnly {
                GeometryReader { size in
                    let scale = min(size.size.width / 530, size.size.height / 112)
                    Text(verbatim: clockTime)
                        .font(.jarasSystem(size: max(1, 62 * scale), weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color(hex: 0x8bbaff))
                        .lineLimit(1).minimumScaleFactor(0.4).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 8) {
                    fields(["BAR", "BEAT", "DIV", "TICK"], range: 0..<4)
                    Divider().frame(height: 22)
                    fields(["HR", "MIN", "SEC"], range: 4..<7)
                }.fixedSize()
            }
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline position")
            .onAppear { update(show.snapshot) }
            .onReceive(show.$snapshot) { update($0) }
    }

    private func fields(_ names: [String], range: Range<Int>) -> some View {
        HStack(spacing: 5) {
            ForEach(range, id: \.self) { index in
                VStack(spacing: 0) {
                    Text(verbatim: position[index])
                        .font(.jarasSystem(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(running ? JarasTheme.licenseTitleGreen : JarasTheme.yellow)
                    Text(verbatim: names[index - range.lowerBound])
                        .font(.jarasSystem(size: 7, weight: .medium)).foregroundStyle(JarasTheme.secondary)
                }.frame(minWidth: index == 0 ? 30 : 21)
            }
        }
    }

    private func update(_ snapshot: ShowSnapshot) {
        let transport = snapshot.transport
        let active = transport.playing || transport.paused == true
        if running != active { running = active }
        let needle = active ? transport.position : transport.editPosition ?? transport.position
        let seconds = needle.isFinite ? min(1e9, max(0, needle)) : 0
        let subframes = Int64(floor(seconds * 3000 + 1e-7))
        let elapsed = subframes / 3000
        if clockOnly {
            let text = String(format: "%02lld:%02lld:%02lld:%02lld.%02lld",
                              elapsed / 3600, elapsed / 60 % 60, elapsed % 60, subframes / 100 % 30, subframes % 100)
            if text != clockTime { clockTime = text }
            return
        }
        var next = ["001", "1", "1", "001"]
        if let song = snapshot.project.songs.first(where: { $0.id == transport.songId }) {
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
        next += [elapsed / 3600, elapsed / 60 % 60, elapsed % 60]
            .map { String(format: "%02lld", $0) }
        if next != position { position = next }
    }
}

#if os(iOS)
struct NativeClockPosition: View {
    let show: ShowController
    let available: CGSize
    let close: () -> Void
    @State private var preferredSize = CGSize(width: 440, height: 138)
    @State private var location = CGSize(width: 0, height: 44)
    @GestureState private var resize = CGSize.zero
    @GestureState private var movement = CGSize.zero

    var body: some View {
        let limit = CGSize(width: max(1, available.width - 16), height: max(1, available.height - 52))
        let size = resized(by: resize, limit: limit)
        let offset = boundedOffset(movement, size: size)
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: ProTimelinePosition.clockTitle).font(.jarasSystem(size: 14, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 30) }
                    .accessibilityLabel("Close")
            }.padding(.leading, 12)
            ProTimelinePosition(show: show, clockOnly: true)
                .contentShape(Rectangle())
                .gesture(LongPressGesture(minimumDuration: 0.18, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .updating($movement) { phase, value, _ in
                        if case .second(true, let drag?) = phase { value = drag.translation }
                    }
                    .onEnded { phase in
                        if case .second(true, let drag?) = phase { location = boundedOffset(drag.translation, size: size) }
                    })
                .accessibilityHint("Touch and hold the clock to move it.")
        }
        .frame(width: size.width, height: size.height)
        .background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
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
        .offset(x: offset.width, y: offset.height)
    }

    private func resized(by drag: CGSize, limit: CGSize) -> CGSize {
        CGSize(width: min(limit.width, max(240, preferredSize.width + drag.width)),
               height: min(limit.height, max(94, preferredSize.height + drag.height)))
    }

    private func boundedOffset(_ drag: CGSize, size: CGSize) -> CGSize {
        let horizontal = max(0, (available.width - size.width) / 2 - 8)
        return CGSize(width: min(horizontal, max(-horizontal, location.width + drag.width)),
                      height: min(max(0, available.height - size.height - 8), max(0, location.height + drag.height)))
    }
}
#endif

enum ProGridTool: String, CaseIterable {
    case select = "Select", cut = "Cut", mute = "Mute", solo = "Solo", exclusiveSolo = "Exclusive Solo"

    var appliesToTrack: Bool { self == .mute || self == .solo || self == .exclusiveSolo }

    @MainActor func apply(to track: UUID, show: ShowController) {
        guard let kind = show.current?.tracks.first(where: { $0.id == track })?.kind else { return }
        switch self {
        case .mute where kind.supportsTrackMute: show.send(.mute, target: track)
        case .solo where kind.supportsTrackSolo: show.send(.solo, target: track)
        case .exclusiveSolo where kind.supportsTrackSolo: show.soloTrackExclusively(track)
        default: break
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .cut: return "scissors"
        case .mute: return "M"
        case .solo: return "S"
        case .exclusiveSolo: return "1.circle"
        }
    }
    var letter: Bool { self == .mute || self == .solo }
    static var current: ProGridTool {
        UserDefaults.standard.string(forKey: "jaras.timeline.proTool").flatMap(ProGridTool.init(rawValue:)) ?? .select
    }
}

struct ProGridToolPicker: View {
    static let width: CGFloat = 42
    @Binding var selection: ProGridTool
    var height = TransportControlMetrics.proHeight
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                icon(selection).frame(width: 16, height: 16)
                DesktopToolbarSymbol(name: "chevron.down")
                    .foregroundStyle(Color(hex: 0xa9a9a9))
                    .frame(width: 11, height: 11)
            }.frame(width: Self.width, height: height)
                .background(Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Grid tool").accessibilityValue(JarasLocalization.string(selection.rawValue))
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
        else { DesktopToolbarSymbol(name: tool.symbol).frame(width: 16, height: 16) }
    }
}

struct ProTransportButtons: View {
    static let controlCount: CGFloat = 9
    static let playbackOrder: [IpadTransportControl] = [.play, .pause, .fadeout, .record, .repeatPlayback]
    static let playbackControlCount = CGFloat(playbackOrder.count)
    static let horizontalInset: CGFloat = 4
    static let navigationGap: CGFloat = 10
    static let splitHorizontalInset: CGFloat = 2 * horizontalInset + navigationGap
    let show: ShowController
    let configureFadeout: () -> Void
    var buttonWidth: CGFloat = 31
    var controlHeight = TransportControlMetrics.proHeight
    var splitNavigation = false
    enum Section { case all, navigation, playback }
    var section: Section = .all
    var visiblePlayback = Self.playbackOrder
    @ObservedObject private var recorder = TrackRecording.shared

    var body: some View {
        if section == .navigation {
            controlGroup { navigationControls }
        } else if section == .playback {
            controlGroup { playbackControls }
        } else if splitNavigation {
            HStack(spacing: Self.navigationGap) {
                controlGroup { navigationControls }
                    .overlay(alignment: .trailing) {
                        TransportGroupDivider().offset(x: Self.navigationGap / 2)
                    }
                controlGroup { playbackControls }
            }.fixedSize()
        } else {
            controlGroup {
                navigationControls
                playbackControls
            }
        }
    }

    @ViewBuilder private var navigationControls: some View {
        navigation(.projectStart)
        navigation(.previousTimelinePoint)
        navigation(.nextTimelinePoint)
        navigation(.projectEnd)
    }

    @ViewBuilder private var playbackControls: some View {
        let transport = show.snapshot.transport
        let running = transport.playing || show.preparingAudio
        let recording = recorder.recording || recorder.countingIn
        ForEach(visiblePlayback) { command in
            switch command {
            case .play:
                control(running ? "Stop" : "Play", icon: running ? "stopall" : "play",
                    tint: running ? .white : JarasTheme.green, selectedColor: running ? JarasTheme.liveOffRed : nil) {
                    show.send(running ? .stop : .play)
                }
            case .pause:
                control("Pause", icon: "pause", selectedColor: transport.paused == true ? JarasTheme.yellow : nil,
                    enabled: transport.playing || transport.paused == true) { show.send(.pause) }
            case .fadeout:
                control("Fadeout", icon: "fadeout", tint: JarasTheme.yellow) { show.triggerTransportFadeout() }
                    .immediateRightClick { configureFadeout() }
            case .record:
                control("Record", icon: "record", tint: recording ? .white : JarasTheme.liveOffRed,
                    selectedColor: recording ? JarasTheme.liveOffRed : nil, enabled: !recorder.busy || recorder.countingIn) {
                    recorder.toggle(show: show)
                }.contextMenu { StopPlaybackOnRecordDisarm() }
            case .repeatPlayback:
                control("Repeat", icon: "loop", tint: transport.loop.enabled ? .black : .white,
                    selectedColor: transport.loop.enabled ? JarasTheme.yellow : nil) {
                    show.send(.toggleLoop)
                }
            case .metronome, .bpm, .tuner:
                EmptyView()
            }
        }
    }

    private func controlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .padding(.horizontal, Self.horizontalInset / 2)
            .background(JarasTheme.transportControlGroup, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if !splitNavigation {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.22))
                        .allowsHitTesting(false)
                }
            }
            .fixedSize()
    }

    private func navigation(_ action: DAWAction) -> some View {
        control(action.title, icon: action.rawValue) { show.performAction(action) }
    }

    private func control(_ title: String, icon: String, tint: Color = .white,
                         selectedColor: Color? = nil, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TransportControlIcon(name: icon, size: 18, color: tint)
                .frame(width: buttonWidth, height: controlHeight).contentShape(Rectangle())
                .background(selectedColor ?? .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.36)
            .accessibilityLabel(LocalizedStringKey(title)).jarasHelp(title)
    }
}
#if os(macOS)
struct DesktopTimelineEditingBar: View {
    let show: ShowController
    let mixerButtons: AnyView
    let workspaceButtons: AnyView
    let liveButtons: AnyView
    @Environment(\.desktopTimelineToolbar) private var controls
    @AppStorage("jaras.timeline.proTool") private var tool = ProGridTool.select

    var body: some View {
        if let controls {
            DesktopTimelineEditingControls(show: show, controls: controls, mixerButtons: mixerButtons,
                                           workspaceButtons: workspaceButtons, liveButtons: liveButtons, tool: $tool)
        }
    }
}

private struct DesktopTimelineEditingControls: View {
    let show: ShowController
    @ObservedObject var controls: DesktopTimelineToolbar
    let mixerButtons: AnyView
    let workspaceButtons: AnyView
    let liveButtons: AnyView
    @Binding var tool: ProGridTool

    var body: some View {
        TimelineEditingBar(show: show, editKey: TimelineEditPreferences.desktop, tool: $tool,
                           movingRegion: controls.movingRegion, mixerButtons: mixerButtons,
                           workspaceButtons: workspaceButtons, liveButtons: liveButtons) { showsSliders in
            DesktopZoomControls(
                height: .init(label: "Track height", toggleLabel: "Toggle track height", id: "track-height",
                              value: Binding(get: { controls.trackHeight }, set: { controls.changeTrackHeight?($0) }),
                              range: controls.limits.tracks, active: controls.trackHeightMemory != nil,
                              toggle: controls.toggleMinimumTrackHeight),
                time: .init(label: "Timeline zoom", toggleLabel: "Toggle timeline zoom", id: "timeline-zoom",
                            value: Binding(get: { log(max(controls.limits.zoom.lowerBound, controls.zoom)) },
                                           set: { controls.changeZoom?(exp($0)) }),
                            range: log(controls.limits.zoom.lowerBound)...log(controls.limits.zoom.upperBound),
                            active: controls.zoomMemory != nil, toggle: controls.toggleMinimumZoom),
                controlHeight: TimelineEditingBarMetrics.controlHeight, sliderWidth: TimelineEditingBarMetrics.sliderWidth,
                largerSliders: true, memoryButtonWidth: 24, showsSliders: showsSliders,
                groupSpacing: 5)
        }
    }
}
#endif

enum DesktopEditingStripDensity {
    case full, remoteIcon, videoIcon, lockIcon
    var showsRemoteTitle: Bool { self == .full }
    var showsVideoTitle: Bool { self == .full || self == .remoteIcon }
    var showsLockTitle: Bool { self != .lockIcon }
}

private struct DesktopEditingStripDensityKey: EnvironmentKey {
    static let defaultValue: DesktopEditingStripDensity = .full
}

extension EnvironmentValues {
    var desktopEditingStripDensity: DesktopEditingStripDensity {
        get { self[DesktopEditingStripDensityKey.self] }
        set { self[DesktopEditingStripDensityKey.self] = newValue }
    }
}

private struct TimebaseChange {
    let project: UUID
    let song: UUID
    let relative: Bool
    var title: String { relative ? "Enable relative timebase?" : "Disable relative timebase?" }
    var action: String { relative ? "Enable" : "Disable" }
    var message: String { relative ? "Relative timebase: changing the project BPM adjusts item duration and playback speed to follow the tempo. With Free timebase, changing the project BPM preserves item duration and playback speed. Tempo markers with their own timebase keep their individual settings." : "Free timebase: changing the project BPM changes the grid without stretching or shortening items. Item duration and playback speed are preserved. Tempo markers with their own timebase keep their individual settings." }
}

#if os(macOS)
private struct TimebaseConfirmationButton<Label: View>: View {
    let request: () -> TimebaseChange?
    let apply: (TimebaseChange) -> Void
    @ViewBuilder let label: () -> Label
    @State private var presenter = Presenter()

    private final class Presenter {
        weak var anchor: NSView?
        lazy var popover = NSPopover()
    }

    private struct Anchor: NSViewRepresentable {
        let presenter: Presenter
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            presenter.anchor = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    var body: some View {
        Button {
            guard let anchor = presenter.anchor, anchor.window != nil, !presenter.popover.isShown,
                  let change = request() else { return }
            let popover = presenter.popover
            popover.behavior = .transient
            popover.animates = false
            let content = VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: JarasLocalization.string(change.title)).font(.headline)
                Text(verbatim: JarasLocalization.string(change.message)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(JarasLocalization.string("Cancel")) { [weak popover] in popover?.close() }.keyboardShortcut(.cancelAction)
                    Button(JarasLocalization.string(change.action)) { [weak popover, apply] in
                        popover?.close()
                        apply(change)
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(16).frame(width: 360)
            let controller = NSHostingController(rootView: content)
            controller.view.setAccessibilityIdentifier("timeline-timebase-confirmation")
            popover.contentViewController = controller
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } label: { label() }
        .background(Anchor(presenter: presenter).allowsHitTesting(false))
    }
}
#endif

struct TimelineEditingBar<Zoom: View>: View {
    let show: ShowController
    let editKey: String
    @Binding var tool: ProGridTool
    var movingRegion = false
    let mixerButtons: AnyView
    let workspaceButtons: AnyView?
    let liveButtons: AnyView?
    let nativeUtilityButtons: AnyView?
    @ViewBuilder let zoom: (Bool) -> Zoom
    @ObservedObject private var updates: ShowProjectPresentation
    @AppStorage(TimelineSnapPreference.key) private var snapEnabled = true
    #if !os(macOS)
    @State private var pendingTimebase: TimebaseChange?
    @State private var confirmingTimebase = false
    #endif

    init(show: ShowController, editKey: String, tool: Binding<ProGridTool>, movingRegion: Bool,
         mixerButtons: AnyView, workspaceButtons: AnyView? = nil, liveButtons: AnyView? = nil,
         nativeUtilityButtons: AnyView? = nil, @ViewBuilder zoom: @escaping (Bool) -> Zoom) {
        self.show = show
        self.editKey = editKey
        self.movingRegion = movingRegion
        self.mixerButtons = mixerButtons
        self.workspaceButtons = workspaceButtons; self.liveButtons = liveButtons
        self.nativeUtilityButtons = nativeUtilityButtons
        self.zoom = zoom
        _tool = tool
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let workspaceButtons, let liveButtons {
                    if #available(macOS 13, iOS 16, *) {
                        ViewThatFits(in: .horizontal) {
                            desktopStrip(width: geometry.size.width, workspace: workspaceButtons, live: liveButtons) { zoom(true) }
                            desktopStrip(width: geometry.size.width, workspace: workspaceButtons, live: liveButtons) { zoom(false) }
                            desktopStrip(width: geometry.size.width, workspace: workspaceButtons, live: liveButtons, density: .remoteIcon) { zoom(false) }
                            desktopStrip(width: geometry.size.width, workspace: workspaceButtons, live: liveButtons, density: .videoIcon) { zoom(false) }
                            desktopStrip(width: geometry.size.width, workspace: workspaceButtons, live: liveButtons, density: .lockIcon) { zoom(false) }
                            ScrollView(.horizontal, showsIndicators: false) {
                                desktopStrip(width: geometry.size.width, workspace: workspaceButtons, live: liveButtons,
                                             density: .lockIcon) { zoom(false) }
                            }
                        }
                    } else {
                        let width = geometry.size.width
                        let density: DesktopEditingStripDensity = width >= 1325 ? .full
                            : width >= 1275 ? .remoteIcon : width >= 1235 ? .videoIcon : .lockIcon
                        ScrollView(.horizontal, showsIndicators: false) {
                            desktopStrip(width: width, workspace: workspaceButtons, live: liveButtons, density: density) {
                                zoom(width >= 1530)
                            }
                        }
                    }
                } else {
                    #if os(iOS)
                    ViewThatFits(in: .horizontal) {
                        nativeStrip(width: geometry.size.width).fixedSize(horizontal: true, vertical: false)
                        ScrollView(.horizontal, showsIndicators: false) { nativeStrip(width: geometry.size.width) }
                    }
                    #else
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            nativeStripControls(live: liveButtons)
                            zoom(true).fixedSize(horizontal: true, vertical: false)
                        }.frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    #endif
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TimelineEditingBarMetrics.height)
        .background(JarasTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(JarasTheme.line).frame(height: 1).allowsHitTesting(false)
        }
        .controlSize(.small)
        #if !os(macOS)
        .alert(Text(verbatim: JarasLocalization.string(pendingTimebase?.title ?? "")), isPresented: $confirmingTimebase) {
            Button("Cancel", role: .cancel) { pendingTimebase = nil }
            Button(LocalizedStringKey(pendingTimebase?.action ?? "")) {
                if let pending = pendingTimebase { applyTimebase(pending) }
                pendingTimebase = nil
            }
        } message: {
            Text(LocalizedStringKey(pendingTimebase?.message ?? ""))
        }
        #endif
    }

    #if os(iOS)
    private func nativeStrip(width: CGFloat) -> some View {
        NativeTimelineStripLayout(viewportWidth: width) {
            nativeStripControls(live: nil).fixedSize()
            desktopStripGroup {
                HStack(spacing: 0) { nativeUtilityButtons }
            }
            HStack(spacing: 10) {
                if let liveButtons { desktopStripGroup { liveButtons.fixedSize() } }
                zoom(true)
            }.fixedSize()
        }
    }
    #endif

    private func nativeStripControls(live: AnyView?) -> some View {
        HStack(spacing: 10) {
            desktopStripGroup { mixerButtons.fixedSize() }
            desktopStripGroup { timelineToggles.fixedSize() }
            desktopStripGroup { editTools }
            if let live { desktopStripGroup { live.fixedSize() } }
        }
    }

    private func desktopStrip<ZoomTools: View>(width: CGFloat, workspace: AnyView, live: AnyView,
                                              density: DesktopEditingStripDensity = .full,
                                              @ViewBuilder zoomTools: () -> ZoomTools) -> some View {
        HStack(spacing: 8) {
            desktopStripGroup { leftControls(showsTiming: true) }
            desktopStripGroup { editTools }
            desktopStripGroup { workspace.fixedSize() }
            HStack(spacing: 8) {
                desktopStripGroup { live.fixedSize() }
                    .overlay(alignment: .leading) { desktopStripDivider.offset(x: -4) }
                zoomTools()
            }.fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.frame(minWidth: width)
            .environment(\.desktopEditingStripDensity, density)
        #if os(macOS)
        .environment(\.desktopEditingStripChrome, true)
        #endif
    }

    private func desktopStripGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().overlay(alignment: .trailing) {
            desktopStripDivider.offset(x: 4)
        }
    }

    private var desktopStripDivider: some View {
        Rectangle().fill(.white.opacity(0.17)).frame(width: 1, height: 22).allowsHitTesting(false)
    }

    private var editTools: some View {
        let height = TimelineEditingBarMetrics.controlHeight
        let envelopesVisible = show.allTrackAutomationLanesVisible
        return HStack(spacing: TransportControlMetrics.groupSpacing) {
            TimelineEditButton(show: show, key: editKey, width: 74, height: height, showsTitle: true)
            ProGridToolPicker(selection: $tool, height: height)
            Button { show.toggleAllTrackAutomationLanes() } label: {
                TransportControlIcon(name: "automationLanes", size: 17)
            }.buttonStyle(TransportButtonStyle(color: envelopesVisible ? JarasTheme.green : Color(hex: 0x454545),
                active: envelopesVisible, inactiveOpacity: 1, width: 34, height: height, bordered: false))
                .accessibilityLabel("Track envelopes").accessibilityIdentifier("track-envelopes")
                .accessibilityAddTraits(envelopesVisible ? .isSelected : [])
                .jarasHelp("Track envelopes").disabled(!show.canToggleAllTrackAutomationLanes)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func leftControls(showsTiming: Bool = true) -> some View {
        HStack(spacing: TimelineEditingBarMetrics.groupSpacing) {
            if workspaceButtons != nil && showsTiming {
                desktopStripGroup { mixerButtons }
            } else {
                mixerButtons
            }
            if showsTiming { timelineToggles }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var timelineToggles: some View {
        let relative = show.current?.projectTime.timebase == .relative
        return HStack(spacing: TransportControlMetrics.groupSpacing) {
            Button { snapEnabled.toggle() } label: {
                timelineLabel(icon: "magnet", active: snapEnabled)
            }.buttonStyle(TimelineSwitchStyle())
                .accessibilityLabel("Timeline snapping").accessibilityIdentifier("timeline-snap")
                .accessibilityValue(snapEnabled ? "On" : "Off")
                .jarasHelp(snapEnabled ? "Snap on — Shift temporarily disables snapping" : "Snap off — free positioning")
            #if os(macOS)
            TimebaseConfirmationButton(request: { timebaseChange(relative: !relative) }, apply: applyTimebase) {
                timelineLabel(icon: "itemTimebase", active: relative && !movingRegion)
            }
            .buttonStyle(TimelineSwitchStyle())
            .accessibilityLabel("Relative timebase").accessibilityIdentifier("timeline-timebase")
            .accessibilityValue(relative && !movingRegion ? "Enabled" : "Disabled")
            .disabled(show.current == nil || movingRegion)
            #else
            Button {
                guard let request = timebaseChange(relative: !relative) else { return }
                pendingTimebase = request
                confirmingTimebase = true
            } label: {
                timelineLabel(icon: "itemTimebase", active: relative && !movingRegion)
            }.buttonStyle(TimelineSwitchStyle())
                .accessibilityLabel("Relative timebase").accessibilityIdentifier("timeline-timebase")
                .accessibilityValue(relative && !movingRegion ? "Enabled" : "Disabled")
                .disabled(show.current == nil || movingRegion)
            #endif
        }
    }

    private func timelineLabel(icon: String, active: Bool) -> some View {
        TransportControlIcon(name: icon, size: 17)
            .foregroundStyle(active ? JarasTheme.green : JarasTheme.yellow)
            .frame(width: 34, height: TimelineEditingBarMetrics.controlHeight).contentShape(Rectangle())
    }

    private func timebaseChange(relative: Bool) -> TimebaseChange? {
        guard show.canControl(), let song = show.current else { return nil }
        return TimebaseChange(project: show.snapshot.project.id, song: song.id, relative: relative)
    }

    private func applyTimebase(_ pending: TimebaseChange) {
        guard pending.project == show.snapshot.project.id, show.canControl(),
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
                .overlay { shape.strokeBorder(Color.white.opacity(0.23)).allowsHitTesting(false) }
                .contentShape(Rectangle())
        }
    }

}

#if os(iOS)
private struct NativeTimelineStripLayout: Layout {
    var viewportWidth: CGFloat
    private let spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let controls = subviews[0].sizeThatFits(.unspecified)
        let utilities = subviews[1].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        return CGSize(width: max(viewportWidth, controls.width + utilities.width + right.width + spacing * 2),
                      height: max(controls.height, utilities.height, right.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let controls = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        let utilityWidth = max(0, bounds.width - controls.width - right.width - spacing * 2)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(controls))
        subviews[1].place(at: CGPoint(x: bounds.minX + controls.width + spacing, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: utilityWidth, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(right))
    }
}
#endif

struct DesktopZoomControls: View {
    static let defaultSliderWidth: CGFloat = 68
    static let memoryWidth: CGFloat = 49
    static func totalWidth(sliderWidth: CGFloat) -> CGFloat { memoryWidth + 6 + 2 * sliderWidth }
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
    var controlHeight: CGFloat = 24
    var sliderWidth = DesktopZoomControls.defaultSliderWidth
    var largerSliders = false
    var memoryButtonWidth: CGFloat = 24
    var showsSliders = true
    var showsMemories = true
    var groupSpacing: CGFloat = 5

    var body: some View {
        HStack(spacing: groupSpacing) {
            if showsMemories {
                HStack(spacing: 0) {
                    ZoomButton(symbol: "fitTracks", label: height.toggleLabel, id: height.id + "-memory",
                               active: height.active, controlHeight: controlHeight, width: memoryButtonWidth, action: height.toggle)
                    Rectangle().fill(Color(hex: 0x393939)).frame(width: 1)
                    ZoomButton(symbol: "fitTime", label: time.toggleLabel, id: time.id + "-memory",
                               active: time.active, controlHeight: controlHeight, width: memoryButtonWidth, action: time.toggle)
                }.frame(height: controlHeight)
                    .background(Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if showsSliders {
                HStack(spacing: 0) {
                    ZoomSlider(symbol: "trackHeightAxis", label: height.label, id: height.id + "-slider",
                               value: height.value, range: height.range, controlHeight: controlHeight, width: sliderWidth, larger: largerSliders)
                    Rectangle().fill(Color(hex: 0x242424)).frame(width: 1)
                    ZoomSlider(symbol: "timelineZoomAxis", label: time.label, id: time.id + "-slider",
                               value: time.value, range: time.range, controlHeight: controlHeight, width: sliderWidth, larger: largerSliders)
                }.frame(height: controlHeight)
                    .background(Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private struct ZoomButton: View {
        let symbol: String
        let label: LocalizedStringKey
        let id: String
        let active: Bool
        let controlHeight: CGFloat
        let width: CGFloat
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                TransportControlIcon(name: symbol, size: 15, color: active ? JarasTheme.green : Color(hex: 0xd5d5d5))
                    .frame(width: width, height: controlHeight).contentShape(Rectangle())
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
        let controlHeight: CGFloat
        let width: CGFloat
        let larger: Bool

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
                    let diameter: CGFloat = larger ? 12 : 10
                    let radius = diameter / 2
                    let travel = max(1, geometry.size.width - diameter)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: 0x202020)).frame(height: larger ? 5 : 4).padding(.horizontal, radius)
                        Circle().fill(Color(hex: 0xa4a4a4)).frame(width: diameter, height: diameter)
                            .offset(x: travel * fraction)
                    }.frame(height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged {
                            let fraction = min(1, max(0, ($0.location.x - radius) / travel))
                            value = range.lowerBound + fraction * span
                        })
                }
            }.padding(.horizontal, 3).frame(width: width, height: controlHeight)
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
    init(show: ShowController, documents: ProjectDocuments? = nil, embedded: Bool = false, alignment: Alignment = .trailing) {
        self.show = show; self.documents = documents; self.embedded = embedded; self.alignment = alignment
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    var documents: ProjectDocuments? = nil
    var embedded = false
    var alignment: Alignment
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
                    .frame(maxWidth: .infinity, alignment: alignment)
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
                    FooterInformationDisplay(show: noticeShow, embedded: true, alignment: .center)
                        .frame(width: max(0, noticeWidth - 1))
                        .frame(height: height)
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

struct PanelCollapseButton: View {
    let collapsed: Bool
    let title: String
    var icon: String? = nil
    let label: String
    let tooltip: String
    var height = TransportControlMetrics.height
    var cornerRadius: CGFloat = 6
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let icon { TransportControlIcon(name: icon, size: 17) }
                else { Text(verbatim: title).font(.jarasSystem(size: 9, weight: .bold)) }
            }
                .foregroundStyle(collapsed ? Color.white : Color.black)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(collapsed ? Color(hex: 0x454545) : JarasTheme.green)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityValue(collapsed ? "Hidden" : "Shown").jarasHelp(tooltip)
    }
}

#if os(macOS)
/// Finish a field edit even when the destination is not focusable.
struct FieldOutsideClick: NSViewRepresentable {
    let active: Bool
    var includesOtherWindows = false
    let dismiss: () -> Void
    func makeNSView(context: Context) -> FieldOutsideClickView { FieldOutsideClickView() }
    func updateNSView(_ view: FieldOutsideClickView, context: Context) {
        view.active = active; view.includesOtherWindows = includesOtherWindows; view.dismiss = dismiss
    }
}
final class FieldOutsideClickView: NSView {
    var active = false
    var includesOtherWindows = false
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
        guard active, let window else { return }
        if event.window === window {
            guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        } else if !includesOtherWindows {
            return
        }
        // Do this before forwarding the event so the destination receives its
        // usual click and may acquire focus itself (including the other field).
        active = false
        window.makeFirstResponder(nil)
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
    @State private var bpmDraft = ""
    @State private var invalidBPM = false
    @FocusState private var bpmFocused: Bool
    @State private var beats = "4"
    @State private var unit = "4"
    @State private var hoveredStep: Double?
    @FocusState private var meterFocus: Int?
    let panelHeight: CGFloat
    let panelWidth: CGFloat?
    init(show: ShowController, documents: ProjectDocuments? = nil, panelHeight: CGFloat = TransportControlMetrics.detailHeight, panelWidth: CGFloat? = nil) {
        self.show = show; self.documents = documents; self.panelHeight = panelHeight; self.panelWidth = panelWidth
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    private var bpmText: String {
        String(format: "%g", show.tempoControlBPM)
    }
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                meterField($beats, index: 0, label: "Beats per bar")
                Text(verbatim: "/").foregroundStyle(JarasTheme.text).frame(width: 6).fixedSize()
                meterField($unit, index: 1, label: "Beat unit")
            }
            if panelWidth != nil { Spacer(minLength: 0) }
            HStack(spacing: 2) {
                tempoStep(-1, symbol: "minus")
                if panelWidth != nil { Spacer(minLength: 0) }
                bpmReadout
                if panelWidth != nil { Spacer(minLength: 0) }
                tempoStep(1, symbol: "plus")
            }
        }.textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            .font(.jarasSystem(size: 13, design: .monospaced))
            .padding(.horizontal, 4)
            .frame(width: panelWidth, height: panelHeight)
            .background(TransportDetailSurface())
            .onAppear(perform: refreshMeter)
            .onChange(of: meterFocus) { if $0 == nil { commitMeter() } }
            .onChange(of: show.tempoInputAllowed) { if !$0 { cancelBPMEntry() } }
            .onChange(of: show.transportMeter?.beats) { _ in if meterFocus == nil { refreshMeter() } }
            .onChange(of: show.transportMeter?.unit) { _ in if meterFocus == nil { refreshMeter() } }
            .onChange(of: show.transportMeterEditingAllowed) { if !$0 { meterFocus = nil; refreshMeter() } }
            .onChange(of: show.snapshot.project.id) { _ in cancelBPMEntry(); show.resetTapTempo(); refreshMeter() }
    }

    private var bpmReadout: some View {
        VStack(spacing: 0) {
            if editing {
                TextField("BPM", text: $bpmDraft).focused($bpmFocused).accessibilityIdentifier("inline-bpm")
                    .onAppear { bpmFocused = true }
                    .onSubmit { finishBPMEntry(keepInvalidOpen: true) }
                    .onChange(of: bpmDraft) { _ in invalidBPM = false }
                    .onChange(of: bpmFocused) { if !$0 { finishBPMEntry() } }
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalidBPM ? Color.red : .clear).allowsHitTesting(false))
                    #if os(macOS)
                    .onExitCommand(perform: cancelBPMEntry)
                    .background(FieldOutsideClick(active: true) { finishBPMEntry() })
                    #endif
            } else {
                Button { show.tapTempo() } label: {
                    Text(bpmText).font(.jarasSystem(size: 15, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(show.tempoControlNeedsRender ? JarasTheme.yellow : JarasTheme.text)
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("BPM · Tap tempo")
                    .jarasHelp("Tap tempo · Right-click to edit BPM")
                    .immediateRightClick {
                        guard show.tempoInputAllowed else { return }
                        bpmDraft = bpmText; invalidBPM = false; editing = true
                    }
            }
            Text("BPM").font(.jarasSystem(size: 8))
        }.frame(width: 54, height: min(35, TransportControlMetrics.detailHeight - 2))
    }

    private func cancelBPMEntry() {
        editing = false; bpmFocused = false
    }

    private func finishBPMEntry(keepInvalidOpen: Bool = false) {
        guard editing else { return }
        let draft = bpmDraft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard show.tempoInputAllowed, let value = Double(draft), TimelineTempo.bpmRange.contains(value) else {
            if keepInvalidOpen { invalidBPM = true } else { cancelBPMEntry() }
            return
        }
        cancelBPMEntry()
        show.resetTapTempo()
        show.setTypedTempo(value)
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
    private func meterField(_ value: Binding<String>, index: Int, label: LocalizedStringKey) -> some View {
        Group {
            if show.transportMeterEditingAllowed {
                TextField("4", text: value)
                    .textFieldStyle(.plain)
                    .focused($meterFocus, equals: index)
                    #if os(macOS)
                    .background(FieldOutsideClick(active: meterFocus == index) { meterFocus = nil })
                    .immediateRightClick {}
                    #endif
                    .onSubmit { commitMeter(); meterFocus = nil }
            } else {
                Text(verbatim: value.wrappedValue)
                    .accessibilityValue(Text(verbatim: value.wrappedValue))
            }
        }
        .foregroundStyle(JarasTheme.text)
        .lineLimit(1)
        .padding(.horizontal, 2)
        .frame(width: 25, height: 24)
        .background(JarasTheme.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.10)) }
        .accessibilityLabel(Text(label))
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
    #if os(macOS)
    static let proHeight: CGFloat = 31
    #else
    static let proHeight: CGFloat = 32
    #endif
    static let playbackWidth: CGFloat = 60
    static let groupSpacing: CGFloat = 6
    static let desktopMainWidth: CGFloat = 248
    static let desktopBPMWidth: CGFloat = 238
    static let desktopTunerWidth: CGFloat = 138
    #if os(macOS)
    static let playbackHeight: CGFloat = 24
    static let detailHeight = proHeight
    #else
    static let playbackHeight: CGFloat = 28
    static let detailHeight: CGFloat = 43
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
struct TimelineEditButton: View {
    static let controlWidth: CGFloat = 28

    @AppStorage private var enabled: Bool
    @AppStorage private var seek: TimelineEditPreferences.Seek
    #if os(iOS)
    @State private var showingSeekOptions = false
    #endif
    let show: ShowController?
    let width: CGFloat
    let height: CGFloat
    let showsTitle: Bool

    init(show: ShowController?, key: String, width: CGFloat, height: CGFloat, showsTitle: Bool = false) {
        self.show = show; self.width = width; self.height = height
        self.showsTitle = showsTitle
        _enabled = AppStorage(wrappedValue: false, key)
        _seek = AppStorage(wrappedValue: .bar, key + ".seek")
    }

    var body: some View {
        let foreground = enabled ? Color.black : JarasTheme.text
        HStack(spacing: 0) {
            Button {
                enabled.toggle()
                if !enabled { clearPendingSeek() }
            } label: {
                HStack(spacing: 5) {
                    TransportControlIcon(name: "editCursor", size: 17)
                    if showsTitle { Text(verbatim: "Edit").font(.jarasSystem(size: TimelineEditingBarMetrics.labelSize, weight: .semibold)) }
                }.lineLimit(1)
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, minHeight: height).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Edit").accessibilityIdentifier("editMode")
                .accessibilityAddTraits(enabled ? .isSelected : [])
            #if os(iOS)
            Button { showingSeekOptions = true } label: {
                seekArrow(width: showsTitle ? 20 : 14, color: foreground)
            }.buttonStyle(.plain)
                .accessibilityLabel("Edit seek mode").accessibilityIdentifier("editSeekMode")
                .accessibilityValue(Text(verbatim: seek.label))
                .popover(isPresented: $showingSeekOptions, arrowEdge: .bottom) {
                    let options = VStack(spacing: 0) {
                        ForEach(TimelineEditPreferences.Seek.allCases, id: \.self) { mode in
                            Button {
                                seek = mode
                                showingSeekOptions = false
                            } label: {
                                HStack {
                                    Text(verbatim: mode.label)
                                    Spacer(minLength: 12)
                                    if seek == mode { Image(systemName: "checkmark") }
                                }.font(.jarasSystem(size: 13, weight: .semibold))
                                    .frame(height: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(seek == mode ? .isSelected : [])
                        }
                    }.frame(width: 168).padding(10)
                    if #available(iOS 16.4, *) { options.presentationCompactAdaptation(.popover) }
                    else { options }
                }
            #else
            Menu {
                Picker("Edit seek mode", selection: $seek) {
                    ForEach(TimelineEditPreferences.Seek.allCases, id: \.self) { mode in
                        Text(verbatim: mode.label).tag(mode)
                    }
                }.pickerStyle(.inline)
            } label: {
                seekArrow(width: showsTitle ? 14 : 11, color: foreground)
            }.buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("Edit seek mode")
            #endif
        }
        .frame(width: width, height: height)
        .background(enabled ? JarasTheme.yellow : Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: seek) { _ in clearPendingSeek() }
    }

    private func seekArrow(width: CGFloat, color: Color) -> some View {
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).frame(width: width, height: height).contentShape(Rectangle())
    }

    private func clearPendingSeek() {
        if let show, show.snapshot.transport.beatSeek != nil { show.send(.cancelBeatSeek) }
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
                if bordered { RoundedRectangle(cornerRadius: 6).stroke(active ? color : Color.white.opacity(0.45)).allowsHitTesting(false) }
            }
            .contentShape(Rectangle())
    }
}
struct TransportPreview: PreviewProvider { static var previews: some View { TransportView(show: try! AppContainer(preview: true).show).frame(width: 980, height: 118) } }

struct MetronomeModeButton: View {
    var controlHeight = TransportControlMetrics.proHeight
    @ObservedObject private var settings = MetronomeSettings.shared
    private var mode: Int { min(2, max(0, settings.mode)) }
    private var label: String { ["A-B", "A", "B"][mode] }

    var body: some View {
        Button { settings.mode = (mode + 1) % 3 } label: { Text(verbatim: label) }
            .buttonStyle(TransportButtonStyle(color: Color(hex: 0x454545), inactiveOpacity: 1,
                fontSize: 10, width: TransportControlMetrics.iconWidth, height: controlHeight, bordered: false))
            .accessibilityLabel("Click mode").accessibilityValue(label)
    }
}

private struct MetronomeControl: View {
    @ObservedObject private var settings = MetronomeSettings.shared
    @State private var configuring = false
    var body: some View { control }
    private var control: some View {
        Button { settings.enabled.toggle() } label: {
            TransportControlIcon(name: "metronome", size: 17)
        }
            .buttonStyle(TransportButtonStyle(color: settings.enabled ? JarasTheme.yellow : Color(hex: 0x454545),
                active: settings.enabled, inactiveOpacity: 1, fontSize: TransportControlMetrics.font,
                width: TransportControlMetrics.iconWidth, height: TransportControlMetrics.proHeight, bordered: false))
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
    @Environment(\.desktopEditingStripDensity) private var density
    var body: some View {
        Button { video.toggle() } label: {
            DesktopToolbarLabel(title: "Video", systemImage: "video", tone: video.visible ? .live : .neutral, showsTitle: density.showsVideoTitle)
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
    @Environment(\.desktopEditingStripDensity) private var density
    private let remote = DAWRemoteSession.shared
    @State private var enabled = DAWRemoteSession.shared.enabled
    @State private var settings = false
    var body: some View {
        Button {
            if remote.enabled { remote.setHostEnabled(false); settings = false }
            else { DAWRemoteHostBridge.bind(show); remote.setHostEnabled(true) }
        } label: {
            DesktopToolbarLabel(title: "Remote", systemImage: "dot.radiowaves.left.and.right", tone: enabled ? .live : .neutral,
                                showsTitle: density.showsRemoteTitle)
        }.buttonStyle(.plain)
            .accessibilityLabel("Remote").accessibilityValue(enabled ? "On" : "Off").help(Text("Remote"))
            .popover(isPresented: $settings) { DAWRemoteHostView() }
            .immediateRightClick { settings = true }
            .onReceive(remote.$enabled.removeDuplicates()) { if enabled != $0 { enabled = $0 } }
            .onReceive(remote.$connected.removeDuplicates()) { if $0 && settings { settings = false } }
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
