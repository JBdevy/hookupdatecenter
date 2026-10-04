import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// One native layout for Mac and iPad: settings and geometry follow the same formulas.
struct TeleprompterProjectionLayout<Media: View>: View {
    let content: DAWRemoteTeleprompter
    let fullscreen: Bool
    let timerValue: () -> (text: String, opacity: Double, expired: Bool)
    @ViewBuilder let media: () -> Media
    private var settings: TeleprompterSettings { content.resolvedSettings }
    var body: some View {
        GeometryReader { geometry in
            let animatedBorders = settings.rgbWindowBorderEnabled || settings.rgbClockBorderEnabled || settings.rgbTextBoxBorderEnabled || settings.rgbChordBorderEnabled
            TimelineView(.periodic(from: .now,by: animatedBorders ? 0.2 : 0.5)) { context in
                VStack(spacing: 3) {
                    decorations(top: true,date: context.date,size: geometry.size)
                    GeometryReader { area in
                        ZStack {
                            Color.clear
                            if content.preview { previewGrid(size: area.size) }
                            else if !content.text.isEmpty { lyricText(size: area.size,date: context.date) }
                        }.clipped()
                    }
                    decorations(top: false,date: context.date,size: geometry.size)
                }.padding(fullscreen ? 0 : 3)
                    .background {
                        ZStack {
                            Color.black
                            if !content.preview { media().scaleEffect(settings.mediaScale / 100).clipped() }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.windowBorderEnabled ? border(settings.borderColor,rgb: settings.rgbWindowBorderEnabled,date: context.date) : .clear,lineWidth: 2))
            }
        }.background(Color.black)
    }
    @ViewBuilder private func decorations(top: Bool, date: Date, size: CGSize) -> some View {
        let timerHere = settings.clockEnabled && settings.clockPosition.hasSuffix(top ? "top" : "bottom")
        let localHere = settings.localClockEnabled && (settings.clockEnabled ? timerHere : top)
        if timerHere || localHere { clockRow(date: date,size: size,timer: timerHere,local: localHere) }
        if settings.songNameEnabled && !content.song.isEmpty && settings.songNamePosition == (top ? "top" : "bottom") {
            title(content.song,color: settings.songNameColor,font: settings.songNameFontFamily,scale: settings.songNameScale)
        }
        if settings.queueNameEnabled && !content.queued.isEmpty && settings.queueNamePosition == (top ? "top" : "bottom") {
            title(content.queued,color: settings.queueNameColor,font: settings.queueNameFontFamily,scale: settings.queueNameScale)
        }
        if !content.preview && settings.chordsEnabled && !content.chords.isEmpty && settings.chordPosition == (top ? "top" : "bottom") {
            Text(settings.display(content.chords)).font(tpFont(settings.chordFontFamily,size: settings.chordScale))
                .foregroundStyle(Color(hex: settings.chordColor)).lineLimit(2).minimumScaleFactor(0.4).padding(6)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(border(settings.chordColor,rgb: settings.rgbChordBorderEnabled,date: date),lineWidth: 1))
        }
        if settings.progressEnabled && settings.progressPosition == (top ? "top" : "bottom") {
            GeometryReader { bar in Color(hex: settings.progressColor).frame(width: bar.size.width * content.progress) }
                .frame(height: 5).background(Color.white.opacity(0.1))
        }
    }
    private func clockRow(date: Date, size: CGSize, timer: Bool, local: Bool) -> some View {
        let width = max(1,size.width - 16), side = !settings.clockPosition.hasPrefix("center")
        let font = max(size.height > size.width ? 15 : 18,min(width / 11,size.height / 8) * settings.clockScale / 100)
        let localSideFont = max(size.height > size.width ? 15 : 18,min(width / 11,size.height / 8) * settings.localClockScale / 100)
        let height = max(28,(side && local ? max(font,localSideFont) : font) + (side && local ? 10 : 18))
        // Keep a real clock column on narrow phone screens, including fullscreen.
        let timerLimit = compactPhone && local && !side ? max(1, width - 152) : width
        let timerWidth = min(timerLimit,max(118,tpTimerTextWidth(font) + 36))
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
        Text(timerValue().text).opacity(timerValue().opacity).font(.custom("Arial-BoldMT",size: font)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.3)
            .foregroundStyle(Color(hex: timerValue().expired ? settings.clockExpiredColor : settings.clockColor)).padding(.horizontal,10).padding(.vertical,5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.clockBorderEnabled ? border(settings.clockBorderColor,rgb: settings.rgbClockBorderEnabled,date: date) : .clear,lineWidth: 2))
    }
    private func localClock(_ date: Date,font: CGFloat) -> some View {
        let values = Calendar.current.dateComponents([.hour,.minute,.second],from: date)
        return Text(String(format: "%02d:%02d:%02d",values.hour ?? 0,values.minute ?? 0,values.second ?? 0)).font(.custom("Arial-BoldMT",size: font)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.3)
            .foregroundStyle(Color(hex: settings.localClockColor)).padding(.horizontal,5).padding(.vertical,5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.localClockBorderEnabled ? border(settings.localClockBorderColor,rgb: settings.rgbClockBorderEnabled,date: date) : .clear,lineWidth: 1))
            .padding(.horizontal,fullscreen && !compactPhone ? 24 : 0)
    }
    private var compactPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
    private func title(_ text: String,color: UInt32,font: String,scale: Double) -> some View {
        Text(settings.display(text)).font(tpFont(font,size: 22 * scale / 100)).foregroundStyle(Color(hex: color))
            .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity)
    }
    private func lyricText(size: CGSize,date: Date) -> some View {
        let text = settings.display(content.text)
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
        let blocks = content.blocks
        let columns = max(1,min(4,blocks.count))
        let longestColumn = max(1,(blocks.count + columns - 1) / columns)
        let mostSongs = max(1,blocks.map { $0.rows.count + ($0.name.isEmpty ? 0 : 1) }.max() ?? 1)
        let font = max(9,min((size.width/Double(columns)-20)/13,(size.height/Double(longestColumn)-20)/Double(mostSongs)/1.1) * settings.previewScale / 100)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 8,alignment: .top),count: columns),alignment: .leading,spacing: 8) {
            ForEach(blocks) { block in
                VStack(alignment: .leading,spacing: 3) {
                    if !block.name.isEmpty {
                        Text(settings.display(block.name) + (settings.previewBlockDurationEnabled && (block.rows.reduce(0) { $0 + $1.duration }) > 0 ? " • " + tpTime(Int(ceil((block.rows.reduce(0) { $0 + $1.duration })))) : ""))
                            .font(tpFont(settings.previewFontFamily,size: font * 1.05)).foregroundStyle(Color(hex: block.color)).lineLimit(2)
                    }
                    ForEach(block.rows) { song in
                        Text(settings.display(song.name) + (settings.previewSongDurationEnabled ? " • " + tpTime(Int(ceil(song.duration))) : ""))
                            .font(tpFont(settings.previewFontFamily,size: font))
                            .underline(settings.previewUnderlineEnabled)
                            .foregroundStyle(Color(hex: song.color)).lineLimit(2)
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
    if let font = names[name], tpFontAvailable(font, size: size) { return .custom(font,size: size) }
    return .system(size: size,weight: .bold,design: name == "mono" ? .monospaced : .default)
}
private func tpTime(_ seconds: Int,spaced: Bool = false) -> String {
    let value = abs(seconds), separator = spaced ? " : " : ":"
    let time = String(format: "%02d%@%02d%@%02d",value/3600,separator,value/60%60,separator,value%60)
    return (seconds < 0 ? "−" : "") + time
}
private func tpFontAvailable(_ name: String, size: CGFloat) -> Bool {
    #if os(macOS)
    return NSFont(name: name, size: size) != nil
    #else
    return UIFont(name: name, size: size) != nil
    #endif
}
private func tpTimerTextWidth(_ size: CGFloat) -> CGFloat {
    #if os(macOS)
    let font = NSFont(name: "Arial-BoldMT", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    #else
    let font = UIFont(name: "Arial-BoldMT", size: size) ?? UIFont.boldSystemFont(ofSize: size)
    #endif
    return ("-00 : 00 : 00" as NSString).size(withAttributes: [.font: font]).width
}

#if os(macOS)
import AppKit
import Combine
import UniformTypeIdentifiers

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
    let initialSlot: Int
    let close: () -> Void
    @State private var slot = 1
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Teleprompter", selection: $slot) {
                Text("Teleprompter 1").tag(1)
                Text("Teleprompter 2").tag(2)
            }.pickerStyle(.segmented).padding(12)
            TeleprompterConfig(preferences: slot == 1 ? .shared : .second, close: close)
        }.onAppear { slot = initialSlot }
            .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
    }
}

