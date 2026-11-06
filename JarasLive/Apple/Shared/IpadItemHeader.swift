#if os(iOS)
import SwiftUI
import UIKit

/// Weakly registered headers follow the exact native viewport without
/// rebuilding the waveform or publishing scroll positions through SwiftUI.
final class IpadItemHeaderViewport: UIScrollView {
    private let headers = NSHashTable<UIView>.weakObjects()
    func registerHeader(_ header: UIView) { headers.add(header) }
    func unregisterHeader(_ header: UIView) { headers.remove(header) }
    func refreshHeaders() {
        for header in headers.allObjects { header.setNeedsDisplay() }
    }
}

enum IpadItemMixParameter { case gain, pan }

/// Uses the desktop header geometry, including name priority when zooming out.
struct IpadItemHeader: UIViewRepresentable {
    let clip: AudioClip
    let editable: Bool
    let textEditable: Bool
    let interactionID: UUID
    let mix: (IpadItemMixParameter, Double, Bool, Bool) -> Void
    let mute: () -> Void
    let phase: () -> Void
    let fx: () -> Void
    let menu: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeUIView(context: Context) -> IpadItemHeaderControl { IpadItemHeaderControl() }
    func updateUIView(_ view: IpadItemHeaderControl, context: Context) {
        view.interactionID = interactionID
        view.clip = clip; view.editable = editable; view.textEditable = textEditable
        view.mix = mix; view.mute = mute; view.phase = phase; view.fx = fx; view.menu = menu
        view.isEnabled = enabled; view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: IpadItemHeaderControl, coordinator: ()) { view.cancelTracking(with: nil) }
}

