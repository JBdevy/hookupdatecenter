// Compiled with the production ruler model and native cached text renderer.
_ = NSApplication.shared
let end = 1_000_000_000.0
let steady = [TimelineTempoSection(start: 0, end: end, bpm: 123, beats: 7, unit: 8, timebase: .free)]
var dense = (0..<160).map { index in
    TimelineTempoSection(start: Double(index) * 0.15, end: Double(index + 1) * 0.15,
        bpm: [60.0, 90, 123, 299][index % 4], beats: index % 7 + 1, unit: [4, 8, 16][index % 3], timebase: .free)
}
dense.append(TimelineTempoSection(start: 24, end: end, bpm: 120, beats: 4, unit: 4, timebase: .free))
let scales = [0.01, 0.02, 0.05, 0.1, 0.5, 1, 8, 40, 100, 1000, 81920.0]
    + (0...90).map { 0.01 * pow(81920 / 0.01, Double($0) / 90) }
let origins: [Double] = [0, 9 * 3600, 99 * 3600, 99_999 * 3600]
var checked = 0
var labelCount = 0
for backingScale in [1.0, 2.0, 3.0] {
    let sample = TimelineTimeRuler.labelSample(through: end)
    precondition(sample.hasPrefix("277777:"), "large hours remain complete")
    let measuredWidth = Double(TimelineStaticText.label(sample, style: .barNumber, displayScale: backingScale)!.size.width)
    for sections in [steady, dense] {
        for scale in scales {
            let spacing = TimelineTimeRuler.labelSpacing(through: end, measuredWidth: measuredWidth, pixelsPerSecond: scale)
            precondition(TimelineTimeRuler.labelSpacing(through: end, pixelsPerSecond: scale) >= spacing, "font-free estimate covers the real font")
            for origin in origins {
                let limit = origin + 2400 / scale
                let marks = TimelineTimeRuler.ticks(in: sections, from: origin, to: limit,
                    pixelsPerSecond: scale, divisions: 8, minimumLabelSpacing: spacing)
                let grid = TimelineTimeRuler.ticks(in: sections, from: origin, to: limit,
                    pixelsPerSecond: scale, divisions: 8, labels: false)
                precondition(marks.map(\.time) == grid.map(\.time), "adaptive text cannot remove or move grid ticks")
                precondition(marks.map(\.primary) == grid.map(\.primary), "primary/secondary line weights remain unchanged")
                var previousRight = -Double.infinity
                var previousTime = -Double.infinity
                for tick in marks where !tick.label.isEmpty {
                    let text = TimelineStaticText.label(tick.label, style: .barNumber, displayScale: backingScale)!
                    let left = floor(tick.time * scale * backingScale) / backingScale + 0.5 / backingScale + 2
                    precondition(left - previousRight >= TimelineTimeRuler.labelGap - 1.01,
                        "rendered text overlaps at scale \(scale), time \(tick.time), label \(tick.label)")
                    previousRight = left + Double(text.size.width)
                    precondition((tick.time - previousTime) * scale >= spacing - 1e-5,
                        "tempo changes share one global label spacing rather than restarting a label at each region")
                    previousTime = tick.time
                    labelCount += 1
                }
                for fraction in [0.013, 0.37, 0.79] {
                    let a = origin + (limit - origin) * fraction
                    let b = origin + (limit - origin) * min(1, fraction + 0.2)
                    let tile = TimelineTimeRuler.ticks(in: sections, from: a, to: b,
                        pixelsPerSecond: scale, divisions: 8, minimumLabelSpacing: spacing)
                    let expected = marks.filter { $0.time >= a && $0.time <= b }
                    precondition(tile.map(\.time) == expected.map(\.time), "scrolling preserves tick positions")
                    precondition(tile.map(\.label) == expected.map(\.label), "tile boundaries cannot change which labels are visible")
                }
                checked += 1
            }
        }
    }
}
let tiny = TimelineTimeRuler.ticks(in: dense, from: 0, to: 24, pixelsPerSecond: 0.01)
precondition(tiny.filter { !$0.label.isEmpty }.count == 1, "nearby section starts share the same collision rule")
precondition(tiny.count >= 160, "dense tempo changes retain their grid lines")
let simple = [TimelineTempoSection(start: 0, end: 1000, bpm: 120, beats: 4, unit: 4, timebase: .free)]
var previousInterval = 0.0
for scale in [100.0, 40, 8, 1, 0.5, 0.1] {
    let labels = TimelineTimeRuler.ticks(in: simple, from: 0, to: 999, pixelsPerSecond: scale).filter { !$0.label.isEmpty }
    if labels.count >= 2 {
        let interval = labels[1].time - labels[0].time
        precondition(interval >= previousInterval, "zooming out progressively increases the label interval")
        previousInterval = interval
    }
}
precondition(labelCount > 10_000, "exercise actual native glyph bounds rather than empty viewports")
print("TIMELINE_RULER_NATIVE_WIDTH_NO_OVERLAP_TILES_AND_GRID_OK cases=\(checked) labels=\(labelCount)")

