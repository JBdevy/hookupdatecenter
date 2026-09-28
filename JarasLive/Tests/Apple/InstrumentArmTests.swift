import Foundation
import AVFoundation

try MainActor.assumeIsolated {
    let sf2 = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JARAS_TEST_SF2"]!)
    let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.onError = { error in fatalError(error.localizedDescription) }
    audio.instrumentFile = { _ in (sf2, false) }
    audio.midiSlotsProvider = { [123, 0, 0] }
    audio.open(directory: sf2.deletingLastPathComponent())
    var project = Project.empty(name: "Instrument MIDI arm")
    var track = Track(id: UUID(), name: "SF2", role: .keys)
    var fx = NativeFXSettings(); fx.instrumentID = "gemani-pad"; fx.inserted = ["Instruments"]
    var params = InstrumentParameters(); params.release = 0.001
    fx.instrumentParameters = params
    track.fx = fx; track.midiInput = 1
    project.songs[0].tracks = [track]
    let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let deadline = Date().addingTimeInterval(10)
    while !audio.isInstrumentReady(track.id) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(audio.isInstrumentReady(track.id))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func render(_ blocks: Int = 12) throws -> Float {
        var peak: Float = 0
        for index in 0..<blocks {
            let status = try engine.renderOffline(512, to: buffer); precondition(status == .success)
            if index >= blocks - 4 {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][frame])) }
            }
        }
        return peak
    }
    func peak(_ blocks: Int = 12) -> Float { do { return try render(blocks) } catch { fatalError(error.localizedDescription) } }
    @MainActor func midi(_ status: UInt8, _ number: UInt8, _ value: UInt8) { audio.receiveMIDI(device: 123, status: status, number: number, value: value) }
    midi(0x90, 60, 100)
    precondition(peak() < 0.000001, "SF2 rejects note-on without Rec arm")
    audio.setArmedInstrumentTracks([track.id]); midi(0x90, 60, 100)
    precondition(peak() > 0.0001, "SF2 accepts notes while armed")
    audio.setArmedInstrumentTracks([])
    precondition(peak() > 0.0001, "disarming SF2 does not cut the playing note")
    midi(0x80, 60, 0)
    precondition(peak(50) < 0.00001, "note-off releases SF2 while unarmed")
    midi(0x90, 62, 100)
    precondition(peak() < 0.00001, "new SF2 notes remain blocked after disarming")
    audio.setArmedInstrumentTracks([track.id]); midi(0xb0, 64, 127); midi(0x90, 60, 100)
    precondition(peak() > 0.0001)
    midi(0x80, 60, 0); audio.setArmedInstrumentTracks([])
    precondition(peak() > 0.0001, "sustain continues sounding after disarm")
    midi(0xb0, 64, 0)
    precondition(peak(50) < 0.00001, "sustain up still releases SF2 while unarmed")
    audio.prepareForClosing()
    print("SF2_REC_ARM_NEW_NOTES_ONLY_NOTE_OFF_SUSTAIN_CONTINUE_PCM_OK")
}
