import SwiftUI
import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit

/// AVPlayer owns decoding and presentation. The UI only publishes transport
/// changes; normal playback never seeks or copies decoded frames on each tick.
@MainActor final class VideoPlayback: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = VideoPlayback()
    static let teleprompter = VideoPlayback(preferences: .standard, trackKind: .teleprompt)
    static let teleprompter2 = VideoPlayback(preferences: .standard, trackKind: .teleprompt2)
    @Published private(set) var visible = false
    @Published private(set) var message = ""
    @Published private(set) var stretch: Bool
    @Published private(set) var image: NSImage?
    @Published private(set) var opacity = 1.0
    let player = AVPlayer()
    private var window: NSWindow?
    private var directory: URL?
    private var snapshot: ShowSnapshot?
    private var clipID: UUID?
    private let trackKind: TrackKind
    private var stretchKey: String { trackKind == .teleprompt ? "jaras.teleprompter.video.stretch" : trackKind == .teleprompt2 ? "jaras.teleprompter2.video.stretch" : "jaras.video.stretch" }
    private var projectionEnabled = false
    private var active: Bool { visible || projectionEnabled }
    private var playbackRate: Float = 0
    private var lastSourcePosition: Double?
    private var lastPosition: Double?
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
        else if let snapshot { update(snapshot) }
    }
    func open(directory: URL) {
        reset(); self.directory = directory; snapshot = nil
    }
    func closeProject() {
        window?.close(); projectionEnabled = false
        reset(); directory = nil; snapshot = nil; message = ""
    }
    func toggle() {
        if visible { window?.close(); return }
        let window = ProjectionWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 450), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.closesOnRightDoubleClick = true
        window.title = "CatLive Video"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320,height: 180)
        window.level = .floating; window.hidesOnDeactivate = false; window.delegate = self
        window.contentView = NSHostingView(rootView: VideoSurface(controller: self))
        window.restorePlacement(key: "jaras.videoWindow"); window.makeKeyAndOrderFront(nil)
        self.window = window; visible = true
        if let snapshot { update(snapshot) }
    }
    func windowWillClose(_ notification: Notification) {
        visible = false
        if !active { reset() }
        window?.contentView = nil; window = nil
    }
    private func reset() {
        generation = UUID(); pendingSeek = nil; seeking = false
        player.pause(); player.replaceCurrentItem(with: nil)
        itemStatus = nil; clipID = nil; playbackRate = 0; lastPosition = nil; lastSourcePosition = nil
        if image != nil { image = nil }
    }
    func update(_ snapshot: ShowSnapshot) {
        self.snapshot = snapshot
        guard active, let directory else { return }
        guard let originalSong = snapshot.project.songs.first(where: { $0.id == snapshot.transport.songId }) else { reset(); return }
        let song = snapshot.transport.multiLoop?.projectionSong(originalSong) ?? originalSong
        let transport = snapshot.transport
        let position = transport.playing || transport.paused == true ? transport.position : transport.editPosition ?? transport.position
        guard let clip = song.firstProjectionItem(at: position, trackKind: trackKind == .video ? nil : trackKind), let file = clip.audioFile else {
            if clipID != nil { reset() }
            message = ""; return
        }
        func curve(_ amount: Double) -> Double { let value = min(1, max(0, amount)); return value * value * (3 - 2 * value) }
        let elapsed = position - (clip.fadeTimelineStart ?? clip.startTime)
        let duration = clip.fadeTimelineDuration ?? clip.duration
        let fade = ((clip.fadeIn ?? 0) > 0 ? curve(elapsed / clip.fadeIn!) : 1) *
                   ((clip.fadeOut ?? 0) > 0 ? curve((duration - elapsed) / clip.fadeOut!) : 1)
        if opacity != fade { opacity = fade }
        let url = directory.appendingPathComponent(file.path)
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
                    if let decoded { self.image = NSImage(cgImage: decoded, size: .zero) }
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
        if changedClip {
            reset(); clipID = clip.id
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            if trackKind == .video { item.preferredMaximumResolution = VideoMediaSettings.shared.size }
            itemStatus = item.observe(\.status, options: [.new]) { [weak self] item,_ in
                let error = item.error?.localizedDescription
                Task { @MainActor [weak self] in if let error { self?.message = error } }
            }
            player.replaceCurrentItem(with: item)
            applyVideoColor()
            message = ""
        }
        let sourceJumped = lastSourcePosition.map { abs(source - $0 - (playbackRate != 0 ? (now - lastHost) * Double(playbackRate) : 0)) > 0.12 } ?? true
        let jumped = lastPosition.map { abs(position - $0 - (playbackRate != 0 ? now-lastHost : 0)) > 0.12 } ?? true
        let playerTime = player.currentTime().seconds
        let drifted = rate != 0 && !seeking && now - lastCorrection > 1.8 && playerTime.isFinite && abs(playerTime - source) > 0.15
        if changedClip || jumped || sourceJumped || drifted || rate != playbackRate || (rate == 0 && lastPosition != position) {
            lastCorrection = now; seek(source, rate: rate)
        }
        playbackRate = rate; lastPosition = position; lastSourcePosition = source; lastHost = now
    }
    private func applyVideoColor() {
        guard trackKind == .video, let item = player.currentItem else { return }
        let settings = VideoMediaSettings.shared
        let source = item.asset.tracks(withMediaType: .video).first
        let natural = source?.naturalSize ?? .zero
        let transform = source?.preferredTransform ?? .identity
        let rotated = natural.applying(transform)
        let width = max(1, abs(rotated.width)), height = max(1, abs(rotated.height))
        let limit = settings.size
        let renderScale = min(1, limit.width / width, limit.height / height)
        guard settings.blackAndWhite || renderScale < 0.999 else { item.videoComposition = nil; return }
        let grayscale = settings.blackAndWhite
        let composition = AVVideoComposition(asset: item.asset, applyingCIFiltersWithHandler: { request in
            if grayscale {
                let filter = CIFilter(name: "CIColorControls")!
                filter.setValue(request.sourceImage.clampedToExtent(), forKey: kCIInputImageKey)
                filter.setValue(0, forKey: kCIInputSaturationKey)
                request.finish(with: filter.outputImage!.cropped(to: request.sourceImage.extent), context: nil)
            } else { request.finish(with: request.sourceImage, context: nil) }
        })
        if let scaled = composition.mutableCopy() as? AVMutableVideoComposition {
            scaled.renderScale = Float(renderScale)
            item.videoComposition = scaled
        } else { item.videoComposition = composition }
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
private struct VideoSurface: View {
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
                    Image(nsImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                NativeVideoLayer(player: controller.player, stretch: controller.stretch)
            }
        }.opacity(controller.opacity).saturation(controller.usesVideoSettings && settings.blackAndWhite ? 0 : 1).allowsHitTesting(false)
    }
}
private struct NativeVideoLayer: NSViewRepresentable {
    let player: AVPlayer
    let stretch: Bool
    func makeNSView(context: Context) -> VideoLayerView { VideoLayerView(player: player, stretch: stretch) }
    func updateNSView(_ view: VideoLayerView, context: Context) { view.setStretch(stretch) }
}
private final class VideoLayerView: NSView {
    let video = AVPlayerLayer()
    init(player: AVPlayer, stretch: Bool) {
        super.init(frame: .zero); wantsLayer = true
        video.player = player; video.videoGravity = stretch ? .resize : .resizeAspect
        layer?.addSublayer(video)
    }
    func setStretch(_ enabled: Bool) {
        let gravity: AVLayerVideoGravity = enabled ? .resize : .resizeAspect
        guard video.videoGravity != gravity else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.videoGravity = gravity
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = bounds; CATransaction.commit()
    }
}
#else
@MainActor final class VideoPlayback {
    static let shared = VideoPlayback()
    static let teleprompter = VideoPlayback()
    static let teleprompter2 = VideoPlayback()
    func open(directory: URL) {}
    func closeProject() {}
    func update(_ snapshot: ShowSnapshot) {}
}
#endif
