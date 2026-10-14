import Foundation
import AVFoundation

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

/// The left channel is an untouched reference stem. Every edit must preserve
/// its exact source samples, including the first buffer after a graph change.
/// Other items sound only on the right, so deleting or muting them is audible
/// without hiding a restart or gap in the reference stem.
@MainActor func runPlaybackEditingContinuityTests() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playback-edits-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 30))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0, count: Int(pcm.frameLength)) }
    for frame in 0..<Int(pcm.frameLength) { pcm.floatChannelData![0][frame] = Float(frame % 4096 + 1) / 65536 }
    try AVAudioFile(forWriting: directory.appendingPathComponent("reference.wav"), settings: format.settings).write(from: pcm)
    pcm.floatChannelData![0].update(repeating: 0, count: Int(pcm.frameLength))
    pcm.floatChannelData![1].update(repeating: 0.02, count: Int(pcm.frameLength))
    try AVAudioFile(forWriting: directory.appendingPathComponent("editing.wav"), settings: format.settings).write(from: pcm)
    var project = Project.empty(name: "Playback editing continuity")
    var reference = Track(id: UUID(), name: "Untouched reference", role: .other)
    reference.clips = [AudioClip(id: UUID(), name: "Reference", startTime: 0, duration: 30, audioFile: AudioFile(path: "reference.wav"))]
    var edited = Track(id: UUID(), name: "Editing target", role: .other)
    let originalItem = AudioClip(id: UUID(), name: "Target", startTime: 0, duration: 30, audioFile: AudioFile(path: "editing.wav"))
    edited.clips = [originalItem]
    project.songs[0].tracks = [reference, edited]
    var timing = project.songs[0].projectTime; timing.timebase = .free
    project.songs[0].timeSettings = timing
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    // Pull both graphs by sample clock: AVAudioPlayerNode host deadlines are
    // undefined when several realtime voices are run by an offline device.
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    let referenceEngine = AVAudioEngine()
    try referenceEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let referenceAudio = StemAudioPlayback(engine: referenceEngine, realtime: false)
    var referenceState = state
    referenceState.project.songs[0].tracks = [reference]
    referenceAudio.open(directory: directory)
    try referenceAudio.update(referenceState, revision: 1)
    defer { audio.prepareForClosing(); referenceAudio.prepareForClosing() }
    var errors: [Error] = []
    audio.onError = { errors.append($0) }
    audio.open(directory: directory)
    var revision: UInt64 = 1
    try audio.update(state, revision: revision)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    let expectedOutput = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var heardReference = false
    func update() throws {
        state.transport.position = Double(engine.manualRenderingSampleTime) / rate
        try audio.update(state, revision: revision)
        referenceState.transport.position = state.transport.position
        try referenceAudio.update(referenceState, revision: 1)
    }
    for _ in 0..<16 {
        let status = try engine.renderOffline(512, to: output)
        let referenceStatus = try referenceEngine.renderOffline(512, to: expectedOutput)
        precondition(status == .success && referenceStatus == .success)
        heardReference = heardReference || abs(output.floatChannelData![0][511]) > 0.00001
        try update()
    }
    precondition(heardReference)
    func check(_ label: String, edit: () -> Void) throws {
        edit(); revision += 1
        try update()
        precondition(engine.isRunning, "\(label) stopped the engine")
        for block in 0..<4 {
            let status = try engine.renderOffline(512, to: output)
            let referenceStatus = try referenceEngine.renderOffline(512, to: expectedOutput)
            precondition(status == .success && referenceStatus == .success)
            for frame in 0..<512 {
                let expected = expectedOutput.floatChannelData![0][frame]
                precondition(abs(output.floatChannelData![0][frame] - expected) < 0.00001,
                    "\(label): interrupted reference PCM at block \(block), sample \(frame)")
            }
            try update()
        }
        print("PLAYBACK_EDIT_PCM_CONTINUITY_OK rate=\(rate) action=\(label)")
    }
    func targetIndex() -> Int { state.project.songs[0].tracks.firstIndex { $0.id == edited.id }! }
    for iteration in 0..<3 {
        try check("track mute \(iteration)") {
            audio.previewMute(edited.id, muted: true)
            state.project.songs[0].tracks[targetIndex()].mute = true
        }
        try check("track unmute \(iteration)") {
            audio.previewMute(edited.id, muted: false)
            state.project.songs[0].tracks[targetIndex()].mute = false
        }
        try check("item mute \(iteration)") {
            audio.previewClipMute(originalItem.id, muted: true)
            state.project.songs[0].tracks[targetIndex()].clips[0].muted = true
        }
        try check("item unmute \(iteration)") {
            audio.previewClipMute(originalItem.id, muted: false)
            state.project.songs[0].tracks[targetIndex()].clips[0].muted = false
        }
        try check("delete item \(iteration)") { state.project.songs[0].tracks[targetIndex()].clips = [] }
        try check("restore deleted item \(iteration)") { state.project.songs[0].tracks[targetIndex()].clips = [originalItem] }
        var inserted = originalItem; inserted.id = UUID()
        try check("insert item \(iteration)") { state.project.songs[0].tracks[targetIndex()].clips.append(inserted) }
        try check("undo inserted item \(iteration)") { state.project.songs[0].tracks[targetIndex()].clips.removeLast() }
        try check("reorder tracks \(iteration)") { state.project.songs[0].tracks.reverse() }
        var settings = NativeFXSettings(); settings.inserted = ["Delay"]; settings.delayEnabled = true; settings.delayMix = 0
        let effect = NativeFXInstance(kind: "Delay", settings: settings)
        settings.instances = [effect]; settings.inserted = [effect.effectKey]
        try settings.validateForClip()
        try check("insert track FX \(iteration)") {
            audio.previewFX(edited.id, settings: settings)
            state.project.songs[0].tracks[targetIndex()].fx = settings
        }
        try check("remove track FX \(iteration)") {
            audio.previewFX(edited.id, settings: NativeFXSettings())
            state.project.songs[0].tracks[targetIndex()].fx = nil
        }
        try check("insert reference track FX \(iteration)") {
            audio.previewFX(reference.id, settings: settings)
            let index = state.project.songs[0].tracks.firstIndex { $0.id == reference.id }!
            state.project.songs[0].tracks[index].fx = settings
        }
        try check("remove reference track FX \(iteration)") {
            audio.previewFX(reference.id, settings: NativeFXSettings())
            let index = state.project.songs[0].tracks.firstIndex { $0.id == reference.id }!
            state.project.songs[0].tracks[index].fx = nil
        }
        try check("insert Master FX \(iteration)") {
            audio.previewFX(nil, settings: settings)
            state.project.masterFX = settings
        }
        try check("remove Master FX \(iteration)") {
            audio.previewFX(nil, settings: NativeFXSettings())
            state.project.masterFX = nil
        }
        try check("insert reference item FX \(iteration)") {
            audio.previewClipFX(reference.clips[0].id, settings: settings)
            let index = state.project.songs[0].tracks.firstIndex { $0.id == reference.id }!
            state.project.songs[0].tracks[index].clips[0].fx = settings
        }
        try check("remove reference item FX \(iteration)") {
            audio.previewClipFX(reference.clips[0].id, settings: NativeFXSettings())
            let index = state.project.songs[0].tracks.firstIndex { $0.id == reference.id }!
            state.project.songs[0].tracks[index].clips[0].fx = nil
        }
    }
    precondition(errors.isEmpty, "Unexpected playback errors: \(errors)")
}

try MainActor.assumeIsolated { try runPlaybackEditingContinuityTests() }
