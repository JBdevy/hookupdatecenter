import Foundation
import AVFoundation

setbuf(stdout, nil)
let mediaURLs = TimelineMediaURLCache()
let projectA = URL(fileURLWithPath: "/tmp/CatLive A", isDirectory: true)
let projectB = URL(fileURLWithPath: "/tmp/CatLive B", isDirectory: true)
let mediaPath = "Stems/Música #1/Violão 50%.wav"
let firstURL = mediaURLs.resolve(mediaPath, directory: projectA)
precondition(firstURL.path == projectA.path + "/" + mediaPath)
for _ in 0..<1000 {
    let source = mediaURLs.resolveSource(mediaPath, directory: projectA)
    precondition(source.url == firstURL && source.path == firstURL.path)
}
let switchedSource = mediaURLs.resolveSource(mediaPath, directory: projectB)
precondition(switchedSource.path == projectB.path + "/" + mediaPath && switchedSource.url.path == switchedSource.path)
precondition(mediaURLs.resolve(mediaPath, directory: projectA) == firstURL)
print("TIMELINE_MEDIA_URL_CACHE_UNICODE_AND_PROJECT_SWITCH_OK")

let clipMedia = TimelineMediaURLCache()
let clipID = UUID(), secondClipID = UUID()
var sourceResolutions = 0
var trackFile = AudioFile(path: mediaPath)
var clipFile: AudioFile?
func effectiveMediaPath() -> String {
    sourceResolutions += 1
    return (clipFile ?? trackFile).path
}
func clipSource(_ id: UUID = clipID) -> TimelineMediaURLCache.Source? {
    clipMedia.resolveClipSource(id, path: effectiveMediaPath())
}
precondition(clipSource() == nil && sourceResolutions == 0)
clipMedia.prepareClipRevision(directory: projectA)
precondition(sourceResolutions == 0, "Configuring a revision must not resolve offscreen sources")
precondition(clipSource()!.url == firstURL && sourceResolutions == 1)
for _ in 0..<1000 {
    precondition(clipSource()!.path == firstURL.path)
}
precondition(sourceResolutions == 1,
             "Warm clip projections must skip path resolution, Unicode hashing and directory comparison")
precondition(clipSource(secondClipID)!.url == firstURL && sourceResolutions == 2)

clipFile = AudioFile(path: "Stems/Outra tomada #2%.wav")
clipMedia.prepareClipRevision(directory: projectA)
let replacement = clipSource()!
precondition(replacement.path == projectA.appendingPathComponent(clipFile!.path, isDirectory: false).path && replacement.url != firstURL,
             "The same UUID and directory must adopt a replacement clip file in a new revision")
clipFile = nil
clipMedia.prepareClipRevision(directory: projectA)
precondition(clipSource()!.url == firstURL, "Removing an override restores the track's source")
trackFile = AudioFile(path: "Stems/Pista substituída.wav")
clipMedia.prepareClipRevision(directory: projectA)
precondition(clipSource()!.path == projectA.appendingPathComponent(trackFile.path, isDirectory: false).path,
             "Inherited track-file edits also invalidate the same clip UUID")

clipMedia.prepareClipRevision(directory: projectB)
precondition(clipSource()!.path == projectB.appendingPathComponent(trackFile.path, isDirectory: false).path)
clipMedia.prepareClipRevision(directory: projectA)
precondition(clipSource()!.path == projectA.appendingPathComponent(trackFile.path, isDirectory: false).path)
// A revision can remove a clip, and a later undo or song can reuse its UUID.
clipMedia.prepareClipRevision(directory: projectA)
_ = clipSource(secondClipID)
trackFile = AudioFile(path: mediaPath)
clipMedia.prepareClipRevision(directory: projectA)
precondition(clipSource()!.url == firstURL)
clipMedia.prepareClipRevision(directory: nil)
let detachedResolutions = sourceResolutions
precondition(clipSource() == nil && sourceResolutions == detachedResolutions,
             "Detaching clears cached clips without evaluating a source path")
clipMedia.prepareClipRevision(directory: projectB)
precondition(clipSource()!.url == switchedSource.url, "Re-enabling cannot reuse a detached project's clip source")
print("TIMELINE_CLIP_MEDIA_REVISION_LAZY_LOOKUP_REPLACEMENT_FALLBACK_REUSE_AND_DETACH_OK")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-metal-scene-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let rate = 48_000.0
let url = directory.appendingPathComponent("Stereo.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
buffer.frameLength = 192_000
for frame in 0..<Int(buffer.frameLength) {
    let value = Float(sin(Double(frame) * 2 * .pi * 437 / rate) * 0.5)
    buffer.floatChannelData![0][frame] = value
    buffer.floatChannelData![1][frame] = -value
}
do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
func awaitValue<T>(_ body: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if let value = body() { return value }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    fatalError("Timed out waiting for Metal scene")
}
let worker = DispatchQueue(label: "jaras.metal.scene.test.decode")
let cache = TimelineAudioWaveform(worker: worker)
let header = awaitValue { cache.header(url) }
let owner = TimelineWaveformVertexOwner()
func ready(_ start: Double, _ end: Double, _ scale: Double) -> TimelineAudioWaveform.VertexDrawing {
    awaitValue {
        let result = cache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: scale)
        return result.complete ? result : nil
    }
}

