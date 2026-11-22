import SwiftUI

#if os(macOS)
import AppKit
import Combine

@MainActor private final class MatrixPatchWindow: NSPanel {
    private var consumedTitlebarClick = false
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp && consumedTitlebarClick {
            consumedTitlebarClick = false
            return
        }
        if event.type == .leftMouseDown, event.clickCount == 2,
           !styleMask.contains(.fullScreen), event.locationInWindow.y >= contentLayoutRect.maxY {
            let onWindowButton = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { type in
                guard let button = standardWindowButton(type) else { return false }
                return button.convert(button.bounds, to: nil).contains(event.locationInWindow)
            }
            if !onWindowButton {
                consumedTitlebarClick = true
                performZoom(nil)
                return
            }
        }
        super.sendEvent(event)
    }
}

/// Never let focus rings or a transient control's ideal size resize its NSWindow.
/// The presenter owns the content rectangle, including on macOS 12.
final class WorkspaceEditorHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}

let workspacePanelStyle: NSWindow.StyleMask = [.titled, .closable, .resizable]

@MainActor func makeWorkspacePanel(title: String, size: NSSize, minimum: NSSize, matrixPatch: Bool = false) -> NSPanel {
    let rect = NSRect(origin: .zero, size: size)
    let panel = matrixPatch
        ? MatrixPatchWindow(contentRect: rect, styleMask: workspacePanelStyle, backing: .buffered, defer: false)
        : NSPanel(contentRect: rect, styleMask: workspacePanelStyle, backing: .buffered, defer: false)
    panel.title = title
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentMinSize = minimum
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false
    panel.level = .normal
    return panel
}

@MainActor private func attachWorkspacePanel(_ panel: NSPanel) {
    // Keep the same workspace/tool ordering without linking window movement
    // or monitor placement to the main interface.
    ProjectionWindow.followWorkspaceWindow(panel)
}

