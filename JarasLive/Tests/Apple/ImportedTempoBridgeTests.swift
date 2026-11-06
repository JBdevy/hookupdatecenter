import Foundation

@main struct ImportedTempoBridgeTests {
    @MainActor static func main() throws {
        var fixture = Project.empty(name: "Imported tempo")
        fixture.importedTimeline = true
        fixture.songs[0].bpm = 140
        fixture.songs[0].markers = [
            TimelineMarker(id: UUID(), name: "140", position: 0, color: 0,
                tempoBPM: 140, tempoTimebase: .global, tempoReferenceBPM: 140),
            TimelineMarker(id: UUID(), name: "160", position: 10, color: 0,
                tempoBPM: 160, tempoTimebase: .global, tempoReferenceBPM: 160)
        ]
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Normal", startTime: 0, duration: 8,
                                audioFile: AudioFile(path: "Stems/normal.wav")),
                       AudioClip(id: UUID(), name: "Intentional rate", startTime: 10, duration: 8,
                                 audioFile: AudioFile(path: "Stems/rate.wav"))]
        track.clips[1].playbackRate = 1.25
        fixture.songs[0].tracks = [track]
        var fixtures = [fixture]
        if let path = ProcessInfo.processInfo.environment["JARAS_REAPER_UNITY_RATE_FIXTURE"] {
            fixtures.append(try ReaperProjectImporter.read(URL(fileURLWithPath: path)).project)
        }
        for source in fixtures {
            let executor = LocalCommandExecutor()
            var opened = source
            let originalSong = source.songs[0]
            let originalClips = originalSong.tracks.flatMap(\.clips)
            for pass in 0..<3 {
                try executor.load(opened)
                let snapshot = try executor.snapshot()
                opened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(snapshot.project))
                GlobalProjectTiming(bpm: 120).applyOnOpen(to: &opened)
                let song = opened.songs[0], clips = song.tracks.flatMap(\.clips)
                guard opened.importedTimeline == true, song.bpm == originalSong.bpm else {
                    print("FAIL: imported timeline lost after core/save/reopen; pass=\(pass), BPM=\(song.bpm), first rate=\(clips.first?.audioRate ?? 0)")
                    exit(1)
                }
                precondition(clips.count == originalClips.count)
                let sections = song.tempoSections(until: song.duration)
                for (clip, original) in zip(clips, originalClips) {
                    precondition(clip.startTime == original.startTime && clip.duration == original.duration)
                    precondition(clip.sourceOffset == original.sourceOffset && clip.audioRate == original.audioRate)
                    for segment in song.tempoAudioSegments(clip, sections: sections) {
                        precondition(abs(segment.audioRate - original.audioRate) < 1e-9)
                    }
                }
                // A metadata edit must not drop the flag either.
                try executor.applyProjectEdit(opened)
                opened = try executor.snapshot().project
            }
            print("PASS: core, edits and three save/reopen cycles preserve \(originalClips.count) items at original rates: \(source.name)")
        }
        for imported in [nil, false] as [Bool?] {
            var local = Project.empty(name: "Ordinary project")
            local.importedTimeline = imported
            let executor = LocalCommandExecutor()
            try executor.load(local)
            let snapshot = try executor.snapshot()
            precondition(snapshot.project.importedTimeline == imported)
        }
    }
}
