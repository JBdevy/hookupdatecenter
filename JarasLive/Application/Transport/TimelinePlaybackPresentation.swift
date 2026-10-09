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

/// Counts elapsed playback, never cursor distance from a Seek command. The
/// region index is rebuilt only after project edits; ordinary samples query
/// the intersecting ranges without scanning the complete arrangement.
struct SetlistLivePlaybackTracker {
    static let threshold: Double = 10
    /// A drawer's history belongs to its songs. The wrapper is complete only
    /// when every current child is complete, including after project edits.
    static func normalizedMarks(project: Project, marked: Set<UUID>) -> Set<UUID> {
        let parts = project.songs.flatMap(\.parts)
        let children = Dictionary(grouping: parts.filter { $0.parentRegionID != nil }, by: { $0.parentRegionID! })
        var result = marked.intersection(parts.map(\.id)).subtracting(children.keys)
        for (parent, members) in children where members.allSatisfy({ result.contains($0.id) }) {
            result.insert(parent)
        }
        return result
    }
    private struct RegionIndex {
        let regions: [Part]
        let maximumEnds: [Double]
        init(_ parts: [Part]) {
            regions = parts.sorted { $0.startTime < $1.startTime }
            var maximum = -Double.infinity
            maximumEnds = regions.map { maximum = max(maximum, $0.endTime); return maximum }
        }
        func intersecting(_ start: Double, _ end: Double) -> ArraySlice<Part> {
            var lower = 0, upper = maximumEnds.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if maximumEnds[middle] <= start { lower = middle + 1 } else { upper = middle }
            }
            let first = lower
            while lower < regions.count && regions[lower].startTime < end { lower += 1 }
            return regions[first..<lower]
        }
        func containing(_ position: Double) -> [Part] {
            intersecting(position, position.nextUp).filter { $0.endTime > position }
        }
    }
    private var projectID: UUID?
    private var revision: UInt64?
    private var indexes: [UUID: RegionIndex] = [:]
    private var childrenByParent: [UUID: Set<UUID>] = [:]
    private var parentByChild: [UUID: UUID] = [:]
    private var elapsedByRegion: [UUID: Double] = [:]

    mutating func record(project: Project, revision: UInt64, before: TransportState,
                         after: TransportState, elapsed: Double, marked: Set<UUID>) -> Set<UUID> {
        guard elapsed.isFinite, elapsed > 0 else { return [] }
        if projectID != project.id { elapsedByRegion.removeAll(); self.revision = nil; projectID = project.id }
        if self.revision != revision {
            let parts = project.songs.flatMap(\.parts)
            childrenByParent = Dictionary(grouping: parts.filter { $0.parentRegionID != nil }, by: { $0.parentRegionID! })
                .mapValues { Set($0.map(\.id)) }
            parentByChild = Dictionary(uniqueKeysWithValues: parts.compactMap { part in part.parentRegionID.map { (part.id, $0) } })
            indexes = Dictionary(uniqueKeysWithValues: project.songs.map { song in
                (song.id, RegionIndex(song.parts.filter { childrenByParent[$0.id] == nil }))
            })
            let playable = Set(parts.filter { childrenByParent[$0.id] == nil }.map(\.id))
            elapsedByRegion = elapsedByRegion.filter { playable.contains($0.key) }
            self.revision = revision
        }
        var contributions: [UUID: Double] = [:]
        func contribute(_ id: UUID, _ duration: Double) {
            guard !marked.contains(id), duration > 0 else { return }
            // Two simultaneous heads in one song still count only real time.
            contributions[id] = max(contributions[id] ?? 0, min(duration, elapsed))
        }
        func stream(wasPlaying: Bool, playing: Bool, start: Double, end: Double, promoted: Bool = false) {
            guard wasPlaying, start.isFinite, end.isFinite,
                  let songID = before.songId, let index = indexes[songID] else { return }
            if before.songId == after.songId && abs(end - start - elapsed) < 0.000001 {
                for region in index.intersecting(start, end) {
                    contribute(region.id, min(end, region.endTime) - max(start, region.startTime))
                }
                return
            }
            let prior = index.containing(start)
            let next = after.songId.flatMap { indexes[$0] }?.containing(end) ?? []
            let nextIDs = Set(next.map(\.id))
            let priorIDs = Set(prior.map(\.id))
            for region in prior {
                let continues = (playing || promoted) && nextIDs.contains(region.id)
                contribute(region.id, continues ? elapsed : min(elapsed, max(0, region.endTime - start)))
            }
            // A queued transition may consume the remaining part of this tick.
            let oldTail = min(elapsed, prior.map { max(0, $0.endTime - start) }.min() ?? 0)
            if playing {
                for region in next where !priorIDs.contains(region.id) {
                    contribute(region.id, min(elapsed - oldTail, max(0, end - region.startTime)))
                }
            }
        }
        stream(wasPlaying: before.playing, playing: after.playing, start: before.position, end: after.position)
        let promoted = before.subPlay.playing && !after.subPlay.playing && after.playing &&
            before.subPlayPromotion != after.subPlayPromotion
        stream(wasPlaying: before.subPlay.playing, playing: after.subPlay.playing,
               start: before.subPlay.position, end: promoted ? after.position : after.subPlay.position, promoted: promoted)
        var newlyMarked: Set<UUID> = []
        for (id, duration) in contributions {
            elapsedByRegion[id, default: 0] += duration
            if elapsedByRegion[id, default: 0] + 0.000000001 >= Self.threshold {
                newlyMarked.insert(id); elapsedByRegion[id] = nil
            }
        }
        if !newlyMarked.isEmpty {
            let completedSongs = marked.union(newlyMarked)
            for parent in Set(newlyMarked.compactMap { parentByChild[$0] }) where !marked.contains(parent) {
                if childrenByParent[parent]?.isSubset(of: completedSongs) == true { newlyMarked.insert(parent) }
            }
        }
        return newlyMarked
    }
}
