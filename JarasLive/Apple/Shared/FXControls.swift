import SwiftUI
import Combine

struct FXKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var multiplier: Double = 1
    var logarithmic = false
    let reset: Double
    let parameter: NativeFXParameter.Key
    @State private var origin: Double?
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, multiplier: Double = 1, logarithmic: Bool = false, reset: Double, parameter: NativeFXParameter.Key) {
        self.title = title; _value = value; self.range = range; self.unit = unit
        self.multiplier = multiplier; self.logarithmic = logarithmic; self.reset = reset; self.parameter = parameter
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
        VStack(spacing: 10) {
            Text(LocalizedStringKey(title)).font(.jarasSystem(size: 11, weight: .medium)).foregroundStyle(JarasTheme.secondary)
            ZStack {
                Circle().trim(from: 0,to: 0.75).stroke(Color.white.opacity(0.08),style: StrokeStyle(lineWidth: 4,lineCap: .round)).rotationEffect(.degrees(135))
                Circle().trim(from: 0,to: 0.75*fraction).stroke(AngularGradient(colors: [Color.cyan,JarasTheme.green],center: .center,startAngle: .degrees(135),endAngle: .degrees(405)),style: StrokeStyle(lineWidth: 4,lineCap: .round)).rotationEffect(.degrees(135))
                Circle().fill(LinearGradient(colors: [Color(white: 0.27),Color(white: 0.10)],startPoint: .topLeading,endPoint: .bottomTrailing)).padding(7)
                    .overlay(Circle().stroke(Color.white.opacity(0.12),lineWidth: 1).padding(7)).shadow(color: .black.opacity(0.6),radius: 3,y: 3)
                Capsule().fill(JarasTheme.green).frame(width: 3,height: 16).offset(y: -21).rotationEffect(.degrees(-135 + fraction*270))
            }.frame(width: 76,height: 76).contentShape(Circle())
                #if os(macOS)
                .overlay(FXKnobMouseInput(fraction: Binding(get: { fraction }, set: { set($0) }), reset: { value = reset }))
                #else
                .overlay(FXTouchDrag(began: { _ in origin = fraction }, changed: { _, translation in
                    set((origin ?? fraction) - translation.height / 180)
                }, ended: { origin = nil }, reset: { value = reset }))
                #endif
                .accessibilityElement().accessibilityLabel(LocalizedStringKey(title)).accessibilityValue(String(format: "%.1f %@",value*multiplier,unit))
                .accessibilityAdjustableAction { set(fraction + ($0 == .increment ? 0.01 : -0.01)) }
            Text(String(format: "%.1f %@", value*multiplier,unit)).font(.jarasSystem(size: 11,weight: .medium,design: .monospaced)).monospacedDigit()
        }.frame(maxWidth: .infinity).jarasHelp("Drag vertically. Double-click to reset.")
            .mapFXMIDI(parameter, name: title, range: range, logarithmic: logarithmic)
    }
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
                            LinearGradient(colors: [.red,.yellow,Color(hex: 0xbf5af2)],startPoint: .top,endPoint: .bottom)
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
