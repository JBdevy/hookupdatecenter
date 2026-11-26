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
                       "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", ",": "!", ".": "?", "/": "?", "\\": "|", "`": "~"]
        return symbols[text] ?? text.uppercased()
    }
}

final class IpadTextKeyboardView: UIInputView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private enum Page { case letters, numbers, symbols, emoji }
    private weak var target: UIView?
    private var input: (any UITextInput)? { target as? any UITextInput }
    private var page = Page.letters
    private var shift = IpadKeyboardShift()
    private var selectionAnchor: Int?
    private var rows: [UIStackView] = []
    private var characterKeys: [(UIButton, String)] = []
    private var shiftButtons: [UIButton] = []
    private var deleteTimer: Timer?
    private var accentHost: UIStackView?
    private var accentSelection: UIButton?
    private let container = UIStackView()
    private let keyColor = UIColor(white: 0.40, alpha: 1)
    private let specialKeyColor = UIColor(white: 0.27, alpha: 1)
    private let green = UIColor(red: 0.39, green: 0.75, blue: 0.26, alpha: 1)
    private let keyboardHeight: CGFloat = 248

    init(target: UIView) {
        self.target = target
        if let traits = target as? any UITextInputTraits,
           [.numberPad, .decimalPad, .phonePad, .numbersAndPunctuation, .asciiCapableNumberPad].contains(traits.keyboardType ?? .default) {
            page = .numbers
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 768, height: keyboardHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = UIColor(white: 0.16, alpha: 1)
        accessibilityIdentifier = "catlive-text-keyboard"
        container.axis = .vertical; container.spacing = 5
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 980),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        let preferredWidth = container.widthAnchor.constraint(equalTo: widthAnchor, constant: -16)
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
        stopRepeating(); hideAccents(); rows.removeAll(); characterKeys.removeAll(); shiftButtons.removeAll()
        for view in container.arrangedSubviews { container.removeArrangedSubview(view); view.removeFromSuperview() }
        let tools = row(height: 26)
        tools.distribution = .fill
        add("↶", id: "undo", to: tools, label: "Desfazer") { [weak self] in self?.target?.undoManager?.undo() }
        add("↷", id: "redo", to: tools, label: "Refazer") { [weak self] in self?.target?.undoManager?.redo() }
        add("", id: "paste", to: tools, label: "Colar") { [weak self] in self?.insert(UIPasteboard.general.string ?? "", applyShift: false) }
        for case let button as UIButton in tools.arrangedSubviews { button.widthAnchor.constraint(equalToConstant: 38).isActive = true }
        tools.addArrangedSubview(UIView())

        let lines: [[String]]
        switch page {
        case .letters: lines = [Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init), Array("zxcvbnm,.").map(String.init)]
        case .numbers: lines = [Array("1234567890").map(String.init), ["@", "#", "$", "&", "*", "(", ")", "'", "\""], ["%", "-", "+", "=", "/", ";", ":", "!", "?"]]
        case .symbols: lines = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥"], ["•", "♭", "♯", "♪", "°", "©", "®", "¿", "¡"]]
        case .emoji: lines = []; addEmojiGrid()
        }
        var unit: UIButton?
        for (index, keys) in lines.enumerated() {
            let line = row(height: 48); line.distribution = .fill
            if index == 1, let unit {
                let indent = UIView(); line.addArrangedSubview(indent)
                indent.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 0.4).isActive = true
            }
            if index == 2 {
                let button = shiftKey(id: "shift", to: line)
                if let unit { button.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true }
            }
            for key in keys {
                let button = character(key, to: line)
                if let unit { button.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true }
                else { unit = button }
            }
            if index == 0 {
                let delete = add("⌫", id: "delete", to: line, label: "Apagar") { [weak self] in self?.input?.deleteBackward() }
                if let unit { delete.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true }
                let repeatDelete = UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:)))
                repeatDelete.minimumPressDuration = 0.4; delete.addGestureRecognizer(repeatDelete)
            } else if index == 1 {
                add(target is UITextView ? "retorno" : "concluir", id: "return", to: line) { [weak self] in self?.submit() }
            } else {
                let button = shiftKey(id: "shift-right", to: line)
                if let unit { button.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true }
            }
        }
        let bottom = row(height: 46); bottom.distribution = .fill
        let changePage: () -> Void = { [weak self] in guard let self else { return }; page = page == .letters ? .numbers : .letters; rebuild() }
        add(page == .letters ? ".?123" : "ABC", id: "page", to: bottom, action: changePage)
        add("", id: "emoji", to: bottom, label: "Emoji") { [weak self] in
            guard let self else { return }; page = page == .emoji ? .letters : .emoji; rebuild()
        }
        let space = add("", id: "space", to: bottom, label: "Espaço") { [weak self] in self?.insert(" ", applyShift: false) }
        space.backgroundColor = keyColor
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(spaceTrackpad(_:)))
        drag.minimumPressDuration = 0.4; space.addGestureRecognizer(drag)
        add(page == .letters ? ".?123" : "ABC", id: "page-right", to: bottom, action: changePage)
        add("", id: "close", to: bottom, label: "Fechar teclado") { [weak self] in self?.target?.resignFirstResponder() }
        for view in bottom.arrangedSubviews where view !== space { view.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.12).isActive = true }
        updateShift()
    }
    private func row(height: CGFloat) -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5; row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        container.addArrangedSubview(row); rows.append(row); return row
    }
    @discardableResult private func add(_ title: String, id: String, to row: UIStackView, label: String? = nil,
                                        action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal); button.setTitleColor(.white, for: .normal)
        let images = ["undo": "arrow.uturn.backward", "redo": "arrow.uturn.forward", "delete": "delete.left", "close": "keyboard.chevron.compact.down", "paste": "doc.on.clipboard", "emoji": "face.smiling"]
        if let image = images[id] {
            button.setTitle(nil, for: .normal)
            button.setImage(UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
            button.tintColor = .white
        }
        button.titleLabel?.font = .systemFont(ofSize: row === rows.first ? 13 : title.count == 1 ? 22 : 15, weight: .regular)
        button.titleLabel?.adjustsFontSizeToFitWidth = true; button.titleLabel?.minimumScaleFactor = 0.7
        button.backgroundColor = row === rows.first ? .clear : specialKeyColor; button.layer.cornerRadius = 6
        if row !== rows.first {
            button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.35
            button.layer.shadowOffset = CGSize(width: 0, height: 1); button.layer.shadowRadius = 0
        }
        button.accessibilityIdentifier = "cat-key-" + id; button.accessibilityLabel = label ?? title
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        row.addArrangedSubview(button); return button
    }
    @discardableResult private func character(_ text: String, to row: UIStackView) -> UIButton {
        let button = add(text, id: text, to: row) { [weak self] in self?.insert(text) }
        button.backgroundColor = keyColor
        characterKeys.append((button, text))
        if Self.accents[text] != nil {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(accentPress(_:)))
            press.minimumPressDuration = 0.4; button.addGestureRecognizer(press)
        }
        return button
    }
    private func shiftKey(id: String, to row: UIStackView) -> UIButton {
        if page == .numbers || page == .symbols {
            return add(page == .numbers ? "#+=" : "123", id: id, to: row) { [weak self] in
                guard let self else { return }; page = page == .numbers ? .symbols : .numbers; rebuild()
            }
        }
        let button = add("", id: id, to: row, label: "Shift") { [weak self] in
            guard let self else { return }; shift.tap(at: ProcessInfo.processInfo.systemUptime); updateShift()
        }
        shiftButtons.append(button); return button
    }
    private var trackpadX: CGFloat?
    @objc private func spaceTrackpad(_ gesture: UILongPressGestureRecognizer) {
        let x = gesture.location(in: self).x
        switch gesture.state {
        case .began: trackpadX = x
        case .changed:
            guard let previous = trackpadX else { return }
            let steps = Int((x - previous) / 12)
            if steps != 0 { moveCursor(steps); trackpadX = previous + CGFloat(steps) * 12 }
        default: trackpadX = nil
        }
    }
    private static let emoji: [String] = {
        let common = Array("😀😃😄😁😆😅😂🙂🙃😉😊😍🥰😘😎😭😢😡👍👎👏🙌🙏❤️🔥🎵🎶🎤🎹🎸🥁🇧🇷🇺🇸🇵🇹").map(String.init)
        let scalars = [0x2300...0x27FF, 0x1F300...0x1FAFF].flatMap { $0 }.compactMap(Unicode.Scalar.init)
            .filter { $0.properties.isEmojiPresentation && !(0x1F3FB...0x1F3FF).contains(Int($0.value)) }.map(String.init)
        return common + scalars.filter { !common.contains($0) }
    }()
    private func addEmojiGrid() {
        let layout = UICollectionViewFlowLayout(); layout.minimumLineSpacing = 2; layout.minimumInteritemSpacing = 2
        let grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.backgroundColor = .clear; grid.dataSource = self; grid.delegate = self
        grid.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "emoji")
        grid.heightAnchor.constraint(equalToConstant: 154).isActive = true
        container.addArrangedSubview(grid)
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { Self.emoji.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath)
        let label = (cell.contentView.viewWithTag(1) as? UILabel) ?? UILabel(frame: cell.contentView.bounds)
        if label.superview == nil { label.tag = 1; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; label.font = .systemFont(ofSize: 27); label.textAlignment = .center; cell.contentView.addSubview(label) }
        label.text = Self.emoji[indexPath.item]
        cell.isAccessibilityElement = true; cell.accessibilityTraits = .button
        cell.accessibilityLabel = label.text; cell.accessibilityIdentifier = "cat-emoji-" + (label.text ?? "")
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { insert(Self.emoji[indexPath.item], applyShift: false) }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: max(32, (collectionView.bounds.width - 22) / 12), height: 36)
    }
    private func updateShift() {
        UIView.performWithoutAnimation {
        for button in shiftButtons {
            button.setImage(UIImage(systemName: shift.mode == .locked ? "capslock.fill" : shift.mode == .once ? "shift.fill" : "shift",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
            button.backgroundColor = shift.mode == .off ? specialKeyColor : .white
            button.tintColor = shift.mode == .off ? .white : .black
            button.accessibilityValue = shift.mode == .off ? "Desativado" : shift.mode == .once ? "Próxima letra" : "Maiúsculas fixas"
        }
        for (button, text) in characterKeys {
            let title = page == .letters ? shift.text(text) : text
            if button.title(for: .normal) != title { button.setTitle(title, for: .normal); button.layoutIfNeeded() }
        }
        }
    }
    private func insert(_ text: String, applyShift: Bool = true) {
        guard !text.isEmpty, let input else { return }
        input.insertText(applyShift && page == .letters ? shift.text(text) : text)
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
