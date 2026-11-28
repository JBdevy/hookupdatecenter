import SwiftUI
import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias ProjectionImage = NSImage
#else
import UIKit
typealias ProjectionImage = UIImage

enum IpadVideoPlacement: Equatable {
    case hidden, docked, floating, window
}
#endif

/// AVPlayer owns decoding and presentation. The UI only publishes transport
/// changes; normal playback never seeks or copies decoded frames on each tick.
@MainActor final class VideoPlayback: NSObject, ObservableObject {
    static let shared = VideoPlayback()
    static let teleprompter = VideoPlayback(preferences: .standard, trackKind: .teleprompt)
    static let teleprompter2 = VideoPlayback(preferences: .standard, trackKind: .teleprompt2)
    @Published private(set) var visible = false
    @Published private(set) var message = ""
    @Published private(set) var stretch: Bool
    @Published private(set) var image: ProjectionImage?
    @Published private(set) var opacity = 1.0
    @Published private(set) var player = AVPlayer()
    private var activeURL: URL?
    private var activeSourceOrigin = 0.0
    private var activeSourceRate = 1.0
    private var activeEnd = 0.0
    private var preparedPlayer: AVPlayer?
    private var preparedID: UUID?
    private var preparedURL: URL?
    private var preparation: Task<Void, Never>?
    private var mediaPreparation: Task<Void, Never>?
    private var initialSeek: (seconds: Double, rate: Float, sampledAt: Double)?
    private var itemReady = false
    private var colorPreparation: Task<Void, Never>?
    #if os(macOS)
    private var window: NSWindow?
    #else
    @Published private(set) var ipadPlacement: IpadVideoPlacement = .hidden
    private var windowRequest: UUID?
    private weak var windowSession: UISceneSession?
    private var windowDisconnect: AnyCancellable?
    #endif
    private var directory: URL?
    private var snapshot: ShowSnapshot?
    private var snapshotRevision: UInt64?
    private var mediaProjection: (project: UUID, song: UUID, revision: UInt64, media: Song)?
    private var clipID: UUID?
    private let trackKind: TrackKind
    private var stretchKey: String { trackKind == .teleprompt ? "jaras.teleprompter.video.stretch" : trackKind == .teleprompt2 ? "jaras.teleprompter2.video.stretch" : "jaras.video.stretch" }
    private var projectionEnabled = false
    private var active: Bool { visible || projectionEnabled }
    private var playbackRate: Float = 0
    private var lastSourcePosition: Double?
    private var lastPosition: Double?
    private var lastSectionJumpSerial: UInt64?
    private var lastHost = 0.0
    private var lastCorrection = 0.0
    private var generation = UUID()
    private var seeking = false
    private var pendingSeek: (Double,Float)?
    private var videoSettingsObservation: AnyCancellable?
    var usesVideoSettings: Bool { trackKind == .video }
    private var itemStatus: NSKeyValueObservation?
    private let preferences: UserDefaults
    override convenience init() { self.init(preferences: .standard) }
    init(preferences: UserDefaults, trackKind: TrackKind = .video) {
        self.preferences = preferences; self.trackKind = trackKind
        stretch = preferences.bool(forKey: trackKind == .teleprompt ? "jaras.teleprompter.video.stretch" : trackKind == .teleprompt2 ? "jaras.teleprompter2.video.stretch" : "jaras.video.stretch")
        super.init()
        player.isMuted = true; player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        if trackKind == .video, preferences === UserDefaults.standard {
            videoSettingsObservation = VideoMediaSettings.shared.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let settings = VideoMediaSettings.shared
                    self.stretch = settings.stretch
                    self.player.currentItem?.preferredMaximumResolution = settings.size
                    self.applyVideoColor()
                    if self.image != nil { self.image = nil; self.clipID = nil }
                }
            }
        }
    }
    func setStretch(_ enabled: Bool) {
        guard stretch != enabled else { return }
        stretch = enabled
        preferences.set(enabled, forKey: stretchKey)
        if trackKind == .video, preferences === UserDefaults.standard { VideoMediaSettings.shared.stretch = enabled }
    }
    /// Each surface has its own decoder and source track. Preview suspends only
    /// the teleprompter decoder, without changing the video window or transport.
    func setProjectionEnabled(_ enabled: Bool) {
        guard projectionEnabled != enabled else { return }
        projectionEnabled = enabled
        if !active { reset() }
        else if let snapshot { update(snapshot, revision: snapshotRevision) }
    }
    func open(directory: URL) {
        reset(); self.directory = directory; snapshot = nil; mediaProjection = nil
    }
    func closeProject() {
        #if os(macOS)
        window?.close()
        #else
        if ipadPlacement != .hidden { ipadPlacement = .hidden }
        endVideoWindow()
        #endif
        visible = false; projectionEnabled = false
        reset(); directory = nil; snapshot = nil; mediaProjection = nil; message = ""
    }
    #if os(macOS)
    func toggle() {
        if visible { window?.close(); return }
        let window = ProjectionWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 450), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.closesOnRightDoubleClick = true
        window.title = "CatLive Video"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320,height: 180)
        window.followApplicationWindowOrder(); window.delegate = self
        let host = NSHostingView(rootView: VideoSurface(controller: self))
        if #available(macOS 13, *) { host.sizingOptions = [] }
        window.contentView = host
        window.restorePlacement(key: "jaras.videoWindow")
        ProjectionWindow.presentWorkspaceWindow(window, activates: false)
        self.window = window; visible = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, let snapshot = self.snapshot else { return }
            self.update(snapshot, revision: self.snapshotRevision)
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, window === closed else { return }
        visible = false; window = nil
        DispatchQueue.main.async { [weak self] in
            closed.contentView = nil
            if let self, !self.active { self.reset() }
        }
    }
    #else
    func toggle() { setVisible(!visible) }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        ipadPlacement = value ? .docked : .hidden
        if !value { endVideoWindow() }
        if !active { reset() }
        else {
            Task { @MainActor [weak self] in
                guard let self, self.visible, let snapshot = self.snapshot else { return }
                self.update(snapshot, revision: self.snapshotRevision)
            }
        }
    }
    func detachVideo(openWindow: OpenWindowAction, supportsMultipleWindows: Bool) {
        guard ipadPlacement == .docked else { return }
        ipadPlacement = .floating
        openDetachedWindow(openWindow, supportsMultipleWindows: supportsMultipleWindows)
    }
    func openDetachedWindow(_ openWindow: OpenWindowAction, supportsMultipleWindows: Bool) {
        // Opening a second scene can cover the entire grid in Full Screen
        // Apps. The panel stays inside the workspace until a distinct desktop
        // exists and iPadOS can move its window there.
        guard ipadPlacement == .floating, windowRequest == nil, supportsMultipleWindows,
              UIApplication.shared.supportsMultipleScenes,
              UIScreen.screens.dropFirst().contains(where: { $0.mirrored == nil }) else { return }
        let request = UUID()
        windowRequest = request
        openWindow(id: IpadVideoDetachedWindow.sceneID, value: request)
    }
    func dockVideo() {
        guard visible else { return }
        ipadPlacement = .docked
        endVideoWindow()
    }
    func attachVideoWindow(_ scene: UIWindowScene, request: UUID?) -> Bool {
        guard visible, ipadPlacement == .floating, let request, request == windowRequest else { return false }
        windowRequest = nil
        let session = scene.session
        windowSession = session
        windowDisconnect = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification, object: scene)
            .sink { [weak self, weak session] _ in
                Task { @MainActor in
                    guard let self, let session, self.windowSession === session else { return }
                    self.windowDisconnect = nil
                    self.windowSession = nil
                    if self.visible { self.ipadPlacement = .docked }
                }
            }
        ipadPlacement = .window
        return true
    }
    private func endVideoWindow() {
        windowRequest = nil
        windowDisconnect = nil
        guard let session = windowSession else { return }
        windowSession = nil
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
    #endif
    private func clearPreparation() {
        preparation?.cancel(); preparation = nil
        preparedPlayer?.pause(); preparedPlayer = nil; preparedID = nil; preparedURL = nil
    }
    private func prepareNextVideo(song: Song, clip: AudioClip, position: Double, playing: Bool, directory: URL) {
        let boundary = clip.startTime + clip.duration
        guard playing, boundary - position <= 5,
              let next = song.firstProjectionItem(at: boundary, trackKind: trackKind == .video ? nil : trackKind),
              next.id != clip.id, let file = next.audioFile else { return }
        let url = directory.projectMedia(file.path)
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) != true else { return }
        guard preparedID != next.id || preparedURL != url else { return }
        clearPreparation(); preparedID = next.id; preparedURL = url
        var source = next.sourceOffset + (boundary - next.startTime) * next.audioRate
        if let length = next.loopLength, length > 0 {
            let start = next.loopStart ?? next.sourceOffset
            source = start + (source - start).truncatingRemainder(dividingBy: length)
        }
        let settings = trackKind == .video ? VideoMediaSettings.shared : nil
        let limit = settings?.size, grayscale = settings?.blackAndWhite ?? false
        let target = CMTime(seconds: max(0, source), preferredTimescale: 60000)
        let rate = Float(next.audioRate)
        preparation = Task.detached(priority: .utility) { [weak self] in
            guard let candidate = try? await Self.makePlayer(url, limit: limit, grayscale: grayscale),
                  let item = candidate.currentItem else { return }
            for _ in 0..<250 {
                guard !Task.isCancelled else { return }
                if item.status != .unknown { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled, item.status == .readyToPlay else { return }
            let sought = await candidate.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard sought, !Task.isCancelled, await candidate.preroll(atRate: rate), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self, self.preparedID == next.id, self.preparedURL == url else { return }
                self.preparedPlayer = candidate
            }
        }
    }
    private func reset(preserveDisplayedFrame: Bool = false) {
        clearPreparation()
        mediaPreparation?.cancel(); mediaPreparation = nil; initialSeek = nil; itemReady = false
        colorPreparation?.cancel(); colorPreparation = nil
        activeURL = nil
        generation = UUID(); pendingSeek = nil; seeking = false
        player.pause()
        if !preserveDisplayedFrame { player.replaceCurrentItem(with: nil) }
        itemStatus = nil; clipID = nil; playbackRate = 0; lastPosition = nil; lastSourcePosition = nil
        lastSectionJumpSerial = nil
        if !message.isEmpty { message = "" }
        if image != nil { image = nil }
    }
    private func install(_ candidate: AVPlayer, generation requestedGeneration: UUID) {
        guard generation == requestedGeneration, active, let item = candidate.currentItem else { return }
        player = candidate
        itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == requestedGeneration, self.active else { return }
                switch item.status {
                case .readyToPlay:
                    self.itemReady = true
                    if let target = self.initialSeek {
                        self.initialSeek = nil
                        let now = ProcessInfo.processInfo.systemUptime
                        self.lastCorrection = now
                        self.seek(target.seconds + (now - target.sampledAt) * Double(target.rate), rate: target.rate)
                    }
                case .failed:
                    self.initialSeek = nil
                    self.message = item.error?.localizedDescription ?? "Could not open video"
                default: break
                }
            }
        }
    }
    private func openMovie(_ url: URL, prepared: AVPlayer?) {
        let requestedGeneration = generation
        if let prepared {
            install(prepared, generation: requestedGeneration)
            return
        }
        let settings = trackKind == .video ? VideoMediaSettings.shared : nil
        let limit = settings?.size
        let grayscale = settings?.blackAndWhite ?? false
        let usesSettings = settings != nil
        mediaPreparation = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let candidate = try await Self.makePlayer(url, limit: limit, grayscale: grayscale)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == requestedGeneration else { return }
                    self.mediaPreparation = nil
                    self.install(candidate, generation: requestedGeneration)
                    let settings = VideoMediaSettings.shared
                    if usesSettings && (settings.size != limit || settings.blackAndWhite != grayscale) {
                        candidate.currentItem?.preferredMaximumResolution = settings.size
                        self.applyVideoColor()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == requestedGeneration else { return }
                    self.mediaPreparation = nil
                    self.initialSeek = nil
                    self.message = error.localizedDescription
                }
            }
        }
    }
    nonisolated private static func makePlayer(_ url: URL, limit: CGSize?, grayscale: Bool) async throws -> AVPlayer {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
        let composition: AVVideoComposition?
        if let limit { composition = try await makeVideoComposition(asset: asset, limit: limit, grayscale: grayscale) }
        else { composition = nil }
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        if let limit {
            item.preferredMaximumResolution = limit
            item.videoComposition = composition
        }
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }
    func update(_ snapshot: ShowSnapshot, revision: UInt64? = nil) {
        self.snapshot = snapshot
        snapshotRevision = revision
        guard active, let directory else { return }
        guard let originalSong = snapshot.project.songs.first(where: { $0.id == snapshot.transport.songId }) else { reset(); return }
        let media: Song
        if let revision, let cached = mediaProjection, cached.project == snapshot.project.id,
           cached.song == originalSong.id, cached.revision == revision {
            media = cached.media
        } else {
            var projection = originalSong
            projection.tracks = originalSong.tracks.compactMap { source in
                guard trackKind == .video ? !source.kind.isTeleprompter : trackKind == source.kind else { return nil }
                let clips = source.clips.filter(\.isProjectionMedia)
                guard !clips.isEmpty else { return nil }
                var track = source
                track.clips = clips
                return track
            }
            media = projection
            mediaProjection = revision.map { (snapshot.project.id, originalSong.id, $0, projection) }
        }
        let song = snapshot.transport.multiLoop?.projectionSong(media) ?? media
        let transport = snapshot.transport
        let position = transport.playing || transport.paused == true ? transport.position : transport.editPosition ?? transport.position
        guard let clip = song.firstProjectionItem(at: position, trackKind: trackKind == .video ? nil : trackKind), let file = clip.audioFile else {
            if clipID != nil { reset() }
            if !message.isEmpty { message = "" }
            return
        }
        let fade = clip.fadeGain(at: position)
        if opacity != fade { opacity = fade }
        let url = directory.projectMedia(file.path)
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            if clipID != clip.id {
                reset(); clipID = clip.id; message = ""
                let requestedGeneration = generation
                let thumbnailLimit = Int(trackKind == .video ? max(VideoMediaSettings.shared.size.width, VideoMediaSettings.shared.size.height) : 4096)
                Task { [weak self] in
                    let decoded = await Task.detached(priority: .utility) {
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: thumbnailLimit] as CFDictionary)
                    }.value
                    guard let self, self.generation == requestedGeneration, self.active else { return }
                    if let decoded {
                        #if os(macOS)
                        self.image = NSImage(cgImage: decoded, size: .zero)
                        #else
                        self.image = UIImage(cgImage: decoded)
                        #endif
                    }
                }
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var source = clip.sourceOffset + (position - clip.startTime) * clip.audioRate
        if let length = clip.loopLength, length > 0 {
            let start = clip.loopStart ?? clip.sourceOffset
            source = start + (source - start).truncatingRemainder(dividingBy: length)
        }
        let rate = transport.playing ? Float(clip.audioRate) : 0
        let changedClip = clipID != clip.id
        var usedPreparedPlayer = false
        let continuousCut = changedClip && transport.playing && activeURL == url &&
            position >= activeEnd && position - activeEnd < 0.15 &&
            abs(clip.audioRate - activeSourceRate) < 0.000001 && clip.loopLength == nil &&
            abs(clip.sourceOffset - clip.startTime * clip.audioRate - activeSourceOrigin) < 0.000001
        if continuousCut { clipID = clip.id }
        if changedClip && !continuousCut {
            let prepared = preparedID == clip.id && preparedURL == url ? preparedPlayer : nil
            preparedPlayer = nil
            reset(preserveDisplayedFrame: true); clipID = clip.id
            openMovie(url, prepared: prepared)
            usedPreparedPlayer = prepared != nil
            itemReady = usedPreparedPlayer
        }
        activeURL = url; activeSourceOrigin = clip.sourceOffset - clip.startTime * clip.audioRate
        activeSourceRate = clip.audioRate; activeEnd = clip.startTime + clip.duration
        // Explicit jumps and loop wraps cannot use the drift tolerance: a
        // short jump is intentional even when it is less than 120 ms.
        let sectionJumped = lastSectionJumpSerial != transport.sectionJumpSerial
        let sourceJumped = lastSourcePosition.map { source < $0 - 0.001 || abs(source - $0 - (playbackRate != 0 ? (now - lastHost) * Double(playbackRate) : 0)) > 0.12 } ?? true
        let jumped = lastPosition.map { position < $0 - 0.001 || abs(position - $0 - (playbackRate != 0 ? now-lastHost : 0)) > 0.12 } ?? true
        let canCheckDrift = itemReady && rate != 0 && !seeking && now - lastCorrection > 1.8
        let playerTime = canCheckDrift ? player.currentTime().seconds : .nan
        let drifted = playerTime.isFinite && abs(playerTime - source) > 0.15
        if usedPreparedPlayer && rate != 0 {
            lastCorrection = now
            player.setRate(rate, time: CMTime(seconds: max(0, source), preferredTimescale: 60000),
                           atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        } else if !itemReady {
            initialSeek = (source, rate, now)
        } else if sectionJumped || jumped || sourceJumped || drifted || rate != playbackRate || (rate == 0 && lastPosition != position) {
            lastCorrection = now; seek(source, rate: rate)
        }
        playbackRate = rate; lastPosition = position; lastSourcePosition = source; lastHost = now
        lastSectionJumpSerial = transport.sectionJumpSerial
        prepareNextVideo(song: song, clip: clip, position: position, playing: transport.playing, directory: directory)
    }
    private func applyVideoColor() {
        guard trackKind == .video, let item = player.currentItem else { return }
        colorPreparation?.cancel()
        let settings = VideoMediaSettings.shared
        let limit = settings.size, grayscale = settings.blackAndWhite
        colorPreparation = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let composition = try await Self.makeVideoComposition(asset: item.asset, limit: limit, grayscale: grayscale)
                guard !Task.isCancelled, self?.player.currentItem === item else { return }
                item.videoComposition = composition
            } catch { }
        }
    }
    nonisolated private static func makeVideoComposition(asset: AVAsset, limit: CGSize, grayscale: Bool) async throws -> AVVideoComposition? {
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        async let natural = source.load(.naturalSize)
        async let transform = source.load(.preferredTransform)
        let rotated = try await natural.applying(transform)
        let width = max(1, abs(rotated.width)), height = max(1, abs(rotated.height))
        let renderScale = min(1, limit.width / width, limit.height / height)
        guard grayscale || renderScale < 0.999 else { return nil }
        try Task.checkCancellation()
        let composition: AVMutableVideoComposition
        if grayscale {
            composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                if let filter = CIFilter(name: "CIColorControls") {
                    filter.setValue(request.sourceImage.clampedToExtent(), forKey: kCIInputImageKey)
                    filter.setValue(0, forKey: kCIInputSaturationKey)
                    if let output = filter.outputImage {
                        request.finish(with: output.cropped(to: request.sourceImage.extent), context: nil)
                        return
                    }
                }
                request.finish(with: request.sourceImage, context: nil)
            })
        } else {
            composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        }
        composition.renderScale = Float(renderScale)
        return composition
    }
    private func seek(_ seconds: Double, rate: Float) {
        if seeking { pendingSeek = (seconds,rate); return }
        seeking = true; let generation = generation
        let requestedAt = ProcessInfo.processInfo.systemUptime
        player.pause()
        let target = CMTime(seconds: max(0,seconds), preferredTimescale: 60000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.seeking = false
                if let next = self.pendingSeek { self.pendingSeek = nil; self.seek(next.0,rate: next.1); return }
                if finished && self.active {
                    let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
                    if rate == 0 { self.player.pause() }
                    else if self.player.status == .readyToPlay {
                        self.player.setRate(rate, time: CMTime(seconds: max(0, seconds + elapsed * Double(rate)), preferredTimescale: 60000), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
                    } else { self.player.rate = rate }
                }
            }
        }
    }
}
#if os(macOS)
extension VideoPlayback: NSWindowDelegate {}
#endif
struct VideoSurface: View {
    @ObservedObject var controller: VideoPlayback
    var body: some View {
        ZStack { Color.black; ProjectionMediaSurface(controller: controller)
            if !controller.message.isEmpty { Text(LocalizedStringKey(controller.message)).foregroundStyle(.white).padding(20) }
        }.ignoresSafeArea()
    }
}
struct ProjectionMediaSurface: View {
    @ObservedObject private var settings = VideoMediaSettings.shared
    @ObservedObject var controller: VideoPlayback
    var body: some View {
        GeometryReader { geometry in
            if let image = controller.image {
                if controller.stretch {
                    projectionImage(image).resizable().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    projectionImage(image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                NativeVideoLayer(player: controller.player, stretch: controller.stretch)
            }
        }.opacity(controller.opacity).saturation(controller.usesVideoSettings && settings.blackAndWhite ? 0 : 1).allowsHitTesting(false)
    }
    private func projectionImage(_ image: ProjectionImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}
#if os(macOS)
private struct NativeVideoLayer: NSViewRepresentable {
    let player: AVPlayer
    let stretch: Bool
    func makeNSView(context: Context) -> VideoLayerView { VideoLayerView(player: player, stretch: stretch) }
    func updateNSView(_ view: VideoLayerView, context: Context) { view.setPlayer(player); view.setStretch(stretch) }
    static func dismantleNSView(_ view: VideoLayerView, coordinator: ()) { view.clear() }
}
typealias ProjectionPlatformView = NSView
#else
private struct NativeVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    let stretch: Bool
    func makeUIView(context: Context) -> VideoLayerView { VideoLayerView(player: player, stretch: stretch) }
    func updateUIView(_ view: VideoLayerView, context: Context) { view.setPlayer(player); view.setStretch(stretch) }
    static func dismantleUIView(_ view: VideoLayerView, coordinator: ()) { view.clear() }
}
typealias ProjectionPlatformView = UIView
#endif
#if os(iOS)
struct IpadNativeVideoButton: View {
    var showsTitle = true
    var height: CGFloat = 32
    private let video = VideoPlayback.shared
    @State private var visible = false
    @State private var stretch = false
    var body: some View {
        Button { video.toggle() } label: {
            HStack(spacing: 3) {
                ControlIcon(name: "video", active: visible, size: 16)
                if showsTitle {
                    Text("Video").font(.jarasSystem(size: TimelineEditingBarMetrics.labelSize, weight: .semibold))
                }
            }.lineLimit(1)
                .frame(width: showsTitle ? 62 : 34, height: height).foregroundStyle(JarasTheme.toolbarTint(active: visible))
                .background { RemoteSurface.panel.clipShape(RoundedRectangle(cornerRadius: 5)) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Video")
            .accessibilityValue(visible ? "On" : "Off")
            .contextMenu { Toggle("Stretch", isOn: Binding(get: { stretch }, set: { video.setStretch($0) })) }
            .onReceive(video.$visible.removeDuplicates()) { visible = $0 }
            .onReceive(video.$stretch.removeDuplicates()) { stretch = $0 }
    }
}

struct IpadVideoDockBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct IpadNativeVideoPanel: View {
    let placement: IpadVideoPlacement
    var dockAnchor: Anchor<CGRect>? = nil
    var fullscreen: Binding<Bool>? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    private let video = VideoPlayback.shared
    @State private var origin: CGPoint?
    @GestureState private var drag = CGSize.zero
    private var floating: Bool { placement == .floating && fullscreen?.wrappedValue != true }

    var body: some View {
        GeometryReader { geometry in
            // Preserve the same AVPlayerLayer when the panel moves inside the
            // workspace. The dock slot provides geometry without owning the player.
            let docked = placement == .docked && fullscreen?.wrappedValue != true
            let dock = dockAnchor.map { geometry[$0] } ?? .zero
            let width = docked ? dock.width : floating
                ? min(480, max(240, geometry.size.width * 0.55), geometry.size.width) : geometry.size.width
            let height = docked ? dock.height : floating
                ? min(geometry.size.height, width * 9 / 16 + 36) : geometry.size.height
            let maxX = max(0, geometry.size.width - width), maxY = max(0, geometry.size.height - height)
            let initial = origin ?? CGPoint(x: max(0, maxX - 12), y: max(0, maxY - 12))
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "video")
                        Text("Video").lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Button {
                        fullscreen?.wrappedValue = false
                        if placement == .docked { video.detachVideo(openWindow: openWindow, supportsMultipleWindows: supportsMultipleWindows) }
                        else { video.dockVideo() }
                    } label: {
                        Image(systemName: placement == .docked ? "arrow.up.right.square" : "pin.fill")
                            .frame(width: 36, height: 36)
                    }.accessibilityLabel(LocalizedStringKey(placement == .docked ? "Detach video" : "Dock video"))
                    if let fullscreen {
                        Button { fullscreen.wrappedValue.toggle() } label: {
                            Image(systemName: fullscreen.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .frame(width: 36, height: 36)
                        }.accessibilityLabel(fullscreen.wrappedValue ? "Sair da tela cheia" : "Tela cheia")
                    }
                    Button { video.setVisible(false) } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                        .accessibilityLabel("Fechar vídeo")
                }.padding(.leading, 12).font(.system(size: 13, weight: .semibold))
                    .frame(height: 36).background(JarasTheme.panel).foregroundStyle(Color.white).buttonStyle(.plain)
                VideoSurface(controller: video).clipped().contentShape(Rectangle())
                    .gesture(TapGesture(count: 2).onEnded { fullscreen?.wrappedValue.toggle() },
                             including: fullscreen == nil ? .none : .gesture)
            }.frame(width: width, height: height)
                .background { Color.black.onTapGesture {} }
                .clipShape(RoundedRectangle(cornerRadius: floating ? 8 : 0))
                .background {
                    if floating {
                        RoundedRectangle(cornerRadius: 8).fill(.black).shadow(radius: 10).allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global).updating($drag) { value, current, _ in
                    current = value.translation
                }.onEnded { value in
                    origin = CGPoint(x: min(maxX, max(0, initial.x + value.translation.width)),
                                     y: min(maxY, max(0, initial.y + value.translation.height)))
                }, including: floating ? .all : .subviews)
                .allowsHitTesting(width > 0 && height > 0)
                .offset(x: docked ? dock.minX : floating ? min(maxX, max(0, initial.x + drag.width)) : 0,
                        y: docked ? dock.minY : floating ? min(maxY, max(0, initial.y + drag.height)) : 0)
        }.clipped()
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.didConnectNotification)) { _ in
                guard floating else { return }
                video.openDetachedWindow(openWindow, supportsMultipleWindows: supportsMultipleWindows)
            }
    }
}

