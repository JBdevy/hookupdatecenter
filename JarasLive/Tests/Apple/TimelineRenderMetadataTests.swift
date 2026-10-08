// These counters instrument the production tempo methods in the shell harness.
// They prove cache hits avoid segmentation rather than merely returning equality.
enum TimelineMetadataWorkProbe {
    enum Work { case sections, fragments }
    private static let lock = NSLock()
    private static var sectionCount = 0, fragmentCount = 0
    static func record(_ work: Work) {
        lock.lock(); defer { lock.unlock() }
        switch work {
        case .sections: sectionCount += 1
        case .fragments: fragmentCount += 1
        }
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        sectionCount = 0; fragmentCount = 0
    }
    static var counts: (sections: Int, fragments: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sectionCount, fragmentCount)
    }
}

func metadataSong() -> Song {
    var song = Project.empty(name: "Metadata zoom").songs[0]
    song.duration = 3072
    song.timeSettings = ProjectTimeSettings()
    song.parts = (0..<256).map { index in
        Part(id: UUID(), name: "Region \(index)", startTime: Double(index * 12), endTime: Double(index * 12 + 12))
    }
    let group = Part(id: UUID(), name: "Folder", startTime: 0, endTime: 24)
    song.parts[0].parentRegionID = group.id
    song.parts[1].parentRegionID = group.id
    song.parts.append(group)
    song.markers = (0..<512).map { index in
        let bpm: Double = index % 2 == 0 ? 120 : 180
        let beats = index % 3 == 0 ? 3 : 4
        return TimelineMarker(id: UUID(), name: "TEMPO", position: Double(index * 6), color: 0x999999,
            tempoBPM: bpm, tempoBeats: beats,
            tempoUnit: 4, tempoTimebase: .relative, tempoReferenceBPM: 120)
    }
    song.tracks = (0..<8).map { trackIndex in
        var track = Track(id: UUID(), name: "Track \(trackIndex)", role: .other)
        track.clips = (0..<256).map { index in
            let start = Double(index * 12) + 1
            var clip = AudioClip(id: UUID(), name: "Clip \(index)", startTime: start, duration: 16)
            clip.sourceOffset = Double(index % 3)
            clip.waveform = [0.1, 0.4, 0.2]
            clip.audioFile = AudioFile(path: "fixture.wav")
            clip.gain = 0.75; clip.fadeIn = 0.25; clip.fadeOut = 0.5; clip.playbackRate = 1.1
            if index % 2 == 0 { clip.loopStart = 1; clip.loopLength = 3 }
            return clip
        }
        return track
    }
    song.tracks[0].clips[2].frozenMIDI = true
    song.tracks[0].clips[3].renderedTiming = true
    song.tracks[0].solo = true
    return song
}

func metadataKey(_ song: Song, revision: UInt64 = 1, project: UUID) -> TimelineRenderKey {
    TimelineRenderKey(revision: revision, songID: song.id, movingClip: nil, movingStart: 0,
        movingTrack: nil, movingRegion: nil, regionDelta: 0, resizingRegion: nil,
        resizedStart: 0, resizedEnd: 0, projectID: project)
}

