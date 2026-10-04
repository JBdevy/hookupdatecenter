import Foundation

/// Frame-rate presentation of the last authoritative transport sample. This
/// never predicts engine transitions: loop wraps, queues and Sub Play promotion
/// remain the engine's responsibility.
public struct TimelinePlaybackPresentation: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case main, sub }

    /// Two transport ticks at 30 Hz. A delayed producer must not leave the
    /// viewport running indefinitely on an old sample.
    public static let maximumExtrapolation: Double = 1.0 / 15.0

    public let mainPosition: Double
    public let subPosition: Double
    public let followSource: Source?

    public var followPosition: Double? {
        switch followSource {
        case .main: return mainPosition
        case .sub: return subPosition
        case nil: return nil
        }
    }

    public init(transport: TransportState, elapsed: Double, songDuration: Double,
                mainBoundary: Double? = nil) {
        let delta = elapsed.isFinite ? min(Self.maximumExtrapolation, max(0, elapsed)) : 0
        var mainEnd = songDuration
        // A loop owns its boundary even when a region ends earlier. Once the
        // engine releases it, the regular region/queue boundary applies again.
        if let loop = transport.multiLoop, !loop.released,
           loop.start.isFinite, loop.end.isFinite, loop.end > loop.start {
            mainEnd = min(mainEnd, loop.end)
        } else if transport.loop.enabled, let start = transport.loop.start,
                  let end = transport.loop.end, start.isFinite, end.isFinite, end > start {
            mainEnd = min(mainEnd, end)
        } else if let boundary = transport.ignoreNextEnd ?? mainBoundary, boundary.isFinite {
            mainEnd = min(mainEnd, boundary)
        }
        mainPosition = Self.advance(transport.position, playing: transport.playing,
                                    delta: delta, end: mainEnd)
        subPosition = Self.advance(transport.subPlay.position, playing: transport.subPlay.playing,
                                   delta: delta, end: songDuration)
        followSource = transport.subPlay.playing ? .sub : transport.playing ? .main : nil
    }

    private static func advance(_ position: Double, playing: Bool, delta: Double, end: Double) -> Double {
        let sample = position.isFinite ? max(0, position) : 0
        guard playing else { return sample }
        // An authoritative sample always wins over stale/malformed limits. Do
        // not pull a cursor backwards or extrapolate beyond a terminal point.
        guard end.isFinite else { return sample }
        return max(sample, min(sample + delta, end))
    }
}

/// Song names and explicit tempo metadata shared by desktop and Remote displays.
public struct TransportSongDisplays {
    public let current: Part?
    public let next: Part?
    public let queued: Part?
    public let currentBPM: Double?
    public let nextBPM: Double?
    public let queuedBPM: Double?

    public init(song: Song?, transport: TransportState, focusedRegion: UUID?) {
        let parts = song?.parts ?? []
        let selected = parts.first { $0.id == (transport.playing ? transport.regionId : focusedRegion ?? transport.regionId) }
        let root = selected?.parentRegionID ?? selected?.id
        let running = transport.playing ? song?.playingSetlistRegion(transport.regionId, position: transport.position,
            expanded: Set(root.map { [$0] } ?? [])) : nil
        current = transport.ignoreNextRegionId.flatMap { id in parts.first { $0.id == id } } ?? running ?? selected
        next = transport.playing && transport.ignoreNextAfter == nil ? song?.nextDrawerRegion(transport.regionId, position: transport.position) : nil
        queued = transport.subPlay.playing ? song?.sectionRegion(at: transport.subPlay.position) : parts.first { $0.id == transport.queuedRegionId }
        func bpm(_ region: Part?, at position: Double? = nil) -> Double? {
            guard let region else { return nil }
            // Do not invent a tempo from the project default or a previous song.
            let markers = (song?.markers ?? []).filter { $0.isTempo && $0.position >= region.startTime && $0.position < region.endTime }
                .sorted { $0.position < $1.position }
            return (position.flatMap { position in markers.last { $0.position <= position } } ?? markers.first)?.tempoBPM
        }
        currentBPM = bpm(current, at: transport.playing ? transport.position : nil)
        nextBPM = bpm(next)
        queuedBPM = bpm(queued, at: transport.subPlay.playing ? transport.subPlay.position : nil)
    }
}

public extension TransportState {
    /// Follow and zoom share transport priority; the editing head owns stopped navigation.
    var timelineZoomPosition: Double {
        let value = subPlay.playing ? subPlay.position : playing ? position : editPosition ?? position
        return value.isFinite ? max(0, value) : 0
    }
}