// Reproduce incrementally completed geometry: block 1 arrives while 2 and 3
// remain blocked, and previously visible block 0 must stay unchanged.
let initial = ready(0, 512 / rate, rate)
let gate = DispatchSemaphore(value: 0)
worker.suspend()
owner.beginFrame()
let pinned = owner.blocks(cache: cache, url: url, header: header, start: 0, end: 1024 / rate, scale: rate, key: "progressive")
owner.endFrame()
precondition(pinned.count == 1 && pinned[0] === initial.blocks[0])
worker.async { gate.wait() }
owner.beginFrame()
_ = owner.blocks(cache: cache, url: url, header: header, start: 0, end: 2048 / rate, scale: rate, key: "progressive")
owner.endFrame()
worker.resume()
_ = ready(512 / rate, 1024 / rate, rate)
owner.beginFrame()
let expanding = owner.blocks(cache: cache, url: url, header: header, start: 0, end: 2048 / rate, scale: rate, key: "progressive")
owner.endFrame()
gate.signal()
precondition(expanding.count == 2 && expanding[0] === initial.blocks[0] && expanding[1].start == 512,
             "new ready blocks must fill the visible interval without replacing its existing curve")
_ = ready(0, 2048 / rate, rate)
print("METAL_SCENE_PARTIAL_BLOCKS_APPEAR_PROGRESSIVELY_WITHOUT_OVERLAPPING_LAYERS_OK")

let scale = 300.0
let start = 10.0
let rect = CGRect(x: start * scale, y: 50, width: 2 * scale, height: 100)
let viewport = CGRect(x: rect.minX + 20, y: 40, width: 400, height: 160)
var clip = AudioClip(id: UUID(), name: "Stereo", startTime: start, duration: 2, sourceOffset: 0.25, gain: 1)
func scene(_ clip: AudioClip, fragments: [AudioClip]? = nil, rectangle: CGRect = rect, window: CGRect = viewport) -> MetalWaveformFrame {
    TimelineMetalWaveformFrameBuilder.make(items: [TimelineWaveformItem(clip: clip, fragments: fragments ?? [clip], url: url, rect: rectangle, gray: 0.7)],
        viewport: window, scale: scale, cache: cache, owner: owner)
}
func audioStrokes(_ frame: MetalWaveformFrame) -> [MetalWaveformStroke] {
    frame.strokes.filter { $0.block.key != "timeline-centerline-unit" }
}
_ = ready(0, 4, scale)
let stereo = scene(clip)
let stereoAudio = audioStrokes(stereo)
precondition(!stereoAudio.isEmpty && Set(stereoAudio.map(\.channel)) == Set([0, 1]))
for stroke in stereoAudio {
    precondition(viewport.size.width >= stroke.clip.maxX && stroke.clip.minX >= 0)
    precondition(stroke.clip.minY >= 0 && stroke.clip.maxY <= viewport.height)
    let sourceTime = Double(stroke.block.start) / rate
    let expected = (clip.startTime + (sourceTime - clip.sourceOffset) / clip.audioRate) * scale - viewport.minX
    precondition(abs(Double(stroke.translation.x) - expected) < 0.001,
                 "waveform vertices and item edges must share the same viewport transform")
}
clip.gain = pow(10, 24.0 / 20)
let louder = audioStrokes(scene(clip))
precondition(abs(louder[0].scale.y / stereoAudio[0].scale.y - Float(pow(10, 24.0 / 20))) < 0.0001,
             "waveform gain must continue scaling above 0 dB up to +24 dB")
clip.gain = 1
for mode in [1, 2, 3] {
    clip.channelMode = mode
    let strokes = audioStrokes(scene(clip))
    precondition(!strokes.isEmpty)
    precondition(Set(strokes.map(\.channel)) == Set([mode == 1 ? 0 : mode == 2 ? 1 : 2]))
    if mode == 3 {
        precondition(strokes.allSatisfy { $0.block.channels[2].allSatisfy { abs($0.y) < 0.000001 } },
                     "L/R mono mix uses the actual phase-cancelled source, not an average peak envelope")
    }
}
print("METAL_SCENE_VIEWPORT_TRANSFORMS_STEREO_MONO_MIX_AND_POSITIVE_GAIN_OK")

clip.channelMode = 0
clip.loopStart = 0.2; clip.loopLength = 0.5; clip.sourceOffset = -0.125
_ = ready(0.2, 0.7, scale)
let repeated = scene(clip)
let repeats = audioStrokes(repeated)
precondition(!repeats.isEmpty && Set(repeats.map { $0.clip.minX }).count >= 3)
precondition(repeats.allSatisfy { $0.firstSeamX != nil && $0.repeatSpacing! >= 10 })
for stroke in repeats {
    let x = Double(stroke.clip.midX)
    let timelinePosition = (x + viewport.minX) / scale
    let relative = clip.sourceOffset + (timelinePosition - clip.startTime) * clip.audioRate
    let phase = ((relative - clip.loopStart!).truncatingRemainder(dividingBy: 0.5) + 0.5).truncatingRemainder(dividingBy: 0.5)
    let actualSource = Double(stroke.block.start) / rate + (x - Double(stroke.translation.x)) / (Double(stroke.scale.x) * rate)
    precondition(abs(actualSource - (clip.loopStart! + phase)) < 0.00001,
                 "backward extensions and repeats must retain their source phase")
}
print("METAL_SCENE_LOOP_OFFSETS_BACKWARD_EXTENSION_AND_NOTCHES_OK")

clip.loopLength = nil; clip.loopStart = nil; clip.sourceOffset = 0
var first = clip, second = clip
first.duration = 1; first.playbackRate = 0.5
second.startTime += 1; second.duration = 1; second.sourceOffset = 0.5; second.playbackRate = 2
_ = ready(0, 0.5, scale / first.audioRate)
_ = ready(0.5, 2.5, scale / second.audioRate)
let tempo = audioStrokes(scene(clip, fragments: [first, second]))
precondition(Set(tempo.map { Int(($0.scale.x * Float(rate)).rounded()) }) == Set([150, 600]),
             "tempo fragments must use their independent playback rates")
