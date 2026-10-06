#if os(macOS)
import XCTest
@testable import JarasApplication

final class ReaperProjectImportTests: XCTestCase {
    private func fixture(_ text: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Migration.rpp")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func testTrackMixerVolumePanMuteIncludingFoldersSurvivesSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture("""
        <REAPER_PROJECT 0.1 "7.0" 1
          <TRACK
            NAME "Folder"
            ISBUS 1 1
            VOLPAN 0.5 -1 1 -1
            MUTESOLO 1 0
          >
          <TRACK
            NAME "Boosted right"
            ISBUS 2 -1
            VOLPAN 1.9952623149688795 1 1 -1
            MUTESOLO 0 0
          >
          <TRACK
            NAME "Silent center"
            VOLPAN 0 0 1 -1
            MUTESOLO 0 0
          >
          <TRACK
            NAME "Partial balance"
            VOLPAN 0.125 0.35 1 -1
            MUTESOLO 1 0
          >
          <TRACK
            NAME "Default controls"
          >
        >
        """, in: directory)
        let original = try Data(contentsOf: url)
        let result = try ReaperProjectImporter.read(url)
        let tracks = result.project.songs[0].tracks
        XCTAssertEqual(tracks.map(\.volume), [0.5, 1.9952623149688795, 0, 0.125, 1])
        XCTAssertEqual(tracks.map(\.pan), [-1, 1, 0, 0.35, 0])
        XCTAssertEqual(tracks.map(\.mute), [true, false, false, true, false])
        XCTAssertEqual(tracks[1].parentTrackID, tracks[0].id)
        let destination = directory.appendingPathComponent("Mixer.jl")
        try ProjectMigration.save(result, to: destination)
        let loaded = try await ProjectStore(url: destination).load()
        XCTAssertEqual(loaded, result.project)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOfflineArrangementAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(#"""
        <REAPER_PROJECT 0.1 "7.0" 1
          TEMPO 120 4 4
          MARKER 1 2 "Whole song" 1 16777471
          MARKER 1 12 "" 1
          MARKER 2 4 "Verse" 1
          MARKER 2 8 "" 1
          MARKER 1 3 "Cue" 0
          <TEMPOENVEX
            PT 0 120 1 262148
            PT 6 100 1
          >
          <TRACK
            NAME "Band"
            ISBUS 1 1
          >
          <TRACK
            NAME `Nested group`
            ISBUS 1 1
          >
          <TRACK
            NAME 'Guitar'
            ISBUS 2 -2
            VOLPAN 0.5 -0.25
            MUTESOLO 1 0
            <ITEM
              POSITION 4.25
              LENGTH 6.5
              SOFFS 1.125
              PLAYRATE 1.25 1 -3.25
              VOLPAN 0.8 0 2 -1
              MUTE 1
              NAME "Guitar item"
              FADEIN 1 0.1
              FADEOUT 1 0.2
              CHANMODE 3
              <SOURCE WAVE
                FILE "C:\Show\Guitar stereo.wav"
              >
            >
          >
        >
        """#, in: directory)
        let original = try Data(contentsOf: url)
        let result = try ReaperProjectImporter.read(url)
        let song = result.project.songs[0]
        XCTAssertEqual(song.tracks.count, 3)
        XCTAssertEqual(song.tracks[1].parentTrackID, song.tracks[0].id)
        XCTAssertEqual(song.tracks[2].parentTrackID, song.tracks[0].id)
        XCTAssertEqual(song.tracks[2].volume, 0.5)
        XCTAssertEqual(song.tracks[2].pan, -0.25)
        XCTAssertTrue(song.tracks[2].mute)
        let clip = try XCTUnwrap(song.tracks[2].clips.first)
        XCTAssertEqual(clip.startTime, 4.25)
        XCTAssertEqual(clip.duration, 6.5)
        XCTAssertEqual(clip.pitchSemitones, -3.25)
        XCTAssertEqual(clip.sourceOffset, 1.125)
        XCTAssertEqual(clip.audioRate, 1.25)
        XCTAssertEqual(clip.gain, 1.6)
        XCTAssertEqual(clip.channelMode, 1)
        XCTAssertEqual(clip.muted, true)
        XCTAssertEqual(song.parts.map(\.name), ["Whole song", "Cue", "Verse"])
        XCTAssertEqual(song.parts[1].parentRegionID, song.parts[0].id)
        XCTAssertEqual(song.markers?.filter { !$0.isTempo }.first?.position, 3)
        XCTAssertEqual(song.markers?.filter(\.isTempo).map(\.tempoBPM), [120, 100])
        let destination = directory.appendingPathComponent("CatLive.jl")
        try ProjectMigration.save(result, to: destination)
        let loaded = try await ProjectStore(url: destination).load()
        XCTAssertEqual(loaded, result.project)
        var timing = result.project
        GlobalProjectTiming(bpm: 180).applyOnOpen(to: &timing)
        XCTAssertEqual(timing, result.project)
        XCTAssertEqual(ProjectAudioRecovery.missingPaths(in: result.project, directory: directory), [clip.audioFile!.path])
        let search = directory.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        let bytes = Data("audio".utf8)
        try bytes.write(to: search.appendingPathComponent("Guitar stereo.wav"))
        let restored = try ProjectAudioRecovery.restore(result.project, directory: directory, searching: search)
        XCTAssertTrue(restored.remaining.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(clip.audioFile!.path)), bytes)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try ProjectMigration.save(result, to: destination))
    }
    func testSelectedTakeMediaCopyAndIndependentSameNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture("""
        <REAPER_PROJECT 0.1
          <TRACK
            NAME Guitar
            <ITEM
              POSITION 2
              LENGTH 5
              NAME old
              <SOURCE WAVE
                FILE "old/Guitar.wav"
              >
              TAKE SEL
              NAME active
              SOFFS 3
              <SOURCE WAVE
                FILE "Media/Guitar.wav"
              >
            >
            <ITEM
              POSITION 10
              LENGTH 2
              <SOURCE WAVE
                FILE "Missing/Guitar.wav"
              >
            >
          >
        >
        """, in: directory)
        let audio = directory.appendingPathComponent("Media/Guitar.wav")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("original".utf8); try bytes.write(to: audio)
        let result = try ReaperProjectImporter.read(url)
        let clips = result.project.songs[0].tracks[0].clips
        XCTAssertEqual(clips[0].name, "active")
        XCTAssertEqual(clips[0].sourceOffset, 3)
        XCTAssertEqual(result.media.count, 2)
        XCTAssertNotEqual(clips[0].audioFile, clips[1].audioFile)
        XCTAssertEqual(result.media.filter { $0.source != nil }.count, 1)
        let destination = directory.appendingPathComponent("Out.jl")
        try ProjectMigration.save(result, to: destination)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(clips[0].audioFile!.path)), bytes)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertEqual(ProjectAudioRecovery.missingPaths(in: result.project, directory: directory), [clips[1].audioFile!.path])
    }
    func testRejectsMalformedInputWithoutCreatingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for text in ["<REAPER_PROJECT\n<TRACK\n>", "<REAPER_PROJECT\nNAME \"broken\n>", "<REAPER_PROJECT\nTEMPO 120 1e200 4\n>", "<REAPER_PROJECT\n<TRACK\n<ITEM\nPOSITION nan\nLENGTH 1\n>\n>\n>", "<REAPER_PROJECT\nMARKER 1 2 intro 1\n>"] {
            let source = try fixture(text, in: directory)
            XCTAssertThrowsError(try ReaperProjectImporter.read(source), text)
        }
    }
    func testSpecialRegionsAndOneFlagPerPosition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture("""
        <REAPER_PROJECT 0.1
          MARKER 1 0 "Medley by markers" 1
          MARKER 1 20 "" 1
          MARKER 1 0 "First full song name" 0
          MARKER 2 0 "First full song name" 0
          MARKER 3 0 "Conflicting name" 0
          MARKER 4 8 "Second song" 0
          MARKER 5 8.0000001 "Second song" 0
          MARKER 6 20 "Medley by regions" 1
          MARKER 6 40 "" 1
          MARKER 7 20 "Child A" 1
          MARKER 7 30 "" 1
          MARKER 8 30 "Child B" 1
          MARKER 8 40 "" 1
          MARKER 10 20 "Duplicate child flag" 0
          MARKER 11 30 "Child B" 0
          MARKER 12 30 "Child B" 0
          MARKER 13 40 "Outside" 0
          MARKER 14 40 "Outside duplicate" 0
        >
        """, in: directory)
        let result = try ReaperProjectImporter.read(source)
        let song = result.project.songs[0]
        let roots = song.parts.filter { $0.parentRegionID == nil }
        XCTAssertEqual(roots.map(\.name), ["Medley by markers", "Medley by regions"])
        let first = song.parts.filter { $0.parentRegionID == roots[0].id }
        XCTAssertEqual(first.map(\.name), ["First full song name", "Second song"])
        XCTAssertEqual(first.map(\.startTime), [0, 8])
        XCTAssertEqual(first.map(\.endTime), [8, 20])
        let second = song.parts.filter { $0.parentRegionID == roots[1].id }
        XCTAssertEqual(second.map(\.name), ["Child A", "Child B"])
        let markers = song.markers ?? []
        XCTAssertEqual(markers.map(\.position), [0, 8, 20, 30, 40])
        XCTAssertEqual(markers.map(\.name), ["First full song name", "Second song", "Child A", "Child B", "Outside"])
        XCTAssertEqual(markers.filter { $0.sourceRegionID != nil }.count, 4)
        for marker in markers where marker.sourceRegionID != nil {
            let child = try XCTUnwrap(song.parts.first { $0.id == marker.sourceRegionID })
            XCTAssertEqual(marker.unifiedRegionID, child.parentRegionID)
        }
        var disunified = result.project
        _ = try disunified.disunifyRegion(roots[0].id)
        XCTAssertTrue(disunified.songs[0].parts.contains { $0.name == "First full song name" && $0.parentRegionID == nil })
    }
    func testSpecialTracksNotesMediaAndRegeneratedTimecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture("""
        <REAPER_PROJECT 0.1
          <TRACK
            NAME "Teleprompt 1"
            <ITEM
              POSITION 2
              LENGTH 4
              <NOTES
                |Primeira linha
                |Segunda linha
              >
            >
            <ITEM
              POSITION 2
              LENGTH 5
            >
            <ITEM
              POSITION 2
              LENGTH 4
              <SOURCE VIDEO
                FILE "Missing/image.png"
              >
            >
          >
          <TRACK
            NAME TELEPROMPT2
            <ITEM
              POSITION 8
              LENGTH 2
              <NOTES
                |Texto do segundo TP
              >
            >
          >
          <TRACK
            NAME MEDIA
            <ITEM
              POSITION 3
              LENGTH 8
              SOFFS 1.5
              <SOURCE VIDEO
                FILE "Missing/video.mp4"
              >
            >
          >
          <TRACK
            NAME CIFRAS
            <ITEM
              POSITION 4
              LENGTH 2
              <NOTES
                |C#m7
              >
            >
          >
          <TRACK
            NAME TIMECODE
            <ITEM
              POSITION 5
              LENGTH 7
              SOFFS 2
              <SOURCE LTC
                STARTTIME 3600
                FRAMERATE 25 0
                SEND 2
                USERDATA 0 0 0 0
              >
            >
            <ITEM
              POSITION 20
              LENGTH 9
              <SOURCE LTC
                STARTTIME 7200
                FRAMERATE 30 0
                SEND 1
                USERDATA 0 0 0 0
              >
            >
          >
        >
        """, in: directory)
        let result = try ReaperProjectImporter.read(source)
        let tracks = result.project.songs[0].tracks
        XCTAssertEqual(tracks.map(\.kind), [.timecode, .chords, .teleprompt, .teleprompt2, .standard])
        XCTAssertEqual(tracks[2].clips.count, 2, "remove only empty placeholders overlapping actual content")
        XCTAssertEqual(tracks[2].clips[0].text, "Primeira linha\nSegunda linha")
        XCTAssertEqual(tracks[3].clips[0].text, "Texto do segundo TP")
        XCTAssertEqual(tracks[1].clips[0].text, "C#m7")
        XCTAssertTrue(tracks[2].clips[1].isProjectionMedia)
        XCTAssertTrue(tracks[4].clips[0].isProjectionMedia)
        XCTAssertEqual(tracks[4].clips[0].sourceOffset, 1.5)
        let timecode = tracks[0]
        XCTAssertEqual(timecode.importedTimecodeItems, true)
        XCTAssertEqual(timecode.clips.map(\.startTime), [5, 20])
        XCTAssertEqual(timecode.clips.map(\.duration), [7, 9])
        XCTAssertEqual(timecode.clips.map { $0.timecode?.mode }, ["mtc", "ltc"])
        XCTAssertEqual(timecode.clips.map { $0.timecode?.frameRate }, [25, 30])
        XCTAssertEqual(timecode.clips.map { $0.timecode?.offset }, [3602, 7200])
        XCTAssertTrue(timecode.clips.allSatisfy { $0.audioFile == nil && $0.sourceOffset == 0 })
        XCTAssertEqual(ProjectAudioRecovery.missingPaths(in: result.project, directory: directory).count, 2)
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(result.project)), result.project)
        var resized = result.project
        resized.resizeItem(timecode.clips[0].id, start: 4, end: 14)
        XCTAssertEqual(resized.songs[0].tracks[0].clips[0].startTime, 4)
        XCTAssertEqual(resized.songs[0].tracks[0].clips[0].duration, 10)
        XCTAssertEqual(resized.songs[0].tracks[0].clips[0].timecode, timecode.clips[0].timecode)
    }
    func testRealProjectsWhenProvided() throws {
        guard let files = ProcessInfo.processInfo.environment["JARAS_REAPER_FIXTURES"] else { return }
        for path in files.components(separatedBy: "\n") where !path.isEmpty {
            let source = URL(fileURLWithPath: path)
            let original = try Data(contentsOf: source)
            let result = try ReaperProjectImporter.read(source)
            try result.project.validate()
            let song = result.project.songs[0]
            XCTAssertFalse(song.tracks.isEmpty)
            XCTAssertFalse(song.parts.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), original)
            print("RPP fixture: \(source.lastPathComponent): \(song.tracks.count) tracks, \(song.tracks.flatMap(\.clips).count) items, \(song.parts.count) regions, \(song.markers?.count ?? 0) markers, \(result.media.count) files")
        }
    }
}
#endif
