#if os(iOS)
import SwiftUI
import UIKit
import ObjectiveC.runtime

/// The keyboard is an input view, not another text editor: selection, bindings,
/// secure entry, undo, delegates and physical-keyboard editing stay with UIKit.
struct IpadTextKeyboardScope: UIViewRepresentable {
    func makeUIView(context: Context) -> ScopeView { ScopeView() }
    func updateUIView(_ view: ScopeView, context: Context) {}
    final class ScopeView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { IpadTextKeyboard.install(in: window) }
        }
    }
}

@MainActor enum IpadTextKeyboard {
    private static let windows = NSHashTable<UIWindow>.weakObjects()
    private static var installed = false

    static func install(in window: UIWindow) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        if !installed {
            installed = true
            intercept(UITextField.self, #selector(UITextField.catLiveBecomeFirstResponder))
            intercept(UITextView.self, #selector(UITextView.catLiveBecomeFirstResponder))
        }
        guard !windows.contains(window) else { return }
        windows.add(window)
        let tap = IpadKeyboardOutsideTap(target: nil, action: nil)
        window.addGestureRecognizer(tap)
    }

    /// Install before UIKit requests an input view, including programmatic focus.
    /// Scope this to our iPad windows and leave Apple's file/share/color pickers alone.
    static func prepare(_ view: UIView) {
        guard let window = view.window, windows.contains(window) else { return }
        var responder: UIResponder? = view
        while let current = responder {
            if current is UIDocumentPickerViewController || current is UIDocumentBrowserViewController
                || current is UIActivityViewController || current is UIColorPickerViewController
                || current is UIImagePickerController { return }
            responder = current.next
        }
        if let field = view as? UITextField {
            guard field.inputView == nil || field.inputView is IpadTextKeyboardView else { return }
            if field.inputView == nil { field.inputView = IpadTextKeyboardView(target: field) }
            field.inputAssistantItem.leadingBarButtonGroups = []
            field.inputAssistantItem.trailingBarButtonGroups = []
        } else if let field = view as? UITextView, field.isEditable {
            guard field.inputView == nil || field.inputView is IpadTextKeyboardView else { return }
            if field.inputView == nil { field.inputView = IpadTextKeyboardView(target: field) }
            field.inputAssistantItem.leadingBarButtonGroups = []
            field.inputAssistantItem.trailingBarButtonGroups = []
        }
    }

    private static func intercept(_ type: AnyClass, _ replacement: Selector) {
        let original = #selector(UIResponder.becomeFirstResponder)
        guard let before = class_getInstanceMethod(type, original),
              let after = class_getInstanceMethod(type, replacement) else { return }
        // Never exchange the implementation on a shared superclass.
        if class_addMethod(type, original, method_getImplementation(after), method_getTypeEncoding(after)) {
            class_replaceMethod(type, replacement, method_getImplementation(before), method_getTypeEncoding(before))
        } else { method_exchangeImplementations(before, after) }
    }
}

private extension UITextField {
    @objc func catLiveBecomeFirstResponder() -> Bool {
        IpadTextKeyboard.prepare(self)
        return catLiveBecomeFirstResponder()
    }
}
private extension UITextView {
    @objc func catLiveBecomeFirstResponder() -> Bool {
        IpadTextKeyboard.prepare(self)
        return catLiveBecomeFirstResponder()
    }
}

/// Does not cancel the tap: Save, sliders and other app controls still act once.
private final class IpadKeyboardOutsideTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        addTarget(self, action: #selector(closeKeyboard))
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    @objc private func closeKeyboard() { view?.endEditing(false) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var ancestor = touch.view
        while let view = ancestor {
            if view is UITextField || view is UITextView || view is IpadTextKeyboardView { return false }
            ancestor = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

struct IpadKeyboardShift {
    enum Mode { case off, once, locked }
    private(set) var mode = Mode.off
    private var lastTap: TimeInterval?
    mutating func tap(at time: TimeInterval) {
        if mode == .once, let lastTap, time - lastTap < 0.35 { mode = .locked; self.lastTap = nil }
        else { mode = mode == .off ? .once : .off; lastTap = time }
    }
    mutating func consume() { if mode == .once { mode = .off }; lastTap = nil }
    func text(_ text: String) -> String {
        guard mode != .off else { return text }
        let symbols = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
                       "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "\\": "|", "`": "~"]
        return symbols[text] ?? text.uppercased()
    }
}

final class IpadTextKeyboardView: UIInputView {
    private enum Page { case letters, numbers, symbols, accents }
    private weak var target: UIView?
    private var input: (any UITextInput)? { target as? any UITextInput }
    private var page = Page.letters
    private var shift = IpadKeyboardShift()
    private var selectionAnchor: Int?
    private var rows: [UIStackView] = []
    private var characterKeys: [(UIButton, String)] = []
    private var shiftButton: UIButton?
    private var deleteTimer: Timer?
    private var accentHost: UIStackView?
    private var accentSelection: UIButton?
    private let container = UIStackView()
    private let keyColor = UIColor(white: 0.26, alpha: 1)
    private let green = UIColor(red: 0.39, green: 0.75, blue: 0.26, alpha: 1)
    private let keyboardHeight: CGFloat = 222

    init(target: UIView) {
        self.target = target
        if let traits = target as? any UITextInputTraits,
           [.numberPad, .decimalPad, .phonePad, .numbersAndPunctuation, .asciiCapableNumberPad].contains(traits.keyboardType ?? .default) {
            page = .numbers
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 768, height: keyboardHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = UIColor(white: 0.10, alpha: 1)
        accessibilityIdentifier = "catlive-text-keyboard"
        container.axis = .vertical; container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 1000),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        let preferredWidth = container.widthAnchor.constraint(equalTo: widthAnchor, constant: -20)
        preferredWidth.priority = .defaultHigh; preferredWidth.isActive = true
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
                                         verticalFittingPriority vertical: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: keyboardHeight)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stopRepeating(); hideAccents() } }
    deinit { deleteTimer?.invalidate() }

    private func rebuild() {
        stopRepeating(); hideAccents(); rows.removeAll(); characterKeys.removeAll(); shiftButton = nil
        for view in container.arrangedSubviews { container.removeArrangedSubview(view); view.removeFromSuperview() }
        let tools = row(height: 28)
        add("Selecionar", id: "select-all", to: tools) { [weak self] in
            guard let self, let input else { return }
            input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        }
        add("Recortar", id: "cut", to: tools) { [weak self] in self?.cutSelection() }
        add("Copiar", id: "copy", to: tools) { [weak self] in self?.copySelection() }
        add("Colar", id: "paste", to: tools) { [weak self] in self?.insert(UIPasteboard.general.string ?? "", applyShift: false) }
        add("↶", id: "undo", to: tools, label: "Desfazer") { [weak self] in self?.target?.undoManager?.undo() }
        add("↷", id: "redo", to: tools, label: "Refazer") { [weak self] in self?.target?.undoManager?.redo() }
        add("←", id: "left", to: tools, label: "Cursor para esquerda") { [weak self] in self?.moveCursor(-1) }
        add("→", id: "right", to: tools, label: "Cursor para direita") { [weak self] in self?.moveCursor(1) }
        add("⇤", id: "home", to: tools, label: "Início do texto") { [weak self] in self?.moveToEnd(false) }
        add("⇥", id: "end", to: tools, label: "Fim do texto") { [weak self] in self?.moveToEnd(true) }
        add("Fechar", id: "close", to: tools) { [weak self] in self?.target?.resignFirstResponder() }

        let digits = row(height: 30)
        for key in Array("1234567890").map(String.init) { character(key, to: digits) }
        let delete = add("⌫", id: "delete", to: digits, label: "Apagar") { [weak self] in self?.input?.deleteBackward() }
        let repeatDelete = UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:)))
        repeatDelete.minimumPressDuration = 0.4; delete.addGestureRecognizer(repeatDelete)

        let lines: [[String]]
        switch page {
        case .letters: lines = [Array("qwertyuiop").map(String.init), Array("asdfghjklç").map(String.init), Array("zxcvbnm").map(String.init)]
        case .numbers: lines = [["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], ["+", "=", "_", "\\", "[", "]", "%", "*", "#", "'"], [".", ",", "?", "!", "€", "£", "°"]]
        case .symbols: lines = [["{", "}", "<", ">", "^", "~", "`", "|", "•", "…"], ["§", "±", "×", "÷", "√", "∞", "©", "®", "™", "✓"], ["♭", "♯", "♪", "º", "ª", "¿", "¡"]]
        case .accents: lines = [Array("áàâãäåéèêë").map(String.init), Array("íìîïóòôõöø").map(String.init), Array("úùûüçñý").map(String.init)]
        }
        for (index, keys) in lines.enumerated() {
            let line = row(height: 34)
            if index == 2 {
                shiftButton = add("⇧", id: "shift", to: line, label: "Shift") { [weak self] in
                    guard let self else { return }; shift.tap(at: ProcessInfo.processInfo.systemUptime); updateShift()
                }
            }
            for key in keys { character(key, to: line) }
            if index == 2 && (page == .letters || page == .accents) { character(".", to: line); character(",", to: line) }
        }
        let bottom = row(height: 30)
        add(page == .letters ? "123" : "ABC", id: "page", to: bottom) { [weak self] in
            guard let self else { return }; page = page == .letters ? .numbers : .letters; rebuild()
        }
        add("#+=", id: "symbols", to: bottom) { [weak self] in self?.page = .symbols; self?.rebuild() }
        add("áéí", id: "accents", to: bottom, label: "Acentos") { [weak self] in self?.page = .accents; self?.rebuild() }
        let space = add("Espaço", id: "space", to: bottom) { [weak self] in self?.insert(" ", applyShift: false) }
        bottom.distribution = .fill
        let enter = add(target is UITextView ? "Nova linha" : "Concluir", id: "return", to: bottom) { [weak self] in self?.submit() }
        for view in bottom.arrangedSubviews where view !== space { view.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.14).isActive = true }
        enter.backgroundColor = green.withAlphaComponent(0.6)
        updateShift()
    }
    private func row(height: CGFloat) -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 4; row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        container.addArrangedSubview(row); rows.append(row); return row
    }
    @discardableResult private func add(_ title: String, id: String, to row: UIStackView, label: String? = nil,
                                        action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal); button.setTitleColor(.white, for: .normal)
        if id == "undo" || id == "redo" {
            button.setTitle(nil, for: .normal)
            button.setImage(UIImage(systemName: id == "undo" ? "arrow.uturn.backward" : "arrow.uturn.forward"), for: .normal)
            button.tintColor = .white
        }
        button.titleLabel?.font = .systemFont(ofSize: row === rows.first ? 13 : 17, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true; button.titleLabel?.minimumScaleFactor = 0.7
        button.backgroundColor = keyColor; button.layer.cornerRadius = 5
        button.accessibilityIdentifier = "cat-key-" + id; button.accessibilityLabel = label ?? title
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        row.addArrangedSubview(button); return button
    }
    private func character(_ text: String, to row: UIStackView) {
        let button = add(text, id: text, to: row) { [weak self] in self?.insert(text) }
        characterKeys.append((button, text))
        if Self.accents[text] != nil {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(accentPress(_:)))
            press.minimumPressDuration = 0.4; button.addGestureRecognizer(press)
        }
    }
    private func updateShift() {
        shiftButton?.setTitle(shift.mode == .locked ? "⇪" : "⇧", for: .normal)
        shiftButton?.backgroundColor = shift.mode == .off ? keyColor : green
        shiftButton?.accessibilityValue = shift.mode == .off ? "Desativado" : shift.mode == .once ? "Próxima letra" : "Maiúsculas fixas"
        for (button, text) in characterKeys { button.setTitle(shift.text(text), for: .normal) }
    }
    private func insert(_ text: String, applyShift: Bool = true) {
        guard !text.isEmpty, let input else { return }
        input.insertText(applyShift ? shift.text(text) : text)
        hideAccents()
        selectionAnchor = nil
        if applyShift { shift.consume(); updateShift() }
    }
    private func submit() {
        // Use the same text-input path as a hardware Return. Calling a delegate
        // directly bypasses SwiftUI's submit action on some iPadOS versions.
        insert("\n", applyShift: false)
    }
    private func copySelection() {
        guard (target as? UITextField)?.isSecureTextEntry != true,
              let input, let range = input.selectedTextRange, let text = input.text(in: range), !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
    private func cutSelection() {
        guard (target as? UITextField)?.isSecureTextEntry != true else { return }
        copySelection()
        if let range = input?.selectedTextRange, !range.isEmpty { input?.insertText("") }
    }
    private func moveCursor(_ offset: Int) {
        guard let input, let range = input.selectedTextRange else { return }
        if shift.mode == .off {
            selectionAnchor = nil
            let position = offset < 0 ? range.start : range.end
            let next = range.isEmpty ? input.position(from: position, offset: offset) ?? position : position
            input.selectedTextRange = input.textRange(from: next, to: next)
        } else {
            let start = input.offset(from: input.beginningOfDocument, to: range.start)
            let end = input.offset(from: input.beginningOfDocument, to: range.end)
            let anchor = selectionAnchor ?? (offset < 0 ? end : start); selectionAnchor = anchor
            let edge = anchor == start ? range.end : range.start
            guard let next = input.position(from: edge, offset: offset),
                  let fixed = input.position(from: input.beginningOfDocument, offset: anchor) else { return }
            let nextOffset = input.offset(from: input.beginningOfDocument, to: next)
            input.selectedTextRange = input.textRange(from: nextOffset < anchor ? next : fixed, to: nextOffset < anchor ? fixed : next)
        }
    }
    private func moveToEnd(_ end: Bool) {
        guard let input, let range = input.selectedTextRange else { return }
        let destination = end ? input.endOfDocument : input.beginningOfDocument
        if shift.mode == .off { input.selectedTextRange = input.textRange(from: destination, to: destination) }
        else { input.selectedTextRange = input.textRange(from: end ? range.start : destination, to: end ? destination : range.end) }
        selectionAnchor = nil
    }
    @objc private func repeatDelete(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            input?.deleteBackward()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in self?.input?.deleteBackward() }
        } else if [.ended, .failed, .cancelled].contains(gesture.state) { stopRepeating() }
    }
    private func stopRepeating() { deleteTimer?.invalidate(); deleteTimer = nil }
    private static let accents = ["a": "áàâãäå", "e": "éèêë", "i": "íìîï", "o": "óòôõöø", "u": "úùûü", "c": "ç", "n": "ñ", "y": "ýÿ"]
    @objc private func accentPress(_ gesture: UILongPressGestureRecognizer) {
        guard let key = gesture.view as? UIButton else { return }
        switch gesture.state {
        case .began:
            guard let base = characterKeys.first(where: { $0.0 === key })?.1, let variants = Self.accents[base] else { return }
            hideAccents()
            let host = UIStackView(); host.spacing = 4; host.distribution = .fillEqually; host.backgroundColor = backgroundColor
            host.layer.cornerRadius = 6; host.isLayoutMarginsRelativeArrangement = true; host.layoutMargins = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            let frame = key.convert(key.bounds, to: self)
            let width = CGFloat(variants.count + 1) * 42 + 8
            host.frame = CGRect(x: max(6, min(bounds.width - width - 6, frame.midX - width / 2)), y: max(0, frame.minY - 46), width: width, height: 42)
            for value in [base] + variants.map(String.init) {
                let button = add(shift.text(value), id: "accent-" + value, to: host) { [weak self] in self?.insert(value); self?.hideAccents() }
                button.accessibilityValue = value
            }
            addSubview(host); accentHost = host
        case .changed:
            guard let host = accentHost else { return }
            let point = gesture.location(in: host)
            accentSelection = host.arrangedSubviews.compactMap { $0 as? UIButton }.first { $0.frame.contains(point) }
            for case let button as UIButton in host.arrangedSubviews { button.backgroundColor = button === accentSelection ? green : keyColor }
        case .ended:
            if let text = accentSelection?.accessibilityValue { insert(text); hideAccents() }
            // Keeping the strip open also permits a second tap or pointer click.
        case .cancelled, .failed: hideAccents()
        default: break
        }
    }
    private func hideAccents() { accentHost?.removeFromSuperview(); accentHost = nil; accentSelection = nil }
}
#endif
