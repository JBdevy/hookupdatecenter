import Foundation

/// Move a boundary inside a contiguous selection of teleprompter text. Outer
/// ends stay fixed; crossing a short neighbour pushes its next boundary only
/// as far as needed to preserve its minimum duration.
public struct TeleprompterBoundaryEdit {
    public let clips: [AudioClip]
    public init?(track: Track, selected: Set<UUID>, left: UUID, right: UUID,
                 position: Double, minimumDuration: Double = 0.01) {
        guard track.kind.isTeleprompter, position.isFinite, minimumDuration.isFinite,
              selected.contains(left), selected.contains(right) else { return nil }
        let ordered = track.clips.sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
        func eligible(_ index: Int) -> Bool {
            selected.contains(ordered[index].id) && ordered[index].text != nil && ordered[index].audioFile == nil && ordered[index].midi == nil
        }
        func adjoining(_ a: Int, _ b: Int) -> Bool {
            eligible(a) && eligible(b) && (ordered[a].recordingLane ?? 0) == (ordered[b].recordingLane ?? 0) &&
                abs(ordered[a].startTime + ordered[a].duration - ordered[b].startTime) < 1e-7
        }
        guard let index = ordered.firstIndex(where: { $0.id == left }), index + 1 < ordered.count,
              ordered[index + 1].id == right, adjoining(index, index + 1) else { return nil }
        var first = index, last = index + 1
        while first > 0 && adjoining(first - 1, first) { first -= 1 }
        while last + 1 < ordered.count && adjoining(last, last + 1) { last += 1 }
        var result = Array(ordered[first...last])
        let minimum = max(0.01, min(minimumDuration, result.map(\.duration).min() ?? 0.01))
        var edges = result.map(\.startTime) + [result.last!.startTime + result.last!.duration]
        let boundary = index - first + 1
        var lower = edges[0], upper = edges.last!
        for _ in 0..<boundary { lower = (lower + minimum).nextUp }
        for _ in boundary..<result.count { upper = (upper - minimum).nextDown }
        guard lower <= upper else { return nil }
        edges[boundary] = min(upper, max(lower, position))
        if boundary + 1 < result.count {
            for i in (boundary + 1)..<result.count { edges[i] = max(edges[i], (edges[i - 1] + minimum).nextUp) }
        }
        if boundary > 1 {
            for i in stride(from: boundary - 1, through: 1, by: -1) { edges[i] = min(edges[i], (edges[i + 1] - minimum).nextDown) }
        }
        for i in result.indices {
            result[i].startTime = edges[i]; result[i].duration = edges[i + 1] - edges[i]
            guard result[i].duration >= 0.01 else { return nil }
        }
        clips = result
    }
}

/// A rolling edit changes one shared boundary and preserves both outer ends.
public struct SharedItemBoundaryEdit {
    public let left: AudioClip
    public let right: AudioClip
    public var position: Double { right.startTime }
    public init?(song: Song, track: Track, left: AudioClip, right: AudioClip, position: Double,
                 minimumDuration: Double = 0.01, sourceDurations: [UUID: Double] = [:]) {
        guard position.isFinite, left.id != right.id,
              abs(left.startTime + left.duration - right.startTime) < 1e-7,
              (left.recordingLane ?? 0) == (right.recordingLane ?? 0) else { return nil }
        let minimum = max(0.01, min(minimumDuration, left.duration, right.duration))
        var lower = (left.startTime + minimum).nextUp
        var upper = (right.startTime + right.duration - minimum).nextDown
        if track.kind == .click {
            if left.audioFile == nil, let region = song.clickRegion(for: left) { upper = min(upper, region.endTime) }
            if right.audioFile == nil, let region = song.clickRegion(for: right) { lower = max(lower, region.startTime) }
        }
        if (right.audioFile ?? track.audioFile) != nil, !right.isImage, right.midi == nil,
           right.loopLength == nil, sourceDurations[right.id] == nil {
            lower = max(lower, right.startTime - right.sourceOffset / right.audioRate)
        }
        guard lower <= upper else { return nil }
        let boundary = min(upper, max(lower, position))
        func resized(_ original: AudioClip, start: Double, end: Double) -> AudioClip? {
            if track.kind == .click && original.audioFile == nil { return song.resizedClick(original, start: start, end: end) }
            if track.kind == .timecode && !original.isProjectionMedia {
                var clip = original
                if track.importedTimecodeItems != true {
                    guard let region = song.parts.first(where: { Project.timecodeItemID($0.id) == original.id }) else { return nil }
                    clip.timecodeStartOffset = start - region.startTime; clip.timecodeEndOffset = end - region.endTime
                }
                clip.startTime = start; clip.duration = end - start
                return clip
            }
            if original.text != nil && original.audioFile == nil && track.audioFile == nil && original.midi == nil {
                var clip = original
                clip.startTime = start; clip.duration = end - start
                return clip
            }
            return original.resized(start: start, end: end, sourceDuration: sourceDurations[original.id])
        }
        guard let a = resized(left, start: left.startTime, end: boundary),
              let b = resized(right, start: boundary, end: right.startTime + right.duration),
              abs(a.startTime + a.duration - b.startTime) < 1e-7,
              abs(a.startTime - left.startTime) < 1e-7,
              abs(b.startTime + b.duration - right.startTime - right.duration) < 1e-7 else { return nil }
        self.left = a; self.right = b
    }
}

public extension Project {
    @discardableResult mutating func resizeTeleprompterBoundary(selected: Set<UUID>, left: UUID, right: UUID, position: Double) -> Bool {
        for s in songs.indices { for t in songs[s].tracks.indices {
            guard let edit = TeleprompterBoundaryEdit(track: songs[s].tracks[t], selected: selected,
                left: left, right: right, position: position) else { continue }
            let changes = Dictionary(uniqueKeysWithValues: edit.clips.map { ($0.id, $0) })
            for i in songs[s].tracks[t].clips.indices {
                if let clip = changes[songs[s].tracks[t].clips[i].id] { songs[s].tracks[t].clips[i] = clip }
            }
            return true
        } }
        return false
    }
    @discardableResult mutating func resizeSharedItemBoundary(left: UUID, right: UUID, position: Double, sourceDurations: [UUID: Double] = [:]) -> Bool {
        for s in songs.indices { for t in songs[s].tracks.indices {
            let track = songs[s].tracks[t]
            guard let a = track.clips.firstIndex(where: { $0.id == left }),
                  let b = track.clips.firstIndex(where: { $0.id == right }),
                  let edit = SharedItemBoundaryEdit(song: songs[s], track: track, left: track.clips[a], right: track.clips[b], position: position, sourceDurations: sourceDurations) else { continue }
            // Validate the pair together: a single-lane neighbour must not block
            // the half of the operation that expands into the other item.
            var remaining = track; remaining.clips.removeAll { $0.id == left || $0.id == right }
            guard remaining.canPlaceItem(start: edit.left.startTime, duration: edit.left.duration, media: edit.left.isProjectionMedia),
                  remaining.canPlaceItem(start: edit.right.startTime, duration: edit.right.duration, media: edit.right.isProjectionMedia) else { return false }
            songs[s].tracks[t].clips[a] = edit.left; songs[s].tracks[t].clips[b] = edit.right
            return true
        } }
        return false
    }
}