let seamX = (start + 1) * scale - viewport.minX
precondition(tempo.contains { abs($0.clip.maxX - seamX) < 0.001 } && tempo.contains { abs($0.clip.minX - seamX) < 0.001 })
let collapsed = scene(clip, rectangle: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 18))
precondition(collapsed.strokes.isEmpty, "thin items must not draw waveforms or centerlines")
precondition(!scene(clip).strokes.isEmpty, "expanding the track restores its cached waveform")
let absent = scene(clip, window: CGRect(x: 0, y: 0, width: 200, height: 200))
precondition(absent.strokes.isEmpty, "offscreen items must not emit waveform work")
print("METAL_SCENE_TEMPO_FRAGMENTS_AND_OFFSCREEN_CULLING_OK")

_ = ready(0, 4, 20) // Prepare the full-source zoom-out pyramid before exercising cached zoom.
let expandingOwner = TimelineWaveformVertexOwner()
expandingOwner.beginFrame()
_ = expandingOwner.blocks(cache: cache, url: url, header: header, start: 0, end: 512 / rate, scale: rate, key: "warm-zoom")
expandingOwner.endFrame()
worker.suspend()
expandingOwner.beginFrame()
let completeOverview = expandingOwner.blocks(cache: cache, url: url, header: header, start: 0, end: 4, scale: 20, key: "warm-zoom")
expandingOwner.endFrame()
worker.resume()
precondition(completeOverview.first?.start == 0 && completeOverview.last?.end == header.frames &&
             zip(completeOverview, completeOverview.dropFirst()).allSatisfy { $0.end >= $1.start },
             "a warm source must immediately cover newly exposed audio while detailed decoding is blocked")
print("METAL_SCENE_WARM_ZOOM_REUSES_COMPLETE_OVERVIEW_WITHOUT_PROGRESSIVE_GAPS_OK")

// A preloaded project uses compact peak intervals. A subpixel loop can fall
// wholly inside one interval, so neither stored endpoint belongs to the loop.
// Its visible band must still contain that interval's actual signed extrema.
var preloaded = false
Task { @MainActor in await cache.preload([url]); preloaded = true }
_ = awaitValue { preloaded ? true : nil }
for length: Double? in [nil, 1 / rate, 0.005, 0.2, 3] {
    for offset in [-0.125, 0.2, 0.701] {
        var seamClip = clip
        seamClip.loopStart = 0.2; seamClip.loopLength = length; seamClip.sourceOffset = offset
        let expected = Array(ClipRepetitionBoundaries(clip: seamClip,
            visible: max(seamClip.startTime, (viewport.minX - 4) / scale)...max(seamClip.startTime, (viewport.maxX + 4) / scale),
            minimumSpacing: 10 / scale)).first.map { CGFloat($0 * scale - viewport.minX) }
        let frame = scene(seamClip)
        precondition(!frame.strokes.isEmpty && frame.strokes.allSatisfy { $0.firstSeamX == expected },
                     "one seam lookup must preserve phase and empty ranges for ordinary and subpixel repetitions")
    }
}
print("METAL_SCENE_FIRST_SEAM_MATCHES_COMPLETE_SEQUENCE_FOR_TRIMS_AND_LOOP_DENSITIES_OK")
var shortLoop = clip
shortLoop.channelMode = 0
shortLoop.loopStart = 0.123
shortLoop.loopLength = 1 / rate
shortLoop.sourceOffset = shortLoop.loopStart!
let tinyLoop = scene(shortLoop)
precondition(tinyLoop.strokes.count == 2 && tinyLoop.strokes.allSatisfy { $0.lineWidth > 30 },
             "a loop contained inside a peak interval must retain both channels' extrema instead of a flat line")
shortLoop.channelMode = 3
let cancellingLoop = scene(shortLoop)
precondition(cancellingLoop.strokes.count == 1 && cancellingLoop.strokes[0].lineWidth == 0.5,
             "a truly phase-cancelled loop must retain the silent centerline")
print("METAL_SCENE_SUBBUCKET_REPETITION_PRESERVES_REAL_PEAKS_AND_MONO_CANCELLATION_OK")

// Hold the detail decoder after its first block. The prepared envelope must
// remain complete until the whole viewport can switch to the thin sample line.
let detailWorker = DispatchQueue(label: "jaras.metal.scene.sample-detail")
let detailCache = TimelineAudioWaveform(worker: detailWorker)
var detailPreloaded = false
Task { @MainActor in await detailCache.preload([url]); detailPreloaded = true }
_ = awaitValue { detailPreloaded ? true : nil }
let detailHeader = detailCache.header(url)!
let detailOwner = TimelineWaveformVertexOwner()
let detailScale = rate / 2
var detailClip = AudioClip(id: UUID(), name: "Sample contour", startTime: 10, duration: 2,
    sourceOffset: 12345.25 / rate, gain: 1)
let detailRect = CGRect(x: detailClip.startTime * detailScale + 1, y: 50, width: 2 * detailScale - 2, height: 100)
let detailViewport = CGRect(x: detailRect.minX + 11.5, y: 40, width: 1024, height: 160)
func detailedScene(_ clip: AudioClip = detailClip) -> MetalWaveformFrame {
    TimelineMetalWaveformFrameBuilder.make(items: [TimelineWaveformItem(clip: clip, fragments: [clip], url: url, rect: detailRect, gray: 0.7)],
        viewport: detailViewport, scale: detailScale, cache: detailCache, owner: detailOwner)
}
let sourceFirst = detailClip.sourceOffset + detailViewport.minX / detailScale - detailClip.startTime
let sourceLast = sourceFirst + detailViewport.width / detailScale
let firstBlockStart = floor(sourceFirst * rate / 512) * 512
detailWorker.suspend()
_ = detailCache.vertexDrawing(url, header: detailHeader, start: firstBlockStart / rate,
    end: (firstBlockStart + 512) / rate, pixelsPerSecond: detailScale)
