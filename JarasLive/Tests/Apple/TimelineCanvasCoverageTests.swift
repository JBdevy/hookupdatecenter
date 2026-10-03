import Foundation
import CoreGraphics

let document = CGSize(width: 4000, height: 5300)
var checked = 0
for height: CGFloat in [256, 360, 512, 720, 768, 1024, 1500] {
    let maximum = document.height - height
    for anchor in stride(from: CGFloat.zero, through: maximum, by: 512) {
        let published = CGRect(x: 0, y: anchor, width: 1100, height: height)
        let prepared = TimelineCanvasCoverage.preparedRect(visibleRect: published, documentSize: document)
        for phase in 0..<512 {
            let position = min(maximum, anchor + CGFloat(phase))
            let actual = CGRect(x: 0, y: position, width: 1100, height: height)
            precondition(prepared.contains(actual), "native viewport must remain covered between 512-point publications: height=\(height), phase=\(phase)")
            checked += 1
        }
        // A bounded extra band protects both directions while SwiftUI commits
        // the next native scroll notification, without a document-sized layer.
        for delta: CGFloat in [-256, 511 + 256] {
            let position = min(maximum, max(0, anchor + delta))
            precondition(prepared.contains(CGRect(x: 0, y: position, width: 1100, height: height)))
        }
        precondition(prepared.minY >= 0 && prepared.maxY <= document.height)
        precondition(prepared.height <= height + 512 + 3 * 256, "lookahead remains bounded independently of project length")
    }
    // Large jumps and immediate direction reversals must prepare the correct
    // new bands, including a clipped last viewport at the document end.
    for position in [maximum, CGFloat(511), CGFloat(2049), CGFloat.zero, maximum - 1, CGFloat(1535)] {
        let y = min(maximum, max(0, position)), anchor = floor(y / 512) * 512
        let actual = CGRect(x: 0, y: y, width: 1100, height: height)
        let prepared = TimelineCanvasCoverage.preparedRect(visibleRect: CGRect(x: 0, y: anchor, width: 1100, height: height), documentSize: document)
        precondition(prepared.contains(actual))
    }
}
print("TIMELINE_VERTICAL_SUBBUCKET_COVERAGE_OK positions=\(checked)")
print("TIMELINE_VERTICAL_FAST_SCROLL_REVERSE_AND_DOCUMENT_END_COVERAGE_OK")

for width: CGFloat in [256, 512, 840, 1024, 1600] {
    let maximum = document.width - width
    for anchor in stride(from: CGFloat.zero, through: maximum, by: 512) {
        let prepared = TimelineCanvasCoverage.preparedRect(visibleRect: CGRect(x: anchor, y: 0, width: width, height: 600), documentSize: document)
        for phase in -512..<512 {
            let x = min(maximum, max(0, anchor + CGFloat(phase)))
            precondition(prepared.contains(CGRect(x: x, y: 0, width: width, height: 600)), "horizontal reserve must cover unpublished travel and immediate reversal")
        }
        precondition(prepared.width <= width + 4 * 512, "horizontal coverage must remain independent of project length")
    }
}
print("TIMELINE_HORIZONTAL_SUBBUCKET_AND_REVERSE_COVERAGE_BOUNDED_OK")
