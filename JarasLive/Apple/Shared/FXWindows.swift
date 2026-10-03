import SwiftUI

struct FXInsertEditor: View {
    let show: ShowController
    let track: UUID?
    let targets: [UUID?]
    var resize: (CGFloat) -> Void = { _ in }
    let dismiss: () -> Void
    @Environment(\.openFX) private var open
    @State private var effect = "EQ"
    @State private var instrument: String?
    @ObservedObject private var library = InstrumentLibrary.shared
    #if os(macOS)
    @ObservedObject private var plugins = PluginCatalog.shared
    @State private var external: String?
    @State private var externalError = ""
    @State private var browsingExternal = false
    #endif
    private var availableEffects: [String] {
        var result = track == nil ? ["EQ", "Compressor", "Limiter"] : NativeFXSettings.order.filter { targets.count == 1 || $0 != "Instruments" }
        #if os(macOS)
        if track != nil && targets.count == 1 { result.append("CatStemSeparation 5") }
        result.append("External")
        #endif
        return result
    }
    private var cannotApply: Bool {
        if effect == "Instruments" { return !library.downloaded.contains(instrument ?? "") }
        #if os(macOS)
        if effect == "External" { return external == nil || plugins.scanning }
        #endif
        return false
    }
    var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Insert effect").font(.headline)
                    Picker("Effect", selection: $effect) {
                        ForEach(availableEffects, id: \.self) { Text(LocalizedStringKey($0 == "Limiter" ? "CatLive Limiter" : $0)).tag($0) }
                    }.pickerStyle(.menu)
                    if effect == "Instruments" { InstrumentBrowser(selected: $instrument).frame(height: 330) }
                    #if os(macOS)
                    if effect == "External" {
                        Button { browsingExternal = true } label: {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                Text(external.flatMap { id in plugins.plugins.first { $0.id == id }?.name } ?? JarasLocalization.string("Choose a plugin"))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "square.grid.2x2")
                            }.frame(maxWidth: .infinity).padding(8)
                        }.buttonStyle(.bordered)
                        HStack { Button("Scan plugins") { plugins.scan() }.disabled(plugins.scanning); if plugins.scanning { ProgressView().controlSize(.small) } }
                        if !externalError.isEmpty { Text(verbatim: externalError).font(.caption).foregroundStyle(.red) }
                    }
                    #endif
                    HStack {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Apply") {
                            guard availableEffects.contains(effect) else { return }
                            #if os(macOS)
                            if effect == "CatStemSeparation 5" {
                                dismiss(); open(track, effect); return
                            }
                            if effect == "External" {
                                guard let chosen = plugins.plugins.first(where: { $0.id == external }) else { return }
                                var prepared: [(UUID?, NativeFXSettings, String)] = []
                                do {
                                    for target in targets {
                                        guard let chain = StemAudioPlayback.shared.effects(for: target) else { continue }
                                        var settings = show.fxSettings(target)
                                        var instance = chosen.instance
                                        settings.externalPlugins = (settings.externalPlugins ?? []) + [instance]
                                        settings.inserted.append(instance.effectKey)
                                        try settings.validate()
                                        let node = try chain.prepareExternal(instance)
                                        if let state = JarasVST3.state(node, identifier: instance.id) {
                                            instance.componentState = state["componentState"] as? String; instance.controllerState = state["controllerState"] as? String
                                            let index = settings.externalPlugins!.count - 1
                                            settings.externalPlugins?[index] = instance
                                        }
                                        prepared.append((target, settings, instance.effectKey))
                                    }
                                    for (target, settings, _) in prepared { show.previewFX(target, settings: settings); show.commitFX() }
                                    if let first = prepared.first { dismiss(); open(first.0, first.2) }
                                } catch {
                                    for target in targets {
                                        StemAudioPlayback.shared.effects(for: target)?.apply(show.fxSettings(target))
                                    }
                                    externalError = error.localizedDescription
                                }
                                return
                            }
                            #endif
                            var insertedKey: String?
                            if effect == "Instruments" {
                                guard targets.count == 1, let instrument, library.downloaded.contains(instrument) else { return }
                                var settings = show.fxSettings(track)
                                insertedKey = settings.appendNative(effect, instrument: instrument, parameters: InstrumentLibrary.parameters(instrument))
                                show.previewFX(track, settings: settings); show.commitFX()
                            } else {
                                for target in targets {
                                    let key = show.insertFX(target, effect: effect)
                                    if target == track { insertedKey = key }
                                }
                            }
                            guard let insertedKey, show.fxSettings(track).inserted.contains(insertedKey) else { return }
                            dismiss()
                            open(track, insertedKey)
                        }.keyboardShortcut(.defaultAction).disabled(cannotApply)
                    }
                }.padding(20).frame(width: effect == "Instruments" ? 440 : 300).foregroundStyle(JarasTheme.text)
        .onAppear { instrument = show.fxSettings(track).instrumentID; resize(210) }
        .onChange(of: effect) { value in resize(value == "Instruments" ? 500 : value == "External" ? 310 : 210) }
        #if os(macOS)
        .onChange(of: effect) { value in if value == "External" { browsingExternal = true } }
        .background(ExternalPluginBrowserPresenter(isPresented: $browsingExternal, selected: $external,
                                                  allowsInstruments: targets.count == 1 && track != nil))
        #endif
    }
}
#if os(macOS)
import AppKit
import Combine

