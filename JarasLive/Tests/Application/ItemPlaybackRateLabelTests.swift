import XCTest
@testable import JarasApplication

final class ItemPlaybackRateLabelTests: XCTestCase {
    private func label(_ clip: AudioClip, in song: Song) -> String {
        TimelineItemPlaybackRate.title(clip.name, rates: song.tempoAudioSegments(clip).map(\.audioRate),
            referenceRate: clip.tempoBasePlaybackRate ?? clip.audioRate)
    }

    func testLabelFollowsActualTempoSpeedAndDisappearsWhenRestored() {
        var song = Project.empty(name: "Rate label").songs[0]
        song.bpm = 120; song.duration = 20
        let clip = AudioClip(id: UUID(), name: "Stem.wav", startTime: 0, duration: 10)
        song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 0, color: 0,
            tempoBPM: 120, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        XCTAssertEqual(label(clip, in: song), "Stem.wav")
        song.markers![0].tempoBPM = 150
        XCTAssertEqual(label(clip, in: song), "[1.25] Stem.wav")
        song.markers![0].tempoBPM = 90
        XCTAssertEqual(label(clip, in: song), "[0.75] Stem.wav")
        song.markers![0].tempoBPM = 120
        XCTAssertEqual(label(clip, in: song), "Stem.wav")
    }

    func testItemRateAndOwnedTempoAreCombinedWithoutForeignTempoChanges() {
        var song = Project.empty(name: "Owned item").songs[0]
        song.bpm = 120; song.duration = 30
        let own = Part(id: UUID(), name: "First song", startTime: 0, endTime: 10)
        let other = Part(id: UUID(), name: "Second song", startTime: 10, endTime: 30)
        song.parts = [own, other]
        let clip = AudioClip(id: UUID(), name: "Tail.wav", startTime: 0, duration: 20,
            playbackRate: 1.25, regionOwnerID: own.id)
        song.markers = [
            TimelineMarker(id: UUID(), name: "Own", position: 0, color: 0, regionOwnerID: own.id,
                tempoBPM: 144, tempoTimebase: .relative, tempoReferenceBPM: 120),
            TimelineMarker(id: UUID(), name: "Other", position: 10, color: 0, regionOwnerID: other.id,
                tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)
        ]
        XCTAssertEqual(label(clip, in: song), "[1.5] Tail.wav")
        song.markers!.append(TimelineMarker(id: UUID(), name: "Own change", position: 5, color: 0,
            regionOwnerID: own.id, tempoBPM: 120, tempoTimebase: .relative, tempoReferenceBPM: 120))
        XCTAssertEqual(label(clip, in: song), "[1.25–1.5] Tail.wav")
    }

    func testManualAndPrintedRatesDoNotImplyBPMAdjustment() {
        var song = Project.empty(name: "Printed item").songs[0]
        song.bpm = 120; song.duration = 20
        song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 0, color: 0,
            tempoBPM: 180, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        var clip = AudioClip(id: UUID(), name: "Printed.wav", startTime: 0, duration: 10,
            playbackRate: 1.1, renderedTiming: true)
        XCTAssertEqual(label(clip, in: song), "Printed.wav")
        clip.renderedTiming = nil; clip.frozenMIDI = true
        XCTAssertEqual(label(clip, in: song), "Printed.wav")
        clip.frozenMIDI = nil; song.markers![0].tempoTimebase = .free
        XCTAssertEqual(label(clip, in: song), "Printed.wav")
        clip.playbackRate = 1.0005
        XCTAssertEqual(label(clip, in: song), "Printed.wav")
        clip.playbackRate = 1
        clip.renderedTiming = true; song.markers![0].tempoTimebase = .relative
        XCTAssertEqual(label(clip, in: song), "Printed.wav", "The printed file must not display its already baked tempo")
        clip.renderedTiming = nil; clip.renderedTempo = true
        XCTAssertEqual(label(clip, in: song), "Printed.wav")
        clip.renderedTempo = nil; clip.playbackRate = 1.25; song.markers![0].tempoBPM = 120
        XCTAssertEqual(label(clip, in: song), "Printed.wav", "An imported rate under an unchanged relative BPM stays unlabelled")
        song.markers![0].tempoBPM = 144
        XCTAssertEqual(label(clip, in: song), "[1.5] Printed.wav", "A later BPM edit exposes the actual combined rate")
    }

    func testLabelsUseAtMostTwoDecimalsAndCollapseIndistinguishableRanges() {
        XCTAssertEqual(TimelineItemPlaybackRate.title("Stem", rates: [1.176657]), "[1.18] Stem")
        XCTAssertEqual(TimelineItemPlaybackRate.title("Stem", rates: [0.876543]), "[0.88] Stem")
        XCTAssertEqual(TimelineItemPlaybackRate.title("Stem", rates: [1.2501, 1.2549]), "[1.25] Stem")
        XCTAssertEqual(TimelineItemPlaybackRate.title("Stem", rates: [0.87654, 1.176657]), "[0.88–1.18] Stem")
        XCTAssertEqual(TimelineItemPlaybackRate.title("Stem", rates: [0.9999, 1.0005]), "Stem")
        XCTAssertEqual(TimelineItemPlaybackRate.title("Stem", rates: [.nan, .infinity, -1, 0]), "Stem")
    }

    func testGlobalBPMEditsStayVisibleWithoutTempoMarkers() {
        var song = Project.empty(name: "Global tempo").songs[0]
        song.bpm = 120; song.duration = 20
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Stem", startTime: 0, duration: 10)]
        song.tracks = [track]
        song.followTempo(140)
        XCTAssertEqual(song.tracks[0].clips[0].tempoBasePlaybackRate, 1)
        XCTAssertEqual(label(song.tracks[0].clips[0], in: song), "[1.17] Stem")
        song.followTempo(120)
        XCTAssertEqual(label(song.tracks[0].clips[0], in: song), "Stem")
    }

    func testGlobalBPMReferenceSurvivesRoundTripAndDoesNotMistakeImportedSpeed() throws {
        var song = Project.empty(name: "Imported rate").songs[0]
        song.bpm = 120; song.duration = 20
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Imported", startTime: 0, duration: 10, playbackRate: 1.25)]
        song.tracks = [track]
        XCTAssertEqual(label(song.tracks[0].clips[0], in: song), "Imported")
        song.followTempo(144)
        XCTAssertEqual(song.tracks[0].clips[0].tempoBasePlaybackRate, 1.25)
        XCTAssertEqual(label(song.tracks[0].clips[0], in: song), "[1.5] Imported")
        song = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(label(song.tracks[0].clips[0], in: song), "[1.5] Imported")
        song.followTempo(120)
        XCTAssertEqual(label(song.tracks[0].clips[0], in: song), "Imported")
    }
}
