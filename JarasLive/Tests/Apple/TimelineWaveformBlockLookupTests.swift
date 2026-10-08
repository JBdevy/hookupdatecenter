import Foundation

setbuf(stdout, nil)
typealias Block = TimelineAudioWaveform.VertexBlock

for sampleRate in [44_100.0, 48_000, 96_000] {
    precondition(TimelineWaveformStrokeStyle.lineWidth(sampleRate: sampleRate, pixelsPerSecond: sampleRate / 512) == 2)
    precondition(TimelineWaveformStrokeStyle.lineWidth(sampleRate: sampleRate, pixelsPerSecond: sampleRate) == 1)
    var previous = 2.0
    for index in 0...1000 {
        let scale = sampleRate / 1024 * pow(2, Double(index) / 100)
        let width = TimelineWaveformStrokeStyle.lineWidth(sampleRate: sampleRate, pixelsPerSecond: scale)
        precondition(width >= 1 && width <= previous && previous - width < 0.01,
                     "zoom stroke width must become thin continuously without detail-level jumps")
        previous = width
    }
}
for invalid in [0.0, -1, Double.nan, Double.infinity] {
    precondition(TimelineWaveformStrokeStyle.lineWidth(sampleRate: 48_000, pixelsPerSecond: invalid) == 2)
}
print("WAVEFORM_SAMPLE_CONTOUR_WIDTH_SMOOTH_MONOTONIC_RATE_INDEPENDENT_AND_BOUNDED_OK")

let expectedSteps = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 80, 96, 128, 192]
precondition(TimelineAudioWaveform.detailSteps == expectedSteps)
for rate in [44_100.0, 48_000, 96_000] {
    for (index, step) in expectedSteps.enumerated() {
        let next = index + 1 < expectedSteps.count ? expectedSteps[index + 1] : 256
        for framesPerPoint in [Double(step), Double(step) + 0.01, Double(next) - 0.01] {
            precondition(TimelineAudioWaveform.step(rate: rate, pixelsPerSecond: rate / (framesPerPoint * 2)) == step,
                         "all 16 true PCM intervals must be reachable and stable throughout their zoom band")
        }
    }
    for step in [256, 512, 1024, 65536] {
        precondition(TimelineAudioWaveform.step(rate: rate, pixelsPerSecond: rate / Double(step * 2)) == step,
                     "the compact overview keeps its existing dyadic selector")
    }
}
print("WAVEFORM_16_DETAIL_LEVEL_BOUNDARIES_AND_UNCHANGED_OVERVIEW_SELECTOR_OK")

func block(_ start: Int64, _ end: Int64) -> Block {
    Block(channels: [], start: start, end: end, step: 256, rate: 48_000, key: "\(start):\(end)")
}

func reference(_ blocks: [Block], _ first: Double, _ last: Double, inclusive: Bool) -> [Block] {
    blocks.filter {
        inclusive ? Double($0.end) >= first && Double($0.start) <= last
            : Double($0.end) > first && Double($0.start) < last
    }
}

func check(_ blocks: [Block], _ first: Double, _ last: Double) {
    for inclusive in [false, true] {
        let expected = reference(blocks, first, last, inclusive: inclusive)
        let actual = TimelineAudioWaveform.visibleVertexBlocks(blocks, from: first, to: last,
                                                               includingBoundaryBlocks: inclusive)
        precondition(actual.count == expected.count && zip(actual, expected).allSatisfy { $0 === $1 },
                     "source overlap and immutable block identity must match at \(first)...\(last), inclusive=\(inclusive)")
    }
}

let irregular = [block(0, 512), block(512, 1024), block(1536, 1667), block(2000, 4096), block(4096, 4101)]
for first in [-100.0, -0.25, 0, 0.25, 511.75, 512, 512.25, 1024, 1024.25, 1535.75, 1536, 1667, 2000, 4096, 4101, 8192] {
    for width in [0.0, 0.25, 1, 512, 4096, 16_384] {
        check(irregular, first, first + width)
        check([], first, first + width)
        check([irregular[2]], first, first + width)
    }
}
precondition(TimelineAudioWaveform.visibleVertexBlocks(irregular, from: 1024, to: 1536).isEmpty,
             "a missing source interval must not manufacture neighboring coverage")
