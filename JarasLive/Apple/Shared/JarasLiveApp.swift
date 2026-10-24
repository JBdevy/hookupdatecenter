import SwiftUI
#if os(iOS)
import UIKit

@MainActor final class JarasMobileApplicationDelegate: NSObject, UIApplicationDelegate {
    private static var iPadOrientations: UIInterfaceOrientationMask = .landscape

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? Self.iPadOrientations : .portrait
    }

    static func setObserverOrientation(_ observer: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        iPadOrientations = observer ? .all : .landscape
        updateOrientations()
    }

    static func updateOrientations() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.activationState == .foregroundActive {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: iPadOrientations)) { error in
                NSLog("CatLive: unable to update iPad orientation: %@", error.localizedDescription)
            }
        }
    }
}
#endif
@MainActor final class Bootstrap: ObservableObject {
    @Published var container: AppContainer?
    @Published var error: String?
    init() {
        #if os(iOS)
        return
        #else
        retry()
        #endif
    }
    func retry() { do {
        let initial = try AppContainer(); container = initial
        #if os(macOS)
        DesktopProjectTabs.shared.install(initial)
        #endif
        error = nil
    } catch { self.error = error.localizedDescription } }
}
@main @MainActor struct JarasLiveApp: App {
    @StateObject private var bootstrap = Bootstrap()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(JarasApplicationDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(JarasMobileApplicationDelegate.self) private var appDelegate
    #endif
    @ViewBuilder private var appContent: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { PhoneRemoteHomeView() }
        else { IpadNativeHome(bootstrap: bootstrap) }
        #else
        bootstrappedContent
        #endif
    }
    @ViewBuilder private var bootstrappedContent: some View {
        if let container = bootstrap.container {
            #if os(macOS)
            DesktopProjectRoot(initial: container)
            #else
            RootView(container: container)
            #endif
        }
        else { VStack(spacing: 20) { Text("CatLive").font(.jarasLargeTitle.bold()); Text(LocalizedStringKey(bootstrap.error ?? "Iniciando…")); Button("Tentar novamente") { bootstrap.retry() } }.padding(40) }
    }
    var body: some Scene {
        #if os(macOS)
        // ProjectWindowSizing owns the editor/browser frame on every supported
        // OS. Reuse the workspace for opened projects and omit New Window.
        WindowGroup("CatLive", id: "main") {
            appContent.handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { RegionShortcutView.performClipboard("x") }.keyboardShortcut("x")
                Button("Copy") { RegionShortcutView.performClipboard("c") }.keyboardShortcut("c")
                Button("Paste") { RegionShortcutView.performClipboard("v") }.keyboardShortcut("v")
                Button("Duplicate") { RegionShortcutView.performClipboard("d") }.keyboardShortcut("d")
            }
        }
        #else
        WindowGroup("CatLive") {
            appContent.statusBarHidden(true).persistentSystemOverlays(.hidden)
                .background(IpadTextKeyboardScope())
                .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
        }
        .onChange(of: scenePhase) { phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase == .active { JarasMobileApplicationDelegate.updateOrientations() }
        }
        #endif
    }
}
struct RootView: View {
    @AppStorage("jaras.language") private var language = "en"
    @ObservedObject var container: AppContainer
    @ObservedObject private var auth: AuthService
    @ObservedObject private var documents: ProjectDocuments
    var leaveNative: (() -> Void)? = nil
    @State private var browsingNative = false
    init(container: AppContainer, leaveNative: (() -> Void)? = nil) {
        self.container = container; self.leaveNative = leaveNative; auth = container.auth; documents = container.documents
    }
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
                #if os(iOS)
                if documents.ready && !browsingNative {
                    IpadStandaloneWorkspace(show: container.show, documents: documents, auth: auth, backend: container.backend, onExit: {
                        browsingNative = true
                    })
                        .id(documents.opened)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Modes") { leaveNative?() }.disabled(documents.busy)
                            Spacer()
                            Text("Native").font(.jarasHeadline).foregroundStyle(JarasTheme.green)
                            Spacer()
                            if documents.ready { Button("Back to project") { browsingNative = false } }
                        }.padding(16).background(JarasTheme.panel)
                        ProjectBrowserView(documents: documents) { if documents.ready { browsingNative = false } }
                    }
                }
                #else
                if documents.ready || documents.projectTabCount > 1 {
                    ZStack {
                        DesktopWorkspaceView(container: container)
                        if !documents.ready {
                            Color.black.opacity(0.45).ignoresSafeArea()
                            VStack(spacing: 0) {
                                HStack {
                                    Text("Projects").font(.jarasHeadline)
                                    Spacer()
                                    if documents.canCancelOpening {
                                        Button { documents.cancelOpening() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                    }
                                }.padding(16)
                                Divider()
                                ProjectBrowserView(documents: documents)
                            }.frame(width: 560, height: 500)
                                .background(JarasTheme.background)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                } else {
                    ProjectBrowserView(documents: documents)
                        .background(ProjectTitlebarContent { EmptyView() })
                }
                #endif
            }
            else if [.launching,.checkingSession,.checkingLicense,.checkingDevice].contains(auth.phase) {
                StartupView(progress: nil, stage: [.launching, .checkingSession].contains(auth.phase) ? "Restaurando ativação…" : "Validando acesso…")
            } else {
                LoginView(auth: auth, backend: container.backend,
                          offersTrial: auth.trialDaysRemaining != 0,
                          showsCloseButton: false)
            }
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InterfaceScaleAnchor(preserveFrame: true))
        .background(TrialTitlebar(auth: auth))
        .background(ProjectWindowSizing(editor: (documents.ready || documents.projectTabCount > 1) && auth.workspaceAllowed,
                                        login: !auth.workspaceAllowed, documents: documents))
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
        .onOpenURL { url in
            #if os(macOS)
            if ["jl", "bkjl", "logicx", "rpp", "ziplive", "zip"].contains(url.pathExtension.lowercased()) { documents.open(url) }
            #else
            if ["ziplive", "zip"].contains(url.pathExtension.lowercased()) { documents.importPortablePackage(url) }
            #endif
        }
        #if os(iOS)
        .disabled(documents.busy)
        .overlay {
            if documents.busy {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView(value: documents.audioImportProgress).tint(JarasTheme.green)
                        Text(LocalizedStringKey(documents.status)).font(.jarasCallout)
                        if documents.canCancelOpening { Button("Cancel") { documents.cancelOpening() } }
                    }.padding(28).frame(width: 360).background(JarasTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .modifier(NativeProjectPresentation(documents: documents))
        .onChange(of: documents.folderReview != nil || documents.scan != nil) { reviewing in if reviewing { browsingNative = true } }
        #endif
        .sheet(item: $documents.missingAudioPrompt) { _ in
            MissingAudioRecoveryView(documents: documents)
        }
        .sheet(isPresented: Binding(get: { !documents.migrationNotice.isEmpty }, set: { if !$0 { documents.migrationNotice = "" } })) {
            ProjectMigrationNotice(notice: documents.migrationNotice, language: language) {
                documents.migrationNotice = ""
            }
        }
        .overlay(alignment: .top) {
            if !documents.closeNotice.isEmpty {
                Text(LocalizedStringKey(documents.closeNotice)).font(.jarasCallout)
                    .padding(12).background(JarasTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 20)
                    .accessibilityAddTraits(.updatesFrequently)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .jarasHideScrollIndicators()
        .environment(\.locale, Locale(identifier: language)).task { await container.start() }
        #if os(macOS)
        .interfaceScaled()
        .font(.jarasBody)
        #endif
    }
}
#if os(macOS)
/// Each tab owns its mounted workspace. Switching tabs detaches and reattaches
/// that host, preserving timeline/mixer views and their local presentation state.
@MainActor private struct DesktopWorkspaceView: NSViewRepresentable {
    let container: AppContainer
    @Environment(\.locale) private var locale
    @Environment(\.displayScale) private var displayScale
    private var environmentKey: String { locale.identifier + "|" + String(describing: displayScale) }
    private func content() -> AnyView {
        AnyView(MainView(show: container.show, auth: container.auth, backend: container.backend, documents: container.documents)
            .environment(\.locale,locale).environment(\.colorScheme,.dark)
            .environment(\.displayScale,displayScale).font(.jarasBody))
    }
    final class Deck: NSView {
        override func layout() {
            super.layout()
            for view in subviews where !view.isHidden { view.frame = bounds }
        }
        override var isFlipped: Bool { true }
    }
    func makeNSView(context: Context) -> Deck { Deck() }
    func updateNSView(_ deck: Deck, context: Context) {
        guard container.documents.ready else { return }
        let host: NSHostingView<AnyView>
        if container.desktopWorkspaceIdentity == container.documents.opened,
           let cached = container.desktopWorkspaceHost { host = cached }
        else {
            container.desktopWorkspaceHost?.removeFromSuperview()
            host = NSHostingView(rootView: content())
            if #available(macOS 13, *) { host.sizingOptions = [] }
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            host.setContentHuggingPriority(.defaultLow, for: .horizontal)
            host.setContentHuggingPriority(.defaultLow, for: .vertical)
            container.desktopWorkspaceHost = host
            container.desktopWorkspaceIdentity = container.documents.opened
            container.desktopWorkspaceEnvironment = environmentKey
        }
        if container.desktopWorkspaceEnvironment != environmentKey {
            container.desktopWorkspaceEnvironment = environmentKey
            host.rootView = content()
        }
        // Keep mounted workspaces attached to the same window. Removing a
        // hosting view from its window tears down native descendants on a switch.
        if host.superview !== deck { deck.addSubview(host) }
        let live = DesktopProjectTabs.shared.projects.compactMap { $0.desktopWorkspaceHost }
        for view in deck.subviews {
            if !live.contains(where: { $0 === view }) && view !== host { view.removeFromSuperview() }
            else { view.isHidden = view !== host }
        }
        host.frame = deck.bounds
        deck.needsLayout = true
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Deck, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }
}
#endif
/// A native alert sizes itself to all of its text, which can put its dismiss
/// button below the screen for projects with many unsupported effects. Only
/// the details scroll here; the title and confirmation remain in view.
struct ProjectMigrationNotice: View {
    let notice: String
    let language: String
    let dismiss: () -> Void
    private var notes: [String] { notice.components(separatedBy: "\n\n").filter { !$0.isEmpty } }
    private var preferredHeight: CGFloat { min(360, max(220, CGFloat(notes.count) * 62 + 136)) }
    private func text(_ key: String) -> String { JarasLocalization.string(key, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text("Project migration")).font(.jarasHeadline)
                Text(verbatim: text("Project imported. Review these notes before playback."))
                    .font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("migration-notice-header")
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "\(index + 1).").foregroundStyle(JarasTheme.yellow)
                            Text(verbatim: note).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.disabled)
                        }
                    }
                }.font(.jarasSystem(size: 12)).padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JarasTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("migration-notice-details")
            HStack {
                Text(verbatim: String(format: text("Import notes: %ld"), notes.count))
                    .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                Spacer()
                Button(action: dismiss) {
                    Text(verbatim: text("OK")).frame(minWidth: 64, minHeight: 24)
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("migration-notice-ok")
            }
        }
        .padding(20).background(JarasTheme.panel)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 520,
               minHeight: 200, idealHeight: preferredHeight, maxHeight: preferredHeight)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: language))
    }
}

