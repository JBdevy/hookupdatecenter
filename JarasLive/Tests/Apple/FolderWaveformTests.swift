import Foundation
import AVFoundation
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-folder-test-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("source.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
buffer.frameLength = 44_100
for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.25; buffer.floatChannelData![1][i] = 0.5 }
do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
func source(_ gain: Double, start: Double = 0, pan: Double = 0) -> FolderWaveformCache.Source {
    .init(url: url, start: start, duration: 1, offset: 0, rate: 1, loopStart: nil, loopLength: nil,
          gain: gain, pan: pan, fadeIn: 0, fadeOut: 0, fadeStart: start, fadeDuration: 1, mode: 0)
}
let folder = UUID()
let cancelled = FolderWaveformCache.render(.init(folder: folder, sources: [source(1), source(-1)], page: 0), key: "cancel")!
precondition(cancelled.channels.allSatisfy { $0.allSatisfy { abs($0.y) < 0.00001 } }, "folder must sum actual PCM, including phase cancellation")
let sum = FolderWaveformCache.render(.init(folder: folder, sources: [source(1), source(0.5)], page: 0), key: "sum")!
precondition(abs(sum.channels[0].map { abs($0.y) }.max()! - 0.375) < 0.00001)
precondition(abs(sum.channels[1].map { abs($0.y) }.max()! - 0.75) < 0.00001)
let panned = FolderWaveformCache.render(.init(folder: folder, sources: [source(1, start: 2, pan: 1), source(0)], page: 0), key: "pan")!
precondition(panned.channels[0].allSatisfy { $0.y == 0 })
precondition(panned.channels[1].filter { $0.x < 88_200 }.allSatisfy { $0.y == 0 }, "source starts at its exact timeline position")
let cache = FolderWaveformCache()
let deadline = Date(timeIntervalSinceNow: 10)
var ready: TimelineAudioWaveform.VertexBlock?
while Date() < deadline && ready == nil {
    cache.beginFrame(); ready = cache.block(folder: folder, sources: [source(1)], page: 0, pixelsPerSecond: 1); cache.endFrame()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
}
precondition(ready != nil && ready!.step >= 16_384, "folder zoom-out uses prepared GPU levels")
let detail = cache.block(folder: folder, sources: [source(1)], page: 0, pixelsPerSecond: 1000)
precondition(detail != nil && detail!.step == 256, "zoom changes do not remix PCM")
print("FOLDER_PCM_SUM_PHASE_GAIN_MUTE_PAN_ALIGNMENT_AND_CACHED_ZOOM_LEVELS_OK")

let empty = FolderWaveformCache.prepare(folder: folder, sources: [source(0)], page: 0)
precondition(empty.activeRanges.isEmpty, "muted sources never draw silence across a folder page")
let spans = FolderWaveformCache.prepare(folder: folder, sources: [source(1, start: 1), source(1, start: 1.5), source(1, start: 4)], page: 0)
precondition(spans.activeRanges == [1.0...2.5, 4.0...5.0], "sum drawing clips to merged real item extents and preserves empty gaps")
let clippedPage = FolderWaveformCache.prepare(folder: folder, sources: [source(1, start: 15.5)], page: 1)
precondition(clippedPage.activeRanges == [16.0...16.5], "sum clip intervals stop exactly at page and item boundaries")
let coarse = TimelineTimeRuler.ticks(from: 0, to: 120, pixelsPerSecond: 8)
precondition(coarse.first?.label == "00:00:00" && coarse.contains { $0.label == "00:01:00" }, "ruler labels seconds independently of meter")
let fine = TimelineTimeRuler.ticks(from: 3600, to: 3600.02, pixelsPerSecond: 100000)
precondition(fine.count <= 30 && Set(fine.map(\.label)).count == fine.count, "close zoom retains unique subsecond labels without excessive ticks")
precondition(TimelineTimeRuler.ticks(from: 0, to: 10, pixelsPerSecond: .nan).isEmpty, "invalid ruler scale is rejected")
print("FOLDER_ACTIVE_EXTENTS_AND_TIME_RULER_BOUNDARIES_OK")

