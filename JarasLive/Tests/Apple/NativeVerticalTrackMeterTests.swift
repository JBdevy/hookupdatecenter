import Foundation

@MainActor func run() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 80, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 80, height: 100))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 10_000))
    scroll.documentView = document; window.contentView = scroll
    let level = TrackMeterLevel(), meter = NativeVerticalTrackMeterView(frame: NSRect(x: 5, y: 0, width: 32, height: 80))
    meter.bind(level, showScale: true); document.addSubview(meter)
    window.orderFront(nil)
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meter.visibleRect.height == 80, "meter fixture must intersect the native viewport")
    func meterLayer(_ name: String) -> CALayer { meter.layer!.sublayers!.first { $0.name == name }! }
    func bitmap() -> NSBitmapImageRep {
        meter.layoutSubtreeIfNeeded(); meter.refreshVisibleDrawing()
        let scale = window.backingScaleFactor
        let width = Int(ceil(meter.bounds.width * scale)), height = Int(ceil(meter.bounds.height * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        meter.layer!.render(in: context)
        return NSBitmapImageRep(cgImage: context.makeImage()!)
    }
    func coloredPixels(_ x: Int) -> Int {
        let image = bitmap()
        let scale = Double(image.pixelsWide) / Double(meter.bounds.width)
        return (0..<image.pixelsHigh).filter { y in
            guard let color = image.colorAt(x: Int(Double(x) * scale), y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.5
        }.count
    }
    window.contentView?.layoutSubtreeIfNeeded(); meter.layoutSubtreeIfNeeded()
    meter.needsDisplay = false
    precondition(!meter.needsLayout, "finish initial AppKit layout before measuring ticks")
    level.update(left: 1, right: 0, elapsed: 1)
    precondition(!meter.needsLayout, "first clip/peak update never invalidates layout")
    precondition(coloredPixels(2) > 50 && coloredPixels(7) == 0, "native drawing must preserve independent left/right levels")
    level.reset(); level.update(left: 0, right: 1, elapsed: 1)
    precondition(coloredPixels(2) == 0 && coloredPixels(7) > 50, "native drawing must preserve the right channel independently")
    meter.layoutSubtreeIfNeeded(); meter.needsDisplay = false
    precondition(meter.hitTest(NSPoint(x: 2, y: 30)) == nil, "meters must never intercept selection, drag or right click")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meter.visibleRect.isEmpty, "fixture must fully clip the meter")
    meter.needsDisplay = false
    level.reset(); level.update(left: 0.1, right: 0.5, elapsed: 1)
    precondition(!meter.needsDisplay && !meter.needsLayout, "offscreen level ticks must not invalidate drawing or layout")
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meterLayer("meter-level-0").frame.height > 0 && meterLayer("meter-level-0").frame.height < meterLayer("meter-level-1").frame.height, "revealing an offscreen meter must apply its latest cached levels to the retained layers")
    precondition(coloredPixels(2) < coloredPixels(7), "reveal must show current stereo values rather than old cached pixels")
    meter.bind(level, showScale: false)
    level.reset(); precondition(coloredPixels(2) == 0 && coloredPixels(7) == 0, "silence clears both cached channels")
    // The gradient remains anchored to the entire range; a -30 dB signal
    // exposes only its lower half and must not stretch red into quiet levels.
    level.reset(); level.update(left: pow(10, -30.0 / 20), right: 1, elapsed: 1)
    let leftClip = meterLayer("meter-level-0"), rightClip = meterLayer("meter-level-1")
    let leftGradient = leftClip.sublayers!.first as! CAGradientLayer
    precondition(abs(leftClip.frame.height - 40) < 0.001 && rightClip.frame.height == 80)
    precondition(leftGradient.frame.height == 80 && leftGradient.locations == [0, 0.5, 1])
    let quietBitmap = bitmap(), backingScale = window.backingScaleFactor
    var matchedGradientPixels = 0
    for y in 0..<quietBitmap.pixelsHigh {
        let left = quietBitmap.colorAt(x: Int(2 * backingScale), y: y)!.usingColorSpace(.deviceRGB)!
        let right = quietBitmap.colorAt(x: Int(7 * backingScale), y: y)!.usingColorSpace(.deviceRGB)!
        if max(left.redComponent, max(left.greenComponent, left.blueComponent)) > 0.5 {
            precondition(abs(left.redComponent - right.redComponent) < 0.03 && abs(left.greenComponent - right.greenComponent) < 0.03,
                         "quiet signal colors match the same fixed gradient position in the full-level channel")
            matchedGradientPixels += 1
        }
    }
    precondition(matchedGradientPixels > 20)
    let oldGradient = leftGradient, oldScale = meterLayer("meter-scale-0"), oldScaleContents = (meterLayer("meter-scale-0") as! CATextLayer).string as! NSAttributedString
    let scaleFrames = (0..<3).map { meterLayer("meter-scale-\($0)").frame }
    meter.needsDisplay = false
    for tick in 0..<50 { level.update(left: tick.isMultiple(of: 2) ? 0.1 : 0.5, right: 0.3, elapsed: 1) }
    precondition(meter.layerContentsRedrawPolicy == .never && !meter.needsLayout,
                 "ordinary level ticks cannot schedule NSView bitmap redraw or layout")
    precondition(leftClip.sublayers!.first === oldGradient && meterLayer("meter-scale-0") === oldScale)
    precondition((0..<3).map { meterLayer("meter-scale-\($0)").frame } == scaleFrames)
    precondition(((meterLayer("meter-scale-0") as! CATextLayer).string as! NSAttributedString) === oldScaleContents,
                 "ordinary ticks reuse scale glyphs without assigning new strings")
    precondition(leftClip.animationKeys()?.isEmpty ?? true, "meter updates must not create implicit lagging animations")
    meter.bind(level, showScale: true)
    level.peakHold.record(pow(10, 3.0 / 20))
    let peakText = (meterLayer("meter-peak") as! CATextLayer).string as! NSAttributedString
    precondition(peakText.string == "+3.00" && !meterLayer("meter-peak").isHidden)
    precondition(peakText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.systemRed)
    precondition(meterLayer("meter-peak").frame.minX == 13 && meterLayer("meter-peak").frame.minY > meterLayer("meter-scale-1").frame.minY)
    precondition((0..<3).allSatisfy { meterLayer("meter-scale-\($0)").contentsScale == window.backingScaleFactor },
                 "retained scale glyphs use the native display backing resolution")
    for index in 0..<3 {
        let label = meterLayer("meter-scale-\(index)")
        let width = max(1, Int(ceil(label.bounds.width * backingScale)))
        let height = max(1, Int(ceil(label.bounds.height * backingScale)))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: backingScale, y: backingScale)
        label.render(in: context)
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        precondition((0..<image.pixelsWide).contains { x in
            (0..<image.pixelsHigh).contains { y in (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        }, "0, −24 and −∞ scale layers must all contain visible glyph pixels")
    }
    print("NATIVE_METER_RETAINED_GRADIENTS_STATIC_SCALE_PEAK_AND_NO_TICK_REDRAW_OK")
    let replacement = TrackMeterLevel()
    replacement.update(left: 1, right: 0, elapsed: 1)
    meter.bind(replacement, showScale: true)
    precondition(coloredPixels(2) > 50 && coloredPixels(7) == 0, "rebinding reads the current replacement level")
    meter.needsDisplay = false
    level.update(left: 1, right: 1, elapsed: 1)
    precondition(coloredPixels(2) > 50 && coloredPixels(7) == 0, "rebinding must cancel the previous meter subscription and keep replacement pixels")

    // Compact mixer meters must never clip the right channel at narrow widths.
    meter.bind(replacement, showScale: false)
    for width in [8.0, 10.0] {
        meter.setFrameSize(NSSize(width: width, height: 80))
        func litPixelCount(left: Double, right: Double) -> Int {
            replacement.reset(); replacement.update(left: left, right: right, elapsed: 1)
            let image = bitmap()
            var count = 0
            for x in 0..<image.pixelsWide {
                for y in 0..<image.pixelsHigh {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.5 { count += 1 }
                }
            }
            return count
        }
        let left = litPixelCount(left: 1, right: 0)
        let right = litPixelCount(left: 0, right: 1)
        precondition(left > 0 && left == right, "Compact L/R meters must have equal visible pixel area at width \(width): \(left) vs \(right)")
    }
    meter.setFrameSize(NSSize(width: 32, height: 80))
    replacement.reset(); replacement.update(left: pow(10, -30.0 / 20), right: 1, elapsed: 1)
    meter.setFrameSize(NSSize(width: 32, height: 120)); meter.layoutSubtreeIfNeeded()
    precondition(abs(meterLayer("meter-level-0").frame.height - 60) < 0.001 && meterLayer("meter-level-1").frame.height == 120)
    precondition(meterLayer("meter-level-0").sublayers!.first!.frame.height == 120,
                 "resizing the track updates the fixed gradient and preserves the current dB fraction")
    meter.setFrameSize(NSSize(width: 32, height: 80)); meter.layoutSubtreeIfNeeded()
    print("NATIVE_COMPACT_METER_EQUAL_LEFT_RIGHT_WIDTH_OK")

    var offscreenLevels: [TrackMeterLevel] = [], offscreenViews: [NativeVerticalTrackMeterView] = []
    for index in 0..<95 {
        let model = TrackMeterLevel()
        let view = NativeVerticalTrackMeterView(frame: NSRect(x: 5, y: CGFloat(index + 1) * 90 + 100, width: 32, height: 80))
        document.addSubview(view); view.bind(model, showScale: true)
        view.layoutSubtreeIfNeeded(); view.needsDisplay = false
        offscreenLevels.append(model); offscreenViews.append(view)
    }
    window.contentView?.layoutSubtreeIfNeeded()
    for view in offscreenViews { view.layoutSubtreeIfNeeded(); view.needsDisplay = false }
    let start = ProcessInfo.processInfo.systemUptime
    for tick in 0..<300 {
        let amplitude = tick.isMultiple(of: 2) ? 1.0 : 0.1
        for model in offscreenLevels { model.update(left: amplitude, right: amplitude / 2, elapsed: 1) }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    precondition(offscreenViews.allSatisfy { !$0.needsDisplay && !$0.needsLayout }, "95 offscreen meters must cause zero draw/layout invalidations across 300 ticks")
    window.orderOut(nil)
    let hiddenDrawingState = meter.needsDisplay, hiddenLayoutState = meter.needsLayout
    replacement.reset()
    precondition(meter.needsDisplay == hiddenDrawingState && meter.needsLayout == hiddenLayoutState, "hidden-window level changes must not add AppKit invalidations")
    print("NATIVE_STEREO_METER_DRAW_VISIBLE_CLIP_REVEAL_SUBSCRIPTION_AND_ZERO_OFFSCREEN_LAYOUT_OK")
    print("NATIVE_METER_95_OFFSCREEN_300_TICKS_MS=\(elapsed * 1_000) per_tick_ms=\(elapsed * 1_000 / 300)")
}
MainActor.assumeIsolated { run() }
