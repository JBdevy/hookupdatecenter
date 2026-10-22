#if os(iOS)
import SwiftUI
import UIKit

@MainActor enum IpadHardwareKeyboardFocus {
    static func permitsInput(in view: UIView, enabled: Bool = true, allowsMappingLearning: Bool = false) -> Bool {
        guard let window = view.window, window.isKeyWindow, !view.isHidden,
              window.windowScene?.activationState == .foregroundActive else { return false }
        var parent = window.catliveKeyboardFirstResponder
        var textEditing = false
        while let responder = parent {
            if responder is UITextInput { textEditing = true; break }
            parent = responder.next
        }
        let mappings = ControlMappings.shared
        let presentation = window.rootViewController?.catliveFrontmostKeyboardPresentation
        let covered = presentation.map { controller in
            controller.viewIfLoaded.map { !view.isDescendant(of: $0) } ?? true
        } ?? false
        return HardwareKeyboardFocusContext(enabled: enabled,
            applicationActive: UIApplication.shared.applicationState == .active,
            textEditing: textEditing, modalPresented: covered,
            learningMapping: allowsMappingLearning && mappings.editing != nil && !(presentation is UIAlertController),
            transferringMapping: mappings.transferRequest != nil).permitsShortcuts
    }
}

/// Background responder for the native workspace. It observes pointer activity
/// without replacing the grid's gestures and yields to text fields and sheets.
struct IpadHardwareKeyboard: UIViewRepresentable {
    var enabled = true
    var onKey: (HardwareKeyboardEvent) -> Bool
    var onModifiersChanged: (HardwareKeyboardModifiers) -> Void = { _ in }

    func makeUIView(context: Context) -> IpadHardwareKeyboardView { IpadHardwareKeyboardView() }
    func updateUIView(_ view: IpadHardwareKeyboardView, context: Context) {
        view.onKey = onKey; view.onModifiersChanged = onModifiersChanged
        view.keyboardEnabled = enabled
        view.scheduleFocus()
    }
    static func dismantleUIView(_ view: IpadHardwareKeyboardView, coordinator: ()) { view.detach() }
}

