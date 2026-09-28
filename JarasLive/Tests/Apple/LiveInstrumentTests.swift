import Foundation
import AVFoundation
@MainActor func run() throws {
    let engine = AVAudioEngine()
    let renderer = StemAudioPlayback(engine: engine)
    renderer.onError = { error in print("LIVE_INSTRUMENT_ERROR",error); exit(1) }
    let sf2 = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JARAS_TEST_SF2"]!)
    let mediaName = UUID().uuidString + ".wav"
    let media = sf2.deletingLastPathComponent().appendingPathComponent(mediaName)
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: media, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 44100) }
        try file.write(from: buffer)
    }
    renderer.instrumentFile = { _ in (sf2,false) }
    renderer.open(directory: sf2.deletingLastPathComponent())
    var project = Project.empty(name: "Live instrument validation")
    var track = Track(id: UUID(),name: "Instrument",role: .keys)
    var fx = NativeFXSettings(); fx.instrumentID = "gemani-pad"; fx.inserted = ["Instruments"]
    track.clips = [AudioClip(id: UUID(), name: "Silent graph validation", startTime: 0, duration: 1, audioFile: AudioFile(path: mediaName))]
    track.fx = fx; project.songs[0].tracks = [track]; project.songs[0].duration = 120
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false,position: 0)))
    try renderer.update(snapshot,revision: 1)
    DispatchQueue.main.asyncAfter(deadline: .now()+0.2) {
        snapshot.transport.playing = true
        do { try renderer.update(snapshot,revision: 1) } catch { print(error); exit(1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now()+2) {
        precondition(renderer.isInstrumentReady(track.id), "instrument must be attached to the running audio graph")
        snapshot.project.songs[0].tracks[0].fx?.instrumentID = "replacement"
        do { try renderer.update(snapshot, revision: 2) } catch { print(error); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now()+2) {
            precondition(renderer.isInstrumentReady(track.id), "replacement must finish attaching")
            snapshot.transport.playing = false
            do { try renderer.update(snapshot, revision: 2) } catch { print(error); exit(1) }
            renderer.stop()
            try? FileManager.default.removeItem(at: media)
            print("LIVE_INSTRUMENT_GRAPH_REPLACE_STOP_OK")
            exit(0)
        }
    }
}
DispatchQueue.main.async { do { try run() } catch { print(error); exit(1) } }
RunLoop.main.run()
