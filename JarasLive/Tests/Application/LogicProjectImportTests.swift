#if os(macOS)
import XCTest
@testable import JarasApplication

final class LogicProjectImportTests: XCTestCase {
    private func put(_ value: UInt64, in data: inout Data, at offset: Int, width: Int = 4) {
        for byte in 0..<width { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
    }
    private func record(_ tag: String, body: Data, owner: Int = 0, index: Int = 0, kind: Int = 23, version: Int = 5) -> Data {
        var data = Data(count: 36)
        data.replaceSubrange(0..<4, with: tag.utf8)
        put(UInt64(version), in: &data, at: 4, width: 2)
        put(UInt64(kind), in: &data, at: 6, width: 2)
        put(UInt64(owner), in: &data, at: 8)
        put(UInt64(index), in: &data, at: tag == "karT" ? 18 : 14)
        put(UInt64(body.count), in: &data, at: 28)
        data.append(body); return data
    }
    private func text(_ value: String, in data: inout Data, at offset: Int, utf16: Bool = false) {
        let bytes = value.data(using: utf16 ? .utf16LittleEndian : .utf8)!
        put(UInt64(utf16 ? value.utf16.count : bytes.count), in: &data, at: offset, width: 2)
        data.replaceSubrange((offset + 2)..<(offset + 2 + bytes.count), with: bytes)
    }
    private func fixture(_ directory: URL, active: String = "000", corruptLink: Bool = false) throws -> URL {
        let bundle = directory.appendingPathComponent("Migration.logicx")
        let alternative = bundle.appendingPathComponent("Alternatives/" + active)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let meta: [String: Any] = ["SampleRate": 48000, "BeatsPerMinute": 60, "SongSignatureNumerator": 4, "SongSignatureDenominator": 4]
        try PropertyListSerialization.data(fromPropertyList: meta, format: .binary, options: 0).write(to: alternative.appendingPathComponent("MetaData.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["ActiveVariant": Int(active)!], format: .binary, options: 0).write(to: bundle.appendingPathComponent("Resources/ProjectInformation.plist"))
        var records = Data()
        var sequence = Data(count: 80); text("Migration", in: &sequence, at: 16)
        records.append(record("qeSM", body: sequence, owner: 0x40000))
        for (index, title) in ["Group", "Guitar"].enumerated() {
            var env = Data(count: 200); text(title, in: &env, at: 158)
            records.append(record("ivnE", body: env, owner: (index + 1) << 18, kind: 20))
            var row = Data(count: 58); row[0] = 1
            put(UInt64((index + 1) << 18), in: &row, at: 6)
            put(UInt64(index), in: &row, at: 14, width: 2)
            records.append(record("karT", body: row, owner: 0x40000, index: index))
        }
        var file = Data(count: 100); text("Guitar.wav", in: &file, at: 8, utf16: true)
        records.append(record("lFuA", body: file, kind: 11))
        var region = Data(count: 160)
        put(48000, in: &region, at: 6, width: 8)
        put(480000, in: &region, at: 22, width: 8)
        text("Trimmed guitar", in: &region, at: 74)
        records.append(record("gRuA", body: region, kind: 11))
        var event = Data(count: 80); event[0] = 0x24
        put(34560 + 8 * 960, in: &event, at: 4)
        put(0x100, in: &event, at: 12)
        put(2, in: &event, at: 20)
        for offset in [23, 39, 55, 71] { event[offset] = 0x88 }
        if corruptLink { put(99, in: &event, at: 44) }
        records.append(record("qSvE", body: event, owner: 0x40000))
        var tempos = Data()
        for (tick, bpm) in [(0, 60), (3840, 120)] {
            var tempo = Data(count: 32); tempo[0] = 0x60; tempo[23] = 0x88
            put(UInt64(tick + 38400), in: &tempo, at: 4)
            put(UInt64(bpm * 10000), in: &tempo, at: 16)
            tempos.append(tempo)
        }
        records.append(record("qSvE", body: tempos, kind: 3))
        var marker = Data(count: 48); marker[0] = 0x12; marker[23] = 0x88; marker[39] = 0x88
        put(38400, in: &marker, at: 4); put(4, in: &marker, at: 16); put(8 * 960, in: &marker, at: 28)
        records.append(record("qSvE", body: marker, kind: 22))
        records.append(record("qSxT", body: Data("{\\rtf1\\ansi Introduction}".utf8), owner: 4 << 16, kind: 32))
        var data = Data(count: 24); put(0xabc04723, in: &data, at: 0); put(UInt64(records.count), in: &data, at: 16)
        data.append(records); try data.write(to: alternative.appendingPathComponent("ProjectData"))
        return bundle
    }
    func testOfflineMigrationRoundTripAndRecoveryPreserveGrid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try fixture(directory, active: "000", corruptLink: true)
        let source = try fixture(directory, active: "002")
        let result = try LogicProjectImporter.read(source)
        var openedProject = result.project
        GlobalProjectTiming(bpm: 200).applyOnOpen(to: &openedProject)
        XCTAssertEqual(openedProject, result.project, "global timing cannot move imported clips or markers")
        XCTAssertFalse(openedProject.songs[0].tempoMarkersAffectAudio)
        let destination = directory.appendingPathComponent("Migrated.jl")
        try LogicProjectImporter.save(result, to: destination)
        let loaded = try await ProjectStore(url: destination).load()
        XCTAssertEqual(loaded, result.project)
        let song = try XCTUnwrap(loaded?.songs.first)
        XCTAssertEqual(song.tracks[1].parentTrackID, song.tracks[0].id)
        let clip = try XCTUnwrap(song.tracks[1].clips.first)
        XCTAssertEqual(clip.startTime, 6, accuracy: 0.000001) // 4 beats at 60 + 4 at 120.
        XCTAssertEqual(clip.duration, 10)
        XCTAssertEqual(clip.sourceOffset, 1)
        XCTAssertEqual(clip.muted, true)
        XCTAssertEqual(song.parts[0].name, "Introduction")
        XCTAssertEqual(song.parts[0].endTime, 6)
        XCTAssertEqual(ProjectAudioRecovery.missingPaths(in: result.project, directory: directory), [clip.audioFile!.path])
        let search = directory.appendingPathComponent("Relink")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        let bytes = Data("original audio bytes".utf8)
        try bytes.write(to: search.appendingPathComponent("Guitar.wav"))
        let recovered = try ProjectAudioRecovery.restore(result.project, directory: directory, searching: search)
        XCTAssertTrue(recovered.remaining.isEmpty)
        XCTAssertEqual(recovered.recovered, [clip.audioFile!.path])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(clip.audioFile!.path)), bytes)
        let afterRecovery = try await ProjectStore(url: destination).load()
        XCTAssertEqual(afterRecovery, loaded)
    }
    func testBundledAudioCopiesAndExistingDestinationIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try fixture(directory)
        let audio = bundle.appendingPathComponent("Media/Audio Files/Guitar.wav")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("bundled audio".utf8); try bytes.write(to: audio)
        let result = try LogicProjectImporter.read(bundle)
        XCTAssertEqual(result.media.first?.source, audio)
        let destination = directory.appendingPathComponent("Copy.jl")
        try LogicProjectImporter.save(result, to: destination)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(result.media[0].relativePath)), bytes)
        let saved = try Data(contentsOf: destination)
        XCTAssertThrowsError(try LogicProjectImporter.save(result, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), saved)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }
    func testBrokenReferencesAndTruncatedDataFailWithoutPartialMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try fixture(directory, corruptLink: true)
        XCTAssertThrowsError(try LogicProjectImporter.read(bundle))
        let data = bundle.appendingPathComponent("Alternatives/000/ProjectData")
        try Data([0x23, 0x47]).write(to: data)
        XCTAssertThrowsError(try LogicProjectImporter.read(bundle))
    }

    func testMusicTrackAutomaticallyCreatesDrawerEntriesAcrossTempoChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try fixture(directory)
        let url = bundle.appendingPathComponent("Alternatives/000/ProjectData")
        var data = try Data(contentsOf: url)
        var extra = Data()
        var env = Data(count: 200); text("  MÚSICAS  ", in: &env, at: 158)
        extra.append(record("ivnE", body: env, owner: 0xc0000, kind: 20))
        var row = Data(count: 58); row[0] = 1; put(0xc0000, in: &row, at: 6)
        extra.append(record("karT", body: row, owner: 0x40000, index: 2))
        // Different UTF-8 name lengths exercise the variable field alignment.
        // +8 is deliberately zero: copied regions still resolve through +32.
        for (index, item) in [("Primeira", 0, 3840), ("Canção dois", 3840, 3840), ("Duplicate", 3840, 3840), ("Outside", 19200, 960)].enumerated() {
            let (name, tick, length) = item
            let owner = UInt64(0x100 + index * 4)
            var sequence = Data(count: 360); text(name, in: &sequence, at: 16)
            put(UInt64(length), in: &sequence, at: 78 + ((name.utf8.count + 1) & ~1))
            extra.append(record("qeSM", body: sequence, owner: Int(owner << 16)))
            var event = Data(count: 80); event[0] = 0x20
            put(UInt64(34560 + tick), in: &event, at: 4)
            put(3, in: &event, at: 20); put(owner, in: &event, at: 32)
            for offset in [23, 39, 55, 71] { event[offset] = 0x88 }
            extra.append(record("qSvE", body: event, owner: 0x40000))
        }
        data.append(extra); put(UInt64(data.count - 24), in: &data, at: 16)
        try data.write(to: url)
        let result = try LogicProjectImporter.read(bundle)
        let song = result.project.songs[0]
        let root = try XCTUnwrap(song.parts.first { $0.name == "Introduction" })
        let children = song.parts.filter { $0.parentRegionID == root.id }
        XCTAssertEqual(children.map(\.name), ["Primeira", "Canção dois"])
        XCTAssertEqual(children.map(\.startTime), [0, 4])
        XCTAssertEqual(children.map(\.endTime), [4, 6])
        XCTAssertTrue(song.parts.contains { $0.name == "Outside" && $0.parentRegionID == nil && $0.startTime == 12 && $0.endTime == 12.5 })
        let flags = (song.markers ?? []).filter { !$0.isTempo }
        XCTAssertEqual(flags.count, 3)
        XCTAssertEqual(flags.filter { $0.unifiedRegionID == root.id }.map(\.sourceRegionID), children.map { Optional($0.id) })
        XCTAssertEqual(song.markers?.filter(\.isTempo).count, 2)
        XCTAssertTrue(song.tracks[2].clips.isEmpty)
        XCTAssertFalse(result.warnings.contains { $0.contains("MIDI") })
        XCTAssertEqual(try Data(contentsOf: url), data, "the source is read-only")
    }

    func testMIDINotesTrimmedRepeatedRegionsChannelsAndTempoRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try fixture(directory)
        let url = bundle.appendingPathComponent("Alternatives/000/ProjectData")
        var data = try Data(contentsOf: url)
        let title = "Canção MIDI", owner = 0x1800000
        let alignedName = (title.utf8.count + 1) & ~1
        var sequence = Data(count: 360); text(title, in: &sequence, at: 16)
        put(960, in: &sequence, at: 22 + alignedName) // Source left trim, independent of placement.
        put(3840, in: &sequence, at: 78 + alignedName)
        data.append(record("qeSM", body: sequence, owner: owner))
        // Real Logic qSvE note layout (32 bytes, or 48 with extra metadata):
        // status/channel +0, tick +4 (origin 38400), velocity +11, pitch +12,
        // continuation 0x89 at +23 and duration +28. No note-off pairing needed.
        // Corroborated by Apple templates and LogicProFormatWriter format §8.5.
        var notes = Data()
        for (index, values) in [(0, 60, 100, 240, 1), (480, 61, 99, 960, 2), (1920, 73, 77, 960, 16), (3840, 85, 111, 1920, 4)].enumerated() {
            let (tick, pitch, velocity, length, channel) = values
            var note = Data(count: index == 2 ? 48 : 32)
            note[0] = 0x90 | UInt8(channel - 1)
            put(UInt64(38400 + tick), in: &note, at: 4)
            note[11] = UInt8(velocity); note[12] = UInt8(pitch); note[15] = 0x81
            note[16] = 64; note[23] = 0x89
            put(UInt64(length), in: &note, at: 28)
            if note.count == 48 { note[39] = 0xa7 }
            notes.append(note)
        }
        notes.append(Data([0xf1, 0, 0, 0, 255, 255, 255, 63, 0, 0, 0, 0, 0, 0, 0, 0]))
        data.append(record("qSvE", body: notes, owner: owner, version: 1))
        for (index, tick) in [1920, 7680].enumerated() {
            var placement = Data(count: 80); placement[0] = 0x20
            put(UInt64(34560 + tick), in: &placement, at: 4)
            put(2, in: &placement, at: 20); put(UInt64(owner >> 16), in: &placement, at: 32)
            if index == 1 { put(0x100, in: &placement, at: 12) }
            for offset in [23, 39, 55, 71] { placement[offset] = 0x88 }
            data.append(record("qSvE", body: placement, owner: 0x40000))
        }
        put(UInt64(data.count - 24), in: &data, at: 16); try data.write(to: url)
        let result = try LogicProjectImporter.read(bundle)
        let song = result.project.songs[0]
        let clips = song.tracks[1].clips.filter { $0.midi != nil }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.map(\.name), [title, title])
        XCTAssertEqual(clips.map(\.startTime), [2, 6])
        XCTAssertEqual(clips.map(\.duration), [3, 2])
        XCTAssertEqual(clips.map(\.sourceOffset), [0, 0])
        XCTAssertEqual(clips[0].midi?.notes.map(\.pitch), [61, 73, 85])
        XCTAssertEqual(clips[0].midi?.notes.map(\.velocity), [99, 77, 111])
        XCTAssertEqual(clips[0].midi?.notes.map(\.channel), [2, 16, 4])
        let first = song.midiPlaybackNotes(in: clips[0])
        XCTAssertEqual(first.map(\.start), [2, 3, 4.5])
        XCTAssertEqual(first.map(\.end), [2.5, 4, 5])
        XCTAssertEqual(clips[1].muted, true)
        var repeated = clips[1]; repeated.muted = false
        XCTAssertEqual(song.midiPlaybackNotes(in: repeated).map(\.start), [6, 6.5, 7.5])
        XCTAssertEqual(song.midiPlaybackNotes(in: repeated).map(\.end), [6.25, 7, 8])
        XCTAssertTrue(result.warnings.contains { $0.contains("Choose an instrument") })
        XCTAssertTrue(result.warnings.contains { $0.contains("visible bounds") })
        XCTAssertEqual(result.media.count, 1, "MIDI adds no fake audio references")
        let destination = directory.appendingPathComponent("MIDI.jl")
        try LogicProjectImporter.save(result, to: destination)
        let reopened = try await ProjectStore(url: destination).load()
        XCTAssertEqual(reopened, result.project)
        XCTAssertEqual(try Data(contentsOf: url), data, "source Logic project remains untouched")
        // A broken linked note must fail, instead of silently producing an empty region.
        let noteBytes = Data(notes.prefix(32))
        let range = try XCTUnwrap(data.range(of: noteBytes))
        data[range.lowerBound + 23] = 0x88
        try data.write(to: url)
        XCTAssertThrowsError(try LogicProjectImporter.read(bundle))
    }

    func testMixerUUIDLinkFractionalGainPanAndMuteRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try fixture(directory)
        let url = bundle.appendingPathComponent("Alternatives/000/ProjectData")
        let baseline = try Data(contentsOf: url)
        // Captured Logic faders: -9.8 dB and +2.1 dB. Uneven names and
        // strip table lengths ensure channel linkage never uses track order.
        let cases: [(UInt64, UInt64, UInt64, Double, Double)] = [
            (0x33325f1c, 0, 1, pow(10, -9.8 / 20), -1),
            (0x65908be0, 127, 0, pow(10, 2.1 / 20), 1),
            (0x5a000000, 64, 1, 1, 0),
            (0, 48, 0, 0, -0.25),
            (0x7f000000, 96, 1, pow(127.0 / 90, 2), 32.0 / 63)
        ]
        for (iteration, settings) in cases.enumerated() {
            let (fader, pan, mute, gain, balance) = settings
            var data = baseline
            var channels: [Data] = []
            for (index, name) in ["Áudio ímpar", "Track with a longer name"].enumerated() {
                var env = Data(count: 463 + ((name.utf8.count + 1) & ~1))
                text(name, in: &env, at: 158)
                let uuid = Data(repeating: UInt8(index + 1), count: 16)
                env.replaceSubrange((env.count - 16)..<env.count, with: uuid)
                data.append(record("ivnE", body: env, owner: (index + 1) << 18, kind: 20, version: 12))
                let count = index == 0 ? 13 : 0
                var strip = Data(count: 201 + 4 * count)
                put(UInt64(count), in: &strip, at: 26, width: 2)
                put(index == 0 ? fader : 0x5a000000, in: &strip, at: 116)
                put(index == 0 ? pan : 64, in: &strip, at: 89, width: 1)
                put(index == 0 ? mute : 0, in: &strip, at: 90, width: 1)
                strip.replaceSubrange((153 + 4 * count)..<(169 + 4 * count), with: uuid)
                channels.append(record("OCuA", body: strip, owner: 0x240000, kind: 14, version: 7))
            }
            for channel in channels.reversed() { data.append(channel) }
            put(UInt64(data.count - 24), in: &data, at: 16); try data.write(to: url)
            let result = try LogicProjectImporter.read(bundle)
            let track = result.project.songs[0].tracks[0]
            XCTAssertEqual(track.volume, gain, accuracy: 0.00000001)
            XCTAssertEqual(track.pan, balance, accuracy: 0.00000001)
            XCTAssertEqual(track.mute, mute != 0)
            XCTAssertEqual(result.project.songs[0].tracks[1].volume, 1)
            XCTAssertEqual(result.project.songs[0].tracks[1].pan, 0)
            XCTAssertFalse(result.project.songs[0].tracks[1].mute)
            XCTAssertFalse(result.warnings.contains { $0.contains("mixer channels") })
            let destination = directory.appendingPathComponent("Mixer-\(iteration)/Mixer.jl")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LogicProjectImporter.save(result, to: destination)
            let reopened = try await ProjectStore(url: destination).load()
            XCTAssertEqual(reopened, result.project)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testUnsupportedMixerIsExplicitAndTruncatedStripFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try fixture(directory)
        XCTAssertTrue(try LogicProjectImporter.read(bundle).warnings.contains { $0.contains("mixer channels") })
        let url = bundle.appendingPathComponent("Alternatives/000/ProjectData")
        var data = try Data(contentsOf: url)
        var strip = Data(count: 169)
        put(100, in: &strip, at: 26, width: 2) // Points outside the bounded record.
        data.append(record("OCuA", body: strip, owner: 0x240000, kind: 14, version: 7))
        put(UInt64(data.count - 24), in: &data, at: 16); try data.write(to: url)
        XCTAssertThrowsError(try LogicProjectImporter.read(bundle))
    }

    func testRealProjectsWhenProvided() throws {
        guard let directory = ProcessInfo.processInfo.environment["JARAS_LOGIC_FIXTURES"] else { throw XCTSkip("Local Logic fixtures not supplied") }
        for (filename, trackCount, clipCount, markerCount) in [
            ("VS SHOW KITARA 2026.logicx", 19, 315, 38),
            ("VS SHOW VICTOR SANTOS 2026 V4.logicx", 60, 1394, 86)
        ] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
            let original = try Data(contentsOf: url.appendingPathComponent("Alternatives/000/ProjectData"))
            let result = try LogicProjectImporter.read(url)
            let song = result.project.songs[0]
            XCTAssertFalse(result.warnings.contains { $0.contains("mixer channels") })
            XCTAssertEqual(song.tracks.count, trackCount)
            XCTAssertEqual(song.tracks.flatMap(\.clips).filter { $0.audioFile != nil }.count, clipCount)
            XCTAssertTrue(song.tracks.flatMap(\.clips).contains { $0.midi?.notes.isEmpty == false })
            XCTAssertEqual(song.markers?.filter { !$0.isTempo }.count, markerCount)
            XCTAssertTrue(song.tracks.flatMap(\.clips).allSatisfy { ($0.midi != nil || $0.audioFile?.path.hasPrefix("Stems/Logic-") == true) && $0.duration > 0 })
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("Alternatives/000/ProjectData")), original)
            print("LOGIC_REAL_IMPORT \(filename) tracks=\(song.tracks.count) clips=\(song.tracks.flatMap(\.clips).count) groups=\(song.tracks.filter { $0.parentTrackID != nil }.count) duration=\(song.duration) missing=\(result.media.filter { $0.source == nil }.count)")
            if trackCount == 19 {
                XCTAssertEqual(song.tracks[1].volume, pow(10, -9.8 / 20), accuracy: 0.00000001)
                XCTAssertEqual(song.tracks[2].volume, pow(10, 2.1 / 20), accuracy: 0.00000001)
                XCTAssertEqual(song.tracks[7].volume, pow(10, -5.0 / 20), accuracy: 0.00000001)
                XCTAssertEqual(song.tracks.indices.filter { song.tracks[$0].mute }, [1, 2, 3, 4, 5])
                XCTAssertTrue(song.tracks.allSatisfy { $0.pan == 0 })
                let block = try XCTUnwrap(song.parts.first { $0.name == "BL01 A CASA CAIU" })
                XCTAssertEqual(song.parts.filter { $0.parentRegionID == block.id }.map(\.name), ["A CASA CAIU", "TENTATIVAS EM VÃO", "LOUCA", "UM NOVO AMOR"])
                XCTAssertEqual(song.parts.filter { $0.parentRegionID != nil }.count, 26)
                XCTAssertTrue(song.parts.contains { $0.name == "ESPELHO DO PODER" && $0.parentRegionID != nil })
                XCTAssertEqual(song.tracks[7].name, "BASS")
                XCTAssertEqual(song.tracks[14].name, "KEY 2")
                let first = try XCTUnwrap(song.tracks[7].clips.first)
                XCTAssertEqual(first.startTime, 0)
                XCTAssertEqual(first.duration, 4382897.0 / 48000, accuracy: 0.000001)
                let muted = try XCTUnwrap(song.tracks[14].clips.first { $0.name == "KEY 2_6.80" })
                XCTAssertEqual(muted.muted, true)
            } else {
                XCTAssertEqual(song.tracks.first { $0.name == "18 - Cng H_33" }?.pan, -40.0 / 64)
                XCTAssertEqual(song.tracks.first { $0.name == "19 - Cng_19 L" }?.pan, 33.0 / 63)
                XCTAssertEqual(song.tracks[6].name, "KEY")
                XCTAssertEqual(song.tracks[7].parentTrackID, song.tracks[6].id)
            }
        }
    }
}
#endif
