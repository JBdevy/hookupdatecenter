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
    print("REMOTE_HEIGHT_RATIO_ROUNDTRIP_OVERLAPS_COMPACT_REGION_OK")
    print("TRACK_HEIGHT_SHARED_GEOMETRY_OVERLAPS_INDIVIDUAL_PREVIEW_LANE_CACHE_GLOBAL_RATIOS_BOUNDS_ACTIVE_RECORDING_OK")
}
