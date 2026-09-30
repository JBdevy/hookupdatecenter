import AppKit

@MainActor func verifySharedScale() {
    for width: CGFloat in [800.125, 1700.375, 950.625, 3600.875, 801.25, 1200.125] {
        let fraction: CGFloat = 0.173
        func layer(_ layoutWidth: CGFloat) -> some View {
            ViewportTimelineCanvas(visibleRect: CGRect(x: 0, y: 0, width: 700, height: 24), synchronized: true, documentWidth: width, identity: TimelineTileIdentity()) { context, size, _ in
                context.fill(Path(CGRect(x: size.width * fraction, y: 0, width: 3, height: 24)), with: .color(.white))
            }.frame(width: layoutWidth, height: 24).frame(width: 700, height: 24, alignment: .leading).clipped()
        }
        // The two native hosts can report intermediate/rounded widths in the
        // same update. Both must draw the model's exact scale, not those widths.
        let content = VStack(spacing: 0) { layer(width.rounded(.down)); layer(width * 0.87) }
            .frame(width: 700, height: 48).background(Color.black)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
        func extent(_ y: Int) -> ClosedRange<Int> {
            let lit = (0..<bitmap.pixelsWide).filter { bitmap.colorAt(x: $0, y: y)!.usingColorSpace(.deviceRGB)!.redComponent > 0.5 }
            precondition(!lit.isEmpty, "neither surface can become blank during a fast scale change")
            return lit.first!...lit.last!
        }
        let top = extent(12), bottom = extent(60)
        if CommandLine.arguments.contains("legacy"), top != bottom {
            print("LEGACY_INTERMEDIATE_WIDTH_REPRODUCED_PIXEL_MISMATCH top=\(top) bottom=\(bottom)")
            return
        }
        precondition(top == bottom, "regions and waveform surfaces must share the same pixel position even with stale host geometry")
        precondition(abs(CGFloat(top.lowerBound) / 2 - width * fraction) <= 0.5, "both surfaces must use the current logical zoom")
    }
    precondition(!CommandLine.arguments.contains("legacy"), "negative control must reproduce the old mismatch")
    print("ZOOM_SHARED_SCALE_INTERMEDIATE_HOST_WIDTHS_NO_DRIFT_OR_BLANK_OK")
}
MainActor.assumeIsolated { verifySharedScale() }
