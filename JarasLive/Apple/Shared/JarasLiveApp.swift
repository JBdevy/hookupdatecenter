import SwiftUI
@MainActor final class Bootstrap: ObservableObject {
    @Published var container: AppContainer?
    @Published var error: String?
    init() { retry() }
    func retry() { do { container = try AppContainer(); error = nil } catch { self.error = error.localizedDescription } }
}
@main @MainActor struct JarasLiveApp: App {
    @StateObject private var bootstrap = Bootstrap()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(JarasApplicationDelegate.self) private var appDelegate
    #endif
    @ViewBuilder private var appContent: some View {
        if let container = bootstrap.container { RootView(container: container) }
        else { VStack(spacing: 20) { Text("CatLive").font(.largeTitle.bold()); Text(LocalizedStringKey(bootstrap.error ?? "Iniciando…")); Button("Tentar novamente") { bootstrap.retry() } }.padding(40) }
    }
    var body: some Scene {
        #if os(macOS)
        Window("CatLive", id: "main") { appContent }
            .defaultSize(width: ProjectWindowAnchor.editorFrameSize.width, height: ProjectWindowAnchor.editorFrameSize.height)
            .windowStyle(.hiddenTitleBar)
        #else
        WindowGroup("CatLive") { appContent.statusBarHidden(true).persistentSystemOverlays(.hidden) }
        #endif
    }
}
struct RootView: View {
    @AppStorage("jaras.language") private var language = "en"
    @ObservedObject var container: AppContainer
    @ObservedObject private var auth: AuthService
    @ObservedObject private var documents: ProjectDocuments
    init(container: AppContainer) { self.container = container; auth = container.auth; documents = container.documents }
    private var canEnter: Bool {
        #if os(iOS)
        true
        #else
        auth.workspaceAllowed
        #endif
    }
    var body: some View {
        Group {
            if container.starting {
                StartupView(progress: container.startupProgress, stage: container.startupStage)
            } else if canEnter {
                if documents.ready { MainView(show: container.show, auth: auth, backend: container.backend, documents: documents) }
                else { ProjectBrowserView(documents: documents) }
            }
            else if [.launching,.checkingSession,.checkingLicense,.checkingDevice].contains(auth.phase) {
                StartupView(progress: nil, stage: "Validando acesso…")
            } else { LoginView(auth: auth, backend: container.backend) }
        }
        #if os(macOS)
        .frame(minWidth: documents.ready ? 1408 : 600, minHeight: documents.ready ? 650 : 460)
        .background(TrialTitlebar(auth: auth))
        .background(ProjectWindowSizing(editor: documents.ready, documents: documents))
        .overlay {
            GeometryReader { geometry in
                JarasTheme.titlebar
                    .frame(height: geometry.safeAreaInsets.top)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(JarasTheme.line.opacity(0.65)).frame(height: 1)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
        .overlay { if !container.starting { LicenseNotice(auth: auth, backend: container.backend) } }
        .background(FloatingStartup(active: container.starting, progress: container.startupProgress, stage: container.startupStage, language: language))
        #endif
        .onOpenURL { url in if ["jl", "bkjl", "logicx", "rpp"].contains(url.pathExtension.lowercased()) { documents.open(url) } }
        .sheet(item: $documents.missingAudioPrompt) { _ in
            MissingAudioRecoveryView(documents: documents)
        }
        .alert("Project migration", isPresented: Binding(get: { !documents.migrationNotice.isEmpty }, set: { if !$0 { documents.migrationNotice = "" } })) {
            Button("OK") { documents.migrationNotice = "" }
        } message: { Text(documents.migrationNotice) }
        .overlay(alignment: .top) {
            if !documents.closeNotice.isEmpty {
                Text(LocalizedStringKey(documents.closeNotice)).font(.callout)
                    .padding(12).background(JarasTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 20)
                    .accessibilityAddTraits(.updatesFrequently)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .scrollIndicators(.hidden)
        .environment(\.locale, Locale(identifier: language)).task { await container.start() }
    }
}
struct UnauthorizedPreview: PreviewProvider { static var previews: some View { let container = try! AppContainer(preview: true); LoginView(auth: container.auth, backend: container.backend).frame(width: 1100, height: 720) } }

struct StartupView: View {
    let progress: Double?
    let stage: String
    var transparent = false
    @State private var pulse = false
    var body: some View {
        ZStack {
            if !transparent { JarasTheme.background.ignoresSafeArea() }
            VStack(spacing: 22) {
                Image("CatLiveSplash").resizable().scaledToFit()
                    .frame(width: 330, height: 330).accessibilityLabel("CatLive")
                Group {
                    if let progress {
                        GeometryReader { geometry in
                            Capsule().fill(JarasTheme.green.opacity(0.14))
                            Capsule().fill(JarasTheme.green)
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                                .opacity(pulse ? 1 : 0.55)
                                .shadow(color: JarasTheme.green.opacity(pulse ? 0.5 : 0.15), radius: pulse ? 5 : 2)
                        }.frame(height: 5)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(JarasTheme.green)
                    }
                }.frame(width: 300)
                    .accessibilityLabel(LocalizedStringKey(stage))
                    .accessibilityValue(progress.map { "\(Int($0 * 100))%" } ?? "")
                Text(LocalizedStringKey(stage)).font(.system(size: 12))
                    .foregroundStyle(JarasTheme.secondary)
            }
            .onAppear { withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }
}

#if os(macOS)
import AppKit
private struct FloatingStartup: NSViewRepresentable {
    let active: Bool
    let progress: Double
    let stage: String
    let language: String
    func makeNSView(context: Context) -> FloatingStartupAnchor { FloatingStartupAnchor() }
    func updateNSView(_ view: FloatingStartupAnchor, context: Context) {
        view.active = active
        view.splashContent = AnyView(StartupView(progress: progress, stage: stage, transparent: true)
            .environment(\.locale, Locale(identifier: language)))
        view.refresh()
    }
    static func dismantleNSView(_ view: FloatingStartupAnchor, coordinator: ()) { view.finish() }
}
private final class FloatingStartupAnchor: NSView {
    var active = false
    var splashContent = AnyView(EmptyView())
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var hidMain = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    func refresh() {
        guard let window else { return }
        if active {
            window.alphaValue = 0
            hidMain = true
            if panel == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 430), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .floating
                panel.isReleasedWhenClosed = false
                panel.ignoresMouseEvents = true
                let hosting = NSHostingView(rootView: splashContent)
                panel.contentView = hosting
                self.hosting = hosting
                self.panel = panel
                panel.center()
                panel.orderFrontRegardless()
            }
            hosting?.rootView = splashContent
        } else { finish() }
    }
    func finish() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        if hidMain {
            window?.alphaValue = 1
            window?.makeKeyAndOrderFront(nil)
            hidMain = false
        }
    }
}
#endif

#if os(macOS)
@MainActor final class JarasApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let guardClose = ProjectCloseGuard.shared
        guard !guardClose.pending else { guardClose.focusCurrentDialog(); return .terminateCancel }
        guard guardClose.attached else { return .terminateNow }
        Task { @MainActor in
            guardClose.request { allowed in sender.reply(toApplicationShouldTerminate: allowed) }
        }
        return .terminateLater
    }
}

@MainActor private final class ClosingLogo: ObservableObject {
    @Published private(set) var remaining = 1.0
    private var panel: NSPanel?
    private var hiddenWindows: [NSWindow] = []
    func begin() {
        remaining = 1
        hiddenWindows = NSApp.windows.filter { $0.isVisible }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 430), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ClosingLogoView(state: self)
            .environment(\.locale, Locale(identifier: UserDefaults.standard.string(forKey: "jaras.language") ?? "en")))
        if let screen = NSApp.mainWindow?.screen {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 195, y: screen.visibleFrame.midY - 215))
        } else { panel.center() }
        self.panel = panel
        hiddenWindows.forEach { $0.orderOut(nil) }
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }
    func advance(_ completed: Double) { remaining = min(remaining, max(0, 1 - completed)) }
    func focus() -> Bool {
        guard let panel else { return false }
        panel.orderFrontRegardless()
        return true
    }
    func finish(restore: Bool) {
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
        if restore { hiddenWindows.forEach { $0.orderFront(nil) } }
        hiddenWindows.removeAll()
    }
}
private struct ClosingLogoView: View {
    @ObservedObject var state: ClosingLogo
    var body: some View { StartupView(progress: state.remaining, stage: "Closing…", transparent: true) }
}

