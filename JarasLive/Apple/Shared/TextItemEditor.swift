import SwiftUI

private struct EditTextItemKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}
private struct GridInteractionBlockedKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var gridInteractionBlocked: Bool {
        get { self[GridInteractionBlockedKey.self] }
        set { self[GridInteractionBlockedKey.self] = newValue }
    }
    var editTextItem: (UUID) -> Void {
        get { self[EditTextItemKey.self] }
        set { self[EditTextItemKey.self] = newValue }
    }
}

/// The draft stays in the editor until Apply; transport updates never write it.
struct TextItemEditor: View {
    let apply: (String) -> Bool
    let close: () -> Void
    private let showHeader: Bool
    @State private var draft: String
    init(text: String, showHeader: Bool = true, apply: @escaping (String) -> Bool, close: @escaping () -> Void) {
        self.apply = apply; self.close = close; self.showHeader = showHeader
        _draft = State(initialValue: text)
    }
    private func confirm() {
        if apply(draft) { close() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showHeader { HStack {
                Text("Text Editor").font(.jarasHeadline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Cancel")
            } }
            #if os(macOS)
            TextItemNotepad(text: $draft, apply: confirm, cancel: close)
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(JarasTheme.line, lineWidth: 1))
            #else
            TextEditor(text: $draft).frame(height: 180)
            #endif
            HStack {
                Spacer()
                Text("\(ItemTextColors.plain(draft).unicodeScalars.count)")
                    .monospacedDigit()
                Text("characters")
            }.font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            Text("Command+Enter to apply; Enter for a new line.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply", action: confirm).keyboardShortcut(.return, modifiers: .command)
            }.buttonStyle(.bordered)
        }.padding(18).frame(width: 430)
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}

#if os(macOS)
import AppKit

private struct TextItemNotepad: NSViewRepresentable {
    @Binding var text: String
    let apply: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let editor = TextItemNotepadView()
        editor.isRichText = true; editor.importsGraphics = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .jarasSystemFont(ofSize: 14)
        editor.textColor = NSColor(JarasTheme.text)
        editor.insertionPointColor = NSColor(JarasTheme.green)
        editor.backgroundColor = NSColor(JarasTheme.background)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 180)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.loadColoredText(text); editor.delegate = context.coordinator
        editor.apply = apply; editor.cancel = cancel
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? TextItemNotepadView else { return }
        editor.apply = apply; editor.cancel = cancel
        if ItemTextColors.runs(editor.encodedText) != ItemTextColors.runs(text) { editor.loadColoredText(text) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextItemNotepad
        init(_ parent: TextItemNotepad) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = (editor as? TextItemNotepadView)?.encodedText ?? editor.string
        }
    }
}

private final class TextItemNotepadView: NSTextView {
    var apply: () -> Void = {}
    var cancel: () -> Void = {}
    private static let colorKey = NSAttributedString.Key("CatLiveItemColor")
    private var paletteWindow: NSPanel?
    var encodedText: String {
        guard let storage = textStorage else { return string }
        var runs: [ItemTextColors.Run] = []
        storage.enumerateAttribute(Self.colorKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            runs.append(.init(text: (storage.string as NSString).substring(with: range), color: (value as? NSNumber)?.uint32Value))
        }
        return ItemTextColors.encode(runs)
    }
    func loadColoredText(_ value: String) {
        let result = NSMutableAttributedString(string: "")
        for run in ItemTextColors.runs(value) {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.jarasSystemFont(ofSize: 14), .foregroundColor: NSColor(JarasTheme.text)]
            if let color = run.color { attributes[.foregroundColor] = NSColor(Color(hex: color)); attributes[Self.colorKey] = NSNumber(value: color) }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        textStorage?.setAttributedString(result)
    }
    func applyTextColor(_ color: UInt32, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length,
              shouldChangeText(in: range, replacementString: nil) else { return }
        textStorage?.addAttributes([.foregroundColor: NSColor(Color(hex: color)), Self.colorKey: NSNumber(value: color)], range: range)
        didChangeText()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let selected = selectedRange()
        guard selected.length > 0, let parent = window, paletteWindow == nil else { return super.menu(for: event) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("Text color", comment: "")
        let dismiss: () -> Void = { [weak self, weak parent, weak panel] in
            guard let panel else { return }; parent?.endSheet(panel); panel.orderOut(nil); self?.paletteWindow = nil
        }
        panel.contentView = NSHostingView(rootView: ItemTextColorPalette(pick: { [weak self] color in
            guard let self, NSMaxRange(selected) <= (self.string as NSString).length else { dismiss(); return }
            self.applyTextColor(color, range: selected)
            dismiss(); parent.makeFirstResponder(self); self.setSelectedRange(selected)
        }, cancel: dismiss))
        paletteWindow = panel
        parent.beginSheet(panel)
        return nil
    }
    private var initiallyFocused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !initiallyFocused else { return }
        initiallyFocused = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel(); return }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) { apply(); return }
        super.keyDown(with: event)
    }
}
#endif

struct ItemNameEditor: View {
    let apply: (String) -> Bool
    let close: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool
    init(name: String, apply: @escaping (String) -> Bool, close: @escaping () -> Void) {
        self.apply = apply; self.close = close; _name = State(initialValue: name)
    }
    private func confirm() { if apply(name) { close() } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Editar nome").font(.jarasHeadline)
            TextField("Nome do item", text: $name).focused($focused).onSubmit(confirm)
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: confirm).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(.bordered)
        }.padding(24).frame(width: 380).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { focused = true }
    }
}

import UniformTypeIdentifiers
struct MIDIItemDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "mid") ?? .data] }
    let data: Data
    init(clip: AudioClip) throws { data = try MIDIItemExport.data(for: clip) }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ItemTextColorPalette: View {
    let pick: (UInt32) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Text("Text color").font(.jarasHeadline)
            HStack(spacing: 10) {
                ForEach(ItemTextColors.palette, id: \.self) { color in
                    Button { pick(color) } label: {
                        RoundedRectangle(cornerRadius: 6).fill(Color(hex: color)).frame(width: 30, height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.4)))
                    }.buttonStyle(.plain).accessibilityLabel(String(format: "#%06X", color))
                }
            }
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }.padding(20).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}
extension ItemTextColors {
    static func view(_ value: String, display: (String) -> String = { $0 }, fallback: Color? = nil) -> Text {
        runs(value).reduce(Text("")) { result, run in
            let part = Text(verbatim: display(run.text))
            return result + ((run.color.map { Color(hex: $0) } ?? fallback).map { part.foregroundColor($0) } ?? part)
        }
    }
    #if os(macOS)
    static func attributed(_ value: String, font: NSFont, fallback: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        for run in runs(value) { text.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: run.color.map { NSColor(Color(hex: $0)) } ?? fallback])) }
        return text
    }
    #endif
}