final class IpadItemHeaderControl: UIControl {
    static let itemBackgroundColor = UIColor(white: 0.19, alpha: 1)
    var clip = AudioClip(id: UUID(), name: "", startTime: 0, duration: 0) {
        didSet { if oldValue.id != clip.id { cancelTracking(with: nil) }; refreshTooltip() }
    }
    var interactionID: UUID? {
        didSet { if oldValue != interactionID { cancelTracking(with: nil) } }
    }
    override var isEnabled: Bool {
        didSet { if !isEnabled && oldValue { cancelTracking(with: nil) } }
    }
    var editable = true {
        didSet { if !editable && oldValue { cancelTracking(with: nil) } }
    }
    var textEditable = false
    var mix: (IpadItemMixParameter, Double, Bool, Bool) -> Void = { _, _, _, _ in }
    var mute: () -> Void = {}
    var phase: () -> Void = {}
    var fx: () -> Void = {}
    var menu: () -> Void = {}
    private enum Hit { case gain, pan, mute, phase, fx, edit }
    private var hovered: Hit?
    private var tooltip: UILabel?
    private var activeGesture: (hit: Hit, point: CGPoint, geometry: GridSelectionItem)?
    private weak var viewport: IpadItemHeaderViewport?
    private var geometry: GridSelectionItem {
        let item = GridSelectionItem(id: clip.id, rect: bounds, gain: clip.gain ?? 1,
            phaseInverted: clip.phaseInverted == true, pan: clip.pan ?? 0,
            editable: editable, midiEditable: clip.midi != nil, textEditable: textEditable,
            name: clip.name, muted: clip.muted == true, hasFX: !(clip.fx?.inserted.isEmpty ?? true),
            fxBypassed: clip.fxBypassed == true)
        guard let viewport else { return item }
        let visible = convert(viewport.bounds, from: viewport)
        let titleWidth = (clip.name as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: GridSelectionItem.headerFontSize, weight: .semibold)
        ]).width
        return item.visibleLeftHeader(in: visible, titleWidth: titleWidth)
    }
    private func bindViewport() {
        var ancestor = superview
        while let view = ancestor, !(view is IpadItemHeaderViewport) { ancestor = view.superview }
        let next = ancestor as? IpadItemHeaderViewport
        guard viewport !== next else { return }
        viewport?.unregisterHeader(self)
        viewport = next; next?.registerHeader(self)
        setNeedsDisplay()
    }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = true; backgroundColor = Self.itemBackgroundColor
        isMultipleTouchEnabled = false
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); bindViewport(); setNeedsDisplay() }
    override func didMoveToWindow() {
        super.didMoveToWindow(); bindViewport()
        if window == nil { hovered = nil; hideTooltip() }
    }
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .ended || recognizer.state == .cancelled ? nil : hit(recognizer.location(in: self))
        if activeGesture == nil { refreshTooltip() }
    }
    private func hideTooltip() { tooltip?.removeFromSuperview(); tooltip = nil }
    private func refreshTooltip() {
        guard isEnabled, editable, let target = activeGesture?.hit ?? hovered else { hideTooltip(); return }
        showTooltip(target, geometry: geometry)
    }
    private func showTooltip(_ target: Hit, geometry g: GridSelectionItem) {
        guard target == .gain || target == .pan, let window else { hideTooltip(); return }
        let rect = target == .gain ? g.gainKnobRect : g.panKnobRect
        guard let rect else { hideTooltip(); return }
        let label = tooltip ?? UILabel()
        if tooltip == nil {
            label.accessibilityIdentifier = "itemMixTooltip"
            label.isUserInteractionEnabled = false
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white; label.backgroundColor = UIColor(white: 0.06, alpha: 0.96)
            label.textAlignment = .center; label.layer.cornerRadius = 4; label.clipsToBounds = true
            tooltip = label; window.addSubview(label)
        }
        label.text = target == .gain ? g.gainLabel : g.panLabel
        let size = label.sizeThatFits(CGSize(width: 180, height: 28))
        let width = size.width + 14, height: CGFloat = 26
        let anchor = convert(rect, to: window)
        let y = anchor.minY >= height + window.safeAreaInsets.top + 6 ? anchor.minY - height - 5 : anchor.maxY + 5
        label.frame = CGRect(x: min(max(window.safeAreaInsets.left + 4, anchor.midX - width / 2), window.bounds.maxX - width - window.safeAreaInsets.right - 4),
                             y: min(y, window.bounds.maxY - height - window.safeAreaInsets.bottom - 4), width: width, height: height)
        window.bringSubviewToFront(label)
    }
    private func hit(_ point: CGPoint) -> Hit? {
        let g = geometry
        if g.gainKnobRect?.contains(point) == true || g.gainLabelRect?.contains(point) == true { return .gain }
        if g.panKnobRect?.contains(point) == true || g.panLabelRect?.contains(point) == true { return .pan }
        if g.muteRect?.contains(point) == true { return .mute }
        if g.phaseRect?.contains(point) == true { return .phase }
        if g.fxRect?.contains(point) == true { return .fx }
        if g.editRect?.contains(point) == true { return .edit }
        return nil
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isEnabled && bounds.contains(point) && hit(point) != nil
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, let hit = hit(touch.location(in: self)) else { return false }
        if event?.buttonMask.contains(.secondary) == true { menu(); return false }
        if touch.tapCount == 2, hit == .gain || hit == .pan {
            mix(hit == .gain ? .gain : .pan, hit == .gain ? 1 : 0, true, false)
            return false
        }
        activeGesture = (hit, touch.location(in: self), geometry)
        refreshTooltip()
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, activeGesture != nil else { return false }
        updateMix(at: touch.location(in: self), finished: false)
        return true
    }
    private func updateMix(at point: CGPoint, finished: Bool) {
        guard let activeGesture else { return }
        let delta = point.y - activeGesture.point.y
        switch activeGesture.hit {
        case .gain:
            var preview = activeGesture.geometry; preview.gain = preview.draggingGain(by: delta)
            mix(.gain, preview.gain, finished, false); showTooltip(.gain, geometry: preview)
        case .pan:
            var preview = activeGesture.geometry; preview.pan = preview.draggingPan(by: delta)
            mix(.pan, preview.pan, finished, false); showTooltip(.pan, geometry: preview)
        default: break
        }
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let activeGesture else { return }
        let point = touch?.location(in: self) ?? activeGesture.point
        updateMix(at: point, finished: true)
        self.activeGesture = nil
        refreshTooltip()
        guard hit(point) == activeGesture.hit else { return }
        switch activeGesture.hit {
        case .mute: mute()
        case .phase: phase()
        case .fx: fx()
        case .edit: menu()
        default: break
        }
    }
    override func cancelTracking(with event: UIEvent?) {
        let previous = activeGesture; activeGesture = nil
        hovered = nil; hideTooltip()
        if let activeGesture = previous {
            if activeGesture.hit == .gain { mix(.gain, activeGesture.geometry.gain, true, true) }
            if activeGesture.hit == .pan { mix(.pan, activeGesture.geometry.pan, true, true) }
        }
        super.cancelTracking(with: event)
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor(white: 0.19, alpha: 1).setFill(); context.fill(bounds)
        let g = geometry
        let green = UIColor(red: 0.37, green: 0.75, blue: 0.25, alpha: 1)
        func label(_ text: String, _ rect: CGRect?, color: UIColor = .white, centered: Bool = true) {
            guard let rect, rect.width > 0 else { return }
            let style = NSMutableParagraphStyle(); style.alignment = centered ? .center : .left
            style.lineBreakMode = .byTruncatingTail
            let font = UIFont.systemFont(ofSize: GridSelectionItem.headerFontSize, weight: .semibold)
            let line = CGRect(x: rect.minX, y: rect.midY - font.lineHeight / 2, width: rect.width, height: font.lineHeight)
            (text as NSString).draw(in: line, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
        func button(_ rect: CGRect?, active: Bool, text: String, ink: UIColor = .white) {
            guard let rect else { return }
            (active ? UIColor.systemRed : UIColor.white.withAlphaComponent(0.10)).setFill()
            context.fill(rect); label(text, rect, color: ink)
        }
        func knob(_ rect: CGRect?, position: Double) {
            guard let rect else { return }
            let center = CGPoint(x: rect.midX, y: rect.midY), radius: CGFloat = min(5, rect.height / 2 - 1)
            UIColor.black.setFill(); context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            context.setLineWidth(1.3); context.setLineCap(.round)
            context.setStrokeColor(UIColor.white.cgColor)
            context.addArc(center: center, radius: radius, startAngle: .pi * 0.75, endAngle: .pi * 2.25, clockwise: false); context.strokePath()
            let angle = (.pi * 0.75) + CGFloat(position) * .pi * 1.5
            context.setStrokeColor(green.cgColor)
            context.move(to: center); context.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)); context.strokePath()
        }
        knob(g.gainKnobRect, position: g.gainPosition); label(g.gainLabel, g.gainLabelRect)
        button(g.muteRect, active: g.muted, text: "M")
        button(g.fxRect, active: g.fxBypassed, text: "FX", ink: g.hasFX && !g.fxBypassed ? green : .white)
        if let phase = g.phaseRect {
            if g.phaseInverted { UIColor.systemYellow.setFill(); context.fill(phase) }
            context.setStrokeColor((g.phaseInverted ? UIColor.black : .white).cgColor); context.setLineWidth(1.1)
            let center = CGPoint(x: phase.midX, y: phase.midY)
            context.strokeEllipse(in: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            context.move(to: CGPoint(x: center.x - 5.5, y: center.y + 5.5)); context.addLine(to: CGPoint(x: center.x + 5.5, y: center.y - 5.5)); context.strokePath()
        }
        knob(g.panKnobRect, position: g.panPosition); label(g.panLabel, g.panLabelRect)
        button(g.editRect, active: false, text: JarasLocalization.string("Edit"))
        label(clip.name, CGRect(x: g.headerRect.minX + g.titleInset, y: 0, width: max(0, g.headerRect.width - g.titleInset - 2), height: bounds.height), centered: false)
    }
}
#endif
