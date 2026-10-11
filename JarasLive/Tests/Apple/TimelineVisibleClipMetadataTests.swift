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

    // Revisions and published values can become visible in separate SwiftUI
    // updates. Equal count alone also misses reordered or relocated items.
    var sameRevision = song
    sameRevision.tracks[0].clips.removeLast()
    let removed = cache.metadata(song: sameRevision, key: key)
    precondition(removed !== original && removed.clipIndices(inTrack: 0, from: 26, through: 27) == [1])
    sameRevision.tracks[0].clips.reverse()
    let reversed = cache.metadata(song: sameRevision, key: key)
    precondition(reversed !== removed && reversed.clipIndices(inTrack: 0, from: 26, through: 27) == [0])
    sameRevision.tracks[0].clips[0].startTime = 2000
    let relocated = cache.metadata(song: sameRevision, key: key)
    precondition(relocated !== reversed && relocated.clipIndices(inTrack: 0, from: 26, through: 27).isEmpty)
    var short = track; short.id = UUID(); short.clips = [track.clips[2]]
    sameRevision.tracks.insert(short, at: 0)
    let inserted = cache.metadata(song: sameRevision, key: key)
    precondition(inserted.clipIndices(inTrack: 0, from: 26, through: 27) == [0] &&
        inserted.clipIndices(inTrack: 1, from: 26, through: 27).isEmpty)
    sameRevision.tracks.reverse()
    let trackOrder = cache.metadata(song: sameRevision, key: key)
    precondition(trackOrder.clipIndices(inTrack: 0, from: 26, through: 27).isEmpty &&
        trackOrder.clipIndices(inTrack: 1, from: 26, through: 27) == [0])
    sameRevision.tracks.removeLast()
    let fewerTracks = cache.metadata(song: sameRevision, key: key)
    precondition(fewerTracks.clipIndices(inTrack: 1, from: 0, through: 3000).isEmpty)
    sameRevision.markers = [.init(id: UUID(), name: "TEMPO", position: 0, color: 0,
        tempoBPM: 145, tempoTimebase: .relative, tempoReferenceBPM: 120)]
    let newTempo = cache.metadata(song: sameRevision, key: key)
    precondition(newTempo !== fewerTracks && newTempo.sections(until: 100) == sameRevision.tempoSections(until: 100))
    for _ in 0..<80 {
        precondition(cache.metadata(song: sameRevision, key: key) === newTempo,
            "Coherence checking keeps an unchanged COW snapshot and its cached work")
    }
    sameRevision.tracks[0].heightScale = 2
    precondition(cache.metadata(song: sameRevision, key: key) === newTempo,
        "Individual height previews must not rebuild item indexes or tempo metadata")
    sameRevision.tracks[0].audioFile = AudioFile(path: "replacement.wav")
    let inheritedAudio = cache.metadata(song: sameRevision, key: key)
    precondition(inheritedAudio !== newTempo, "Inherited track audio changes item media and hit actions")
    sameRevision.tracks[0].timecode = TimecodeSettings()
    let timecode = cache.metadata(song: sameRevision, key: key)
    precondition(timecode !== inheritedAudio, "Track timecode labels belong to the same selection snapshot")
    sameRevision.tracks[0].clips[0].renderedTiming = true
    let rendered = cache.metadata(song: sameRevision, key: key)
    precondition(rendered !== timecode)
    sameRevision.tracks[0].clips[0].pitchSemitones = 3
    precondition(cache.metadata(song: sameRevision, key: key) !== rendered,
        "Rendered timing and pitch updates cannot reuse a stale clip snapshot")
    precondition(original.clipIndices(inTrack: 0, from: 26, through: 27) == [1, 2],
        "Previously captured drawing closures retain their original immutable item index")
    print("TIMELINE_METADATA_SAME_REVISION_CLIP_DELETE_REORDER_MOVE_TRACK_INSERT_REORDER_DELETE_TEMPO_AND_RESIZE_REUSE_OK")

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