let stale = cache.block(folder: folder, sources: [source(0.5)], page: 0, pixelsPerSecond: 1000)
precondition(stale === detail, "gain refresh keeps the last complete sum instead of blanking it")
var refreshed: TimelineAudioWaveform.VertexBlock?
let refreshDeadline = Date(timeIntervalSinceNow: 10)
while Date() < refreshDeadline && refreshed == nil {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    let next = cache.block(folder: folder, sources: [source(0.5)], page: 0, pixelsPerSecond: 1000)
    if let next, next !== detail { refreshed = next }
}
precondition(refreshed != nil && abs(refreshed!.channels[0].map { abs($0.y) }.max()! - 0.125) < 0.00001,
             "new gain replaces the retained curve with the actual recomputed PCM sum")
print("FOLDER_GAIN_REFRESH_RETAINS_COMPLETE_CURVE_UNTIL_REPLACEMENT_OK")

let preloadedFolder = FolderWaveformCache()
let preloadFolderID = UUID()
var folderPreloadFinished = false
Task { @MainActor in
    await preloadedFolder.preload([(folder: preloadFolderID, sources: [source(1, start: 0), source(1, start: 33)])])
    folderPreloadFinished = true
}
let folderPreloadDeadline = Date(timeIntervalSinceNow: 15)
while !folderPreloadFinished && Date() < folderPreloadDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
precondition(folderPreloadFinished)
let revisionBeforeZoom = preloadedFolder.revision
let moved = directory.appendingPathComponent("source-moved.wav")
try FileManager.default.moveItem(at: url, to: moved)
for page in [0, 2] {
    for scale in [0.1, 1, 20, 300, 2000, 81920] {
        let block = preloadedFolder.block(folder: preloadFolderID, sources: [source(1), source(1, start: 33)], page: page, pixelsPerSecond: scale)
        precondition(block != nil, "all active sum pages and zoom levels are ready in RAM before opening")
        precondition(abs(block!.channels[0].map { abs($0.y) }.max()! - 0.25) < 0.00001)
    }
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
precondition(preloadedFolder.revision == revisionBeforeZoom, "sum zoom never launches a new background mix")
try FileManager.default.moveItem(at: moved, to: url)
print("FOLDER_PROJECT_PRELOAD_ACTIVE_PAGES_ALL_ZOOMS_RAM_ONLY_WITHOUT_BACKGROUND_MIX_OK")

let diskRequest = FolderWaveformCache.Request(folder: UUID(), sources: [source(1)], page: 0)
// Use a whole-second timestamp so restoring Date through the filesystem does
// not round a fractional nanosecond and intentionally invalidate the cache.
try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
let diskBase = FolderWaveformCache.loadOrRender(diskRequest, key: "disk-initial")!
let sumCacheURL = FolderWaveformCache.diskCacheURL(diskRequest)!
let savedSum = try Data(contentsOf: sumCacheURL)
let sourceBytes = try Data(contentsOf: url)
let sourceDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
try Data(repeating: 0, count: sourceBytes.count).write(to: url)
try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: url.path)
let reopenedSum = FolderWaveformCache.loadOrRender(diskRequest, key: "disk-reopened")!
precondition(reopenedSum.channels == diskBase.channels, "valid sum cache opens without a decodable audio source")
let reopenedBytes = try Data(contentsOf: sumCacheURL)
precondition(reopenedBytes == savedSum, "valid cache must not be rewritten")
try sourceBytes.write(to: url)
try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: url.path)
let editedRequest = FolderWaveformCache.Request(folder: diskRequest.folder, sources: [source(0.5)], page: 0)
let editedSum = FolderWaveformCache.loadOrRender(editedRequest, key: "disk-edited")!
precondition(abs(editedSum.channels[0].map { abs($0.y) }.max()! - 0.125) < 0.00001, "gain change invalidates disk sum")
try Data([1, 2, 3]).write(to: sumCacheURL)
let repairedSum = FolderWaveformCache.loadOrRender(editedRequest, key: "disk-repaired")!
precondition(repairedSum.channels == editedSum.channels, "corrupt cache is rebuilt before publication")
print("FOLDER_PERSISTENT_CACHE_REOPEN_WITHOUT_AUDIO_DECODE_GAIN_INVALIDATION_AND_CORRUPTION_RECOVERY_OK")