let detailGate = DispatchSemaphore(value: 0)
detailWorker.async { detailGate.wait() }
let waitingFrame = detailedScene()
let waitingAudio = audioStrokes(waitingFrame)
precondition(!waitingAudio.isEmpty && waitingAudio.allSatisfy { $0.block.isPeakEnvelope },
             "preloaded detail must keep the complete envelope while PCM is unavailable")
detailWorker.resume()
_ = awaitValue {
    detailCache.vertexDrawing(url, header: detailHeader, start: firstBlockStart / rate,
        end: (firstBlockStart + 512) / rate, pixelsPerSecond: detailScale).complete ? true : nil
}
let partialDetail = detailCache.vertexDrawing(url, header: detailHeader, start: sourceFirst, end: sourceLast, pixelsPerSecond: detailScale)
precondition(!partialDetail.complete && !partialDetail.blocks.isEmpty)
let partialFrame = audioStrokes(detailedScene())
precondition(partialFrame.count == waitingAudio.count && zip(partialFrame, waitingAudio).allSatisfy { $0.block === $1.block },
             "a partial fine level must not overlap or punch holes in the prepared envelope")
detailGate.signal()
let completeFrame: MetalWaveformFrame = awaitValue {
    let frame = detailedScene(), audio = audioStrokes(frame)
    return !audio.isEmpty && audio.allSatisfy({ !$0.block.isPeakEnvelope && $0.block.step == 1 }) ? frame : nil
}
let completeAudio = audioStrokes(completeFrame)
precondition(completeAudio.allSatisfy { $0.lineWidth == 1 }, "sample detail draws a thin connected contour")
for stroke in completeAudio {
    let expected = (detailClip.startTime + (Double(stroke.block.start) / rate - detailClip.sourceOffset)) * detailScale - detailViewport.minX
    precondition(abs(Double(stroke.translation.x) - expected) < 0.0001,
                 "the envelope-to-sample transition must preserve fractional source offset and viewport alignment")
}
detailWorker.suspend()
let warmDetail = audioStrokes(detailedScene())
detailWorker.resume()
precondition(warmDetail.count == completeAudio.count && zip(warmDetail, completeAudio).allSatisfy { $0.block === $1.block },
             "warm sample transforms reuse the same immutable source vertices")
print("METAL_PRELOADED_DETAIL_RETAINS_ENVELOPE_UNTIL_COMPLETE_THEN_DRAWS_ALIGNED_THIN_PCM_OK")

// Detail levels 3 and 6 have nonnested 512/768-frame block boundaries. A
// partially ready replacement must never overlap the retained complete curve.
let transitionOwner = TimelineWaveformVertexOwner()
func transition(_ first: Double, _ last: Double, step: Int, key: String = "detail-transition") -> [TimelineAudioWaveform.VertexBlock] {
    transitionOwner.beginFrame()
    let blocks = transitionOwner.blocks(cache: detailCache, url: url, header: detailHeader,
        start: first / rate, end: last / rate, scale: rate / Double(step * 2), key: key)
    transitionOwner.endFrame()
    return blocks
}
func contiguous(_ blocks: [TimelineAudioWaveform.VertexBlock], _ first: Double, _ last: Double) -> Bool {
    blocks.first.map { Double($0.start) <= first } == true &&
    blocks.last.map { Double($0.end) >= last } == true &&
    zip(blocks, blocks.dropFirst()).allSatisfy { $0.end == $1.start }
}
let transitionFirst = 70_000.25, transitionLast = 72_000.5
let level3 = awaitValue {
    let blocks = transition(transitionFirst, transitionLast, step: 3)
    return blocks.allSatisfy({ $0.step == 3 && !$0.isPeakEnvelope }) && contiguous(blocks, transitionFirst, transitionLast) ? blocks : nil
}
detailWorker.sync {}
detailWorker.suspend()
let first6 = floor(transitionFirst / 768) * 768
_ = detailCache.vertexDrawing(url, header: detailHeader, start: first6 / rate,
    end: (first6 + 768) / rate, pixelsPerSecond: rate / 12)
let transitionGate = DispatchSemaphore(value: 0)
detailWorker.async { transitionGate.wait() }
let blocked6 = transition(transitionFirst, transitionLast, step: 6)
precondition(blocked6.count == level3.count && zip(blocked6, level3).allSatisfy { $0 === $1 },
    "a cold fine level must keep the exact previous PCM curve")
detailWorker.resume()
_ = awaitValue {
    detailCache.vertexDrawing(url, header: detailHeader, start: first6 / rate,
        end: (first6 + 768) / rate, pixelsPerSecond: rate / 12).complete ? true : nil
}
let partial6 = detailCache.vertexDrawing(url, header: detailHeader,
    start: transitionFirst / rate, end: transitionLast / rate, pixelsPerSecond: rate / 12)