final class IpadHardwareKeyboardView: UIView {
    var onKey: (HardwareKeyboardEvent) -> Bool = { _ in false }
    var onModifiersChanged: (HardwareKeyboardModifiers) -> Void = { _ in }
    var keyboardEnabled = true {
        didSet {
            guard oldValue != keyboardEnabled, !keyboardEnabled else { return }
            stopRepeating()
            // updateUIView can disable capture while SwiftUI is presenting a
            // dialog. Publish the modifier reset outside that view update.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.keyboardEnabled else { return }
                self.releaseKeys()
                if self.isFirstResponder { _ = self.resignFirstResponder() }
            }
        }
    }
    private var modifiers: HardwareKeyboardModifiers = []
    private var pressed = Set<Int>()
    private var handled = Set<Int>()
    private var repeating: (usage: Int, event: HardwareKeyboardEvent)?
    private var repeatTimer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var focusPending = false
    private weak var observedWindow: UIWindow?
    private var pointerObserver: IpadKeyboardPointerObserver?

    override var canBecomeFirstResponder: Bool { keyboardEnabled }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window !== observedWindow else { return }
        detach()
        guard let window else { return }
        observedWindow = window
        let observer = IpadKeyboardPointerObserver()
        observer.cancelsTouchesInView = false; observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
        observer.allowedPressTypes = []
        observer.observe = { [weak self] point, flags in
            guard let self, let window = self.window,
                  self.convert(self.bounds, to: window).contains(point) else { return }
            self.setModifiers(.init(rawValue: UInt(bitPattern: flags.rawValue)))
            self.scheduleFocus()
        }
        window.addGestureRecognizer(observer); pointerObserver = observer
        for name in [UIApplication.didBecomeActiveNotification, UIWindow.didBecomeKeyNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFocus() }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseKeys() }
            })
        scheduleFocus()
    }
    func detach() {
        if let observer = pointerObserver { observedWindow?.removeGestureRecognizer(observer) }
        pointerObserver = nil; observedWindow = nil
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        releaseKeys(deferModifiers: true)
    }
    func scheduleFocus() {
        guard !focusPending, !isFirstResponder else { return }
        focusPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusPending = false
            guard self.permitsShortcuts else { self.releaseKeys(); return }
            if !self.isFirstResponder { _ = self.becomeFirstResponder() }
        }
    }
    private var permitsShortcuts: Bool {
        IpadHardwareKeyboardFocus.permitsInput(in: self, enabled: keyboardEnabled, allowsMappingLearning: true)
    }
    private func setModifiers(_ value: HardwareKeyboardModifiers) {
        guard modifiers != value else { return }
        modifiers = value; onModifiersChanged(value)
    }
    private func releaseKeys(deferModifiers: Bool = false) {
        stopRepeating(); pressed.removeAll(); handled.removeAll()
        if deferModifiers, !modifiers.isEmpty {
            modifiers = []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.modifiers.isEmpty else { return }
                self.onModifiersChanged([])
            }
        } else { setModifiers([]) }
    }
    private func stopRepeating() { repeatTimer?.invalidate(); repeatTimer = nil; repeating = nil }
    private func beginRepeating(usage: Int, event: HardwareKeyboardEvent) {
        stopRepeating(); repeating = (usage, event)
        // Raw UIPress events provide physical press/release, not text-system
        // autorepeat. Only handled keys repeat; Actions decide which may execute.
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let repeating = self.repeating else { return }
                guard self.permitsShortcuts, self.isFirstResponder, self.pressed.contains(repeating.usage) else {
                    self.releaseKeys(); return
                }
                var event = repeating.event; event.isRepeat = true
                if !self.onKey(event) { self.stopRepeating() }
            }
        }
        timer.fireDate = Date(timeIntervalSinceNow: 0.42)
        repeatTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func updateModifiers(_ key: UIKey, down: Bool) {
        var next = HardwareKeyboardModifiers(rawValue: UInt(bitPattern: key.modifierFlags.rawValue))
        let usage = key.keyCode.rawValue
        let pairs: [(Int, Int, HardwareKeyboardModifiers)] = [
            (0xe0, 0xe4, .control), (0xe1, 0xe5, .shift), (0xe2, 0xe6, .option), (0xe3, 0xe7, .command)
        ]
        for (left, right, flag) in pairs where usage == left || usage == right {
            if down || pressed.contains(usage == left ? right : left) { next.insert(flag) }
            else { next.remove(flag) }
        }
        setModifiers(next)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard permitsShortcuts else { releaseKeys(); super.pressesBegan(presses, with: event); return }
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let usage = key.keyCode.rawValue
            updateModifiers(key, down: true)
            let firstPress = self.pressed.insert(usage).inserted
            guard let input = HardwareKeyboardInput.event(hidUsage: usage, modifierFlags: modifiers.rawValue,
                                                          characters: key.charactersIgnoringModifiers) else {
                unhandled.insert(press); continue
            }
            if input.isModifier { stopRepeating(); unhandled.insert(press); continue }
            if !firstPress {
                if !handled.contains(usage) { unhandled.insert(press) }
                continue
            }
            if onKey(input) {
                handled.insert(usage); beginRepeating(usage: usage, event: input)
            } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let usage = key.keyCode.rawValue
            self.pressed.remove(usage); updateModifiers(key, down: false)
            if repeating?.usage == usage { stopRepeating() }
            let wasHandled = handled.remove(usage) != nil
            if permitsShortcuts, let input = HardwareKeyboardInput.event(hidUsage: usage,
                modifierFlags: modifiers.rawValue, characters: key.charactersIgnoringModifiers, phase: .up) { _ = onKey(input) }
            if !wasHandled { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseKeys(); super.pressesCancelled(presses, with: event)
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { releaseKeys(deferModifiers: true) }
        return result
    }
    deinit {
        repeatTimer?.invalidate()
        notifications.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class IpadKeyboardPointerObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var observe: (CGPoint, UIKeyModifierFlags) -> Void = { _, _ in }
    override init(target: Any?, action: Selector?) { super.init(target: target, action: action); delegate = self }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { observe(touch.location(in: view), modifierFlags) }
        // It never recognizes a gesture or delays another recognizer.
        state = .failed
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

private extension UIView {
    var catliveKeyboardFirstResponder: UIResponder? {
        if isFirstResponder { return self }
        for child in subviews { if let responder = child.catliveKeyboardFirstResponder { return responder } }
        return nil
    }
}
private extension UIViewController {
    var catliveFrontmostKeyboardPresentation: UIViewController? {
        if let presentedViewController {
            return presentedViewController.catliveFrontmostKeyboardPresentation ?? presentedViewController
        }
        for child in children.reversed() {
            if let presented = child.catliveFrontmostKeyboardPresentation { return presented }
        }
        return nil
    }
}
#endif
