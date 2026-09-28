import SwiftUI
struct RegionEditor: View {
    let region: Part
    let initialColor: UInt32
    let save: (String, UInt32, Bool) -> Void
    @State private var uppercaseName = true
    var body: some View {
        NameColorEditor(title: "Editar região", initialName: region.name, initialColor: initialColor,
                        save: { save($0, $1, uppercaseName) }, uppercaseName: $uppercaseName)
            .onAppear { uppercaseName = region.usesUppercase }
    }
}
struct NameColorEditor: View {
    let title: String
    let initialName: String
    let initialColor: UInt32
    let save: (String, UInt32) -> Void
    var close: (() -> Void)? = nil
    var symbol: Binding<Bool>? = nil
    var uppercaseName: Binding<Bool>? = nil
    var maximumNameLength: Int? = nil
    var nameEditable = true
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var red = 0.0
    @State private var green = 0.0
    @State private var blue = 0.0
    private var rgb: UInt32 { UInt32(red.rounded()) << 16 | UInt32(green.rounded()) << 8 | UInt32(blue.rounded()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(title)).font(.headline)
            TextField("Nome", text: $name)
                .disabled(!nameEditable).textFieldStyle(.roundedBorder)
                .focused($nameFocused).onSubmit { confirm() }
                .onChange(of: name) { value in
                    if let maximumNameLength, value.count > maximumNameLength { name = String(value.prefix(maximumNameLength)) }
                }
            RoundedRectangle(cornerRadius: 5).fill(Color(hex: rgb)).frame(height: 28)
            channel("R", value: $red, color: .red)
            channel("G", value: $green, color: .green)
            channel("B", value: $blue, color: .blue)
            if let symbol { Toggle("SIMBOL", isOn: symbol) }
            if let uppercaseName { Toggle("Uppercase", isOn: uppercaseName) }
            HStack {
                Button("Cancelar") { finish() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar") { confirm() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 300)
            .onAppear {
                name = initialName
                nameFocused = nameEditable
                red = Double((initialColor >> 16) & 255)
                green = Double((initialColor >> 8) & 255)
                blue = Double(initialColor & 255)
            }
    }
    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(trimmed, rgb)
        finish()
    }
    private func finish() { if let close { close() } else { dismiss() } }
    private func channel(_ title: String, value: Binding<Double>, color: Color) -> some View {
        HStack {
            Text(title).frame(width: 14)
            Slider(value: value, in: 0...255, step: 1).tint(color)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 30)
        }
    }
}
struct UnifyRegionEditor: View {
    let create: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name = ""
    @State private var invalid = false
    @State private var shake = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unify regions").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : .clear))
                .modifier(InputValidationShake(animatableData: shake))
                .onSubmit(confirm).onChange(of: name) { _ in invalid = false }
            if invalid { Text("Choose a name").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
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
        if create(name) { dismiss() }
    }
}
#if os(macOS)
import AppKit
struct RegionRightClick: NSViewRepresentable {
    let edit: () -> Void
    var unify: (() -> Void)? = nil
    var disunify: (() -> Void)? = nil
    var delete: (() -> Void)? = nil
    var resizable = true
    var drag: (CGFloat, Bool, Int) -> Void = { _, _, _ in }
    func makeNSView(context: Context) -> RegionRightClickView { RegionRightClickView() }
    func updateNSView(_ view: RegionRightClickView, context: Context) { view.edit = edit; view.unify = unify; view.disunify = disunify; view.delete = delete; view.drag = drag; view.resizable = resizable }
}
final class RegionRightClickView: NSView {
    var edit: (() -> Void)?
    var unify: (() -> Void)?
    var disunify: (() -> Void)?
    var delete: (() -> Void)?
    var drag: ((CGFloat, Bool, Int) -> Void)?
    var resizable = true { didSet {
        if resizable != oldValue {
            if !resizable { hoverEdge = 0; if edge != 0 { startX = nil; activeDrag = nil; edge = 0 } }
            window?.invalidateCursorRects(for: self)
        }
    } }
    private var startX: CGFloat?
    private var edge = 0
    private var activeDrag: ((CGFloat, Bool, Int) -> Void)?
    private var hoverEdge = 0 { didSet { if hoverEdge != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    private var edgeWidth: CGFloat { min(34, max(0, (bounds.width - 8) / 2)) }
    private func edge(at x: CGFloat) -> Int {
        guard resizable else { return 0 }
        return x <= edgeWidth ? -1 : (x >= bounds.width - edgeWidth ? 1 : 0)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard startX == nil else { return }
        hoverEdge = edge(at: convert(event.locationInWindow, from: nil).x)
        if hoverEdge != 0 { NSCursor.resizeLeftRight.set() }
    }
    override func mouseExited(with event: NSEvent) { if startX == nil { hoverEdge = 0 } }
    override func draw(_ dirtyRect: NSRect) {
        guard resizable, hoverEdge != 0 else { return }
        let x: CGFloat = hoverEdge < 0 ? 10 : bounds.width - 10
        NSColor(srgbRed: 0.33, green: 1, blue: 0.58, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 2, y: 3, width: 4, height: max(0, bounds.height - 6)), xRadius: 2, yRadius: 2).fill()
    }
    override func resetCursorRects() {
        guard resizable else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: edgeWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edgeWidth, y: 0, width: edgeWidth, height: bounds.height), cursor: .resizeLeftRight)
    }
    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(regionMenu(), with: event, for: self)
    }
    func regionMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: JarasLocalization.string(title), action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        add("Edit", #selector(editSelected))
        if unify != nil { add("Unify", #selector(unifySelected)) }
        if disunify != nil { add("Disunify", #selector(disunifySelected)) }
        if delete != nil { add("Delete region", #selector(deleteSelected)) }
        return menu
    }
    @objc private func deleteSelected() { delete?() }
    @objc private func unifySelected() { unify?() }
    @objc private func editSelected() { edit?() }
    @objc private func disunifySelected() { disunify?() }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { startX = nil; activeDrag = nil; rightMouseDown(with: event) }
        else {
            startX = event.locationInWindow.x
            let x = convert(event.locationInWindow, from: nil).x
            edge = edge(at: x)
            hoverEdge = edge
            activeDrag = drag
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if let startX { activeDrag?(event.locationInWindow.x - startX, false, edge) }
    }
    override func mouseUp(with event: NSEvent) {
        if let startX { activeDrag?(event.locationInWindow.x - startX, true, edge) }
        startX = nil; activeDrag = nil
        hoverEdge = edge(at: convert(event.locationInWindow, from: nil).x)
    }
}
struct MarkerEditAnchor: NSViewRepresentable {
    let edit: () -> Void
    let delete: () -> Void
    func makeNSView(context: Context) -> MarkerEditClickView { MarkerEditClickView() }
    func updateNSView(_ view: MarkerEditClickView, context: Context) { view.action = edit; view.optionClick = delete }
}
final class MarkerEditClickView: RightClickTargetView {
    override var priority: Int { 110 }
}
#endif

private struct EditTrackDetailsKey: EnvironmentKey {
    static let defaultValue: (UUID, String, UInt32) -> Void = { _, _, _ in }
}
extension EnvironmentValues {
    var editTrackDetails: (UUID, String, UInt32) -> Void {
        get { self[EditTrackDetailsKey.self] }
        set { self[EditTrackDetailsKey.self] = newValue }
    }
}
