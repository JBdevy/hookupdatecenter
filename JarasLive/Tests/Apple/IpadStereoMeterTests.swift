private let meter = MixerRailLayers(flipped: true)
let gradient = meter.layer.sublayers!.first as! CAGradientLayer
let channels = gradient.mask!.sublayers!
let colors = gradient.colors as! [CGColor]
precondition(MixerMeterStyle.railBackground(for: .lightDark) == MixerMeterStyle.cgColor(JarasTheme.lightDarkBackgroundHex))
precondition(MixerMeterStyle.railBackground(for: .dark) == MixerMeterStyle.cgColor(0x0a0a0a))
let unchanged = CGSize(width: 200, height: 14)
meter.update(size: unchanged, levels: .zero, theme: .lightDark)
precondition(meter.layer.backgroundColor == MixerMeterStyle.railBackground(for: .lightDark))
meter.update(size: unchanged, levels: .zero, theme: .dark)
precondition(meter.layer.backgroundColor == MixerMeterStyle.railBackground(for: .dark),
    "Changing theme updates a retained idle fader without a meter sample")
precondition(colors[0] == MixerMeterStyle.cgColor(0x239653)
    && colors[2] == MixerMeterStyle.cgColor(0xFFDC52)
    && colors[4] == MixerMeterStyle.cgColor(0xF44336))
precondition(MixerMeterStyle.gradientAxis(in: CGRect(x: 0, y: 0, width: 6, height: 100),
    vertical: true).start.y == 100, "Vertical rails grow from the bottom")

for width: CGFloat in [0, 1, 8, 9.5, 200] {
    let size = CGSize(width: width, height: MixerMeterStyle.railThickness)
    let channelHeight = (size.height - 1) / 2
    meter.update(size: size, levels: SIMD2(1, 0))
    precondition(channels[0].frame == CGRect(x: 0, y: 0, width: width, height: channelHeight))
    precondition(channels[1].frame == CGRect(x: 0, y: channelHeight + 1, width: 0, height: channelHeight))
    meter.update(size: size, levels: SIMD2(pow(10, -30.0 / 20), 1))
    precondition(abs(channels[0].frame.width - width / 2) < 0.001)
    precondition(channels[1].frame.minY - channels[0].frame.maxY == 1, "A one-point gap separates left and right")
    precondition(channels[1].frame.width == width)
}
meter.update(size: CGSize(width: 200, height: 6), levels: SIMD2(.nan, .infinity))
precondition(channels.allSatisfy { $0.frame.width == 0 })

let compact = CGSize(width: 9, height: 20)
meter.update(size: compact, levels: SIMD2(pow(10, -30.0 / 20), 1), compact: true)
precondition(meter.layer.frame == CGRect(x: 0.5, y: 0, width: 8, height: 20) && meter.layer.cornerRadius == 4)
precondition(gradient.startPoint.y == 1 && gradient.endPoint.y == 0)
precondition(channels[0].frame == CGRect(x: 0, y: 10, width: 3.5, height: 10))
precondition(channels[1].frame == CGRect(x: 4.5, y: 0, width: 3.5, height: 20))
meter.update(size: CGSize(width: 7, height: 14), levels: .zero, compact: true)
precondition(meter.layer.frame.size == CGSize(width: 7, height: 14) && channels.allSatisfy { $0.frame.height == 0 })
for tick in 0..<300 {
    meter.update(size: CGSize(width: 200, height: 6), levels: SIMD2(Double(tick % 2), Double((tick + 1) % 2)))
}
precondition(zip(channels, gradient.mask!.sublayers!).allSatisfy { $0 === $1 })
precondition(gradient.startPoint.x == 0 && gradient.endPoint.x == 1)
precondition(channels.allSatisfy { $0.animationKeys()?.isEmpty != false })
print("IPAD_STEREO_FADER_AND_COMPACT_RAIL_OK")
