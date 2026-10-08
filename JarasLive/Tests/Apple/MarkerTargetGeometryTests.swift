// Compare against the original full-measurement path, including exact flag
// constraints at viewport edges. No application project or window is opened.
private func originalTargets(_ markers: [TimelineMarker], scale: Double, viewport: CGRect,
                             facesLeft: Bool, ends: [UUID: Double], dragging: UUID?,
                             label: (TimelineMarker) -> String, measure: (String) -> Double) -> [(UUID, Double, Double)] {
    let measured = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, measure(label($0))) })
    let widths = TimelineMarker.flagWidths(markers, scale: scale, widths: measured, regionEnds: ends, facesLeft: facesLeft)
    return markers.compactMap { marker in
        let x = marker.position * scale, width = max(8, widths[marker.id] ?? 0)
        let left = facesLeft && marker.position > 0 ? max(0, x - width) : x
        guard marker.id == dragging || left + width >= viewport.minX && left <= viewport.maxX else { return nil }
        return (marker.id, left, width)
    }
}

private func verify(_ markers: [TimelineMarker], scale: Double, viewport: CGRect, facesLeft: Bool,
                    ends: [UUID: Double], dragging: UUID?, labels: MarkerTargetLabelWidths,
                    label: (TimelineMarker) -> String, measure: (String) -> Double) {
    let expected = originalTargets(markers, scale: scale, viewport: viewport, facesLeft: facesLeft,
        ends: ends, dragging: dragging, label: label, measure: measure)
    let actual = MarkerTargetGeometry.visible(markers, scale: scale, viewport: viewport, facesLeft: facesLeft,
        regionEnds: ends, draggingID: dragging, labels: labels, label: label)
    precondition(actual.map(\.id) == expected.map { $0.0 }, "visible markers and their original ordering must not change")
    for (value, old) in zip(actual, expected) {
        precondition(abs(value.left - old.1) < 1e-9 && abs(value.width - old.2) < 1e-9,
            "culling must preserve the original target position and width")
    }
}

let fontMeasure: (String) -> Double = {
    Double(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).width)
}
private let realLabels = MarkerTargetLabelWidths()
let names = ["", "I", "ENTRADA", "😀🎸", "-12st  REGIÃO", "120  4/4", String(repeating: "W", count: 300)]
for name in names {
    precondition(realLabels.width(name) == fontMeasure(name), "cached font metrics must match the existing native font exactly")
}

var markers = (0..<180).map { index in
    TimelineMarker(id: UUID(), name: names[index % names.count], position: Double((index / 3) * 11), color: 0)
}
// Shuffle storage order while retaining tied positions, both zero heads and a
// label long enough to reach a viewport from far outside its left edge.
markers = Array(markers[90...]) + Array(markers[..<90].reversed())
let ends = Dictionary(uniqueKeysWithValues: markers.enumerated().compactMap { index, marker in
    index % 4 == 0 ? (marker.id, marker.position + Double(index % 9)) : nil
})
let labels: (TimelineMarker) -> String = { $0.name }
var cases = 0
for facesLeft in [false, true] {
    for scale in [0.01, 0.25, 1, 5.2, 123.0] {
        for x in [-12.0, 0, 7.999, 8, 11, 90, 511, 1234, 4000, 90_000] {
            for width in [0.0, 13, 320, 1200] {
                for dragging in [nil, markers.first?.id] {
                    verify(markers, scale: scale, viewport: CGRect(x: x, y: 0, width: width, height: 16),
                        facesLeft: facesLeft, ends: ends, dragging: dragging, labels: realLabels,
                        label: labels, measure: fontMeasure)
                    cases += 1
                }
            }
        }
    }
}

var measurementCount = 0, labelCount = 0
private let countedLabels = MarkerTargetLabelWidths { text in
    measurementCount += 1
    return Double(text.count * 6)
}
let dense = (0..<2000).map { index in
    TimelineMarker(id: UUID(), name: "MARKER \(index)", position: Double(index * 100), color: 0)
}
let viewport = CGRect(x: 100_000, y: 0, width: 900, height: 16)
private func prepare(_ source: [TimelineMarker], scale: Double = 1, dragging: UUID? = nil) -> [MarkerTargetGeometry] {
    MarkerTargetGeometry.visible(source, scale: scale, viewport: viewport, facesLeft: false,
        regionEnds: [:], draggingID: dragging, labels: countedLabels) {
            labelCount += 1
            return $0.name
        }
}
private let first = prepare(dense)
precondition(!first.isEmpty && measurementCount <= 12 && labelCount <= 12,
    "offscreen markers must be culled before formatting or measuring their labels")
