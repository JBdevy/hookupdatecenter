func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
private let cache = IpadTimelineContentCache()
let parts = (0..<6000).map { Part(startTime: Double($0 * 10), endTime: Double($0 * 10 + 12)) }
let clips = (0..<2000).map { AudioClip(startTime: Double($0 * 10), duration: $0 % 7 == 0 ? 14 : 8) }
var song = Song(parts: parts, tracks: [Track(clips: clips)])
let project = UUID()
private var key = IpadTimelineContentCache.Key(project: project, song: song.id, revision: 1,
    region: nil, markerID: nil, markerPosition: nil, move: nil, mix: nil)
var builds = 0
private func get() -> IpadTimelineContent { cache.value(key) { builds += 1; return song }! }
private let initial = get(), track = initial.track(song.tracks[0].id)!
let expectedLanes = TrackLanes(track: song.tracks[0])
let begin = Date()
for frame in 0..<1000 {
    let content = get()
    check(content === initial, "Zoom rebuilt the document snapshot")
    check(content.track(song.tracks[0].id) === track, "Zoom rebuilt overlap components")
    let start = Double(frame * 50), end = start + 40
    let visible = content.regions(from: start, through: end)
    let expected = parts.filter { $0.startTime <= end && $0.endTime >= start }
    check(visible.map(\.id) == expected.map(\.id), "Culling changed boundary or paint order")
    let clip = clips[frame % clips.count]
    check(track.clips[clip.id]?.id == clip.id, "Clip lookup lost an item")
    check(track.lanes.localCount(for: clip.id) == expectedLanes.localCount(for: clip.id), "Overlap geometry changed")
}
check(builds == 1, "The pinch path rebuilt document data")
for revision in 2...3 {
    key = .init(project: project, song: song.id, revision: UInt64(revision), region: nil, markerID: nil, markerPosition: nil, move: nil, mix: nil)
    check(get() !== initial, "Document edits retained stale geometry")
}
key = .init(project: project, song: song.id, revision: 3, region: .init(id: parts[0].id, start: 7), markerID: nil, markerPosition: nil, move: nil, mix: nil)
private let preview = get()
key = .init(project: project, song: song.id, revision: 3, region: nil, markerID: nil, markerPosition: nil, move: nil, mix: nil)
check(get() !== preview, "Cancelling a drag retained the preview")
key = .init(project: project, song: song.id, revision: 3, region: nil, markerID: UUID(), markerPosition: 17, move: .init(start: 6), mix: .init(value: 0.5))
private let edited = get()
key = .init(project: UUID(), song: song.id, revision: 3, region: nil, markerID: nil, markerPosition: nil, move: nil, mix: nil)
check(get() !== edited, "Project switch retained live edits")
song = Song(parts: [], tracks: [])
key = .init(project: project, song: song.id, revision: 3, region: nil, markerID: nil, markerPosition: nil, move: nil, mix: nil)
check(get().roots.isEmpty && get().tracks.isEmpty, "Empty project kept old content")
print("NATIVE_6000_REGIONS_2000_ITEMS_1000_ZOOM_FRAMES_REUSE_AND_EDIT_INVALIDATION_OK \(Int(Date().timeIntervalSince(begin) * 1000))ms")
