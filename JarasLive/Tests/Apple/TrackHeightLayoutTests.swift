MainActor.assumeIsolated {
    var tracks = [Track(heightScale: 0.5), Track(clips: [AudioClip(startTime: 0, duration: 5), AudioClip(startTime: 1, duration: 2)]), Track(heightScale: 1.5)]
    let cache = TrackLayoutCache(), key = TimelineRenderKey(revision: 1)
    let initial = cache.layout(tracks, height: 64, key: key)
    precondition(initial.lanes.map(\.count) == [1, 2, 1])
    precondition(initial.heights == [32, 89.6, 96] && initial.offsets == [0, 32, 121.6])
    precondition(initial.globalLimits == 48...160)
    for frame in 0..<50 {
        let rows = cache.layout(tracks, height: CGFloat(24 + frame * 6), key: key)
        precondition(rows.lanes == initial.lanes && LaneBuildCounter.count == 3, "zoom shares expensive lane maps")
        precondition(abs(rows.heights[0] / rows.heights[2] - 1.0 / 3) < 1e-12)
        precondition(abs(rows.heights[1] / rows.heights[2] - 89.6 / 96) < 1e-12)
        precondition(rows.laneHeights.enumerated().allSatisfy { index, height in
            let limits = TrackHeightGeometry.laneLimits(count: rows.lanes[index].count)
            return limits.contains(Double(height))
        })
    }
    tracks[1].heightScale = 2
    let resized = cache.layout(tracks, height: 64, key: key)
    precondition(resized.heights == [32, 179.2, 96] && resized.offsets == [0, 32, 211.2])
    precondition(LaneBuildCounter.count == 3 && resized.lanes == initial.lanes, "individual preview does not rebuild lanes")
    tracks = [Track(heightScale: 0.375), Track(heightScale: 3.75)]
    let extreme = cache.layout(tracks, height: 64, key: TimelineRenderKey(revision: 2))
    precondition(extreme.heights == [24, 240] && extreme.globalLimits == 64...64)
    for height: CGFloat in [24, 48, 120, 240] {
        let rows = cache.layout(tracks, height: height, key: TimelineRenderKey(revision: 2))
        precondition(rows.heights == [24, 240] && rows.baseHeight == 64, "a full-range pair stops shared zoom without changing ratios")
    }
    var recording = Track()
    RecordingLaneLayout.shared.counts[recording.id] = 3
    recording.heightScale = 1.5
    let activeTake = TrackRowLayout(tracks: [recording], baseHeight: 64)
    precondition(activeTake.lanes[0].count == 3 && abs(activeTake.laneHeights[0] - 67.2) < 1e-9)
    precondition(abs(activeTake.heights[0] - 201.6) < 1e-9, "active recording lanes use the same effective height")
    let remoteFirst = DAWRemoteState.Track(id: UUID(), name: "Short", color: 0x828282, volume: 1, pan: 0, mute: false, solo: false, clips: [], heightScale: 0.5)
    let remoteSecond = DAWRemoteState.Track(id: UUID(), name: "Tall", color: 0x828282, volume: 1, pan: 0, mute: false, solo: false, clips: [], laneCount: 2, heightScale: 1.5)
    precondition(DAWRemoteItemLayout.laneHeight(remoteFirst) == 43)
    precondition(abs(DAWRemoteItemLayout.rowHeight(remoteSecond) - 180.6) < 1e-9)
    let region = DAWRemoteState.Region(id: UUID(), name: "Region", start: 0, end: 10, color: 0)
    let compact = DAWRemoteItemLayout.tracks([remoteSecond], within: region)[0]
    precondition(compact.heightScale == 1.5 && compact.laneCount == 1)
    let data = try! JSONEncoder().encode(remoteSecond)
    precondition(try! JSONDecoder().decode(DAWRemoteState.Track.self, from: data).heightScale == 1.5)

    let snapshotCache = TrackLayoutCache(), unchangedKey = TimelineRenderKey(revision: 10)
    let first = Track(clips: [AudioClip(startTime: 0, duration: 8), AudioClip(startTime: 1, duration: 2)])
    let second = Track(clips: [AudioClip(startTime: 3, duration: 2)])
    let third = Track(clips: [AudioClip(startTime: 1, duration: 5), AudioClip(startTime: 2, duration: 3), AudioClip(startTime: 3, duration: 1)])
    let beforeInsert = snapshotCache.layout([first, second], height: 64, key: unchangedKey)
    let afterInsert = snapshotCache.layout([first, second, third], height: 64, key: unchangedKey)
    precondition(afterInsert.lanes.map(\.count) == [2, 1, 3])
    precondition(afterInsert.offsets.count == 3 && afterInsert.heights.count == 3, "a new published track must immediately get a row, even before the render revision changes")
    let reordered = snapshotCache.layout([third, first, second], height: 64, key: unchangedKey)
    precondition(reordered.lanes == [afterInsert.lanes[2], afterInsert.lanes[0], afterInsert.lanes[1]], "equal scales and row count do not identify the track order")
    let reduced = snapshotCache.layout([second], height: 64, key: unchangedKey)
    precondition(reduced.lanes == [beforeInsert.lanes[1]] && reduced.offsets == [0] && reduced.heights == [64])
    let replaced = snapshotCache.layout([third], height: 64, key: unchangedKey)
    precondition(replaced.lanes == [afterInsert.lanes[2]], "switching the only track must replace its lane map")
    let empty = snapshotCache.layout([], height: 64, key: unchangedKey)
    precondition(empty.lanes.isEmpty && empty.offsets.isEmpty && empty.heights.isEmpty && empty.audioHeights.isEmpty && empty.envelopeHeights.isEmpty && empty.totalHeight == 0)
    let restored = snapshotCache.layout([first, second], height: 64, key: unchangedKey)
    precondition(restored.lanes == beforeInsert.lanes && restored.heights == beforeInsert.heights)

    var clipEdit = first
    clipEdit.clips.removeLast()
    let removedClip = snapshotCache.layout([clipEdit, second], height: 64, key: unchangedKey)
    precondition(removedClip.lanes[0].count == 1 && removedClip.lanes[0].lanes.count == 1 && removedClip.heights == [64, 64],
        "Removing an overlapping item must retire its lane before the render revision changes")
    clipEdit.clips = first.clips.reversed()
    let reorderedClips = snapshotCache.layout([clipEdit, second], height: 64, key: unchangedKey)
    precondition(reorderedClips.lanes == beforeInsert.lanes)
    clipEdit.clips[0].startTime = 20
    let movedClip = snapshotCache.layout([clipEdit, second], height: 64, key: unchangedKey)
    precondition(movedClip.lanes[0].count == 1 && movedClip.heights == [64, 64],
        "Equal clip counts and IDs cannot keep overlap geometry after a position edit")
    _ = snapshotCache.layout([first, second], height: 64, key: unchangedKey)
    print("TRACK_ROW_CACHE_SAME_REVISION_CLIP_DELETE_REORDER_RELOCATE_EXACT_GEOMETRY_OK")

    var automated = first
    automated.automation = TrackAutomation(envelopes: [.init(), .init(visible: false), .init()])
    let buildCountBeforeEnvelopeChange = LaneBuildCounter.count
    let withEnvelope = snapshotCache.layout([automated, second], height: 64, key: unchangedKey)
    precondition(withEnvelope.audioHeights == beforeInsert.heights && withEnvelope.envelopeCounts == [2, 0])
    precondition(abs(withEnvelope.envelopeHeights[0] * 3 - beforeInsert.heights[0]) < 1e-9)
    precondition(abs(withEnvelope.heights[0] - beforeInsert.heights[0] * (1 + 2.0 / 3)) < 1e-9 && withEnvelope.offsets[1] == withEnvelope.heights[0])
    automated.automation?.lanesVisible = false
    let hidden = snapshotCache.layout([automated, second], height: 64, key: unchangedKey)
    precondition(hidden.heights == beforeInsert.heights && hidden.envelopeCounts == [0, 0])
    automated.automation?.lanesVisible = true
    let reshown = snapshotCache.layout([automated, second], height: 64, key: unchangedKey)
    precondition(reshown.heights == withEnvelope.heights && reshown.audioHeights == withEnvelope.audioHeights)
    automated.automation?.enabled = false
    let disabled = snapshotCache.layout([automated, second], height: 64, key: unchangedKey)
    precondition(disabled.heights == beforeInsert.heights && disabled.envelopeCounts == [0, 0], "Env OFF closes its space below the audio row")
    precondition(LaneBuildCounter.count == buildCountBeforeEnvelopeChange, "showing or hiding envelopes must not rebuild the audio lane maps")

    automated.automation?.enabled = true
    var automatedSecond = second, automatedThird = third
    automatedSecond.automation = TrackAutomation(envelopes: [.init()])
    automatedThird.automation = TrackAutomation(envelopes: [.init(), .init(), .init()])
    let proportionalCache = TrackLayoutCache()
    let proportionalTracks = [automated, automatedSecond, automatedThird]
    let normalRows = proportionalCache.layout(proportionalTracks, height: 64, key: unchangedKey)
    let laneBuildsBeforeResize = LaneBuildCounter.count
    precondition(normalRows.lanes.map(\.count) == [2, 1, 3] && normalRows.envelopeCounts == [2, 1, 3])
    for height: CGFloat in [24, 32, 48, 64, 128, 240] {
        let rows = proportionalCache.layout(proportionalTracks, height: height, key: unchangedKey)
        var expectedOffset: CGFloat = 0
        for index in proportionalTracks.indices {
            precondition(abs(rows.envelopeHeights[index] * 3 - rows.audioHeights[index]) < 1e-9,
                         "Each envelope is one third of the complete audio area, including overlapping item lanes")
            precondition(abs(rows.heights[index] - rows.audioHeights[index] - CGFloat(rows.envelopeCounts[index]) * rows.envelopeHeights[index]) < 1e-9)
            precondition(abs(rows.offsets[index] - expectedOffset) < 1e-9)
            expectedOffset += rows.heights[index]
        }
        precondition(abs(rows.totalHeight - expectedOffset) < 1e-9)
    }
    var individuallyResized = proportionalTracks
    individuallyResized[0].heightScale = 2
    let doubled = proportionalCache.layout(individuallyResized, height: 64, key: unchangedKey)
    precondition(abs(doubled.audioHeights[0] - normalRows.audioHeights[0] * 2) < 1e-9 && abs(doubled.envelopeHeights[0] - normalRows.envelopeHeights[0] * 2) < 1e-9,
                 "Individual resize scales both audio and envelope areas by the same proportion")
    precondition(doubled.audioHeights[1] == normalRows.audioHeights[1] && doubled.envelopeHeights[1] == normalRows.envelopeHeights[1])
    precondition(doubled.offsets[1] == doubled.heights[0] && LaneBuildCounter.count == laneBuildsBeforeResize)
    print("ENVELOPE_ONE_THIRD_AUDIO_HEIGHT_GLOBAL_INDIVIDUAL_RESIZE_OVERLAP_OFFSETS_LANE_REUSE_OK")
    print("TRACK_ROW_CACHE_INSERT_REORDER_REDUCE_REPLACE_CLEAR_SAME_REVISION_ENVELOPE_VISIBILITY_AUDIO_HEIGHT_OK")
    print("REMOTE_HEIGHT_RATIO_ROUNDTRIP_OVERLAPS_COMPACT_REGION_OK")
    print("TRACK_HEIGHT_SHARED_GEOMETRY_OVERLAPS_INDIVIDUAL_PREVIEW_LANE_CACHE_GLOBAL_RATIOS_BOUNDS_ACTIVE_RECORDING_OK")
}