// Fractional playback crosses the decoder page and loops back across it.
let seamURL = directory.appendingPathComponent("seam.wav")
let seamBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 70_000)!
seamBuffer.frameLength = 70_000
for i in 0..<70_000 {
    seamBuffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1))
    seamBuffer.floatChannelData![1][i] = Float(cos(Double(i) * 0.2))
}
do { let file = try AVAudioFile(forWriting: seamURL, settings: format.settings); try file.write(from: seamBuffer) }
for looped in [false, true] {
    let origin = 65_534.0 / 44_100, length = 8.0 / 44_100
    let source = FolderWaveformCache.Source(url: seamURL, start: 0, duration: 0.01,
        offset: origin + 0.25 / 44_100, rate: 0.75,
        loopStart: looped ? origin : nil, loopLength: looped ? length : nil,
        gain: 0.7, pan: 0.2, fadeIn: 0, fadeOut: 0, fadeStart: 0, fadeDuration: 0.01, mode: 0)
    var expected = [[Float]](repeating: [Float](repeating: 0, count: 16 * 44_100), count: 2)
    for i in 0..<441 {
        var position = source.offset + Double(i) / 44_100 * source.rate
        if looped { position = origin + ((position - origin).truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length) }
        let frame = position * 44_100, index = Int(frame), blend = Float(frame - Double(index))
        for channel in 0..<2 {
            let samples = seamBuffer.floatChannelData![channel]
            expected[channel][i] = (samples[index] + (samples[index + 1] - samples[index]) * blend) * Float(source.gain * (channel == 0 ? 0.8 : 1))
        }
    }
    let reference = TimelineAudioWaveform.VertexBlock(pcm: .init(channels: expected), start: 0,
        span: 16 * 44_100, step: 256, rate: 44_100, key: "reference")
    let actual = FolderWaveformCache.render(.init(folder: UUID(), sources: [source], page: 0), key: "seam")!
    precondition(actual.channels == reference.channels, "fractional rate and loops interpolate exactly across decoder pages")
}
print("FOLDER_SEQUENTIAL_READER_FRACTIONAL_RATE_LOOP_AND_PAGE_SEAMS_OK")
let seamReader = try FolderWaveformCache.Reader(seamURL)
for frame in [65_534.75, 65_535.0, 65_535.25, 65_535.5, 65_535.75, 65_536.0, 65_536.25] {
    let actual = seamReader.sample(frame), index = Int(frame), blend = Float(frame - Double(index))
    for channel in 0..<2 {
        let samples = seamBuffer.floatChannelData![channel]
        let expected = samples[index] + (samples[index + 1] - samples[index]) * blend
        precondition((channel == 0 ? actual.0 : actual.1) == expected)
    }
}
precondition(seamReader.decodedPageCount == 2, "fractional seam reuse must not seek back and restart the decoder")
print("FOLDER_INTERPOLATION_SEAM_TWO_SEQUENTIAL_READS_NO_BACKWARD_DECODE_OK")


let compactHeader = try Data(contentsOf: sumCacheURL)
precondition(compactHeader.prefix(4) == Data("JFS2".utf8))
precondition(compactHeader.count < 48_000, "16-second stereo+mono sum stores compact indexed peak pairs, not graphics vertices")
for gain in [6.0, -6.0] {
    let amplified = FolderWaveformCache.loadOrRender(.init(folder: UUID(), sources: [source(gain)], page: 0), key: "headroom-\(gain)")!
    let peak = amplified.channels[1].map { abs($0.y) }.max()!
    precondition(abs(peak - 3) < 0.0011, "RPKL encoding preserves sum amplitudes above unity, including inverted phase")
}