let warmCount = measurementCount
for _ in 0..<40 { _ = prepare(dense) }
precondition(measurementCount == warmCount, "repeated zoom/layout passes reuse the same native font metrics")
_ = prepare(dense, scale: 1.00001)
precondition(measurementCount <= warmCount + 1, "small zoom changes reuse labels and inspect only newly exposed neighbours")
var renamed = dense
renamed[1000].name = "RENAMED"
let beforeRename = measurementCount
_ = prepare(renamed)
precondition(measurementCount == beforeRename + 1, "editing marker text invalidates its width without retaining the previous label")
private let dragged = prepare(dense, dragging: dense.last!.id)
precondition(dragged.contains { $0.id == dense.last!.id }, "dragged targets stay mounted even far outside the viewport")
verify([], scale: 1, viewport: viewport, facesLeft: false, ends: [:], dragging: nil,
    labels: realLabels, label: labels, measure: fontMeasure)
print("MARKER_TARGET_CULLING_GEOMETRY_CACHE_AND_DRAG_OK cases=\(cases) initialMeasurements=\(warmCount)/2000")

// Compare the retained native lane against both unmodified reference paths.
// Medium raster widths and semibold hit widths deliberately differ, including
// at the 18-point flag threshold; neither may be substituted for the other.
import CoreText
private func mediumDrawingWidth(_ text: String) -> Double {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]))
    return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
}
private func verifyNativeLayout(_ source: [TimelineMarker], ends: [UUID: Double]) -> Int {
    let inputWidths = Dictionary(uniqueKeysWithValues: source.map { ($0.id, fontMeasure($0.name)) })
    let drawingWidths = Dictionary(uniqueKeysWithValues: source.map { ($0.id, mediumDrawingWidth($0.name)) })
    let retained = NativeTimelineMarkerLayout(source, drawingWidths: drawingWidths,
        inputWidths: inputWidths, regionEnds: ends)
    var checked = 0
    for scale in [0.01, 0.125, 0.99999, 1.0, 1.00001, 5.2, 10.23, 123.0, 1280.0, 81920.0] {
        for x in [-12.0, 0, 7.999, 8, 11, 90, 511, 1234, 4000, 90_000] {
            for width in [0.0, 13, 320, 1200] {
                for dragging in [nil, source.last?.id] {
                    let viewport = CGRect(x: x, y: 0, width: width, height: 16)
                    let expectedDrawing = TimelineMarker.flagWidths(source, scale: scale,
                        widths: drawingWidths, regionEnds: ends)
                    let expectedTargets = MarkerTargetGeometry.visible(source, scale: scale,
                        viewport: viewport, facesLeft: false, regionEnds: ends,
                        draggingID: dragging, labels: realLabels, label: { $0.name })
                    var actualTargets: [MarkerTargetGeometry] = [], visited: [UUID] = []
                    retained.forEachProjection(scale: scale, viewport: viewport, draggingID: dragging) { marker, projectedX, drawingWidth, target in
                        visited.append(marker.id)
                        precondition(projectedX == marker.position * scale,
                            "cached layout preserves exact floating-point positions")
                        precondition(drawingWidth == (expectedDrawing[marker.id] ?? 0),
                            "native flag width must match the original raster-font constraints exactly")
                        if let target { actualTargets.append(target) }
                    }
                    precondition(visited == source.map(\.id), "storage and overlap precedence must remain unchanged")
                    precondition(actualTargets.map(\.id) == expectedTargets.map(\.id),
                        "cached native targets preserve culling, dragged items and tied-marker order")
                    for (actual, expected) in zip(actualTargets, expectedTargets) {
                        precondition(actual.left == expected.left && actual.width == expected.width,
                            "cached native target frames match the original semibold measurements exactly")
                    }
                    checked += 1
                }
            }
        }
    }
    return checked
}
var nativeCases = verifyNativeLayout(markers, ends: ends)
var editedMarkers = markers
editedMarkers[0].name = "日本語 Árvores 👩🏽‍🚀 e\u{301} \u{1F1E7}\u{1F1F7}"
editedMarkers[1].position = 0
editedMarkers[2].position += 0.003
editedMarkers[3].unifiedRegionID = UUID()
editedMarkers[4].sourceRegionID = UUID()
var editedEnds = ends
editedEnds[editedMarkers[3].id] = editedMarkers[3].position + 0.1
editedEnds[editedMarkers[4].id] = editedMarkers[4].position
nativeCases += verifyNativeLayout(Array(editedMarkers.reversed()), ends: editedEnds)
nativeCases += verifyNativeLayout([], ends: [:])
print("NATIVE_MARKER_RETAINED_LAYOUT_EXACT_GEOMETRY_AND_METRICS_OK cases=\(nativeCases)")