@MainActor final class FXWindows: NSObject, NSWindowDelegate {
    static let shared = FXWindows()
    private enum Target: Hashable {
        case plugin(UUID?, String)
        case clip(UUID)
    }
    private struct WindowKey: Hashable {
        let project: UUID
        let target: Target
    }
    private var windows: [WindowKey:NSPanel] = [:]
    private var projectObservation: AnyCancellable?
    private weak var show: ShowController?
    func open(show: ShowController, track: UUID?, effect: String, language: String) {
        open(show: show, target: WindowKey(project: show.snapshot.project.id, target: .plugin(track, effect)))
    }
    func openClipChain(show: ShowController, clip: UUID, openLibrary: @escaping () -> Void) {
        open(show: show, target: WindowKey(project: show.snapshot.project.id, target: .clip(clip)), openLibrary: openLibrary)
    }
    private func targetExists(_ key: WindowKey, in show: ShowController) -> Bool {
        guard key.project == show.snapshot.project.id else { return false }
        switch key.target {
        case .clip(let clip): return FXModelLookup.clip(clip, in: show.snapshot.project) != nil
        case .plugin(let track, let effect):
            return show.fxSettings(track).effectKeys.contains(effect) &&
                (track == nil || track.map { FXModelLookup.track($0, in: show.snapshot.project)?.kind == .standard } == true)
        }
    }
    private func title(_ key: WindowKey, in show: ShowController) -> String {
        switch key.target {
        case .clip(let clip): return JarasLocalization.string("FX Manager") + " - " + (FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—")
        case .plugin(let track, let effect):
            let name = track.flatMap { id in FXModelLookup.track(id, in: show.snapshot.project)?.name } ?? "Main"
            let settings = show.fxSettings(track)
            let plugin = settings.externalPlugins?.first(where: { $0.effectKey == effect })?.name ??
                JarasLocalization.string(settings.kind(of: effect))
            return plugin + " - " + name
        }
    }
    private func content(_ key: WindowKey, show: ShowController, panel: NSPanel, openLibrary: @escaping () -> Void) -> NSView {
        switch key.target {
        case .clip(let clip):
            let view = TrackFXChainView(show: show, track: nil, clip: clip, effect: show.clipFXSettings(clip).clipEffectKeys.first ?? "",
                                        panel: panel, openLibrary: openLibrary)
            panel.setContentSize(view.preferredContentSize)
            return view
        case .plugin(let track, let effect):
            let view = TrackFXChainView(show: show, track: track, effect: effect, panel: panel, singlePlugin: true)
            panel.setContentSize(view.preferredContentSize)
            return view
        }
    }
    private func open(show: ShowController, target key: WindowKey, openLibrary: @escaping () -> Void = {}) {
        guard !ProjectSyncControl.following else { return }
        guard targetExists(key, in: show) else { return }
        if self.show !== show {
            closeAll(); self.show = show
            projectObservation = show.$snapshot.map { $0.project.id }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.closeAll() }
        }
        if let panel = windows[key] {
            ProjectionWindow.presentWorkspaceWindow(panel); return
        }
        // The normal titlebar provides full-size native window controls for
        // both track chains and item FX, including third-party editors.
        let panel = makeWorkspacePanel(title: title(key, in: show),
                                       size: NSSize(width: 740, height: 560),
                                       minimum: NSSize(width: 640, height: 540))
        panel.delegate = self
        panel.contentView = content(key, show: show, panel: panel, openLibrary: openLibrary)
        InterfaceScaling.shared.register(panel)
        panel.center()
        let stagger = CGFloat(windows.count % 5) * 26
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + stagger,y: panel.frame.minY - stagger))
        windows[key] = panel
        attachWorkspacePanel(panel)
        ProjectionWindow.presentWorkspaceWindow(panel)
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        if let show, let key = windows.first(where: { $0.value === panel })?.key,
           case .plugin(let track, let effect) = key.target {
            for plugin in show.fxSettings(track).externalPlugins ?? [] where plugin.effectKey == effect {
                ExternalPluginState.capture(show: show, track: track, identifier: plugin.id)
            }
        }
        (panel.contentView as? TrackFXChainView)?.closeEditors()
        panel.parent?.removeChildWindow(panel)
        windows = windows.filter { $0.value !== panel }
        panel.contentView = nil
    }
    func synchronize(show: ShowController) {
        for (key, panel) in Array(windows) {
            guard targetExists(key, in: show) else { panel.close(); continue }
            panel.title = title(key, in: show)
            // Both track and item chains observe FX metadata themselves and
            // retain the selected editor while transport snapshots advance.
        }
    }
    func suspendAudioEditors() {
        ClipExternalPluginHostView.suspendAll()
        for panel in windows.values { (panel.contentView as? TrackFXChainView)?.suspendAudioEditor() }
    }
    func restoreAudioEditors() {
        ClipExternalPluginHostView.restoreAll()
        for panel in windows.values { (panel.contentView as? TrackFXChainView)?.restoreAudioEditor() }
    }
    func closeAll() { for panel in Array(windows.values) { panel.close() }; windows.removeAll() }
}

@MainActor private final class WorkspaceSettingsSelection: ObservableObject {
    @Published var section: SettingsView.Section
    init(_ section: SettingsView.Section) { self.section = section }
}

private struct WorkspaceSettingsContent: View {
    let auth: AuthService
    let show: ShowController
    let backend: any BackendClient
    @ObservedObject var selection: WorkspaceSettingsSelection
    var body: some View {
        SettingsView(auth: auth, show: show, backend: backend, selection: $selection.section)
    }
}

@MainActor private final class WorkspaceToolPresentation: ObservableObject {
    @Published var generation = 0
}
private struct WorkspaceAdvancedContent: View {
    let show: ShowController
    let documents: ProjectDocuments?
    let close: () -> Void
    @ObservedObject var presentation: WorkspaceToolPresentation
    var body: some View {
        AdvancedView(show: show, documents: documents, close: close, presentationID: presentation.generation)
    }
}

private struct WorkspaceToolContent<Content: View>: View {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @AppStorage("jaras.language") private var language = "en"
    let content: Content
    let updateTitle: () -> Void
    var body: some View {
        content
            .background(interfaceTheme.background).foregroundStyle(JarasTheme.text)
            .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
            .onChange(of: language) { _ in updateTitle() }
    }
}

