import SwiftUI

struct FXInsertEditor: View {
    let show: ShowController
    let track: UUID?
    let targets: [UUID?]
    var clip: UUID? = nil
    var inserted: ((String) -> Void)? = nil
    var resize: (CGFloat) -> Void = { _ in }
    let dismiss: () -> Void
    private let project: UUID
    private let isActive: () -> Bool
    init(show: ShowController, track: UUID?, targets: [UUID?], clip: UUID? = nil,
         inserted: ((String) -> Void)? = nil, isActive: @escaping () -> Bool = { true },
         resize: @escaping (CGFloat) -> Void = { _ in },
         dismiss: @escaping () -> Void) {
        self.show = show; self.track = track; self.targets = targets; self.clip = clip
        self.inserted = inserted; self.isActive = isActive; self.resize = resize; self.dismiss = dismiss
        project = show.snapshot.project.id
    }
    private var targetIsCurrent: Bool {
        guard isActive(), show.snapshot.project.id == project else { return false }
        if let clip { return FXModelLookup.clip(clip, in: show.snapshot.project) != nil }
        return targets.allSatisfy { target in
            target == nil || target.flatMap { FXModelLookup.track($0, in: show.snapshot.project) } != nil
        }
    }
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
        var result = NativeFXSettings.order.filter { $0 != "Instruments" || (clip == nil && track != nil && targets.count == 1) }
        #if os(iOS)
        result.removeAll { $0 == "Instruments" }
        #endif
        if targets.count == 1 { result.append(NativeFXSettings.stemSeparator) }
        #if os(macOS)
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
    private func finishInsertion(_ key: String, track target: UUID?) {
        guard targetIsCurrent else { dismiss(); return }
        dismiss()
        if let inserted { inserted(key) }
        else if clip == nil { open(target, key) }
    }
    var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Insert effect").font(.jarasHeadline)
                    Picker("Effect", selection: $effect) {
                        ForEach(availableEffects, id: \.self) { Text(LocalizedStringKey($0 == "Limiter" ? "CatLive Limiter" : $0)).tag($0) }
                    }.pickerStyle(.menu)
                    #if os(iOS)
                    .padding(12).frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.25)))
                    .tint(JarasTheme.green)
                    #endif
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
                        if !externalError.isEmpty { Text(verbatim: externalError).font(.jarasCaption).foregroundStyle(.red) }
                    }
                    #endif
                    HStack {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Apply") {
                            guard targetIsCurrent else { dismiss(); return }
                            guard availableEffects.contains(effect) else { return }
                            #if os(macOS)
                            if effect == "External" {
                                guard let chosen = plugins.plugins.first(where: { $0.id == external }) else { return }
                                if let clip {
                                    // A MIDI take has no audio instance before its first
                                    // instrument. Validate the chosen plugin separately,
                                    // then let the normal item update build its live voice.
                                    let preparation = NativeEffectsChain()
                                    defer { preparation.releaseExternal() }
                                    do {
                                        var settings = show.clipFXSettings(clip)
                                        var instance = try FXPresetStore.shared.applyingDefault(to: chosen.instance)
                                        settings.externalPlugins = (settings.externalPlugins ?? []) + [instance]
                                        settings.inserted.append(instance.effectKey)
                                        try settings.validateForClip()
                                        let node = try preparation.prepareExternal(instance)
                                        if let state = JarasVST3.state(node, identifier: instance.id) {
                                            instance.componentState = state["componentState"] as? String
                                            instance.controllerState = state["controllerState"] as? String
                                            if let index = settings.externalPlugins?.firstIndex(where: { $0.id == instance.id }) {
                                                settings.externalPlugins?[index] = instance
                                            }
                                        }
                                        show.previewClipFX(clip, settings: settings); show.commitFX()
                                        guard show.clipFXSettings(clip).inserted.contains(instance.effectKey) else {
                                            externalError = show.message
                                            return
                                        }
                                        finishInsertion(instance.effectKey, track: nil)
                                    } catch { externalError = error.localizedDescription }
                                    return
                                }
                                var prepared: [(UUID?, NativeFXSettings, String)] = []
                                do {
                                    for target in targets {
                                        guard let chain = StemAudioPlayback.shared.effects(for: target) else { continue }
                                        var settings = show.fxSettings(target)
                                        var instance = try FXPresetStore.shared.applyingDefault(to: chosen.instance)
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
                                    for (target, settings, _) in prepared { show.previewFX(target, settings: settings) }
                                    show.commitFX()
                                    if let first = prepared.first { finishInsertion(first.2, track: first.0) }
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
                            if let clip {
                                insertedKey = show.insertClipFX(clip, effect: effect)
                            } else if effect == "Instruments" {
                                guard targets.count == 1, let instrument, library.downloaded.contains(instrument) else { return }
                                var settings = show.fxSettings(track)
                                insertedKey = settings.appendNative(effect, instrument: instrument, parameters: InstrumentLibrary.parameters(instrument))
                                do { settings = try FXPresetStore.shared.applyingDefault(to: settings, effect: insertedKey!) }
                                catch { show.message = error.localizedDescription; return }
                                show.previewFX(track, settings: settings); show.commitFX()
                            } else {
                                insertedKey = show.insertFX(targets, effect: effect)[track]
                            }
                            let settings = clip.map(show.clipFXSettings) ?? show.fxSettings(track)
                            guard let insertedKey, settings.inserted.contains(insertedKey) else { return }
                            finishInsertion(insertedKey, track: track)
                        }.keyboardShortcut(.defaultAction).disabled(cannotApply)
                    }
                    #if os(iOS)
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
                    #endif
                }.padding(20).frame(width: effect == "Instruments" ? 440 : 360).foregroundStyle(JarasTheme.text)
        .onAppear { instrument = (clip.map(show.clipFXSettings) ?? show.fxSettings(track)).instrumentID; resize(210) }
        .onChange(of: effect) { value in resize(value == "Instruments" ? 500 : value == "External" ? 310 : 210) }
        #if os(macOS)
        .onChange(of: effect) { value in if value == "External" { browsingExternal = true } }
        .background(ExternalPluginBrowserPresenter(isPresented: $browsingExternal, selected: $external,
                                                  allowsInstruments: clip.map { FXModelLookup.clip($0, in: show.snapshot.project)?.midi != nil } ?? (targets.count == 1 && track != nil)))
        #endif
    }
}
#if os(macOS)
import AppKit
import Combine

