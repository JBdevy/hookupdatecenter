import SwiftUI

struct FullLyricsTarget: Identifiable {
    let id = UUID()
    let project: UUID
    let song: UUID
    let track: UUID
    let range: FullLyricsRange
    @MainActor init(show: ShowController, track: UUID) throws {
        guard let song = show.current, song.tracks.contains(where: { $0.id == track && $0.kind.isTeleprompter }) else {
            throw ProjectError.invalid("The text track is no longer available.")
        }
        project = show.snapshot.project.id; self.song = song.id; self.track = track
        range = try FullLyricsRange(song: song, position: show.snapshot.transport.editPosition ?? show.snapshot.transport.position)
    }
}

private struct AddFullLyricsKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}
extension EnvironmentValues {
    var addFullLyrics: (UUID) -> Void {
        get { self[AddFullLyricsKey.self] }
        set { self[AddFullLyricsKey.self] = newValue }
    }
}

struct FullLyricsEditor: View {
    let show: ShowController
    let target: FullLyricsTarget
    let close: () -> Void
    @State private var draft = ""
    @State private var warning: String?
    private func createItems() {
        do {
            _ = try target.range.items(text: draft)
            if show.addFullLyrics(track: target.track, text: draft, range: target.range, project: target.project, song: target.song) { close() }
            else { warning = show.message ?? "Could not create the lyrics items." }
        } catch { warning = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full lyrics").font(.jarasHeadline)
            Text(verbatim: target.range.name).font(.jarasSystem(size: 14, weight: .semibold)).lineLimit(1)
            Text("Separate each stanza with two blank lines. Items will fill the whole song equally.")
                .font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.secondary)
            Group {
                #if os(macOS)
                TextItemNotepad(text: $draft, apply: createItems, cancel: close, outlineStanzas: true)
                #else
                NativeFullLyricsInput(text: $draft)
                #endif
            }
            .accessibilityLabel("Full lyrics").frame(minHeight: 150)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.secondary.opacity(0.35)).allowsHitTesting(false))
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create items", action: createItems).buttonStyle(.borderedProminent).tint(JarasTheme.green)
            }
        }.padding(18).background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .alert("Full lyrics", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("OK") { warning = nil }
            } message: { Text(LocalizedStringKey(warning ?? "")) }
    }
}


#if os(iOS)
import UIKit

private struct NativeFullLyricsInput: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = StanzaTextView(usingTextLayoutManager: false)
        view.backgroundColor = UIColor(JarasTheme.background)
        view.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        view.typingAttributes = StanzaTextView.defaultAttributes
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeFullLyricsInput
        init(parent: NativeFullLyricsInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            let storage = textView.textStorage
            var runs = [ItemTextColors.Run]()
            storage.enumerateAttribute(StanzaTextView.colorKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                runs.append(.init(text: (storage.string as NSString).substring(with: range), color: (value as? NSNumber)?.uint32Value))
            }
            parent.text = ItemTextColors.encode(runs)
            textView.setNeedsDisplay()
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            textView.typingAttributes = StanzaTextView.defaultAttributes
            return true
        }
        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let titles = ["White", "Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple"]
            let palette = zip(ItemTextColors.palette, titles).map { color, title in
                UIAction(title: JarasLocalization.string(title), image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(Color(hex: color)), renderingMode: .alwaysOriginal)) { [weak self, weak textView] _ in
                    guard let textView, NSMaxRange(range) <= textView.textStorage.length else { return }
                    textView.textStorage.addAttributes([.foregroundColor: UIColor(Color(hex: color)),
                        StanzaTextView.colorKey: NSNumber(value: color)], range: range)
                    self?.textViewDidChange(textView)
                }
            }
            return UIMenu(children: suggestedActions + [UIMenu(title: JarasLocalization.string("Text color"), children: palette)])
        }
    }
}
private final class StanzaTextView: UITextView {
    static let colorKey = NSAttributedString.Key("CatLiveItemColor")
    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor(JarasTheme.text)]
    }
    override func draw(_ rect: CGRect) {
        UIColor(JarasTheme.secondary.opacity(0.45)).setStroke()
        for range in FullLyrics.stanzaRanges(text ?? "") {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            box.origin.y += textContainerInset.top
            box.origin.x = 4
            box.size.width = bounds.width - 8
            box = box.insetBy(dx: 0, dy: -2)
            if rect.intersects(box) { UIBezierPath(roundedRect: box, cornerRadius: 4).stroke() }
        }
        super.draw(rect)
    }
}
#endif
