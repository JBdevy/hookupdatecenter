import SwiftUI
#if os(macOS)
import AppKit
import Combine

private struct TPPreviewSong: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let duration: Double
    let color: UInt32
}
private struct TPPreviewBlock: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let color: UInt32
    var songs: [TPPreviewSong] = []
    var duration = 0.0
}
private struct TPProjectionData: Equatable {
    var text = "", chords = "", song = "", queued = ""
    var currentRegion: UUID?, queuedRegion: UUID?
    var progress = 0.0
    var preview: [TPPreviewBlock] = []
}
@MainActor private final class TPProjectionDisplay: ObservableObject {
    @Published var data = TPProjectionData()
    @Published var fullscreen = false
    @Published var previewActive = false
    @Published var previewPage = 0
}
private struct LocalizedTeleprompterConfig: View {
    let preferences: TeleprompterPreferences
    let close: () -> Void
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        TeleprompterConfig(preferences: preferences,close: close)
            .environment(\.locale,Locale(identifier: language)).preferredColorScheme(.dark)
    }
}

@MainActor final class TeleprompterWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TeleprompterWindow()
    @Published private(set) var visible = false
    @Published private(set) var previewActive = false
    @Published private(set) var previewPage = 0
    private var window: ProjectionWindow?
    private var remoteConfiguration: NSPanel?
    private var configuration: NSPanel?
    private weak var show: ShowController?
    private let display = TPProjectionDisplay()
    private let preferences = TeleprompterPreferences.shared
    private var minimizeObservation: NSObjectProtocol?
    private var restoreObservation: NSObjectProtocol?
    private var minimizedWithMain = false
    private var preferenceObservation: AnyCancellable?
    private var cachedProject: UUID?, cachedSong: UUID?
    private var cachedRevision: UInt64?
    private var lastRemoteRefresh = 0.0
    private var cachedPreview: [TPPreviewBlock] = []
    override init() {
        super.init()
        minimizeObservation = NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification,object: nil,queue: .main) { [weak self] notice in
            guard let parent = notice.object as? NSWindow, parent.title == "Jaras Live" else { return }
            MainActor.assumeIsolated {
                guard let self, let window = self.window, !window.isProjectionFullscreen else { return }
                self.minimizedWithMain = true
                window.orderOut(nil)
            }
        }
        restoreObservation = NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification,object: nil,queue: .main) { [weak self] notice in
            guard let parent = notice.object as? NSWindow, parent.title == "Jaras Live" else { return }
            MainActor.assumeIsolated {
                guard let self, self.minimizedWithMain else { return }
                self.minimizedWithMain = false
                self.window?.orderFrontRegardless()
            }
        }
        preferenceObservation = preferences.$settings.dropFirst().sink { [weak self] _ in
            guard self?.visible == true || TeleprompterRemote.shared.enabled else { return }
            // Published sends before the stored profile changes. Read it on the
            // next main-queue turn so progress mode also changes while stopped.
            DispatchQueue.main.async { [weak self] in
                guard let self, let show = self.show else { return }
                self.update(show.snapshot,revision: show.projectRevision)
            }
        }
    }
    func toggle(show: ShowController) {
        if visible { window?.close(); return }
        self.show = show
        let window = ProjectionWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 450),styleMask: [.titled,.closable,.resizable,.miniaturizable],backing: .buffered,defer: false)
        window.title = "Teleprompter"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320,height: 180)
        window.level = .floating; window.hidesOnDeactivate = false; window.delegate = self
        window.contentView = NSHostingView(rootView: TeleprompterProjectionView(display: display,preferences: preferences))
        self.window = window; visible = true; display.fullscreen = false
        VideoPlayback.teleprompter.setProjectionEnabled(!previewActive)
        cachedRevision = nil
        update(show.snapshot,revision: show.projectRevision)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func togglePreview() {
        previewActive.toggle()
        display.previewActive = previewActive
        VideoPlayback.teleprompter.setProjectionEnabled(visible && !previewActive)
    }
    func selectPreviewPage(_ page: Int) {
        previewPage = min(5,max(0,page))
        display.previewPage = previewPage
    }
    /// Setlist edits invalidate only the cached preview, without rescheduling audio.
    func invalidatePreview() { cachedRevision = nil }
    /// INIT AUTO observes only playback identity; closed projections do no content work.
    func update(_ snapshot: ShowSnapshot, revision: UInt64 = 0) {
        TeleprompterTimerController.shared.observePlayback(snapshot)
        guard visible || TeleprompterRemote.shared.enabled else { return }
        if !visible {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastRemoteRefresh >= 0.1 else { return }
            lastRemoteRefresh = now
        }
        guard let song = snapshot.project.songs.first(where: { $0.id == snapshot.transport.songId }) ?? snapshot.project.songs.first else {
            if display.data != TPProjectionData() { display.data = TPProjectionData() }
            TeleprompterRemote.shared.clear()
            return
        }
        if cachedProject != snapshot.project.id || cachedSong != song.id || cachedRevision != revision {
            cachedProject = snapshot.project.id; cachedSong = song.id; cachedRevision = revision
            cachedPreview = preview(song: song,project: snapshot.project)
        }
        if visible {
            VideoPlayback.teleprompter.setStretch(preferences.settings.stretchesMedia)
            VideoPlayback.teleprompter.update(snapshot)
        }
        let transport = snapshot.transport
        let position = transport.playing ? transport.position : transport.editPosition ?? transport.position
        let region = (!transport.playing ? song.parts.first(where: { position >= $0.startTime && position < $0.endTime }) : nil)
            ?? song.parts.first(where: { $0.id == transport.regionId })
            ?? song.parts.first(where: { position >= $0.startTime && position < $0.endTime })
        let queue = song.parts.first(where: { $0.id == transport.queuedRegionId })
        var next = TPProjectionData()
        next.song = region?.name ?? song.name
        next.queued = queue?.name ?? snapshot.project.songs.first(where: { $0.id == snapshot.nextSongId || $0.id == transport.queue.songId })?.name ?? ""
        next.currentRegion = region?.id; next.queuedRegion = queue?.id
        var lyricClip: AudioClip?, chordClip: AudioClip?
        for track in song.tracks where !track.mute && (track.kind == .teleprompt || track.kind == .chords) {
            let active = track.clips.lazy.filter { !$0.isProjectionMedia && $0.muted != true && position >= $0.startTime && position < $0.startTime + $0.duration }.max { $0.startTime < $1.startTime }
            if track.kind == .teleprompt, lyricClip == nil { lyricClip = active }
            if track.kind == .chords, chordClip == nil { chordClip = active }
        }
        next.text = lyricClip?.text ?? ""; next.chords = chordClip?.text ?? ""
        if preferences.settings.progressEnabled,
           let clip = preferences.settings.progressMode == "chords" ? chordClip : lyricClip {
            // The bar needs smooth visible progress; other display fields update only at second/content boundaries.
            next.progress = (min(1,max(0,(position - clip.startTime) / clip.duration)) * 1000).rounded() / 1000
        }
        next.preview = cachedPreview
        if visible, display.data != next { display.data = next }
        if let window, display.fullscreen != window.isProjectionFullscreen { display.fullscreen = window.isProjectionFullscreen }
        if TeleprompterRemote.shared.enabled {
            let blocks = Array(next.preview.dropFirst(previewPage * 4).prefix(4)).map { block in
                TeleprompterRemoteBlock(name: block.name, color: block.color, duration: block.duration, songs: block.songs.map {
                    TeleprompterRemoteSong(name: $0.name, color: $0.id == next.currentRegion ? preferences.settings.highlightColor : $0.id == next.queuedRegion ? preferences.settings.queueNameColor : $0.color, duration: $0.duration)
                })
            }
            TeleprompterRemote.shared.update(text: next.text, chords: next.chords, song: next.song, queued: next.queued, progress: next.progress, preview: previewActive, blocks: blocks, snapshot: snapshot)
        }
    }
    private func preview(song: Song, project: Project) -> [TPPreviewBlock] {
        let state = project.regionSetlist ?? RegionSetlist()
        let playlist = state.playlists.first { $0.id == state.selectedId && $0.songId == song.id }
        let lookup = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id,$0) })
        let regions = playlist.map { $0.regionIds.compactMap { lookup[$0] } } ?? song.parts.filter { $0.parentRegionID == nil }.sorted { $0.startTime < $1.startTime }
        let blocks = Dictionary(grouping: (state.blocks ?? []).filter { $0.songId == song.id && $0.playlistId == playlist?.id },by: \.beforeRegionId)
        var result = [TPPreviewBlock(id: song.id.uuidString,name: "",color: 0xffea00)]
        for region in regions {
            for block in blocks[region.id] ?? [] {
                result.append(TPPreviewBlock(id: block.id.uuidString,name: block.name,color: block.color))
            }
            let last = result.count - 1
            result[last].duration += region.endTime - region.startTime
            result[last].songs.append(TPPreviewSong(id: region.id,name: region.displayName,duration: region.endTime-region.startTime,color: region.color ?? result[last].color))
        }
        result += (blocks[nil] ?? []).map { TPPreviewBlock(id: $0.id.uuidString,name: $0.name,color: $0.color) }
        return result.filter { !$0.name.isEmpty || !$0.songs.isEmpty }
    }

    func showSettings() {
        if let configuration { configuration.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 760,height: 700),styleMask: [.titled,.closable,.resizable,.utilityWindow],backing: .buffered,defer: false)
        panel.title = JarasLocalization.string("Teleprompter settings")
        panel.contentMinSize = NSSize(width: 500,height: 520)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false; panel.hidesOnDeactivate = true
        panel.level = .normal; panel.delegate = self
        panel.contentView = NSHostingView(rootView: LocalizedTeleprompterConfig(preferences: preferences,close: { [weak panel] in panel?.close() }))
        configuration = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func configureRemote(show: ShowController, directory: URL?) {
        self.show = show
        TeleprompterRemote.shared.configure(directory: directory) { [weak self, weak show] in
            guard let self, let show else { return }
            self.update(show.snapshot, revision: show.projectRevision)
        }
    }
    func showRemote(show: ShowController, directory: URL?) {
        configureRemote(show: show, directory: directory)
        if let remoteConfiguration { remoteConfiguration.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = JarasLocalization.string("TP Remoto"); panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hidesOnDeactivate = true; panel.delegate = self
        panel.contentView = NSHostingView(rootView: TeleprompterRemoteView(close: { [weak panel] in panel?.close() }))
        remoteConfiguration = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func windowDidResize(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        if display.fullscreen != window.isProjectionFullscreen { display.fullscreen = window.isProjectionFullscreen }
    }
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        if closed === window {
            minimizedWithMain = false
            visible = false; window?.contentView = nil; window = nil
            VideoPlayback.teleprompter.setProjectionEnabled(false)
            cachedPreview = []; cachedRevision = nil
            if !TeleprompterRemote.shared.enabled { show = nil }
        } else if closed === configuration { configuration?.contentView = nil; configuration = nil }
        else if closed === remoteConfiguration { remoteConfiguration?.contentView = nil; remoteConfiguration = nil }
    }
}

