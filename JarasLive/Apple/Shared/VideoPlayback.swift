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
    #if os(macOS)
    private var window: NSWindow?
    #endif
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
        else if let snapshot { update(snapshot) }
    }
    func open(directory: URL) {
        reset(); self.directory = directory; snapshot = nil
    }
    func closeProject() {
        #if os(macOS)
        window?.close()
        #endif
        visible = false; projectionEnabled = false
        reset(); directory = nil; snapshot = nil; message = ""
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
        window.restorePlacement(key: "jaras.videoWindow"); window.makeKeyAndOrderFront(nil)
        self.window = window; visible = true
        if let snapshot { update(snapshot) }
    }
    func windowWillClose(_ notification: Notification) {
        visible = false
        if !active { reset() }
        window?.contentView = nil; window = nil
    }
    #else
    func toggle() { setVisible(!visible) }
    func setVisible(_ value: Bool) {
        visible = value
        if !active { reset() }
        else if let snapshot { update(snapshot) }
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
        let url = directory.appendingPathComponent(file.path)
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) != true else { return }
        guard preparedID != next.id || preparedURL != url else { return }
        clearPreparation(); preparedID = next.id; preparedURL = url
        var source = next.sourceOffset + (boundary - next.startTime) * next.audioRate
        if let length = next.loopLength, length > 0 {
            let start = next.loopStart ?? next.sourceOffset
            source = start + (source - start).truncatingRemainder(dividingBy: length)
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        if trackKind == .video { item.preferredMaximumResolution = VideoMediaSettings.shared.size }
        let candidate = AVPlayer(playerItem: item)
        candidate.isMuted = true; candidate.volume = 0
        candidate.automaticallyWaitsToMinimizeStalling = false
        preparation = Task { [weak self] in
            // Loading and seeking happen while the preceding clip still plays.
            for _ in 0..<250 {
                guard !Task.isCancelled else { return }
                if item.status != .unknown { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled, item.status == .readyToPlay else { return }
            self?.applyVideoColor(to: item)
            let sought = await candidate.seek(to: CMTime(seconds: max(0, source), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard sought, !Task.isCancelled else { return }
            let ready = await candidate.preroll(atRate: Float(next.audioRate))
            guard ready, !Task.isCancelled, let self, self.preparedID == next.id, self.preparedURL == url else { return }
            self.preparedPlayer = candidate
        }
    }
    private func reset(preserveDisplayedFrame: Bool = false) {
        clearPreparation()
        activeURL = nil
        generation = UUID(); pendingSeek = nil; seeking = false
        player.pause()
        if !preserveDisplayedFrame { player.replaceCurrentItem(with: nil) }
        itemStatus = nil; clipID = nil; playbackRate = 0; lastPosition = nil; lastSourcePosition = nil
        lastSectionJumpSerial = nil
        if !message.isEmpty { message = "" }
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
        let fade = clip.fadeGain(at: position)
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
            player = prepared ?? AVPlayer()
            player.isMuted = true; player.volume = 0
            player.automaticallyWaitsToMinimizeStalling = false
            usedPreparedPlayer = prepared != nil
            let item = prepared?.currentItem ?? AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            if trackKind == .video { item.preferredMaximumResolution = VideoMediaSettings.shared.size }
            let requestedGeneration = generation
            itemStatus = item.observe(\.status, options: [.new]) { [weak self] item,_ in
                let error = item.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == requestedGeneration else { return }
                    if let error { self.message = error }
                }
            }
            if prepared == nil { player.replaceCurrentItem(with: item); applyVideoColor() }
            message = ""
        }
        activeURL = url; activeSourceOrigin = clip.sourceOffset - clip.startTime * clip.audioRate
        activeSourceRate = clip.audioRate; activeEnd = clip.startTime + clip.duration
        // Explicit jumps and loop wraps cannot use the drift tolerance: a
        // short jump is intentional even when it is less than 120 ms.
        let sectionJumped = lastSectionJumpSerial != transport.sectionJumpSerial
        let sourceJumped = lastSourcePosition.map { source < $0 - 0.001 || abs(source - $0 - (playbackRate != 0 ? (now - lastHost) * Double(playbackRate) : 0)) > 0.12 } ?? true
        let jumped = lastPosition.map { position < $0 - 0.001 || abs(position - $0 - (playbackRate != 0 ? now-lastHost : 0)) > 0.12 } ?? true
        let playerTime = player.currentTime().seconds
        let drifted = rate != 0 && !seeking && now - lastCorrection > 1.8 && playerTime.isFinite && abs(playerTime - source) > 0.15
        if usedPreparedPlayer && rate != 0 {
            lastCorrection = now
            player.setRate(rate, time: CMTime(seconds: max(0, source), preferredTimescale: 60000), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        } else if (changedClip && !continuousCut) || sectionJumped || jumped || sourceJumped || drifted || rate != playbackRate || (rate == 0 && lastPosition != position) {
            lastCorrection = now; seek(source, rate: rate)
        }
        playbackRate = rate; lastPosition = position; lastSourcePosition = source; lastHost = now
        lastSectionJumpSerial = transport.sectionJumpSerial
        prepareNextVideo(song: song, clip: clip, position: position, playing: transport.playing, directory: directory)
    }
    private func applyVideoColor(to preparedItem: AVPlayerItem? = nil) {
        guard trackKind == .video, let item = preparedItem ?? player.currentItem else { return }
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
/// A ready AVPlayerItem is not necessarily a drawable AVPlayerLayer yet.
/// Keep the outgoing layer visible until the incoming layer has a real frame.
final class VideoLayerView: NSView {
    private(set) var video = AVPlayerLayer()
    private var incoming: AVPlayerLayer?
    private var readiness: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private weak var requestedPlayer: AVPlayer?
    init(player: AVPlayer, stretch: Bool) {
        super.init(frame: .zero); wantsLayer = true
        video.videoGravity = stretch ? .resize : .resizeAspect
        layer?.addSublayer(video)
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
        layer?.insertSublayer(next, below: video)
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
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = bounds; incoming?.frame = bounds; CATransaction.commit()
    }
}

#else
private struct NativeVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    let stretch: Bool
    func makeUIView(context: Context) -> VideoLayerView { VideoLayerView(player: player, stretch: stretch) }
    func updateUIView(_ view: VideoLayerView, context: Context) { if view.video.player !== player { view.video.player = player }; view.setStretch(stretch) }
    static func dismantleUIView(_ view: VideoLayerView, coordinator: ()) { view.video.player = nil }
}
private final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var video: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer, stretch: Bool) {
        super.init(frame: .zero)
        backgroundColor = .black; video.player = player; setStretch(stretch)
    }
    func setStretch(_ enabled: Bool) {
        let gravity: AVLayerVideoGravity = enabled ? .resize : .resizeAspect
        guard video.videoGravity != gravity else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.videoGravity = gravity
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
