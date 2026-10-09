import Foundation

@MainActor func run() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 80, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 80, height: 100))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 10_000))
    scroll.documentView = document; window.contentView = scroll
    let held = TrackMeterLevel()
    var peakPublications = 0
    let peakSubscription = held.peakHold.$decibels.dropFirst().sink { _ in peakPublications += 1 }
    held.update(peak: pow(10, -24.01 / 20), elapsed: 0.03)
    precondition(held.peakHold.decibels == nil && peakPublications == 0)
    held.update(peak: pow(10, -24.0 / 20), elapsed: 0.03)
    precondition(held.peakHold.decibels == -24 && peakPublications == 1)
    held.update(peak: pow(10, -6.0 / 20), elapsed: 0.03)
    for _ in 0..<300 { held.update(peak: 0, elapsed: 1) }
    held.reset()
    precondition(held.peakHold.decibels == -6 && peakPublications == 2,
                 "silence, Stop and five minutes cannot refresh or clear the held number")
    held.update(peak: pow(10, -12.0 / 20), elapsed: 0.03)
    precondition(held.peakHold.decibels == -6 && peakPublications == 2,
                 "only a higher peak updates the number")
    held.peakHold.clear(); held.peakHold.clear()
    precondition(held.peakHold.decibels == nil && peakPublications == 3)
    held.update(peak: pow(10, -18.0 / 20), elapsed: 0.03)
    precondition(held.peakHold.decibels == -18 && peakPublications == 4,
                 "after an explicit reset a lower peak starts a new maximum")
    withExtendedLifetime(peakSubscription) {}
    print("PEAK_HOLD_MINUS24_THRESHOLD_HIGHER_ONLY_NO_TIMED_RESET_OK")
    let decayMeter = TrackMeterLevel()
    decayMeter.update(left: 1, right: 0.1, elapsed: 0)
    for _ in 0..<15 { decayMeter.update(left: 0, right: 0, elapsed: 1.0 / 30) }
    precondition(abs(20 * log10(decayMeter.levels.x) + 24) < 0.001,
                 "a transient falls 24 dB within half a second without altering its peak")
    precondition(abs(decayMeter.levels.x / decayMeter.levels.y - 10) < 0.001,
                 "release preserves independent channel amplitudes")
    for _ in 0..<30 { decayMeter.update(left: 0, right: 0, elapsed: 1.0 / 30) }
    precondition(decayMeter.levels == .zero, "silence clears a full-scale transient within 1.5 seconds")
    decayMeter.update(left: 0.8, right: 0.3, elapsed: 1.0 / 30)
    precondition(decayMeter.levels == SIMD2(0.8, 0.3), "new peaks still attack immediately")
    print("METER_FAST_RELEASE_STEREO_SILENCE_AND_INSTANT_ATTACK_OK")
    let level = TrackMeterLevel(), meter = NativeVerticalTrackMeterView(frame: NSRect(x: 5, y: 0, width: 40, height: 80))
    meter.bind(level, showScale: true); document.addSubview(meter)
    window.orderFront(nil)
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meter.visibleRect.height == 80, "meter fixture must intersect the native viewport")
    func meterLayer(_ name: String) -> CALayer { meter.layer!.sublayers!.first { $0.name == name }! }
    let emptyPeakFrame = meterLayer("meter-peak").frame
    precondition(!meterLayer("meter-peak").isHidden && emptyPeakFrame.width > 0 && meterLayer("meter-peak").borderWidth == 0
        && meterLayer("meter-peak").backgroundColor == nil,
                 "the number keeps its transparent hit area without painting a rectangle or border")
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
    precondition(peakText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.white)
    precondition(meterLayer("meter-peak").frame.minX == 13 && meterLayer("meter-peak").frame.minY > meterLayer("meter-scale-1").frame.minY)
    precondition(meterLayer("meter-peak").frame == emptyPeakFrame,
                 "a peak never changes the rectangle geometry or surrounding meter layout")
    let peakPoint = NSPoint(x: emptyPeakFrame.midX, y: emptyPeakFrame.midY)
    precondition(meter.hitTest(meter.convert(peakPoint, to: meter.superview)) === meter,
                 "only the peak-number rectangle receives the reset click")
    let peakClick = NSEvent.mouseEvent(with: .leftMouseDown, location: meter.convert(peakPoint, to: nil), modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    meter.mouseDown(with: peakClick)
    precondition(level.peakHold.decibels == nil && !meterLayer("meter-peak").isHidden && meterLayer("meter-peak").frame == emptyPeakFrame,
                 "click clears the held maximum and preserves its transparent fixed hit area")
    level.peakHold.record(pow(10, -24.0 / 20))
    let quietPeakText = (meterLayer("meter-peak") as! CATextLayer).string as! NSAttributedString
    precondition(quietPeakText.string == "-24.00" && quietPeakText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.white)
    precondition(quietPeakText.size().width <= emptyPeakFrame.width - 2,
                 "the complete negative number fits the normal mixer meter column without clipping")
    precondition(meterLayer("meter-peak").frame == emptyPeakFrame)
    precondition((0..<3).allSatisfy { meterLayer("meter-scale-\($0)").contentsScale == window.backingScaleFactor },
                 "retained scale glyphs use the native display backing resolution")
    for index in 0..<3 {
        let label = meterLayer("meter-scale-\(index)")
        precondition(label.backgroundColor == nil && label.borderWidth == 0,
            "Scale glyphs have no black background or outline")
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
    for kind in TrackKind.allCases.map(Optional.some) + [nil] {
        let showsNumbers = trackShowsMeterReadouts(kind)
        let expected = kind == nil || kind == .standard || kind == .video || kind == .click
        precondition(showsNumbers == expected, "Only TP1/TP2, chords and timecode omit numeric meter readouts")
        meter.bind(level, showScale: showsNumbers, foreground: .black)
        precondition(meterLayer("meter-peak").isHidden == !expected)
        precondition((0..<3).allSatisfy { meterLayer("meter-scale-\($0)").isHidden == !expected })
        precondition(meterLayer("meter-level-0").frame.height > 0 && meterLayer("meter-level-1").frame.height > 0,
            "Removing numerical readouts must retain stereo level bars, including LTC")
        if expected {
            for name in ["meter-scale-0", "meter-scale-1", "meter-scale-2", "meter-peak"] {
                let text = (meterLayer(name) as! CATextLayer).string as! NSAttributedString
                precondition(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.black,
                    "Each readout uses the provided track-name contrast color")
            }
            precondition(meter.hitTest(meter.convert(peakPoint, to: meter.superview)) === meter)
        } else {
            precondition(meter.hitTest(meter.convert(peakPoint, to: meter.superview)) == nil,
                "Special tracks do not retain an invisible peak reset target")
        }
    }
    meter.setFrameSize(NSSize(width: 52, height: 80)); meter.layoutSubtreeIfNeeded()
    meter.bind(level, showScale: true, foreground: .black, peakOnly: true)
    func numberColor(_ name: String) -> NSColor {
        let text = (meterLayer(name) as! CATextLayer).string as! NSAttributedString
        return text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
    }
    precondition(meter.layer?.backgroundColor == nil,
        "The meter and numerical readout column does not cover the track with a black rectangle")
    precondition((0..<3).allSatisfy { meterLayer("meter-scale-\($0)").isHidden } && !meterLayer("meter-peak").isHidden,
        "The Track Mixer column shows only the held peak, never fixed 0, −24 or −∞ labels")
    precondition(numberColor("meter-peak") == .black, "Peak uses the configured track-name color")
    let bottomPeakFrame = meterLayer("meter-peak").frame
    let bottomPeakPoint = NSPoint(x: bottomPeakFrame.midX, y: bottomPeakFrame.midY)
    let bottomPeakClick = NSEvent.mouseEvent(with: .leftMouseDown, location: meter.convert(bottomPeakPoint, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
    precondition(bottomPeakFrame.minX == 21 && bottomPeakFrame.minY == meter.bounds.minY && bottomPeakFrame.width == 31,
        "Peak stays to the right of MIDI at the bottom of the track")
    precondition(meterLayer("meter-background-0").frame.height == 80,
        "Audio bars keep the full height without a peak header")
    precondition(meterLayer("meter-peak").backgroundColor == nil)
    meter.bind(level, showScale: true, foreground: .systemGreen, peakOnly: true)
    precondition(numberColor("meter-peak") == .systemGreen, "Name color changes propagate to the peak")
    let transparentImage = bitmap()
    let transparentPixel = transparentImage.colorAt(x: transparentImage.pixelsWide - 1, y: transparentImage.pixelsHigh / 3)!
    precondition(transparentPixel.alphaComponent < 0.01,
        "The empty space beside the peak lets the existing track color show through")
    precondition(meterLayer("meter-background-0").backgroundColor == NSColor.black.withAlphaComponent(0.55).cgColor
        && meterLayer("meter-background-1").backgroundColor == NSColor.black.withAlphaComponent(0.55).cgColor,
        "The preexisting narrow stereo bar backgrounds are preserved")
    for decibels in [-0.01, 0.0, 3.0] {
        level.peakHold.clear(); level.peakHold.record(pow(10, decibels / 20))
        precondition(numberColor("meter-peak") == .systemGreen,
            "Peak color follows the name below, at and above zero dB")
    }
    meter.layer = CALayer()
    precondition(meter.layer?.backgroundColor == nil && (0..<3).allSatisfy { meterLayer("meter-scale-\($0)").isHidden } && numberColor("meter-peak") == .systemGreen,
        "Replacing the backing layer preserves the transparent column with only the measured peak visible")
    precondition(meterLayer("meter-peak").frame == bottomPeakFrame && meterLayer("meter-peak").borderWidth == 0
        && meterLayer("meter-peak").backgroundColor == nil)
    precondition(meter.hitTest(meter.convert(bottomPeakPoint, to: meter.superview)) === meter)
    precondition(meter.hitTest(meter.convert(NSPoint(x: 2, y: 30), to: meter.superview)) == nil,
        "The bars still pass through selection and dragging after moving the reset target to the bottom")
    meter.mouseDown(with: bottomPeakClick)
    precondition(level.peakHold.decibels == nil && meter.layer?.backgroundColor == nil
        && meterLayer("meter-peak").backgroundColor == nil,
        "Resetting the held peak keeps the area transparent")
    meter.setFrameSize(NSSize(width: 52, height: 56)); meter.layoutSubtreeIfNeeded()
    level.reset(); level.update(left: 1, right: 0.1, elapsed: 1)
    precondition(meterLayer("meter-level-0").frame.height == 56
        && meterLayer("meter-level-0").sublayers!.first!.frame.height == 56,
        "Levels and the fixed gradient retain the full bar height")
    level.peakHold.clear(); level.peakHold.record(pow(10, -24.0 / 20))
    let compactPeak = (meterLayer("meter-peak") as! CATextLayer).string as! NSAttributedString
    precondition(compactPeak.size().width <= 26 && meterLayer("meter-peak").frame == CGRect(x: 21, y: 0, width: 31, height: 12),
        "The full negative peak fits beside MIDI without clipping")
    meter.setFrameSize(NSSize(width: 40, height: 80)); meter.layoutSubtreeIfNeeded()
    meter.bind(level, showScale: false, peakOnly: true)
    precondition(meterLayer("meter-peak").isHidden && (0..<3).allSatisfy { meterLayer("meter-scale-\($0)").isHidden },
        "Peak-only style never overrides the request to hide numeric readouts for special tracks")
    meter.bind(level, showScale: true, foreground: .black)
    precondition(meter.layer?.backgroundColor == nil && numberColor("meter-scale-0") == .black && numberColor("meter-scale-1") == .black
        && (0..<3).allSatisfy { !meterLayer("meter-scale-\($0)").isHidden },
        "Default transparent callers recover their visible scale and configured name color when a styled row is recycled")
    meter.bind(level, showScale: true, foreground: .white)
    print("NATIVE_METER_SIDE_PEAK_TRANSPARENT_NAME_COLOR_RESET_AND_LAYER_RECOVERY_OK")
    print("NATIVE_METER_ROLE_VISIBILITY_TRANSPARENT_READOUTS_AND_NAME_CONTRAST_OK")
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
    // No new level value is sent after the window returns. The window event
    // itself must flush the cached value; moving to another screen is unnecessary.
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(meterLayer("meter-level-0").frame.height == 0 && meterLayer("meter-level-1").frame.height == 0,
                 "Window reveal must flush cached silence without an audio tick")
    replacement.update(left: 0.1, right: 0.5, elapsed: 1)
    let retainedLeft = meterLayer("meter-level-0")
    meter.layer = CALayer()
    precondition(retainedLeft.superlayer === meter.layer && retainedLeft.frame.height > 0,
                 "Replacing the backing layer must restore bars immediately, without resizing or a new audio tick")
    meter.needsLayout = true; meter.layoutSubtreeIfNeeded()
    precondition(meterLayer("meter-level-0") === retainedLeft && retainedLeft.frame.height > 0,
                 "A replaced AppKit backing layer reattaches the retained meter without new audio")
    // Master is outside a scroll container and needs the same wake-up path.
    let masterWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
    let masterModel = TrackMeterLevel()
    let masterView = NativeVerticalTrackMeterView(frame: NSRect(x: 0, y: 0, width: 12, height: 70))
    masterView.bind(masterModel, showScale: false); masterWindow.contentView = masterView
    masterModel.update(left: 0.5, right: 1, elapsed: 1)
    masterWindow.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    let masterLevel = masterView.layer!.sublayers!.first { $0.name == "meter-level-1" }!
    precondition(masterLevel.frame.height == masterView.bounds.height && masterLevel.frame.height > 0,
                 "Master created while its window is hidden appears on reveal without changing screen")
    masterWindow.orderOut(nil); window.orderOut(nil)
    print("NATIVE_MASTER_METER_WINDOW_REVEAL_AND_BACKING_LAYER_RECOVERY_OK")
    print("NATIVE_STEREO_METER_DRAW_VISIBLE_CLIP_REVEAL_SUBSCRIPTION_AND_ZERO_OFFSCREEN_LAYOUT_OK")
    print("NATIVE_METER_95_OFFSCREEN_300_TICKS_MS=\(elapsed * 1_000) per_tick_ms=\(elapsed * 1_000 / 300)")
}
MainActor.assumeIsolated { run() }
