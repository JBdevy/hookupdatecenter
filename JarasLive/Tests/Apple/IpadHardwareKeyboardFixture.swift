// Standalone UIKit responder regression app; built by test-ipad-hardware-keyboard.sh.
import UIKit
@MainActor final class ControlMappings { static let shared = ControlMappings(); var editing: Int?; var transferRequest: Int? }
final class ProbeKey: UIKey {
    let usage: UIKeyboardHIDUsage; let flags: UIKeyModifierFlags; let text: String
    init(_ usage: Int, flags: UIKeyModifierFlags = [], text: String = "") { self.usage = UIKeyboardHIDUsage(rawValue: usage)!; self.flags = flags; self.text = text; super.init() }
    required init?(coder: NSCoder) { fatalError() }
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var modifierFlags: UIKeyModifierFlags { flags }
    override var charactersIgnoringModifiers: String { text }
    override var characters: String { text }
}
final class ProbePress: UIPress {
    let probeKey: UIKey
    init(_ key: UIKey) { probeKey = key; super.init() }
    override var key: UIKey? { probeKey }
}
@main final class App: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Tests", sessionRole: session.role); config.delegateClass = Scene.self; return config
    }
}
final class Scene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?; var started = false
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene); window.rootViewController = UIViewController(); window.rootViewController?.view.backgroundColor = .gray
        self.window = window; window.makeKeyAndVisible()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }; started = true
        Task { @MainActor in await run() }
    }
    func wait(_ seconds: Double = 0.1) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func run() async {
        await wait(0.5)
        let root = window!.rootViewController!, capture = IpadHardwareKeyboardView(frame: window!.bounds)
        var events: [HardwareKeyboardEvent] = []; var modifiers: HardwareKeyboardModifiers = []
        capture.onKey = { event in events.append(event); return !event.isModifier }
        capture.onModifiersChanged = { modifiers = $0 }
        root.view.addSubview(capture); capture.scheduleFocus(); await wait()
        var failures: [String] = []
        func expect(_ result: Bool, _ message: String) { if !result { failures.append(message) } }
        expect(capture.isFirstResponder, "Workspace should acquire keyboard automatically")
        let space = ProbePress(ProbeKey(0x2c, text: " "))
        capture.pressesBegan([space], with: nil); await wait(0.58)
        expect(events.contains { $0.keyCode == 49 && $0.phase == .down && !$0.isRepeat }, "Initial key missing")
        expect(events.contains { $0.keyCode == 49 && $0.isRepeat }, "Held key did not repeat")
        capture.pressesEnded([space], with: nil)
        let releasedCount = events.count; await wait(0.15)
        expect(events.count == releasedCount, "Released key kept repeating")
        let shift = ProbePress(ProbeKey(0xe1, flags: .shift))
        capture.pressesBegan([shift], with: nil); expect(modifiers == .shift, "Shift not published")
        capture.pressesEnded([shift], with: nil); expect(modifiers.isEmpty, "Shift stuck after release")
        let field = UITextField(frame: CGRect(x: 10, y: 10, width: 200, height: 40)); root.view.addSubview(field)
        field.becomeFirstResponder(); capture.scheduleFocus(); await wait()
        expect(field.isFirstResponder, "Stole text editing focus")
        let beforeText = events.count; capture.pressesBegan([space], with: nil)
        expect(events.count == beforeText, "Transport action escaped text guard")
        field.resignFirstResponder(); capture.scheduleFocus(); await wait()
        expect(capture.isFirstResponder, "Keyboard did not resume after text editing")
        let modal = UIViewController(); modal.modalPresentationStyle = .formSheet
        await withCheckedContinuation { continuation in root.present(modal, animated: false) { continuation.resume() } }; await wait()
        expect(!IpadHardwareKeyboardFocus.permitsInput(in: capture), "Covered workspace accepted keys")
        let beforeModal = events.count; capture.pressesBegan([space], with: nil)
        expect(events.count == beforeModal, "Transport action escaped modal guard")
        await withCheckedContinuation { continuation in root.dismiss(animated: false) { continuation.resume() } }; await wait()
        let workspace = UIViewController(); workspace.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in root.present(workspace, animated: false) { continuation.resume() } }; await wait()
        capture.removeFromSuperview(); capture.frame = workspace.view.bounds; workspace.view.addSubview(capture)
        capture.scheduleFocus(); await wait()
        expect(IpadHardwareKeyboardFocus.permitsInput(in: capture), "Fullscreen workspace was mistaken for blocking modal: window=\(capture.window != nil) key=\(capture.window?.isKeyWindow == true) scene=\(String(describing:capture.window?.windowScene?.activationState)) present=\(String(describing:root.presentedViewController)) correct=\(root.presentedViewController === workspace) descendant=\(capture.isDescendant(of: workspace.view)) hidden=\(capture.isHidden)")
        expect(capture.isFirstResponder, "Fullscreen workspace could not capture keyboard")
        ControlMappings.shared.editing = 1
        let alert = UIAlertController(title: "Confirm", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); await withCheckedContinuation { continuation in workspace.present(alert, animated: false) { continuation.resume() } }; await wait()
        expect(!IpadHardwareKeyboardFocus.permitsInput(in: capture, allowsMappingLearning: true), "Learning bypassed confirmation alert")
        await withCheckedContinuation { continuation in workspace.dismiss(animated: false) { continuation.resume() } }; ControlMappings.shared.editing = nil; await wait()
        capture.keyboardEnabled = false; capture.scheduleFocus(); await wait()
        expect(!capture.isFirstResponder, "Disabled adapter retained focus")
        let output = failures.isEmpty ? "IPAD_HARDWARE_KEYBOARD_UIKIT_FOCUS_REPEAT_MODIFIERS_MODAL_OK" : "FAIL: " + failures.joined(separator: "; ")
        try! output.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(output)
    }
}