@MainActor final class TeleprompterWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TeleprompterWindow(index: 1)
    static let second = TeleprompterWindow(index: 2)
    let index: Int
    @Published private(set) var visible = false
    @Published private(set) var previewActive = false
    @Published private(set) var previewPage = 0
    private var window: ProjectionWindow?
    private var remoteConfiguration: NSPanel?
    private var configuration: NSPanel?
    private weak var show: ShowController?
    private let display = TPProjectionDisplay()
    private let preferences: TeleprompterPreferences
    private var video: VideoPlayback { index == 1 ? .teleprompter : .teleprompter2 }
    private var minimizeObservation: NSObjectProtocol?
    private var restoreObservation: NSObjectProtocol?
    private var minimizedWithMain = false
    private var preferenceObservation: AnyCancellable?
    private var cachedProject: UUID?, cachedSong: UUID?
    private var cachedRevision: UInt64?
    private var lastRemoteRefresh = 0.0
    private var cachedPreview: [TPPreviewBlock] = []
    init(index: Int) {
        self.index = index
        preferences = index == 1 ? .shared : .second
        super.init()
        minimizeObservation = NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification,object: nil,queue: .main) { [weak self] notice in
            guard let parent = notice.object as? NSWindow, parent.title == "CatLive" else { return }
            MainActor.assumeIsolated {
                guard let self, let window = self.window, !window.isProjectionFullscreen else { return }
                self.minimizedWithMain = true
                window.orderOut(nil)
            }
        }
        restoreObservation = NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification,object: nil,queue: .main) { [weak self] notice in
            guard let parent = notice.object as? NSWindow, parent.title == "CatLive" else { return }
            MainActor.assumeIsolated {
                guard let self, self.minimizedWithMain else { return }
                self.minimizedWithMain = false
                self.window?.orderFrontRegardless()
            }
        }
        preferenceObservation = preferences.$settings.dropFirst().sink { [weak self] _ in
            guard self?.visible == true || (self?.index == 1 && TeleprompterRemote.shared.enabled) else { return }
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
        window.title = "Teleprompter \(index)"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320,height: 180)
        window.level = .floating; window.hidesOnDeactivate = false; window.delegate = self
        window.contentView = NSHostingView(rootView: TeleprompterProjectionView(index: index, display: display, preferences: preferences, video: video))
        self.window = window; visible = true; display.fullscreen = false
        if index == 2 { previewActive = Self.shared.previewActive; display.previewActive = previewActive }
        video.setProjectionEnabled(!previewActive)
        cachedRevision = nil
        update(show.snapshot,revision: show.projectRevision)
        window.restorePlacement(key: "jaras.teleprompterWindow.\(index)"); window.makeKeyAndOrderFront(nil)
        display.fullscreen = window.isProjectionFullscreen
    }
    func togglePreview() {
        setPreview(!previewActive)
        if index == 1 { Self.second.setPreview(previewActive) }
    }
    private func setPreview(_ active: Bool) {
        previewActive = active
        display.previewActive = active
        video.setProjectionEnabled(visible && !active)
    }
    func selectPreviewPage(_ page: Int) {
        previewPage = min(5,max(0,page))
        display.previewPage = previewPage
        if index == 1 { Self.second.previewPage = previewPage; Self.second.display.previewPage = previewPage }
    }
    /// Setlist edits invalidate only the cached preview, without rescheduling audio.
    func invalidatePreview() { cachedRevision = nil }
    /// INIT AUTO observes only playback identity; closed projections do no content work.
    func update(_ snapshot: ShowSnapshot, revision: UInt64 = 0) {
        if index == 1 { TeleprompterTimerController.shared.observePlayback(snapshot) }
        guard visible || (index == 1 && TeleprompterRemote.shared.enabled) else { return }
        if !visible {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastRemoteRefresh >= 0.1 else { return }
            lastRemoteRefresh = now
        }
        guard let originalSong = snapshot.project.songs.first(where: { $0.id == snapshot.transport.songId }) ?? snapshot.project.songs.first else {
            if display.data != TPProjectionData() { display.data = TPProjectionData() }
            if index == 1 { TeleprompterRemote.shared.clear() }
            return
        }
        let song = snapshot.transport.multiLoop?.projectionSong(originalSong) ?? originalSong
        if cachedProject != snapshot.project.id || cachedSong != song.id || cachedRevision != revision {
            cachedProject = snapshot.project.id; cachedSong = song.id; cachedRevision = revision
            cachedPreview = preview(song: song,project: snapshot.project)
        }
        if visible {
            video.setStretch(preferences.settings.stretchesMedia)
            video.update(snapshot)
        }
        let transport = snapshot.transport
        let position = transport.playing ? transport.position : transport.editPosition ?? transport.position
        let region = song.parts.filter { position >= $0.startTime && position < $0.endTime }
            .min { $0.endTime - $0.startTime < $1.endTime - $1.startTime }
        let queue = song.parts.first(where: { $0.id == transport.queuedRegionId })
        var next = TPProjectionData()
        next.song = region?.name ?? ""
        next.queued = queue?.name ?? snapshot.project.songs.first(where: { $0.id == transport.queue.songId })?.name ?? ""
        next.currentRegion = region?.id; next.queuedRegion = queue?.id
        var lyricClip: AudioClip?, chordClip: AudioClip?
        let lyricKind: TrackKind = index == 1 ? .teleprompt : .teleprompt2
        for track in song.tracks where !track.mute && (track.kind == lyricKind || track.kind == .chords) {
            let active = track.clips.lazy.filter { !$0.isProjectionMedia && $0.muted != true && position >= $0.startTime && position < $0.startTime + $0.duration }.max { $0.startTime < $1.startTime }
            if track.kind == lyricKind, lyricClip == nil { lyricClip = active }
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
        if index == 1 && TeleprompterRemote.shared.enabled {
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
        if index == 2 { Self.shared.showSettings(initialSlot: 2); return }
        showSettings(initialSlot: 1)
    }
    private func showSettings(initialSlot: Int) {
        if let configuration {
            configuration.contentView = NSHostingView(rootView: LocalizedTeleprompterConfig(initialSlot: initialSlot, close: { [weak configuration] in configuration?.close() }))
            configuration.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 760,height: 700),styleMask: [.titled,.closable,.resizable,.utilityWindow],backing: .buffered,defer: false)
        panel.title = JarasLocalization.string("Teleprompter settings")
        panel.contentMinSize = NSSize(width: 500,height: 520)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false; panel.hidesOnDeactivate = true
        panel.level = .normal; panel.delegate = self
        panel.contentView = NSHostingView(rootView: LocalizedTeleprompterConfig(initialSlot: initialSlot, close: { [weak panel] in panel?.close() }))
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
            video.setProjectionEnabled(false)
            cachedPreview = []; cachedRevision = nil
            if index == 2 || !TeleprompterRemote.shared.enabled { show = nil }
        } else if closed === configuration { configuration?.contentView = nil; configuration = nil }
        else if closed === remoteConfiguration { remoteConfiguration?.contentView = nil; remoteConfiguration = nil }
    }
}