precondition(!partial6.complete && partial6.blocks.count == 1)
for step in [6, 3, 12, 3, 6] {
    let blocks = transition(transitionFirst, transitionLast, step: step)
    precondition(blocks.count == level3.count && zip(blocks, level3).allSatisfy { $0 === $1 } &&
        contiguous(blocks, transitionFirst, transitionLast),
        "rapid reversal and nonnested partial levels must retain one contiguous PCM curve without a coarse flash")
}
transitionGate.signal()
let level6 = awaitValue {
    let blocks = transition(transitionFirst, transitionLast, step: 6)
    return blocks.allSatisfy({ $0.step == 6 }) && contiguous(blocks, transitionFirst, transitionLast) ? blocks : nil
}
precondition(!level6.isEmpty && level6.allSatisfy { !$0.isPeakEnvelope })
print("METAL_DETAIL_NONNESTED_PARTIAL_LEVEL_AND_RAPID_REVERSAL_KEEP_COMPLETE_PCM_OK")

// Give the bounded neighbor reserve time to finish, then pan farther than the
// reserve with decoding held. Existing fine blocks stay visible; arriving
// adjacent blocks extend that same level, without restoring the old envelope.
detailWorker.sync {}
let panFirst = transitionLast - 384, panLast = transitionLast + 4 * 768
detailWorker.suspend()
let coldPan = transition(panFirst, panLast, step: 6)
precondition(!coldPan.isEmpty && coldPan.allSatisfy { $0.step == 6 && !$0.isPeakEnvelope } &&
    zip(coldPan, coldPan.dropFirst()).allSatisfy { $0.end == $1.start },
    "a pan into adjacent cold blocks must retain fine detail instead of flashing a prepared envelope")
let coldDuplicate = transition(panFirst + 20_000, panLast + 20_000, step: 6, key: "new-fragment")
precondition(coldDuplicate.allSatisfy { !$0.isPeakEnvelope },
    "new loop/fragment presentation keys must not undo the source's established fine detail")
detailWorker.resume()
_ = awaitValue {
    let blocks = transition(panFirst, panLast, step: 6)
    return blocks.allSatisfy({ $0.step == 6 }) && contiguous(blocks, panFirst, panLast) ? true : nil
}
print("METAL_DETAIL_COLD_ADJACENT_PAN_AND_NEW_FRAGMENT_NEVER_RESTORE_PEAK_ENVELOPE_OK")

// Sweep every genuine PCM resolution in both directions. All swaps are single
// level, source aligned, contiguous, and use the same exact original samples.
for step in TimelineAudioWaveform.detailSteps + TimelineAudioWaveform.detailSteps.reversed() {
    let blocks = awaitValue {
        let blocks = transition(65_001.25, 78_003.5, step: step)
        precondition(blocks.allSatisfy { !$0.isPeakEnvelope }, "settling a fine zoom must never restore the old envelope")
        return blocks.allSatisfy({ $0.step == step }) && contiguous(blocks, 65_001.25, 78_003.5) ? blocks : nil
    }
    precondition(Set(blocks.map(\.step)) == [step])
    for block in blocks {
        for point in block.channels[0] {
            let frame = Double(block.start) + Double(point.x)
            let original = Float(sin(frame * 2 * .pi * 437 / rate) * 0.5)
            precondition(abs(point.y + original) < 0.000001, "16 levels must use original sample coordinates and amplitude")
        }
    }
}
detailWorker.suspend()
let realZoomOut = transition(0, Double(detailHeader.frames), step: 512)
detailWorker.resume()
precondition(contiguous(realZoomOut, 0, Double(detailHeader.frames)) &&
    realZoomOut.allSatisfy { $0.isPeakEnvelope && $0.step >= 256 } && realZoomOut.count < 8,
    "a genuine zoom-out must immediately release raw detail for bounded overview work")
print("METAL_ALL_16_TRUE_PCM_LEVELS_SETTLE_IN_BOTH_DIRECTIONS_AND_REAL_ZOOMOUT_STAYS_BOUNDED_OK")

// Warm a much wider old sample level. With the desired 192-frame level held
// cold, repeated frames must not accumulate those warm neighbors indefinitely.
_ = awaitValue {
    let value = detailCache.vertexDrawing(url, header: detailHeader, start: 0,
        end: Double(detailHeader.frames) / rate, pixelsPerSecond: rate / 2)
    return value.complete ? true : nil
}
let narrowRaw = transition(70_000.25, 72_000.5, step: 1)
precondition(narrowRaw.allSatisfy { $0.step == 1 })
detailWorker.sync {}
detailWorker.suspend()
var widest = 0
for _ in 0..<256 {
    let waiting = transition(0, Double(detailHeader.frames), step: 192)
    widest = max(widest, waiting.count)
    precondition(waiting.allSatisfy { $0.step == 1 && !$0.isPeakEnvelope },
        "a pending fine zoom-out retains existing raw detail without a coarse flash")
}
detailWorker.resume()
precondition(widest <= narrowRaw.count + 4,
    "repeated frames must not accumulate an entire warm sample level while a wider fine viewport is pending")
print("METAL_PENDING_FINE_ZOOMOUT_CANNOT_ACCUMULATE_UNBOUNDED_OLD_SAMPLE_BLOCKS_OK")

