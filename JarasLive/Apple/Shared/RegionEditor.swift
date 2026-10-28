import SwiftUI
#if os(iOS)
import UIKit
#endif
struct RegionEditor: View {
    let region: Part
    let initialColor: UInt32
    let save: (String, UInt32, Bool) -> Void
    @State private var uppercaseName = true
    var body: some View {
        NameColorEditor(title: "Edit song", initialName: region.name, initialColor: initialColor,
                        save: { save($0, $1, uppercaseName) }, uppercaseName: $uppercaseName)
            .onAppear { uppercaseName = region.usesUppercase }
    }
}
struct NameColorEditor: View {
    fileprivate static let presetColors: [UInt32] = [
        0x000000, 0x414141, 0x828282, 0xbdbdbd, 0xffffff, 0xf44336, 0xff6f00, 0xffc107,
        0xffeb3b, 0xb9e229, 0x70d14d, 0x00a65a, 0x00cfa0, 0x00c9c9, 0x00a3e0, 0x287bff,
        0x4a4ddb, 0x7548dd, 0xae40d6, 0xe13db5, 0xff6993, 0xb84a56, 0x9a613b, 0xc7915e
    ]
    let title: String
    let initialName: String
    let initialColor: UInt32
    let save: (String, UInt32) -> Void
    var close: (() -> Void)? = nil
    var symbol: Binding<Bool>? = nil
    var uppercaseName: Binding<Bool>? = nil
    var maximumNameLength: Int? = nil
    var nameEditable = true
    var showsName = true
    var previewColor: ((UInt32) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceEditorDismiss) private var closeEditor
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var red = 0.0
    @State private var green = 0.0
    @State private var blue = 0.0
    @State private var originalColor: UInt32?
    @State private var colorConfirmed = false
    private var rgb: UInt32 { UInt32(red.rounded()) << 16 | UInt32(green.rounded()) << 8 | UInt32(blue.rounded()) }
    var body: some View {
        #if os(macOS)
        // Keep this frequently opened form in one native layout. Building the
        // slider/palette SwiftUI subtree delayed every marker/track/region edit.
        NativeNameColorEditor(editor: self, finish: finish)
            .frame(width: 300, height: NativeNameColorEditorView.height(for: self))
        #else
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(title)).font(.jarasHeadline)
            if showsName {
            TextField("Nome", text: $name)
                .disabled(!nameEditable).textFieldStyle(.roundedBorder)
                .focused($nameFocused).onSubmit { confirm() }
                .onChange(of: name) { value in
                    if let maximumNameLength, value.count > maximumNameLength { name = String(value.prefix(maximumNameLength)) }
                }
            }
            RoundedRectangle(cornerRadius: 5).fill(Color(hex: rgb)).frame(height: 28)
            channel("R", value: $red, color: .red)
            channel("G", value: $green, color: .green)
            channel("B", value: $blue, color: .blue)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.presetColors, id: \.self) { color in
                    Button { chooseColor(color) } label: {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: color))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.2)))
                            .overlay {
                                if rgb == color {
                                    RoundedRectangle(cornerRadius: 3).inset(by: 1).stroke(.white, lineWidth: 2)
                                    RoundedRectangle(cornerRadius: 2).inset(by: 3).stroke(.black, lineWidth: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(String(format: "#%06X", color))
                        .accessibilityAddTraits(rgb == color ? .isSelected : [])
                }
            }
            if let symbol { Toggle("SIMBOL", isOn: symbol) }
            if let uppercaseName { Toggle("Uppercase", isOn: uppercaseName) }
            HStack {
                Button("Cancelar") { finish() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar") { confirm() }.keyboardShortcut(.defaultAction)
                    .disabled(showsName && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 300)
            #if os(iOS)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { nameFocused = false })
            #endif
            .onAppear {
                originalColor = initialColor
                colorConfirmed = false
                name = initialName
                nameFocused = nameEditable && showsName
                chooseColor(initialColor)
            }
            .onChange(of: rgb) { color in
                if originalColor != nil { previewColor?(color) }
            }
            .onDisappear {
                if !colorConfirmed, let originalColor { previewColor?(originalColor) }
            }
        #endif
    }
    private func chooseColor(_ color: UInt32) {
        red = Double((color >> 16) & 255)
        green = Double((color >> 8) & 255)
        blue = Double(color & 255)
    }
    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !showsName || !trimmed.isEmpty else { return }
        colorConfirmed = true
        save(trimmed, rgb)
        finish()
    }
    private func finish() {
        #if os(iOS)
        nameFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        if let close { close() } else { (closeEditor ?? { dismiss() })() }
    }
    private func channel(_ title: String, value: Binding<Double>, color: Color) -> some View {
        HStack {
            Text(title).frame(width: 14)
            Slider(value: value, in: 0...255, step: 1).tint(color)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 30)
        }
    }
}
#if os(macOS)
import AppKit