/// The workspace owns these panels, just as it owns its detached mixer.
/// Refocusing a tool keeps its hosting view, selection and unfinished text edits.
@MainActor final class WorkspaceToolWindows: NSObject, ObservableObject, NSWindowDelegate {
    private enum Tool: String { case advanced, settings, textItem, fullLyrics, matrixPatch }
    @Published private(set) var settingsOpen = false
    @Published private(set) var advancedOpen = false
    @Published private(set) var matrixPatchOpen = false
    private var windows: [Tool: NSPanel] = [:]
    private var settingsSelection: WorkspaceSettingsSelection?
    private let advancedPresentation = WorkspaceToolPresentation()
    private var discardingWindows = false
    private weak var show: ShowController?
    private var projectObservation: AnyCancellable?

    private func bind(_ show: ShowController) {
        guard self.show !== show else { return }
        closeAll()
        self.show = show
        projectObservation = show.$snapshot.map { $0.project.id }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.closeAll() }
    }
    func openTextItem(show: ShowController, id: UUID) {
        bind(show)
        guard let track = show.current?.tracks.first(where: { $0.kind.isText && $0.clips.contains { $0.id == id } }),
              let item = track.clips.first(where: { $0.id == id }) else { return }
        // Keep the draft in one independent tool window, above the projection
        // without bringing the whole workspace in front of that projection.
        present(.textItem, title: "Text Editor", size: NSSize(width: 700, height: 360)) { panel in
            TextItemEditor(text: item.text ?? "", showHeader: false,
                           apply: { show.updateTextItem(id, text: $0) },
                           close: { [weak panel] in panel?.close() })
        }
    }
    func openFullLyrics(show: ShowController, track: UUID) {
        bind(show)
        do {
            let target = try FullLyricsTarget(show: show, track: track)
            present(.fullLyrics, title: "Full lyrics", size: NSSize(width: 620, height: 460)) { panel in
                FullLyricsEditor(show: show, target: target, close: { [weak panel] in panel?.close() })
            }
        } catch { show.message = error.localizedDescription }
    }
    func openAdvanced(show: ShowController, documents: ProjectDocuments?) {
        bind(show)
        if windows[.advanced]?.isVisible != true { advancedPresentation.generation &+= 1 }
        present(.advanced, title: "Advanced", size: AdvancedView.desktopSize) { panel in
            WorkspaceAdvancedContent(show: show, documents: documents,
                close: { [weak panel] in panel?.close() }, presentation: advancedPresentation)
        }
        advancedOpen = true
    }
    func openMatrixPatch(show: ShowController) {
        bind(show)
        present(.matrixPatch, title: "Matrix Patch", size: NSSize(width: 1000, height: 650)) { _ in
            MatrixPatchView(show: show)
        }
        matrixPatchOpen = true
    }
    func openSettings(auth: AuthService, show: ShowController, backend: any BackendClient,
                      section: SettingsView.Section? = nil) {
        bind(show)
        if windows[.settings]?.isVisible != true { settingsSelection?.section = section ?? .general }
        else if let section { settingsSelection?.section = section }
        let selection = settingsSelection ?? WorkspaceSettingsSelection(section ?? .general)
        settingsSelection = selection
        present(.settings, title: "Configurações", size: NSSize(width: 940, height: 540)) { _ in
            WorkspaceSettingsContent(auth: auth, show: show, backend: backend, selection: selection)
        }
        settingsOpen = true
    }
    private func present<Content: View>(_ tool: Tool, title: String, size: NSSize,
                                       @ViewBuilder content: (NSPanel) -> Content) {
        if let panel = windows[tool] {
            if !panel.isVisible {
                panel.contentView?.isHidden = false
                attachWorkspacePanel(panel)
            }
            ProjectionWindow.presentWorkspaceWindow(panel)
            return
        }
        let expandable = tool == .matrixPatch
        let panel = makeWorkspacePanel(title: JarasLocalization.string(title), size: size, minimum: size, matrixPatch: expandable)
        if expandable { panel.collectionBehavior.insert(.fullScreenPrimary) }
        else { panel.styleMask.remove(.resizable) }
        panel.identifier = NSUserInterfaceItemIdentifier("catlive.tool." + tool.rawValue)
        if tool == .textItem {
            // Keep the draft visible while the user focuses the projection.
            // It remains an independent window, without a modal session.
            panel.level = .normal
            panel.hidesOnDeactivate = false
            panel.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        panel.delegate = self
        let editor = WorkspaceToolContent(content: content(panel), updateTitle: { [weak panel] in
            panel?.title = JarasLocalization.string(title)
        })
        // Settings and the text editor own their scrolling and fill the window.
        // Advanced has a fixed minimum canvas; scroll that canvas only if the
        // available screen cannot fit it, without asking it for an ideal size.
        let host = WorkspaceEditorHostingView(rootView: WorkspaceEditorViewport(content: editor, scrolls: tool == .advanced, layoutSize: tool == .advanced ? size : nil).interfaceScaled())
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        panel.contentView = host
        let available = panel.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? size
        panel.contentMinSize = expandable
            ? NSSize(width: min(640, available.width), height: min(420, max(240, available.height - 32)))
            : .zero
        panel.setContentSize(NSSize(width: min(size.width, available.width), height: min(size.height, max(240, available.height - 32))))
        InterfaceScaling.shared.register(panel)
        panel.center()
        windows[tool] = panel
        attachWorkspacePanel(panel)
        ProjectionWindow.presentWorkspaceWindow(panel)
    }
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        if window === windows[.matrixPatch] { return window.screen?.visibleFrame ?? newFrame }
        return newFrame
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let tool = windows.first(where: { $0.value === panel })?.key else { return }
        panel.parent?.removeChildWindow(panel)
        if tool == .settings { settingsOpen = false; ControlMappings.shared.editing = nil }
        if tool == .matrixPatch { matrixPatchOpen = false }
        if tool == .advanced { advancedOpen = false }
        if !discardingWindows && tool != .textItem && tool != .fullLyrics {
            // Keep the hosting tree and native window; hide it from layout,
            // hit testing and accessibility until the next presentation.
            panel.contentView?.isHidden = true
            return
        }
        windows.removeValue(forKey: tool)
        panel.contentView = nil
    }
    func closeAll() {
        discardingWindows = true
        for panel in Array(windows.values) { panel.close(); panel.contentView = nil }
        windows.removeAll()
        discardingWindows = false
        settingsOpen = false
        matrixPatchOpen = false
        advancedOpen = false
        settingsSelection = nil
    }
}