// Zooming through detail levels must not eagerly decode invisible neighbors.
// Their cached geometry can still be retained immediately, and a same-level pan
// enables reads only toward the approaching edge of the source window.
let reserveWorker = DispatchQueue(label: "jaras.metal.scene.reserve")
let reserveCache = TimelineAudioWaveform(worker: reserveWorker)
let reserveHeader = awaitValue { reserveCache.header(url) }
let reserveOwner = TimelineWaveformVertexOwner()
func reserveView(_ first: Double, _ last: Double, step: Int = 8) -> [TimelineAudioWaveform.VertexBlock] {
    reserveOwner.beginFrame()
    let blocks = reserveOwner.blocks(cache: reserveCache, url: url, header: reserveHeader,
        start: first / rate, end: last / rate, scale: rate / Double(step * 2), key: "reserve")
    reserveOwner.endFrame()
    return blocks
}
func reserveReady(_ first: Double, _ last: Double, step: Int = 8) -> TimelineAudioWaveform.VertexDrawing {
    awaitValue {
        let drawing = reserveCache.vertexDrawing(url, header: reserveHeader,
            start: first / rate, end: last / rate, pixelsPerSecond: rate / Double(step * 2))
        return drawing.complete ? drawing : nil
    }
}
_ = reserveReady(50_200, 52_100)
reserveWorker.sync {}
reserveWorker.suspend()
let firstReserve = reserveView(50_200, 52_100)
precondition(contiguous(firstReserve, 50_200, 52_100))
for _ in 0..<16 {
    reserveCache.advanceRevisionForSceneTest()
    _ = reserveView(50_200, 52_100)
}
precondition(reserveCache.pendingCountForSceneTest() == 0,
    "new levels and unrelated revisions must not decode invisible reserve blocks")
_ = reserveView(50_300, 52_200) // Same width, forward pan near the block's right edge.
precondition(reserveCache.pendingCountForSceneTest() == 2,
    "an approaching same-level pan queues only its two leading neighbor blocks")
reserveWorker.resume()
reserveWorker.sync {}
let forwardNeighbors = reserveCache.vertexDrawing(url, header: reserveHeader, start: 52_224 / rate,
    end: 54_272 / rate, pixelsPerSecond: rate / 16, cachedOnly: true)
let backwardNeighbors = reserveCache.vertexDrawing(url, header: reserveHeader, start: 48_128 / rate,
    end: 50_176 / rate, pixelsPerSecond: rate / 16, cachedOnly: true)
precondition(forwardNeighbors.complete && backwardNeighbors.blocks.isEmpty,
    "directional reserve must leave the opposite side undecoded")

// Warm both sides deliberately, let the owner retain them, then evict the
// transient cache. Revisions from any other file must not recreate these blocks.
_ = reserveReady(48_128, 54_272)
reserveWorker.sync {}
reserveCache.advanceRevisionForSceneTest()
let retainedReserve = reserveView(50_300, 52_200)
reserveCache.evictVertexBlocksForSceneTest()
reserveWorker.suspend()
for _ in 0..<32 {
    reserveCache.advanceRevisionForSceneTest()
    let visible = reserveView(50_300, 52_200)
    precondition(visible.count == retainedReserve.count && zip(visible, retainedReserve).allSatisfy { $0 === $1 })
}
precondition(reserveCache.pendingCountForSceneTest() == 0,
    "a complete owner-held reserve must survive cache eviction and global revisions without extra decoding")
reserveWorker.resume()
print("METAL_RESERVE_NEW_LOD_NO_SPECULATIVE_DECODE_DIRECTIONAL_PAN_AND_EVICTED_WARM_REUSE_OK")

// All unpublished native origins and the lookahead before a synchronous jump
// must stay covered, including fractional window sizes and document edges.
for x in [0.0, 512.0, 8192.0] {
    for y in [0.0, 512.0, 4096.0] {
        for size in [CGSize(width: 375.5, height: 640.5), CGSize(width: 1080, height: 856), CGSize(width: 2500.75, height: 1500.25)] {
            let document = CGSize(width: 20000, height: 12000)
            let visible = CGRect(origin: CGPoint(x: x, y: y), size: size)
            let coverage = TimelineWaveformCoverage.preparedRect(visibleRect: visible, documentSize: document)
            for dx in [-128.0, 0, 127.5, 511.99, 640] {
                for dy in [-128.0, 0, 127.5, 511.99, 640] {
                    let moved = CGRect(x: max(0, x + dx), y: max(0, y + dy), width: size.width, height: size.height)
                    precondition(coverage.contains(moved), "every origin before the native synchronous flush must have waveform coverage")
                }
            }
            let bounded = TimelineWaveformCoverage.preparedRect(visibleRect: visible, documentSize: CGSize(width: x + size.width, height: y + size.height))
            precondition(bounded.maxX <= x + size.width && bounded.maxY <= y + size.height)
        }
    }
}
let zoomViewport = CGRect(x: 8192, y: 0, width: 1080, height: 856)
let zoomCoverage = TimelineWaveformCoverage.preparedRect(visibleRect: zoomViewport, documentSize: CGSize(width: 20000, height: 12000))
precondition(zoomCoverage.width * zoomCoverage.height < 2560 * 1792 * 0.7,
             "a representative zoom must no longer prepare almost three times the visible waveform area")
print("METAL_PREPARATION_COVERS_NATIVE_BUCKETS_REVERSALS_JUMPS_AND_EDGES_WITH_SMALLER_OVERSCAN_OK")

