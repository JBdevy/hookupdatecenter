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
    @StateObject private var purchases = NativePurchaseStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("jaras.language") private var language = "en"
    @State private var native = false
    @State private var remote = false
    @State private var entering = false
    @State private var starting = true
    @State private var error = ""
    @State private var showingPurchase = false
    @State private var pendingPackage: URL?
    var body: some View {
        Group {
            if native, let container = bootstrap.container {
                RootView(container: container, leaveNative: { leave(container) })
                    .modifier(NativeTrialSession(show: container.show, purchases: purchases) { showingPurchase = true })
            } else if starting {
                StartupView(progress: nil, stage: "Iniciando…")
            } else {
                VStack(spacing: 26) {
                    Image("CatLiveSplash").resizable().scaledToFit().frame(width: 200, height: 200)
                    HStack(spacing: 22) {
                        mode("Native", detail: "Play your projects directly on this iPad.", icon: "waveform", action: { enter() })
                        mode("Remote", detail: "Control or follow your PC’s session.", icon: "network", action: { remote = true })
                    }.frame(maxWidth: 760)
                    if !purchases.unlocked, purchases.trialDaysRemaining > 0 {
                        HStack {
                            Text("Free trial: \(purchases.trialDaysRemaining) day(s) remaining")
                            Button("Unlock Native mode") { showingPurchase = true }
                        }.font(.callout).foregroundStyle(JarasTheme.green)
                    }
                    if entering { ProgressView() }
                    if !error.isEmpty { Text(LocalizedStringKey(error)).foregroundStyle(.red).multilineTextAlignment(.center) }
                    Picker("Language", selection: $language) {
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Português").tag("pt-BR")
                    }.pickerStyle(.segmented).frame(maxWidth: 360)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RemoteSurface.background)
            }
        }
        .preferredColorScheme(.dark).environment(\.locale, Locale(identifier: language))
        .fullScreenCover(isPresented: $remote) { DAWRemoteClientView().environment(\.locale, Locale(identifier: language)) }
        .fullScreenCover(isPresented: $showingPurchase) {
            IpadNativePurchaseView(store: purchases, close: { showingPurchase = false; pendingPackage = nil }, openNative: {
                showingPurchase = false
                let package = pendingPackage; pendingPackage = nil
                enter(package: package)
            }).environment(\.locale, Locale(identifier: language))
        }
        .task { do { try await Task.sleep(nanoseconds: 3_000_000_000); starting = false } catch {} }
        .task { await purchases.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await purchases.refresh() } }
        }
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
                .background(RemoteSurface.panel)
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
            await purchases.refresh()
            guard purchases.canAccessNative else {
                pendingPackage = package; showingPurchase = true; starting = false
                return
            }
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

/// Present the unlock screen after playback ends, without cutting a performance or deleting work.
private struct NativeTrialSession: ViewModifier {
    let show: ShowController
    @ObservedObject var purchases: NativePurchaseStore
    let expired: () -> Void
    @StateObject private var updates: ShowPresentationObserver
    init(show: ShowController, purchases: NativePurchaseStore, expired: @escaping () -> Void) {
        self.show = show; self.purchases = purchases; self.expired = expired
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    func body(content: Content) -> some View {
        content.onChange(of: purchases.canAccessNative) { allowed in
            if !allowed && !show.isPlaying { expired() }
        }.onChange(of: show.isPlaying) { playing in
            if !playing && !purchases.canAccessNative { expired() }
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
        let types: [UTType] = (kind == .stems || kind == .storage || kind == .packageDestination) ? [.folder] : kind == .trackAudio ? [.mp3, .wav, .aiff] : kind == .trackMedia ? [.image, .movie] : [.catLivePackage, .zip]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: kind == .trackAudio || kind == .trackMedia)
        picker.allowsMultipleSelection = kind == .stems
        if kind == .stems { picker.title = JarasLocalization.string("Choose the folder containing your song folders") }
        if kind == .storage { picker.title = JarasLocalization.string("Choose an external folder for CatLive projects") }
        if kind == .package { picker.title = JarasLocalization.string("Choose a CatLive project") }
        if kind == .packageDestination { picker.title = JarasLocalization.string("Choose a folder for the imported project") }
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let owner: NativeProjectPicker
        private var completed = false
        init(_ owner: NativeProjectPicker) { self.owner = owner }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
            owner.picked(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
            owner.cancelled()
        }
    }
}

/// Keep the granted URLs alive until the picker has completely dismissed and
/// ProjectDocuments has taken ownership of its own security-scoped access.
private final class NativeProjectPickerSelection {
    let urls: [URL]
    let kind: ProjectDocuments.NativePicker
    private let scopedURLs: [URL]
    init(urls: [URL], kind: ProjectDocuments.NativePicker) {
        self.urls = urls; self.kind = kind
        scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { for url in scopedURLs { url.stopAccessingSecurityScopedResource() } }
}

struct NativeProjectPresentation: ViewModifier {
    @ObservedObject var documents: ProjectDocuments
    @State private var pickerSelection: NativeProjectPickerSelection?
    @State private var presentedPicker: ProjectDocuments.NativePicker?
    func body(content: Content) -> some View {
        content
            .sheet(item: $documents.nativePicker, onDismiss: pickerDismissed) { kind in
                NativeProjectPicker(kind: kind, picked: { urls in
                    guard documents.nativePicker == kind, pickerSelection == nil else { return }
                    pickerSelection = NativeProjectPickerSelection(urls: urls, kind: kind)
                    documents.nativePicker = nil
                }, cancelled: { if documents.nativePicker == kind { documents.nativePicker = nil } })
                    // UIKit's Files controller handles its own keyboard and
                    // rename popovers; a second SwiftUI resize can steal focus.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .onAppear { presentedPicker = kind }
            }
            .alert(item: $documents.nativePackagePrompt) { prompt in
                Alert(title: Text(LocalizedStringKey(prompt.title)),
                      message: Text(LocalizedStringKey(prompt.message)),
                      primaryButton: .default(Text(LocalizedStringKey(prompt.action))) { documents.continueNativePackageImport(prompt) },
                      secondaryButton: .cancel(Text("Cancel")) { documents.cancelNativePackageImport() })
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
    private func pickerDismissed() {
        let selection = pickerSelection, kind = presentedPicker
        pickerSelection = nil; presentedPicker = nil
        if let selection {
            documents.receiveNativeFiles(selection.urls, kind: selection.kind)
        } else if let kind {
            documents.cancelNativePicker(kind: kind)
        }
    }
}
#endif
