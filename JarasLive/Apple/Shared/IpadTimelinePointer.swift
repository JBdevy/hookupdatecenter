#if os(iOS)
import SwiftUI
import UIKit

struct IpadTimelinePointerEvent {
    enum Phase { case began, moved, ended, cancelled }
    let phase: Phase
    let position: CGPoint
    let origin: CGPoint
    let secondary: Bool
    let modifiers: HardwareKeyboardModifiers
    var distance: CGFloat { hypot(position.x - origin.x, position.y - origin.y) }
}

/// Only a connected pointer uses this recognizer. Direct touch keeps the
/// existing scrolling, long press, pinch and resize controls.
struct IpadTimelinePointerProbe: UIViewRepresentable {
    var enabled: Bool
    var capturesPointer = true
    var reset: UUID
    var accepts: (CGPoint) -> Bool
    var wantsAutoScroll: (CGPoint) -> Bool
    var event: (IpadTimelinePointerEvent) -> Void
    var wheel: (CGPoint, HardwareKeyboardModifiers) -> Void
    func makeUIView(context: Context) -> IpadTimelinePointerView { IpadTimelinePointerView() }
    func updateUIView(_ view: IpadTimelinePointerView, context: Context) {
        view.accepts = accepts; view.wantsAutoScroll = wantsAutoScroll; view.event = event; view.wheel = wheel
        view.setEnabled(enabled, reset: reset, capturesPointer: capturesPointer)
    }
    static func dismantleUIView(_ view: IpadTimelinePointerView, coordinator: ()) { view.detach() }
}