let plateauURL = directory.appendingPathComponent("plateau.wav")
let plateauBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
plateauBuffer.frameLength = 44_100
for i in 0..<44_100 {
    let value: Float = i < 192 ? (i % 2 == 0 ? -0.8 : 0.9) : (i < 20_000 ? 0.2 : 0)
    plateauBuffer.floatChannelData![0][i] = value
    plateauBuffer.floatChannelData![1][i] = -value
}
do { let file = try AVAudioFile(forWriting: plateauURL, settings: format.settings); try file.write(from: plateauBuffer) }
try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)], ofItemAtPath: plateauURL.path)
let plateauSource = FolderWaveformCache.Source(url: plateauURL, start: 0, duration: 1, offset: 0, rate: 1,
    loopStart: nil, loopLength: nil, gain: 1, pan: 0, fadeIn: 0, fadeOut: 0, fadeStart: 0, fadeDuration: 1, mode: 0)
let plateauRequest = FolderWaveformCache.Request(folder: UUID(), sources: [plateauSource], page: 0)
let originalPlateau = FolderWaveformCache.render(plateauRequest, key: "plateau-raw")!
_ = FolderWaveformCache.loadOrRender(plateauRequest, key: "plateau-compact")!
let plateauCache = FolderWaveformCache.diskCacheURL(plateauRequest)!
let compactBytes = try Data(contentsOf: plateauCache)
let fingerprint = String(data: compactBytes.subdata(in: 4..<68), encoding: .utf8)!
let legacy: [String: Any] = ["version": 1, "fingerprint": fingerprint,
    "channels": originalPlateau.channels.map { $0.withUnsafeBytes { Data($0) } }]
try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0).write(to: plateauCache)
let plateauBytes = try Data(contentsOf: plateauURL)
try Data(repeating: 0, count: plateauBytes.count).write(to: plateauURL)
try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)], ofItemAtPath: plateauURL.path)
let migratedPlateau = FolderWaveformCache.loadOrRender(plateauRequest, key: "plateau-migrated")!
let constant = migratedPlateau.channels[0].filter { $0.x > 512 && $0.x < 19_000 }
precondition(!constant.isEmpty && constant.allSatisfy { abs($0.y + 0.2) < 0.000021 },
    "migration must extend the last constant sample, not a preceding bucket's negative minimum")
precondition(migratedPlateau.channels[2].allSatisfy { $0.y == 0 }, "compact cache keeps signed mono cancellation")
precondition(migratedPlateau.channels[0].filter { $0.x > 21_000 }.allSatisfy { $0.y == 0 }, "migration preserves silence")
let migratedBytes = try Data(contentsOf: plateauCache)
precondition(migratedBytes.prefix(4) == Data("JFS2".utf8), "v1 migrates without decoding audio again")
print("FOLDER_COMPACT_PEAK_SIZE_HEADROOM_PHASE_AND_LOSSLESS_CACHE_MIGRATION_SOURCE_OK")

let tiny = FolderWaveformCache.Source(url: url, start: 1000 / 44_100, duration: 1 / 44_100,
    offset: 0, rate: 1, loopStart: nil, loopLength: nil, gain: 1, pan: 0,
    fadeIn: 0, fadeOut: 0, fadeStart: 1000 / 44_100, fadeDuration: 1 / 44_100, mode: 0)
let tinyPage = FolderWaveformCache.prepare(folder: UUID(), sources: [tiny], page: 0)
let tinyBlock = FolderWaveformCache.loadOrRender(tinyPage.request, key: "tiny")!
let pairs = stride(from: 0, to: tinyBlock.channels[0].count, by: 2).map { (tinyBlock.channels[0][$0], tinyBlock.channels[0][$0 + 1]) }
let covering = pairs.first { $0.0.x <= 1000 && $0.1.x >= 1001 }
precondition(tinyBlock.isPeakEnvelope && covering != nil && covering!.0.y == -0.25,
    "one-sample active item inside a bin retains its peak over the entire clipped item")
