// Real UIKit header/control/focus regression. Device input is synthetic; shared
// header geometry and native multi-item mix handler are extracted unchanged.
import UIKit
import SwiftUI

struct TestFX { var inserted: [String] = [] }
struct AudioClip: Identifiable {
    var id: UUID; var name: String; var startTime: Double; var duration: Double
    var gain: Double?; var pan: Double?; var phaseInverted: Bool?; var muted: Bool?
    var fx: TestFX?; var fxBypassed: Bool?; var midi: Bool?
}
struct Track { enum Kind { case standard, special }; var kind = Kind.standard; var clips: [AudioClip] }
struct Song { var id = UUID(); var tracks: [Track] }
struct Project { var id = UUID() }
struct Snapshot { var project = Project() }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
@MainActor final class ControlMappings { static let shared = ControlMappings(); var editing: Int?; var transferRequest: Int? }
@MainActor final class TestShow {
    var current: Song?; var snapshot = Snapshot(); var allowed = true
    var gains: [UUID: Double] = [:]; var pans: [UUID: Double] = [:]; var commits = 0
    func canControl() -> Bool { allowed }
    func previewItemGain(_ id: UUID, gain: Double) { gains[id] = gain }
    func previewItemPan(_ id: UUID, pan: Double) { pans[id] = pan }
    func setItemGain(_ id: UUID, gain: Double) { commits += 1; gains[id] = gain }
    func setItemPan(_ id: UUID, pan: Double) { commits += 1; pans[id] = pan }
    func setItemsMix(_ ids: Set<UUID>, gain: Double? = nil, pan: Double? = nil) {
        commits += 1
        for id in ids { if let gain { gains[id] = gain }; if let pan { pans[id] = pan } }
    }
}
// MIX_MODEL
@MainActor final class TestScrolling {
    enum Scope { case tracks, grid, setlist }
    var selectionScope = Scope.tracks
    var itemSelection = TimelinePointerSelection()
    var itemMix: IpadNativeItemMix?
}
@MainActor final class MixHarness {
    var localShow: TestShow?
    let scrolling = TestScrolling()
    var state: (project: UUID, song: UUID)
    var editorEnabled = true
    init(_ show: TestShow) { localShow = show; state = (show.snapshot.project.id,show.current!.id) }
    // MIX_HANDLER
}
final class HeaderTouch: UITouch {
    let target: UIView; var point: CGPoint; var taps = 1
    init(_ target: UIView, _ point: CGPoint) { self.target = target; self.point = point; super.init() }
    override var view: UIView? { target }
    override var type: UITouch.TouchType { .indirectPointer }
    override var tapCount: Int { taps }
    override func location(in view: UIView?) -> CGPoint { target.convert(point, to: view) }
}
final class HeaderEvent: UIEvent {
    let buttons: UIEvent.ButtonMask
    init(_ buttons: UIEvent.ButtonMask = .primary) { self.buttons = buttons; super.init() }
    override var buttonMask: UIEvent.ButtonMask { buttons }
}
final class ResizePan: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .began
    var delta = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { sampleState } set { sampleState = newValue } }
    override func translation(in view: UIView?) -> CGPoint { delta }
}
@main final class App: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Tests", sessionRole: session.role); config.delegateClass = Scene.self; return config
    }
}
final class Scene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?; var started = false
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene); window.rootViewController = UIViewController()
        self.window = window; window.makeKeyAndVisible()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }; started = true
        Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); run() }
    }
    func run() {
        var failures: [String] = []; var count = 0
        func expect(_ value: Bool, _ description: String) { count += 1; if !value { failures.append(description) } }
        var first = AudioClip(id: UUID(), name: "Guide.wav", startTime: 0, duration: 10); first.gain = 1; first.pan = -0.3
        var second = AudioClip(id: UUID(), name: "Guitar.wav", startTime: 0, duration: 10); second.gain = 0.5; second.pan = 0.6
        let other = AudioClip(id: UUID(), name: "Other.wav", startTime: 0, duration: 10)
        let show = TestShow(); show.current = Song(tracks: [.init(clips: [first, second, other])])
        let harness = MixHarness(show); harness.scrolling.itemSelection.replace([first.id, second.id], anchor: first.id)
        let control = IpadItemHeaderControl(frame: CGRect(x: 50, y: 100, width: 600, height: GridSelectionItem.headerHeight))
        control.clip = first; control.interactionID = UUID()
        control.mix = { harness.updateNativeItemMix(first.id, $0, $1, $2, $3) }
        window!.rootViewController!.view.addSubview(control)
        var mutes = 0, phases = 0, effects = 0, menus = 0
        control.mute = { mutes += 1 }; control.phase = { phases += 1 }; control.fx = { effects += 1 }; control.menu = { menus += 1 }
        func geometry() -> GridSelectionItem {
            GridSelectionItem(id: first.id, rect: control.bounds, gain: first.gain ?? 1, pan: first.pan ?? 0, name: first.name)
        }
        func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        for width in [8.0, 24, 60, 100, 200, 400, 800] {
            control.frame.size.width = width
            let g = geometry()
            let rects = [g.gainKnobRect, g.gainLabelRect, g.muteRect, g.fxRect, g.phaseRect, g.panKnobRect, g.panLabelRect].compactMap { $0 }
            expect(rects.allSatisfy { control.bounds.contains($0) }, "Header control exceeds bounds at \(width)")
            for r in rects { expect(control.point(inside: center(r), with: nil), "Visible button cannot be clicked at \(width)") }
            if g.titleInset + 2 < width {
                expect(!control.point(inside: CGPoint(x: g.titleInset + 2,y: 8), with: nil), "Name prevents item drag at \(width)")
            }
            expect(!control.point(inside: CGPoint(x: 10,y: 25), with: nil), "Header captured item body")
        }
        control.frame.size.width = 600
        let g = geometry(), gain = HeaderTouch(control,center(geometry().gainKnobRect!))
        expect(control.beginTracking(gain, with: HeaderEvent()), "Gain knob refused primary press")
        gain.point.y -= 15; _ = control.continueTracking(gain, with: HeaderEvent())
        expect(show.commits == 0 && show.gains[first.id] == show.gains[second.id] && show.gains[first.id]! > 1, "Selected gains do not preview together before release")
        expect(show.gains[other.id] == nil && harness.scrolling.selectionScope == .grid, "Gain touched unselected item or kept track focus")
        let preview = harness.scrolling.itemMix!.applying(to: show.current!)
        expect(preview.tracks[0].clips[0].gain == preview.tracks[0].clips[1].gain && preview.tracks[0].clips[2].gain == nil, "Visual preview did not match selected audio gain")
        control.clip.gain = show.gains[first.id]
        gain.point.y -= 5; _ = control.continueTracking(gain, with: HeaderEvent())
        expect(abs(show.gains[first.id]! - g.draggingGain(by: -20)) < 0.0001, "Live redraw changed knob drag baseline")
        control.cancelTracking(with: nil)
        expect(show.commits == 0 && harness.scrolling.itemMix == nil && show.gains[first.id] == 1 && show.gains[second.id] == 0.5, "Cancelled gain failed to restore individual original values")
        control.clip = first
        let pan = HeaderTouch(control,center(geometry().panKnobRect!))
        expect(control.beginTracking(pan, with: HeaderEvent()), "Pan refused primary press")
        pan.point.y -= 12; _ = control.continueTracking(pan, with: HeaderEvent())
        expect(show.pans[first.id] == show.pans[second.id] && show.commits == 0, "Selected pans did not preview before release")
        control.endTracking(pan, with: HeaderEvent())
        expect(show.commits == 1 && harness.scrolling.itemMix == nil, "Pan release did not commit once")
        let button = HeaderTouch(control,center(geometry().muteRect!))
        _ = control.beginTracking(button, with: HeaderEvent()); control.endTracking(button, with: HeaderEvent())
        expect(mutes == 1, "Mute did not trigger on release")
        expect(!control.beginTracking(button, with: HeaderEvent(.secondary)) && menus == 1 && mutes == 1, "Right click activated mute")
        let phase = HeaderTouch(control,center(geometry().phaseRect!))
        _ = control.beginTracking(phase, with: HeaderEvent()); control.endTracking(phase, with: HeaderEvent())
        expect(phases == 1, "Phase control did not fire")
        let fx = HeaderTouch(control,center(geometry().fxRect!))
        _ = control.beginTracking(fx, with: HeaderEvent()); control.endTracking(fx, with: HeaderEvent())
        expect(effects == 1, "FX control did not fire")
        let double = HeaderTouch(control,center(geometry().gainKnobRect!)); double.taps = 2
        _ = control.beginTracking(double, with: HeaderEvent())
        expect(show.commits == 2 && show.gains[first.id] == 1 && show.gains[second.id] == 1, "Double click did not reset selected gains")
        let pending = HeaderTouch(control,center(geometry().gainKnobRect!))
        _ = control.beginTracking(pending, with: HeaderEvent()); pending.point.y -= 10
        _ = control.continueTracking(pending, with: HeaderEvent()); control.isEnabled = false
        expect(harness.scrolling.itemMix == nil && show.gains[second.id] == 0.5, "Disabled control left an audio preview active")
        control.endTracking(pending, with: HeaderEvent())
        expect(show.commits == 2 && !control.point(inside: center(geometry().gainKnobRect!), with: nil), "Disabled control committed or still captured input")
        control.isEnabled = true; pending.point = center(geometry().gainKnobRect!)
        _ = control.beginTracking(pending, with: HeaderEvent()); pending.point.y -= 10
        _ = control.continueTracking(pending, with: HeaderEvent()); control.interactionID = UUID()
        expect(harness.scrolling.itemMix == nil && show.commits == 2, "Project/interaction reset did not cancel knob")
        control.endTracking(pending, with: HeaderEvent())
        expect(show.commits == 2, "Ended reset gesture applied stale gain")
        let pointer = IpadTimelinePointerView(frame: window!.bounds); pointer.accepts = { _ in true }; pointer.setEnabled(true, reset: UUID())
        window!.rootViewController!.view.insertSubview(pointer, at: 0)
        let recognizer = window!.gestureRecognizers!.first { $0 is IpadGridPointerRecognizer }!
        let blocked = HeaderTouch(control, center(geometry().gainKnobRect!))
        expect(!pointer.gestureRecognizer(recognizer, shouldReceive: blocked), "Grid drag stole knob gesture")
        expect(window!.hitTest(control.convert(CGPoint(x: geometry().titleInset+5,y: 8), to: window), with: nil) !== control, "Header name fails UIKit pass-through hit test")
        pointer.detach(); pointer.removeFromSuperview()
        let resize = IpadItemResizeControl(frame: CGRect(x: 50,y: 200,width: 28,height: 80))
        window!.rootViewController!.view.addSubview(resize)
        var resized: [(Double,Bool,Bool)] = []
        resize.changed = { resized.append(($0,$1,$2)) }; resize.interactionID = UUID()
        let resizePan = ResizePan()
        func drag(_ state: UIGestureRecognizer.State, _ delta: Double = 0) {
            resizePan.sampleState = state; resizePan.delta.x = delta
            _ = resize.perform(NSSelectorFromString("dragged:"), with: resizePan)
        }
        drag(.began); drag(.changed, 24)
        expect(resized.count == 2 && resized.last!.0 == 24 && !resized.last!.1, "Resize does not preview during drag")
        drag(.ended, 30)
        expect(resized.count == 3 && resized.last!.0 == 30 && resized.last!.1 && !resized.last!.2, "Resize did not commit exactly on release")
        drag(.began); resize.interactionID = UUID()
        expect(resized.last!.1 && resized.last!.2, "Context change failed to cancel resize")
        let afterReset = resized.count; drag(.ended, 70)
        expect(resized.count == afterReset, "Mouse-up from old context resized new item")
        drag(.began); resize.isEnabled = false
        expect(resized.last!.2, "Disabled resize control kept pending drag")
        let afterDisabled = resized.count; drag(.changed, 80); drag(.ended, 80)
        expect(resized.count == afterDisabled, "Disabled resize committed stale change")
        resize.isEnabled = true
        drag(.began); resize.removeFromSuperview()
        expect(resized.last!.2, "Detaching resize handle left pending preview")
        let afterDetach = resized.count; drag(.ended, 80)
        expect(resized.count == afterDetach, "Detached resize committed stale change")
        window!.rootViewController!.view.addSubview(resize)
        let field = UITextField(frame: CGRect(x: 50,y: 350,width: 100,height: 40))
        window!.rootViewController!.view.addSubview(field); field.becomeFirstResponder()
        let beforeText = resized.count; drag(.began); drag(.ended, 80)
        expect(resized.count == beforeText, "Resize changed item during text editing")
        field.resignFirstResponder(); field.removeFromSuperview(); resize.removeFromSuperview()
        let output = failures.isEmpty ? "IPAD_ITEM_HEADER_UIKIT_OK assertions=\(count)" : "FAIL: " + failures.joined(separator: "; ")
        try! output.write(to: FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("result.txt"),atomically:true,encoding:.utf8)
        print(output)
    }
}