let touching = TimelineAudioWaveform.visibleVertexBlocks(irregular, from: 1024, to: 1536, includingBoundaryBlocks: true)
precondition(touching.count == 2 && touching[0] === irregular[1] && touching[1] === irregular[2],
             "fallback lookup retains both endpoint neighbors exactly as before")
print("WAVEFORM_BLOCK_LOOKUP_EMPTY_SHORT_GAPS_AND_EXACT_FRACTIONAL_BOUNDARIES_OK")

var randomState: UInt64 = 0xC47_11FE
func random(_ limit: UInt64) -> Int64 {
    randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
    return Int64((randomState >> 16) % limit)
}
var mixed: [Block] = [], end: Int64 = 0
for _ in 0..<1000 {
    let start = end + random(37)
    end = start + 1 + random(1024)
    mixed.append(block(start, end))
}
for _ in 0..<3000 {
    let first = Double(random(UInt64(end + 2048)) - 1024) + Double(random(4)) / 4
    check(mixed, first, first + Double(random(8192)) + Double(random(4)) / 4)
}
let distant: Int64 = 1 << 54
check([block(distant, distant + 1024), block(distant + 2048, distant + 3072)], Double(distant + 512), Double(distant + 2048))
print("WAVEFORM_BLOCK_LOOKUP_VARIABLE_SPANS_RANDOM_WINDOWS_AND_DISTANT_COORDINATES_OK")

weak var unselected: Block?
var retained: [Block] = []
func retainVisibleOnly() {
    let source = [block(0, 512), block(512, 1024), block(1024, 1536)]
    unselected = source[0]
    retained = TimelineAudioWaveform.visibleVertexBlocks(source, from: 600, to: 900)
}
retainVisibleOnly()
precondition(unselected == nil && retained.count == 1 && retained[0].start == 512,
             "a visible result must not extend ownership of unselected source blocks")
print("WAVEFORM_BLOCK_LOOKUP_RETAINS_ONLY_SELECTED_SOURCE_OBJECTS_OK")

@inline(never)
func benchmark(_ blocks: [Block], indexed: Bool, iterations: Int) -> (milliseconds: Double, checksum: Int64) {
    let began = ProcessInfo.processInfo.systemUptime
    var checksum: Int64 = 0
    for index in 0..<iterations {
        let first = Double((index * 131 % (blocks.count - 24)) * 32768) + 0.25
        let last = first + 16 * 32768
        let result = indexed ? TimelineAudioWaveform.visibleVertexBlocks(blocks, from: first, to: last)
            : reference(blocks, first, last, inclusive: false)
        checksum &+= result.first?.start ?? 0
        checksum &+= Int64(result.count)
    }
    return ((ProcessInfo.processInfo.systemUptime - began) * 1000, checksum)
}

for count in ProcessInfo.processInfo.environment["JARAS_SKIP_BENCHMARKS"] == "1" ? [] : [2048, 131_072] {
    let blocks = (0..<count).map { block(Int64($0) * 32768, Int64($0 + 1) * 32768) }
    var indexedTimes: [Double] = [], filteredTimes: [Double] = []
    for _ in 0..<3 {
        let indexed = benchmark(blocks, indexed: true, iterations: 600)
        let filtered = benchmark(blocks, indexed: false, iterations: 600)
        precondition(indexed.checksum == filtered.checksum)
        indexedTimes.append(indexed.milliseconds); filteredTimes.append(filtered.milliseconds)
    }
    let indexed = indexedTimes.sorted()[1], filtered = filteredTimes.sorted()[1]
    print(String(format: "WAVEFORM_BLOCK_LOOKUP_BENCHMARK blocks=%d queries=600 indexed_ms=%.3f full_filter_ms=%.3f speedup=%.1fx", count, indexed, filtered, filtered / max(0.000001, indexed)))
}