// Zoomed-out clips retain the same immutable peak geometry across transforms
// and unrelated readiness notifications, including transient cache eviction.
let coarseWorker = DispatchQueue(label: "jaras.metal.scene.coarse-owner")
let coarseCache = TimelineAudioWaveform(worker: coarseWorker)
var coarsePrepared = false
Task { @MainActor in await coarseCache.preload([url]); coarsePrepared = true }
_ = awaitValue { coarsePrepared ? true : nil }
let coarseHeader = coarseCache.header(url)!
let coarseOwner = TimelineWaveformVertexOwner()
func coarseView(first: Double = 512, last: Double = 100_000, step: Int = 256) -> [TimelineAudioWaveform.VertexBlock] {
    coarseOwner.beginFrame()
    let result = coarseOwner.blocks(cache: coarseCache, url: url, header: coarseHeader,
        start: first / rate, end: last / rate, scale: rate / Double(step * 2), key: "coarse")
    coarseOwner.endFrame()
    return result
}
let initialCoarse = awaitValue {
    let result = coarseView()
    return contiguous(result,512,100_000) && result.allSatisfy { $0.step == 256 } ? result : nil
}
precondition(contiguous(initialCoarse,512,100_000) && initialCoarse.allSatisfy { $0.step == 256 && $0.isPeakEnvelope })
coarseWorker.sync {}; coarseWorker.suspend()
coarseCache.evictVertexBlocksForSceneTest()
for tick in 0..<128 {
    coarseCache.advanceRevisionForSceneTest()
    let current = coarseView(first:512 + Double(tick),last:100_000 - Double(tick))
    precondition(current.count == initialCoarse.count && zip(current,initialCoarse).allSatisfy { $0 === $1 },
        "covered coarse projections must reuse owner-held vertices, including after cache eviction")
}
precondition(coarseCache.pendingCountForSceneTest() == 0,
    "warm coarse projection must not enqueue source decoding or geometry rebuilds")
coarseWorker.resume()
let coarseLevelChange = awaitValue {
    let result = coarseView(step:1024)
    return contiguous(result,512,100_000) && result.allSatisfy { $0.step == 1024 } ? result : nil
}
precondition(coarseLevelChange.allSatisfy { $0.step == 1024 && $0.isPeakEnvelope } && contiguous(coarseLevelChange,512,100_000),
    "an actual coarse LOD change must immediately use its requested peak level")
let coarsePan = awaitValue {
    let result = coarseView(first:95_000,last:180_000)
    return contiguous(result,95_000,180_000) && result.allSatisfy { $0.step == 256 } ? result : nil
}
precondition(coarsePan.allSatisfy { $0.step == 256 } && contiguous(coarsePan,95_000,180_000),
    "panning beyond retained coverage obtains the missing peak blocks")
precondition(coarseOwner.pinnedCountForSceneTest == 1)
coarseOwner.beginFrame(); coarseOwner.endFrame()
precondition(coarseOwner.pinnedCountForSceneTest == 0,
    "clips that leave the viewport must release their owner pins; project overview cache may still hold shared geometry")
print("METAL_COARSE_OWNER_REUSES_COMPLETE_PEAKS_AFTER_EVICTION_LOD_PAN_AND_RELEASE_OK")

// Retained source headers must observe canonical cache replacements, including
// same-path reloads, recording updates, and an independent cache.
let headerURLs = TimelineMediaURLCache()
let headerURL = directory.appendingPathComponent("Música e produção – capítulo #3 50% versão final violão.wav")
try FileManager.default.copyItem(at: url, to: headerURL)
let headerWorker = DispatchQueue(label: "jaras.metal.scene.headers")
let headerCache = TimelineAudioWaveform(worker: headerWorker)
let headerSource = headerURLs.resolveSource(headerURL.lastPathComponent, directory: directory)
let initialHeader = awaitValue { headerSource.header(cache: headerCache, refresh: false, contentRevision: 1) }
_ = awaitValue { headerCache.revision > 0 ? true : nil }
let currentHeader = headerSource.header(cache: headerCache, refresh: false, contentRevision: 1)!
let initialLookups = headerCache.headerLookupsForSceneTest
for _ in 0..<256 {
    precondition(headerSource.header(cache: headerCache, refresh: false, contentRevision: 1) === currentHeader)
}
precondition(headerCache.headerLookupsForSceneTest == initialLookups,
    "warm source projections must not revisit NSString header lookup")
let replacingHeader = TimelineAudioWaveform.Header(rate: rate, frames: initialHeader.frames / 2, channels: 1,
    sourcePath: headerURL.path, sourceVersion: "same-path-ready")
headerCache.replaceHeaderForSceneTest(replacingHeader, url: headerURL, publish: true)
precondition(headerSource.header(cache: headerCache, refresh: false, contentRevision: 1) === replacingHeader,
    "same-path source readiness must replace a retained header")
let editedHeader = TimelineAudioWaveform.Header(rate: rate / 2, frames: initialHeader.frames / 4, channels: 2,
    sourcePath: headerURL.path, sourceVersion: "same-path-edit")
headerCache.replaceHeaderForSceneTest(editedHeader, url: headerURL, publish: false)
precondition(headerSource.header(cache: headerCache, refresh: false, contentRevision: 2) === editedHeader,
    "a structural content revision must revisit the source cache at the same path")
let recordingHeader = TimelineAudioWaveform.Header(rate: rate, frames: initialHeader.frames * 2, channels: 2,
    sourcePath: headerURL.path, sourceVersion: "recording-growth")
headerCache.replaceHeaderForSceneTest(recordingHeader, url: headerURL, publish: false)
let beforeRecording = headerCache.headerLookupsForSceneTest
for _ in 0..<32 {
    precondition(headerSource.header(cache: headerCache, refresh: true, contentRevision: 2) === recordingHeader,
        "recording must keep the existing refresh behavior even before readiness is published")
}
precondition(headerCache.headerLookupsForSceneTest == beforeRecording + 32)
let otherHeaderCache = TimelineAudioWaveform(worker: headerWorker)
let independentHeader = TimelineAudioWaveform.Header(rate: rate / 4, frames: 1024, channels: 1,
    sourcePath: headerURL.path, sourceVersion: "independent-cache")
otherHeaderCache.replaceHeaderForSceneTest(independentHeader, url: headerURL, publish: false)
precondition(headerSource.header(cache: otherHeaderCache, refresh: false, contentRevision: 2) === independentHeader,
    "same path and revision from another cache must not reuse a former cache's header")
