import SwiftUI
@MainActor final class Bootstrap: ObservableObject {
    @Published var container: AppContainer?
    @Published var error: String?
    init() { retry() }
    func retry() { do { container = try AppContainer(); error = nil } catch { self.error = error.localizedDescription } }
}
@main @MainActor struct JarasLiveApp: App {
    @StateObject private var bootstrap = Bootstrap()
    var body: some Scene {
        WindowGroup("Jaras Live") {
            if let container = bootstrap.container { RootView(container: container) }
            else { VStack(spacing: 20) { Text("Jaras Live").font(.largeTitle.bold()); Text(LocalizedStringKey(bootstrap.error ?? "Iniciando…")); Button("Tentar novamente") { bootstrap.retry() } }.padding(40).preferredColorScheme(.dark) }
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 800)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
struct RootView: View {
    @AppStorage("jaras.language") private var language = "en"
    @ObservedObject var container: AppContainer
    @ObservedObject private var auth: AuthService
    init(container: AppContainer) { self.container = container; auth = container.auth }
    var body: some View {
        Group {
            if container.starting {
                StartupView(progress: container.startupProgress, stage: container.startupStage)
            } else if auth.allowed { MainView(show: container.show, auth: auth, backend: container.backend) }
            else if [.launching,.checkingSession,.checkingLicense,.checkingDevice].contains(auth.phase) {
                StartupView(progress: nil, stage: "Validando acesso…")
            } else { LoginView(auth: auth, backend: container.backend) }
        }
        #if os(macOS)
        .frame(minWidth: 1050, minHeight: 650)
        .background(FloatingStartup(active: container.starting, progress: container.startupProgress, stage: container.startupStage, language: language))
        #endif
        .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark).task { await container.start() }
    }
}
struct UnauthorizedPreview: PreviewProvider { static var previews: some View { let container = try! AppContainer(preview: true); LoginView(auth: container.auth, backend: container.backend).frame(width: 1100, height: 720) } }

struct StartupView: View {
    let progress: Double?
    let stage: String
    var transparent = false
    var body: some View {
        ZStack {
            if !transparent { JarasTheme.background.ignoresSafeArea() }
            VStack(spacing: 22) {
                Image("JarasLogo").resizable().scaledToFit()
                    .frame(width: 330, height: 330).accessibilityLabel("Jaras Live")
                ProgressView(value: progress).progressViewStyle(.linear)
                    .tint(JarasTheme.green).frame(width: 300)
                    .accessibilityLabel(LocalizedStringKey(stage))
                Text(LocalizedStringKey(stage)).font(.system(size: 12))
                    .foregroundStyle(JarasTheme.secondary)
            }
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
            .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark))
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
