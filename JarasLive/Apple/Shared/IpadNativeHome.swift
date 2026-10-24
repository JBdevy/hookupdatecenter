#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import Combine

extension UTType {
    static let catLivePackage = UTType(exportedAs: "com.hookdeveloper.catlive.ziplive", conformingTo: .zip)
}

/// Every open document retains its controller and audio graph. Only the selected
/// project owns live input, MIDI mappings and the visible workspace.
@MainActor final class NativeProjectTabs: ObservableObject {
    static let shared = NativeProjectTabs()
    @Published private(set) var projects: [AppContainer] = []
    @Published private(set) var selected = 0
    @Published private(set) var transitioning = false
    @Published var error = ""
    private var openingObservers: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    var active: AppContainer? { projects.indices.contains(selected) ? projects[selected] : nil }
    func isForeground(_ show: ShowController?) -> Bool { projects.isEmpty || active?.show === show }
    func hasEnabledAudio(excluding container: AppContainer) -> Bool {
        projects.contains { $0 !== container && $0.localPlaybackEnabled }
    }
    func handleAudioEvent(_ event: MobileAudioSessionEvent) {
        for project in projects { project.handleMobileAudioEvent(event) }
    }
    func install(_ initial: AppContainer) {
        guard projects.isEmpty else { return }
        projects = [initial]; configure(initial); publishTabs()
        DAWRemoteHostBridge.projectTabsProvider = { [weak self] in
            guard let self else { return [] }
            return projects.enumerated().map { index, project in
                .init(id: project.remoteProjectTabID, name: project.documents.currentURL?.deletingPathExtension().lastPathComponent ?? project.show.snapshot.project.name, selected: index == self.selected)
            }
        }
        DAWRemoteHostBridge.selectProjectTabHandler = { [weak self] id in
            guard let self, let index = projects.firstIndex(where: { $0.remoteProjectTabID == id }) else { return }
            select(index)
        }
    }
    private var canChange: Bool {
        !transitioning && active?.documents.busy != true && active?.documents.importingAudio != true &&
        !TrackRecording.shared.recording && !TrackRecording.shared.busy
    }
    private func publishTabs() {
        for project in projects {
            project.documents.projectTabCount = projects.count
            project.documents.projectTabIndex = selected
        }
    }
    private func configure(_ container: AppContainer) {
        container.documents.openInNewProjectTab = { [weak self] in self?.open($0) }
        container.documents.activateExistingProjectTab = { [weak self, weak container] url in
            guard let self else { return false }
            guard let index = projects.firstIndex(where: { $0 !== container && self.canonical($0.documents.currentURL) == self.canonical(url) }) else { return false }
            select(index); return true
        }
        container.documents.navigateProjectTab = { [weak self] in self?.navigate($0) }
        container.show.navigateProjectTab = { [weak self] in self?.navigate($0) }
        container.documents.additionalProtectedMediaURLs = { [weak self, weak container] in
            guard let self else { return [] }
            var urls = Set<URL>()
            for project in projects where project !== container {
                urls.formUnion(project.projectAudio.activeMediaURLs)
                if let directory = project.documents.currentURL?.deletingLastPathComponent() {
                    urls.formUnion(project.show.snapshot.project.mediaPaths.map { directory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() })
                }
            }
            return urls
        }
    }
    private func canonical(_ url: URL?) -> URL? { url?.standardizedFileURL.resolvingSymlinksInPath() }
    func navigate(_ direction: Int) {
        guard let index = ProjectTabNavigation.destination(current: selected, count: projects.count, direction: direction) else { return }
        select(index)
    }
    func select(_ index: Int) {
        guard canChange, projects.indices.contains(index), index != selected else { return }
        activate(index)
    }
    private func activate(_ index: Int) {
        if let old = active {
            old.projectAudio.releaseKeyboardNotes()
            old.projectAudio.setArmedInstrumentTracks([])
            old.projectRecorder.suspendProjectTab()
        }
        selected = index
        let next = projects[index]
        StemAudioPlayback.shared = next.projectAudio
        TrackRecording.shared = next.projectRecorder
        next.projectRecorder.bind(next.show)
        let instruments = Set(next.show.snapshot.project.songs.flatMap(\.tracks).filter { $0.fx?.instrumentKeys.isEmpty == false }.map(\.id))
        next.projectAudio.setArmedInstrumentTracks(next.projectRecorder.armed.intersection(instruments))
        next.projectAudio.armedMIDIRecordingTracks = next.projectRecorder.armed.intersection(Set(next.show.snapshot.project.songs.flatMap(\.tracks).filter { $0.recordingMode == .midi }.map(\.id)))
        let directory = next.documents.currentURL?.deletingLastPathComponent()
        InstrumentLibrary.shared.setProjectDirectory(directory)
        if let directory {
            VideoPlayback.teleprompter.open(directory: directory)
            VideoPlayback.teleprompter2.open(directory: directory)
            TeleprompterRemote.setProjectDirectory(directory)
        }
        DAWRemoteHostBridge.documents = next.documents
        DAWRemoteHostBridge.bind(next.show, session: .nativeHost)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        next.documents.recent = (UserDefaults.standard.stringArray(forKey: "jaras.recentProjects") ?? []).map { NativeRecentProjectPath.resolve($0, documents: documents) }
        publishTabs()
    }
    func open(_ url: URL) {
        guard canChange, let previous = active, previous.documents.ready else { return }
        if let index = projects.firstIndex(where: { canonical($0.documents.currentURL) == canonical(url) }) { select(index); return }
        transitioning = true
        Task { @MainActor in
            defer { transitioning = false }
            do {
                let engine = AVAudioEngine()
                let audio = StemAudioPlayback(engine: engine, mobileOutput: JarasMobileAudioOutput(engine: engine), auxiliarySelectedHardware: true)
                let next = try AppContainer(sharedAuth: previous.auth, audio: audio)
                configure(next)
                guard await next.setLocalPlaybackEnabled(true) else { throw ProjectError.invalid(next.show.message) }
                projects.append(next); activate(projects.count - 1)
                watchOpening(next, fallback: previous)
                next.documents.open(url)
            } catch { previous.documents.error = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    private func watchOpening(_ project: AppContainer, fallback: AppContainer) {
        let id = ObjectIdentifier(project)
        var subscriptions = Set<AnyCancellable>()
        let check: () -> Void = { [weak self, weak project, weak fallback] in
            DispatchQueue.main.async {
                guard let self, let project, let fallback, self.openingObservers[id] != nil,
                      !project.documents.busy else { return }
                if project.documents.ready { self.openingObservers.removeValue(forKey: id); return }
                guard project.documents.missingAudioPrompt == nil else { return }
                self.openingObservers.removeValue(forKey: id)
                Task { @MainActor in
                    self.transitioning = true
                    defer { self.transitioning = false }
                    let error = project.documents.error
                    _ = await project.setLocalPlaybackEnabled(false)
                    project.projectAudio.prepareForClosing()
                    guard let index = self.projects.firstIndex(where: { $0 === project }),
                          let previous = self.projects.firstIndex(where: { $0 === fallback }) else { return }
                    if self.active === project { self.activate(previous) }
                    self.projects.remove(at: index)
                    if self.selected > index { self.selected -= 1 }
                    self.publishTabs()
                    fallback.documents.error = error
                    self.error = error
                }
            }
        }
        project.documents.$busy.dropFirst().sink { busy in if !busy { check() } }.store(in: &subscriptions)
        project.documents.$missingAudioPrompt.dropFirst().sink { _ in check() }.store(in: &subscriptions)
        openingObservers[id] = subscriptions
    }
    func close(_ id: UUID) async {
        guard canChange, let index = projects.firstIndex(where: { $0.remoteProjectTabID == id }) else { return }
        activate(index); transitioning = true
        defer { transitioning = false }
        let project = projects[index]
        guard await project.closeNativeProject(resumeAudio: projects.count == 1) else { error = project.documents.error; return }
        if projects.count > 1 {
            activate(index == 0 ? 1 : index - 1)
            projects.remove(at: index)
            if selected > index { selected -= 1 }
            publishTabs()
        }
    }
    func leave() async -> Bool {
        guard canChange else { return false }
        transitioning = true
        defer { transitioning = false }
        // Save every project before closing any, so a failed save preserves all tabs.
        do {
            for project in projects where project.documents.ready {
                try await project.show.saveForClosing()
                try await project.documents.rememberProjectMedia()
            }
        } catch { active?.documents.error = error.localizedDescription; return false }
        for index in projects.indices {
            activate(index)
            guard await projects[index].closeNativeProject(resumeAudio: false) else { return false }
        }
        activate(0); projects = [projects[0]]; publishTabs()
        return true
    }
}

@MainActor private struct NativeProjectTabBar: View {
    @ObservedObject var tabs: NativeProjectTabs
    @State private var closing: UUID?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tabs.projects.enumerated()), id: \.element.remoteProjectTabID) { index, project in
                    HStack(spacing: 0) {
                        Button { tabs.select(index) } label: {
                            Text(project.documents.currentURL?.deletingPathExtension().lastPathComponent ?? project.show.snapshot.project.name)
                                .font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
                                .frame(minWidth: 100, maxWidth: 230).padding(.horizontal, 12).frame(height: 38)
                                .contentShape(Rectangle())
                        }
                        Button { closing = project.remoteProjectTabID } label: {
                            Image(systemName: "xmark").font(.jarasSystem(size: 12)).frame(width: 38, height: 38).contentShape(Rectangle())
                        }.accessibilityLabel("Close tab")
                    }.buttonStyle(.plain)
                        .foregroundStyle(index == tabs.selected ? JarasTheme.green : JarasTheme.text)
                        .background(index == tabs.selected ? JarasTheme.panel : JarasTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }.padding(4)
        }.background(JarasTheme.background)
            .alert("Close tab", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                Button("Cancel", role: .cancel) { closing = nil }
                Button("Save and close") { if let id = closing { closing = nil; Task { await tabs.close(id) } } }
            } message: { Text("The project will be saved before closing.") }
    }
}

