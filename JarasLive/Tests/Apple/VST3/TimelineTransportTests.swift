import Foundation
import AVFoundation
import Darwin

@MainActor func runTimelineTransportTest() throws {
    let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"]!
    var error: NSError?
    let catalog = JarasVST3.scan(path, error: &error)[0]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    audio.open(directory: directory)
    var project = Project.empty(name: "Timeline host sync")
    var track = Track(id: UUID(), name: "VST3", role: .keys)
    let instance = ExternalPlugin(classID: catalog["classID"] as! String, name: "Gain fixture", path: path)
    var fx = NativeFXSettings(); fx.externalPlugins = [instance]; fx.inserted = [instance.effectKey]
    track.fx = fx; track.inputPatch = OutputPatch.none
    project.songs[0].tracks = [track]; project.masterFX = fx
    project.songs[0].bpm = 120
    project.songs[0].markers = [
        TimelineMarker(id: UUID(), name: "90", position: 10, color: 0, tempoBPM: 90, tempoBeats: 7, tempoUnit: 8),
        TimelineMarker(id: UUID(), name: "60", position: 20, color: 0, tempoBPM: 60, tempoBeats: 3, tempoUnit: 4)
    ]
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 9.99, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    audio.setArmedInstrumentTracks([track.id])
    if !engine.isRunning { try engine.start() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func context(_ target: UUID?) -> [Double] {
        let node = audio.effects(for: target)!.externalNode(instance.id)!
        let state = JarasVST3.state(node, identifier: instance.id)!
        let bytes = Data(base64Encoded: state["componentState"] as! String)!
        return bytes.withUnsafeBytes { raw in (0..<8).map { raw.loadUnaligned(fromByteOffset: 12 + $0 * 8, as: Double.self) } }
    }
    func render() throws { let result = try engine.renderOffline(512, to: buffer); precondition(result == .success) }
    func near(_ a: Double, _ b: Double) { precondition(abs(a-b)<0.0001, "\(a) != \(b)") }
    for block in 0..<4 {
        try render()
        for target in [track.id, nil] {
            let values = context(target), seconds = 9.99 + Double(block*512)/48000
            near(values[0], seconds < 10 ? 120 : 90); near(values[2],seconds)
            near(values[1], seconds < 10 ? seconds*2 : 20+(seconds-10)*1.5)
        }
    }
    snapshot.transport.playing = false; snapshot.transport.position = 0; snapshot.transport.editPosition = 22
    try audio.update(snapshot, revision: 1)
    try engine.start()
    for _ in 0..<3 {
        try render()
        for target in [track.id, nil] { let values=context(target); near(values[0],60); near(values[1],37); near(values[2],22);near(values[6],0) }
    }
    snapshot.transport.editPosition = 2; snapshot.project.songs[0].bpm = 100
    try audio.update(snapshot, revision: 1) // Preview can retain the structural revision.
    try engine.start(); try render(); near(context(track.id)[0],100)
    audio.prepareForClosing()
    print("TIMELINE_TRACK_AND_MASTER_VST3_MAP_IDLE_CURSOR_AND_LIVE_BPM_OK")
}
Task { @MainActor in
    do { try runTimelineTransportTest(); exit(0) }
    catch { print(error); exit(1) }
}
RunLoop.main.run()