/// Window close and Quit share an explicit Save / Discard / Cancel decision.
@MainActor final class ProjectCloseGuard: NSObject {
    static let shared = ProjectCloseGuard()
    private weak var window: NSWindow?
    private weak var documents: ProjectDocuments?
    private(set) var pending = false
    private var closeKeyMonitor: Any?
    private let closingLogo = ClosingLogo()

    var attached: Bool { documents != nil }
    var needsConfirmation: Bool {
        documents?.show.hasUnsavedChanges == true || documents?.show.saving == true ||
        documents?.busy == true || TrackRecording.shared.recording || TrackRecording.shared.busy
    }
    func attach(window: NSWindow, documents: ProjectDocuments) {
        self.documents = documents
        self.window = window
        // Preserve SwiftUI's window delegate, which also routes Finder document opens.
        let close = window.standardWindowButton(.closeButton)
        close?.target = self
        close?.action = #selector(closeMainWindow(_:))
        routeCloseMenu(NSApp.mainMenu)
        if closeKeyMonitor == nil {
            closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "w" else { return event }
                self.closeMainWindow(nil)
                return nil
            }
        }
    }
    private func routeCloseMenu(_ menu: NSMenu?) {
        for item in menu?.items ?? [] {
            if item.action == #selector(NSWindow.performClose(_:)) {
                item.target = self
                item.action = #selector(closeMainWindow(_:))
            }
            routeCloseMenu(item.submenu)
        }
    }
    @objc private func closeMainWindow(_ sender: Any?) {
        // FX windows keep their own normal Close behavior.
        if sender is NSMenuItem, let key = NSApp.keyWindow, key !== window, key.sheetParent !== window { key.performClose(sender); return }
        guard !pending else { focusCurrentDialog(); return }
        guard window != nil else { return }
        NSApp.terminate(nil)
    }
    func focusCurrentDialog() {
        NSApp.activate(ignoringOtherApps: true)
        if closingLogo.focus() { return }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        var sheet = window?.attachedSheet
        while let current = sheet {
            current.makeKeyAndOrderFront(nil)
            sheet = current.attachedSheet
        }
    }
    private func localized(_ key: String) -> String {
        JarasLocalization.string(key)
    }
    func request(completion: @escaping (Bool) -> Void) {
        guard !pending else { focusCurrentDialog(); completion(false); return }
        guard let documents else { completion(false); return }
        // Finish the current dialog before allowing a close request to open another sheet.
        guard window?.attachedSheet == nil else { focusCurrentDialog(); completion(false); return }
        if documents.busy {
            pending = true
            focusCurrentDialog()
            Task { @MainActor in
                let cancelled = await documents.cancelOpeningAndWait()
                pending = false
                if cancelled { request(completion: completion) }
                else {
                    documents.closeNotice = "Finish the current operation before closing."
                    focusCurrentDialog()
                    completion(false)
                }
            }
            return
        }
        documents.closeNotice = ""
        pending = true
        if !needsConfirmation {
            finishClosing(documents: documents, save: false, completion: completion)
            return
        }
        let alert = NSAlert()
        alert.messageText = localized("Do you want to save this project?")
        alert.addButton(withTitle: localized("Save")).keyEquivalent = "\r"
        alert.addButton(withTitle: localized("Close without saving"))
        alert.addButton(withTitle: localized("Cancel")).keyEquivalent = "\u{1b}"
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { completion(false); return }
            switch response {
            case .alertFirstButtonReturn:
                self.finishClosing(documents: documents, save: true, completion: completion)
            case .alertSecondButtonReturn:
                self.finishClosing(documents: documents, save: false, completion: completion)
            default:
                self.pending = false; completion(false)
            }
        }
        if let window { window.makeKeyAndOrderFront(nil); alert.beginSheetModal(for: window, completionHandler: answer) }
        else { answer(alert.runModal()) }
    }
    private func finishClosing(documents: ProjectDocuments, save: Bool, completion: @escaping (Bool) -> Void) {
        closingLogo.begin()
        Task { @MainActor in
            do {
                // Let the transparent logo paint before releasing playback resources.
                await Task.yield()
                let capture = TrackRecording.shared
                let wasRecording = capture.recording || capture.busy
                await capture.finishAndWait()
                if wasRecording && !capture.error.isEmpty { throw ProjectError.invalid(capture.error) }
                closingLogo.advance(0.1)
                documents.show.send(.stopAll)
                while documents.show.saving { try await Task.sleep(nanoseconds: 20_000_000) }
                if save { try await documents.show.saveForClosing() }
                closingLogo.advance(0.25)
                FXWindows.shared.closeAll()
                StemAudioPlayback.shared.prepareForClosing()
                try await documents.rememberProjectMedia()
                closingLogo.advance(1)
                await Task.yield()
                closingLogo.finish(restore: false)
                pending = false
                completion(true)
            } catch {
                closingLogo.finish(restore: true)
                pending = false
                documents.error = error.localizedDescription
                completion(false)
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = localized("Could not close the project.")
                failure.informativeText = localized(error.localizedDescription)
                failure.addButton(withTitle: "OK")
                if let window { window.makeKeyAndOrderFront(nil); failure.beginSheetModal(for: window, completionHandler: nil) }
                else { failure.runModal() }
            }
        }
    }
}
#endif
