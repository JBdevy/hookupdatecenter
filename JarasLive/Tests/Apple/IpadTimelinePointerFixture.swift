// Runs production pointer/focus adapters in a real UIKit window. Synthetic public
// UITouch/UIEvent subclasses supply device inputs; this is not a hardware E2E test.
import UIKit

@MainActor final class ControlMappings {
    static let shared = ControlMappings()
    var editing: Int?
    var transferRequest: Int?
}
final class PointerTouch: UITouch {
    let target: UIView
    var point: CGPoint
    let kind: UITouch.TouchType
    init(target: UIView, point: CGPoint, kind: UITouch.TouchType = .indirectPointer) {
        self.target = target; self.point = point; self.kind = kind; super.init()
    }
    override var view: UIView? { target }
    override var window: UIWindow? { target.window }
    override var type: UITouch.TouchType { kind }
    override func location(in view: UIView?) -> CGPoint {
        guard let view else { return point }
        return view.convert(point, from: target.window)
    }
}
final class PointerEvent: UIEvent {
    let flags: UIKeyModifierFlags
    let buttons: UIEvent.ButtonMask
    init(flags: UIKeyModifierFlags = [], buttons: UIEvent.ButtonMask = .primary) {
        self.flags = flags; self.buttons = buttons; super.init()
    }
    override var modifierFlags: UIKeyModifierFlags { flags }
    override var buttonMask: UIEvent.ButtonMask { buttons }
}
final class WheelRecognizer: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .changed
    var samplePoint = CGPoint.zero
    var delta = CGPoint.zero
    var flags: UIKeyModifierFlags = []
    override var state: UIGestureRecognizer.State { get { sampleState } set { sampleState = newValue } }
    override var modifierFlags: UIKeyModifierFlags { flags }
    override func location(in view: UIView?) -> CGPoint { samplePoint }
    override func translation(in view: UIView?) -> CGPoint { delta }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { delta = translation }
}
@main final class App: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Tests", sessionRole: session.role)
        config.delegateClass = Scene.self; return config
    }
}
final class Scene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var started = false
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .gray
        self.window = window; window.makeKeyAndVisible()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }; started = true
        Task { @MainActor in await run() }
    }
    func wait(_ seconds: Double = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    func run() async {
        await wait(0.3)
        let root = window!.rootViewController!
        let surface = UIView(frame: CGRect(x: 70, y: 90, width: 700, height: 500))
        root.view.addSubview(surface)
        let capture = IpadTimelinePointerView(frame: surface.bounds)
        capture.accepts = { $0.x >= 40 && $0.y >= 30 }
        capture.setEnabled(true, reset: UUID())
        surface.addSubview(capture)
        var failures: [String] = []
        var assertions = 0
        func expect(_ value: Bool, _ message: String) {
            assertions += 1; if !value { failures.append(message) }
        }
        func recognizers() -> [UIGestureRecognizer] {
            (window!.gestureRecognizers ?? []).filter { $0.delegate === capture }
        }
        expect(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSupportsIndirectInputEvents") as? Bool == true,
               "Bundle must opt into real indirect pointer events on iPadOS 16")
        let attached = recognizers()
        expect(attached.count == 2, "Pointer and wheel must attach once to the UIWindow")
        guard let pointer = attached.first(where: { $0 is IpadGridPointerRecognizer }) as? IpadGridPointerRecognizer,
              let scroll = attached.first(where: { $0 is UIPanGestureRecognizer }) as? UIPanGestureRecognizer else {
            write("FAIL: missing attached recognizers"); return
        }
        expect(pointer.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)], "Pointer consumes direct touch")
        expect(scroll.allowedTouchTypes.isEmpty && scroll.allowedScrollTypesMask == [.continuous, .discrete], "Wheel must accept both mouse and trackpad scrolling without stealing touch pan")
        expect(!scroll.cancelsTouchesInView, "Wheel cancels other controls")
        let point = surface.convert(CGPoint(x: 200, y: 150), to: window)
        let touch = PointerTouch(target: surface, point: point)
        expect(capture.gestureRecognizer(pointer, shouldReceive: touch), "Valid pointer rejected")
        expect(!capture.gestureRecognizer(pointer, shouldReceive: PointerTouch(target: surface, point: point, kind: .direct)), "Finger incorrectly enters pointer path")
        expect(!capture.gestureRecognizer(pointer, shouldReceive: PointerTouch(target: surface, point: point, kind: .pencil)), "Pencil incorrectly enters pointer path")
        expect(!capture.gestureRecognizer(pointer, shouldReceive: PointerTouch(target: surface, point: CGPoint(x: 10, y: 10))), "Outside point accepted")
        expect(!capture.gestureRecognizer(pointer, shouldReceive: PointerTouch(target: surface, point: surface.convert(CGPoint(x: 10, y: 10), to: window))), "Reserved header accepted")
        let control = UIButton(frame: CGRect(x: 100, y: 100, width: 100, height: 40))
        let label = UILabel(frame: control.bounds); control.addSubview(label); surface.addSubview(control)
        expect(!capture.gestureRecognizer(pointer, shouldReceive: PointerTouch(target: label, point: point)), "Nested UIControl child captured")
        let editor = UITextView(frame: CGRect(x: 100, y: 150, width: 100, height: 40)); surface.addSubview(editor)
        expect(!capture.gestureRecognizer(pointer, shouldReceive: PointerTouch(target: editor, point: point)), "UITextView captured")
        let protectedWheel = WheelRecognizer(); protectedWheel.samplePoint = CGPoint(x: 120, y: 120)
        expect(capture.gestureRecognizerShouldBegin(protectedWheel), "Grid wheel must zoom over item header controls")
        protectedWheel.samplePoint = CGPoint(x: 120, y: 170)
        expect(!capture.gestureRecognizerShouldBegin(protectedWheel), "Wheel captured a text view")
        protectedWheel.samplePoint = CGPoint(x: 10, y: 10)
        expect(!capture.gestureRecognizerShouldBegin(protectedWheel), "Wheel captured a reserved header")
        control.removeFromSuperview(); editor.removeFromSuperview()

        var events: [IpadTimelinePointerEvent] = []
        capture.event = { events.append($0) }
        // UIKit's internal touch bookkeeping is unavailable for synthetic public
        // UITouch instances. Test the real delegate separately above, then deliver
        // recognizer transitions directly without a fake zero-location delegate veto.
        pointer.delegate = nil
        let startEvent = PointerEvent(flags: [.command, .shift])
        pointer.touchesBegan([touch], with: startEvent)
        capture.perform(NSSelectorFromString("pointerChanged:"), with: pointer)
        expect(pointer.origin == point && !pointer.secondary, "Primary press lost origin/button")
        expect(pointer.modifiers == [.command, .shift], "Primary press lost modifiers")
        expect(events.last?.phase == .began && events.last?.origin == CGPoint(x: 200, y: 150), "Press callback lost phase or coordinate conversion")
        pointer.touchesMoved([touch], with: PointerEvent(flags: .alternate))
        capture.perform(NSSelectorFromString("pointerChanged:"), with: pointer)
        expect(events.last?.phase == .moved && events.last?.modifiers == .option, "Move did not refresh current modifiers")
        await wait()
        let centerEvents = events.count
        await wait(0.15)
        expect(events.count == centerEvents, "Stationary center drag must not generate autoscroll ticks")
        capture.wantsAutoScroll = { _ in true }
        await wait(0.15)
        expect(events.count > centerEvents, "Stationary edge drag did not keep autoscrolling")
        capture.wantsAutoScroll = { _ in false }
        pointer.touchesEnded([touch], with: PointerEvent())
        capture.perform(NSSelectorFromString("pointerChanged:"), with: pointer)
        expect(events.last?.phase == .ended && events.last?.modifiers.isEmpty == true, "Release callback missing or modifier stuck")
        capture.setEnabled(true, reset: UUID()); await wait()
        pointer.touchesBegan([touch], with: PointerEvent(flags: .control, buttons: .secondary))
        capture.perform(NSSelectorFromString("pointerChanged:"), with: pointer)
        expect(pointer.secondary && events.last?.secondary == true && events.last?.modifiers == .control, "Secondary press mistaken for primary")
        pointer.touchesCancelled([touch], with: PointerEvent(buttons: .secondary))
        capture.perform(NSSelectorFromString("pointerChanged:"), with: pointer)
        expect(events.last?.phase == .cancelled, "Cancellation not forwarded")
        capture.setEnabled(true, reset: UUID()); await wait()

        pointer.delegate = capture
        var wheels: [(CGPoint, HardwareKeyboardModifiers)] = []
        capture.wheel = { wheels.append(($0, $1)) }
        let wheel = WheelRecognizer(); wheel.samplePoint = CGPoint(x: 200, y: 150)
        expect(capture.gestureRecognizerShouldBegin(wheel), "Valid wheel rejected")
        wheel.samplePoint = CGPoint(x: -1, y: -1)
        expect(!capture.gestureRecognizerShouldBegin(wheel), "Outside wheel accepted")
        wheel.samplePoint = CGPoint(x: 200, y: 150)
        wheel.delta = CGPoint(x: 2, y: -15); wheel.flags = [.command, .shift]
        capture.perform(NSSelectorFromString("wheelChanged:"), with: wheel)
        expect(wheels.count == 1 && wheels.last?.0 == CGPoint(x: 2, y: -15), "Wheel delta not delivered")
        expect(wheels.last?.1 == [.command, .shift] && wheel.delta == .zero, "Wheel modifier stale or delta not consumed")
        capture.perform(NSSelectorFromString("wheelChanged:"), with: wheel)
        expect(wheels.count == 1, "Zero delta emitted a duplicate wheel event")
        wheel.flags = .alternate; wheel.delta = CGPoint(x: 0, y: 5)
        capture.perform(NSSelectorFromString("wheelChanged:"), with: wheel)
        expect(wheels.last?.1 == .option, "Wheel uses previous click modifiers")

        let field = UITextField(frame: CGRect(x: 50, y: 50, width: 200, height: 40)); surface.addSubview(field)
        field.becomeFirstResponder(); await wait()
        expect(field.isFirstResponder, "Text fixture could not acquire focus")
        expect(!capture.gestureRecognizer(pointer, shouldReceive: touch), "Pointer escaped active text editor")
        expect(!capture.gestureRecognizer(scroll, shouldReceive: PointerEvent()), "Wheel escaped active text editor")
        let beforeText = wheels.count; wheel.delta = CGPoint(x: 0, y: 20)
        capture.perform(NSSelectorFromString("wheelChanged:"), with: wheel)
        expect(wheels.count == beforeText, "Wheel callback escaped active text editor")
        field.resignFirstResponder(); field.removeFromSuperview(); await wait()
        expect(capture.gestureRecognizer(pointer, shouldReceive: touch), "Pointer did not resume after text editing")

        let modal = UIViewController(); modal.modalPresentationStyle = .formSheet
        await withCheckedContinuation { continuation in root.present(modal, animated: false) { continuation.resume() } }
        expect(!capture.gestureRecognizer(pointer, shouldReceive: touch), "Pointer escaped blocking modal")
        expect(!capture.gestureRecognizer(scroll, shouldReceive: PointerEvent()), "Wheel escaped blocking modal")
        let beforeModal = wheels.count
        capture.perform(NSSelectorFromString("wheelChanged:"), with: wheel)
        expect(wheels.count == beforeModal, "Wheel callback escaped blocking modal")
        ControlMappings.shared.editing = 1
        expect(!capture.gestureRecognizer(pointer, shouldReceive: touch), "Mapping learning bypassed pointer modal guard")
        ControlMappings.shared.editing = nil
        await withCheckedContinuation { continuation in root.dismiss(animated: false) { continuation.resume() } }

        let workspace = UIViewController(); workspace.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in root.present(workspace, animated: false) { continuation.resume() } }
        surface.removeFromSuperview(); workspace.view.addSubview(surface); await wait()
        expect(recognizers().count == 2, "Reattaching duplicated window recognizers")
        expect(capture.gestureRecognizer(pointer, shouldReceive: touch), "Presented fullscreen workspace was incorrectly blocked")
        capture.setEnabled(false, reset: UUID())
        expect(!pointer.isEnabled && !scroll.isEnabled, "Disabling did not disable recognizers")
        expect(!capture.gestureRecognizer(pointer, shouldReceive: touch), "Disabled pointer accepts input")
        let beforeDisabled = wheels.count
        capture.perform(NSSelectorFromString("wheelChanged:"), with: wheel)
        expect(wheels.count == beforeDisabled, "Disabled wheel callback accepted input")
        capture.setEnabled(true, reset: UUID()); capture.isHidden = true
        expect(!capture.gestureRecognizer(scroll, shouldReceive: PointerEvent()), "Hidden probe accepts wheel")
        capture.isHidden = false
        ControlMappings.shared.transferRequest = 1
        expect(!capture.gestureRecognizer(pointer, shouldReceive: touch), "Mapping transfer did not block pointer")
        ControlMappings.shared.transferRequest = nil
        capture.detach()
        expect(recognizers().isEmpty, "Detached probe leaked window recognizers")
        capture.removeFromSuperview()
        // Real nested scroll views reproduce the wheel-owner competition that a
        // flat UIView fixture cannot catch. Event payloads remain synthetic.
        let mixer = UIScrollView(frame: CGRect(x: 20, y: 100, width: 180, height: 300))
        let grid = UIScrollView(frame: CGRect(x: 220, y: 100, width: 400, height: 300))
        mixer.contentSize = CGSize(width: 180, height: 1400)
        grid.contentSize = CGSize(width: 400, height: 1400)
        mixer.panGestureRecognizer.allowedScrollTypesMask = [.continuous, .discrete]
        grid.panGestureRecognizer.allowedScrollTypesMask = [.continuous, .discrete]
        let mixerTouches = mixer.panGestureRecognizer.allowedTouchTypes
        let gridTouches = grid.panGestureRecognizer.allowedTouchTypes
        workspace.view.addSubview(mixer); workspace.view.addSubview(grid)
        let gridContent = UIView(frame: CGRect(origin: .zero, size: grid.contentSize))
        grid.addSubview(gridContent)
        let gridCapture = IpadTimelinePointerView(frame: gridContent.bounds)
        gridCapture.accepts = { _ in true }; gridCapture.setEnabled(true, reset: UUID())
        gridContent.addSubview(gridCapture)
        await wait()
        let owned = (window!.gestureRecognizers ?? []).filter { $0.delegate === gridCapture }
        let gridWheel = owned.first { $0 is UIPanGestureRecognizer }!
        let gridPointer = owned.first { $0 is IpadGridPointerRecognizer }!
        expect(grid.panGestureRecognizer.allowedScrollTypesMask.isEmpty, "Grid UIScrollView still competes for mouse/trackpad wheel")
        expect(mixer.panGestureRecognizer.allowedScrollTypesMask == [.continuous, .discrete], "Grid wheel policy disabled TrackMixer scrolling")
        expect(grid.isScrollEnabled && grid.panGestureRecognizer.isEnabled && grid.panGestureRecognizer.allowedTouchTypes == gridTouches,
               "Grid wheel policy disabled touch pan")
        expect(mixer.panGestureRecognizer.allowedTouchTypes == mixerTouches, "Grid wheel policy changed mixer touch input")
        grid.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        mixer.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        let nestedWheel = WheelRecognizer(); nestedWheel.samplePoint = CGPoint(x: 150, y: 400)
        var zoom = 1.0
        gridCapture.wheel = { delta, _ in zoom *= exp(Double(delta.y) * 0.009) }
        expect(gridCapture.gestureRecognizerShouldBegin(nestedWheel), "Visible grid wheel rejected after vertical scroll")
        nestedWheel.delta = CGPoint(x: 0, y: 20)
        gridCapture.perform(NSSelectorFromString("wheelChanged:"), with: nestedWheel)
        expect(zoom > 1 && grid.contentOffset.y == 300, "Grid wheel failed to zoom without vertical movement")
        nestedWheel.samplePoint = CGPoint(x: 150, y: 200)
        expect(!gridCapture.gestureRecognizerShouldBegin(nestedWheel), "Clipped grid content captured wheel outside viewport")
        nestedWheel.samplePoint = CGPoint(x: -100, y: 400)
        expect(!gridCapture.gestureRecognizerShouldBegin(nestedWheel), "Grid zoom captured wheel over TrackMixer")
        let finger = PointerTouch(target: gridContent, point: grid.convert(CGPoint(x: 150,y: 400), to: window), kind: .direct)
        expect(!gridCapture.gestureRecognizer(gridPointer, shouldReceive: finger), "Grid pointer intercepted touch scroll")
        expect(!gridCapture.gestureRecognizer(gridWheel, shouldRecognizeSimultaneouslyWith: grid.panGestureRecognizer),
               "Grid wheel simultaneously moves native vertical scroll")
        gridCapture.setEnabled(false, reset: UUID())
        expect(grid.panGestureRecognizer.allowedScrollTypesMask == [.continuous, .discrete], "Disabled grid input did not restore native wheel policy")
        gridCapture.setEnabled(true, reset: UUID())
        expect(grid.panGestureRecognizer.allowedScrollTypesMask.isEmpty, "Re-enabling grid input lost zoom wheel ownership")
        expect(mixer.panGestureRecognizer.allowedScrollTypesMask == [.continuous, .discrete], "Toggling grid input disabled mixer wheel")
        gridCapture.detach()
        expect(grid.panGestureRecognizer.allowedScrollTypesMask == [.continuous, .discrete], "Detaching grid pointer failed to restore native wheel policy")
        gridCapture.removeFromSuperview(); grid.removeFromSuperview(); mixer.removeFromSuperview()
        write(failures.isEmpty ? "IPAD_TIMELINE_POINTER_UIKIT_OK assertions=\(assertions)" : "FAIL: " + failures.joined(separator: "; "))
    }
    func write(_ output: String) {
        try! output.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(output)
    }
}
