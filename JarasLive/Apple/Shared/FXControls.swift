import SwiftUI
import Combine

enum NativeFXAppearance {
    static let violet = Color(red: 0.76, green: 0.66, blue: 0.97)
    static let mint = Color(red: 0.49, green: 0.85, blue: 0.75)
    static let chassis = [Color(red: 0.14, green: 0.15, blue: 0.17), Color(red: 0.09, green: 0.10, blue: 0.12)]
    static let plum = [Color(red: 0.18, green: 0.12, blue: 0.23), Color(red: 0.09, green: 0.06, blue: 0.13)]
    static func accent(_ effect: String) -> Color {
        switch effect {
        case "EQ", "EQ - 31 Band", "Arpeggiator", "Pitch": return violet
        case "Compressor", "Limiter", "Cat Gate", "CatLive Trigger", "Amp":
            return Color(red: 0.93, green: 0.72, blue: 0.41)
        case "Phaser", "Chorus": return Color(red: 0.48, green: 0.78, blue: 0.93)
        default: return mint
        }
    }
}
private struct FXDialAccentKey: EnvironmentKey { static let defaultValue = NativeFXAppearance.mint }
extension EnvironmentValues {
    var fxDialAccent: Color {
        get { self[FXDialAccentKey.self] }
        set { self[FXDialAccentKey.self] = newValue }
    }
}
extension View {
    func nativeFXRack() -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return background(shape.fill(LinearGradient(colors: [Color(red: 0.105, green: 0.115, blue: 0.14),
                                                            Color(red: 0.07, green: 0.078, blue: 0.095)],
                                                    startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1).allowsHitTesting(false))
    }
}