precondition(headerSource.header(cache: headerCache, refresh: false, contentRevision: 2) === recordingHeader)
print("METAL_RETAINED_HEADER_WARM_LOOKUP_READY_EDIT_RECORDING_AND_CACHE_IDENTITY_OK")

// A real asynchronous reload can change the source while preserving its URL.
// The published revision must replace both header dimensions and source key.
let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 6000)!
mono.frameLength = 6000
for index in 0..<6000 { mono.floatChannelData![0][index] = 0.25 }
do { let replacementFile = try AVAudioFile(forWriting: headerURL, settings: monoFormat.settings); try replacementFile.write(from: mono) }
var reloadedHeaderSource = false
Task { @MainActor in await headerCache.preload([headerURL]); reloadedHeaderSource = true }
_ = awaitValue { reloadedHeaderSource ? true : nil }
let replacedFileHeader = headerSource.header(cache: headerCache, refresh: false, contentRevision: 2)!
precondition(replacedFileHeader.frames == 6000 && replacedFileHeader.rate == 24_000 && replacedFileHeader.channels == 1 &&
    replacedFileHeader.cachePrefix != recordingHeader.cachePrefix,
    "a real same-path file reload must replace the retained version and dimensions")
print("METAL_RETAINED_HEADER_REAL_SAME_PATH_RELOAD_SOURCE_VERSION_OK")

// The retained path is also used by the frame builder, and preserves exact
// source coordinates, channels, trims and visibility through a zoom sweep.
var fixtureURL = url
var benchmarkSource = headerURLs.resolveSource(url.lastPathComponent, directory: directory)
let fixtureClips = (0..<64).map { index in
    AudioClip(id: UUID(), name: "Stem \(index)", startTime: 0, duration: 4, sourceOffset: 0, gain: 1)
}
func headerScene(scale: Double, retained: Bool, owner: TimelineWaveformVertexOwner) -> MetalWaveformFrame {
    let items = fixtureClips.enumerated().map { index, clip in
        TimelineWaveformItem(clip: clip, fragments: [clip], url: fixtureURL,
            rect: CGRect(x: 1, y: Double(index * 80), width: 4 * scale - 2, height: 74), gray: 0.8,
            sourcePath: benchmarkSource.path, mediaSource: retained ? benchmarkSource : nil)
    }
    return TimelineMetalWaveformFrameBuilder.make(items: items,
        viewport: CGRect(x: 0, y: 0, width: 1200, height: 64 * 80), scale: scale,
        cache: cache, owner: owner, contentRevision: 7)
}
let ordinaryHeaderOwner = TimelineWaveformVertexOwner(), retainedHeaderOwner = TimelineWaveformVertexOwner()
for zoom in [80.0, 100, 175, 120, 90] {
    _ = ready(0, 4, zoom)
    let ordinary = headerScene(scale: zoom, retained: false, owner: ordinaryHeaderOwner)
    let retained = headerScene(scale: zoom, retained: true, owner: retainedHeaderOwner)
    precondition(retained.hasSameContent(as: ordinary),
        "cached headers must produce identical waveform geometry and coordinates through zoom")
}
let beforeSceneHeaderLookups = cache.headerLookupsForSceneTest
for index in 0..<256 {
    _ = headerScene(scale: 90 + Double(index % 16), retained: true, owner: retainedHeaderOwner)
}
precondition(cache.headerLookupsForSceneTest == beforeSceneHeaderLookups,
    "warm zoom frame construction must consume retained source headers without canonical cache lookup")
print("METAL_RETAINED_HEADER_BUILDER_EXACT_ZOOM_GEOMETRY_AND_NO_HEADER_LOOKUPS_OK")

if ProcessInfo.processInfo.environment["CATLIVE_HEADER_BENCHMARK"] == "1" {
    func benchmark(_ name: String) {
        let samples = 5, frames = 500
        var ordinary: [Double] = [], retained: [Double] = []
        var sink = 0
        for repetition in 0..<samples {
            for useRetained in repetition % 2 == 0 ? [false, true] : [true, false] {
                let owner = useRetained ? retainedHeaderOwner : ordinaryHeaderOwner
                let started = ProcessInfo.processInfo.systemUptime
                for index in 0..<frames {
                    sink += headerScene(scale: 90 + Double(index % 16), retained: useRetained, owner: owner).strokes.count
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000 / Double(frames)
                if useRetained { retained.append(elapsed) } else { ordinary.append(elapsed) }
            }
        }
        print("HEADER_SCENE_BENCHMARK_MS \(name) baseline=\(ordinary) retained=\(retained) sink=\(sink)")
    }
    benchmark("ASCII")
    let unicodeURL = directory.appendingPathComponent("Produção musical sessão com região musical original Violão Música Capítulo #1 50% versão final.wav")
    try FileManager.default.copyItem(at: url, to: unicodeURL)
    var fixturePrepared = false
    Task { @MainActor in await cache.preload([unicodeURL, url]); fixturePrepared = true }
    _ = awaitValue { fixturePrepared ? true : nil }
    fixtureURL = unicodeURL
    benchmarkSource = headerURLs.resolveSource(unicodeURL.lastPathComponent, directory: directory)
    let unicodeHeader = cache.header(unicodeURL)!
    _ = awaitValue {
        let drawing = cache.vertexDrawing(unicodeURL, header: unicodeHeader, start: 0, end: 4, pixelsPerSecond: 100)
        return drawing.complete ? true : nil
    }
    _ = headerScene(scale: 100, retained: false, owner: ordinaryHeaderOwner)
    _ = headerScene(scale: 100, retained: true, owner: retainedHeaderOwner)
    benchmark("Unicode")
}
