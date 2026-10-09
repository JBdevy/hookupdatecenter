@MainActor private func testNativeTimelineBody() throws {
    func awaitValue(_ condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        precondition(condition(), message)
    }
    awaitValue({ MetalWaveformRenderer.isSupported }, "Metal must become available for native body test")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-native-body-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
    pcm.frameLength = 96_000
    for sample in 0..<Int(pcm.frameLength) {
        let value = Float(sin(Double(sample) * 0.031) * 0.5)
        pcm.floatChannelData![0][sample] = value
        pcm.floatChannelData![1][sample] = -value
    }
    let url = directory.appendingPathComponent("audio.wav")
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
    let first = AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 2, audioFile: AudioFile(path: "audio.wav"))
    var loop = AudioClip(id: UUID(), name: "Loop", startTime: 2.5, duration: 2, audioFile: AudioFile(path: "audio.wav"))
    loop.loopLength = 0.5
    var midi = AudioClip(id: UUID(), name: "MIDI", startTime: 6, duration: 1)
    midi.midi = MIDIItem()
    let missing = AudioClip(id: UUID(), name: "Missing", startTime: 9, duration: 1, audioFile: AudioFile(path: "missing.wav"))
    let embedded = AudioClip(id: UUID(), name: "Embedded", startTime: 11, duration: 1)
    var audioTrack = Track(id: UUID(), name: "Audio", role: TrackRole(rawValue: "standard"))
    audioTrack.clips = [first, loop, midi, missing, embedded]
    var clickTrack = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
    clickTrack.clips = [AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 12)]
    var textTrack = Track(id: UUID(), name: "Text", role: TrackRole(rawValue: "teleprompt"))
    textTrack.clips = [AudioClip(id: UUID(), name: "Text", startTime: 0, duration: 12, text: "Verso 1\nC Am F G")]
    var song = Song(id: UUID(), name: "Mixed", duration: 12, bpm: 120, tracks: [audioTrack, clickTrack, textTrack], parts: [])
    func configuration(_ source: Song, selected: Set<UUID> = [], height: CGFloat = 64) -> NativeTimelineAudioBodyConfiguration? {
        NativeTimelineAudioBodyConfiguration.make(song: source, rows: TrackRowLayout(tracks: source.tracks, baseHeight: height),
            metadata: TimelineRenderMetadata(song: source), rulerHeight: 55, selectedClips: selected,
            mediaDirectory: directory, missingAudioPaths: ["missing.wav"])
    }
    let mixed = configuration(song)!
    precondition(mixed.itemIDs == Set([first.id, loop.id, missing.id, textTrack.clips[0].id]))
    precondition(mixed.hasFallbackItems && !mixed.hasFallbackWaveforms,
        "audio, missing media and text use native bodies while MIDI/click/embedded waveforms retain Canvas")
    precondition(mixed.fallbackItems.count == 3 && mixed.decorations.count == 2,
        "only MIDI, click and the embedded waveform belong to hosted coverage")
    print("NATIVE_BODY_MIXED_SUBSET_ELIGIBILITY_OK")

    let cache = TimelineAudioWaveform.shared
    cache.pauseNativeBodyTestDecoding()
    var paused = true
    defer { if paused { cache.resumeNativeBodyTestDecoding() } }
    let body = NativeTimelineAudioBodyView()
    body.configure(mixed)
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 260)
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 300)
    let cold = body.fillsForTest!
    precondition(cold.items.count == 3 && !cold.isEmpty && cold.strokes.isEmpty)
    precondition(body.waveformsForTest?.isEmpty == true && body.observesReadinessForTest,
        "cold PCM must leave its item visible while the decoder is blocked")
    precondition(body.inkValuesForTest == ["Verso 1\nC Am F G"],
        "visible text must be ready while PCM decoding is blocked")
    let fillCount = body.fillSubmissionsForTest
    let inkUpdates = body.inkUpdatesForTest
    cache.resumeNativeBodyTestDecoding(); paused = false
    awaitValue({ body.waveformsForTest?.strokes.contains { $0.block.key != "timeline-centerline-unit" } == true },
        "cold source must appear from native readiness without a SwiftUI update or another project() call")
    precondition(body.fillSubmissionsForTest == fillCount && body.fillsForTest!.hasSameContent(as: cold),
        "waveform readiness must not redraw item fills")
    precondition(body.inkUpdatesForTest == inkUpdates,
        "PCM readiness must leave retained text/media ink untouched")
    print("NATIVE_BODY_FILL_AND_TEXT_BEFORE_PCM_READINESS_WITHOUT_FILL_OR_INK_REDRAW_OK")

    body.project(viewport: CGRect(x: 700, y: 0, width: 600, height: 260), documentSize: CGSize(width: 8000, height: 400), scale: 600)
    let zoomed = body.fillsForTest!
    precondition(zoomed.coordinateSpace?.pixelsPerSecond == 600)
    precondition(zoomed.coordinateSpace == body.waveformsForTest?.coordinateSpace)
    let origin = zoomed.coordinateSpace!.documentOrigin
    precondition(abs(zoomed.items[0].rect.minX + origin.x - 1) < 0.001)
    precondition(abs(zoomed.items[0].rect.width - 1198) < 0.001)
    let projectedSubmissions = body.fillSubmissionsForTest
    body.project(viewport: CGRect(x: 700, y: 0, width: 600, height: 260), documentSize: CGSize(width: 8000, height: 400), scale: 600)
    precondition(body.fillSubmissionsForTest == projectedSubmissions, "identical native projection must be retained")
    let waveformSubmissions = body.waveformSubmissionsForTest
    for _ in 0..<8 { body.submitDeferredReadinessForTest() }
    precondition(body.waveformSubmissionsForTest == waveformSubmissions,
        "readiness already consumed by this projection must not submit the same GPU scene again")
    print("NATIVE_BODY_ZOOM_PAN_COHERENT_AND_UNCHANGED_PROJECTION_RETAINED_OK")

    // Native scrolling supplies continuous origins, while the former hosted
    // path publishes 512-point horizontal buckets. Keep horizontal geometry
    // through the bucket; native vertical hysteresis is tested separately.
    let largeDocument = CGSize(width: 8000, height: 4000)
    let bucketStart = CGRect(x: 512, y: 0, width: 600, height: 260)
    body.project(viewport: bucketStart, documentSize: largeDocument, scale: 400)
    let retainedSurfaceGeometry = body.surfaceGeometryForTest
    for (index, offset) in [CGFloat(0), 0.25, 63.75, 128, 255.5, 384, 511.999].enumerated() {
        let movingViewport = bucketStart.offsetBy(dx: offset, dy: 0)
        let exactScale = Double(400 + index)
        body.project(viewport: movingViewport, documentSize: largeDocument, scale: exactScale)
        precondition(body.surfaceGeometryForTest == retainedSurfaceGeometry,
                     "subbucket zoom origins must not mutate body, surface, or MTKView frames/bounds")
        precondition(body.frame.contains(movingViewport),
                     "both the true right and bottom edges remain covered through the whole unpublished bucket")
        let exact = body.fillsForTest!
        precondition(exact.coordinateSpace?.pixelsPerSecond == exactScale &&
                     abs(exact.items[0].rect.width - (2 * exactScale - 2)) < 0.001,
                     "retained surface geometry still redraws item coordinates at the exact live scale")
    }
    for movingViewport in [CGRect(x: 1024, y: 512, width: 600, height: 260),
                           CGRect(x: 1535.999, y: 1023.999, width: 600, height: 260),
                           CGRect(x: 7400, y: 3740, width: 600, height: 260)] {
        body.project(viewport: movingViewport, documentSize: largeDocument, scale: 400)
        precondition(body.frame.contains(movingViewport), "bucket transitions and document end preserve complete true viewport coverage")
        precondition(body.frame.maxX <= largeDocument.width && body.frame.maxY <= largeDocument.height,
                     "retained coverage never expands beyond logical document extent")
    }
    print("NATIVE_BODY_SUBBUCKET_FRAMES_BOUNDS_STABLE_REAL_RIGHT_BOTTOM_AND_END_COVERED_OK")

    song.tracks[0].clips[0].startTime = 1
    song.tracks[0].clips[0].duration = 1
    body.configure(configuration(song, selected: [first.id]))
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 300)
    let edited = body.fillsForTest!
    precondition(abs(edited.items[0].rect.minX - 301) < 0.001 && edited.items[0].borderWidth == 1.5)
    precondition(edited.coordinateSpace?.contentRevision != cold.coordinateSpace?.contentRevision)
    body.configure(configuration(song, selected: [first.id], height: 24))
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 300)
    precondition(body.fillsForTest!.items[0].rect.height == 18 && body.waveformsForTest!.isEmpty && body.inkForTest.isEmpty,
        "collapsed native clips keep their bar without waveform work")
    print("NATIVE_BODY_EDIT_SELECTION_AND_COLLAPSED_ROW_OK")

    var shortLoop = first
    shortLoop.loopLength = 20
    song.tracks = [audioTrack]
    song.tracks[0].clips = [shortLoop]
    body.configure(configuration(song))
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 300)
    precondition(body.fillsForTest!.items[0].firstSeamX == nil && body.fillsForTest!.items[0].repeatSpacing == nil,
        "an interval without a real repetition boundary cannot synthesize a seam at zero")
    song.tracks[0].clips = [loop]
    body.configure(configuration(song))
    body.project(viewport: CGRect(x: 750, y: 0, width: 600, height: 260), documentSize: CGSize(width: 4000, height: 400), scale: 300)
    precondition(body.fillsForTest!.items[0].firstSeamX != nil && body.fillsForTest!.items[0].repeatSpacing == 150)
    print("NATIVE_BODY_REAL_REPEAT_SEAMS_ONLY_OK")

    // Media/text use the same original-length boundary as audio, including a
    // trim into the source. Their retained ink cannot fill the triangular cut.
    var repeatedText = textTrack
    repeatedText.clips = [AudioClip(id: UUID(), name: "Repeated lyrics", startTime: 1, duration: 7, text: "Verse\nChorus")]
    var repeatedImage = textTrack
    repeatedImage.clips = [AudioClip(id: UUID(), name: "Repeated image", startTime: 1, duration: 7,
        audioFile: AudioFile(path: "Videos/image.jpg"))]
    var repeatedVideo = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
    repeatedVideo.clips = [AudioClip(id: UUID(), name: "Repeated video", startTime: 1, duration: 7,
        audioFile: AudioFile(path: "Videos/video.mp4"))]
    var repeatedTracks = [repeatedText, repeatedImage, repeatedVideo]
    for index in repeatedTracks.indices {
        repeatedTracks[index].clips[0].loopLength = 2
        repeatedTracks[index].clips[0].sourceOffset = 0.5
    }
    let repeatedSong = Song(id: UUID(), name: "Repeating media", duration: 10, bpm: 120, tracks: repeatedTracks, parts: [])
    body.configure(configuration(repeatedSong))
    body.project(viewport: CGRect(x: 0, y: 0, width: 800, height: 300),
        documentSize: CGSize(width: 1000, height: 400), scale: 80)
    precondition(body.fillsForTest!.items.count == 3 && body.inkForTest.count == 3)
    for (fill, ink) in zip(body.fillsForTest!.items, body.inkForTest) {
        precondition(fill.firstSeamX == 200 && fill.repeatSpacing == 160,
            "lyrics, image and video show repetition at the original boundary, adjusted for trim offset")
        let path = ink.clippingPath(visible: body.bounds)
        for x: CGFloat in [200, 360, 520] {
            precondition(!path.contains(CGPoint(x: x, y: ink.rect.maxY - 1), using: .evenOdd),
                "native text/media ink must preserve each bottom triangular opening")
            precondition(path.contains(CGPoint(x: x + 10, y: ink.rect.maxY - 1), using: .evenOdd))
        }
    }
    body.configure(configuration(repeatedSong, height: 24))
    body.project(viewport: viewport, documentSize: CGSize(width: 1000, height: 400), scale: 80)
    precondition(body.inkForTest.isEmpty && body.fillsForTest!.items.allSatisfy { $0.firstSeamX == 200 && $0.repeatSpacing == 160 },
        "collapsed media/text bars retain repetition cuts without preparing body ink")
    print("NATIVE_BODY_TEXT_IMAGE_VIDEO_REPEAT_SEAMS_AND_INK_CUTOUTS_OK")

    // Projects made entirely of retained text and media must release the
    // hosted scale path, while mixed MIDI/click projects retain their coverage.
    var imageClip = AudioClip(id: UUID(), name: "Image", startTime: 5, duration: 2,
        audioFile: AudioFile(path: "Videos/image.jpg"))
    imageClip.waveformChannels = [[], []]
    var specialText = textTrack
    specialText.clips[0].duration = 4
    specialText.clips.append(imageClip)
    var videoTrack = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
    videoTrack.clips = [AudioClip(id: UUID(), name: "Legacy image", startTime: 0, duration: 4,
        audioFile: AudioFile(path: "Legacy/icon.ico"))]
    var timecodeTrack = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
    timecodeTrack.clips = [AudioClip(id: UUID(), name: "Timecode", startTime: 0, duration: 4)]
    var missingTrack = audioTrack
    var missingAtStart = missing; missingAtStart.startTime = 0
    missingTrack.clips = [missingAtStart]
    var specials = Song(id: UUID(), name: "Native specials", duration: 12, bpm: 120,
        tracks: [specialText, videoTrack, timecodeTrack, missingTrack], parts: [])
    let allNative = configuration(specials)!
    precondition(allNative.itemIDs == Set(specials.tracks.flatMap { $0.clips.map(\.id) }) &&
        !allNative.hasFallbackItems && !allNative.hasFallbackWaveforms && allNative.fallbackItems.isEmpty,
        "all text/media/missing items must be retained without a hidden hosted fallback")
    let coverage = TimelineHostedItemCoverage(items: allNative.fallbackItems)
    for zoom in [0.01, 1, 80, 600, 10_000] {
        precondition(!coverage.containsItems(viewport: viewport,
            documentSize: CGSize(width: 200_000, height: 4000), scale: zoom),
            "an all-native special project must leave hosted coverage inactive at every scale")
    }
    let mixedCoverage = TimelineHostedItemCoverage(items: mixed.fallbackItems)
    precondition(mixedCoverage.containsItems(viewport: viewport,
        documentSize: CGSize(width: 4000, height: 400), scale: 300),
        "the visible click/MIDI fallback must still activate its hosted coverage")
    body.configure(allNative)
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 80)
    precondition(body.waveformsForTest!.isEmpty && body.fillsForTest!.items.count == 5)
    precondition(Set(body.inkValuesForTest) == Set(["Verso 1\nC Am F G", "channels:2", "Image", "TIMECODE", "Not found"]),
        "retained ink must preserve text, all image types, each empty channel, timecode and missing labels")
    let firstInk = body.inkForTest.map(\.rect)
    let settledInkUpdates = body.inkUpdatesForTest
    cache.publishNativeBodyTestReadiness()
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    precondition(body.inkUpdatesForTest == settledInkUpdates,
        "unrelated source readiness must not invalidate a text-only/media project")
    body.project(viewport: CGRect(x: 6000, y: 0, width: 600, height: 260),
        documentSize: CGSize(width: 8000, height: 400), scale: 80)
    precondition(body.inkForTest.isEmpty && body.fillsForTest!.isEmpty)
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 80)
    precondition(body.inkForTest.map(\.rect) == firstInk, "returning from an offscreen pan restores exact ink geometry")
    body.configure(configuration(specials, height: 24))
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 80)
    precondition(body.inkForTest.isEmpty && body.fillsForTest!.items.count == 5,
        "collapsed special items preserve bars without text or labels")
    body.configure(allNative)
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 0.01)
    for zoom in [0.015, 0.02, 0.04, 0.1] {
        body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: zoom)
    }
    // The image's empty centerlines remain visible at narrow widths, matching
    // Canvas; remove that item to isolate invisible text/label dirty behavior.
    specials.tracks[0].clips.removeLast()
    body.configure(configuration(specials))
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 0.01)
    let invisibleInkInvalidations = body.inkInvalidationsForTest
    for zoom in [0.015, 0.02, 0.04, 0.1] {
        body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: zoom)
    }
    precondition(body.inkForTest.isEmpty && body.inkInvalidationsForTest == invisibleInkInvalidations,
        "wide zoom with invisible text/labels must not dirty the native ink surface")
    specials.id = UUID()
    specials.tracks[0].clips[0].text = "Nova canção\nDm G C"
    body.configure(configuration(specials))
    precondition(body.inkForTest.isEmpty, "project replacement clears previous ink before projection")
    body.project(viewport: viewport, documentSize: CGSize(width: 4000, height: 400), scale: 80)
    precondition(body.inkValuesForTest.contains("Nova canção\nDm G C") &&
        !body.inkValuesForTest.contains("Verso 1\nC Am F G"), "project replacement cannot retain a previous text body")
    print("NATIVE_BODY_SPECIALS_HOSTED_COVERAGE_READINESS_PAN_COLLAPSE_DIRTY_AND_PROJECT_SWITCH_OK")

    // Distinct cold sources ensure offscreen rows cannot be satisfied through
    // a duplicate source already decoded for the visible rows.
    var verticalSong = Song(id: UUID(), name: "Vertical coverage", duration: 20, bpm: 120, tracks: [], parts: [])
    var verticalURLs: [URL] = []
    for index in 0..<24 {
        let path = "row-\(index).wav"
        let target = directory.appendingPathComponent(path)
        try FileManager.default.copyItem(at: url, to: target)
        verticalURLs.append(target)
        var track = Track(id: UUID(), name: "Row \(index)", role: TrackRole(rawValue: "standard"))
        track.clips = [AudioClip(id: UUID(), name: "Wave \(index)", startTime: 0, duration: 2,
                               audioFile: AudioFile(path: path))]
        verticalSong.tracks.append(track)
    }
    var verticalPrepared = false
    Task { @MainActor in
        await cache.preload(verticalURLs)
        verticalPrepared = true
    }
    awaitValue({ verticalPrepared }, "all compact source overviews must be ready before the cold detail gesture")
    body.configure(configuration(verticalSong, height: 80))
    let verticalDocument = CGSize(width: 40_000, height: 55 + 24 * 80)
    var verticalViewport = CGRect(x: 512, y: 800, width: 600, height: 260)
    cache.pauseNativeBodyTestDecoding(); paused = true
    body.project(viewport: verticalViewport, documentSize: verticalDocument, scale: 600)
    let baselineTile = TimelineWaveformCoverage.preparedRect(visibleRect: CGRect(x: 512, y: 512, width: 600, height: 260), documentSize: verticalDocument)
    let baselineRows = verticalSong.tracks.indices.filter { index in
        let rect = CGRect(x: 1, y: 58 + index * 80, width: 1198, height: 74)
        return rect.intersects(baselineTile)
    }.count
    precondition(body.waveformIDsForTest.count <= baselineRows - 3,
                 "native Y coverage must remove at least three offscreen PCM sources in this viewport")
    let firstVerticalGeometry = body.surfaceGeometryForTest
    let firstVerticalIDs = body.waveformIDsForTest
    for (index, scale) in [600.0, 800, 1200, 2400, 1200, 600].enumerated() {
        body.project(viewport: verticalViewport.offsetBy(dx: CGFloat(index) * 35, dy: 0),
                     documentSize: verticalDocument, scale: scale)
        precondition(body.surfaceGeometryForTest == firstVerticalGeometry && body.waveformIDsForTest == firstVerticalIDs,
                     "horizontal zoom/pan retains native Y geometry and source membership")
    }
    body.project(viewport: verticalViewport, documentSize: verticalDocument, scale: 600)
    let stationarySubmissions = body.fillSubmissionsForTest
    for delta in stride(from: CGFloat(0), through: 192, by: 0.5) {
        body.project(viewport: verticalViewport.offsetBy(dx: 0, dy: delta), documentSize: verticalDocument, scale: 600)
        precondition(body.frame.contains(verticalViewport.offsetBy(dx: 0, dy: delta)))
    }
    precondition(body.fillSubmissionsForTest == stationarySubmissions,
                 "384 subpixel vertical events inside the retained safety margin must submit no new scene")
    print("NATIVE_Y_RETAINS_ACROSS_ZOOM_AND_SUBPIXEL_PAN_SOURCES_\(body.waveformIDsForTest.count)_OLD_\(baselineRows)_OK")

    let device = MTLCreateSystemDefaultDevice()!
    let visualEngine = MetalWaveformEngine(device: device, synchronousPreparation: true)
    precondition(visualEngine.isReady)
    var visualBuffers: MetalWaveformEngine.SourceBuffers = [:]
    func assertVisibleWaves(_ visible: CGRect, name: String) {
        let frame = body.waveformsForTest!
        precondition(body.frame.contains(visible), "destination coverage exists before the clip moves")
        let origin = frame.coordinateSpace!.documentOrigin
        let expectedRows = verticalSong.tracks.indices.filter { index in
            CGRect(x: 1, y: 58 + index * 80, width: 1198, height: 74).intersects(visible)
        }
        for index in expectedRows {
            precondition(frame.strokes.contains { stroke in
                stroke.block.key != "timeline-centerline-unit" &&
                abs(stroke.itemRect.minY + origin.y - CGFloat(58 + index * 80)) < 0.001
            }, "every newly visible row has actual source geometry while PCM decode is paused")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(frame.size.width), height: Int(frame.size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = visualEngine.commandQueue!.makeCommandBuffer()!
        precondition(visualEngine.encode(frame, pass: pass, command: command, density: 1, retaining: &visualBuffers))
        command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
                        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        for index in expectedRows {
            let rect = CGRect(x: 1, y: 58 + index * 80 + 25, width: 1198, height: 49).intersection(visible)
            if rect.isNull || rect.height < 2 { continue }
            let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            var alpha = 0
            for y in Int(ceil(local.minY))..<Int(floor(local.maxY)) {
                for x in Int(ceil(local.minX))..<Int(floor(local.maxX)) {
                    alpha += pixels[(y * texture.width + x) * 4 + 3] > 0 ? 1 : 0
                }
            }
            precondition(alpha > 0, "rendered \(name) visible row \(index) cannot pop in blank")
        }
    }
    // Model the controller preflight: project the exact destination before
    // NSClipView exposes it, including destinations inside a hosted bucket.
    for y: CGFloat in [1021, 1450, 1715, 0, 800] {
        verticalViewport.origin.y = y
        body.project(viewport: verticalViewport, documentSize: verticalDocument, scale: 600)
        assertVisibleWaves(verticalViewport, name: "cold-\(Int(y))")
        let entered = body.fillSubmissionsForTest
        body.project(viewport: verticalViewport, documentSize: verticalDocument, scale: 600)
        precondition(body.fillSubmissionsForTest == entered, "bounds notification following preflight cannot redraw twice")
    }
    let coarseBeforeReadiness = body.waveformsForTest!
    let fillsBeforeReadiness = body.fillSubmissionsForTest
    cache.resumeNativeBodyTestDecoding(); paused = false
    awaitValue({ body.waveformsForTest!.strokes.contains { !$0.block.isPeakEnvelope && $0.block.key != "timeline-centerline-unit" } },
               "cold visible PCM must replace its compact source curve without another viewport event")
    precondition(body.fillSubmissionsForTest == fillsBeforeReadiness &&
                 body.waveformsForTest!.coordinateSpace == coarseBeforeReadiness.coordinateSpace,
                 "PCM readiness preserves exact projected item alignment and fill surface")
    assertVisibleWaves(verticalViewport, name: "ready")
    print("NATIVE_Y_FAST_ENTRY_COLD_SOURCE_PIXELS_PCM_READINESS_AND_STOP_EXACT_OK")

    let beforeResize = body.frame
    verticalViewport.size.height = 400
    body.project(viewport: verticalViewport, documentSize: verticalDocument, scale: 600)
    precondition(body.frame.contains(verticalViewport) && body.frame != beforeResize,
                 "window resize refreshes the retained vertical band")
    body.project(viewport: CGRect(x: 512, y: 1715, width: 600, height: 260), documentSize: verticalDocument, scale: 600)
    precondition(body.frame.maxY == verticalDocument.height, "document end clips retained coverage exactly")
    print("NATIVE_Y_RESIZE_AND_DOCUMENT_EDGE_COVERAGE_OK")

    body.configure(nil)
    precondition(body.isHidden && !body.observesReadinessForTest && body.fillsForTest!.isEmpty && body.waveformsForTest!.isEmpty && body.inkForTest.isEmpty)
    let removedCount = body.waveformSubmissionsForTest
    cache.publishNativeBodyTestReadiness()
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    precondition(body.waveformSubmissionsForTest == removedCount, "removed body cannot retain readiness work")
    song.tracks.removeAll()
    precondition(configuration(song) == nil)
    print("NATIVE_BODY_REMOVAL_AND_EMPTY_PROJECT_OK")
}
setbuf(stdout, nil)
try MainActor.assumeIsolated { try testNativeTimelineBody() }
