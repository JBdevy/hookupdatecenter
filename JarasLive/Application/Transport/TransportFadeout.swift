import Foundation
import Combine

/// A performance gesture, never a project edit or an automation envelope.
@MainActor public final class TransportFadeout: ObservableObject {
    public struct Run: Equatable {
        public let project: UUID
        public let song: UUID
        public let startedAt: Double
        public let duration: Double
        public let originalVolumes: [UUID: Double]
        public var elapsed: Double
        public var remaining: Double { max(0, duration - elapsed) }
        public var fraction: Double { max(0, min(1, remaining / duration)) }
        public var gains: [UUID: Double] { originalVolumes.mapValues { _ in fraction } }
    }
    @Published public private(set) var enabled = false
    @Published public private(set) var duration = 3.0
    @Published public private(set) var trackIDs: Set<UUID> = []
    @Published public private(set) var run: Run?
    @Published public private(set) var notice: String?
    private var noticeToken = UUID()
    private var defaults: UserDefaults?
    private var project: UUID?
    public static let key = "jaras.transportFadeout"
    public var active: Bool { run != nil }
    public func load(project: UUID, defaults: UserDefaults?, defaultTracks: Set<UUID> = []) {
        self.defaults = defaults; self.project = project
        enabled = defaults?.bool(forKey: Self.key + ".enabled") ?? false
        duration = Self.validDuration(defaults?.object(forKey: Self.key + ".duration") as? Double ?? 3)
        let selections = defaults?.dictionary(forKey: Self.key + ".projects") ?? [:]
        trackIDs = (selections[project.uuidString] as? [String]).map { Set($0.compactMap(UUID.init(uuidString:))) } ?? defaultTracks
    }
    public func configure(enabled: Bool, duration: Double, tracks: Set<UUID>) {
        self.enabled = enabled; self.duration = Self.validDuration(duration); trackIDs = tracks
        defaults?.set(enabled, forKey: Self.key + ".enabled")
        defaults?.set(self.duration, forKey: Self.key + ".duration")
        if let project {
            var selections = defaults?.dictionary(forKey: Self.key + ".projects") ?? [:]
            selections[project.uuidString] = tracks.map(\.uuidString).sorted()
            defaults?.set(selections, forKey: Self.key + ".projects")
        }
    }
    public static func validDuration(_ value: Double) -> Double { value.isFinite ? min(5, max(1, value)) : 3 }
    @discardableResult public func start(project: UUID, song: UUID, volumes: [UUID: Double], at time: Double) -> Bool {
        guard enabled, run == nil, !volumes.isEmpty, time.isFinite,
              volumes.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        notice = nil
        run = Run(project: project, song: song, startedAt: time, duration: duration, originalVolumes: volumes, elapsed: 0)
        return true
    }
    /// Includes a zero-gain sample at the endpoint; the caller stops audio before clearing it.
    @discardableResult public func advance(to time: Double) -> Bool {
        guard var next = run, time.isFinite else { return false }
        next.elapsed = min(next.duration, max(next.elapsed, time - next.startedAt))
        if next != run { run = next }
        return next.remaining <= 0
    }
    public func cancel() { run = nil }
    public func multiplier(for track: UUID?) -> Double {
        guard let track, let run, run.originalVolumes[track] != nil else { return 1 }
        return run.fraction
    }
    public func warn(_ message: String) {
        let token = UUID(); noticeToken = token; notice = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }
}

extension ShowController {
    public var fadeoutTracks: [Track] { (current?.tracks ?? []).filter { $0.kind == .standard || $0.kind == .click } }
    public func configureTransportFadeout(enabled: Bool, duration: Double, tracks: Set<UUID>) {
        if !enabled { cancelTransportFadeout() }
        transportFadeout.configure(enabled: enabled, duration: duration,
            tracks: tracks.intersection(fadeoutTracks.map(\.id)))
    }
    public func triggerTransportFadeout() {
        if transportFadeout.active { cancelTransportFadeout(); return }
        guard transportFadeoutCanStart, transportFadeout.enabled else { return }
        guard snapshot.transport.playing else { transportFadeout.warn("Fadeout requires playback."); return }
        guard !snapshot.transport.subPlay.playing else { transportFadeout.warn("Stop Sub Play before starting Fadeout."); return }
        guard let song = current else { return }
        let volumes = Dictionary(uniqueKeysWithValues: fadeoutTracks.filter { transportFadeout.trackIDs.contains($0.id) }.map { ($0.id, $0.volume) })
        guard !volumes.isEmpty else { transportFadeout.warn("Select tracks in the Fadeout settings."); return }
        if transportFadeout.start(project: snapshot.project.id, song: song.id, volumes: volumes, at: timelinePlaybackNow) {
            audioStartTransportFade(Set(volumes.keys), transportFadeout.duration)
            audioTransportFade(transportFadeout.run!.gains)
            startClock()
        }
    }
    public func cancelTransportFadeout() {
        guard transportFadeout.active else { return }
        audioTransportFade([:]); transportFadeout.cancel()
    }
    /// This is called after the transport/audio sample; normal Stop stays immediate.
    func updateTransportFadeout(at time: Double) {
        guard let run = transportFadeout.run else { return }
        guard snapshot.transport.playing, !snapshot.transport.subPlay.playing,
              run.project == snapshot.project.id, run.song == snapshot.transport.songId else { cancelTransportFadeout(); return }
        let finished = transportFadeout.advance(to: time)
        audioTransportFade(transportFadeout.run!.gains)
        if finished {
            send(.stop) // audioUpdate consumes Stop while the selected outputs are still silent.
            cancelTransportFadeout()
        }
    }
}