precondition(tinyPage.activeRanges.count == 1 && tinyPage.activeRanges[0].upperBound - tinyPage.activeRanges[0].lowerBound < 0.000023,
    "envelope coverage never enlarges the actual item clipping interval")

let validEdited = try Data(contentsOf: sumCacheURL)
let editedFingerprint = String(data: validEdited.subdata(in: 4..<68), encoding: .utf8)!
let malformed: [SIMD2<Float>] = [SIMD2(.nan, 0)]
let malformedData = malformed.withUnsafeBytes { Data($0) }
let invalidLegacy: [String: Any] = ["version": 1, "fingerprint": editedFingerprint,
    "channels": [malformedData, malformedData, malformedData]]
try PropertyListSerialization.data(fromPropertyList: invalidLegacy, format: .binary, options: 0).write(to: sumCacheURL)
let recoveredLegacy = FolderWaveformCache.loadOrRender(editedRequest, key: "malformed")!
precondition(recoveredLegacy.channels[0].allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
    abs(recoveredLegacy.channels[0].map { abs($0.y) }.max()! - 0.125) < 0.00001,
    "invalid legacy coordinates rebuild safely instead of trapping during migration")
print("FOLDER_SUB_BUCKET_ITEMS_REMAIN_VISIBLE_AND_INVALID_LEGACY_GEOMETRY_RECOVERS_OK")