/// A separate SwiftUI scene retains the same player as the dock and lets
/// iPadOS move its window between the device and an extended desktop.
struct IpadVideoDetachedWindow: View {
    static let sceneID = "catlive-video"
    let request: UUID?
    private let video = VideoPlayback.shared
    @State private var session: UISceneSession?

    var body: some View {
        ZStack {
            if session != nil { IpadNativeVideoPanel(placement: .window) }
            else { Color.black }
        }
        .frame(minWidth: 280, idealWidth: 480, minHeight: 196, idealHeight: 306)
        .preferredColorScheme(.dark)
        .background(WindowConnection(connect: connect))
    }
    private func connect(_ window: UIWindow) {
        guard let scene = window.windowScene, session !== scene.session else { return }
        guard video.attachVideoWindow(scene, request: request) else {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
            return
        }
        if #available(iOS 17, *), let content = window.rootViewController?.view {
            content.addInteraction(UIWindowSceneDragInteraction())
        }
        session = scene.session
    }

    private struct WindowConnection: UIViewRepresentable {
        let connect: (UIWindow) -> Void
        func makeUIView(context: Context) -> Probe {
            let view = Probe()
            view.isUserInteractionEnabled = false
            view.connect = connect
            return view
        }
        func updateUIView(_ view: Probe, context: Context) { view.connect = connect }
        final class Probe: UIView {
            var connect: ((UIWindow) -> Void)?
            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard let window else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.connect?(window)
                }
            }
        }
    }
}
#endif