final class IpadTimelinePointerView: UIView, UIGestureRecognizerDelegate {
    var accepts: (CGPoint) -> Bool = { _ in false }
    var wantsAutoScroll: (CGPoint) -> Bool = { _ in false }
    var event: (IpadTimelinePointerEvent) -> Void = { _ in }
    var wheel: (CGPoint, HardwareKeyboardModifiers) -> Void = { _,_ in }
    private var active = false
    private var capturesPointer = true
    private var resetID: UUID?
    private weak var owner: UIWindow?
    private weak var wheelScrollView: UIScrollView?
    private var originalScrollTypes: UIScrollTypeMask?
    private var dragClock: CADisplayLink?
    private final class TickTarget: NSObject {
        weak var view: IpadTimelinePointerView?
        init(_ view: IpadTimelinePointerView) { self.view = view }
        @objc func tick() { view?.dragTick() }
    }
    private lazy var pointer = IpadGridPointerRecognizer(target: self, action: #selector(pointerChanged(_:)))
    private lazy var scroll = UIPanGestureRecognizer(target: self, action: #selector(wheelChanged(_:)))
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow(); detach()
        guard let window else { return }
        owner = window
        pointer.delegate = self
        pointer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointer.cancelsTouchesInView = true
        scroll.delegate = self; scroll.allowedTouchTypes = []
        scroll.allowedScrollTypesMask = [.continuous, .discrete]
        scroll.cancelsTouchesInView = false
        window.addGestureRecognizer(pointer); window.addGestureRecognizer(scroll)
        updateWheelRouting()
    }
    override func didMoveToSuperview() { super.didMoveToSuperview(); updateWheelRouting() }
    override func layoutSubviews() { super.layoutSubviews(); updateWheelRouting() }
    /// The grid owns wheel zoom. Its UIScrollView still owns finger scrolling;
    /// only indirect scroll events are removed from that native pan recognizer.
    private func updateWheelRouting() {
        var parent = superview
        var candidate: UIScrollView?
        while let view = parent {
            if let scroll = view as? UIScrollView { candidate = scroll; break }
            parent = view.superview
        }
        if !active || window == nil { candidate = nil }
        if wheelScrollView !== candidate {
            restoreWheelRouting()
            wheelScrollView = candidate
            originalScrollTypes = candidate?.panGestureRecognizer.allowedScrollTypesMask
        }
        candidate?.panGestureRecognizer.allowedScrollTypesMask = []
    }
    private func restoreWheelRouting() {
        if let wheelScrollView, let originalScrollTypes {
            wheelScrollView.panGestureRecognizer.allowedScrollTypesMask = originalScrollTypes
        }
        wheelScrollView = nil; originalScrollTypes = nil
    }
    private func containsVisiblePoint(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { return false }
            if view.clipsToBounds && !view.bounds.contains(convert(point, to: view)) { return false }
            ancestor = view.superview
        }
        return true
    }
    func setEnabled(_ enabled: Bool, reset: UUID, capturesPointer: Bool = true) {
        if resetID != reset || active != enabled || self.capturesPointer != capturesPointer {
            pointer.isEnabled = false; scroll.isEnabled = false
            resetID = reset; active = enabled; self.capturesPointer = capturesPointer
            pointer.isEnabled = enabled && capturesPointer; scroll.isEnabled = enabled
        }
        updateWheelRouting()
    }
    func detach() {
        dragClock?.invalidate(); dragClock = nil
        restoreWheelRouting()
        owner?.removeGestureRecognizer(pointer); owner?.removeGestureRecognizer(scroll); owner = nil
    }
    deinit { dragClock?.invalidate() }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        IpadHardwareKeyboardFocus.permitsInput(in: self, enabled: active)
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard IpadHardwareKeyboardFocus.permitsInput(in: self, enabled: active), touch.type == .indirectPointer, containsVisiblePoint(touch.location(in: self)),
              accepts(touch.location(in: self)) else { return false }
        var view = touch.view
        while let candidate = view, candidate !== window {
            if candidate is UIControl || candidate is UITextView { return false }
            view = candidate.superview
        }
        return true
    }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        let point = recognizer.location(in: self)
        guard IpadHardwareKeyboardFocus.permitsInput(in: self, enabled: active),
              containsVisiblePoint(point), accepts(point) else { return false }
        var target = owner?.hitTest(convert(point, to: owner), with: nil)
        while let candidate = target, candidate !== owner {
            if candidate is UITextView || (recognizer === pointer && candidate is UIControl) { return false }
            target = candidate.superview
        }
        return true
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
    @objc private func pointerChanged(_ recognizer: IpadGridPointerRecognizer) {
        let phase: IpadTimelinePointerEvent.Phase
        switch recognizer.state {
        case .began:
            phase = .began
            dragClock?.invalidate()
            let clock = CADisplayLink(target: TickTarget(self), selector: #selector(TickTarget.tick))
            clock.preferredFramesPerSecond = 30; clock.add(to: .main, forMode: .common); dragClock = clock
        case .changed: phase = .moved
        case .ended: phase = .ended; dragClock?.invalidate(); dragClock = nil
        case .cancelled, .failed: phase = .cancelled; dragClock?.invalidate(); dragClock = nil
        default: return
        }
        event(.init(phase: phase, position: recognizer.location(in: self),
                    origin: convert(recognizer.origin, from: owner), secondary: recognizer.secondary,
                    modifiers: recognizer.modifiers))
    }
    private func dragTick() {
        guard pointer.state == .changed else { return }
        if !IpadHardwareKeyboardFocus.permitsInput(in: self, enabled: active) {
            pointer.isEnabled = false; pointer.isEnabled = active; return
        }
        guard wantsAutoScroll(pointer.location(in: self)) else { return }
        event(.init(phase: .moved, position: pointer.location(in: self), origin: convert(pointer.origin, from: owner),
                    secondary: pointer.secondary, modifiers: pointer.modifiers))
    }
    @objc private func wheelChanged(_ recognizer: UIPanGestureRecognizer) {
        guard IpadHardwareKeyboardFocus.permitsInput(in: self, enabled: active),
              [.began, .changed, .ended].contains(recognizer.state) else { return }
        let delta = recognizer.translation(in: self); recognizer.setTranslation(.zero, in: self)
        let point = recognizer.location(in: self)
        guard containsVisiblePoint(point), accepts(point) else { return }
        if delta != .zero { wheel(delta, .init(rawValue: UInt(bitPattern: recognizer.modifierFlags.rawValue))) }
    }
}

final class IpadGridPointerRecognizer: UIGestureRecognizer {
    private(set) var origin = CGPoint.zero
    private(set) var secondary = false
    private(set) var modifiers: HardwareKeyboardModifiers = []
    private func update(_ event: UIEvent) {
        var value: HardwareKeyboardModifiers = []
        if event.modifierFlags.contains(.shift) { value.insert(.shift) }
        if event.modifierFlags.contains(.command) { value.insert(.command) }
        if event.modifierFlags.contains(.control) { value.insert(.control) }
        if event.modifierFlags.contains(.alternate) { value.insert(.option) }
        modifiers = value
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, touch.type == .indirectPointer else { state = .failed; return }
        origin = touch.location(in: view); secondary = event.buttonMask.contains(.secondary); update(event)
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { update(event); state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { update(event); state = .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
}
#endif
