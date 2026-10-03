import Foundation
import AVFoundation

setbuf(stdout, nil)
let mediaURLs = TimelineMediaURLCache()
let projectA = URL(fileURLWithPath: "/tmp/CatLive A", isDirectory: true)
let projectB = URL(fileURLWithPath: "/tmp/CatLive B", isDirectory: true)
let mediaPath = "Stems/Música #1/Violão 50%.wav"
let firstURL = mediaURLs.resolve(mediaPath, directory: projectA)
precondition(firstURL.path == projectA.path + "/" + mediaPath)
for _ in 0..<1000 { precondition(mediaURLs.resolve(mediaPath, directory: projectA) == firstURL) }
precondition(mediaURLs.resolve(mediaPath, directory: projectB).path == projectB.path + "/" + mediaPath)
precondition(mediaURLs.resolve(mediaPath, directory: projectA) == firstURL)
print("TIMELINE_MEDIA_URL_CACHE_UNICODE_AND_PROJECT_SWITCH_OK")
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
let completeOverview = expandingOwner.blocks(cache: cache, url: url, header: header, start: 0, end: 4, scale: 2000, key: "warm-zoom")
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