MainActor.assumeIsolated {
    let song = metadataSong(), project = UUID()
    let key = metadataKey(song, project: project)
    let cache = TimelineRenderMetadataCache()
    TimelineMetadataWorkProbe.reset()
    let metadata = cache.metadata(song: song, key: key)
    precondition(TimelineMetadataWorkProbe.counts == (0, 0), "constructing a snapshot must not segment offscreen clips")
    precondition(metadata.hasSolo && metadata.affectsAudio && !metadata.hasClickTrack)
    precondition(metadata.regionParentIDs == Set(song.parts.compactMap(\.parentRegionID)))
    let visible = song.tracks.flatMap { Array($0.clips.prefix(4)) }
    let sections = song.tempoSections(until: song.duration)
    let expected = visible.map { song.tempoAudioSegments($0, sections: sections) }
    TimelineMetadataWorkProbe.reset()
    for (index, clip) in visible.enumerated() {
        precondition(metadata.fragments(for: clip) == expected[index])
    }
    precondition(TimelineMetadataWorkProbe.counts == (1, visible.count))
    for frame in 0..<80 {
        let reused = cache.metadata(song: song, key: key)
        precondition(reused === metadata, "zoom-only changes retain the same snapshot")
        let scale = pow(1.065, Double(frame))
        for (index, clip) in visible.enumerated() {
            let fragments = reused.fragments(for: clip)
            precondition(fragments == expected[index])
            precondition(fragments.map { $0.startTime * scale } == expected[index].map { $0.startTime * scale })
        }
        precondition(reused.sections(until: song.duration) == sections)
    }
    precondition(TimelineMetadataWorkProbe.counts == (1, visible.count), "repeated zoom frames perform no additional tempo work")

    // A separate one-entry preview cache keeps the unchanged base item hot.
    var preview = visible[0]
    for gain in [0.1, 0.5, 1.8, 0.0] {
        preview.gain = gain
        let expectedPreview = song.tempoAudioSegments(preview, sections: sections)
        precondition(metadata.fragments(for: preview, preview: true) == expectedPreview)
        let before = TimelineMetadataWorkProbe.counts
        precondition(metadata.fragments(for: preview, preview: true) == expectedPreview)
        precondition(metadata.fragments(for: visible[0]) == expected[0])
        precondition(TimelineMetadataWorkProbe.counts == before)
    }
    preview.sourceOffset += 2
    preview.playbackRate = 0.8
    preview.loopLength = 2
    precondition(metadata.fragments(for: preview, preview: true) == song.tempoAudioSegments(preview, sections: sections))

    var edited = song
    edited.markers![1].tempoBPM = 210
    edited.parts[0].startTime = 2
    edited.tracks[0].clips[0].sourceOffset = 5
    let editedKey = metadataKey(edited, revision: 2, project: project)
    let changed = cache.metadata(song: edited, key: editedKey)
    precondition(changed !== metadata)
    let editedSections = edited.tempoSections(until: edited.duration)
    precondition(changed.fragments(for: edited.tracks[0].clips[0]) == edited.tempoAudioSegments(edited.tracks[0].clips[0], sections: editedSections))
    precondition(metadata.fragments(for: visible[0]) == expected[0], "old Canvas callbacks retain the old content snapshot")

    var moved = edited
    moved.parts[0].endTime += 3
    moved.tracks[0].clips[0].startTime += 4
    var moveKey = editedKey
    moveKey.resizingItem = visible[0].id
    moveKey.itemStart = moved.tracks[0].clips[0].startTime
    moveKey.itemEnd = moveKey.itemStart + moved.tracks[0].clips[0].duration
    let moving = cache.metadata(song: moved, key: moveKey)
    precondition(moving !== changed)
    precondition(moving.fragments(for: moved.tracks[0].clips[0]) == moved.tempoAudioSegments(moved.tracks[0].clips[0], sections: moved.tempoSections(until: moved.duration)))

    // Duplicated projects can preserve song/clip UUIDs and revision numbers.
    let duplicateBase = cache.metadata(song: edited, key: editedKey)
    let otherProject = cache.metadata(song: edited, key: metadataKey(edited, revision: 2, project: UUID()))
    precondition(otherProject !== duplicateBase)
    var otherSong = edited; otherSong.id = UUID(); otherSong.bpm = 93
    let songBase = cache.metadata(song: edited, key: editedKey)
    let switched = cache.metadata(song: otherSong, key: editedKey)
    precondition(switched !== songBase)
    precondition(switched.sections(until: otherSong.duration) == otherSong.tempoSections(until: otherSong.duration))

    var free = song
    free.markers = nil
    let freeMetadata = TimelineRenderMetadata(song: free)
    precondition(freeMetadata.fragments(for: visible[0]) == [visible[0]])
    let extent = song.duration + 600
    precondition(metadata.sections(until: extent) == song.tempoSections(until: extent))
    precondition(metadata.sections(until: song.duration) == sections)

    // Concurrent render callbacks and old/new generations must remain isolated.
    let parallel = TimelineRenderMetadata(song: song)
    TimelineMetadataWorkProbe.reset()
    DispatchQueue.concurrentPerform(iterations: 64) { iteration in
        let index = iteration % visible.count
        precondition(parallel.fragments(for: visible[index]) == expected[index])
        precondition(parallel.sections(until: song.duration) == sections)
    }
    precondition(TimelineMetadataWorkProbe.counts == (1, visible.count))
    print("TIMELINE_METADATA_LAZY_ZOOM_PARITY_PREVIEW_EDITS_TEMPO_PROJECT_SWITCH_CONCURRENT_CANVAS_OK")

    let frames = 80
    TimelineMetadataWorkProbe.reset()
    let oldStart = ProcessInfo.processInfo.systemUptime
    var oldChecksum = 0.0
    for frame in 0..<frames {
        let repeatedSections = song.tempoSections(until: song.duration)
        for clip in visible {
            oldChecksum += song.tempoAudioSegments(clip, sections: repeatedSections).reduce(0) { $0 + $1.sourceOffset + $1.duration * Double(frame + 1) }
        }
    }
    let oldTime = ProcessInfo.processInfo.systemUptime - oldStart
    let oldWork = TimelineMetadataWorkProbe.counts
    TimelineMetadataWorkProbe.reset()
    let next = TimelineRenderMetadata(song: song)
    let newStart = ProcessInfo.processInfo.systemUptime
    var newChecksum = 0.0
    for frame in 0..<frames {
        _ = next.sections(until: song.duration)
        for clip in visible {
            newChecksum += next.fragments(for: clip).reduce(0) { $0 + $1.sourceOffset + $1.duration * Double(frame + 1) }
        }
    }
    let newTime = ProcessInfo.processInfo.systemUptime - newStart
    precondition(oldChecksum == newChecksum)
    precondition(oldWork == (frames, frames * visible.count))
    precondition(TimelineMetadataWorkProbe.counts == (1, visible.count))
    print(String(format: "TIMELINE_METADATA_BENCHMARK frames=%d visible=%d project_clips=%d old_ms=%.3f cached_ms=%.3f speedup=%.1fx old_segments=%d cached_segments=%d",
        frames, visible.count, song.tracks.reduce(0) { $0 + $1.clips.count }, oldTime * 1000, newTime * 1000, oldTime / max(newTime, 1e-9), oldWork.fragments, TimelineMetadataWorkProbe.counts.fragments))
}
