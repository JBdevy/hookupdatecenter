import AppKit
import AVFoundation

@MainActor func run() async throws {
    _ = NSApplication.shared
    let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JARAS_TEST_VIDEO"]!)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let videoTrackID = UUID()
    let imported = try await Task.detached {
        try StemProjectImporter.prepareDroppedAudio([source],start: 30,destinationTracks: [videoTrackID],destination: directory.appendingPathComponent("test.jl"),destinationKind: .video)
    }.value
    precondition(imported.tracks.count == 1 && imported.tracks[0].kind == .video && imported.tracks[0].name == "Video")
    precondition(imported.tracks[0].id == videoTrackID, "video attaches to an explicitly chosen existing Video track")
    let clip = imported.tracks[0].clips[0]
    precondition(clip.audioFile!.path.hasPrefix("Videos/"), "videos use their own media folder")
    precondition(clip.startTime == 30 && clip.duration > 1 && clip.waveform.isEmpty)
    precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent(clip.audioFile!.path).path), "media is copied into the project")
    var project = Project.empty(name: "Video")
    project.songs[0].tracks = imported.tracks
    project.songs[0].duration = 30 + clip.duration
    let restored = try JSONDecoder().decode(Project.self,from: JSONEncoder().encode(project))
    try restored.validate()
    let suite = "jaras.video.tests." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let controller = VideoPlayback(preferences: preferences)
    precondition(!controller.stretch)
    controller.setStretch(true)
    precondition(VideoPlayback(preferences: preferences).stretch, "Stretch persists without changing the transport or decoder")
    controller.open(directory: directory)
    controller.toggle()
    for window in NSApp.windows where window.title == "Jaras Video" { window.orderOut(nil) }
    var snapshot = ShowSnapshot(project: restored,transport: TransportState(playing: false,songId: restored.songs[0].id,position: 30,queue: QueueState(),loop: LoopState(enabled: false),subPlay: SubPlayState(playing: false,position: 0)))
    controller.update(snapshot)
    for _ in 0..<100 {
        if controller.player.currentItem?.status == .readyToPlay { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(controller.player.currentItem?.status == .readyToPlay, "imported video must decode")
    precondition(controller.player.isMuted && controller.player.volume == 0, "video must never output soundtrack audio")
    let item = controller.player.currentItem
    controller.setStretch(false)
    precondition(controller.player.currentItem === item && !controller.stretch, "Stretch changes the presentation without reopening media")
    snapshot.transport.playing = true
    controller.update(snapshot)
    for _ in 0..<15 {
        try await Task.sleep(nanoseconds: 33_333_333)
        snapshot.transport.position += 1.0/30
        controller.update(snapshot)
    }
    precondition(controller.player.currentItem === item, "continuous playback keeps the same decoder")
    precondition(controller.player.currentTime().seconds > 0.2, "video advances with transport")
    snapshot.transport.playing = false; snapshot.transport.editPosition = 31
    controller.update(snapshot)
    try await Task.sleep(nanoseconds: 250_000_000)
    precondition(abs(controller.player.currentTime().seconds-1) < 0.1, "stopped cursor seeks the corresponding video frame")
    controller.setProjectionEnabled(true)
    let sharedItem = controller.player.currentItem
    controller.toggle()
    precondition(!controller.visible && controller.player.currentItem === sharedItem, "an additional active surface keeps its decoder")
    controller.setProjectionEnabled(false)
    precondition(!controller.visible && controller.player.currentItem == nil, "closed video window releases decoding resources")
    controller.setProjectionEnabled(true)
    for _ in 0..<100 {
        if controller.player.currentItem?.status == .readyToPlay { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(controller.player.currentItem?.status == .readyToPlay && !controller.visible, "teleprompter playback works without a video window")
    let png = directory.appendingPathComponent("Slide.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<32 { for x in 0..<64 { bitmap.setColor(.red, atX: x, y: y) } }
    try bitmap.representation(using: .png, properties: [:])!.write(to: png)
    let slide = try StemProjectImporter.prepareDroppedAudio([png], start: 40, destinationTracks: [videoTrackID], destination: directory.appendingPathComponent("test.jl"), destinationKind: .video)
    precondition(slide.tracks[0].clips[0].duration == 10 && slide.tracks[0].clips[0].audioFile!.path.hasPrefix("Videos/"), "images are copied to Videos with an initial ten-second duration")
    snapshot.project.songs[0].tracks[0].clips += slide.tracks[0].clips
    snapshot.transport.editPosition = 40
    controller.update(snapshot)
    for _ in 0..<100 {
        if controller.image != nil { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(controller.image != nil && controller.player.currentItem == nil, "images render without a video decoder")
    let unchangedImage = controller.image
    controller.update(snapshot)
    precondition(controller.image === unchangedImage, "transport ticks do not reload the same image")
    controller.setProjectionEnabled(false)
    precondition(controller.image == nil && controller.player.currentItem == nil, "Preview releases media when the video window is closed")
    controller.setProjectionEnabled(true)
    snapshot.transport.editPosition = 70
    controller.update(snapshot)
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(controller.image == nil && controller.player.currentItem == nil, "a stale image decode cannot appear outside its item")
    controller.setProjectionEnabled(false)
    let teleprompterID = UUID()
    let tpImport = try StemProjectImporter.prepareDroppedAudio([source], start: 30, destinationTracks: [teleprompterID], destination: directory.appendingPathComponent("test.jl"), destinationKind: .teleprompt)
    precondition(tpImport.tracks[0].kind == .teleprompt && tpImport.tracks[0].name == "Teleprompter")
    var tpTrack = tpImport.tracks[0]
    tpTrack.clips.append(AudioClip(id: UUID(), name: "Lyrics", startTime: 30, duration: 10, text: "Text over video"))
    snapshot.project.songs[0].tracks.append(tpTrack)
    snapshot.project.songs[0].duration = max(snapshot.project.songs[0].duration, snapshot.project.songs[0].tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 40)
    try snapshot.project.validate()
    snapshot.transport.editPosition = 30
    let tpController = VideoPlayback(preferences: preferences, trackKind: .teleprompt)
    precondition(!tpController.stretch, "teleprompter Stretch does not inherit the video setting")
    tpController.open(directory: directory); tpController.setProjectionEnabled(true); tpController.update(snapshot)
    controller.setProjectionEnabled(true); controller.update(snapshot)
    for _ in 0..<100 {
        if tpController.player.currentItem?.status == .readyToPlay && controller.player.currentItem?.status == .readyToPlay { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(tpController.player.currentItem?.status == .readyToPlay, "teleprompter media imports and decodes over its text layer")
    precondition(tpController.player.currentItem !== controller.player.currentItem, "both windows use independent media sources and decoders")
    let tpItem = tpController.player.currentItem
    tpController.setStretch(true)
    precondition(tpController.player.currentItem === tpItem && !controller.stretch, "TP Stretch never changes the video window or reopens the media")
    precondition(VideoPlayback(preferences: preferences, trackKind: .teleprompt).stretch)
    snapshot.project.songs[0].tracks.removeAll { $0.id == teleprompterID }
    tpController.update(snapshot)
    precondition(tpController.player.currentItem == nil, "a video on the Video track never appears in the teleprompter")
    precondition(controller.player.currentItem != nil, "TP changes never stop the separate video decoder")
    controller.setProjectionEnabled(false); tpController.setProjectionEnabled(false)
    print("VIDEO_IMPORT_PERSISTENCE_SILENT_PLAYBACK_CURSOR_AND_CLOSE_OK")
    print("TELEPROMPTER_MEDIA_SOURCE_TEXT_OVERLAY_INDEPENDENT_STRETCH_AND_PREVIEW_OK")
}
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
}
RunLoop.main.run()
