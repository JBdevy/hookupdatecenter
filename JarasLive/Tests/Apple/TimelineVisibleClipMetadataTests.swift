MainActor.assumeIsolated {
    let project = UUID()
    var song = Project.empty(name: "Clip index generations").songs[0]
    var track = Track(id: UUID(), name: "Imported order", role: .other)
    track.clips = [
        AudioClip(id: UUID(), name: "Late", startTime: 100, duration: 20),
        AudioClip(id: UUID(), name: "Spanning", startTime: 0, duration: 1000),
        AudioClip(id: UUID(), name: "Inside", startTime: 25, duration: 5)
    ]
    song.tracks = [track]
    let cache = TimelineRenderMetadataCache()
    let key = metadataKey(song, project: project)
    let original = cache.metadata(song: song, key: key)
    precondition(original.clipIndices(inTrack: 0, from: 26, through: 27) == [1, 2])
    precondition(cache.metadata(song: song, key: key) === original, "zoom keeps the existing index snapshot")

    var dragged = song
    dragged.tracks[0].clips[2].startTime = 80
    let dragKey = TimelineRenderKey(revision: key.revision, songID: song.id,
        movingClip: track.clips[2].id, movingStart: 80, movingTrack: nil,
        movingRegion: nil, regionDelta: 0, resizingRegion: nil, resizedStart: 0, resizedEnd: 0,
        projectID: project)
    let drag = cache.metadata(song: dragged, key: dragKey)
    precondition(drag !== original)
    precondition(drag.clipIndices(inTrack: 0, from: 26, through: 27) == [1])
    precondition(drag.clipIndices(inTrack: 0, from: 81, through: 82) == [1, 2])
    precondition(original.clipIndices(inTrack: 0, from: 26, through: 27) == [1, 2], "old Canvas callbacks keep their generation")

    // Structural edits may reorder both track and clip arrays. Source indices
    // must belong to the exact same snapshot as the renderer's song.
    var edited = dragged
    edited.tracks[0].clips.remove(at: 0)
    edited.tracks[0].clips.reverse()
    let first = Track(id: UUID(), name: "New first track", role: .other)
    edited.tracks.insert(first, at: 0)
    let next = cache.metadata(song: edited, key: metadataKey(edited, revision: 2, project: project))
    precondition(next.clipIndices(inTrack: 0, from: 0, through: 1000).isEmpty)
    precondition(next.clipIndices(inTrack: 1, from: 81, through: 82) == [0, 1])
    precondition(next.clipIndices(inTrack: 1, from: 26, through: 27) == [1])
    precondition(next.clipIndices(inTrack: -1, from: 0, through: 1000).isEmpty)
    precondition(next.clipIndices(inTrack: 2, from: 0, through: 1000).isEmpty)
    precondition(drag.clipIndices(inTrack: 0, from: 100, through: 101) == [0, 1])
    print("TIMELINE_VISIBLE_CLIP_METADATA_ZOOM_REUSE_DRAG_STRUCTURAL_EDIT_OLD_GENERATION_OK")
}