struct UnauthorizedPreview: PreviewProvider { static var previews: some View { let container = try! AppContainer(preview: true); LoginView(auth: container.auth, backend: container.backend).frame(width: 1100, height: 720) } }

struct StartupView: View {
    static let panelWidth: CGFloat = 600
    static let panelHeight: CGFloat = 280
    let progress: Double?
    let stage: String
    var transparent = false
    var body: some View {
        ZStack {
            if !transparent { JarasTheme.background.ignoresSafeArea() }
            HStack(spacing: 0) {
                Image("CatLiveSplash").resizable().scaledToFit()
                    .padding(24)
                    .frame(width: Self.panelWidth * 0.4, height: Self.panelHeight)
                    .accessibilityLabel("CatLive")
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        HStack(alignment: .center, spacing: 2) {
                            ForEach(Array([10.0, 20, 30, 38, 26, 18, 8].enumerated()), id: \.offset) { _, height in
                                Capsule().frame(width: 3, height: height)
                            }
                        }.frame(width: 33, height: 38).accessibilityHidden(true)
                        Text(verbatim: "CatLive").font(.jarasSystem(size: 54, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0x72FFB3), Color(hex: 0x00CF64)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(verbatim: "Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                        .font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.secondary).padding(.top, 8)
                    Spacer(minLength: 24)
                    Group {
                        if let progress {
                            GeometryReader { geometry in
                                Capsule().fill(JarasTheme.green.opacity(0.14))
                                Capsule().fill(JarasTheme.green)
                                    .frame(width: geometry.size.width * min(1, max(0, progress)))
                            }.frame(height: 5)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(JarasTheme.green)
                        }
                    }
                    .accessibilityLabel(LocalizedStringKey(stage))
                    .accessibilityValue(progress.map { "\(Int($0 * 100))%" } ?? "")
                    Text(LocalizedStringKey(stage)).font(.jarasSystem(size: 12))
                        .foregroundStyle(JarasTheme.secondary).padding(.top, 10)
                    Text(verbatim: "© reivsoficial").font(.jarasSystem(size: 10))
                        .foregroundStyle(JarasTheme.secondary).padding(.top, 4)
                }.padding(24).frame(width: Self.panelWidth * 0.6 - 1, height: Self.panelHeight)
            }
            .frame(width: Self.panelWidth, height: Self.panelHeight)
            .background(JarasTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
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
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: StartupView.panelWidth, height: StartupView.panelHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.level = .floating
                panel.isReleasedWhenClosed = false
                panel.ignoresMouseEvents = true
                let hosting = NSHostingView(rootView: splashContent)
                panel.contentView = hosting
                self.hosting = hosting
                self.panel = panel
                panel.center()
                panel.orderFrontRegardless()
                DispatchQueue.main.async { AppStartupPresentation.playSoundOnce() }
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProjectSyncControl.following {
            DesktopProjectTabs.shared.active?.documents.closeNotice = "Project Sync: o PC B está seguindo o PC A. Desative a sincronização antes de encerrar."
            return .terminateCancel
        }
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: StartupView.panelWidth, height: StartupView.panelHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ClosingLogoView(state: self)
            .environment(\.locale, Locale(identifier: UserDefaults.standard.string(forKey: "jaras.language") ?? "en")))
        if let screen = NSApp.mainWindow?.screen {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - StartupView.panelWidth / 2, y: screen.visibleFrame.midY - StartupView.panelHeight / 2))
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
/// Save confirmation shared visually with Windows, with an explicit app logo.
/// AppKit can omit the app icon from NSAlert sheets, so own this small surface.
@MainActor final class ProjectSaveAlert: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
    private final class Content: NSView {
        override var isFlipped: Bool { true }
    }
    private final class Action: NSButton {
        var primary = false
        override func draw(_ dirtyRect: NSRect) {
            let fill = primary ? NSColor(srgbRed: 0.376, green: 0.710, blue: 0.239, alpha: 1)
                               : NSColor(white: 0.28, alpha: 0.85)
            (isHighlighted ? fill.blended(withFraction: 0.15, of: .black)! : fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white, .paragraphStyle: style]
            let height = (title as NSString).size(withAttributes: attrs).height
            (title as NSString).draw(in: NSRect(x: 4, y: (bounds.height-height)/2, width: bounds.width-8, height: height), withAttributes: attrs)
            if window?.firstResponder === self {
                NSColor.white.withAlphaComponent(0.5).setStroke()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height/2, yRadius: bounds.height/2).stroke()
            }
        }
    }
    var messageText = ""
    private var buttons: [NSButton] = []
    private let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 244),
                              styleMask: .borderless, backing: .buffered, defer: false)
    private var finishing = false
    override init() {
        super.init()
        panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
    }
    @discardableResult func addButton(withTitle title: String) -> NSButton {
        let button = Action(title: title, target: self, action: #selector(answer(_:)))
        button.primary = buttons.isEmpty
        button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttons.count
        button.isBordered = false; button.focusRingType = .none
        buttons.append(button)
        return button
    }
    private func prepare() {
        let content = Content(frame: NSRect(x: 0, y: 0, width: 260, height: 244))
        content.wantsLayer = true
        let glass = NSVisualEffectView(frame: content.bounds)
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        content.addSubview(glass)
        let tint = NSView(frame: content.bounds); tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.82).cgColor
        content.addSubview(tint)
        content.layer?.cornerRadius = 25; content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1; content.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        let logo = NSImageView(frame: NSRect(x: 98, y: 24, width: 64, height: 64))
        logo.image = NSApp.applicationIconImage; logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("CatLive")
        content.addSubview(logo)
        let title = NSTextField(labelWithString: messageText)
        title.font = .systemFont(ofSize: 14, weight: .bold); title.textColor = NSColor(white: 0.87, alpha: 1)
        title.alignment = .center; title.frame = NSRect(x: 16, y: 98, width: 228, height: 24)
        content.addSubview(title)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 16, y: 132 + index * 34, width: 228, height: 28)
            content.addSubview(button)
        }
        panel.contentView = content
        panel.title = messageText
        panel.setAccessibilityLabel(messageText)
    }
    @objc private func answer(_ sender: NSButton) {
        guard !finishing else { return }; finishing = true
        let response = NSApplication.ModalResponse(rawValue: sender.tag)
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: response) }
        else { NSApp.stopModal(withCode: response) }
    }
    func beginSheetModal(for parent: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        prepare()
        parent.beginSheet(panel) { [self] response in
            panel.orderOut(nil)
            completionHandler(response)
        }
    }
    func runModal() -> NSApplication.ModalResponse {
        prepare(); panel.center()
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }
}

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
    func request(confirmPlayback: Bool = true, completion: @escaping (Bool) -> Void) {
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
        if confirmPlayback && (documents.show.isPlaying || DesktopProjectTabs.shared.anyPlaying) {
            let alert = NSAlert()
            alert.messageText = localized("Close CatLive?")
            alert.informativeText = localized("Playback is in progress. Do you really want to close CatLive?")
            alert.addButton(withTitle: localized("Cancel")).keyEquivalent = "\r"
            alert.addButton(withTitle: localized("Close CatLive"))
            let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { completion(false); return }
                self.pending = false
                guard response == .alertSecondButtonReturn else { completion(false); return }
                // Playback continues until all close/save decisions succeed.
                // Cancelling a later save dialog must not interrupt the music.
                DispatchQueue.main.async { self.request(confirmPlayback: false, completion: completion) }
            }
            if let window { window.makeKeyAndOrderFront(nil); alert.beginSheetModal(for: window, completionHandler: answer) }
            else { answer(alert.runModal()) }
            return
        }
        if !needsConfirmation {
            finishClosing(documents: documents, save: false, completion: completion)
            return
        }
        let alert = ProjectSaveAlert()
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
        Task { @MainActor in
            do {
                guard try await DesktopProjectTabs.shared.confirmAndSaveBackgroundProjects(excluding: documents) else {
                    pending = false; completion(false); return
                }
                closingLogo.begin()
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
                capture.closeProject()
                DesktopProjectTabs.shared.stopAll()
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