private struct FXKnobDiameterKey: EnvironmentKey { static let defaultValue: CGFloat = 76 }
extension EnvironmentValues {
    var fxKnobDiameter: CGFloat {
        get { self[FXKnobDiameterKey.self] }
        set { self[FXKnobDiameterKey.self] = newValue }
    }
}
struct FXKnob: View {
    @Environment(\.fxKnobDiameter) private var diameter
    @Environment(\.fxDialAccent) private var accent
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var multiplier: Double = 1
    var logarithmic = false
    let reset: Double
    let parameter: NativeFXParameter.Key?
    var dialOnly = false
    @State private var origin: Double?
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, multiplier: Double = 1, logarithmic: Bool = false, reset: Double, parameter: NativeFXParameter.Key? = nil, dialOnly: Bool = false) {
        self.title = title; _value = value; self.range = range; self.unit = unit
        self.multiplier = multiplier; self.logarithmic = logarithmic; self.reset = reset; self.parameter = parameter; self.dialOnly = dialOnly
    }
    private var fraction: Double {
        let offset = range.lowerBound == 0 ? 0.001 : 0
        let amount = logarithmic ? log((max(range.lowerBound,value)+offset)/(range.lowerBound+offset))/log((range.upperBound+offset)/(range.lowerBound+offset)) : (value-range.lowerBound)/(range.upperBound-range.lowerBound)
        return min(1,max(0,amount))
    }
    private func set(_ amount: Double) {
        let x = min(1,max(0,amount))
        let offset = range.lowerBound == 0 ? 0.001 : 0
        value = logarithmic ? (range.lowerBound+offset)*pow((range.upperBound+offset)/(range.lowerBound+offset),x)-offset : range.lowerBound+x*(range.upperBound-range.lowerBound)
    }
    var body: some View {
        if let parameter { knob.mapFXMIDI(parameter, name: title, range: range, logarithmic: logarithmic) }
        else { knob }
    }
    private var knob: some View {
        VStack(spacing: diameter < 76 ? 6 : 10) {
            if !dialOnly { Text(verbatim: title).font(.jarasSystem(size: 11, weight: .medium)).foregroundStyle(JarasTheme.secondary) }
            ZStack {
                Canvas { context, size in
                    let radius = size.width / 2
                    for i in 0...10 {
                        let angle = Double(-225 + i * 27) * .pi / 180
                        let length: CGFloat = i.isMultiple(of: 5) ? 4 : 2.5
                        var tick = Path()
                        tick.move(to: CGPoint(x: radius + (radius - length) * cos(angle), y: radius + (radius - length) * sin(angle)))
                        tick.addLine(to: CGPoint(x: radius + (radius - 1) * cos(angle), y: radius + (radius - 1) * sin(angle)))
                        context.stroke(tick, with: .color(.white.opacity(0.50)), lineWidth: 1)
                    }
                }
                Circle().trim(from: 0, to: 0.75).stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135)).padding(min(7, diameter * 0.1))
                Circle().trim(from: 0, to: 0.75 * fraction).stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135)).padding(min(7, diameter * 0.1))
                Circle().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.17), lineWidth: 1)).padding(min(11, diameter * 0.17))
                Capsule().fill(accent).frame(width: 3, height: diameter * 0.16)
                    .offset(y: -diameter * 0.21).rotationEffect(.degrees(-135 + fraction * 270))
            }.frame(width: diameter,height: diameter).contentShape(Circle())
                #if os(macOS)
                .overlay(FXKnobMouseInput(fraction: Binding(get: { fraction }, set: { set($0) }), reset: { value = reset }))
                #else
                .overlay(FXTouchDrag(began: { _ in origin = fraction }, changed: { _, translation in
                    set((origin ?? fraction) - translation.height / 180)
                }, ended: { origin = nil }, reset: { value = reset }))
                #endif
                .accessibilityElement().accessibilityLabel(Text(verbatim: title)).accessibilityValue(String(format: "%.1f %@",value*multiplier,unit))
                .accessibilityAdjustableAction { set(fraction + ($0 == .increment ? 0.01 : -0.01)) }
            if !dialOnly {
                Text(verbatim: String(format: "%.1f %@", value * multiplier, unit))
                .font(.jarasSystem(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(accent).padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 4))
            }
        }.frame(maxWidth: dialOnly ? diameter : .infinity).jarasHelp("Drag vertically. Double-click to reset.")
    }
}
struct ArpeggiatorControls: View {
    @Binding var parameters: NativeArpeggiatorSettings
    private let pitches = [60, 64, 67]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(verbatim: "Pattern preview").font(.jarasSystem(size: 15, weight: .semibold))
                Spacer()
                Toggle("Sync", isOn: $parameters.sync).toggleStyle(.switch).tint(JarasTheme.green)
            }
            Canvas { context, size in
                let count = parameters.division
                let step = size.width / CGFloat(count)
                let lanes = parameters.octaves * pitches.count
                let lane = size.height / CGFloat(lanes)
                let color = NativeFXAppearance.violet
                for column in 0..<count {
                    let x = CGFloat(column) * step
                    let stroke = CGRect(x: x, y: 0, width: 1, height: size.height)
                    context.fill(Path(stroke), with: .color(.white.opacity(column.isMultiple(of: max(1, count / 4)) ? 0.23 : 0.08)))
                    let pitch = parameters.step(column, count: pitches.count) { pitches[$0] }
                    let row = lanes - 1 - (pitch.transpose / 12 * pitches.count + pitch.note)
                    let rect = CGRect(x: x, y: CGFloat(row) * lane + 1,
                                      width: max(1, step * parameters.gateFraction), height: max(1, lane - 2))
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                }
            }.frame(height: 112).accessibilityHidden(true)
            HStack(alignment: .top, spacing: 14) {
                control("Rate") {
                    Picker("Rate", selection: $parameters.division) {
                        ForEach(NativeArpeggiatorSettings.divisions, id: \.self) { rate in
                            Text(verbatim: rate.isMultiple(of: 3) ? "1/\(rate * 2 / 3)T" : "1/\(rate)").tag(rate)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                }
                control("Direction") {
                    Picker("Direction", selection: $parameters.direction) {
                        ForEach(NativeArpeggiatorSettings.directions.indices, id: \.self) { index in
                            Text(verbatim: NativeArpeggiatorSettings.directions[index]).tag(index)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                }
                control("Octaves") {
                    Picker("Octaves", selection: $parameters.octaves) {
                        ForEach(1...4, id: \.self) { value in Text(verbatim: String(value)).tag(value) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                control("Gate") {
                    Stepper(value: $parameters.gate, in: 5...100) {
                        Text(verbatim: "\(parameters.gate)%").monospacedDigit()
                    }.accessibilityLabel("Gate").accessibilityValue("\(parameters.gate)%")
                }
                control("BPM") {
                    Stepper(value: $parameters.bpm, in: 20...400) {
                        Text(verbatim: String(parameters.bpm)).monospacedDigit()
                    }.accessibilityLabel("BPM").accessibilityValue(String(parameters.bpm)).disabled(parameters.sync)
                }
            }
        }.padding(16).nativeFXRack()
    }

    private func control<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label).foregroundStyle(Color.white.opacity(0.72))
            content()
        }.font(.jarasSystem(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The marker and the live input share a linear dB scale.
struct DynamicsThresholdMeter: View {
    let track: UUID?
    let effect: String
    @Binding var threshold: Double
    let compressor: Bool
    @State private var input = SIMD2<Double>.zero
    @State private var reduction = 0.0
    @State private var clock = Timer.publish(every: 1.0/30, on: .main, in: .common).autoconnect()
    private var floorDB: Double { compressor ? -60 : -80 }
    private let railHeight: CGFloat = 152
    private var valueText: String { String(format: "%.1f dB", threshold) }

    private static let handle = Path { path in
        path.move(to: CGPoint(x: 2, y: 0.5))
        path.addQuadCurve(to: CGPoint(x: 0.5, y: 1.5), control: CGPoint(x: 0.5, y: -0.3))
        path.addLine(to: CGPoint(x: 0.5, y: 8.5))
        path.addQuadCurve(to: CGPoint(x: 2, y: 9.5), control: CGPoint(x: 0.5, y: 10.3))
        path.addLine(to: CGPoint(x: 9, y: 6))
        path.addLine(to: CGPoint(x: 37, y: 6))
        path.addQuadCurve(to: CGPoint(x: 37, y: 4), control: CGPoint(x: 39, y: 5))
        path.addLine(to: CGPoint(x: 9, y: 4))
        path.closeSubpath()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                title("Threshold")
                GeometryReader { geometry in
                    let height = geometry.size.height
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<2, id: \.self) { channel in
                            let db = input[channel] > 0 ? 20 * log10(input[channel]) : floorDB
                            let fraction = min(1, max(0, 1 - db / floorDB))
                            ZStack(alignment: .bottom) {
                                Color.black.opacity(0.65)
                                LinearGradient(colors: [.yellow, JarasTheme.green], startPoint: .top, endPoint: .bottom)
                                    .mask(alignment: .bottom) { Rectangle().frame(height: height * fraction) }
                            }.frame(width: 11, height: height).clipShape(RoundedRectangle(cornerRadius: 2))
                                .offset(x: CGFloat(7 + channel * 14))
                        }
                        ForEach(Array(stride(from: 0, through: Int(-floorDB), by: 20)), id: \.self) { tick in
                            Text(verbatim: tick == 0 ? "0" : "−" + String(tick))
                                .font(.jarasSystem(size: 9, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                                .position(x: 51, y: min(height - 5, max(5, CGFloat(tick) / -floorDB * height)))
                        }
                        Self.handle.fill(Color.white).frame(width: 38, height: 10)
                            .shadow(color: .black, radius: 1)
                            .offset(y: min(height, max(0, height * threshold / floorDB)) - 5)
                            .allowsHitTesting(false)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        #if os(iOS)
                        .overlay(FXTouchDrag(began: { set(at: $0.y, height: height) },
                                             changed: { point, _ in set(at: point.y, height: height) },
                                             ended: {}, reset: reset))
                        #else
                        .gesture(DragGesture(minimumDistance: 0).onChanged { set(at: $0.location.y, height: height) })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
                        #endif
                }.frame(width: 65, height: railHeight)
                readout(valueText)
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Threshold")).accessibilityValue(Text(verbatim: valueText))
                .accessibilityAdjustableAction { threshold = min(0, max(floorDB, threshold + ($0 == .increment ? 1 : -1))) }
                .mapFXMIDI(compressor ? .threshold : .gateThreshold, name: "Threshold", range: floorDB...0)
            if compressor {
                VStack(spacing: 8) {
                    title("Reduce")
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.65)
                        Rectangle().fill(Color.red).frame(height: railHeight * min(1, reduction / 24))
                    }.frame(width: 14, height: railHeight).clipShape(RoundedRectangle(cornerRadius: 2))
                    readout(String(format: "%.1f dB", reduction))
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "Reduce"))
                    .accessibilityValue(Text(verbatim: String(format: "%.1f dB", reduction)))
            }
        }
        .onReceive(clock) { _ in
            let engine = StemAudioPlayback.shared
            let peaks = engine.effectPeaks(track, effect: effect)
            guard peaks.count >= 2 else { return }
            let decay = pow(10.0, -TrackMeterLevel.releaseDecibelsPerSecond / (30 * 20))
            var next = input * decay
            for channel in 0..<2 {
                next[channel] = max(next[channel], Double(peaks[channel]))
                if next[channel] < 0.0001 { next[channel] = 0 }
            }
            if next != input { input = next }
            if compressor {
                let db = max(peaks[0], peaks[1]) > 0 ? engine.compressorReduction(track, effect: effect) : 0
                let shown = max(db, reduction - 1.4)
                if shown != reduction { reduction = shown }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text).font(.jarasSystem(size: 11, weight: .semibold)).foregroundStyle(JarasTheme.secondary)
    }
    private func readout(_ text: String) -> some View {
        Text(verbatim: text).font(.jarasSystem(size: 10, weight: .semibold, design: .monospaced)).monospacedDigit()
            .foregroundStyle(.white).frame(minWidth: 49)
    }
    private func set(at y: CGFloat, height: CGFloat) {
        let db = (floorDB * min(1, max(0, y / max(1, height))) * 10).rounded() / 10
        if threshold != db { threshold = db }
    }
    private func reset() { threshold = compressor ? -20 : -40 }
}

struct EffectVerticalMeters: View {
    let track: UUID?
    let effect: String
    @StateObject private var input = TrackMeterLevel()
    @StateObject private var output = TrackMeterLevel()
    @State private var clock = Timer.publish(every: 1.0/30,on: .main,in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 9) {
            bars(input.levels, title: "IN")
            VStack { Text("0"); Spacer(); Text("−24"); Spacer(); Text("−60") }.font(.jarasSystem(size: 8,design: .monospaced)).foregroundStyle(JarasTheme.secondary).padding(.vertical,20)
            bars(output.levels, title: "OUT")
        }.frame(width: 104,height: 145)
        .onReceive(clock) { _ in
            let values = StemAudioPlayback.shared.effectPeaks(track,effect: effect)
            input.update(left: Double(values[0]),right: Double(values[1]),elapsed: 1.0/30)
            output.update(left: Double(values[2]),right: Double(values[3]),elapsed: 1.0/30)
        }
    }
    private func bars(_ values: SIMD2<Double>, title: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.jarasSystem(size: 9,weight: .semibold,design: .monospaced)).foregroundStyle(JarasTheme.secondary)
            HStack(spacing: 3) {
                ForEach(0..<2,id: \.self) { channel in
                    GeometryReader { geometry in
                        let fraction = min(1,max(0,(20*log10(max(0.001,values[channel]))+60)/60))
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.7))
                            LinearGradient(colors: [.red,.yellow,Color(hex: 0x0a84ff)],startPoint: .top,endPoint: .bottom)
                                .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height*fraction) }
                        }.clipShape(RoundedRectangle(cornerRadius: 2))
                    }.frame(width: 9)
                }
            }
            Text("L  R").font(.jarasSystem(size: 8,design: .monospaced)).foregroundStyle(JarasTheme.secondary)
        }
    }
}