struct TeleprompterToggleButton: View {
    let show: ShowController
    var directory: URL? = nil
    let index: Int
    @ObservedObject private var controller: TeleprompterWindow
    init(show: ShowController, directory: URL? = nil, index: Int) {
        self.show = show
        self.directory = directory
        self.index = index
        self.controller = index == 1 ? .shared : .second
    }
    var body: some View {
        Button { controller.toggle(show: show) } label: {
            Label("TP-\(index)",systemImage: "text.alignleft").font(.system(size: TransportControlMetrics.font,weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: TransportControlMetrics.width, height: TransportControlMetrics.height)
                .foregroundStyle(controller.visible ? Color.black : JarasTheme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(controller.visible ? JarasTheme.green : Color(hex: 0xc44545)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(controller.visible ? JarasTheme.green : Color(hex: 0xc44545)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Configurações") { controller.showSettings() }
                if index == 1 { Button("TP Remoto") { controller.showRemote(show: show, directory: directory) } }
            }
            .jarasHelp(index == 1 ? ControlMappings.shared.shortcutHelp(.toggleTeleprompter) : "Teleprompter 2")
            .accessibilityLabel("Teleprompter \(index)")
    }
}
struct TeleprompterPreviewButton: View {
    @ObservedObject private var controller = TeleprompterWindow.shared
    @State private var choosingPage = false
    var body: some View {
        Button { controller.togglePreview() } label: {
            Text("Preview").font(.system(size: TransportControlMetrics.font,weight: .semibold))
                .frame(width: TransportControlMetrics.width, height: TransportControlMetrics.height)
                .foregroundStyle(controller.previewActive ? Color.black : JarasTheme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(controller.previewActive ? JarasTheme.green : Color(hex: 0xc44545)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(controller.previewActive ? JarasTheme.green : Color(hex: 0xc44545)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).jarasHelp("Show blocks in the teleprompter")
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
    let index: Int
    @ObservedObject var display: TPProjectionDisplay
    @ObservedObject var preferences: TeleprompterPreferences
    @ObservedObject var video: VideoPlayback
    @ObservedObject private var timer = TeleprompterTimerController.shared
    @AppStorage("jaras.language") private var language = "en"
    private var content: DAWRemoteTeleprompter {
        let data = display.data, settings = preferences.settings
        let blocks = Array(data.preview.dropFirst(display.previewPage * 4).prefix(4)).map { block in
            DAWRemoteTeleprompter.Block(id: UUID(uuidString: block.id)!, name: block.name, color: block.color, rows: block.songs.map { song in
                .init(id: song.id, name: song.name, color: song.id == data.currentRegion ? settings.highlightColor : song.id == data.queuedRegion ? settings.queueNameColor : song.color, duration: song.duration)
            })
        }
        return .init(index: index, text: data.text, chords: data.chords, song: data.song, queued: data.queued,
                     progress: data.progress, style: .init(), preview: display.previewActive, blocks: blocks, settings: settings)
    }
    var body: some View {
        TeleprompterProjectionLayout(content: content, fullscreen: display.fullscreen,
            timerValue: { (timer.displayText(spaced: true), timer.displayOpacity(), timer.expired()) },
            media: { ProjectionMediaSurface(controller: video) })
            .overlay { TPNoticeOverlay(index: index) }.environment(\.locale, Locale(identifier: language))
    }
}
#else
@MainActor final class TeleprompterWindow: ObservableObject {
    static let shared = TeleprompterWindow()
    func invalidatePreview() {}
    func update(_ snapshot: ShowSnapshot,revision: UInt64 = 0) { TeleprompterTimerController.shared.observePlayback(snapshot) }
}
#endif

#if os(macOS)
struct TPNoticeAppearance: Codable {
    var window1 = true, window2 = true, emojiEnabled = false, cleanDisplay = true
    var emoji = "⚠️", font = "Arial"
    var scale = 100.0
    var text: UInt32 = 0xffffff, background: UInt32 = 0x000000, flash: UInt32 = 0xffdc52
}
@MainActor final class TPNoticeController: ObservableObject {
    static let shared = TPNoticeController()
    @Published var appearance: TPNoticeAppearance { didSet { persist() } }
    @Published var templates: [String] { didSet { persist() } }
    @Published var images: [Data?] { didSet { persist() } }
    @Published var draft = ""
    @Published var slot = -1
    @Published private(set) var message = ""
    @Published private(set) var image: NSImage?
    @Published private(set) var pinned = false
    @Published private(set) var flashing = false
    private var flashTask: Task<Void, Never>?
    private(set) var remoteImage: String?
    @Published private(set) var sentAt = Date.distantPast
    @Published private(set) var deadline: Date?
    private var pausedRemaining = 20.0
    private var expiry: Task<Void, Never>?
    private var panel: NSWindow?
    private var globalDraft = ""
    init() {
        let defaults = UserDefaults.standard
        appearance = defaults.data(forKey: "jaras.notices.appearance").flatMap { try? JSONDecoder().decode(TPNoticeAppearance.self, from: $0) } ?? TPNoticeAppearance()
        let stored = defaults.stringArray(forKey: "jaras.notices.templates") ?? []
        templates = (0..<3).map { stored.indices.contains($0) ? stored[$0] : "" }
        images = (0..<3).map { defaults.data(forKey: "jaras.notices.image.\($0)") }
    }
    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: "jaras.notices.appearance") }
        defaults.set(templates, forKey: "jaras.notices.templates")
        for i in 0..<3 { defaults.set(images[i], forKey: "jaras.notices.image.\(i)") }
    }
    var active: Bool { !message.isEmpty || image != nil }
    func remaining(at date: Date = Date()) -> Double { pinned ? pausedRemaining : max(0, deadline?.timeIntervalSince(date) ?? 0) }
    func select(_ index: Int) {
        if slot == -1 { globalDraft = draft }
        slot = index; draft = index == -1 ? globalDraft : templates[index]
    }
    func send() {
        let value = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let selectedImage = slot >= 0 ? images[slot].flatMap(NSImage.init(data:)) : nil
        guard !value.isEmpty || selectedImage != nil else { return }
        message = value; image = selectedImage; sentAt = Date(); pausedRemaining = 20
        remoteImage = slot >= 0 ? images[slot].map { "data:image/jpeg;base64," + $0.base64EncodedString() } : nil
        flashing = true; flashTask?.cancel()
        flashTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_050_000_000) } catch { return }
            self?.flashing = false
        }
        schedule(seconds: 20)
    }
    private func schedule(seconds: Double) {
        expiry?.cancel(); deadline = pinned ? nil : Date().addingTimeInterval(seconds)
        guard !pinned else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
            self?.clear()
        }
    }
    func togglePin() {
        let seconds = active ? remaining() : 20
        pinned.toggle(); pausedRemaining = seconds
        if active { schedule(seconds: seconds) }
    }
    func clear() { expiry?.cancel(); expiry = nil; flashTask?.cancel(); flashing = false; message = ""; image = nil; remoteImage = nil; deadline = nil; pinned = false }
    func chooseImage() {
        guard slot >= 0 else { return }
        let imageSlot = slot
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]; picker.allowsMultipleSelection = false
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url, let source = NSImage(contentsOf: url), let self else { return }
            let ratio = min(1, 1920 / max(source.size.width, source.size.height))
            let resized = NSImage(size: NSSize(width: source.size.width * ratio, height: source.size.height * ratio))
            resized.lockFocus(); source.draw(in: NSRect(origin: .zero, size: resized.size)); resized.unlockFocus()
            if let data = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                self.images[imageSlot] = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }
        }
    }
    func open() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 520,height: 430),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        window.title = JarasLocalization.string("Messages"); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420,height: 360)
        window.contentView = NSHostingView(rootView: TPNoticeEditor(model: self))
        window.center(); window.makeKeyAndOrderFront(nil); panel = window
    }
}
struct TPNoticeButton: View {
    var body: some View {
        Button { TPNoticeController.shared.open() } label: {
            HStack(spacing: 3) {
                Image(systemName: "text.bubble")
                Text("Messages")
            }
        }
            .buttonStyle(TransportButtonStyle(color: JarasTheme.yellow, active: false, fontSize: TransportControlMetrics.font, width: TransportControlMetrics.width, height: TransportControlMetrics.height))
    }
}
private struct TPNoticeEditor: View {
    @AppStorage("jaras.language") private var language = "en"
    @ObservedObject var model: TPNoticeController
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Send") { model.send() }.keyboardShortcut(.return, modifiers: .command)
                Button("Withdraw message") { model.clear() }.disabled(!model.active)
                Toggle("Pin", isOn: Binding(get: { model.pinned },set: { _ in model.togglePin() })).toggleStyle(.button)
                Spacer()
                TimelineView(.animation(minimumInterval: 0.25, paused: !model.active || model.pinned)) { context in Text("\(Int(ceil(model.remaining(at: context.date))))s").monospacedDigit() }
            }
            Picker("Message", selection: Binding(get: { model.slot },set: { model.select($0) })) {
                Text("Global").tag(-1)
                ForEach(0..<3) { index in Text("Message \(index + 1)").tag(index) }
            }.pickerStyle(.segmented)
            TextEditor(text: $model.draft).font(.system(size: 18)).onChange(of: model.draft) { value in
                if value.count > 500 { model.draft = String(value.prefix(500)) }
            }
            HStack {
                Text("\(model.draft.count) / 500").foregroundStyle(.secondary)
                Spacer()
                if model.slot >= 0 {
                    Button("Save") { model.templates[model.slot] = model.draft }
                    Button("Add image") { model.chooseImage() }
                    if model.images[model.slot] != nil { Button("Remove image") { model.images[model.slot] = nil } }
                }
            }
        }.padding(16).background(JarasTheme.panel).foregroundStyle(JarasTheme.text).environment(\.locale, Locale(identifier: language))
    }
}
struct TPNoticeSettingsView: View {
    @ObservedObject private var model = TPNoticeController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show on TP-1", isOn: $model.appearance.window1)
            Toggle("Show on TP-2", isOn: $model.appearance.window2)
            Picker("Font", selection: $model.appearance.font) {
                ForEach(["Arial","Verdana","Georgia","Menlo","Impact"], id: \.self) { Text($0).tag($0) }
            }
            Text("Text scale: \(Int(model.appearance.scale))%")
            Slider(value: $model.appearance.scale, in: 50...100)
            color("Text color", path: \.text); color("Background color", path: \.background); color("Flash color", path: \.flash)
            Toggle("Show emoji", isOn: $model.appearance.emojiEnabled)
            TextField("Emoji", text: $model.appearance.emoji).onChange(of: model.appearance.emoji) { value in
                if value.count > 8 { model.appearance.emoji = String(value.prefix(8)) }
            }
            Toggle("Hide content while showing a message", isOn: $model.appearance.cleanDisplay)
        }.padding(16)
    }
    private func color(_ label: String, path: WritableKeyPath<TPNoticeAppearance, UInt32>) -> some View {
        ColorPicker(LocalizedStringKey(label), selection: Binding(get: { Color(hex: model.appearance[keyPath: path]) }, set: { value in
            if let rgb = NSColor(value).usingColorSpace(.deviceRGB) { model.appearance[keyPath: path] = UInt32((rgb.redComponent * 255).rounded()) << 16 | UInt32((rgb.greenComponent * 255).rounded()) << 8 | UInt32((rgb.blueComponent * 255).rounded()) }
        }), supportsOpacity: false)
    }
}
private struct TPNoticeOverlay: View {
    @ObservedObject private var model = TPNoticeController.shared
    let index: Int
    var body: some View {
        if model.active && (index == 1 ? model.appearance.window1 : model.appearance.window2) {
            TimelineView(.animation(minimumInterval: 0.175, paused: !model.flashing)) { context in
                GeometryReader { geometry in
                    let appearance = model.appearance
                    let elapsed = context.date.timeIntervalSince(model.sentAt)
                    let flash = model.flashing && elapsed < 1.05 && Int(max(0, elapsed) / 0.175) % 2 == 0
                    VStack {
                        if let image = model.image { Image(nsImage: image).resizable().scaledToFit() }
                        else {
                            let text = model.message.uppercased()
                            Text(appearance.emojiEnabled ? "\(appearance.emoji) \(text) \(appearance.emoji)" : text)
                                .font(.custom(appearance.font,size: min(72,max(24,geometry.size.width * 0.078)) * appearance.scale / 100))
                                .foregroundStyle(Color(hex: appearance.text)).multilineTextAlignment(.center).minimumScaleFactor(0.3)
                        }
                    }.padding(24).frame(maxWidth: .infinity,maxHeight: appearance.cleanDisplay ? .infinity : nil)
                        .background(Color(hex: flash ? appearance.flash : appearance.background))
                        .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .top)
                }
            }.allowsHitTesting(false)
        }
    }
}
#endif
