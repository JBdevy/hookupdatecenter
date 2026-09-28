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
    let maximumLength: Int
    let apply: (String) -> Bool
    let close: () -> Void
    @State private var draft: String
    @State private var limitReached = false
    init(text: String, maximumLength: Int = AudioClip.maximumTextLength, apply: @escaping (String) -> Bool, close: @escaping () -> Void) {
        self.maximumLength = maximumLength
        self.apply = apply; self.close = close
        _draft = State(initialValue: text)
    }
    private func confirm() {
        guard draft.unicodeScalars.count <= maximumLength else { limitReached = true; return }
        if apply(draft) { close() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Text Editor").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Cancel")
            }
            #if os(macOS)
            TextItemNotepad(text: $draft, maximumLength: maximumLength, exceeded: { limitReached = true }, apply: confirm, cancel: close)
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(limitReached ? Color.red : JarasTheme.line, lineWidth: 1))
            #else
            TextEditor(text: $draft).frame(height: 180)
                .onChange(of: draft) { value in
                    if value.unicodeScalars.count > maximumLength {
                        draft = String(String.UnicodeScalarView(value.unicodeScalars.prefix(maximumLength)))
                        limitReached = true
                    }
                }
            #endif
            HStack {
                if limitReached { Text("Maximum \(maximumLength) characters.").foregroundStyle(.red) }
                Spacer()
                Text("\(draft.unicodeScalars.count)/\(maximumLength)")
                    .monospacedDigit()
                Text("characters")
            }.font(.caption).foregroundStyle(JarasTheme.secondary)
            Text("Command+Enter to apply; Enter for a new line.").font(.caption).foregroundStyle(JarasTheme.secondary)
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply", action: confirm).keyboardShortcut(.return, modifiers: .command)
            }.buttonStyle(.bordered)
        }.padding(18).frame(width: 430)
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onChange(of: draft) { _ in limitReached = false }
    }
}

#if os(macOS)
import AppKit

private struct TextItemNotepad: NSViewRepresentable {
    @Binding var text: String
    let maximumLength: Int
    let exceeded: () -> Void
    let apply: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let editor = TextItemNotepadView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = NSColor(JarasTheme.text)
        editor.insertionPointColor = NSColor(JarasTheme.green)
        editor.backgroundColor = NSColor(JarasTheme.background)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 180)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = context.coordinator
        editor.apply = apply; editor.cancel = cancel
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? TextItemNotepadView else { return }
        editor.apply = apply; editor.cancel = cancel
        if editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextItemNotepad
        init(_ parent: TextItemNotepad) { self.parent = parent }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            guard let range = Range(affectedCharRange, in: textView.string) else { return false }
            let candidate = textView.string.replacingCharacters(in: range, with: replacementString)
            guard candidate.unicodeScalars.count <= parent.maximumLength else { parent.exceeded(); return false }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class TextItemNotepadView: NSTextView {
    var apply: () -> Void = {}
    var cancel: () -> Void = {}
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
