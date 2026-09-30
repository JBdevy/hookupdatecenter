import Foundation
import SwiftUI
import Darwin

setbuf(stdout, nil)
var samples = (0..<2048).map { Double(($0 * 37) % 101) / 100 }
private let original = TimelineWaveformGeometry.geometry(samples, step: 1, chunk: 0)
precondition(original === TimelineWaveformGeometry.geometry(samples, step: 1, chunk: 0), "repeated zooms reuse the same sample geometry")
let copy = samples
precondition(original === TimelineWaveformGeometry.geometry(copy, step: 1, chunk: 0), "duplicate items share waveform geometry")
samples[0] = 0.123
precondition(original !== TimelineWaveformGeometry.geometry(samples, step: 1, chunk: 0), "editing samples must not return stale geometry")
let left = Array(repeating: 0.1, count: 512), right = Array(repeating: 0.8, count: 512)
precondition(TimelineWaveformGeometry.geometry(left, step: 1, chunk: 0).path.boundingRect.height < TimelineWaveformGeometry.geometry(right, step: 1, chunk: 0).path.boundingRect.height, "stereo channels retain their independent amplitudes")
var transient = Array(repeating: 0.0, count: 512); transient[203] = 1
precondition(TimelineWaveformGeometry.geometry(transient, step: 64, chunk: 0).path.boundingRect.height == 2, "zooming out preserves short peaks")
var transformed = Path()
appendTimelineWaveform(transient, rect: CGRect(x: 20, y: 0, width: 600, height: 40), middle: 50, amplitude: 0.25, tile: CGRect(x: 0, y: 0, width: 800, height: 100), path: &transformed)
precondition(transformed.boundingRect.minY == 49.75 && transformed.boundingRect.maxY == 50.25, "gain and placement transform cached geometry without changing samples")
var empty = Path()
appendTimelineWaveform([], rect: .zero, middle: 0, amplitude: 1, tile: .zero, path: &empty)
precondition(empty.isEmpty)
print("WAVEFORM_CACHE_DUPLICATES_STEREO_COW_INVALIDATION_GAIN_TRANSFORMS_AND_PEAK_PRESERVATION_OK")

func originalWaveform(_ samples: [Double], rect: CGRect, tile: CGRect, path: inout Path) {
    let intervals = CGFloat(max(1, samples.count - 1))
    let first = max(0, min(samples.count - 1, Int(floor((tile.minX - rect.minX) / rect.width * intervals))))
    let last = max(first, min(samples.count - 1, Int(ceil((tile.maxX - rect.minX) / rect.width * intervals))))
    let step = max(1, Int(floor(CGFloat(samples.count) / max(1, rect.width))))
    for sample in stride(from: first, through: last, by: step) {
        let peak = samples[sample..<min(samples.count, sample + step)].max() ?? 0
        let x = rect.minX + CGFloat(sample) / intervals * rect.width
        path.move(to: CGPoint(x: x, y: 40 - peak * 20)); path.addLine(to: CGPoint(x: x, y: 40 + peak * 20))
    }
}
let tile = CGRect(x: 0, y: 0, width: 1400, height: 1000)
func measure(cached: Bool) -> Double {
    let start = ProcessInfo.processInfo.systemUptime
    var checksum: CGFloat = 0
    for frame in 0..<360 {
        let width = 1800 + CGFloat(frame % 60) * 8
        for channel in 0..<16 {
            let rect = CGRect(x: -CGFloat(channel % 3) * 90, y: 0, width: width, height: 60)
            var path = Path()
            if cached { appendTimelineWaveform(copy, rect: rect, middle: 40, amplitude: 20, tile: tile, path: &path) }
            else { originalWaveform(copy, rect: rect, tile: tile, path: &path) }
            checksum += path.boundingRect.height
        }
    }
    precondition(checksum > 0)
    return ProcessInfo.processInfo.systemUptime - start
}
_ = measure(cached: true)
let uncached = measure(cached: false), cached = measure(cached: true)
print(String(format: "WAVEFORM_ZOOM_CPU_BENCHMARK uncached=%.4fs cached=%.4fs speedup=%.2fx", uncached, cached, uncached / cached))
precondition(cached < uncached, "warm geometry reuse must cost less than rebuilding each peak path")