private struct NativeNameColorEditor: NSViewRepresentable {
    let editor: NameColorEditor
    let finish: () -> Void
    @Environment(\.locale) private var locale
    func makeNSView(context: Context) -> NativeNameColorEditorView {
        NativeNameColorEditorView(editor: editor, locale: locale.identifier, finish: finish)
    }
    func updateNSView(_ view: NativeNameColorEditorView, context: Context) {
        view.update(editor: editor, locale: locale.identifier, finish: finish)
    }
    static func dismantleNSView(_ view: NativeNameColorEditorView, coordinator: ()) {
        view.restorePreviewIfNeeded()
    }
}

/// The draft belongs to the presented form, not the frequently refreshed project
/// view. Native controls keep editing/focus intact when live color preview updates
/// its parent; closing the popover without Save restores the original color.
final class NativeNameColorEditorView: NSView, NSTextFieldDelegate {
    private var editor: NameColorEditor
    private var locale: String
    private var finish: () -> Void
    private var completed = false
    private var previewChanged = false
    private var focused = false
    private var color: UInt32
    private let originalColor: UInt32
    private let titleLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField(string: "")
    private let preview = NativeEditorColorPreview()
    private let channelLabels = ["R", "G", "B"].map { NSTextField(labelWithString: $0) }
    private let values = (0..<3).map { _ in NSTextField(labelWithString: "0") }
    private let sliders = (0..<3).map { _ in NSSlider(value: 0, minValue: 0, maxValue: 255, target: nil, action: nil) }
    private var swatches: [NativeEditorColorSwatch] = []
    private let symbolButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let uppercaseButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let saveButton = NSButton(title: "", target: nil, action: nil)