#if os(macOS)
private struct FXKnobMouseInput: NSViewRepresentable {
    @Binding var fraction: Double
    let reset: () -> Void
    func makeNSView(context: Context) -> FXKnobMouseView { FXKnobMouseView() }
    func updateNSView(_ view: FXKnobMouseView, context: Context) {
        view.value = fraction; view.changed = { fraction = $0 }; view.reset = reset
    }
}
private final class FXKnobMouseView: NSView {
    var value = 0.0
    var changed: ((Double) -> Void)?
    var reset: (() -> Void)?
    private var startY: CGFloat?
    private var startValue = 0.0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { startY = nil; reset?(); return }
        startY = event.locationInWindow.y; startValue = value
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startY else { return }
        changed?(min(1,max(0,startValue + Double(event.locationInWindow.y-startY)/180)))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); startY = nil }
}
#endif

#if os(iOS)
import UIKit

/// Claim a touch that starts on an FX control before an ancestor scroll view can
/// turn it into scrolling. Touches outside the control still scroll normally.
struct FXTouchDrag: UIViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let began: (CGPoint) -> Void
    let changed: (CGPoint, CGSize) -> Void
    let ended: () -> Void
    var reset: (() -> Void)? = nil
    func makeUIView(context: Context) -> FXTouchDragView { FXTouchDragView() }
    func updateUIView(_ view: FXTouchDragView, context: Context) {
        view.began = began; view.changed = changed; view.ended = ended; view.reset = reset
        view.isUserInteractionEnabled = enabled
    }
}
final class FXTouchDragView: UIView {
    var began: ((CGPoint) -> Void)?
    var changed: ((CGPoint, CGSize) -> Void)?
    var ended: (() -> Void)?
    var reset: (() -> Void)?
    private var resetting = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(FXImmediateDrag(target: self, action: #selector(handle(_:))))
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func handle(_ gesture: FXImmediateDrag) {
        switch gesture.state {
        case .began:
            resetting = gesture.tapCount == 2 && reset != nil
            if resetting { reset?() } else { began?(gesture.start) }
        case .changed:
            if !resetting {
                changed?(gesture.point, CGSize(width: gesture.point.x - gesture.start.x, height: gesture.point.y - gesture.start.y))
            }
        case .ended, .cancelled, .failed:
            ended?(); resetting = false
        default: break
        }
    }
}
private final class FXImmediateDrag: UIGestureRecognizer {
    private(set) var start = CGPoint.zero
    private(set) var point = CGPoint.zero
    private(set) var tapCount = 0
    private weak var activeTouch: UITouch?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch; point = touch.location(in: view); start = point
        tapCount = touch.tapCount; state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        point = activeTouch.location(in: view); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        point = activeTouch.location(in: view); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { super.reset(); activeTouch = nil }
}
#endif
