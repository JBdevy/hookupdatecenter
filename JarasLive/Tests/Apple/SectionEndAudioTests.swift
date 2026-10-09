import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

@MainActor private func field(_ name: String, of value: Any) -> Any? {
    Mirror(reflecting: value).children.first { $0.label == name }?.value
}
@MainActor private func preparedBoundary(_ audio: StemAudioPlayback) -> Double? {
    guard let optional = field("preparedJump", of: audio), let jump = Mirror(reflecting: optional).children.first?.value else { return nil }
    return field("boundary", of: jump) as? Double
}
@MainActor private func players(_ head: Int, audio: StemAudioPlayback) -> Set<ObjectIdentifier> {
    guard let voices = field("voices", of: audio) else { return [] }
    return Set(Mirror(reflecting: voices).children.compactMap { entry in
        let pair = Array(Mirror(reflecting: entry.value).children)
        guard pair.count == 2, field("head", of: pair[0].value) as? Int == head,
              let player = field("player", of: pair[1].value) as? AVAudioPlayerNode else { return nil }
        return ObjectIdentifier(player)
    })
}

@MainActor private func run() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 4))!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0.01 } }
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings)
        try file.write(from: buffer)
    }
    let writtenFrames = try AVAudioFile(forReading: directory.appendingPathComponent("tone.wav")).length
    precondition(writtenFrames == Int64(buffer.frameLength))
    for queueSong in [false, true] {
    for ignoreNext in [false, true] {
        let audio = StemAudioPlayback(engine: AVAudioEngine(), realtime: true)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "End trigger")
        project.masterMute = true // Exercise the live graph without audible output.
        project.songs[0].duration = 4
        let root = Part(id: UUID(), name: "Special", startTime: 0, endTime: 4)
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 1, parentRegionID: ignoreNext ? root.id : nil)
        let second = Part(id: UUID(), name: "Second", startTime: 1, endTime: 4, parentRegionID: ignoreNext ? root.id : nil)
        project.songs[0].parts = ignoreNext ? [root, first, second] : [first, second]
        let incoming = Part(id: UUID(), name: "Queued", startTime: 2, endTime: 4)
        if queueSong {
            project.songs[0].parts.append(incoming)
            var list = RegionSetlist(); list.stopAtRegionEnd = true
            project.regionSetlist = list
        }
        let firstDuration = ignoreNext ? 1.4 : 1
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "First", startTime: 0, duration: firstDuration, audioFile: AudioFile(path: "tone.wav")),
                       AudioClip(id: UUID(), name: "Second", startTime: 1, duration: 3, audioFile: AudioFile(path: "tone.wav"))]
        project.songs[0].tracks = [track]
        let core = JarasCoreBridge()
        try core.load(projectData: JSONEncoder().encode(project))
        func snapshot() throws -> ShowSnapshot { try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot()) }
        try audio.update(snapshot(), revision: 1)
        try core.execute(command: "seek", target: nil, value: 0.5)
        try core.execute(command: "play", target: nil, value: 0)
        if ignoreNext { try core.execute(command: "ignoreNext", target: nil, value: 0) }
        try core.execute(command: queueSong ? "queueRegion" : "queueSection", target: (queueSong ? incoming.id : first.id).uuidString, value: 0)
        try audio.update(snapshot(), revision: 1)
        var last = ProcessInfo.processInfo.systemUptime
        var prepared: Set<ObjectIdentifier> = []
        let timeout = last + 3
        var jumped = false
        var checkedCancellation = false
        while ProcessInfo.processInfo.systemUptime < timeout {
            try await Task.sleep(nanoseconds: 10_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            core.advance(now - last); last = now
            let state = try snapshot()
            try audio.update(state, revision: 1)
            if let boundary = preparedBoundary(audio) {
                if queueSong && !checkedCancellation {
                    var preparedOnly = state
                    preparedOnly.project.regionSetlist?.prepareWithoutPlayback = true
                    try audio.update(preparedOnly, revision: 1)
                    precondition(preparedBoundary(audio) == nil && players(2, audio: audio).isEmpty,
                                 "prepare-only cancels pre-scheduled incoming audio")
                    try audio.update(state, revision: 1)
                    var cancelled = state; cancelled.transport.queuedRegionId = nil
                    try audio.update(cancelled, revision: 1)
                    precondition(preparedBoundary(audio) == nil && players(2, audio: audio).isEmpty,
                                 "clearing the queue removes its future players and boundary")
                    try audio.update(state, revision: 1)
                    checkedCancellation = true
                }
                precondition(abs(boundary - firstDuration) < 0.00001,
                             "the scheduled audio boundary follows region end or the actual Ignore Next tail")
                prepared.formUnion(players(2, audio: audio))
            }
            if (state.transport.sectionJumpSerial ?? 0) > 0 {
                precondition(state.transport.playing && state.transport.queuedSectionMarkerId == nil)
                if prepared.isEmpty || players(0, audio: audio).isDisjoint(with: prepared) {
                    let clocks = field("headAudioClock", of: audio)
                    FileHandle.standardError.write(Data("Promotion diagnostic: ignoreNext=\(ignoreNext) prepared=\(prepared) main=\(players(0, audio: audio)) future=\(players(2, audio: audio)) boundary=\(String(describing: preparedBoundary(audio))) position=\(state.transport.position) clocks=\(String(describing: clocks))\n".utf8))
                }
                precondition(!prepared.isEmpty && !players(0, audio: audio).isDisjoint(with: prepared),
                             "the pre-scheduled destination player must be promoted without stopping or rescheduling it")
                jumped = true; break
            }
        }
        precondition(jumped, "the end boundary must execute its armed jump")
        print("REALTIME_END_PRESCHEDULED_PLAYER_PROMOTION_OK queueSong=\(queueSong) ignoreNext=\(ignoreNext) sampleRate=\(rate)")
    }
    }
}

Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("REALTIME_SECTION_END_FAILED \(error)"); exit(1) }
}
dispatchMain()