/// Measure before InterfaceScaleLayout: its GeometryReader intentionally has a
/// 10-point ideal size, which is not the editor's required content size.
private func workspaceEditorContentSize<Content: View>(_ content: Content) -> NSSize {
    let fitted = NSHostingView(rootView: content).fittingSize
    guard fitted.width.isFinite, fitted.height.isFinite else { return NSSize(width: 380, height: 500) }
    return NSSize(width: min(940, max(340, fitted.width)), height: min(700, max(280, fitted.height)))
}

private struct WorkspaceEditorViewport<Content: View>: View {
    let content: Content
    var scrolls = true
    /// Layout-driven tools need a finite proposal; an intrinsic-size request
    /// collapses GeometryReader to its ten-point ideal size.
    var layoutSize: NSSize? = nil
    var body: some View {
        if scrolls {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                if let layoutSize {
                    content.frame(width: layoutSize.width, height: layoutSize.height, alignment: .topLeading)
                } else {
                    content.fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } else { content }
    }
}

/// Editors remain independent windows so mixer, timeline and transport stay interactive.
private struct WorkspaceEditorPresenter<Content: View>: NSViewRepresentable {
    @Binding var presented: Bool
    let title: String
    var scrolls = true
    var size: CGSize? = nil
    var canClose: () -> Bool = { true }
    @ViewBuilder let content: () -> Content
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.presented = $presented
        coordinator.canClose = canClose
        guard presented else { coordinator.close(notify: false); return }
        if coordinator.panel != nil { return }
        guard !coordinator.opening else { return }
        coordinator.opening = true
        let title = title, content = content, scrolls = scrolls, size = size
        DispatchQueue.main.async { [weak coordinator] in
            guard let coordinator else { return }
            coordinator.opening = false
            guard coordinator.presented?.wrappedValue == true else { return }
            let panel = makeWorkspacePanel(title: JarasLocalization.string(title),
                size: NSSize(width: 380, height: 500), minimum: NSSize(width: 320, height: 240))
            panel.identifier = NSUserInterfaceItemIdentifier("catlive.editor." + title)
            panel.delegate = coordinator
            let editor = WorkspaceToolContent(content: content().environment(\.workspaceEditorDismiss, { [weak coordinator] in coordinator?.close(notify: true) }), updateTitle: { [weak panel] in
                panel?.title = JarasLocalization.string(title)
            })
            // Fixed-canvas editors already know their dimensions. Measuring a
            // second hosting tree repeats construction and onAppear work before
            // their real window can become visible.
            let initialSize = size ?? workspaceEditorContentSize(editor)
            let host = WorkspaceEditorHostingView(rootView: WorkspaceEditorViewport(content: editor, scrolls: scrolls).interfaceScaled())
            if #available(macOS 13, *) { host.sizingOptions = [] }
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            panel.contentView = host
            let available = panel.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? initialSize
            panel.styleMask.remove(.resizable)
            panel.contentMinSize = .zero
            panel.setContentSize(NSSize(width: min(initialSize.width, available.width), height: min(initialSize.height, max(240, available.height - 32))))
            InterfaceScaling.shared.register(panel)
            coordinator.panel = panel
            panel.center(); attachWorkspacePanel(panel); ProjectionWindow.presentWorkspaceWindow(panel)
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close(notify: false) }
    final class Coordinator: NSObject, NSWindowDelegate {
        var presented: Binding<Bool>?
        var panel: NSPanel?
        var opening = false
        var canClose: () -> Bool = { true }
        func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
        func close(notify: Bool) {
            guard let panel else { return }
            detach(panel)
            panel.orderOut(nil)
            panel.close()
            if notify { presented?.wrappedValue = false }
        }
        func windowWillClose(_ notification: Notification) {
            guard let closing = notification.object as? NSPanel, closing === panel else { return }
            detach(closing)
            presented?.wrappedValue = false
        }
        private func detach(_ closing: NSPanel) {
            panel = nil
            closing.delegate = nil
            closing.parent?.removeChildWindow(closing)
            // Let the window leave the screen before tearing down SwiftUI.
            DispatchQueue.main.async { closing.contentView = nil }
        }

    }
}

#else
struct MovableFXPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var offset = CGSize.zero
    @State private var origin = CGSize.zero
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(JarasTheme.secondary).frame(width: 56,height: 5).padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                .gesture(DragGesture().onChanged { offset = CGSize(width: origin.width + $0.translation.width,height: origin.height + $0.translation.height) }.onEnded { _ in origin = offset })
            content()
        }.background(JarasTheme.panel).cornerRadius(12).offset(offset)
    }
}
#endif


private struct WorkspaceEditorDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var workspaceEditorDismiss: (() -> Void)? {
        get { self[WorkspaceEditorDismissKey.self] }
        set { self[WorkspaceEditorDismissKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func workspaceEditor<Content: View>(_ title: String, isPresented: Binding<Bool>, scrolls: Bool = true, size: CGSize? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        background(WorkspaceEditorPresenter(presented: isPresented, title: title, scrolls: scrolls, size: size, content: content).frame(width: 0, height: 0))
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
    @ViewBuilder func workspaceEditor<Item: Identifiable, Content: View>(_ title: String, item: Binding<Item?>, scrolls: Bool = true,
        size: CGSize? = nil, canClose: @escaping () -> Bool = { true }, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(macOS)
        background(WorkspaceEditorPresenter(presented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), title: title, scrolls: scrolls, size: size, canClose: canClose) {
            if let value = item.wrappedValue { content(value) }
        }.frame(width: 0, height: 0))
        #else
        sheet(item: item, content: content)
        #endif
    }
}