struct TeleprompterToggleButton: View {
    let show: ShowController
    var directory: URL? = nil
    @ObservedObject private var controller = TeleprompterWindow.shared
    var body: some View {
        Button { controller.toggle(show: show) } label: {
            Label("Teleprompter",systemImage: "text.alignleft").font(.system(size: 10,weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7).frame(height: 28)
                .foregroundStyle(controller.visible ? Color.black : JarasTheme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(controller.visible ? JarasTheme.green : Color(hex: 0xc44545)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(controller.visible ? JarasTheme.green : Color(hex: 0xc44545)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Configurações") { controller.showSettings() }
                Button("TP Remoto") { controller.showRemote(show: show, directory: directory) }
            }
            .jarasHelp("Teleprompter").accessibilityLabel("Teleprompter")
    }
}
struct TeleprompterPreviewButton: View {
    @ObservedObject private var controller = TeleprompterWindow.shared
    @State private var choosingPage = false
    var body: some View {
        Button { controller.togglePreview() } label: {
            Text("Preview").font(.system(size: 10,weight: .semibold))
                .padding(.horizontal, 7).frame(height: 28)
                .foregroundStyle(controller.previewActive ? Color.black : JarasTheme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(controller.previewActive ? JarasTheme.green : Color(hex: 0xc44545)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(controller.previewActive ? JarasTheme.green : Color(hex: 0xc44545)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).jarasHelp("Preview")
            .overlay(TeleprompterRightClick(action: { choosingPage = true }))
            .popover(isPresented: $choosingPage) {
                VStack(alignment: .leading,spacing: 12) {
                    Text("Preview").font(.headline)
                    Picker("Blocks",selection: Binding(get: { controller.previewPage },set: { controller.selectPreviewPage($0) })) {
                        ForEach(0..<6) { page in
                            Text("Blocks \(page * 4 + 1)–\(page * 4 + 4)").tag(page)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                }.padding(16).frame(width: 660)
            }
    }
}
private struct TeleprompterRightClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> TeleprompterRightClickView { TeleprompterRightClickView() }
    func updateNSView(_ view: TeleprompterRightClickView, context: Context) { view.action = action }
}
private final class TeleprompterRightClickView: RightClickTargetView { override var priority: Int { 100 } }

private struct TeleprompterProjectionView: View {
    @ObservedObject var display: TPProjectionDisplay
    @ObservedObject var preferences: TeleprompterPreferences
    @ObservedObject private var timer = TeleprompterTimerController.shared
    @AppStorage("jaras.language") private var language = "en"
    private var settings: TeleprompterSettings { preferences.settings }
    private var data: TPProjectionData { display.data }
    var body: some View {
        GeometryReader { geometry in
            let animatedBorders = settings.rgbWindowBorderEnabled || settings.rgbClockBorderEnabled || settings.rgbTextBoxBorderEnabled || settings.rgbChordBorderEnabled
            TimelineView(.periodic(from: .now,by: animatedBorders ? 0.2 : 0.5)) { context in
                VStack(spacing: 3) {
                    decorations(top: true,date: context.date,size: geometry.size)
                    GeometryReader { content in
                        ZStack {
                            Color.clear
                            if display.previewActive { previewGrid(size: content.size) }
                            else if !data.text.isEmpty { lyricText(size: content.size,date: context.date) }
                        }.clipped()
                    }
                    decorations(top: false,date: context.date,size: geometry.size)
                }.padding(display.fullscreen ? 0 : 3)
                    .background {
                        ZStack {
                            Color.black
                            if !display.previewActive { ProjectionMediaSurface(controller: VideoPlayback.teleprompter) }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.windowBorderEnabled ? border(settings.borderColor,rgb: settings.rgbWindowBorderEnabled,date: context.date) : .clear,lineWidth: 2))
            }
        }.background(Color.black).environment(\.locale,Locale(identifier: language))
    }
    @ViewBuilder private func decorations(top: Bool, date: Date, size: CGSize) -> some View {
        let timerHere = settings.clockEnabled && settings.clockPosition.hasSuffix(top ? "top" : "bottom")
        let localHere = settings.localClockEnabled && (settings.clockEnabled ? timerHere : top)
        if timerHere || localHere { clockRow(date: date,size: size,timer: timerHere,local: localHere) }
        if settings.songNameEnabled && settings.songNamePosition == (top ? "top" : "bottom") {
            title(data.song,color: settings.songNameColor,font: settings.songNameFontFamily,scale: settings.songNameScale)
        }
        if settings.queueNameEnabled && settings.queueNamePosition == (top ? "top" : "bottom") {
            title(data.queued.isEmpty ? JarasLocalization.string("Queue is empty") : data.queued,color: settings.queueNameColor,font: settings.queueNameFontFamily,scale: settings.queueNameScale)
        }
        if !display.previewActive && settings.chordsEnabled && !data.chords.isEmpty && settings.chordPosition == (top ? "top" : "bottom") {
            Text(settings.display(data.chords)).font(tpFont(settings.chordFontFamily,size: settings.chordScale))
                .foregroundStyle(Color(hex: settings.chordColor)).lineLimit(2).minimumScaleFactor(0.4).padding(6)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(border(settings.chordColor,rgb: settings.rgbChordBorderEnabled,date: date),lineWidth: 1))
        }
        if settings.progressEnabled && settings.progressPosition == (top ? "top" : "bottom") {
            GeometryReader { bar in Color(hex: settings.progressColor).frame(width: bar.size.width * data.progress) }
                .frame(height: 5).background(Color.white.opacity(0.1))
        }
    }
    private func clockRow(date: Date, size: CGSize, timer: Bool, local: Bool) -> some View {
        let width = max(1,size.width - 16), side = !settings.clockPosition.hasPrefix("center")
        let font = max(size.height > size.width ? 15 : 18,min(width / 11,size.height / 8) * settings.clockScale / 100)
        let localSideFont = max(size.height > size.width ? 15 : 18,min(width / 11,size.height / 8) * settings.localClockScale / 100)
        let height = max(28,(side && local ? max(font,localSideFont) : font) + (side && local ? 10 : 18))
        let timerWidth = min(width,max(118,("-00 : 00 : 00" as NSString).size(withAttributes: [.font: NSFont(name: "Arial-BoldMT",size: font) ?? NSFont.boldSystemFont(ofSize: font)]).width + 36))
        return ZStack {
            if side && timer && local {
                HStack(spacing: 8) {
                    if settings.clockPosition.hasPrefix("right") { localClock(date,font: localSideFont).frame(maxWidth: .infinity) }
                    timerText(font: font,date: date).frame(maxWidth: .infinity)
                    if settings.clockPosition.hasPrefix("left") { localClock(date,font: localSideFont).frame(maxWidth: .infinity) }
                }
            } else {
                if timer {
                    timerText(font: font,date: date).frame(width: timerWidth)
                        .frame(maxWidth: .infinity,alignment: settings.clockPosition.hasPrefix("left") ? .leading : settings.clockPosition.hasPrefix("right") ? .trailing : .center)
                }
                if local {
                    let localWidth = timer ? max(0,(width-timerWidth)/2-8) : width
                    let localFont = max(10,min(24,size.height/28) * settings.localClockScale / 100)
                    HStack {
                        if settings.localClockPosition == "right" { Spacer(minLength: 0) }
                        localClock(date,font: localFont).frame(maxWidth: localWidth,alignment: settings.localClockPosition == "right" ? .trailing : .leading).clipped()
                        if settings.localClockPosition != "right" { Spacer(minLength: 0) }
                    }.frame(maxHeight: .infinity,alignment: settings.clockPosition.hasSuffix("bottom") ? .bottom : .top)
                }
            }
        }.frame(height: height).frame(maxWidth: .infinity)
    }
    private func timerText(font: CGFloat,date: Date) -> some View {
        Text(timer.displayText(spaced: true)).opacity(timer.displayOpacity()).font(.custom("Arial-BoldMT",size: font)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.3)
            .foregroundStyle(timer.expired() ? Color.red : Color(hex: settings.clockColor)).padding(.horizontal,10).padding(.vertical,5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.clockBorderEnabled ? border(settings.clockBorderColor,rgb: settings.rgbClockBorderEnabled,date: date) : .clear,lineWidth: 2))
    }
    private func localClock(_ date: Date,font: CGFloat) -> some View {
        let values = Calendar.current.dateComponents([.hour,.minute,.second],from: date)
        return Text(String(format: "%02d:%02d:%02d",values.hour ?? 0,values.minute ?? 0,values.second ?? 0)).font(.custom("Arial-BoldMT",size: font)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.3)
            .foregroundStyle(Color(hex: settings.localClockColor)).padding(.horizontal,5).padding(.vertical,5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.localClockBorderEnabled ? border(settings.localClockBorderColor,rgb: settings.rgbClockBorderEnabled,date: date) : .clear,lineWidth: 1))
            .padding(.horizontal,display.fullscreen ? 24 : 0)
    }
    private func title(_ text: String,color: UInt32,font: String,scale: Double) -> some View {
        Text(settings.display(text)).font(tpFont(font,size: 22 * scale / 100)).foregroundStyle(Color(hex: color))
            .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity)
    }
    private func lyricText(size: CGSize,date: Date) -> some View {
        let text = settings.display(data.text)
        let lines = text.components(separatedBy: .newlines)
        let longest = max(1,lines.map(\.count).max() ?? 1)
        let font = max(9,min(120,min((size.width-20) / (Double(longest)*0.64),(size.height-20) / (Double(max(1,lines.count))*1.2))) * settings.textScale / 100)
        let textWidth = min(size.width,max(20,Double(longest) * font * 0.64 + 12))
        let alignment: Alignment = settings.textAlignment == "left" ? .leading : settings.textAlignment == "right" ? .trailing : .center
        let textAlignment: TextAlignment = settings.textAlignment == "left" ? .leading : settings.textAlignment == "right" ? .trailing : .center
        return Text(text).font(tpFont(settings.fontFamily,size: font)).foregroundStyle(Color(hex: settings.textColor))
            .multilineTextAlignment(textAlignment).lineLimit(nil).minimumScaleFactor(0.3).padding(6).frame(width: textWidth)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.textBoxEnabled ? border(settings.textBoxColor,rgb: settings.rgbTextBoxBorderEnabled,date: date) : .clear,lineWidth: 2))
            .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: alignment)
    }
    private func previewGrid(size: CGSize) -> some View {
        let blocks = Array(data.preview.dropFirst(display.previewPage * 4).prefix(4))
        let columns = max(1,min(4,blocks.count))
        let longestColumn = max(1,(blocks.count + columns - 1) / columns)
        let mostSongs = max(1,blocks.map { $0.songs.count + ($0.name.isEmpty ? 0 : 1) }.max() ?? 1)
        let font = max(9,min((size.width/Double(columns)-20)/13,(size.height/Double(longestColumn)-20)/Double(mostSongs)/1.1) * settings.previewScale / 100)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 8,alignment: .top),count: columns),alignment: .leading,spacing: 8) {
            ForEach(blocks) { block in
                VStack(alignment: .leading,spacing: 3) {
                    if !block.name.isEmpty {
                        Text(settings.display(block.name) + (settings.previewBlockDurationEnabled && block.duration > 0 ? " • " + tpTime(Int(ceil(block.duration))) : ""))
                            .font(tpFont(settings.previewFontFamily,size: font * 1.05)).foregroundStyle(Color(hex: block.color)).lineLimit(2)
                    }
                    ForEach(block.songs) { song in
                        Text(settings.display(song.name) + (settings.previewSongDurationEnabled ? " • " + tpTime(Int(ceil(song.duration))) : ""))
                            .font(tpFont(settings.previewFontFamily,size: font))
                            .foregroundStyle(Color(hex: song.id == data.currentRegion ? settings.highlightColor : song.id == data.queuedRegion ? settings.queueNameColor : song.color))
                            .underline(settings.previewUnderlineEnabled).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity,alignment: .leading).padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: block.color).opacity(0.7)))
            }
        }.padding(6).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
    }
    private func border(_ color: UInt32,rgb: Bool,date: Date) -> Color {
        rgb ? Color(hue: date.timeIntervalSince1970.truncatingRemainder(dividingBy: 6)/6,saturation: 0.9,brightness: 1) : Color(hex: color)
    }
}
private func tpFont(_ name: String,size: CGFloat) -> Font {
    let names = ["arial":"Arial-BoldMT","segoe":"SegoeUI-Bold","bahnschrift":"Bahnschrift","verdana":"Verdana-Bold","tahoma":"Tahoma-Bold","georgia":"Georgia-Bold","trebuchet":"TrebuchetMS-Bold","impact":"Impact","mono":"CourierNewPS-BoldMT"]
    if let font = names[name], NSFont(name: font,size: size) != nil { return .custom(font,size: size) }
    return .system(size: size,weight: .bold,design: name == "mono" ? .monospaced : .default)
}
private func tpTime(_ seconds: Int,spaced: Bool = false) -> String {
    let value = abs(seconds), separator = spaced ? " : " : ":"
    let time = String(format: "%02d%@%02d%@%02d",value/3600,separator,value/60%60,separator,value%60)
    return (seconds < 0 ? "−" : "") + time
}
#else
@MainActor final class TeleprompterWindow: ObservableObject {
    static let shared = TeleprompterWindow()
    func invalidatePreview() {}
    func update(_ snapshot: ShowSnapshot,revision: UInt64 = 0) { TeleprompterTimerController.shared.observePlayback(snapshot) }
}
#endif
