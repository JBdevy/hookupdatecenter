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
    precondition(imported.tracks.count == 1 && imported.tracks[0].kind == .standard)
    precondition(imported.tracks[0].id == videoTrackID, "video attaches to an explicitly chosen standard track")
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
    for window in NSApp.windows where window.title == "CatLive Video" { window.orderOut(nil) }
    var snapshot = ShowSnapshot(project: restored,transport: TransportState(playing: false,songId: restored.songs[0].id,position: 30,queue: QueueState(),loop: LoopState(enabled: false),subPlay: SubPlayState(playing: false,position: 0)))
    controller.update(snapshot)
    for _ in 0..<100 {
        if controller.player.currentItem?.status == .readyToPlay { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(controller.player.currentItem?.status == .readyToPlay, "imported video must decode")
    precondition(controller.player.isMuted && controller.player.volume == 0, "video must never output soundtrack audio")
    let videoSettings = VideoMediaSettings.shared
    let savedResolution = videoSettings.resolution, savedGray = videoSettings.blackAndWhite
    defer { videoSettings.resolution = savedResolution; videoSettings.blackAndWhite = savedGray }
    videoSettings.resolution = 360; videoSettings.blackAndWhite = true
    let capped = VideoPlayback(preferences: .standard)
    capped.open(directory: directory); capped.setProjectionEnabled(true); capped.update(snapshot)
    for _ in 0..<100 {
        if capped.player.currentItem?.status == .readyToPlay { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    guard let composition = capped.player.currentItem?.videoComposition else { preconditionFailure("resolution and grayscale use a real video composition") }
    precondition(composition.renderSize.width * CGFloat(composition.renderScale) <= 640.1 &&
                 composition.renderSize.height * CGFloat(composition.renderScale) <= 360.1,
                 "1080p media must be rendered within the selected 360p output")
    capped.setProjectionEnabled(false)
    videoSettings.resolution = savedResolution; videoSettings.blackAndWhite = savedGray
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
    let originalVideoClips = snapshot.project.songs[0].tracks[0].clips
    snapshot.project.songs[0].tracks[0].clips = slide.tracks[0].clips
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
    snapshot.project.songs[0].tracks[0].clips = originalVideoClips
    let teleprompterID = UUID()
    let tpImport = try StemProjectImporter.prepareDroppedAudio([source], start: 30, destinationTracks: [teleprompterID], destination: directory.appendingPathComponent("test.jl"), destinationKind: .teleprompt)
    precondition(tpImport.tracks[0].kind == .teleprompt)
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
    // Exercise the real AVPlayer transport for all three projection surfaces.
    var tp2Track = tpTrack
    tp2Track.id = UUID(); tp2Track.role = TrackRole(rawValue: TrackKind.teleprompt2.rawValue)
    tp2Track.clips = tp2Track.clips.map { value in var copy = value; copy.id = UUID(); return copy }
    snapshot.project.songs[0].tracks.append(tp2Track)
    let tp2Controller = VideoPlayback(preferences: preferences, trackKind: .teleprompt2)
    tp2Controller.open(directory: directory); tp2Controller.setProjectionEnabled(true)
    let projections = [controller, tpController, tp2Controller]
    func publish() { for projection in projections { projection.update(snapshot) } }
    func advance(from start: Double, duration: Double) async throws {
        let begin = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - begin < duration {
            snapshot.transport.position = start + ProcessInfo.processInfo.systemUptime - begin
            publish()
            try await Task.sleep(nanoseconds: 16_666_667)
        }
    }
    snapshot.transport.playing = true; snapshot.transport.position = 30
    publish()
    try await advance(from: 30, duration: 0.6)
    func checkFrames(_ target: Double, tolerance: Double = 0.15, _ reason: String) {
        for (index, projection) in projections.enumerated() {
            let actual = projection.player.currentTime().seconds
            precondition(actual.isFinite && abs(actual - target) < tolerance,
                         "Surface \(index): \(reason); expected \(target), actual \(actual)")
        }
    }
    checkFrames(snapshot.transport.position - 30, "normal playback")
    let identities = projections.map { $0.player.currentItem }
    // Moving the edit cursor while playing must not seek any decoder.
    snapshot.transport.editPosition = 35; publish()
    try await advance(from: snapshot.transport.position, duration: 0.2)
    checkFrames(snapshot.transport.position - 30, "edit cursor must not restart playback")
    // Forward and backward jumps on the same video, including repeated loop turns.
    for destination in [31.0, 30.15, 31.25, 30.2, 30.7, 30.2] {
        snapshot.transport.position = destination
        snapshot.transport.sectionJumpSerial = (snapshot.transport.sectionJumpSerial ?? 0) + 1
        publish()
        try await advance(from: destination, duration: 0.3)
        checkFrames(snapshot.transport.position - 30, "section jump or loop")
    }
    precondition(zip(projections, identities).allSatisfy { $0.player.currentItem === $1 },
                 "jumps within a clip reuse all three decoders")
    let shortJump = snapshot.transport.position - 0.1
    snapshot.transport.position = shortJump
    snapshot.transport.sectionJumpSerial = (snapshot.transport.sectionJumpSerial ?? 0) + 1
    publish()
    try await advance(from: shortJump, duration: 0.3)
    checkFrames(snapshot.transport.position - 30, tolerance: 0.07, "short explicit section jump")
    snapshot.transport.playing = false; snapshot.transport.paused = true
    snapshot.transport.position = 30.8; snapshot.transport.editPosition = 35
    publish(); try await Task.sleep(nanoseconds: 250_000_000)
    checkFrames(0.8, tolerance: 0.05, "pause follows playback, not the edit cursor")
    precondition(projections.allSatisfy { $0.player.rate == 0 }, "all projections pause")
    // A source repetition wraps independently of a continuously advancing grid.
    for trackIndex in snapshot.project.songs[0].tracks.indices {
        for clipIndex in snapshot.project.songs[0].tracks[trackIndex].clips.indices
            where snapshot.project.songs[0].tracks[trackIndex].clips[clipIndex].isProjectionMedia {
            snapshot.project.songs[0].tracks[trackIndex].clips[clipIndex].loopLength = 0.8
            snapshot.project.songs[0].tracks[trackIndex].clips[clipIndex].playbackRate = 1.5
        }
    }
    snapshot.transport.playing = true; snapshot.transport.paused = false
    snapshot.transport.position = 30; publish()
    try await advance(from: 30, duration: 1.35)
    checkFrames(((snapshot.transport.position - 30) * 1.5).truncatingRemainder(dividingBy: 0.8),
                "source loop and playback rate")
    snapshot.transport.playing = false; snapshot.transport.editPosition = snapshot.project.songs[0].duration + 1
    publish(); try await Task.sleep(nanoseconds: 100_000_000)
    precondition(projections.allSatisfy { $0.player.currentItem == nil }, "no stale video outside items")
    snapshot.transport.editPosition = 30; publish()
    snapshot.transport.editPosition = snapshot.project.songs[0].duration + 1; publish()
    try await Task.sleep(nanoseconds: 250_000_000)
    precondition(projections.allSatisfy { $0.player.currentItem == nil }, "late seeks cannot revive stopped media")
    snapshot.transport.editPosition = 30; publish()
    tp2Controller.setProjectionEnabled(false)
    print("VIDEO_TP1_TP2_REAL_PLAYER_JUMPS_LOOPS_RATE_PAUSE_EDIT_CURSOR_AND_STALE_SEEKS_OK")
    snapshot.project.songs[0].tracks.removeAll { $0.id == teleprompterID }
    tpController.update(snapshot)
    precondition(tpController.player.currentItem == nil, "a video on the Video track never appears in the teleprompter")
    precondition(controller.player.currentItem != nil, "TP changes never stop the separate video decoder")
    // The next video lives on another track and is ready at the exact boundary.
    let transition = VideoPlayback(preferences: preferences)
    transition.open(directory: directory); transition.setProjectionEnabled(true)
    var transitionSnapshot = snapshot
    var first = clip; first.startTime = 0; first.duration = 1
    var second = clip; second.id = UUID(); second.startTime = 1; second.duration = 1
    var upper = imported.tracks[0]; upper.clips = [first]
    var lower = upper; lower.id = UUID(); lower.clips = [second]
    transitionSnapshot.project.songs[0].tracks = [upper, lower]
    transitionSnapshot.transport.playing = true; transitionSnapshot.transport.paused = false
    transitionSnapshot.transport.position = 0
    transition.update(transitionSnapshot)
    let outgoingPlayer = transition.player
    // Give the preloader time while leaving transport before the boundary.
    try await Task.sleep(nanoseconds: 2_000_000_000)
    transitionSnapshot.transport.position = 1
    transition.update(transitionSnapshot)
    precondition(transition.player !== outgoingPlayer, "Cross-track boundary reuses the prepared player")
    precondition(transition.player.currentItem?.status == .readyToPlay, "Next video is already ready at transition")
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(transition.player.currentTime().seconds < 0.4, "Incoming source starts at its own offset")
    transition.setProjectionEnabled(false)
    precondition(transition.player.currentItem == nil, "Closing clears the prepared playback too")
    print("VIDEO_CROSS_TRACK_PREPARED_TRANSITION_OK")
    // A split of the same source must keep both player and item alive.
    transitionSnapshot.project.songs[0].tracks[1].clips[0].sourceOffset = first.sourceOffset + first.duration * first.audioRate
    transitionSnapshot.transport.position = 0.95
    transition.setProjectionEnabled(true); transition.update(transitionSnapshot)
    try await Task.sleep(nanoseconds: 250_000_000)
    let continuousPlayer = transition.player, continuousItem = transition.player.currentItem
    transitionSnapshot.transport.position = 1
    transition.update(transitionSnapshot)
    precondition(transition.player === continuousPlayer && transition.player.currentItem === continuousItem,
                 "A continuous cut must not replace or reopen the decoder")
    transition.setProjectionEnabled(false)
    print("VIDEO_CONTIGUOUS_CUT_REUSES_PLAYER_AND_ITEM_OK")
    let firstPlayer = AVPlayer(url: source), secondPlayer = AVPlayer(url: source)
    firstPlayer.isMuted = true; secondPlayer.isMuted = true
    let surface = VideoLayerView(player: firstPlayer, stretch: false)
    let surfaceWindow = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 160, height: 90),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
    surfaceWindow.isReleasedWhenClosed = false
    surfaceWindow.contentView = surface; surfaceWindow.orderBack(nil)
    firstPlayer.play()
    for _ in 0..<200 {
        if surface.video.player === firstPlayer && surface.video.isReadyForDisplay { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(surface.video.player === firstPlayer && surface.video.isReadyForDisplay, "First layer has a drawable frame")
    firstPlayer.pause()
    surface.setPlayer(secondPlayer)
    precondition(surface.video.player === firstPlayer && surface.video.isReadyForDisplay, "Outgoing frame stays visible while the next layer loads")
    secondPlayer.play()
    for _ in 0..<200 {
        if surface.video.player === secondPlayer { break }
        precondition(surface.video.player === firstPlayer && surface.video.isReadyForDisplay, "No empty active layer during the handoff")
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(surface.video.player === secondPlayer && surface.video.isReadyForDisplay, "Switch only to a drawable layer")
    secondPlayer.replaceCurrentItem(with: nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(surface.video.player == nil, "End of media must clear the retained frame")
    surface.clear(); surfaceWindow.close()
    print("VIDEO_LAYER_HANDOFF_PRESERVES_FRAME_UNTIL_READY_AND_CLEARS_AT_END_OK")
    controller.setProjectionEnabled(false); tpController.setProjectionEnabled(false)
    print("VIDEO_IMPORT_PERSISTENCE_SILENT_PLAYBACK_CURSOR_AND_CLOSE_OK")
    print("TELEPROMPTER_MEDIA_SOURCE_TEXT_OVERLAY_INDEPENDENT_STRETCH_AND_PREVIEW_OK")
}
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
}
RunLoop.main.run()
