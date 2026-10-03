#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ClickSoundDesigner: View {
    @ObservedObject var show: ShowController
    let track: UUID
    let directory: URL?
    let close: () -> Void
    @State private var busy = false
    @State private var error = ""
    private var sound: AudioFile? { show.current?.tracks.first { $0.id == track }?.clickSound }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sound Designer", systemImage: "waveform").font(.headline).foregroundStyle(JarasTheme.green)
            Text(sound.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Click padrão")
                .font(.system(size: 13, weight: .medium)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.black.opacity(0.3)).cornerRadius(8)
            Text("WAV, AIFF ou MP3. O som escolhido será copiado para a pasta Stems deste projeto.")
                .font(.caption).foregroundStyle(JarasTheme.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Escolher arquivo…", action: choose).disabled(busy || directory == nil)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Usar padrão") { show.setClickSound(track: track, file: nil); error = "" }.disabled(busy || sound == nil)
            }.buttonStyle(.bordered)
            HStack { Spacer(); Button("Fechar", action: close).keyboardShortcut(.cancelAction).disabled(busy) }
        }.padding(22).frame(width: 360).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
    private func choose() {
        guard let directory, show.canExecute() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["wav", "aif", "aiff", "mp3"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let project = show.snapshot.project.id
        busy = true; error = ""
        Task {
            defer { busy = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    let file = try ClickSoundImport.copy(source, to: directory)
                    do { _ = try ClickAudioSample.load(sampleRate: 48000, url: directory.appendingPathComponent(file.path)) }
                    catch { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.path).deletingLastPathComponent()); throw error }
                    return file
                }.value
                guard show.snapshot.project.id == project else {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.path).deletingLastPathComponent()); return
                }
                show.setClickSound(track: track, file: file)
                if sound != file {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.path).deletingLastPathComponent())
                    error = show.message
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