/// A ready AVPlayerItem is not necessarily a drawable AVPlayerLayer yet.
/// Keep the outgoing layer visible until the incoming layer has a real frame.
final class VideoLayerView: ProjectionPlatformView {
    private var projectionLayer: CALayer? { layer }
    private(set) var video = AVPlayerLayer()
    private var incoming: AVPlayerLayer?
    private var readiness: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private weak var requestedPlayer: AVPlayer?
    init(player: AVPlayer, stretch: Bool) {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        backgroundColor = .black
        #endif
        video.videoGravity = stretch ? .resize : .resizeAspect
        projectionLayer?.addSublayer(video)
        setPlayer(player)
    }
    func clear() {
        readiness = nil; itemObservation = nil; requestedPlayer = nil
        incoming?.player = nil; incoming?.removeFromSuperlayer(); incoming = nil
        video.player = nil
    }
    func setPlayer(_ player: AVPlayer) {
        guard requestedPlayer !== player else { return }
        readiness = nil; itemObservation = nil
        incoming?.player = nil; incoming?.removeFromSuperlayer(); incoming = nil
        requestedPlayer = player
        guard player.currentItem != nil else { video.player = player; return }
        let next = AVPlayerLayer(player: player)
        next.frame = bounds; next.videoGravity = video.videoGravity
        incoming = next
        // Decode behind the previous frame, without hiding the incoming layer.
        projectionLayer?.insertSublayer(next, below: video)
        readiness = next.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak next] _, _ in
            DispatchQueue.main.async {
                guard let self, let next, self.incoming === next, next.isReadyForDisplay else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                let previous = self.video
                self.video = next; self.incoming = nil; self.readiness = nil
                previous.removeFromSuperlayer(); previous.player = nil
                CATransaction.commit()
            }
        }
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self, weak player] _, _ in
            DispatchQueue.main.async {
                guard let self, let player, self.requestedPlayer === player, player.currentItem == nil else { return }
                self.clear()
            }
        }
    }
    func setStretch(_ enabled: Bool) {
        let gravity: AVLayerVideoGravity = enabled ? .resize : .resizeAspect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.videoGravity = gravity; incoming?.videoGravity = gravity
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func layoutVideo() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = bounds; incoming?.frame = bounds; CATransaction.commit()
    }
    #if os(macOS)
    override func layout() { super.layout(); layoutVideo() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); layoutVideo() }
    #endif
}
