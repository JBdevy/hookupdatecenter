import Foundation

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