/// iPhone never constructs this view or a local audio container.
@MainActor struct IpadNativeHome: View {
    @ObservedObject var bootstrap: Bootstrap
    @StateObject private var purchases = NativePurchaseStore.shared
    @StateObject private var tabs = NativeProjectTabs.shared
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
            if native, let container = tabs.active ?? bootstrap.container {
                VStack(spacing: 0) {
                    if tabs.projects.count > 1 { NativeProjectTabBar(tabs: tabs) }
                    RootView(container: container, leaveNative: { leave(container) })
                        .id(ObjectIdentifier(container))
                }
                .modifier(NativeTrialSession(show: container.show, purchases: purchases) { showingPurchase = true })
                .disabled(tabs.transitioning)

            } else if starting {
                StartupView(progress: nil, stage: "Iniciando…")
            } else {
                VStack(spacing: 26) {
                    Image("CatLiveSplash").resizable().scaledToFit().frame(width: 200, height: 200)
                    HStack(spacing: 22) {
                        mode("Native", detail: "Play your projects directly on this iPad.", icon: "waveform", action: { enter() })
                        mode("Remote", detail: "Control or follow your PC’s session.", icon: "network", action: { remote = true })
                    }.frame(maxWidth: 760)
                    if !purchases.unlocked {
                        VStack(spacing: 8) {
                            if purchases.trialDaysRemaining > 0 {
                                Text("Free trial: \(purchases.trialDaysRemaining) day(s) remaining")
                            }
                            Button("Unlock Native mode") { showingPurchase = true }
                                .buttonStyle(.bordered).controlSize(.large)
                                .accessibilityIdentifier("catlive-home-unlock-native")
                        }.font(.jarasCallout).foregroundStyle(JarasTheme.green)
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
        .alert("Project", isPresented: Binding(get: { !tabs.error.isEmpty }, set: { if !$0 { tabs.error = "" } })) {
            Button("OK", role: .cancel) { tabs.error = "" }
        } message: { Text(LocalizedStringKey(tabs.error)) }
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
                Image(systemName: icon).font(.jarasSystem(size: 34)).foregroundStyle(JarasTheme.green)
                Text(LocalizedStringKey(name)).font(.jarasTitle2.bold())
                Text(LocalizedStringKey(detail)).font(.jarasBody).foregroundStyle(JarasTheme.secondary)
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
            tabs.install(container)
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
            guard await tabs.leave() else { error = tabs.active?.documents.error ?? container.documents.error; return }
            native = false
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