let batchCache = FolderWaveformCache(), batchFolder = UUID()
let batchPresentation = FolderWaveformCache.Presentation()
func batchSources(_ gain: Double) -> [FolderWaveformCache.Source] {
    (0..<5).map { source(gain, start: Double($0) * FolderWaveformCache.pageSeconds) }
}
var batchPreloaded = false
Task { @MainActor in
    await batchCache.preload([(folder: batchFolder, sources: batchSources(1))])
    batchPreloaded = true
}
let batchPreloadDeadline = Date().addingTimeInterval(15)
while !batchPreloaded && Date() < batchPreloadDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
precondition(batchPreloaded)
func batchDrawing(_ sources: [FolderWaveformCache.Source], pages: ClosedRange<Int> = 0...4,
                  scale: Double = 1000) -> [FolderWaveformCache.PresentedPage] {
    batchCache.beginFrame(); defer { batchCache.endFrame() }
    let prepared = pages.map { FolderWaveformCache.prepare(folder: batchFolder, sources: sources, page: $0) }
    return batchCache.drawing(pages: prepared, pixelsPerSecond: scale, presentation: batchPresentation)
}
func peaks(_ pages: [FolderWaveformCache.PresentedPage]) -> [Double] {
    pages.map { Double($0.block.channels[0].map { abs($0.y) }.max() ?? 0) }
}
func allPeaks(_ values: [Double], equal expected: Double) -> Bool {
    !values.isEmpty && values.allSatisfy { abs($0 - expected) < 0.00002 }
}
precondition(allPeaks(peaks(batchDrawing(batchSources(1))), equal: 0.25))
var observedBatches: [[Double]] = []
let batchDeadline = Date().addingTimeInterval(15)
while Date() < batchDeadline {
    let values = peaks(batchDrawing(batchSources(0.25)))
    if observedBatches.last != values { observedBatches.append(values) }
    precondition(values.count == 5 && (allPeaks(values, equal: 0.25) || allPeaks(values, equal: 0.0625)),
                 "five-page gain change must never display mixed old/new pages or a hole: \(values)")
    if allPeaks(values, equal: 0.0625) { break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
precondition(observedBatches.count == 2 && allPeaks(observedBatches.last!, equal: 0.0625),
             "complete folder replacement must become visible in one swap")
print("FOLDER_FIVE_PAGE_GAIN_ATOMIC_SWAP_OK frames=\(observedBatches)")

// Two edits arrive before the first worker finishes. Old completions are cache
// entries only; they must never become the visible intermediate generation.
_ = batchDrawing(batchSources(0.5))
let latestDeadline = Date().addingTimeInterval(15)
var latestReady = false
while Date() < latestDeadline {
    let values = peaks(batchDrawing(batchSources(0.75)))
    precondition(values.count == 5 && (allPeaks(values, equal: 0.0625) || allPeaks(values, equal: 0.1875)),
                 "obsolete gain completions cannot replace the displayed folder")
    if allPeaks(values, equal: 0.1875) { latestReady = true; break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
precondition(latestReady)

// Reveal more preloaded pages and change zoom while the new gain is pending.
_ = batchDrawing(batchSources(0.6), pages: 0...1)
let panDeadline = Date().addingTimeInterval(15)
var panReady = false
while Date() < panDeadline {
    let value = batchDrawing(batchSources(0.6), pages: 1...4, scale: 64)
    let values = peaks(value)
    precondition(value.map(\.page) == [1, 2, 3, 4] && (allPeaks(values, equal: 0.1875) || allPeaks(values, equal: 0.15)),
                 "newly exposed pages retain complete previous sums during a gain edit")
    if allPeaks(values, equal: 0.15) { panReady = true; break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
precondition(panReady)
print("FOLDER_LATEST_GAIN_AND_VIEWPORT_CHANGE_RETAIN_COMPLETE_CURVE_OK")

// A muted first page disappears with the rest of the replacement, never early.
let partlyMuted = [source(0)] + (1..<5).map { source(0.125, start: Double($0) * 16) }
let muteDeadline = Date().addingTimeInterval(15)
var muteReady = false
while Date() < muteDeadline {
    let value = batchDrawing(partlyMuted, pages: 1...4)
    let values = peaks(value)
    precondition(allPeaks(values, equal: 0.15) || allPeaks(values, equal: 0.03125))
    if allPeaks(values, equal: 0.03125) { muteReady = true; break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
precondition(muteReady)
let muteFirst = [source(0, start: 16)] + (2..<5).map { source(0.375, start: Double($0) * 16) }
let rangeDeadline = Date().addingTimeInterval(15)
var rangesReady = false
while Date() < rangeDeadline {
    let value = batchDrawing(muteFirst, pages: 1...4)
    let values = peaks(value)
    if value.count == 3 {
        precondition(value.map(\.page) == [2, 3, 4] && allPeaks(values, equal: 0.09375))
        rangesReady = true; break
    }
    precondition(value.count == 4 && allPeaks(values, equal: 0.03125) && value.first?.activeRanges == [16.0...17.0],
                 "pending replacement keeps the old active ranges, including the page being muted")
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
precondition(rangesReady)
print("FOLDER_ACTIVE_RANGE_REMOVAL_COMMITS_WITH_COMPLETE_REPLACEMENT_OK")

// A decode/open failure must retain real prior samples rather than publish an
// all-zero replacement or repeatedly wake the UI to retry the same failure.
let unavailableURL = directory.appendingPathComponent("unavailable-until-restored.wav")
try FileManager.default.moveItem(at: url, to: unavailableURL)
let failureDeadline = Date().addingTimeInterval(0.4)
while Date() < failureDeadline {
    let values = peaks(batchDrawing(batchSources(0.9), pages: 2...4))
    precondition(values.count == 3 && allPeaks(values, equal: 0.09375), "failed gain recompute retains complete prior samples")
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
}
let failedRevision = batchCache.revision
for _ in 0..<20 {
    _ = batchDrawing(batchSources(0.9), pages: 2...4)
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
}
precondition(batchCache.revision == failedRevision, "failed visible generation must not spin in a retry/publication loop")
try FileManager.default.moveItem(at: unavailableURL, to: url)
let recoveredDeadline = Date().addingTimeInterval(15)
var recoveryReady = false
while Date() < recoveredDeadline {
    let values = peaks(batchDrawing(batchSources(0.8), pages: 2...4))
    precondition(allPeaks(values, equal: 0.09375) || allPeaks(values, equal: 0.2))
    if allPeaks(values, equal: 0.2) { recoveryReady = true; break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
precondition(recoveryReady)
print("FOLDER_FAILED_REPLACEMENT_RETAINS_PRIOR_CURVE_WITHOUT_RETRY_SPIN_OK")
