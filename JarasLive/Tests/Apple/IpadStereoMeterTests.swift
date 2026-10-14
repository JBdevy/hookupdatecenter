private let meter = IpadStereoMeterLayers()
let wells = meter.layer.sublayers!
let bars = wells.map { $0.sublayers!.first! }
let masks = bars.map { $0.mask! }
for scale: CGFloat in [1, 2, 3] {
    for width: CGFloat in [0, 1, 8, 9.5, 10, 11, 12] {
        for height: CGFloat in [28, 70, 140] {
            meter.update(size: CGSize(width: width, height: height), scale: scale, levels: SIMD2(1, 0))
            precondition(wells[0].frame.width == wells[1].frame.width)
            precondition(wells[0].frame.maxX <= wells[1].frame.minX)
            precondition(wells[1].frame.maxX <= width)
            if width >= 8 { precondition(wells[1].frame.minX - wells[0].frame.maxX >= 2) }
            precondition(masks[0].frame.height == height && masks[1].frame.height == 0)
            meter.update(size: CGSize(width: width, height: height), scale: scale, levels: SIMD2(0, 1))
            precondition(masks[0].frame.height == 0 && masks[1].frame.height == height)
            meter.update(size: CGSize(width: width, height: height), scale: scale, levels: SIMD2(pow(10, -30.0 / 20), 1))
            precondition(abs(masks[0].frame.height - height / 2) < 0.001)
            precondition(bars.allSatisfy { $0.frame.height == height }, "gradient must not stretch with level")
        }
    }
}
meter.update(size: CGSize(width: 10, height: 70), scale: 2, levels: SIMD2(.nan, .infinity))
precondition(masks.allSatisfy { $0.frame.height == 0 })
for tick in 0..<300 {
    meter.update(size: CGSize(width: 10, height: 70), scale: 2, levels: SIMD2(Double(tick % 2), Double((tick + 1) % 2)))
}
precondition(zip(wells, meter.layer.sublayers!).allSatisfy { $0 === $1 }, "meter ticks reuse layers")
precondition(meter.layer.backgroundColor == nil, "the stereo gutter must be transparent")
precondition(wells.allSatisfy { $0.animationKeys()?.isEmpty != false })
precondition(masks.allSatisfy { $0.animationKeys()?.isEmpty != false })
print("IPAD_MASTER_TRACK_STEREO_INDEPENDENT_CHANNELS_EQUAL_PIXEL_WIDTH_GUTTER_RESIZE_AND_RETAINED_LAYERS_OK")
