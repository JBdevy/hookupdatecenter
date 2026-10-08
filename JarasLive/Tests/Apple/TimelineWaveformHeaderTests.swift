import Foundation
import AVFoundation

// The harness instruments only the production header() normalization call.
// Cache, refresh, worker scheduling and file decoding stay unchanged.
enum WaveformHeaderNormalizationProbe {
    static var calls = 0
    static var pathCalls = 0
    static func path(_ url: URL) -> String {
        pathCalls += 1
        return url.path
    }
    static func normalize(_ url: URL) -> URL {
        calls += 1
        return url.standardizedFileURL
    }
}

setbuf(stdout, nil)
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("catlive-waveform-header-\(UUID())", isDirectory: true).standardizedFileURL
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let child = temporary.appendingPathComponent("child", isDirectory: true)
try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
let url = temporary.appendingPathComponent("source.wav").standardizedFileURL
let alias = child.appendingPathComponent("../source.wav")
precondition(alias.path != url.path && alias.standardizedFileURL == url,
             "The alias test must actually enter the existing normalization path")
let worker = DispatchQueue(label: "catlive.header.tests")
let cache = TimelineAudioWaveform(worker: worker)
func writeAudio(_ destination: URL, frames: UInt32) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
        for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = Float(channel + 1) * 0.125 }
    }
    let file = try AVAudioFile(forWriting: destination, settings: format.settings)
    try file.write(from: buffer)
}
try writeAudio(url, frames: 1024)
precondition(cache.header(url) == nil, "Cold reads remain asynchronous")
worker.sync {}
let original = cache.header(url)!
precondition(original.frames == 1024 && original.rate == 48_000 && original.channels == 2)
let warmed = WaveformHeaderNormalizationProbe.calls
for _ in 0..<10_000 {
    precondition(cache.header(url) === original)
}
precondition(WaveformHeaderNormalizationProbe.calls == warmed,
             "A warm canonical header must perform zero path normalizations")
precondition(cache.header(url, refresh: true) === original)
precondition(WaveformHeaderNormalizationProbe.calls == warmed,
             "Live refresh within one second must reuse the same fast lookup")
precondition(cache.header(alias) === original && WaveformHeaderNormalizationProbe.calls == warmed + 1,
             "Aliases preserve existing normalization and resolve to the canonical header")
let aliasWarmed = WaveformHeaderNormalizationProbe.calls
for _ in 0..<10_000 { precondition(cache.header(alias) === original) }
precondition(cache.header(alias, refresh: true) === original && WaveformHeaderNormalizationProbe.calls == aliasWarmed,
             "Repeated alias hits and a fresh live refresh must not repeat normalization")
let systemTemporary = FileManager.default.temporaryDirectory
print("WAVEFORM_HEADER_TEMPORARY_PATH_ALIAS=\(systemTemporary.path != systemTemporary.standardizedFileURL.path)")
print("WAVEFORM_HEADER_WARM_CANONICAL_AND_ALIAS_10000_ZERO_NORMALIZATIONS_OK")

let sourcePath = url.path, aliasPath = alias.path
let pathCalls = WaveformHeaderNormalizationProbe.pathCalls
for _ in 0..<10_000 {
    precondition(cache.header(url, sourcePath: sourcePath) === original)
    precondition(cache.header(alias, sourcePath: aliasPath) === original)
}
precondition(WaveformHeaderNormalizationProbe.pathCalls == pathCalls &&
             WaveformHeaderNormalizationProbe.calls == aliasWarmed,
             "Media URL cache paths bypass repeated URL decoding without changing alias lookup")
print("WAVEFORM_HEADER_CACHED_CANONICAL_AND_ALIAS_PATHS_ZERO_URL_DECODES_OK")

// The pinned project cache must still serve a canonical header after NSCache
// evicts it. The harness exposes this private cache transition only in its copy.
cache.installPinnedHeaderForTesting(original, path: url.path)
let pinned = WaveformHeaderNormalizationProbe.calls
precondition(cache.header(url) === original)
precondition(cache.header(alias) === original)
precondition(WaveformHeaderNormalizationProbe.calls == pinned,
             "Pinned canonical and alias headers bypass normalization after NSCache eviction")
print("WAVEFORM_HEADER_PINNED_PROJECT_CACHE_ZERO_NORMALIZATIONS_OK")

let missing = temporary.appendingPathComponent("missing.wav").standardizedFileURL
let missingAlias = child.appendingPathComponent("../missing.wav")
precondition(cache.header(missing) == nil)
worker.sync {}
let negative = WaveformHeaderNormalizationProbe.calls
for _ in 0..<1000 { precondition(cache.header(missing) == nil) }
precondition(WaveformHeaderNormalizationProbe.calls == negative,
             "A cached missing file must not normalize or enqueue another read")