    static func height(for editor: NameColorEditor) -> CGFloat {
        // Same 300 pt form, 18 pt inset, 14 pt row gaps and 8 × 3 swatches.
        369 + (editor.showsName ? 0 : -38)
            + (editor.symbol == nil ? 0 : 32) + (editor.uppercaseName == nil ? 0 : 32)
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: Self.height(for: editor)) }
    init(editor: NameColorEditor, locale: String, finish: @escaping () -> Void) {
        self.editor = editor; self.locale = locale; self.finish = finish
        color = editor.initialColor; originalColor = editor.initialColor
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height(for: editor)))
        autoresizesSubviews = false
        titleLabel.font = .jarasSystemFont(ofSize: 13, weight: .bold)
        nameField.stringValue = editor.maximumNameLength.map { String(editor.initialName.prefix($0)) } ?? editor.initialName
        nameField.isBezeled = true; nameField.bezelStyle = .roundedBezel
        nameField.font = .jarasSystemFont(ofSize: 13)
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("name-color-name")
        for control in [symbolButton, uppercaseButton, cancelButton, saveButton] {
            control.font = .jarasSystemFont(ofSize: 13)
            control.target = self
        }
        cancelButton.bezelStyle = .rounded; saveButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"; saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalentModifierMask = []; saveButton.keyEquivalentModifierMask = []
        cancelButton.action = #selector(cancel); saveButton.action = #selector(confirm)
        cancelButton.setAccessibilityIdentifier("name-color-cancel")
        saveButton.setAccessibilityIdentifier("name-color-save")
        symbolButton.action = #selector(toggleSymbol); uppercaseButton.action = #selector(toggleUppercase)
        symbolButton.setAccessibilityIdentifier("name-color-symbol")
        uppercaseButton.setAccessibilityIdentifier("name-color-uppercase")
        [titleLabel, nameField, preview, symbolButton, uppercaseButton, cancelButton, saveButton].forEach(addSubview)
        for i in 0..<3 {
            channelLabels[i].font = .jarasSystemFont(ofSize: 13)
            channelLabels[i].alignment = .center
            values[i].font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            values[i].alignment = .center
            sliders[i].trackFillColor = [NSColor.systemRed, .systemGreen, .systemBlue][i]
            sliders[i].tag = i; sliders[i].isContinuous = true
            sliders[i].target = self; sliders[i].action = #selector(changeChannel(_:))
            sliders[i].setAccessibilityLabel(["R", "G", "B"][i])
            sliders[i].setAccessibilityIdentifier("name-color-channel-\(i)")
            [channelLabels[i], sliders[i], values[i]].forEach(addSubview)
        }
        swatches = NameColorEditor.presetColors.map { rgb in
            let button = NativeEditorColorSwatch(color: rgb)
            button.target = self; button.action = #selector(selectSwatch(_:))
            addSubview(button); return button
        }
        update(editor: editor, locale: locale, finish: finish)
        updateColorControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(editor: NameColorEditor, locale: String, finish: @escaping () -> Void) {
        let previousSize = intrinsicContentSize
        self.editor = editor; self.finish = finish; self.locale = locale
        func text(_ key: String) -> String { JarasLocalization.string(key, language: locale) }
        titleLabel.stringValue = text(editor.title)
        nameField.placeholderString = text("Nome")
        nameField.isHidden = !editor.showsName; nameField.isEnabled = editor.nameEditable
        symbolButton.isHidden = editor.symbol == nil; symbolButton.title = text("SIMBOL")
        symbolButton.state = editor.symbol?.wrappedValue == true ? .on : .off
        uppercaseButton.isHidden = editor.uppercaseName == nil; uppercaseButton.title = text("Uppercase")
        uppercaseButton.state = editor.uppercaseName?.wrappedValue == true ? .on : .off
        cancelButton.title = text("Cancelar"); saveButton.title = text("Salvar")
        saveButton.isEnabled = !editor.showsName || !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if previousSize != intrinsicContentSize { invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let x: CGFloat = 18, width: CGFloat = 264
        var y: CGFloat = 18
        titleLabel.frame = NSRect(x: x - 2, y: y, width: width + 4, height: 16); y += 30
        if editor.showsName { nameField.frame = NSRect(x: x, y: y, width: width, height: 24); y += 38 }
        preview.frame = NSRect(x: x, y: y, width: width, height: 28); y += 42
        for i in 0..<3 {
            channelLabels[i].frame = NSRect(x: x, y: y, width: 14, height: 16)
            sliders[i].frame = NSRect(x: x + 22, y: y - 1, width: width - 60, height: 18)
            values[i].frame = NSRect(x: x + width - 30, y: y, width: 30, height: 16)
            y += 30
        }
        let side = (width - 42) / 8
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: x + CGFloat(i % 8) * (side + 6), y: y + CGFloat(i / 8) * (side + 6), width: side, height: side)
        }
        y += side * 3 + 12 + 14
        for button in [symbolButton, uppercaseButton] where !button.isHidden {
            button.frame = NSRect(x: x, y: y, width: width, height: 18); y += 32
        }
        cancelButton.sizeToFit(); saveButton.sizeToFit()
        cancelButton.frame = NSRect(x: x, y: y - 3, width: cancelButton.frame.width, height: 30)
        saveButton.frame = NSRect(x: x + width - saveButton.frame.width, y: y - 3, width: saveButton.frame.width, height: 30)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !focused, editor.showsName, editor.nameEditable else { return }
        // Attachment occurs before the sheet/popover becomes key. Focus at the
        // next event turn, without a timer or delaying its presentation.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.focused else { return }
            self.focused = true
            window.makeFirstResponder(self.nameField); self.nameField.selectText(nil)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, !completed,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 36 || event.keyCode == 76 { confirm(); return true }
        if event.keyCode == 53 { cancel(); return true }
        return super.performKeyEquivalent(with: event)
    }
    func controlTextDidChange(_ notification: Notification) {
        if let maximum = editor.maximumNameLength, nameField.stringValue.count > maximum {
            nameField.stringValue = String(nameField.stringValue.prefix(maximum))
        }
        saveButton.isEnabled = !editor.showsName || !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { confirm(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
    @objc private func toggleSymbol() { editor.symbol?.wrappedValue = symbolButton.state == .on }
    @objc private func toggleUppercase() { editor.uppercaseName?.wrappedValue = uppercaseButton.state == .on }
    @objc private func changeChannel(_ sender: NSSlider) {
        let shift = (2 - sender.tag) * 8
        let value = UInt32(max(0, min(255, sender.doubleValue.rounded())))
        setColor((color & ~(UInt32(255) << shift)) | (value << shift))
    }
    @objc private func selectSwatch(_ sender: NativeEditorColorSwatch) { setColor(sender.color) }
    private func setColor(_ value: UInt32) {
        guard value != color else { return }
        color = value; updateColorControls()
        previewChanged = true; editor.previewColor?(color)
    }
    private func updateColorControls() {
        preview.color = color
        for i in 0..<3 {
            let value = Int((color >> ((2 - i) * 8)) & 255)
            sliders[i].integerValue = value; values[i].integerValue = value
        }
        for swatch in swatches { swatch.state = swatch.color == color ? .on : .off; swatch.needsDisplay = true }
    }
    func restorePreviewIfNeeded() {
        guard !completed else { return }
        completed = true
        if previewChanged { editor.previewColor?(originalColor) }
    }
    @objc private func cancel() { guard !completed else { return }; restorePreviewIfNeeded(); finish() }
    @objc private func confirm() {
        guard !completed else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editor.showsName || !trimmed.isEmpty else { return }
        completed = true; editor.save(trimmed, color); finish()
    }
}

private func nativeEditorColor(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
}
private final class NativeEditorColorPreview: NSView {
    var color: UInt32 = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        nativeEditorColor(color).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}
private final class NativeEditorColorSwatch: NSButton {
    let color: UInt32
    init(color: UInt32) {
        self.color = color; super.init(frame: .zero)
        isBordered = false; title = ""
        setAccessibilityLabel(String(format: "#%06X", color))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        nativeEditorColor(color).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.2).setStroke(); path.lineWidth = 1; path.stroke()
        if state == .on {
            NSColor.white.setStroke()
            let selected = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3)
            selected.lineWidth = 2; selected.stroke()
            NSColor.black.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3.5, dy: 3.5), xRadius: 2, yRadius: 2).stroke()
        }
    }
}
#endif

