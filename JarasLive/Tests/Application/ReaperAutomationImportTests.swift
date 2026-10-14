import XCTest
@testable import JarasApplication
#if os(macOS)
final class ReaperAutomationImportTests: XCTestCase {
    private let classID = "1234123456785678ABCDEF0012345678"
    // Captured from a disposable REAPER instance with GainFixture set to .73.
    private let routing = "Ws5aH+5e7f4CAAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAAAAAAIAAAAAAAAAKAAAAAEAAAD//wAA"
    private let state = "DAAAAAEAAABI4To/AAAAAAAAAAAMAAAAAAAAAEjhOj8AAAAAAAAAAA=="
    private let payload = "SOE6PwAAAAAAAAAA"
    private func fixture(_ body: String) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Automation.rpp")
        try ("<REAPER_PROJECT 0.1\nTEMPO 120 4 4\n" + body + "\n>\n").write(to: file, atomically: true, encoding: .utf8)
        return (folder, file)
    }
    private func vst(_ parameter: String = "0:7001") -> String { """
    BYPASS 0 0 0
    <VST "VST3: Gain fixture" GainFixture.vst3 0 "" 526044762{\(classID)} ""
      \(routing)
      \(state)
      AAAAAAAA
    >
    <PARMENV \(parameter) 0 1 0.5 "Gain / Gain fixture"
      ACT 1 -1
      VIS 0 1 1
      ARM 1
      PT 0 0.23 0
      PT 4 0.81 1
    >
    """ }
    private func resolved(_ request: ReaperProjectImporter.VST3Request) -> ReaperProjectImporter.VST3Resolution {
        var plugin = request.plugin
        plugin.path = "/Library/Audio/Plug-Ins/VST3/GainFixture.vst3"
        return .init(plugin: plugin, parameterIDs: [0: 7001])
    }
    func testVST3OpaqueStatesAreUnwrappedExactlyAndRejectMalformedPayload() throws {
        let states = try ReaperProjectImporter.vst3States([routing, state, "AAAAAAAA"])
        XCTAssertEqual(states.component, payload)
        XCTAssertEqual(states.controller, payload)
        let gain = try XCTUnwrap(Data(base64Encoded: states.component!)).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(gain, 0.73, accuracy: 0.000001)
        XCTAssertThrowsError(try ReaperProjectImporter.vst3States([routing, "broken"]))
        XCTAssertThrowsError(try ReaperProjectImporter.vst3States([routing, "AAAAAAAA"]))
    }
    func testMalformedVST3EnvelopeIdentityIsRejectedWithoutIndexingEmptyFields() throws {
        for parameter in [":", "\"\"", "0:", "::", "0:invalid", "0:1:2", "-1", "invalid"] {
            let (folder, file) = try fixture("<TRACK\nNAME FX\n<FXCHAIN\n\(vst(parameter))\n>\n>")
            defer { try? FileManager.default.removeItem(at: folder) }
            XCTAssertThrowsError(try ReaperProjectImporter.read(file, resolveVST3: resolved), parameter)
        }
    }
    func testTrackAndMasterFXStateAutomationAndUnsupportedFormats() throws {
        let (folder, file) = try fixture("""
        MASTER_VOLUME 0.8 -0.2
        <MASTERFXLIST
          \(vst())
        >
        <VOLENV2
          ACT 1 -1
          VIS 0 1 1
          PT 0 0.1 0
          PT 4 1 1
        >
        <TRACK
          NAME Synth
          VOLPAN 0.5 0.25
          IPHASE 1
          <FXCHAIN
            BYPASS 0 0 0
            <VST "VST: ReaComp (Cockos)" reacomp.vst.dylib 0 "" 1919247213 ""
              AAAA
            >
            <PARMENV 0 0 1 0.5
              PT 0 0.9 0
            >
            \(vst("0"))
          >
          <PANENV2
            ACT 0 -1
            VIS 1 1 1
            PT 0 -1 0
            PT 4 1 0
          >
          <MUTEENV
            ACT 1 -1
            VIS 0 1 1
            PT 0 1 1
            PT 4 0 1
          >
        >
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: file)
        let result = try ReaperProjectImporter.read(file, resolveVST3: resolved)
        let track = result.project.songs[0].tracks[0]
        XCTAssertTrue(track.phaseInverted == true)
        XCTAssertEqual(track.fx?.inserted.count, 1)
        XCTAssertEqual(track.fx?.externalPlugins?.first?.componentState, payload)
        XCTAssertEqual(result.project.masterFX?.externalPlugins?.first?.controllerState, payload)
        XCTAssertEqual(result.project.masterPan, -0.2)
        let master = try XCTUnwrap(result.project.masterAutomation)
        XCTAssertEqual(master.active.count, 2)
        let volume = try XCTUnwrap(master.envelopes.first { $0.target.kind == .volume })
        XCTAssertEqual(TrackEnvelope.gain(volume.value(at: 2)), 0.55, accuracy: 0.000001)
        let automation = try XCTUnwrap(track.automation)
        XCTAssertEqual(automation.envelopes.count, 3)
        XCTAssertEqual(automation.active.count, 2) // ACT0 pan stays disabled; VIS0 active lanes stay audible.
        let parameter = try XCTUnwrap(automation.envelopes.first { $0.target.kind == .externalFX })
        XCTAssertEqual(parameter.target.parameter, 7001)
        XCTAssertEqual(parameter.target.plugin, track.fx?.externalPlugins?.first?.id)
        XCTAssertEqual(parameter.value(at: 2), 0.52, accuracy: 0.000001)
        let mute = try XCTUnwrap(automation.envelopes.first { $0.target.kind == .mute })
        XCTAssertEqual(mute.value(at: 1), 0)
        XCTAssertEqual(mute.value(at: 4), 1)
        XCTAssertEqual(result.warnings.count, 1, result.warnings.description)
        XCTAssertTrue(result.warnings.contains { $0.contains("ReaComp") && $0.contains("only VST3") })
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(result.project)), result.project)
    }
    func testWarningTemplatesUseSelectedLanguageWithoutChangingNamesOrPercentSigns() throws {
        let trackName = "Pista \"principal\" 100%"
        let pluginName = "JS: Compressor \"Master\" 50% %@"
        let (folder, file) = try fixture("""
        <TRACK
          NAME `\(trackName)`
          <FXCHAIN
            <JS `\(pluginName)`
            >
            \(vst("0"))
          >
        >
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: file)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Apple/Resources")
        for language in ["pt-BR", "en"] {
            let bundle = try XCTUnwrap(Bundle(path: resources.appendingPathComponent(language + ".lproj").path))
            let imported = try ReaperProjectImporter.read(file, localizeWarning: {
                bundle.localizedString(forKey: $0, value: $0, table: nil)
            })
            let unsupported = language == "pt-BR"
                ? "\(trackName): \(pluginName) não foi importado; somente efeitos VST3 são compatíveis com a importação do REAPER."
                : "\(trackName): \(pluginName) was not imported; only VST3 effects are supported during REAPER migration."
            XCTAssertTrue(imported.warnings.contains(unsupported), imported.warnings.description)
            XCTAssertTrue(imported.warnings.contains { $0.contains(trackName) && $0.contains("Gain fixture") && $0.contains(language == "pt-BR" ? "não foi encontrado" : "was not found") })
            XCTAssertTrue(imported.warnings.contains { $0.contains(language == "pt-BR" ? "parâmetro de automação" : "automation parameter") })
            XCTAssertEqual(imported.project.songs[0].tracks[0].name, trackName)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
    func testInvalidVST3StateWarningsLocalizeTheDetailAfterTheREAPERPrefix() throws {
        let invalidState = vst().replacingOccurrences(of: state, with: "broken")
        let (folder, file) = try fixture("<TRACK\nNAME FX\n<FXCHAIN\n\(invalidState)\n>\n>")
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Apple/Resources")
        for language in ["pt-BR", "en"] {
            let bundle = try XCTUnwrap(Bundle(path: resources.appendingPathComponent(language + ".lproj").path))
            let imported = try ReaperProjectImporter.read(file, resolveVST3: { request in
                var plugin = request.plugin; plugin.classID = String(repeating: "0", count: 32)
                return .init(plugin: plugin)
            }, localizeWarning: { bundle.localizedString(forKey: $0, value: $0, table: nil) })
            let expected = language == "pt-BR"
                ? "FX: a configuração de Gain fixture não foi importada: REAPER: Codificação ou tamanho inválido da configuração do VST3."
                : "FX: Gain fixture state was not imported: REAPER: Invalid VST3 state encoding or size."
            XCTAssertTrue(imported.warnings.contains(expected), imported.warnings.description)
            let resolverDetail = language == "pt-BR"
                ? "REAPER: A busca do VST3 retornou uma classe de plug-in diferente."
                : "REAPER: VST3 resolver returned a different plugin class."
            XCTAssertTrue(imported.warnings.contains { $0.contains(resolverDetail) }, imported.warnings.description)
            XCTAssertTrue(imported.project.songs[0].tracks[0].fx?.inserted.isEmpty == true)
        }
    }
    func testFaderScaledEnvelopeMatchesREAPEROracle() throws {
        let (folder, file) = try fixture("""
        <TRACK
          NAME Dynamics
          <VOLENV2
            ACT 1 -1
            VOLTYPE 1
            PT 0 0.1 0
            PT 4 1 0
          >
        >
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try ReaperProjectImporter.read(file)
        let envelope = try XCTUnwrap(result.project.songs[0].tracks[0].automation?.envelopes.first)
        for (time, gain) in [(0.0, 0.1), (1, 0.20008139230339), (2, 0.3622085862061), (3, 0.61503968429076), (4, 1)] {
            XCTAssertEqual(TrackEnvelope.gain(envelope.value(at: time)), gain, accuracy: 0.000011)
        }
        XCTAssertLessThan(envelope.points.count, 1000)
    }
    func testBothAudioAndMIDITakesRetainBoundsOffsetsRatesPitchAndOwnFX() throws {
        let (folder, file) = try fixture("""
        <TRACK
          NAME teste
          <ITEM
            POSITION 10
            LENGTH 4
            NAME "Audio take"
            SOFFS 3
            PLAYRATE 2 1 -2
            VOLPAN -0.8 -0.3 0.5
            <SOURCE WAVE
              FILE take.wav
            >
            <TAKEFX
              \(vst())
            >
            <VOLENV
              ACT 1
              VIS 0 1 1
              PT 0 0.1 0
              PT 4 1 1
            >
            TAKE SEL
            NAME "MIDI take"
            SOFFS 0
            PLAYRATE 1 1 3
            <SOURCE MIDI
              HASDATA 1 960 QN
              E 0 90 3c 64
              E 960 80 3c 00
              E 6720 b0 7b 00
            >
            <TAKEFX
              \(vst())
            >
          >
        >
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try ReaperProjectImporter.read(file, resolveVST3: resolved)
        let track = result.project.songs[0].tracks[0], clips = track.clips
        XCTAssertEqual(clips.map(\.name), ["Audio take", "MIDI take"])
        XCTAssertEqual(clips.map(\.startTime), [10, 10])
        XCTAssertEqual(clips.map(\.duration), [4, 4])
        XCTAssertTrue(clips[0].muted == true)
        XCTAssertFalse(clips[1].muted == true)
        XCTAssertEqual(clips[0].sourceOffset, 3)
        XCTAssertEqual(clips[0].audioRate, 2)
        XCTAssertEqual(clips[0].pitchSemitones, -2)
        XCTAssertEqual(clips[0].gain, 0.4)
        XCTAssertEqual(clips[0].pan, -0.3)
        XCTAssertTrue(clips[0].phaseInverted == true)
        XCTAssertEqual(clips[1].pitchSemitones, 3)
        XCTAssertEqual(clips[1].midi?.notes.count, 1)
        XCTAssertEqual(clips[1].sourceOffset, 0)
        XCTAssertEqual(clips[1].audioRate, 1)
        XCTAssertEqual(TrackLanes(track: track).count, 2)
        XCTAssertEqual(clips.compactMap { $0.fx?.externalPlugins?.first?.componentState }, [payload, payload])
        XCTAssertNotEqual(clips[0].fx?.externalPlugins?.first?.id, clips[1].fx?.externalPlugins?.first?.id)
        let envelope = try XCTUnwrap(clips[0].automation?.envelopes.first { $0.target.kind == .volume })
        XCTAssertEqual(envelope.points.map(\.time), [3, 7])
        XCTAssertEqual(TrackEnvelope.gain(envelope.value(at: 5)), 0.55, accuracy: 0.000001)
        XCTAssertEqual(clips[1].automation?.envelopes.first?.target.plugin, clips[1].fx?.externalPlugins?.first?.id)
        XCTAssertTrue(result.warnings.contains { $0.contains("MIDI take VST3") && $0.contains("not applied") })
        XCTAssertTrue(result.warnings.contains { $0.contains("no compatible VST3 instrument was inserted on this track") })
        XCTAssertTrue(result.warnings.contains { $0.contains("MIDI take automation") && $0.contains("shared track instrument") })
    }
    func testMIDITakeAutomationClockFollowsFlattenedTakeRate() throws {
        let (folder, file) = try fixture("""
        <TRACK
          NAME MIDI
          <ITEM
            POSITION 10
            LENGTH 4
            PLAYRATE 2 1 0
            SOFFS 0.75
            LOOP 1
            <SOURCE MIDI
              HASDATA 1 960 QN
              E 0 90 3c 64
              E 960 80 3c 00
              E 6720 b0 7b 00
            >
            <VOLENV
              ACT 1
              VIS 0 1 1
              PT 0 0.1 0
              PT 4 1 0
            >
            <TAKEFX
              \(vst().replacingOccurrences(of: "VST3:", with: "VST3i:"))
            >
          >
        >
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try ReaperProjectImporter.read(file, resolveVST3: resolved)
        let clip = result.project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(clip.sourceOffset, 0)
        XCTAssertEqual(clip.audioRate, 1)
        let automation = try XCTUnwrap(clip.automation)
        let volume = try XCTUnwrap(automation.envelopes.first { $0.target.kind == .volume })
        XCTAssertEqual(volume.points.map(\.time), [0, 2])
        XCTAssertEqual(TrackEnvelope.gain(volume.value(at: clip.automationTime(at: 11))), 0.55, accuracy: 0.000001)
        let effect = try XCTUnwrap(automation.envelopes.first { $0.target.kind == .externalFX })
        XCTAssertEqual(effect.points.map(\.time), [0, 2])
        XCTAssertEqual(effect.value(at: clip.automationTime(at: 11)), 0.52, accuracy: 0.000001)
        XCTAssertFalse(result.warnings.contains { $0.contains("MIDI take automation") || $0.contains("MIDI take VST3") || $0.contains("Choose an instrument") }, result.warnings.description)
    }
    func testLiveReferenceMIDIAndRenderedAudioTakeStayTogether() throws {
        // Same structure read from the user's unsaved REAPER 'teste' item:
        // MIDI first, TAKE SEL rendered audio second, newer TAKEVOLPAN layout.
        let (folder, file) = try fixture("""
        <TRACK
          NAME teste
          <ITEM
            POSITION 3221.430093610084
            LENGTH 32.30769230769829
            LOOP 1
            ALLTAKES 0
            NAME 16-teste-MIDI-glued
            VOLPAN 0.8 0 1 -1
            SOFFS 0 0
            PLAYRATE 1 1 0 -1 0 0.0025
            <SOURCE MIDI
              HASDATA 1 960 QN
              E 11520 90 30 60
              E 960 90 30 60
              e 0 90 25 60
              E 1920 90 22 60
              E 4800 90 29 60
              E 0 90 29 60
              E 208 80 29 00
              E 752 90 22 60
              E 3840 80 22 00
              E 1920 80 30 00
              E 0 90 3c 60
              e 960 80 25 00
              E 2880 80 30 00
              E 4800 80 29 00
              E 3840 90 34 60
              E 3840 80 22 00
              E 1920 80 3c 00
              E 3840 90 2c 60
              E 9600 80 34 00
              E 6720 80 2c 00
              E 16320 b0 7b 00
              IGNTEMPO 0 120 4 4
            >
            TAKE SEL
            NAME "16-teste-MIDI-glued render 001.wav"
            TAKEVOLPAN 0.2 0.5 -1
            SOFFS 0
            PLAYRATE 1 1 0 -1 0 0.0025
            <SOURCE WAVE
              FILE reference-render.wav
            >
          >
        >
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try ReaperProjectImporter.read(file)
        let track = result.project.songs[0].tracks[0]
        XCTAssertEqual(track.clips.count, 2)
        XCTAssertEqual(TrackLanes(track: track).count, 2)
        XCTAssertNotNil(track.clips[0].midi)
        XCTAssertGreaterThan(track.clips[0].midi?.notes.count ?? 0, 5)
        XCTAssertNotNil(track.clips[1].audioFile)
        XCTAssertEqual(track.clips[0].startTime, track.clips[1].startTime)
        XCTAssertEqual(track.clips[0].duration, track.clips[1].duration)
        XCTAssertTrue(track.clips[0].muted == true)
        XCTAssertFalse(track.clips[1].muted == true)
        XCTAssertEqual(track.clips[1].pan, 0.2)
        XCTAssertEqual(track.clips[1].gain, 0.4)
        let all = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "ALLTAKES 0", with: "ALLTAKES 1")
        try all.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ReaperProjectImporter.read(file).project.songs[0].tracks[0].clips.allSatisfy { $0.muted != true })
    }
    func testMissingVST3PreservesPresetOutsideRunnableChainWithClearWarning() throws {
        let (folder, file) = try fixture("<TRACK\nNAME FX\n<FXCHAIN\n\(vst())\n>\n>")
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try ReaperProjectImporter.read(file)
        let plugin = try XCTUnwrap(result.project.songs[0].tracks[0].fx?.externalPlugins?.first)
        XCTAssertTrue(plugin.bypassed)
        XCTAssertEqual(result.project.songs[0].tracks[0].fx?.inserted, [])
        XCTAssertEqual(plugin.classID, classID)
        XCTAssertEqual(plugin.componentState, payload)
        XCTAssertTrue(result.warnings.contains { $0.contains("was not found") })
    }
}
#endif