let farEnd = 60 * 3600.0
let clustered = (0..<480).map { index in
    let start = Double(index) * 450.0
    return TimelineTempoSection(start: start, end: start + 450,
        bpm: [63.0, 87.3, 123, 178.6][index % 4], beats: [3, 4, 7][index % 3], unit: [4, 8][index % 2], timebase: .free)
}
let farSample = TimelineTimeRuler.labelSample(through: farEnd)
let farWidth = Double(TimelineStaticText.label(farSample, style: .barNumber, displayScale: 2)!.size.width)
var previousSpacing = 0.0
for zoom in [0.08, 0.03, 0.01, 0.003, 0.001] {
    let scale = zoom * 10
    let spacing = TimelineTimeRuler.labelSpacing(through: farEnd, measuredWidth: farWidth, pixelsPerSecond: scale)
    precondition(spacing >= 130 && spacing <= 180 && spacing >= previousSpacing,
                 "farther zoom progressively opens the space between time labels")
    previousSpacing = spacing
    let from = -500.0, to = min(farEnd, 1046 / scale)
    let marks = TimelineTimeRuler.ticks(in: clustered, from: from, to: to, pixelsPerSecond: scale,
                                      minimumLabelSpacing: spacing)
    let labels = marks.filter { !$0.label.isEmpty }
    precondition(labels.first?.time == 0 && labels.first?.label == "00:00:00",
                 "zero remains the first reference even when the covered viewport starts negative")
    precondition(marks.allSatisfy { $0.time.isFinite && $0.time >= 0 && $0.time <= to })
    precondition(labels.count <= Int(floor(1046 / spacing)) + 1,
                 "many regions cannot fill a distant viewport with time labels")
    let lessSpace = TimelineTimeRuler.ticks(in: clustered, from: from, to: to, pixelsPerSecond: scale,
                                           minimumLabelSpacing: max(72, ceil(farWidth) + TimelineTimeRuler.labelGap))
    precondition(labels.count <= lessSpace.filter { !$0.label.isEmpty }.count,
                 "increased spacing must not create more labels across tempo regions")
    for pair in zip(labels, labels.dropFirst()) {
        let text = TimelineStaticText.label(pair.0.label, style: .barNumber, displayScale: 2)!
        precondition((pair.1.time - pair.0.time) * scale >= max(spacing, Double(text.size.width) + TimelineTimeRuler.labelGap) - 1e-6)
    }
    let tileStart = max(0, to * 0.45 - spacing / scale), tileEnd = to * 0.93
    let tile = TimelineTimeRuler.ticks(in: clustered, from: tileStart, to: tileEnd, pixelsPerSecond: scale,
                                     minimumLabelSpacing: spacing)
    precondition(tile.map(\.label) == marks.filter { $0.time >= tileStart && $0.time <= tileEnd }.map(\.label),
                 "clipping and overscan must not reset global density or introduce negative-time labels")
    print("TIMELINE_RULER_FAR_ZOOM zoom=\(zoom) spacing=\(spacing) labels=\(labels.count)")
}
precondition(TimelineTimeRuler.labelSpacing(through: farEnd, measuredWidth: 250, pixelsPerSecond: 0.01) >= 250 + TimelineTimeRuler.labelGap,
             "unusually wide hour labels override the normal density range without clipping")
print("TIMELINE_RULER_FAR_DENSITY_GLOBAL_REGIONS_ZERO_HOURS_AND_CLIPPING_OK")