@MainActor final class FXWindows: NSObject, NSWindowDelegate {
    static let shared = FXWindows()
    private enum Target: Hashable {
        case track(UUID?)
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
        open(show: show, target: WindowKey(project: show.snapshot.project.id, target: .track(track)), preferredEffect: effect)
    }
    func openClipChain(show: ShowController, clip: UUID) {
        open(show: show, target: WindowKey(project: show.snapshot.project.id, target: .clip(clip)))
    }
    private func targetExists(_ key: WindowKey, in show: ShowController) -> Bool {
        guard key.project == show.snapshot.project.id else { return false }
        switch key.target {
        case .clip(let clip): return FXModelLookup.clip(clip, in: show.snapshot.project) != nil
        case .track(let track):
            return track == nil || track.map { FXModelLookup.track($0, in: show.snapshot.project)?.kind == .standard } == true
        }
    }
    private func title(_ key: WindowKey, in show: ShowController) -> String {
        switch key.target {
        case .clip(let clip): return JarasLocalization.string("FX Manager") + " - " + (FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—")
        case .track(let track):
            let name = track.flatMap { id in FXModelLookup.track(id, in: show.snapshot.project)?.name } ?? "Master"
            return JarasLocalization.string("FX Manager") + " - " + name
        }
    }
    private func content(_ key: WindowKey, show: ShowController, panel: NSPanel, preferredEffect: String?) -> NSView {
        switch key.target {
        case .clip(let clip):
            let view = TrackFXChainView(show: show, track: nil, clip: clip, effect: preferredEffect ?? show.clipFXSettings(clip).clipEffectKeys.first ?? "", panel: panel)
            panel.setContentSize(view.preferredContentSize)
            return view
        case .track(let track):
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
        // The normal titlebar provides full-size native window controls for
        // both track chains and item FX, including third-party editors.
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 740,height: 560), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        panel.title = title(key, in: show)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentMinSize = NSSize(width: 640,height: 540)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false; panel.hidesOnDeactivate = true
        panel.level = .normal; panel.delegate = self
        panel.contentView = content(key, show: show, panel: panel, preferredEffect: preferredEffect)
        InterfaceScaling.shared.register(panel)
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
           case .track(let track) = key.target {
            for plugin in show.fxSettings(track).externalPlugins ?? [] {
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
