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
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full lyrics").font(.jarasHeadline)
            Text(verbatim: target.range.name).font(.jarasSystem(size: 14, weight: .semibold)).lineLimit(1)
            Text("Separate each stanza with two blank lines. Items will fill the whole song equally.")
                .font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.secondary)
            TextEditor(text: $draft).font(.jarasSystem(size: 15)).focused($focused)
                .accessibilityLabel("Full lyrics").frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.secondary.opacity(0.35)))
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create items") {
                    do {
                        _ = try target.range.items(text: draft)
                        if show.addFullLyrics(track: target.track, text: draft, range: target.range, project: target.project, song: target.song) { close() }
                        else { warning = show.message ?? "Could not create the lyrics items." }
                    } catch { warning = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(JarasTheme.green)
            }
        }.padding(18).background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .onAppear { focused = true }
            .alert("Full lyrics", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("OK") { warning = nil }
            } message: { Text(LocalizedStringKey(warning ?? "")) }
    }
}