struct UnifyRegionEditor: View {
    let create: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceEditorDismiss) private var closeEditor
    @FocusState private var focused: Bool
    @State private var name = ""
    @State private var invalid = false
    @State private var shake = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unify regions").font(.jarasHeadline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : .clear))
                .modifier(InputValidationShake(animatableData: shake))
                .onSubmit(confirm).onChange(of: name) { _ in invalid = false }
            if invalid { Text("Choose a name").font(.jarasCaption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { (closeEditor ?? { dismiss() })() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unify", action: confirm).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 300).onAppear { focused = true }
    }
    private func confirm() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            invalid = true; focused = true
            withAnimation(.linear(duration: 0.3)) { shake += 1 }
            return
        }
        if create(name) { (closeEditor ?? { dismiss() })() }
    }
}
#if os(macOS)
import AppKit
struct RegionRightClick: NSViewRepresentable {
    let edit: () -> Void
    var unify: (() -> Void)? = nil
    var detectBPM: (() -> Void)? = nil
    var disunify: (() -> Void)? = nil
    var delete: (() -> Void)? = nil
    var exportAudio: (() -> Void)? = nil
    var resizable = true
    var seek: (() -> Void)? = nil
    var drag: (CGFloat, Bool, Int) -> Void = { _, _, _ in }
    func makeNSView(context: Context) -> RegionRightClickView { RegionRightClickView() }
    func updateNSView(_ view: RegionRightClickView, context: Context) { view.edit = edit; view.detectBPM = detectBPM; view.unify = unify; view.disunify = disunify; view.delete = delete; view.exportAudio = exportAudio; view.drag = drag; view.resizable = resizable; view.seek = seek }
}
final class RegionRightClickView: NSView, NativeTimelineInputObserver {
    var edit: (() -> Void)?
    var detectBPM: (() -> Void)?
    var unify: (() -> Void)?
    var disunify: (() -> Void)?
    var delete: (() -> Void)?
    var exportAudio: (() -> Void)?
    var drag: ((CGFloat, Bool, Int) -> Void)?
    var seek: (() -> Void)?
    var resizable = true { didSet {
        if resizable != oldValue {
            if !resizable { hoverEdge = 0; if edge != 0 { startX = nil; activeDrag = nil; edge = 0 } }
            if !usesStableNativeFrame { window?.invalidateCursorRects(for: self) }
        }
    } }
    private var startX: CGFloat?
    private var startY: CGFloat = 0
    private var edge = 0
    private var activeDrag: ((CGFloat, Bool, Int) -> Void)?
    private var activeSeek: (() -> Void)?
    private var activeDelete: (() -> Void)?
    private var didDrag = false
    private var hoverEdge = 0 { didSet {
        if hoverEdge != oldValue {
            if usesStableNativeFrame { updateNativeGrip() } else { needsDisplay = true }
        }
    } }
    private var tracking: NSTrackingArea?
    private var inputAvailable: Bool { !NativeTimelineInputGate.shared.isBlocked(window) && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timelineInputGateChanged(blocked: true)
        if window != nil { NativeTimelineInputGate.shared.add(self) }
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { startX = nil; activeDrag = nil; activeSeek = nil; activeDelete = nil; didDrag = false }
    }
    func timelinePendingClickCancelled() {
        if !didDrag { timelineInputGateChanged(blocked: true) }
    }
    override var isFlipped: Bool { true }
    // Native timeline mounts use a bounded view while retaining the original
    // padded region geometry for edge hit testing, hover and release checks.
    // Hosted callers keep their existing bounds-based coordinates.
    private var projectedRegionRect: CGRect?
    private var usesStableNativeFrame = false
    private var nativeInputRect: CGRect?
    private let nativeGrip = CAShapeLayer()
    var projectedInputBounds: CGRect { nativeInputRect ?? bounds }
    var hasActiveProjectedGesture: Bool { startX != nil }
    private var presentingProjectedMenu = false
    var isReservedForProjectionReuse: Bool { hasActiveProjectedGesture || presentingProjectedMenu }
    var projectedInteractionEnded: (() -> Void)?
    /// Empty hit geometry and shape layers retain an attached, raster-free slot.
    /// A context menu still dispatches through this view, so do not rebind it
    /// while its modal event loop is active, even if its UUID was removed.
    @discardableResult func deactivateProjectedInput() -> Bool {
        guard usesStableNativeFrame, !hasActiveProjectedGesture else { return false }
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        projectedRegionRect = .zero
        nativeInputRect = .zero
        hoverEdge = 0
        nativeGrip.isHidden = true
        nativeGrip.path = nil
        edit = nil; detectBPM = nil; unify = nil; disunify = nil; delete = nil; exportAudio = nil
        drag = nil; seek = nil
        guard !presentingProjectedMenu else { return false }
        timelineInputGateChanged(blocked: true)
        projectedInteractionEnded = nil
        return true
    }
    override var wantsUpdateLayer: Bool { usesStableNativeFrame }
    override func updateLayer() { updateNativeGrip() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard usesStableNativeFrame else { return super.hitTest(point) }
        guard inputAvailable, projectedInputBounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    private func updateNativeGrip() {
        guard usesStableNativeFrame else { return }
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        guard let gripRect else {
            if !nativeGrip.isHidden { nativeGrip.isHidden = true; nativeGrip.path = nil }
            return
        }
        nativeGrip.isHidden = false
        if nativeGrip.frame != projectedInputBounds { nativeGrip.frame = projectedInputBounds }
        nativeGrip.path = CGPath(roundedRect: gripRect.offsetBy(dx: -projectedInputBounds.minX, dy: -projectedInputBounds.minY),
            cornerWidth: 2, cornerHeight: 2, transform: nil)
    }
    func updateProjectedPointer(at point: CGPoint?) {
        // Explicit cancellation must clear the grip even during a captured drag.
        guard startX == nil || point == nil else { return }
        if let point, inputAvailable, projectedInputBounds.intersection(visibleRect).contains(point) {
            hoverEdge = edge(at: point.x)
        } else { hoverEdge = 0 }
        let cursor = hoverEdge != 0 ? NSCursor.resizeLeftRight : NSCursor.arrow
        if NSCursor.current !== cursor { cursor.set() }
    }
    private var regionRect: CGRect { projectedRegionRect ?? bounds }
    private struct CursorProjection: Equatable {
        let left: CGRect
        let right: CGRect
    }
    private var edgeWidth: CGFloat { min(34, max(0, (regionRect.width - 8) / 2)) }
    private func edge(at x: CGFloat) -> Int {
        guard resizable else { return 0 }
        return x <= regionRect.minX + edgeWidth ? -1 : (x >= regionRect.maxX - edgeWidth ? 1 : 0)
    }
    private func cursorProjection() -> CursorProjection {
        guard resizable else { return CursorProjection(left: .null, right: .null) }
        func clipped(_ rect: CGRect) -> CGRect {
            let clipped = rect.intersection(projectedInputBounds)
            return clipped.isEmpty ? .null : clipped
        }
        return CursorProjection(
            left: clipped(CGRect(x: regionRect.minX, y: regionRect.minY, width: edgeWidth, height: regionRect.height)),
            right: clipped(CGRect(x: regionRect.maxX - edgeWidth, y: regionRect.minY, width: edgeWidth, height: regionRect.height)))
    }
    private var gripRect: CGRect? {
        guard resizable, hoverEdge != 0 else { return nil }
        let x = hoverEdge < 0 ? regionRect.minX + 10 : regionRect.maxX - 10
        return CGRect(x: x - 2, y: regionRect.minY + 3, width: 4, height: max(0, regionRect.height - 6))
    }
    func projectRegion(frame fullFrame: CGRect, viewport: CGRect, stableInputSize: CGSize? = nil) {
        let left = min(viewport.maxX, max(viewport.minX, fullFrame.minX))
        let right = min(viewport.maxX, max(viewport.minX, fullFrame.maxX))
        let nextFrame = CGRect(x: left, y: fullFrame.minY, width: max(0, right - left), height: fullFrame.height)
        if let stableInputSize {
            if !usesStableNativeFrame {
                usesStableNativeFrame = true
                autoresizesSubviews = false
                wantsLayer = true
                layer?.contents = nil
                nativeGrip.fillColor = NSColor(srgbRed: 0.33, green: 1, blue: 0.58, alpha: 0.95).cgColor
                nativeGrip.masksToBounds = true
                layer?.addSublayer(nativeGrip)
                if let tracking { removeTrackingArea(tracking); self.tracking = nil }
            }
            projectedRegionRect = fullFrame
            nativeInputRect = nextFrame
            let host = CGRect(origin: .zero, size: stableInputSize)
            if frame != host { frame = host }
            updateNativeGrip()
            return
        }
        let oldCursor = cursorProjection()
        let oldGrip = gripRect?.intersection(bounds)
        let frameChanged = frame != nextFrame
        projectedRegionRect = fullFrame.offsetBy(dx: -nextFrame.minX, dy: -nextFrame.minY)
        if frameChanged { frame = nextFrame }
        let cursorChanged = oldCursor != cursorProjection()
        // Native geometry already invalidates tracking when the bounded frame
        // changes. A moving offscreen logical edge must not traverse AppKit's
        // window-wide cursor hierarchy on every zoom frame.
        if !frameChanged, cursorChanged {
            window?.invalidateCursorRects(for: self)
            if startX == nil, let window, window.isKeyWindow {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if inputAvailable, bounds.intersection(visibleRect).contains(point) {
                    hoverEdge = edge(at: point.x)
                    (hoverEdge != 0 ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                } else if hoverEdge != 0 {
                    hoverEdge = 0; NSCursor.arrow.set()
                }
            }
        }
        if oldGrip != gripRect?.intersection(bounds) { needsDisplay = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !usesStableNativeFrame, tracking == nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        updateProjectedPointer(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        if startX == nil { hoverEdge = 0; NSCursor.arrow.set() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let gripRect else { return }
        NSColor(srgbRed: 0.33, green: 1, blue: 0.58, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: gripRect, xRadius: 2, yRadius: 2).fill()
    }
    override func resetCursorRects() {
        guard !usesStableNativeFrame else { return }
        let visible = bounds.intersection(visibleRect)
        guard !visible.isEmpty else { return }
        guard resizable, inputAvailable else { addCursorRect(visible, cursor: .arrow); return }
        func register(_ rect: NSRect, cursor: NSCursor) {
            let clipped = rect.intersection(visible)
            if !clipped.isEmpty { addCursorRect(clipped, cursor: cursor) }
        }
        register(NSRect(x: regionRect.minX + edgeWidth, y: regionRect.minY,
            width: max(0, regionRect.width - 2 * edgeWidth), height: regionRect.height), cursor: .arrow)
        register(NSRect(x: regionRect.minX, y: regionRect.minY, width: edgeWidth, height: regionRect.height), cursor: .resizeLeftRight)
        register(NSRect(x: regionRect.maxX - edgeWidth, y: regionRect.minY, width: edgeWidth, height: regionRect.height), cursor: .resizeLeftRight)
    }
    override func rightMouseDown(with event: NSEvent) {
        let reserved = usesStableNativeFrame
        if reserved { presentingProjectedMenu = true }
        defer {
            if reserved {
                presentingProjectedMenu = false
                projectedInteractionEnded?()
            }
        }
        NSMenu.popUpContextMenu(regionMenu(), with: event, for: self)
    }
    func regionMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: JarasLocalization.string(title), action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        add("Edit", #selector(editSelected))
        if detectBPM != nil { add("Detect BPM…", #selector(detectSelected)) }
        if unify != nil { add("Unify", #selector(unifySelected)) }
        if disunify != nil { add("Disunify", #selector(disunifySelected)) }
        if exportAudio != nil { add("Export Audio", #selector(exportAudioSelected)) }
        if delete != nil { add("Delete region", #selector(deleteSelected)) }
        return menu
    }
    @objc private func exportAudioSelected() { exportAudio?() }
    @objc private func detectSelected() { detectBPM?() }
    @objc private func deleteSelected() { delete?() }
    @objc private func unifySelected() { unify?() }
    @objc private func editSelected() { edit?() }
    @objc private func disunifySelected() { disunify?() }
    override func mouseDown(with event: NSEvent) {
        guard inputAvailable else { timelineInputGateChanged(blocked: true); return }
        if event.modifierFlags.contains(.control) { startX = nil; activeDrag = nil; activeSeek = nil; activeDelete = nil; rightMouseDown(with: event) }
        else {
            startX = event.locationInWindow.x
            startY = event.locationInWindow.y
            let x = convert(event.locationInWindow, from: nil).x
            let deleting = event.modifierFlags.contains(.option)
            edge = deleting ? 0 : edge(at: x)
            hoverEdge = edge
            activeDelete = deleting ? delete : nil
            activeDrag = deleting ? nil : drag
            activeSeek = deleting ? nil : seek; didDrag = false
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard inputAvailable else { timelineInputGateChanged(blocked: true); return }
        if let startX {
            let delta = (event.locationInWindow.x - startX) / max(0.01, abs(convert(NSSize(width: 1, height: 1), to: nil).width))
            if abs(delta) >= (edge == 0 ? 3 : 0.5) || abs(event.locationInWindow.y - startY) >= 3 { didDrag = true }
            if didDrag { activeDrag?(delta, false, edge) }
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard inputAvailable else { timelineInputGateChanged(blocked: true); return }
        if let startX {
            let delta = (event.locationInWindow.x - startX) / max(0.01, abs(convert(NSSize(width: 1, height: 1), to: nil).width))
            if didDrag || abs(delta) >= (edge == 0 ? 3 : 0.5) || abs(event.locationInWindow.y - startY) >= 3 { activeDrag?(delta, true, edge) }
            else if let activeDelete {
                if regionRect.contains(convert(event.locationInWindow, from: nil)) { activeDelete() }
            } else { activeSeek?() }
        }
        startX = nil; activeDrag = nil; activeSeek = nil; activeDelete = nil; didDrag = false
        mouseMoved(with: event)
        projectedInteractionEnded?()
    }
}
struct MarkerEditAnchor: NSViewRepresentable {
    var normalCursor = false
    let edit: () -> Void
    let delete: () -> Void
    var seek: (() -> Void)? = nil
    var drag: ((CGFloat, Bool) -> Void)? = nil
    func makeNSView(context: Context) -> MarkerEditClickView { MarkerEditClickView() }
    func updateNSView(_ view: MarkerEditClickView, context: Context) { view.action = edit; view.optionClick = delete; view.seek = seek; view.drag = drag; view.normalCursor = normalCursor }
}
@MainActor private final class MarkerMenuActions: NSObject {
    let edit: () -> Void, convert: () -> Void
    init(edit: @escaping () -> Void, convert: @escaping () -> Void) { self.edit = edit; self.convert = convert }
    @objc func editSelected() { edit() }
    @objc func convertSelected() { convert() }
}
final class MarkerEditClickView: RightClickTargetView, NativeTimelineInputObserver {
    func showMarkerMenu(edit: @escaping () -> Void, convert: @escaping () -> Void) {
        guard let event = NSApp.currentEvent, inputAvailable else { return }
        let actions = MarkerMenuActions(edit: edit, convert: convert)
        let menu = NSMenu()
        for (title, action) in [("Edit", #selector(MarkerMenuActions.editSelected)), ("Converter para região", #selector(MarkerMenuActions.convertSelected))] {
            let item = NSMenuItem(title: JarasLocalization.string(title), action: action, keyEquivalent: "")
            item.target = actions; menu.addItem(item)
        }
        withExtendedLifetime(actions) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    var normalCursor = false { didSet { if normalCursor != oldValue { window?.invalidateCursorRects(for: self) } } }
    private var moveCursor: NSCursor { normalCursor ? .arrow : .resizeLeftRight }
    private var nativeInputBounds: CGRect?
    var hasActiveProjectedGesture: Bool { startX != nil }
    override var isFlipped: Bool { nativeInputBounds != nil || super.isFlipped }
    override var wantsUpdateLayer: Bool { nativeInputBounds != nil }
    override func updateLayer() {}
    override var clickBounds: CGRect { nativeInputBounds ?? bounds }
    override var clickPriorityArea: CGFloat { nativeInputBounds.map { $0.width * $0.height } ?? super.clickPriorityArea }
    func projectInput(_ rect: CGRect, stableSize: CGSize) {
        if nativeInputBounds == nil, let tracking { removeTrackingArea(tracking); self.tracking = nil }
        nativeInputBounds = rect
        if !wantsLayer { wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
        let stable = CGRect(origin: .zero, size: stableSize)
        if frame != stable { frame = stable }
    }
    func updateProjectedPointer(at point: CGPoint?) {
        guard startX == nil || point == nil else { return }
        let movable = point.map { inputAvailable && drag != nil && clickBounds.intersection(visibleRect).contains($0) } ?? false
        let cursor = movable ? moveCursor : NSCursor.arrow
        if NSCursor.current !== cursor { cursor.set() }
    }
    private static let cursorTargets = NSHashTable<MarkerEditClickView>.weakObjects()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timelineInputGateChanged(blocked: true)
        if window != nil { Self.cursorTargets.add(self); NativeTimelineInputGate.shared.add(self) }
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { startX = nil; activeDrag = nil; activeSeek = nil; didDrag = false }
    }
    func timelinePendingClickCancelled() {
        if !didDrag { timelineInputGateChanged(blocked: true) }
    }
    static func usesMoveCursor(for event: NSEvent) -> Bool { cursor(for: event) != nil }
    static func cursor(for event: NSEvent) -> NSCursor? {
        cursorTargets.allObjects.first { view in
            view.window?.windowNumber == event.windowNumber && view.drag != nil && view.inputAvailable
                && view.clickBounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil))
        }?.moveCursor
    }
    var seek: (() -> Void)?
    var drag: ((CGFloat, Bool) -> Void)? { didSet {
        if nativeInputBounds == nil, (drag != nil) != (oldValue != nil) { window?.invalidateCursorRects(for: self) }
    } }
    private var startX: CGFloat?
    private var startY: CGFloat = 0
    private var activeDrag: ((CGFloat, Bool) -> Void)?
    private var activeSeek: (() -> Void)?
    private var didDrag = false
    private var tracking: NSTrackingArea?
    private var inputAvailable: Bool {
        !interactionBlocked && !RightClickRouter.shared.interactionBlocked && !NativeTimelineInputGate.shared.isBlocked(window) && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor
    }
    override func resetCursorRects() {
        if nativeInputBounds == nil, drag != nil, inputAvailable { addCursorRect(bounds, cursor: moveCursor) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard nativeInputBounds == nil, tracking == nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        if drag != nil, inputAvailable { moveCursor.set() }
    }
    override func mouseExited(with event: NSEvent) {
        if drag != nil, startX == nil { NSCursor.arrow.set() }
    }
    override var priority: Int { 110 }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !interactionBlocked, !RightClickRouter.shared.interactionBlocked, window?.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor, let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type),
              !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control),
              clickBounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        timelineInputGateChanged(blocked: true)
        guard inputAvailable,
              !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) else { return }
        // Capture the original callback and window coordinates: moving the
        // display during preview must never change the gesture's origin.
        startX = event.locationInWindow.x
        startY = event.locationInWindow.y
        activeDrag = drag; activeSeek = seek; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard inputAvailable else { timelineInputGateChanged(blocked: true); return }
        guard let startX else { return }
        let delta = (event.locationInWindow.x - startX) / max(0.01, abs(convert(NSSize(width: 1, height: 1), to: nil).width))
        if hypot(delta, event.locationInWindow.y - startY) >= 3 { didDrag = true }
        if didDrag { activeDrag?(delta, false) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let startX else { return }
        let delta = (event.locationInWindow.x - startX) / max(0.01, abs(convert(NSSize(width: 1, height: 1), to: nil).width))
        let finish = activeDrag, click = activeSeek
        let moved = didDrag || hypot(delta, event.locationInWindow.y - startY) >= 3
        self.startX = nil; activeDrag = nil; activeSeek = nil; didDrag = false
        if moved && inputAvailable { finish?(delta, true) }
        else if inputAvailable { click?() }
    }
}
#endif

/// Immutable menu target: a later selection or project change cannot retarget this edit.
struct TrackDetailsEditRequest: Identifiable {
    let id = UUID()
    let project: UUID
    let tracks: Set<UUID>
    let name: String
    let color: UInt32
    let nameEditable: Bool
    var instrumentIcon: String? = nil
    var iconOnly = false
    var iconRequest: Self { var request = self; request.iconOnly = true; return request }
}
private struct EditTrackDetailsKey: EnvironmentKey {
    static let defaultValue: (TrackDetailsEditRequest) -> Void = { _ in }
}
extension EnvironmentValues {
    var editTrackDetails: (TrackDetailsEditRequest) -> Void {
        get { self[EditTrackDetailsKey.self] }
        set { self[EditTrackDetailsKey.self] = newValue }
    }
}