private struct LocalizedClipFXEditor: View {
    let show: ShowController
    let clip: UUID
    let close: () -> Void
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        TabbedClipFXEditor(show: show, clip: clip, close: close)
            .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
    }
}
@MainActor final class FXWindows: NSObject, NSWindowDelegate {
    static let shared = FXWindows()
    weak var documents: ProjectDocuments?
    private enum Target: Hashable {
        case track(UUID?, String)
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
        open(show: show, target: WindowKey(project: show.snapshot.project.id, target: .track(track, "Chain")), preferredEffect: effect)
    }
    func openClipChain(show: ShowController, clip: UUID) {
        open(show: show, target: WindowKey(project: show.snapshot.project.id, target: .clip(clip)))
    }
    private func targetExists(_ key: WindowKey, in show: ShowController) -> Bool {
        guard key.project == show.snapshot.project.id else { return false }
        switch key.target {
        case .clip(let clip): return FXModelLookup.clip(clip, in: show.snapshot.project) != nil
        case .track(let track, let effect):
            return (track == nil || track.map { FXModelLookup.track($0, in: show.snapshot.project)?.kind == .standard } == true) && (effect == "Chain" || show.fxSettings(track).inserted.contains(effect))
        }
    }
    private func title(_ key: WindowKey, in show: ShowController) -> String {
        switch key.target {
        case .clip(let clip): return "CatLive FX · " + (FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—")
        case .track(let track, let effect):
            let name = track.flatMap { id in FXModelLookup.track(id, in: show.snapshot.project)?.name } ?? "Master"
            if effect == "Chain" { return JarasLocalization.string("FX Manager") }
            return (show.fxSettings(track).externalPlugins?.first(where: { $0.effectKey == effect })?.name ?? EffectPresentation.title(effect)) + " · " + name
        }
    }
    private func clipContent(_ clip: UUID, show: ShowController, panel: NSPanel) -> LocalizedClipFXEditor {
        LocalizedClipFXEditor(show: show, clip: clip, close: { [weak panel] in panel?.close() })
    }
    private func content(_ key: WindowKey, show: ShowController, panel: NSPanel, preferredEffect: String?) -> NSView {
        switch key.target {
        case .clip(let clip): return NSHostingView(rootView: clipContent(clip, show: show, panel: panel))
        case .track(let track, _):
            let view = TrackFXChainView(show: show, track: track, effect: preferredEffect ?? show.fxSettings(track).effectKeys.first ?? "EQ", panel: panel)
            panel.setContentSize(view.preferredContentSize)
            return view
        }
    }
    private func open(show: ShowController, target key: WindowKey, preferredEffect: String? = nil) {
        guard targetExists(key, in: show) else { return }
        if self.show !== show {
            closeAll(); self.show = show
            projectObservation = show.$snapshot.map { $0.project.id }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.closeAll() }
        }
        if let panel = windows[key] {
            if let preferredEffect { (panel.contentView as? TrackFXChainView)?.select(preferredEffect) }
            panel.makeKeyAndOrderFront(nil); return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 740,height: 560), styleMask: [.titled,.closable,.resizable,.utilityWindow], backing: .buffered, defer: false)
        panel.title = title(key, in: show)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentMinSize = NSSize(width: 640,height: 540)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false; panel.hidesOnDeactivate = true
        panel.level = .normal; panel.delegate = self
        panel.contentView = content(key, show: show, panel: panel, preferredEffect: preferredEffect)
        panel.center()
        let stagger = CGFloat(windows.count % 5) * 26
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + stagger,y: panel.frame.minY - stagger))
        windows[key] = panel
        // A normal-level child stays above the DAW when the timeline is clicked,
        // while application deactivation and attached editing sheets retain priority.
        if let parent = NSApp.mainWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }) {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        if let show, let key = windows.first(where: { $0.value === panel })?.key,
           case .track(let track, _) = key.target {
            for plugin in show.fxSettings(track).externalPlugins ?? [] {
                ExternalPluginState.capture(show: show, track: track, identifier: plugin.id)
            }
        }
        panel.parent?.removeChildWindow(panel)
        windows = windows.filter { $0.value !== panel }
        panel.contentView = nil
    }
    func synchronize(show: ShowController) {
        for (key, panel) in Array(windows) {
            guard targetExists(key, in: show) else { panel.close(); continue }
            panel.title = title(key, in: show)
            if case .clip(let clip) = key.target, let host = panel.contentView as? NSHostingView<LocalizedClipFXEditor> {
                // Updating the existing host preserves the selected tab and drafts.
                host.rootView = clipContent(clip, show: show, panel: panel)
            }
            // Track chains observe their own FX metadata and preserve the current editor.

        }
    }
    func suspendAudioEditors() {
        for panel in windows.values { (panel.contentView as? TrackFXChainView)?.suspendAudioEditor() }
    }
    func restoreAudioEditors() {
        for panel in windows.values { (panel.contentView as? TrackFXChainView)?.restoreAudioEditor() }
    }
    func closeAll() { for panel in Array(windows.values) { panel.close() }; windows.removeAll() }
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
