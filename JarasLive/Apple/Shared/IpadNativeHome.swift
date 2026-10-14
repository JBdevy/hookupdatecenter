#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let catLivePackage = UTType(exportedAs: "com.hookdeveloper.catlive.ziplive", conformingTo: .zip)
}

/// iPhone never constructs this view or a local audio container.
@MainActor struct IpadNativeHome: View {
    @ObservedObject var bootstrap: Bootstrap
    @AppStorage("jaras.language") private var language = "en"
    @State private var native = false
    @State private var remote = false
    @State private var entering = false
    @State private var starting = true
    @State private var error = ""
    var body: some View {
        Group {
            if native, let container = bootstrap.container {
                RootView(container: container, leaveNative: { leave(container) })
            } else if starting {
                StartupView(progress: nil, stage: "Iniciando…")
            } else {
                VStack(spacing: 26) {
                    Image("CatLiveSplash").resizable().scaledToFit().frame(width: 200, height: 200)
                    HStack(spacing: 22) {
                        mode("Native", detail: "Play your projects directly on this iPad.", icon: "waveform", action: { enter() })
                        mode("Remote", detail: "Control or follow your PC’s session.", icon: "network", action: { remote = true })
                    }.frame(maxWidth: 760)
                    if entering { ProgressView() }
                    if !error.isEmpty { Text(LocalizedStringKey(error)).foregroundStyle(.red).multilineTextAlignment(.center) }
                    Picker("Language", selection: $language) {
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Português").tag("pt-BR")
                    }.pickerStyle(.segmented).frame(maxWidth: 360)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .preferredColorScheme(.dark).environment(\.locale, Locale(identifier: language))
        .fullScreenCover(isPresented: $remote) { DAWRemoteClientView().environment(\.locale, Locale(identifier: language)) }
        .task { do { try await Task.sleep(nanoseconds: 3_000_000_000); starting = false } catch {} }
        .onOpenURL { url in
            guard ["ziplive", "zip"].contains(url.pathExtension.lowercased()) else { return }
            if !native { enter(package: url) }
        }
    }
    private func mode(_ name: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(JarasTheme.green)
                Text(LocalizedStringKey(name)).font(.title2.bold())
                Text(LocalizedStringKey(detail)).font(.body).foregroundStyle(JarasTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(26).frame(maxWidth: .infinity, minHeight: 195, alignment: .leading)
                .background(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(JarasTheme.green.opacity(0.35)))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(entering).accessibilityIdentifier("catlive-mode-" + name.lowercased())
    }
    private func enter(package: URL? = nil) {
        guard !entering else { return }
        entering = true; error = ""
        Task {
            defer { entering = false }
            if bootstrap.container == nil { bootstrap.retry() }
            guard let container = bootstrap.container else { error = bootstrap.error ?? "Could not open Native mode."; return }
            guard await container.setLocalPlaybackEnabled(true) else { error = container.show.message; return }
            JarasMobileApplicationDelegate.setObserverOrientation(false)
            native = true; starting = false
            if let package { container.documents.importPortablePackage(package) }
        }
    }
    private func leave(_ container: AppContainer) {
        guard !entering, !container.documents.busy else { return }
        entering = true
        Task {
            defer { entering = false }
            guard await container.setLocalPlaybackEnabled(false) else { error = container.show.message; return }
            do {
                if container.documents.ready { try await container.show.saveForClosing() }
                native = false
            } catch {
                container.documents.error = error.localizedDescription
                _ = await container.setLocalPlaybackEnabled(true)
            }
        }
    }
}

/// Hold security-scoped folder access through scan, ordering and media copy.
private struct NativeProjectPicker: UIViewControllerRepresentable {
    let kind: ProjectDocuments.NativePicker
    let picked: ([URL]) -> Void
    let cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = (kind == .stems || kind == .storage) ? [.folder] : kind == .trackAudio ? [.mp3, .wav, .aiff] : kind == .trackMedia ? [.image, .movie] : [.catLivePackage, .zip]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: kind == .trackAudio || kind == .trackMedia)
        picker.allowsMultipleSelection = kind == .stems
        if kind == .stems { picker.title = JarasLocalization.string("Choose the folder containing your song folders") }
        if kind == .storage { picker.title = JarasLocalization.string("Choose an external folder for CatLive projects") }
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let owner: NativeProjectPicker
        init(_ owner: NativeProjectPicker) { self.owner = owner }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { owner.picked(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { owner.cancelled() }
    }
}

struct NativeProjectPresentation: ViewModifier {
    @ObservedObject var documents: ProjectDocuments
    func body(content: Content) -> some View {
        content
            .sheet(item: $documents.nativePicker) { kind in
                NativeProjectPicker(kind: kind, picked: { documents.receiveNativeFiles($0, kind: kind) }, cancelled: { documents.cancelNativePicker(kind: kind) })
            }
            .alert("Import", isPresented: Binding(get: { !documents.audioImportError.isEmpty }, set: { if !$0 { documents.audioImportError = "" } })) {
                Button("OK") { documents.audioImportError = "" }
            } message: { Text(verbatim: documents.audioImportError) }
            .alert("Project name", isPresented: $documents.nativeNamePrompt) {
                TextField("Project name", text: $documents.nativeProjectName)
                Button("Cancel", role: .cancel) { documents.cancelNativeProjectName() }
                Button("Create") { documents.confirmNativeProjectName() }
            }
    }
}
#endif
