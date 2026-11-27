import XCTest
import AVFoundation
@testable import JarasApplication

final class StemImportTests: XCTestCase {
    func testImportedTracksUseTheirInstrumentIconAndKeepAnExistingCustomIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try fixture(root, folder: "First", file: "Rhodes.wav")
        _ = try fixture(root, folder: "First", file: "An unclassified take.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        var project = try StemProjectImporter.build(scan: StemProjectImporter.scan([initial]), remove: "",
            base: .empty(name: "Icons"), destination: destination)
        let index = try XCTUnwrap(project.songs[0].tracks.firstIndex(where: { $0.name == "Rhodes" }))
        XCTAssertEqual(project.songs[0].tracks[index].instrumentIcon, "png:Keyboards/electric-piano")
        XCTAssertEqual(project.songs[0].tracks.first(where: { $0.name.hasPrefix("Out") })?.instrumentIcon, "png:Other/waveform")
        project.songs[0].tracks[index].instrumentIcon = "png:Other/dynamic-mic"
        let next = try fixture(root, folder: "Second", file: "Rhodes.wav")
        _ = try fixture(root, folder: "Second", file: "Cagueite.wav")
        project = try StemProjectImporter.build(scan: StemProjectImporter.scan([next]), remove: "",
            base: project, destination: destination)
        XCTAssertEqual(project.songs[0].tracks.first(where: { $0.name == "Rhodes" })?.instrumentIcon, "png:Other/dynamic-mic")
        XCTAssertEqual(project.songs[0].tracks.first(where: { $0.name == "Regência" })?.instrumentIcon, "png:Other/dynamic-mic")
    }

    func testSavedProjectFolderIsRecognizedInAddStems() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ProjectDocumentCodec.encode(.empty(name: "Saved")).write(to: folder.appendingPathComponent("Saved.jl"))
        XCTAssertThrowsError(try StemProjectImporter.scan([folder])) { error in
            XCTAssertEqual(error.localizedDescription, "\(folder.lastPathComponent): contains a CatLive project")
        }
    }
    func testScanSilentlySkipsUnreadableAndUnsupportedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Valid.wav")
        try Data("broken audio".utf8).write(to: folder.appendingPathComponent("Broken.mp3"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
        let scan = try StemProjectImporter.scan([folder])
        XCTAssertTrue(scan.warnings.isEmpty)
        XCTAssertEqual(scan.folders.count, 1)
        XCTAssertEqual(scan.folders[0].files.map(\.name), ["Valid.wav"])
    }

    func testAddStemsImportsPortableLyricsAsMediaWithoutCreatingAnAudioTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Song")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let columns = ItemTextColors.encodeColumns(["Verso", "Refrão"])
        let item = AudioClip(id: UUID(), name: "Lyrics", startTime: 2, duration: 9, text: columns)
        try JSONEncoder().encode(JLLyricsDocument(teleprompter: 2, clips: [item], origin: 0))
            .write(to: source.appendingPathComponent("LyricsPrompter2 - Song.jllyrics"))
        let project = try StemProjectImporter.build(scan: StemProjectImporter.scan([source]), remove: "",
            base: .empty(name: "Import"), destination: root.appendingPathComponent("Project/Show.jl"))
        let song = project.songs[0]
        XCTAssertEqual(song.parts.count, 1)
        let region = try XCTUnwrap(song.parts.first)
        XCTAssertEqual(region.endTime - region.startTime, 11)
        XCTAssertTrue(song.tracks.allSatisfy { $0.kind != .standard })
        let clip = try XCTUnwrap(song.tracks.first(where: { $0.kind == .teleprompt2 })?.clips.first)
        XCTAssertEqual(clip.text, columns)
        XCTAssertEqual(clip.startTime, region.startTime + 2)
        XCTAssertEqual(clip.regionOwnerID, region.id)
        try project.validate()
    }

    func testMultitrackManifestRestoresMediaAndLyricsRelativeToEachNewRegion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports")
        let images = Data([1, 2, 3])
        let exporter = Project.empty(name: "Source")
        let videoID = UUID()
        let lyricID = UUID()
        let formatted = ItemTextColors.encodeColumns(["Coro", "Verso"])
        var source = exporter.songs[0]
        let first = Part(id: UUID(), name: "Primeira canção", startTime: 82, endTime: 106, color: 0xabcdef,
                         uppercaseName: false, pitchSemitones: 2, pitchTrackIDs: [videoID])
        let second = Part(id: UUID(), name: "Segunda canção", startTime: 132, endTime: 156, color: 0x321abc)
        source.parts = [first, second]
        source.markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 82, color: 0, tempoBPM: 147),
                          TimelineMarker(id: UUID(), name: "TEMPO", position: 94, color: 0, tempoBPM: 140)]
        for part in source.parts {
            let folder = exports.appendingPathComponent(part.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try images.write(to: folder.appendingPathComponent("cena.png"))
            var video = Track(id: videoID, name: "Cenas", role: .other, volume: 0.5, color: 0x908611)
            video.outputs = [OutputPatch(firstChannel: 2, channelCount: 1)]
            video.clips = [AudioClip(id: UUID(), name: "Cena", startTime: part.startTime - 2, duration: 9,
                sourceOffset: 1.5, audioFile: AudioFile(path: "Videos/cena.png"), gain: 0.72, pan: -0.3, playbackRate: 0.92)]
            var lyrics = Track(id: lyricID, name: "Teleprompter 2", role: TrackRole(rawValue: TrackKind.teleprompt2.rawValue))
            lyrics.clips = [AudioClip(id: UUID(), name: "Letra", startTime: part.startTime + 6, duration: 7, text: formatted)]
            let data = try MultitrackRegionData.snapshot(song: source, region: part, tracks: [video, lyrics], renderedStems: [], lyricsFiles: [])
            XCTAssertEqual(data.region.startTime, 2)
            try JSONEncoder().encode(data).write(to: folder.appendingPathComponent(".jldata-" + part.name))
        }
        var destination = Project.empty(name: "Target")
        destination.songs[0].parts = [Part(id: UUID(), name: "Existing", startTime: 0, endTime: 12)]
        let scan = try StemProjectImporter.scan([exports])
        XCTAssertEqual(scan.folders.count, 2)
        let result = try StemProjectImporter.build(scan: scan, remove: "canção", base: destination,
            destination: root.appendingPathComponent("Project/Show.jl"))
        let song = result.songs[0]
        XCTAssertEqual(song.parts.map(\.name), ["Existing", first.name, second.name])
        XCTAssertEqual(song.parts[1].color, first.color)
        XCTAssertEqual(song.parts[1].pitchSemitones, 2)
        XCTAssertEqual(song.parts[1].endTime - song.parts[1].startTime, 24, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(song.parts[1].startTime - 2, 12)
        XCTAssertGreaterThanOrEqual(song.parts[2].startTime - 2, song.parts[1].endTime)
        let scenes = try XCTUnwrap(song.tracks.first { $0.id == videoID })
        XCTAssertEqual(scenes.outputPatches, [OutputPatch(firstChannel: 2, channelCount: 1)])
        XCTAssertEqual(scenes.volume, 0.5)
        XCTAssertEqual(scenes.clips.count, 2)
        for (clip, region) in zip(scenes.clips, song.parts.dropFirst()) {
            XCTAssertEqual(clip.startTime, region.startTime - 2, accuracy: 1e-9)
            XCTAssertEqual(clip.duration, 9)
            XCTAssertEqual(clip.sourceOffset, 1.5)
            XCTAssertEqual(clip.audioRate, 0.92)
            XCTAssertEqual(clip.gain, 0.72)
            XCTAssertEqual(clip.pan, -0.3)
            XCTAssertEqual(clip.regionOwnerID, region.id)
        }
        let lyrics = try XCTUnwrap(song.tracks.first { $0.kind == .teleprompt2 })
        for (clip, region) in zip(lyrics.clips, song.parts.dropFirst()) {
            XCTAssertEqual(clip.startTime, region.startTime + 6)
            XCTAssertEqual(clip.text, formatted)
        }
        let tempos = try XCTUnwrap(song.markers).filter { $0.regionOwnerID == song.parts[1].id }
        XCTAssertEqual(tempos.map(\.tempoBPM), [147, 140])
        XCTAssertEqual(tempos.last!.position, song.parts[1].startTime + 12, accuracy: 1e-9)
        try result.validate()
    }

    func testMultitrackDrawerRecreatesSongsAndKeepsIndividualAudioPositionsAndTuner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drawerFolder = root.appendingPathComponent("Seleção")
        let parent = Part(id: UUID(), name: "Seleção", startTime: 30, endTime: 50, color: 0x661199, pitchSemitones: 2)
        let first = Part(id: UUID(), name: "A", startTime: 30, endTime: 40, parentRegionID: parent.id, pitchSemitones: -3)
        let next = Part(id: UUID(), name: "B", startTime: 40, endTime: 50, parentRegionID: parent.id)
        let sourceGroup = Track(id: UUID(), name: "Grupo original", role: .other)
        let sourceTrack = Track(id: UUID(), name: "Pandeirola", role: .drums, parentTrackID: sourceGroup.id)
        var programTrack = Track(id: UUID(), name: "Program Change", role: TrackRole(rawValue: TrackKind.programChange.rawValue))
        programTrack.programChanges = [ProgramChangeMarker(id: UUID(), position: 35, program: 12, channel: 2)]
        var source = Project.empty(name: "Origem").songs[0]
        source.parts = [parent, first, next]
        let nextSection = TimelineMarker(id: UUID(), name: "Entrada", position: 43, color: 3, section: true)
        var section = TimelineMarker(id: UUID(), name: "Refrão", position: 34, color: 1, section: true)
        section.automaticSectionTargetID = nextSection.id
        section.automaticSectionRepeatCount = 2
        let tempo = TimelineMarker(id: UUID(), name: "TEMPO", position: 32, color: 0, tempoBPM: 110)
        source.markers = [section, TimelineMarker(id: UUID(), name: "Sinal", position: 36, color: 2), nextSection, tempo]
        let items = [
            MultitrackRegionData.RenderedStem.Item(offset: -1, duration: 3, rate: 1.1, pitchSemitones: -2),
            MultitrackRegionData.RenderedStem.Item(offset: 7, duration: 4, rate: 1, pitchSemitones: 4),
            MultitrackRegionData.RenderedStem.Item(offset: 1, duration: 2, rate: 1.25, pitchSemitones: 1)
        ]
        var entries: [MultitrackDrawerData.Entry] = []
        for (index, part) in [first, next].enumerated() {
            let stems = try (index == 0 ? [0, 1] : [2]).enumerated().map { ordinal, itemIndex in
                let name = "Pandeirola – " + part.name + String(format: " %03d.wav", ordinal + 1)
                _ = try fixture(drawerFolder, folder: part.name, file: name, seconds: items[itemIndex].duration)
                return MultitrackRegionData.RenderedStem(file: name, track: sourceTrack.id, items: [items[itemIndex]])
            }
            let data = try MultitrackRegionData.snapshot(song: source, region: part, tracks: [sourceGroup, sourceTrack, programTrack],
                renderedStems: stems, lyricsFiles: [], fullItems: true, tunerUnbaked: true)
            XCTAssertTrue(data.renderedStems.flatMap(\.items).allSatisfy { $0.pitchSemitones == nil })
            XCTAssertFalse(data.arrangement.markers?.contains(where: \.isTempo) == true)
            entries.append(.init(folder: part.name, offset: part.startTime - parent.startTime,
                                 cue: index == 0 ? 0 : 10.5, data: data, cueID: UUID(), cueName: "Bandeira " + part.name, cueColor: 0x123456))
        }
        let manifest = MultitrackDrawerData(version: 2, name: parent.name, duration: 20,
            color: parent.color, uppercaseName: false, entries: entries, pitchSemitones: parent.pitchSemitones)
        try JSONEncoder().encode(manifest).write(to: drawerFolder.appendingPathComponent(".jldata-Seleção"))
        let project = try StemProjectImporter.build(scan: StemProjectImporter.scan([drawerFolder]), remove: "",
            base: .empty(name: "Import"), destination: root.appendingPathComponent("Project/Show.jl"))
        let song = project.songs[0]
        let drawer = try XCTUnwrap(song.parts.first { $0.parentRegionID == nil })
        XCTAssertEqual(drawer.name, parent.name)
        XCTAssertEqual(drawer.color, parent.color)
        XCTAssertEqual(drawer.pitchSemitones, 2)
        XCTAssertEqual(drawer.endTime - drawer.startTime, 20)
        let children = song.parts.filter { $0.parentRegionID == drawer.id }.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(children.map(\.name), [first.name, next.name])
        XCTAssertEqual(children.map { $0.startTime - drawer.startTime }, [0, 10])
        XCTAssertEqual(children[0].pitchSemitones, -3)
        XCTAssertNil(children[0].pitchTrackIDs)
        XCTAssertNil(children[0].pitchGroupIDs)
        let marker = try XCTUnwrap(song.markers?.first { $0.sourceRegionID == children[1].id })
        XCTAssertEqual(marker.position - drawer.startTime, 10.5)
        XCTAssertEqual(marker.name, "Bandeira B")
        XCTAssertEqual(marker.color, 0x123456)
        let sourceMarker = try XCTUnwrap(song.markers?.first { $0.name == "Refrão" })
        let targetMarker = try XCTUnwrap(song.markers?.first { $0.name == "Entrada" })
        XCTAssertEqual(sourceMarker.position, drawer.startTime + 4)
        XCTAssertEqual(sourceMarker.automaticSectionTargetID, targetMarker.id)
        XCTAssertEqual(sourceMarker.automaticSectionRepeatCount, 2)
        XCTAssertNotEqual(targetMarker.id, nextSection.id)
        XCTAssertEqual(song.markers?.first { $0.name == "Sinal" }?.position, drawer.startTime + 6)
        let track = try XCTUnwrap(song.tracks.first { $0.clips.count == 3 })
        XCTAssertNotNil(track.parentTrackID)
        XCTAssertFalse(song.tracks.contains { $0.id == sourceGroup.id || $0.id == sourceTrack.id })
        let program = song.tracks.first(where: { $0.kind == .programChange })?.programChanges?.first
        XCTAssertEqual(program?.position, drawer.startTime + 5)
        XCTAssertEqual(program?.program, 12)
        let clips = track.clips.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(clips.map { $0.startTime - drawer.startTime }, [-1, 7, 11])
        XCTAssertEqual(clips.map(\.duration), [3, 4, 2])
        XCTAssertTrue(clips.allSatisfy { $0.pitchSemitones == nil && $0.renderedTempo == true })
        XCTAssertFalse(song.markers?.contains(where: \.isTempo) == true)
        XCTAssertEqual(clips.map(\.audioRate), [1, 1, 1])
        XCTAssertEqual(clips.map(\.regionOwnerID), [children[0].id, children[0].id, children[1].id])
        XCTAssertTrue(clips[1].name.hasSuffix("002.wav"))
        try project.validate()
    }

    func testRenderedStemsRestoreTransportTunerOnlyOnMatchingTracks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Mix", file: "Guitar.wav", seconds: 1)
        _ = try fixture(root, folder: "Mix", file: "Bass.wav", seconds: 1)
        let guitar = Track(id: UUID(), name: "Guitar", role: .other)
        let bass = Track(id: UUID(), name: "Bass", role: .other)
        let region = Part(id: UUID(), name: "Mix", startTime: 0, endTime: 1, pitchSemitones: 3,
                          pitchTrackIDs: [guitar.id], pitchGroupIDs: [])
        var source = Project.empty(name: "Source").songs[0]
        source.tracks = [guitar, bass]
        source.parts = [region]
        source.markers = [
            TimelineMarker(id: UUID(), name: "Tempo", position: 0, color: 0, tempoBPM: 140),
            TimelineMarker(id: UUID(), name: "Cue", position: 0.5, color: 1)
        ]
        let manifest = try MultitrackRegionData.snapshot(song: source, region: region, tracks: source.tracks,
            renderedStems: [
                .init(file: "Guitar.wav", track: guitar.id, items: [.init(offset: 0, duration: 1, rate: 1.1, pitchSemitones: -3)]),
                .init(file: "Bass.wav", track: bass.id, items: [.init(offset: 0, duration: 1, rate: 1)])
            ], lyricsFiles: [], fullItems: true, tunerUnbaked: true)
        XCTAssertEqual(manifest.region.pitchTrackIDs, [guitar.id])
        XCTAssertNil(manifest.renderedStems[0].items[0].pitchSemitones)
        XCTAssertEqual(manifest.arrangement.markers?.map(\.name), ["Cue"])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(".jldata-Mix"))

        var base = Project.empty(name: "Destination")
        let destinationGuitar = Track(id: UUID(), name: "Guitarra", role: .other)
        let destinationBass = Track(id: UUID(), name: "Bass", role: .other)
        base.songs[0].tracks = [destinationGuitar, destinationBass]
        let imported = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "",
            base: base, destination: root.appendingPathComponent("Project/Show.jl")).songs[0]
        let importedRegion = try XCTUnwrap(imported.parts.first)
        XCTAssertEqual(imported.tracks.map(\.id), [destinationGuitar.id, destinationBass.id])
        XCTAssertEqual(importedRegion.pitchTrackIDs, [destinationGuitar.id])
        XCTAssertEqual(imported.pitch(for: destinationGuitar.id, region: importedRegion), 3)
        XCTAssertEqual(imported.pitch(for: destinationBass.id, region: importedRegion), 0)
        let item = try XCTUnwrap(imported.tracks[0].clips.first)
        XCTAssertEqual(item.audioRate, 1)
        XCTAssertNil(item.pitchSemitones)
        XCTAssertEqual(imported.markers?.map(\.name), ["Cue"])
    }

    func testLegacyRenderedStemRestoresPitchStoredOutsideTheAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Old")
        _ = try fixture(root, folder: "Old", file: "Pandeirola.wav", seconds: 1)
        var source = Project.empty(name: "Source").songs[0]
        let track = Track(id: UUID(), name: "Pandeirola", role: .drums)
        let part = Part(id: UUID(), name: "Old", startTime: 0, endTime: 1, pitchSemitones: 2)
        source.parts = [part]
        let stems = [MultitrackRegionData.RenderedStem(file: "Pandeirola.wav", track: track.id,
            items: [.init(offset: 0, duration: 1, rate: 1, pitchSemitones: -3)])]
        let snapshot = try MultitrackRegionData.snapshot(song: source, region: part, tracks: [track],
            renderedStems: stems, lyricsFiles: [], tunerUnbaked: true)
        XCTAssertTrue(snapshot.arrangement.markers?.contains(where: \.isTempo) == true)
        let legacy = MultitrackRegionData(version: 1, project: snapshot.project, renderedStems: stems,
            lyricsFiles: [], tunerUnbaked: true)
        try JSONEncoder().encode(legacy).write(to: folder.appendingPathComponent(".jldata-Old"))
        let imported = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "",
            base: .empty(name: "Import"), destination: root.appendingPathComponent("Project/Show.jl"))
        XCTAssertEqual(imported.songs[0].parts.first?.pitchSemitones, 2)
        XCTAssertEqual(imported.songs[0].tracks.flatMap(\.clips).first?.pitchSemitones, -3)
    }

    func testCreateAndAppendNumberStemItemsAcrossTheGridAndPreserveLegacyDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(root, folder: "Song A", file: "Kick.wav")
        let b = try fixture(root, folder: "Song B", file: "Kick.wav")
        let scan = try StemProjectImporter.scan([a, b])
        let destination = root.appendingPathComponent("Project/Show.jl")
        var project = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Show"), destination: destination)
        func labels(_ value: Project) -> [String] {
            value.songs[0].tracks.flatMap { $0.clips.filter { $0.audioFile != nil }.map(\.name) }.sorted()
        }
        XCTAssertEqual(labels(project), ["Kick 001.wav", "Kick.wav"])
        for row in project.songs[0].tracks.indices {
            for index in project.songs[0].tracks[row].clips.indices { project.songs[0].tracks[row].clips[index].name = "Kick.wav" }
        }
        project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        try project.validate()
        let appended = try StemProjectImporter.build(scan: scan, remove: "", base: project, destination: destination)
        XCTAssertEqual(labels(appended), ["Kick 001.wav", "Kick 002.wav", "Kick.wav", "Kick.wav"])
    }
    func testAppendMatchesCustomNamesBeforeTaxonomyAndPreservesTracks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var base = Project.empty(name: "Custom destinations")
        let names = ["Baixo", "Baixo Moog", "Baixo Analogico", "Tuba Hits"]
        base.songs[0].tracks = names.enumerated().map { index, name in
            var track = Track(id: UUID(), name: name, role: .other, color: UInt32(0x334455 + index))
            track.volume = 0.42; track.pan = -0.25
            return track
        }
        let sources = ["Baixo Moog.wav", "Baixo Analógico.wav", "tuba_hits.wav"]
        var folder = root
        for file in sources { folder = try fixture(root, folder: "Song", file: file) }
        let appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base,
            destination: root.appendingPathComponent("Project/Show.jl"))
        XCTAssertEqual(appended.songs[0].tracks.map(\.id), base.songs[0].tracks.map(\.id))
        XCTAssertEqual(appended.songs[0].tracks.map { $0.clips.count }, [0, 1, 1, 1])
        for (before, after) in zip(base.songs[0].tracks, appended.songs[0].tracks) {
            XCTAssertEqual(after.name, before.name); XCTAssertEqual(after.volume, before.volume)
            XCTAssertEqual(after.pan, before.pan); XCTAssertEqual(after.color, before.color)
            XCTAssertEqual(after.parentTrackID, before.parentTrackID)
        }
    }
    func testAppendCustomNameWithOrderingAndSongSuffix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var base = Project.empty(name: "Custom")
        let track = Track(id: UUID(), name: "Atmosfera Azul", role: .other)
        base.songs[0].tracks = [track]
        let folder = try fixture(root, folder: "Song", file: "01 Atmosfera Azul - Song.wav")
        let appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base,
            destination: root.appendingPathComponent("Project/Show.jl"))
        XCTAssertEqual(appended.songs[0].tracks.map(\.id), [track.id])
        XCTAssertEqual(appended.songs[0].tracks[0].clips.count, 1)
    }
    func testAppendKeepsExplicitNumberedTrackReservedWhenAliasesCollide() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var base = Project.empty(name: "Numbered")
        base.songs[0].tracks = ["Click", "Click 2", "Click 3"].map { Track(id: UUID(), name: $0, role: .other) }
        var folder = root
        for file in ["Click.wav", "Click 2.wav", "Click alternate.wav"] { folder = try fixture(root, folder: "Song", file: file) }
        let appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base,
            destination: root.appendingPathComponent("Project/Show.jl"))
        XCTAssertEqual(appended.songs[0].tracks.map(\.id), base.songs[0].tracks.map(\.id))
        XCTAssertEqual(appended.songs[0].tracks.map { $0.clips.count }, [1, 1, 1], "Simultaneous stems must not overlap on an existing destination")
        XCTAssertEqual(appended.songs[0].tracks.map { $0.clips.first?.name }, ["Click.wav", "Click 2.wav", "Click alternate.wav"])
    }

    func testImportAfterReviewSkipsUnreadableAudioAndKeepsValidStems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Guitarra – João.wav")
        _ = try fixture(root, folder: "Song", file: "Click.wav")
        let scan = try StemProjectImporter.scan([folder])
        let source = folder.appendingPathComponent("Guitarra – João.wav")
        let damaged = Data("invalid audio after review".utf8)
        try damaged.write(to: source)
        let destination = root.appendingPathComponent("Project/Show.jl")
        var skipped: [String] = []
        let project = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Import"), destination: destination,
            onUnreadable: { path, _ in skipped.append(path) })
        XCTAssertEqual(skipped.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, [source.resolvingSymlinksInPath()])
        let clips = project.songs.flatMap(\.tracks).flatMap(\.clips)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.name, "Click.wav")
        XCTAssertEqual(try Data(contentsOf: source), damaged)
        let copies = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().appendingPathComponent("Stems").path)
        XCTAssertEqual(copies, ["Click.wav"])
        try project.validate()
    }
    func testOpeningSkipsBadAudioKeepsReferencesAndRetriesAfterRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Stems", file: "Valid.wav")
        let broken = folder.appendingPathComponent("Broken.wav")
        try Data("invalid audio".utf8).write(to: broken)
        var project = Project.empty(name: "Read failure")
        var track = Track(id: UUID(), name: "Guitar", role: .init(rawValue: "audio"))
        track.clips = ["Valid.wav", "Broken.wav", "Broken.wav"].enumerated().map { index, name in
            AudioClip(id: UUID(), name: name, startTime: Double(index), duration: 1, audioFile: AudioFile(path: "Stems/" + name))
        }
        project.songs[0].tracks = [track]
        var ignored: [String] = []
        let opened = try StemProjectImporter.populateChannelOverviews(project, directory: root, onUnreadable: { path, _ in ignored.append(path) })
        XCTAssertEqual(ignored, ["Stems/Broken.wav"])
        XCTAssertEqual(opened.songs[0].tracks[0].clips.map(\.audioFile), track.clips.map(\.audioFile))
        XCTAssertFalse(try XCTUnwrap(opened.songs[0].tracks[0].clips[0].waveformChannels).isEmpty)
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("Valid.wav"), to: broken)
        ignored.removeAll()
        let repaired = try StemProjectImporter.populateChannelOverviews(opened, directory: root, onUnreadable: { path, _ in ignored.append(path) })
        XCTAssertTrue(ignored.isEmpty)
        XCTAssertTrue(repaired.songs[0].tracks[0].clips.allSatisfy { $0.waveformChannels != nil })
    }
    func testInstrumentGuideAndAccordionAliasesReuseExistingTracks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try fixture(root, folder: "Original", file: "Bateria.wav")
        _ = try fixture(root, folder: "Original", file: "Sanfona.wav")
        _ = try fixture(root, folder: "Original", file: "Voz Guia.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let base = try StemProjectImporter.build(scan: StemProjectImporter.scan([original]), remove: "", base: .empty(name: "Import"), destination: destination)
        let added = try fixture(root, folder: "Added", file: "Bateria guia.wav")
        _ = try fixture(root, folder: "Added", file: "ACC.wav")
        let appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([added]), remove: "", base: base, destination: destination)
        XCTAssertEqual(appended.songs[0].tracks.map(\.id), base.songs[0].tracks.map(\.id))
        for (name, count) in [("Bateria", 2), ("Sanfona", 2), ("Guia", 1)] {
            let track = try XCTUnwrap(appended.songs[0].tracks.first { $0.name == name })
            XCTAssertEqual(track.clips.count, count, name)
            XCTAssertEqual(track.parentTrackID, base.songs[0].tracks.first { $0.id == track.id }?.parentTrackID)
        }
        let accordion = try fixture(root, folder: "Accordion alias", file: "Acordeon.wav")
        let final = try StemProjectImporter.build(scan: StemProjectImporter.scan([accordion]), remove: "", base: appended, destination: destination)
        XCTAssertEqual(final.songs[0].tracks.map(\.id), base.songs[0].tracks.map(\.id))
        XCTAssertEqual(final.songs[0].tracks.first { $0.name == "Sanfona" }?.clips.count, 3)
    }
    func testAppendMatchesFirstNumberedStemToUnnumberedAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["Backing Vocals 1.wav", "Baixo 1.wav", "Metais 1.wav", "Baixo 2.wav", "GTR WAH 1 - Outra música.wav"]
        let folder = try fixture(root, folder: "New Song", file: sources[0])
        for file in sources.dropFirst() { _ = try fixture(root, folder: "New Song", file: file) }
        var base = Project.empty(name: "Existing")
        base.songs[0].tracks = ["Back Vocais", "Bass", "Metais", "Bass 2", "Guitarra Wah", "Guitarra 1"].map {
            Track(id: UUID(), name: $0, role: .other, volume: 0.45, pan: -0.2)
        }
        let destination = root.appendingPathComponent("Project/Show.jl")
        let added = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base, destination: destination)
        XCTAssertEqual(added.songs[0].tracks.map(\.id), base.songs[0].tracks.map(\.id))
        XCTAssertEqual(added.songs[0].tracks.map { $0.clips.first?.name }, sources.map(Optional.some) + [nil])
        XCTAssertEqual(added.songs[0].tracks.map(\.volume), base.songs[0].tracks.map(\.volume))
        XCTAssertEqual(added.songs[0].tracks.map(\.pan), base.songs[0].tracks.map(\.pan))
    }

    func testAppendUsesExistingNumberedInternalTracksAndGroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Click alternate.wav")
        _ = try fixture(root, folder: "Song", file: "Guia.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let scan = try StemProjectImporter.scan([folder])
        let base = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Import"), destination: destination)
        let appended = try StemProjectImporter.build(scan: scan, remove: "", base: base, destination: destination)
        XCTAssertEqual(appended.songs[0].tracks.map(\.id), base.songs[0].tracks.map(\.id))
        for track in appended.songs[0].tracks where ["Click", "Click 2", "Guia"].contains(track.name) {
            XCTAssertEqual(track.clips.count, 2, track.name)
            XCTAssertEqual(track.parentTrackID, base.songs[0].tracks.first { $0.id == track.id }?.parentTrackID)
        }
    }
    func testGridDropCanInsertPortableItemsBeforeWaveformAnalysis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, folder: "Source", file: "Immediate.wav").appendingPathComponent("Immediate.wav")
        let project = root.appendingPathComponent("Project/Show.jl")
        let imported = try StemProjectImporter.prepareDroppedAudio([source], start: 3, destinationTracks: [], destination: project, deferWaveform: true)
        let clip = try XCTUnwrap(imported.tracks.first?.clips.first)
        XCTAssertEqual(clip.startTime, 3)
        XCTAssertEqual(clip.duration, 0.1, accuracy: 0.001)
        XCTAssertTrue(clip.waveform.isEmpty)
        let relative = try XCTUnwrap(clip.audioFile?.path)
        let copy = project.deletingLastPathComponent().appendingPathComponent(relative)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: copy))
        let overview = try StemProjectImporter.audioOverview(copy, duration: clip.duration)
        XCTAssertGreaterThan(overview.peak, 0)
        XCTAssertFalse(overview.waveform.isEmpty)
        XCTAssertTrue(clip.waveform.isEmpty, "Cache analysis must not mutate a previously inserted or undone item")
    }

    func testDroppedAudioRemainsReadableAfterSavingAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Vinheta - ensaio #2 (100%).wav"
        let source = try fixture(root, folder: "Áudios", file: name).appendingPathComponent(name)
        let document = root.appendingPathComponent("Sessão/Show.jl")
        let store = DocumentProjectStore()
        var project = Project.empty(name: "Show")
        await store.select(url: document, id: project.id)
        let drop = try StemProjectImporter.prepareDroppedAudio([source], start: 0, destinationTracks: [],
                                                              destination: document, deferWaveform: true)
        project.songs[0].tracks = drop.tracks
        // The desktop bridge omits empty channel overviews when it saves an item.
        project.songs[0].tracks[0].clips[0].waveformChannels = nil
        try await store.save(project)
        await store.deselect()
        let loaded = try await ProjectStore(url: document).load()
        let reopened = try XCTUnwrap(loaded)
        let folder = document.deletingLastPathComponent()
        XCTAssertEqual(reopened.mediaPaths, ["Stems/" + name])
        XCTAssertTrue(ProjectAudioRecovery.missingPaths(in: reopened, directory: folder).isEmpty)
        var unreadable: [String] = []
        let enriched = try StemProjectImporter.populateChannelOverviews(reopened, directory: folder) { path, _ in unreadable.append(path) }
        XCTAssertTrue(unreadable.isEmpty)
        XCTAssertFalse(enriched.songs[0].tracks[0].clips[0].waveformChannels?.isEmpty ?? true)
        let copy = folder.appendingPathComponent("Stems").appendingPathComponent(name)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: copy))
        XCTAssertGreaterThan(try AVAudioFile(forReading: copy).length, 0)
    }

    func testGridDropReusesOnlyMatchingNameAndContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, folder: "Source", file: "Song.wav").appendingPathComponent("Song.wav")
        let project = root.appendingPathComponent("Project/Show.jl")
        func drop(_ url: URL) throws -> StemProjectImporter.DroppedAudio {
            try StemProjectImporter.prepareDroppedAudio([url], start: 0, destinationTracks: [], destination: project)
        }
        let first = try drop(source)
        let second = try drop(source)
        XCTAssertEqual(first.tracks[0].clips[0].audioFile?.path, second.tracks[0].clips[0].audioFile?.path)
        XCTAssertNotEqual(first.tracks[0].clips[0].id, second.tracks[0].clips[0].id)
        XCTAssertTrue(second.folders.isEmpty)
        let renamed = source.deletingLastPathComponent().appendingPathComponent("Renamed.wav")
        try FileManager.default.copyItem(at: source, to: renamed)
        let third = try drop(renamed)
        XCTAssertNotEqual(first.tracks[0].clips[0].audioFile?.path, third.tracks[0].clips[0].audioFile?.path)
        let different = try fixture(root, folder: "Different", file: "Song.wav", seconds: 0.2).appendingPathComponent("Song.wav")
        let fourth = try drop(different)
        XCTAssertTrue(fourth.tracks[0].clips[0].audioFile!.path.hasSuffix("/Song-001.wav"))
        let retained = project.deletingLastPathComponent().appendingPathComponent(first.tracks[0].clips[0].audioFile!.path)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: source.path, andPath: retained.path))
    }
    func testOverviewAcceptsMP3WithShortOverstatedGaplessTail() throws {
        guard let path = ProcessInfo.processInfo.environment["JARAS_MP3_EOF_FIXTURE"] else {
            throw XCTSkip("Set JARAS_MP3_EOF_FIXTURE to exercise a real MP3 gapless-header mismatch")
        }
        let url = URL(fileURLWithPath: path), file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let overview = try StemProjectImporter.audioOverview(url, duration: Double(file.length) / file.processingFormat.sampleRate)
        XCTAssertGreaterThan(overview.peak, 0)
        XCTAssertEqual(overview.channels.count, Int(file.processingFormat.channelCount))
        XCTAssertTrue(overview.channels.allSatisfy { !$0.isEmpty })
    }
    func testOverviewStillRejectsDamagedFilesAndDoesNotTreatPCMErrorsAsMP3Padding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try fixture(root, folder: "Source", file: "Normal.wav")
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("Normal.wav"))
        file.framePosition = file.length - 17
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        XCTAssertFalse(AudioFileRead.toleratesEnd(NSError(domain: NSOSStatusErrorDomain, code: -39), file: file, buffer: buffer))
        let corrupt = directory.appendingPathComponent("Damaged.mp3")
        try Data("invalid audio".utf8).write(to: corrupt)
        XCTAssertThrowsError(try StemProjectImporter.audioOverview(corrupt, duration: 1))
    }
    func testProjectOpeningIdentifiesUnreadableAudioWithoutChangingTheSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Stems", file: "Valid.wav")
        let broken = folder.appendingPathComponent("Guitarra – João.wav")
        let contents = Data("invalid audio".utf8)
        try contents.write(to: broken)
        var project = Project.empty(name: "Read failure")
        var track = Track(id: UUID(), name: "Guitar", role: .init(rawValue: "audio"))
        track.clips = ["Valid.wav", broken.lastPathComponent].map {
            AudioClip(id: UUID(), name: $0, startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/" + $0))
        }
        project.songs[0].tracks = [track]
        XCTAssertThrowsError(try StemProjectImporter.populateChannelOverviews(project, directory: root)) { error in
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertNotNil(underlying)
            XCTAssertEqual(failure.domain, underlying?.domain)
            XCTAssertEqual(failure.code, underlying?.code)
            XCTAssertEqual(failure.userInfo[NSFilePathErrorKey] as? String, broken.path)
            XCTAssertTrue(failure.localizedDescription.contains("Stems/" + broken.lastPathComponent))
        }
        XCTAssertEqual(try Data(contentsOf: broken), contents)
        XCTAssertTrue(project.songs[0].tracks[0].clips.allSatisfy { $0.waveformChannels == nil })
        project.songs[0].tracks[0].clips.removeLast()
        let opened = try StemProjectImporter.populateChannelOverviews(project, directory: root)
        XCTAssertFalse(try XCTUnwrap(opened.songs[0].tracks[0].clips[0].waveformChannels).isEmpty)
    }
    func testOpeningKeepsRepeatedExternalOverviewsAndEnrichesOnlyLegacyClips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, folder: "Stems", file: "Kick.wav")
        _ = try fixture(root, folder: "Stems", file: "Bass.wav")
        var project = Project.empty(name: "External waveforms")
        var track = Track(id: UUID(), name: "Audio", role: .init(rawValue: "audio"))
        track.clips = ["Kick.wav", "Kick.wav", "Bass.wav", "Kick.wav"].enumerated().map { index, name in
            AudioClip(id: UUID(), name: name, startTime: Double(index), duration: 0.1, audioFile: AudioFile(path: "Stems/" + name))
        }
        track.clips[3].waveform = [0.5]
        project.songs[0].tracks = [track]
        var checked: [String: Int] = [:]
        let opened = try StemProjectImporter.populateChannelOverviews(project, directory: root, externalOverviewIsCurrent: {
            checked[$0.lastPathComponent, default: 0] += 1
            return $0.lastPathComponent == "Kick.wav"
        })
        let clips = opened.songs[0].tracks[0].clips
        XCTAssertEqual(checked, ["Kick.wav": 1, "Bass.wav": 1])
        XCTAssertEqual(Array(clips.prefix(2)), Array(track.clips.prefix(2)))
        XCTAssertNotNil(clips[2].waveformChannels)
        XCTAssertNotNil(clips[3].waveformChannels)
        XCTAssertEqual(clips[3].waveform, [0.5])
    }
    func fixture(_ root: URL, folder: String, file: String, seconds: Double = 0.1) throws -> URL {
        let directory = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1)) * 0.3 }
        try output.write(from: buffer)
        return directory
    }
    func testCleanupSuggestionsProtectHookCenterInstrumentVocabularyAndGroups() throws {
        let js = try StemProjectImporter.context()
        let names = js.evaluateScript("CREATE_PROJECT_TRACK_RULES.map(rule => rule.name).concat(CREATE_PROJECT_TRACK_GROUPS.map(group => group.name))")!.toArray() as! [String]
        for name in names + ["GTR", "Pno", "Metronome", "Accordion", "Drum", "Drumm", "Drums", "Drumms", "Electric Piano", "Hi-Hat"] {
            let suggestions = try StemProjectImporter.call("suggestImportRemovals", args: [[name, name], ["limit": 12]], context: js, as: [ImportSuggestion].self)
            XCTAssertTrue(suggestions.isEmpty, "Instrument or group name must not be proposed for removal: \(name)")
        }
        let sourceNames = ["Fornecedor - Click", "Fornecedor - Sanfona", "Fornecedor - Bateria", "Fornecedor - Piano", "Clube do VS - Click", "Clube do VS - Piano"]
        let suggestions = try StemProjectImporter.call("suggestImportRemovals", args: [sourceNames, ["limit": 12]], context: js, as: [ImportSuggestion].self)
        XCTAssertTrue(suggestions.contains { $0.text == "Fornecedor" })
        XCTAssertTrue(suggestions.contains { $0.text == "Clube do VS" })
        XCTAssertFalse(suggestions.contains { $0.text.contains("Click") || $0.text.contains("Sanfona") })
    }
    func testFolderReviewRetainsSelectionOrderAcrossSearchAndSelectAll() {
        let urls = ["Zulu", "Alpha", "Middle"].map { URL(fileURLWithPath: "/songs/" + $0) }
        var selection = FolderImportSelection(urls + [urls[0]])
        XCTAssertEqual(selection.folders, urls)
        XCTAssertTrue(selection.selected.isEmpty)
        selection.toggle(urls[2]); selection.toggle(urls[0])
        XCTAssertEqual(selection.matching("ALP"), [urls[1]])
        XCTAssertEqual(selection.selected, [urls[2], urls[0]])
        selection.toggleAll()
        XCTAssertTrue(selection.allSelected)
        XCTAssertEqual(selection.selected, [urls[2], urls[0], urls[1]])
        selection.toggle(urls[0]); selection.toggle(urls[0])
        XCTAssertEqual(selection.position(of: urls[0]), 3)
        selection.toggleAll()
        XCTAssertTrue(selection.selected.isEmpty)
        selection.toggleAll()
        XCTAssertEqual(selection.selected, urls)
        selection.toggle(URL(fileURLWithPath: "/not-in-selection"))
        XCTAssertEqual(selection.selected, urls)
    }
    func testCreateAndAppendFollowCheckedFolderOrderBeyondTenFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Zulu", "Alpha", "Quebec", "Bravo", "Yankee", "Charlie", "Xray", "Delta", "Whiskey", "Echo", "Victor", "Foxtrot"]
        let folders = try names.map { try fixture(root, folder: $0, file: "Click.wav") }
        var selection = FolderImportSelection(folders)
        for folder in folders.reversed() { selection.toggle(folder) }
        let scan = try StemProjectImporter.scan(selection.selected)
        XCTAssertEqual(scan.folders.map(\.url), selection.selected)
        let destination = root.appendingPathComponent("Project/Show.jl")
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Order"), destination: destination)
        XCTAssertEqual(first.songs[0].parts.map(\.name), Array(names.reversed()))
        let click = try XCTUnwrap(first.songs[0].tracks.first { $0.name == "Click" })
        let clickGroup = try XCTUnwrap(first.songs[0].tracks.first { $0.id == click.parentTrackID })
        XCTAssertNotEqual(click.color, clickGroup.color, "Folder colors remain stronger than their children")
        for pair in zip(first.songs[0].parts, first.songs[0].parts.dropFirst()) {
            XCTAssertEqual(pair.1.startTime - pair.0.endTime, 30, accuracy: 0.00001)
        }
        let nextScan = try StemProjectImporter.scan([folders[3], folders[0]])
        let appended = try StemProjectImporter.build(scan: nextScan, remove: "", base: first, destination: destination)
        XCTAssertEqual(Array(appended.songs[0].parts.suffix(2)).map(\.name), [names[3], names[0]])
        XCTAssertEqual(appended.songs[0].parts[12].startTime - first.songs[0].parts.last!.endTime, 30, accuracy: 0.00001)
    }
    func testAppendPreservesOpenProjectAndChosenOrderAfterLastRegionOrItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalFolder = try fixture(root, folder: "Existing", file: "Piano.wav", seconds: 0.25)
        let zulu = try fixture(root, folder: "Zulu", file: "Piano.wav", seconds: 0.2)
        let alpha = try fixture(root, folder: "Alpha", file: "Piano.wav", seconds: 0.3)
        let destination = root.appendingPathComponent("Open Project/Show.jl")
        let original = try StemProjectImporter.build(scan: StemProjectImporter.scan([originalFolder]),
            remove: "", base: .empty(name: "My existing show"), destination: destination)
        let pianoIndex = try XCTUnwrap(original.songs[0].tracks.firstIndex { $0.name == "Piano" })
        let media = destination.deletingLastPathComponent().appendingPathComponent(
            try XCTUnwrap(original.songs[0].tracks[pianoIndex].clips[0].audioFile).path)
        let originalMedia = try Data(contentsOf: media)
        // Selection order is deliberate: sorting folder names would reverse it.
        let scan = try StemProjectImporter.scan([zulu, alpha])
        XCTAssertEqual(scan.folders.map(\.url), [zulu, alpha])

        for (regionEnd, itemEnd) in [(80.0, 110.0), (140.0, 90.0), (0.0, 120.0)] {
            var base = original
            base.masterVolume = 0.63
            base.masterMono = true
            base.songs[0].name = "Edited arrangement"
            base.songs[0].bpm = 137
            // Empty timeline space must not determine where appended songs start.
            base.songs[0].duration = 900
            base.songs[0].markers = [TimelineMarker(id: UUID(), name: "Existing cue", position: 12, color: 0x336699)]
            if regionEnd == 0 { base.songs[0].parts = [] }
            else {
                base.songs[0].parts[0].startTime = 10
                base.songs[0].parts[0].endTime = regionEnd
                base.songs[0].parts[0].name = "Edited old region"
            }
            base.songs[0].tracks[pianoIndex].volume = 0.42
            base.songs[0].tracks[pianoIndex].pan = -0.35
            base.songs[0].tracks[pianoIndex].color = 0x13579B
            base.songs[0].tracks[pianoIndex].clips[0].name = "Edited old item"
            base.songs[0].tracks[pianoIndex].clips[0].startTime = itemEnd - 0.25
            base.songs[0].tracks[pianoIndex].clips[0].gain = 0.71
            base.songs[0].tracks[pianoIndex].clips[0].fadeIn = 0.03
            try base.validate()

            let appended = try StemProjectImporter.build(scan: scan, remove: "", base: base, destination: destination)
            let arrangement = appended.songs[0]
            let additions = Array(arrangement.parts.dropFirst(base.songs[0].parts.count))
            XCTAssertEqual(additions.map(\.name), ["Zulu", "Alpha"])
            XCTAssertEqual(additions.count, 2)
            let first = try XCTUnwrap(additions.first), last = try XCTUnwrap(additions.last)
            XCTAssertEqual(first.startTime, max(regionEnd, itemEnd) + 30, accuracy: 0.00001)
            XCTAssertEqual(last.startTime, first.endTime + 30, accuracy: 0.00001)
            XCTAssertEqual(arrangement.tracks.map(\.id), base.songs[0].tracks.map(\.id), "Append must reuse the existing tracks")
            let addedClips = Array(arrangement.tracks[pianoIndex].clips.dropFirst(1))
            XCTAssertEqual(addedClips.map(\.startTime), additions.map(\.startTime))
            XCTAssertEqual(Set(arrangement.tracks[pianoIndex].clips.map(\.id)).count, 3)
            XCTAssertEqual(Set(arrangement.parts.map(\.id)).count, arrangement.parts.count)

            // Removing only the newly appended entities must recover every prior
            // field and ID, including edited audio items, mixer settings and cues.
            var recovered = appended
            recovered.updatedAt = base.updatedAt
            recovered.songs[0].duration = base.songs[0].duration
            recovered.songs[0].parts.removeLast(2)
            recovered.songs[0].tracks[pianoIndex].clips.removeLast(2)
            XCTAssertEqual(recovered, base)
            XCTAssertEqual(try Data(contentsOf: media), originalMedia, "Existing media must remain unchanged")
            try appended.validate()
        }
    }
    func testDroppedAudioCopiesMediaAndKeepsPlacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "Source", file: "One.wav", seconds: 0.2).appendingPathComponent("One.wav")
        let two = try fixture(root, folder: "Source", file: "Two.wav", seconds: 0.3).appendingPathComponent("Two.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let track = UUID()
        let imported = try StemProjectImporter.prepareDroppedAudio([one, two, one], start: 12.5, destinationTracks: [track], destination: destination)
        XCTAssertEqual(imported.tracks.count, 2)
        XCTAssertEqual(imported.tracks[0].id, track)
        XCTAssertNotEqual(imported.tracks[1].id, track)
        XCTAssertTrue(imported.tracks.allSatisfy { $0.color == Track.defaultStandardColor })
        for (index, source) in [one, two].enumerated() {
            let clip = imported.tracks[index].clips[0]
            XCTAssertEqual(clip.startTime, 12.5)
            XCTAssertEqual(clip.duration, index == 0 ? 0.2 : 0.3, accuracy: 0.00001)
            let copy = destination.deletingLastPathComponent().appendingPathComponent(clip.audioFile!.path)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
            XCTAssertFalse(clip.waveform.isEmpty)
        }
        let bad = root.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: bad)
        let existing = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Project/Stems").path)
        let skipped = try StemProjectImporter.prepareDroppedAudio([bad], start: 0, destinationTracks: [], destination: destination)
        XCTAssertTrue(skipped.tracks.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Project/Stems").path), existing)
        let mixed = try StemProjectImporter.prepareDroppedAudio([one, bad], start: 0, destinationTracks: [], destination: destination)
        XCTAssertEqual(mixed.tracks.count, 1)
        let kept = try XCTUnwrap(mixed.tracks.first?.clips.first?.audioFile)
        XCTAssertEqual(try Data(contentsOf: destination.deletingLastPathComponent().appendingPathComponent(kept.path)), try Data(contentsOf: one))
    }
    func testGridBatchDropRoutesDownFromHoveredTrackAndCreatesOnlyOverflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Take A", "Take B", "Take C"]
        let urls = try names.map { name in
            let file = name + ".wav"
            return try fixture(root, folder: "Source", file: file, seconds: 0.2).appendingPathComponent(file)
        }
        let tracks = [
            Track(id: UUID(), name: "Selected", role: .other),
            Track(id: UUID(), name: "Drop here", role: .other),
            Track(id: UUID(), name: "Program Change", role: TrackRole(rawValue: "programChange")),
            Track(id: UUID(), name: "Next visible audio", role: .other)
        ]
        let rows = StemProjectImporter.gridDropRows(in: tracks, startingAt: 1, limit: urls.count)
        XCTAssertEqual(rows, [1, 3])
        let destinations = rows.map { tracks[$0].id }
        let result = try StemProjectImporter.prepareDroppedAudio(urls, start: 12, destinationTracks: destinations,
            destination: root.appendingPathComponent("Project/Show.jl"))
        XCTAssertEqual(Array(result.tracks.prefix(2).map(\.id)), destinations)
        XCTAssertFalse(tracks.map(\.id).contains(result.tracks[2].id))
        XCTAssertEqual(result.tracks[2].name, "Take C")
        XCTAssertEqual(result.tracks.flatMap(\.clips).map(\.name), names)
        XCTAssertEqual(result.tracks.flatMap(\.clips).map(\.startTime), [12, 12, 12])
    }

    func testSameTrackDropUsesGapAndExtensionFreeNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "Source", file: "Song.One.WAV", seconds: 0.2).appendingPathComponent("Song.One.WAV")
        let two = try fixture(root, folder: "Source", file: "Second.wav", seconds: 0.3).appendingPathComponent("Second.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let target = UUID()
        for gap in [0.0, 12.0, 60.0] {
            let result = try StemProjectImporter.prepareDroppedAudio([one,two], start: 30, destinationTracks: [target], destination: destination, layout: .sameTrack, gap: gap)
            XCTAssertEqual(result.tracks.count, 1)
            XCTAssertEqual(result.tracks[0].id, target)
            XCTAssertEqual(result.tracks[0].name, "Song.One")
            XCTAssertEqual(result.tracks[0].clips.map(\.name), ["Song.One", "Second"])
            XCTAssertEqual(result.tracks[0].clips[1].startTime, 30.2 + gap, accuracy: 0.000001)
        }
        let emptyArea = try StemProjectImporter.prepareDroppedAudio([one], start: 10, destinationTracks: [], destination: destination)
        XCTAssertEqual(emptyArea.tracks[0].name, "Song.One")
        XCTAssertNotEqual(emptyArea.tracks[0].id, target)
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([one,two], start: 0, destinationTracks: [], destination: destination, layout: .sameTrack, gap: 61))
    }

    func testStackedImportUsesOneTrackOneStartAndSeparateLanes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "Source", file: "One.wav", seconds: 0.2).appendingPathComponent("One.wav")
        let two = try fixture(root, folder: "Source", file: "Two.wav", seconds: 0.3).appendingPathComponent("Two.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        for target in [nil, UUID()] as [UUID?] {
            let result = try StemProjectImporter.prepareDroppedAudio([one, two], start: 30, destinationTracks: target.map { [$0] } ?? [], destination: destination, layout: .stacked, gap: 12, deferWaveform: true)
            XCTAssertEqual(result.tracks.count, 1)
            let track = result.tracks[0]
            if let target { XCTAssertEqual(track.id, target) }
            XCTAssertEqual(track.clips.map(\.startTime), [30, 30])
            XCTAssertEqual(track.clips.map(\.name), ["One", "Two"])
            XCTAssertTrue(track.clips.allSatisfy { $0.waveform.isEmpty })
            var separated = track
            separated.stackedStems = false
            let lanes = TrackLanes(track: separated)
            XCTAssertEqual(lanes.count, 2)
            XCTAssertNotEqual(lanes.lanes[track.clips[0].id], lanes.lanes[track.clips[1].id])
            let restored = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(separated))
            XCTAssertEqual(TrackLanes(track: restored), lanes)
            XCTAssertEqual(restored.clips.map(\.startTime), [30, 30])
        }
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([one, two], start: 0, destinationTracks: [UUID()], destination: destination, layout: .stacked, destinationKind: .teleprompt))
    }

    func testVectorOverviewMatchesSamplePeaks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav", seconds: 0.2)
        let url = folder.appendingPathComponent("Click.wav")
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let result = try StemProjectImporter.audioOverview(url, duration: duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var expected = Array(repeating: 0.0, count: result.waveform.count)
        var peak = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            let value = abs(Double(buffer.floatChannelData![0][frame]))
            let index = frame * expected.count / Int(file.length)
            expected[index] = max(expected[index], min(1, value)); peak = max(peak, value)
        }
        XCTAssertEqual(result.channels, [expected])
        XCTAssertEqual(result.waveform, expected)
        XCTAssertEqual(result.peak, peak, accuracy: 0.0000001)
    }
    func testStereoOverviewKeepsIndependentChannels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        do {
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
            buffer.frameLength = 4410
            for i in 0..<4410 { buffer.floatChannelData![0][i] = 0.2; buffer.floatChannelData![1][i] = 0.7 }
            try output.write(from: buffer)
        }
        let result = try StemProjectImporter.audioOverview(url, duration: 0.1)
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.channels[0].max()!, 0.2, accuracy: 0.00001)
        XCTAssertEqual(result.channels[1].max()!, 0.7, accuracy: 0.00001)
    }
    func testImportGroupingMediaNamesAndThirtySecondGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "01 - Song One - MultiTracks", file: "Click.wav")
        _ = try fixture(root, folder: one.lastPathComponent, file: "Sanfona.wav", seconds: 0.2)
        let two = try fixture(root, folder: "02 - Song Two - MultiTracks", file: "Click.wav")
        _ = try fixture(root, folder: two.lastPathComponent, file: "Accordion.wav")
        let scan = try StemProjectImporter.scan([one, two])
        XCTAssertTrue(scan.suggestions.contains { $0.text == "MultiTracks" })
        let destination = root.appendingPathComponent("Show.jl")
        let project = try StemProjectImporter.build(scan: scan, remove: "MultiTracks", base: .empty(name: "Show"), destination: destination)
        let song = project.songs[0]
        XCTAssertEqual(song.parts.map(\.name), ["Song One", "Song Two"])
        XCTAssertEqual(song.parts[0].startTime, 30)
        XCTAssertEqual(song.parts[1].startTime - song.parts[0].endTime, 30, accuracy: 0.000001)
        XCTAssertEqual(Set(song.tracks.map(\.name)), ["Interno", "Click", "Sanfonas", "Sanfona"])
        XCTAssertEqual(song.tracks.filter { !$0.clips.isEmpty }.map { $0.clips.count }, [2, 2])
        for clip in song.tracks.flatMap(\.clips) {
            XCTAssertNotNil(clip.audioFile)
            XCTAssertTrue(clip.audioFile!.path.hasPrefix("Stems/"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.audioFile!.path).path))
            XCTAssertGreaterThan(clip.waveform.max()!, 0)
        }
        let next = try StemProjectImporter.build(scan: scan, remove: "MultiTracks", base: project, destination: destination)
        XCTAssertEqual(next.songs[0].tracks.count, 4)
        XCTAssertEqual(next.songs[0].parts[2].startTime - song.parts[1].endTime, 30, accuracy: 0.000001)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(next)), next)
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.appendingPathComponent("Click.wav").path))
    }
    func testSameSongDuplicateTracksAndUnsafeClipPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Metronome.wav")
        let scan = try StemProjectImporter.scan([folder])
        var project = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Show"), destination: root.appendingPathComponent("Show.jl"))
        XCTAssertEqual(Set(project.songs[0].tracks.map(\.name)), ["Interno", "Click", "Click 2"])
        let child = try XCTUnwrap(project.songs[0].tracks.firstIndex { !$0.clips.isEmpty })
        project.songs[0].tracks[child].clips[0].audioFile = AudioFile(path: "../outside.wav")
        XCTAssertThrowsError(try project.validate())
    }
    func testImportedFamiliesBecomeFoldersAndAppendKeepsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "One", file: "Piano.wav")
        _ = try fixture(root, folder: "One", file: "Pad.wav")
        _ = try fixture(root, folder: "One", file: "Guitarra 1.wav")
        _ = try fixture(root, folder: "One", file: "Guitarra 2.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let scan = try StemProjectImporter.scan([folder])
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Groups"), destination: destination)
        let tracks = first.songs[0].tracks
        XCTAssertEqual(tracks.filter { $0.parentTrackID != nil }.count, 4)
        XCTAssertEqual(Set(tracks.filter { $0.parentTrackID == nil }.map(\.name)), ["Guitarras", "Teclados"])
        for child in tracks where child.parentTrackID != nil {
            let parent = try XCTUnwrap(tracks.first { $0.id == child.parentTrackID })
            XCTAssertEqual(parent.name, child.name.hasPrefix("Guitarra") ? "Guitarras" : "Teclados")
            XCTAssertTrue(parent.clips.isEmpty)
            XCTAssertEqual(child.primaryOutput, .masterGroup)
        }
        let second = try StemProjectImporter.build(scan: scan, remove: "", base: first, destination: destination)
        XCTAssertEqual(second.songs[0].tracks.map(\.parentTrackID), tracks.map(\.parentTrackID))
        XCTAssertEqual(second.songs[0].tracks.count, tracks.count)
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(second))
        XCTAssertEqual(reopened, second)
        try reopened.validate()
    }
    func testPercussiveFolderContainsDrumsAndCongaAndIsReusedOnAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "One", file: "Conga.wav")
        _ = try fixture(root, folder: "One", file: "Bateria.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let scan = try StemProjectImporter.scan([folder])
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Groups"), destination: destination)
        let tracks = first.songs[0].tracks
        let group = try XCTUnwrap(tracks.first { $0.name == "Percussivo" })
        XCTAssertNil(group.parentTrackID)
        XCTAssertTrue(group.clips.isEmpty)
        XCTAssertEqual(Set(tracks.filter { $0.parentTrackID == group.id }.map(\.name)), ["Conga", "Bateria"])
        XCTAssertTrue(tracks.filter { $0.parentTrackID == group.id }.allSatisfy { $0.primaryOutput == .masterGroup })
        let second = try StemProjectImporter.build(scan: scan, remove: "", base: first, destination: destination)
        XCTAssertEqual(second.songs[0].tracks.count, tracks.count)
        XCTAssertEqual(second.songs[0].tracks.first { $0.name == "Percussivo" }?.id, group.id)
        XCTAssertEqual(second.songs[0].tracks.first { $0.name == "Bateria" }?.clips.count, 2)
        var appended = second
        for (index, alias) in ["Drum", "DRUMM", "Drumms"].enumerated() {
            let incoming = try fixture(root, folder: "Song\(index)", file: alias + ".wav")
            appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([incoming]), remove: "", base: appended, destination: destination)
            XCTAssertEqual(appended.songs[0].tracks.map(\.id), tracks.map(\.id))
            XCTAssertEqual(appended.songs[0].tracks.map(\.parentTrackID), tracks.map(\.parentTrackID))
            XCTAssertEqual(appended.songs[0].tracks.first { $0.name == "Bateria" }?.clips.count, 3 + index)
        }
    }
    func testEveryHookCenterAuditGroupIncludingOthersIsCreatedAndReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Click", "Guitarra", "Violão", "Sanfona", "Piano", "Pad", "Metais", "Bateria", "Conga", "Backing Vocal", "Baixo", "Mystery Sound"]
        let folder = try fixture(root, folder: "One", file: names[0] + ".wav")
        for name in names.dropFirst() { _ = try fixture(root, folder: "One", file: name + ".wav") }
        let scan = try StemProjectImporter.scan([folder]), destination = root.appendingPathComponent("Project/Show.jl")
        let js = try StemProjectImporter.context()
        let virtual: [[String: Any]] = [["path": "/0/One", "files": scan.folders[0].files.map { ["name": $0.name, "duration": $0.duration, "peakDb": NSNull()] as [String: Any] }]]
        let reference = try StemProjectImporter.call("analyzeImport", args: [virtual], context: js, as: ImportAudit.self)
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Audit"), destination: destination)
        let tracks = first.songs[0].tracks
        XCTAssertEqual(tracks.filter { $0.parentTrackID == nil }.map(\.name), (reference.groups.filter { $0.key != "percussivo" } + reference.groups.filter { $0.key == "percussivo" }).map(\.name))
        XCTAssertEqual(tracks.filter { $0.parentTrackID == nil }.count, 9)
        for group in reference.groups {
            let folder = try XCTUnwrap(tracks.first { $0.name == group.name && $0.parentTrackID == nil })
            let members = tracks.filter { $0.parentTrackID == folder.id }
            XCTAssertEqual(members.map(\.name), group.tracks.map(\.name))
            XCTAssertTrue(members.allSatisfy { $0.color != folder.color && $0.primaryOutput == .masterGroup })
        }
        let second = try StemProjectImporter.build(scan: scan, remove: "", base: first, destination: destination)
        XCTAssertEqual(second.songs[0].tracks.map(\.id), tracks.map(\.id))
        XCTAssertTrue(second.songs[0].tracks.filter { !$0.clips.isEmpty }.allSatisfy { $0.clips.count == 2 })
    }
    func testAppendReusesStandaloneTrackWithoutCreatingOrMovingToFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Guitarra.wav")
        var base = Project.empty(name: "Existing")
        var existing = Track(id: UUID(), name: "GTR", role: .guitar)
        existing.clips = [AudioClip(id: UUID(), name: "Old", startTime: 0, duration: 0.1)]
        base.songs[0].tracks = [existing]
        let appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base, destination: root.appendingPathComponent("Show.jl"))
        XCTAssertEqual(appended.songs[0].tracks.map(\.id), [existing.id])
        XCTAssertNil(appended.songs[0].tracks.first?.parentTrackID)
        XCTAssertEqual(appended.songs[0].tracks.first { $0.id == existing.id }?.clips.count, 2)
    }
    func testAppendPreservesExistingHierarchyAndUsesDecoratedGroupForNewTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Guitarra.wav")
        _ = try fixture(root, folder: "Song", file: "Sanfona.wav")
        _ = try fixture(root, folder: "Song", file: "Guitarra Solo.wav")
        var base = Project.empty(name: "Existing")
        let guitars = Track(id: UUID(), name: "#GUITARRAS", role: .other)
        let other = Track(id: UUID(), name: "Minha pasta", role: .other)
        var guitar = Track(id: UUID(), name: "GTR", role: .guitar)
        guitar.parentTrackID = other.id; guitar.patch = OutputPatch(firstChannel: 4, channelCount: 2)
        let accordion = Track(id: UUID(), name: "Sanfona", role: .accordion)
        base.songs[0].tracks = [other, guitar, accordion, guitars]
        let result = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base, destination: root.appendingPathComponent("Show.jl"))
        let tracks = result.songs[0].tracks, ids = Set(base.songs[0].tracks.map(\.id))
        XCTAssertEqual(tracks.filter { ids.contains($0.id) }.map(\.id), base.songs[0].tracks.map(\.id))
        XCTAssertEqual(tracks.first { $0.id == guitar.id }?.parentTrackID, other.id)
        XCTAssertEqual(tracks.first { $0.id == guitar.id }?.patch, guitar.patch)
        XCTAssertNil(tracks.first { $0.id == accordion.id }?.parentTrackID)
        XCTAssertFalse(tracks.contains { $0.name == "Sanfonas" || $0.name == "Guitarras" })
        XCTAssertEqual(tracks.first { $0.name == "Guitarra Solo" }?.parentTrackID, guitars.id)
        XCTAssertEqual(tracks.filter { $0.id == guitar.id || $0.id == accordion.id }.map { $0.clips.count }, [1,1])
    }
    func testAppendUsesExistingCategoryMembersInCustomAndMixedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Sax.wav")
        for name in ["FX 1", "FX 2", "Baixo", "Guitarra"] { _ = try fixture(root, folder: "Song", file: name + ".wav") }
        var base = Project.empty(name: "Existing")
        let others = Track(id: UUID(), name: "#OUTROS", role: .other)
        var metal = Track(id: UUID(), name: "METAIS", role: .other)
        metal.parentTrackID = others.id; metal.patch = .masterGroup
        var bass = Track(id: UUID(), name: "BASS", role: .bass)
        bass.parentTrackID = others.id; bass.patch = OutputPatch(firstChannel: 4, channelCount: 2)
        let guitars = Track(id: UUID(), name: "Meus instrumentos", role: .other)
        var guitar = Track(id: UUID(), name: "Guitarra Solo", role: .guitar)
        guitar.parentTrackID = guitars.id
        let last = Track(id: UUID(), name: "Last", role: .other)
        base.songs[0].tracks = [others, metal, bass, guitars, guitar, last]
        let scan = try StemProjectImporter.scan([folder])
        let result = try StemProjectImporter.build(scan: scan, remove: "", base: base, destination: root.appendingPathComponent("Show.jl"))
        let tracks = result.songs[0].tracks, ids = Set(base.songs[0].tracks.map(\.id))
        XCTAssertEqual(tracks.filter { ids.contains($0.id) }.map(\.id), base.songs[0].tracks.map(\.id))
        for original in base.songs[0].tracks {
            var found = try XCTUnwrap(tracks.first { $0.id == original.id }); found.clips = original.clips
            XCTAssertEqual(found, original, "Existing track metadata must stay untouched")
        }
        XCTAssertFalse(tracks.contains { ["Metais", "Outros", "Guitarras"].contains($0.name) })
        for name in ["Sax", "FX 1", "FX 2"] { XCTAssertEqual(tracks.first { $0.name == name }?.parentTrackID, others.id) }
        XCTAssertEqual(tracks.first { $0.name == "Guitarra" }?.parentTrackID, guitars.id)
        XCTAssertEqual(tracks.first { $0.id == bass.id }?.clips.count, 1)
        let repeated = try StemProjectImporter.build(scan: scan, remove: "", base: result, destination: root.appendingPathComponent("Show.jl"))
        XCTAssertEqual(repeated.songs[0].tracks.map(\.id), tracks.map(\.id))
    }

    func testAppendKeepsNewCategorySiblingBesideStandaloneTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Sax.wav")
        var base = Project.empty(name: "Existing")
        let metal = Track(id: UUID(), name: "METAIS", role: .other)
        let last = Track(id: UUID(), name: "Last", role: .other)
        base.songs[0].tracks = [metal, last]
        let result = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base, destination: root.appendingPathComponent("Show.jl"))
        XCTAssertEqual(result.songs[0].tracks.map(\.name), ["METAIS", "Sax", "Last"])
        XCTAssertTrue(result.songs[0].tracks.allSatisfy { $0.parentTrackID == nil })
    }

    func testAppendRealProjectFixturePreservesEveryExistingTrack() throws {
        guard let input = ProcessInfo.processInfo.environment["CATLIVE_ADD_PROJECT_FIXTURE"],
              let manifest = ProcessInfo.processInfo.environment["CATLIVE_ADD_PROJECT_FILES"] else {
            throw XCTSkip("Set the read-only project JSON and incoming filenames to verify a real arrangement")
        }
        let base = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Use tiny WAVs with the exact incoming names; the customer's media and document are read-only.
        for name in names { _ = try fixture(root, folder: "vai na marcha", file: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".wav") }
        let scan = try StemProjectImporter.scan([root.appendingPathComponent("vai na marcha")])
        let result = try StemProjectImporter.build(scan: scan, remove: "", base: base, destination: root.appendingPathComponent("Show.jl"))
        let tracks = result.songs[0].tracks, originals = base.songs[0].tracks, ids = Set(originals.map(\.id))
        XCTAssertEqual(tracks.filter { ids.contains($0.id) }.map(\.id), originals.map(\.id))
        for original in originals {
            var found = try XCTUnwrap(tracks.first { $0.id == original.id }); found.clips = original.clips
            XCTAssertEqual(found, original)
        }
        let oldFolders = Set(originals.compactMap(\.parentTrackID))
        XCTAssertEqual(Set(tracks.compactMap(\.parentTrackID)), oldFolders, "No new category folders are needed in this arrangement")
        let others = try XCTUnwrap(originals.first { $0.name == "#OUTROS" })
        XCTAssertEqual(tracks.first { $0.name == "Sax" }?.parentTrackID, others.id)
        print("REAL_ADD_PROJECT_OK original=\(originals.count) final=\(tracks.count) new=\(tracks.filter { !ids.contains($0.id) }.map(\.name))")
    }

    func testParallelImportFailureRollsBackOnlyItsOwnMediaDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Piano.wav")
        let scan = try StemProjectImporter.scan([folder])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Piano.wav"))
        let existing = root.appendingPathComponent("Stems/old.wav")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: existing)
        XCTAssertThrowsError(try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Rollback"), destination: root.appendingPathComponent("Show.jl")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.deletingLastPathComponent().path), ["old.wav"])
    }
    func testCleaningCollisionDoesNotCreateMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Provider Click.wav")
        let scan = try StemProjectImporter.scan([folder])
        XCTAssertThrowsError(try StemProjectImporter.build(scan: scan, remove: "Provider", base: .empty(name: "Show"), destination: root.appendingPathComponent("Show.jl")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Stems").path))
    }
}