precondition(cache.header(missingAlias) == nil && WaveformHeaderNormalizationProbe.calls == negative + 1)
let missingAliasWarmed = WaveformHeaderNormalizationProbe.calls
for _ in 0..<1000 { precondition(cache.header(missingAlias) == nil) }
precondition(WaveformHeaderNormalizationProbe.calls == missingAliasWarmed,
             "Negative alias hits must reuse canonical cache state without normalization")
try writeAudio(missing, frames: 512)
let newlyCreated = WaveformHeaderNormalizationProbe.calls
precondition(cache.header(missing) == nil && cache.header(missing, refresh: true) == nil,
             "Creating a file preserves the existing negative cache during its one-second interval")
worker.sync {}
precondition(WaveformHeaderNormalizationProbe.calls == newlyCreated)

// Age both positive and negative cache entries, then verify refresh reopens
// files while returning the prior positive header until the worker completes.
Thread.sleep(forTimeInterval: 1.05)
try writeAudio(url, frames: 2048)
let aged = WaveformHeaderNormalizationProbe.calls
precondition(cache.header(url) === original && cache.header(missing) == nil,
             "Non-refresh reads preserve cached values even after one second")
precondition(WaveformHeaderNormalizationProbe.calls == aged)
precondition(cache.header(url, refresh: true) === original)
precondition(cache.header(missing, refresh: true) == nil)
precondition(WaveformHeaderNormalizationProbe.calls == aged + 2,
             "Aged refreshes must use the original canonical/file refresh path")
worker.sync {}
let updated = cache.header(url)!, discovered = cache.header(missing)!
precondition(updated !== original && updated.frames == 2048 && updated.channels == 2)
precondition(discovered.frames == 512)
let refreshed = WaveformHeaderNormalizationProbe.calls
precondition(cache.header(url, refresh: true) === updated && cache.header(missing, refresh: true) === discovered)
precondition(WaveformHeaderNormalizationProbe.calls == refreshed)
precondition(cache.header(alias) === updated && cache.header(missingAlias) === discovered)
print("WAVEFORM_HEADER_REFRESH_REOPENS_CHANGED_AND_PREVIOUSLY_MISSING_FILES_OK")

try FileManager.default.removeItem(at: missing)
precondition(cache.header(missing) === discovered, "Deleting a file preserves its cached header until refresh")
Thread.sleep(forTimeInterval: 1.05)
precondition(cache.header(missing, refresh: true) === discovered)
worker.sync {}
let removed = WaveformHeaderNormalizationProbe.calls
precondition(cache.header(missing) == nil && cache.header(missing, refresh: true) == nil)
precondition(WaveformHeaderNormalizationProbe.calls == removed,
             "Deletion refresh must install a fresh negative cache, not return a pinned/stale header")
print("WAVEFORM_HEADER_DELETION_REFRESH_NEGATIVE_CACHE_OK")

// Exercise refresh through the alias itself, not only through a canonical URL.
Thread.sleep(forTimeInterval: 1.05)
try writeAudio(url, frames: 4096)
let aliasAged = WaveformHeaderNormalizationProbe.calls
precondition(cache.header(alias) === updated)
precondition(cache.header(alias, refresh: true, sourcePath: aliasPath) === updated)
precondition(WaveformHeaderNormalizationProbe.calls == aliasAged + 1,
             "Aged alias refresh re-resolves the original path and checks its current file")
worker.sync {}
let aliasUpdated = cache.header(alias)!
precondition(aliasUpdated.frames == 4096 && cache.header(url) === aliasUpdated,
             "Alias and canonical lookups must share the refreshed header, never stale alias copies")
print("WAVEFORM_HEADER_ALIAS_REFRESH_SHARED_CANONICAL_STATE_OK")

// A symbolic directory can point somewhere else between explicit refreshes.
// Keep Foundation's normalization semantics, including platforms that retain
// this symlink in the standardized URL instead of resolving it.
let destination = temporary.appendingPathComponent("replacement", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try writeAudio(destination.appendingPathComponent("source.wav"), frames: 3072)
let link = temporary.appendingPathComponent("link", isDirectory: true)
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temporary)
let linked = link.appendingPathComponent("child/../source.wav")
_ = cache.header(linked)
worker.sync {}
precondition(cache.header(linked)?.frames == 4096)
try FileManager.default.removeItem(at: link)
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
Thread.sleep(forTimeInterval: 1.05)
let retarget = WaveformHeaderNormalizationProbe.calls
_ = cache.header(linked, refresh: true, sourcePath: linked.path)
worker.sync {}
precondition(cache.header(linked)?.frames == 3072,
             "Refreshing a redirected alias must use its new target")
precondition(WaveformHeaderNormalizationProbe.calls == retarget + 1,
             "Alias redirect validation normalizes once during refresh, not on later reads")
print("WAVEFORM_HEADER_ALIAS_RETARGET_REFRESH_OK")
