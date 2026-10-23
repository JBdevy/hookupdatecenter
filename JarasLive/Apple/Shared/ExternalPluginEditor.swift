#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
@MainActor enum ExternalPluginState {
    static func settings(show: ShowController, track: UUID?, clip: UUID? = nil) -> NativeFXSettings {
        clip.map { show.clipFXSettings($0) } ?? show.fxSettings(track)
    }
    static func capture(show: ShowController, track: UUID?, clip: UUID? = nil, identifier: String,
                        node suppliedNode: AVAudioUnitEffect? = nil, project: UUID? = nil) {
        do { try captureState(show: show, track: track, clip: clip, identifier: identifier, node: suppliedNode, project: project, saving: false) }
        catch { show.message = error.localizedDescription }
    }
    static func captureForSaving(show: ShowController, track: UUID?, clip: UUID? = nil, identifier: String,
                                 node suppliedNode: AVAudioUnitEffect? = nil, project: UUID? = nil) throws {
        try captureState(show: show, track: track, clip: clip, identifier: identifier, node: suppliedNode, project: project, saving: true)
    }
    private static func captureState(show: ShowController, track: UUID?, clip: UUID?, identifier: String,
                                     node suppliedNode: AVAudioUnitEffect?, project: UUID?, saving: Bool) throws {
        guard project == nil || project == show.snapshot.project.id else { return }
        if let clip, FXModelLookup.clip(clip, in: show.snapshot.project) == nil { return }
        let node = suppliedNode ?? DesktopProjectTabs.shared.audio(for: show).effects(for: clip ?? track)?.externalNode(identifier)
        guard let node else { return }
        guard let state = JarasVST3.state(node, identifier: identifier) else {
            if saving { throw ProjectError.invalid("Não foi possível capturar o estado atual do plugin. A operação foi cancelada.") }
            return
        }
        var settings = settings(show: show, track: track, clip: clip)
        guard let index = settings.externalPlugins?.firstIndex(where: { $0.id == identifier }) else { return }
        let before = settings
        settings.externalPlugins?[index].componentState = state["componentState"] as? String
        settings.externalPlugins?[index].controllerState = state["controllerState"] as? String
        guard settings != before else { return }
        if saving {
            guard try show.storeCapturedPluginState(track, clip: clip, identifier: identifier,
                componentState: settings.externalPlugins?[index].componentState,
                controllerState: settings.externalPlugins?[index].controllerState),
                let plugin = settings.externalPlugins?[index] else { return }
            DesktopProjectTabs.shared.audio(for: show).rememberCapturedPluginState(track: track, clip: clip, plugin: plugin, source: node)
            return
        }
        if let clip { show.previewClipFX(clip, settings: settings) }
        else { show.previewFX(track, settings: settings) }
        show.commitFX()
    }
    static func captureAll(show: ShowController) {
        do { try captureAllForSaving(show: show) }
        catch { show.message = error.localizedDescription }
    }
    static func captureAllForSaving(show: ShowController) throws {
        let targets: [UUID?] = [nil] + (show.current?.tracks.filter { $0.kind == .standard }.map { Optional($0.id) } ?? [])
        for target in targets { for plugin in show.fxSettings(target).externalPlugins ?? [] { try captureForSaving(show: show, track: target, identifier: plugin.id) } }
        // Only open take editors can have uncaptured UI edits. Do not instantiate
        // every project's item chain merely because the user saved the project.
        try ClipExternalPluginHostView.captureAllForSaving(show: show)
    }
    static func bindEdits(show: ShowController, track: UUID?, clip: UUID?, plugin: ExternalPlugin, node: AVAudioUnitEffect) {
        let project = show.snapshot.project.id
        JarasVST3.onParameterEdit(node, identifier: plugin.id) { [weak show] parameter, value, ended in
            guard let show, show.snapshot.project.id == project else { return }
            // A take editor must never write an envelope on Master or its track.
            if clip == nil {
                show.recordAutomationControl(track, target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: parameter), value: value)
                if ended { show.endAutomationTouch(track) }
            }
        }
        JarasVST3.onEdit(node, identifier: plugin.id) { [weak show, weak node] in
            guard let show, let node else { return }
            capture(show: show, track: track, clip: clip, identifier: plugin.id, node: node, project: project)
        }
    }
    static func clearEdits(node: AVAudioUnitEffect, identifier: String) {
        JarasVST3.onEdit(node, identifier: identifier) {}
        JarasVST3.onParameterEdit(node, identifier: identifier) { _, _, _ in }
    }
}
struct ExternalPluginEditor: View {
    let show: ShowController
    let track: UUID?
    let clip: UUID?
    let effect: String
    private let project: UUID
    @State private var parameters: [[AnyHashable: Any]] = []
    @State private var values: [UInt32: Double] = [:]
    @State private var failure = ""
    @State private var editingNode: AVAudioUnitEffect?
    init(show: ShowController, track: UUID?, clip: UUID? = nil, effect: String) {
        self.show = show; self.track = track; self.clip = clip; self.effect = effect; project = show.snapshot.project.id
    }
    private var plugin: ExternalPlugin? {
        guard show.snapshot.project.id == project else { return nil }
        if let clip, FXModelLookup.clip(clip, in: show.snapshot.project) == nil { return nil }
        return ExternalPluginState.settings(show: show, track: track, clip: clip).externalPlugins?.first { $0.effectKey == effect }
    }
    static func nativeEditor(show: ShowController, track: UUID?, clip: UUID? = nil, effect: String) -> NSView? {
        guard let plugin = ExternalPluginState.settings(show: show, track: track, clip: clip).externalPlugins?.first(where: { $0.effectKey == effect }),
              let chain = DesktopProjectTabs.shared.audio(for: show).effects(for: clip ?? track), chain.externalError == nil, let node = chain.externalNode(plugin.id),
              let view = JarasVST3.editor(node, identifier: plugin.id) else { return nil }
        ExternalPluginState.bindEdits(show: show, track: track, clip: clip, plugin: plugin, node: node)
        return view
    }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if !failure.isEmpty { Text(LocalizedStringKey(failure)).foregroundStyle(.red) }
                ForEach(Array(parameters.enumerated()), id: \.offset) { _, parameter in
                    if let id = parameter["id"] as? UInt32, let name = parameter["name"] as? String {
                        HStack {
                            Text(verbatim: name).frame(width: 190, alignment: .leading).lineLimit(1)
                            Slider(value: Binding(get: { values[id] ?? 0 }, set: { value in
                                guard show.snapshot.project.id == project, let plugin, let node = editingNode else { return }
                                values[id] = value
                                JarasVST3.setParameter(node, identifier: plugin.id, parameter: id, value: value)
                                if clip == nil { show.recordAutomationControl(track, target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: id), value: value) }
                            }), in: 0...1, onEditingChanged: { editing in
                                if !editing, let plugin {
                                    if clip == nil { show.endAutomationTouch(track) }
                                    ExternalPluginState.capture(show: show, track: track, clip: clip, identifier: plugin.id, node: editingNode, project: project)
                                }
                            }).disabled(parameter["readOnly"] as? Bool == true)
                        }
                    }
                }
            }.padding(18)
        }.background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear {
                guard let plugin else { failure = "Plugin settings are unavailable"; return }
                guard let chain = DesktopProjectTabs.shared.audio(for: show).effects(for: clip ?? track) else { failure = "Audio track is not prepared"; return }
                if let error = chain.externalError { failure = error.localizedDescription; return }
                guard let node = chain.externalNode(plugin.id) else { failure = "Plugin is not loaded"; return }
                editingNode = node
                ExternalPluginState.bindEdits(show: show, track: track, clip: clip, plugin: plugin, node: node)
                parameters = JarasVST3.parameters(node, identifier: plugin.id)
                if parameters.isEmpty { failure = "This plugin does not expose controls" }
                for parameter in parameters { if let id = parameter["id"] as? UInt32 { values[id] = parameter["value"] as? Double ?? 0 } }
            }
            .onDisappear {
                if let plugin, let node = editingNode {
                    ExternalPluginState.capture(show: show, track: track, clip: clip, identifier: plugin.id, node: node, project: project)
                    ExternalPluginState.clearEdits(node: node, identifier: plugin.id)
                }
                editingNode = nil
            }
    }
}
/// Keeps a take's native editor attached to its own audio instance. Audio graph
/// rebuilds detach the view first; they must not leave a native editor on an old
/// voice, or edits would no longer reach the instance producing sound.
@MainActor final class ClipExternalPluginHostView: NSView {
    private static let hosts = NSHashTable<ClipExternalPluginHostView>.weakObjects()
    private weak var show: ShowController?
    private let clip: UUID, effect: String, project: UUID
    private let scroll = NSScrollView()
    private var node: AVAudioUnitEffect?
    private var pluginIdentifier: String?
    private var observing = false
    private var usesParameterEditor = false
    init(show: ShowController, clip: UUID, effect: String) {
        self.show = show; self.clip = clip; self.effect = effect; project = show.snapshot.project.id
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; addSubview(scroll)
        Self.hosts.add(self); resume()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); scroll.frame = bounds
        if usesParameterEditor { scroll.documentView?.frame = scroll.contentView.bounds }
    }
    private func capture() {
        if let show, let pluginIdentifier, let node {
            ExternalPluginState.capture(show: show, track: nil, clip: clip, identifier: pluginIdentifier, node: node, project: project)
        }
    }
    func suspend() {
        capture()
        if let pluginIdentifier, let node {
            ExternalPluginState.clearEdits(node: node, identifier: pluginIdentifier)
        }
        scroll.documentView = nil; node = nil; pluginIdentifier = nil; usesParameterEditor = false
        if observing { StemAudioPlayback.shared.observeEffect(clip, effect: effect, active: false); observing = false }
    }
    func resume() {
        guard !observing, let show, show.snapshot.project.id == project,
              FXModelLookup.clip(clip, in: show.snapshot.project) != nil,
              let plugin = show.clipFXSettings(clip).externalPlugins?.first(where: { $0.effectKey == effect }) else { return }
        StemAudioPlayback.shared.observeEffect(clip, effect: effect, active: true); observing = true
        node = StemAudioPlayback.shared.effects(for: clip)?.externalNode(plugin.id); pluginIdentifier = plugin.id
        if let native = ExternalPluginEditor.nativeEditor(show: show, track: nil, clip: clip, effect: effect) {
            scroll.documentView = native
        } else {
            usesParameterEditor = true
            let language = UserDefaults.standard.string(forKey: "jaras.language") ?? "en"
            let host = NSHostingView(rootView: ExternalPluginEditor(show: show, track: nil, clip: clip, effect: effect)
                .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark).interfaceScaled())
            if #available(macOS 13, *) { host.sizingOptions = [] }
            host.frame = bounds; scroll.documentView = host
        }
        needsLayout = true
    }
    static func suspendAll() { for view in hosts.allObjects { view.suspend() } }
    static func restoreAll() { for view in hosts.allObjects where view.window != nil { view.resume() } }
    static func captureAllForSaving(show: ShowController) throws {
        for view in hosts.allObjects where view.show === show {
            if let identifier = view.pluginIdentifier, let node = view.node {
                try ExternalPluginState.captureForSaving(show: show, track: nil, clip: view.clip,
                    identifier: identifier, node: node, project: view.project)
            }
        }
    }
}

#endif

#if os(macOS)
import Combine
@MainActor private final class FXChainTableView: NSTableView {
    var bypassRow: ((Int) -> Void)?
    var removeRow: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            bypassRow?(row(at: convert(event.locationInWindow, from: nil))); return
        }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if event.modifierFlags.contains(.option) { removeRow?(index); return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: JarasLocalization.string("Remove"), action: #selector(removeEffect(_:)), keyEquivalent: "")
        item.target = self; item.tag = index; menu.addItem(item); return menu
    }
    @objc private func removeEffect(_ sender: NSMenuItem) { removeRow?(sender.tag) }
}
@MainActor final class TrackFXChainView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row: Equatable { let effect: String, name: String, enabled: Bool }
    private let show: ShowController
    private let track: UUID?
    private let clip: UUID?
    private let project: UUID
    private var closed = false
    private weak var panel: NSPanel?
    private let list = FXChainTableView()
    private let scroll = NSScrollView()
    private let editorArea = NSView()
    private var presetBar: FXPresetBar!
    private let footer = NSView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private var insertionPanel: NSPanel?
    private var editor: NSView?
    private var rows: [Row] = []
    private var selection: String?
    private var observation: AnyCancellable?
    private var refreshing = false
    private let sidebarWidth: CGFloat = 190
    private static let dragType = NSPasteboard.PasteboardType("com.jaras.fx-order")
    private(set) var preferredContentSize = NSSize(width: 930, height: 560)
    override var isFlipped: Bool { true }
    private var settings: NativeFXSettings { clip.map(show.clipFXSettings) ?? show.fxSettings(track) }
    private var targetIsCurrent: Bool {
        guard !closed, show.snapshot.project.id == project else { return false }
        if let clip { return FXModelLookup.clip(clip, in: show.snapshot.project) != nil }
        return track == nil || track.flatMap { FXModelLookup.track($0, in: show.snapshot.project) } != nil
    }
    init(show: ShowController, track: UUID?, clip: UUID? = nil, effect: String, panel: NSPanel) {
        self.show = show; self.track = track; self.clip = clip; self.panel = panel; project = show.snapshot.project.id
        super.init(frame: NSRect(origin: .zero, size: preferredContentSize))
        wantsLayer = true; layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor
        let enabled = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled")); enabled.width = 30; enabled.minWidth = 30; enabled.maxWidth = 30
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.width = 148
        list.addTableColumn(enabled); list.addTableColumn(name); list.headerView = nil
        list.rowHeight = 28; list.intercellSpacing = NSSize(width: 2, height: 2)
        list.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1); list.style = .plain
        list.dataSource = self; list.delegate = self; list.allowsEmptySelection = false
        list.bypassRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row) else { return }
            self.toggleBypass(self.rows[row].effect)
        }
        list.removeRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row) else { return }
            self.removeEffect(self.rows[row].effect)
        }
        if clip == nil {
            list.registerForDraggedTypes([Self.dragType]); list.setDraggingSourceOperationMask(.move, forLocal: true)
        }
        scroll.documentView = list; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        addButton.title = JarasLocalization.string("Add"); addButton.bezelStyle = .rounded; addButton.target = self; addButton.action = #selector(addEffect)
        removeButton.title = JarasLocalization.string("Remove"); removeButton.bezelStyle = .rounded; removeButton.target = self; removeButton.action = #selector(removeSelectedEffect)
        footer.addSubview(addButton); footer.addSubview(removeButton)
        addSubview(scroll); addSubview(editorArea); addSubview(footer)
        presetBar = FXPresetBar(read: { [weak self] in self?.settings ?? NativeFXSettings() }, capture: { [weak self] effect in
            guard let self, self.targetIsCurrent else { throw ProjectError.invalid("Effect no longer exists") }
            var value = self.settings
            if let index = value.externalPlugins?.firstIndex(where: { $0.effectKey == effect }), let plugin = value.externalPlugins?[index] {
                guard let node = StemAudioPlayback.shared.effects(for: self.clip ?? self.track)?.externalNode(plugin.id),
                      let state = JarasVST3.state(node, identifier: plugin.id) else { throw ProjectError.invalid("Could not read the plugin state") }
                value.externalPlugins?[index].componentState = state["componentState"] as? String
                value.externalPlugins?[index].controllerState = state["controllerState"] as? String
            }
            return value
        }, apply: { [weak self] value in
            guard let self, self.targetIsCurrent else { return }
            if let clip = self.clip { self.show.previewClipFX(clip, settings: value) }
            else { self.show.previewFX(self.track, settings: value) }
            self.show.commitFX()
        }, report: { [weak self] message in
            guard let self else { return }
            self.show.message = message
            if let window = self.window { let alert = NSAlert(); alert.messageText = message; alert.beginSheetModal(for: window) }
        })
        addSubview(presetBar)
        let initial = settings
        refresh(initial, preferred: effect)
        let empty = NativeFXSettings()
        observation = show.$snapshot.map { snapshot in
            if let clip { return FXModelLookup.clip(clip, in: snapshot.project)?.fx ?? empty }
            return track.flatMap { id in snapshot.project.songs.lazy.flatMap(\.tracks).first(where: { $0.id == id })?.fx }
                ?? (track == nil ? snapshot.project.masterFX : nil) ?? empty
        }.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] settings in self?.refresh(settings) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: max(0, bounds.height - 40))
        footer.frame = NSRect(x: 0, y: max(0, bounds.height - 40), width: sidebarWidth, height: 40)
        addButton.frame = NSRect(x: 6, y: 6, width: 84, height: 28)
        removeButton.frame = NSRect(x: 96, y: 6, width: 88, height: 28)
        presetBar.frame = NSRect(x: sidebarWidth, y: 0, width: max(1, bounds.width - sidebarWidth), height: 36)
        editorArea.frame = NSRect(x: sidebarWidth, y: 36, width: max(1, bounds.width - sidebarWidth), height: max(0, bounds.height - 36))
        editor?.frame = editorArea.bounds
    }
    private func refresh(_ settings: NativeFXSettings, preferred: String? = nil) {
        guard targetIsCurrent else { return }
        let effectKeys = clip == nil ? settings.effectKeys : settings.clipEffectKeys
        let next = effectKeys.map { effect in
            Row(effect: effect, name: settings.externalPlugins?.first(where: { $0.effectKey == effect })?.name
                ?? (settings.kind(of: effect) == "Instruments" ? InstrumentLibrary.displayName(settings.settings(for: effect).instrumentID) : JarasLocalization.string(settings.kind(of: effect))), enabled: settings.isEnabled(effect))
        }
        let removedEffect = rows.contains { old in !next.contains(where: { $0.effect == old.effect }) }
        if next != rows { rows = next; refreshing = true; list.reloadData(); refreshing = false }
        let selected = (removedEffect ? rows.last?.effect : nil) ?? preferred.flatMap { value in rows.first(where: { $0.effect == value })?.effect }
            ?? selection.flatMap { value in rows.first(where: { $0.effect == value })?.effect } ?? rows.first?.effect
        removeButton.isEnabled = selected != nil
        presetBar.refresh(effect: selected, settings: settings)
        guard let selected else { removeEditor(); selection = nil; return }
        select(selected)
        if let index = rows.firstIndex(where: { $0.effect == selected }) {
            refreshing = true; list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); refreshing = false
        }
    }
    func select(_ effect: String) {
        guard targetIsCurrent, rows.contains(where: { $0.effect == effect }), selection != effect else { return }
        if clip == nil, let previous = selection, let plugin = settings.externalPlugins?.first(where: { $0.effectKey == previous }) {
            ExternalPluginState.capture(show: show, track: track, identifier: plugin.id)
        }
        selection = effect; removeButton.isEnabled = true; removeEditor()
        presetBar.refresh(effect: effect, settings: settings)
        let content: NSView
        let size: NSSize
        if effect.hasPrefix("External:"), let clip {
            content = ClipExternalPluginHostView(show: show, clip: clip, effect: effect)
            size = NSSize(width: 740, height: 560)
            panel?.contentMinSize = NSSize(width: sidebarWidth + 400, height: 320)
        } else if effect.hasPrefix("External:"), let native = ExternalPluginEditor.nativeEditor(show: show, track: track, effect: effect) {
            content = native; size = native.frame.size
            panel?.contentMinSize = NSSize(width: sidebarWidth + 400, height: 64)
        } else {
            let language = UserDefaults.standard.string(forKey: "jaras.language") ?? "en"
            // editorArea supplies the frame; the panel below supplies the
            // minimum size. Do not ask SwiftUI to remeasure window limits.
            if effect == "CatStemSeparation 5" {
                let host = NSHostingView(rootView: CatStemFXEditor(show: show, track: track, clip: clip).environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark).interfaceScaled())
                if #available(macOS 13, *) { host.sizingOptions = [] }
                content = host
            } else if effect.hasPrefix("External:") {
                let host = NSHostingView(rootView: ExternalPluginEditor(show: show, track: track, effect: effect).environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark).interfaceScaled())
                if #available(macOS 13, *) { host.sizingOptions = [] }
                content = host
            } else {
                let host = NSHostingView(rootView: FXEditor(show: show, track: track, clip: clip, effect: effect, close: { [weak panel] in panel?.close() }).environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark).interfaceScaled())
                if #available(macOS 13, *) { host.sizingOptions = [] }
                content = host
            }
            let kind = settings.kind(of: effect)
            let compactControls = kind == "Delay" || kind == "Reverb"
            size = NSSize(width: 740, height: compactControls ? 360 : 560)
            panel?.contentMinSize = NSSize(width: sidebarWidth + 640, height: compactControls ? 340 : 540)
        }
        editor = content; editorArea.addSubview(content)
        preferredContentSize = NSSize(width: size.width + sidebarWidth, height: size.height + 36)
        if let panel { panel.contentMinSize.height += 36 }
        panel?.setContentSize(preferredContentSize); needsLayout = true
        if let index = rows.firstIndex(where: { $0.effect == effect }) {
            refreshing = true; list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); refreshing = false
        }
    }
    private func removeEditor() {
        // Direct AppKit containment does not invoke NSViewRepresentable's
        // dismantle hook. Release the take editor before replacing its view.
        let previous = editor
        editor = nil
        (previous as? ClipExternalPluginHostView)?.suspend()
        previous?.removeFromSuperview()
    }
    func closeEditors() {
        closed = true
        observation = nil
        if let insertionPanel { insertionPanel.parent?.removeChildWindow(insertionPanel); insertionPanel.close() }
        insertionPanel = nil
        removeEditor()
    }
    func suspendAudioEditor() {
        guard selection?.hasPrefix("External:") == true else { return }
        removeEditor()
    }
    func restoreAudioEditor() {
        guard targetIsCurrent, editor == nil, let selected = selection else { return }
        selection = nil; select(selected)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row]
        if tableColumn?.identifier.rawValue == "enabled" {
            let button = NSButton(title: "By", target: self, action: #selector(toggle(_:)))
            button.isBordered = false; button.font = NSFont.jarasSystemFont(ofSize: 10, weight: .semibold)
            button.identifier = NSUserInterfaceItemIdentifier(value.effect)
            button.wantsLayer = true; button.layer?.cornerRadius = 3
            button.layer?.backgroundColor = (value.enabled ? NSColor.white.withAlphaComponent(0.12) : NSColor.systemRed.withAlphaComponent(0.75)).cgColor
            button.contentTintColor = value.enabled ? .secondaryLabelColor : .white
            button.setAccessibilityLabel(JarasLocalization.string("Bypass") + " · " + value.name)
            return button
        }
        let text = NSTextField(labelWithString: value.name); text.lineBreakMode = .byTruncatingTail
        text.font = NSFont.jarasSystemFont(ofSize: 12); text.textColor = value.enabled ? .labelColor : .secondaryLabelColor
        return text
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let effect = sender.identifier?.rawValue else { return }
        toggleBypass(effect)
    }
    private func toggleBypass(_ effect: String) {
        guard targetIsCurrent else { return }
        if let clip { show.toggleClipFXBypass(clip, effect: effect) }
        else { show.toggleFXBypass(track, effect: effect) }
    }
    private func removeEffect(_ effect: String) {
        guard targetIsCurrent else { return }
        if let clip { show.removeClipFX(clip, effect: effect) }
        else { show.removeFX(track, effect: effect) }
        refresh(settings)
    }
    @objc private func addEffect() {
        guard targetIsCurrent else { return }
        if let insertionPanel, insertionPanel.isVisible { insertionPanel.makeKeyAndOrderFront(nil); return }
        let insertionTargets: [UUID?]
        if clip == nil, let track {
            insertionTargets = show.mixerControlTargets(track).filter { $0.kind == .standard }.map { Optional($0.id) }
        } else { insertionTargets = [track] }
        let insert = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        insert.title = JarasLocalization.string("Insert effect")
        insert.isFloatingPanel = true
        insert.hidesOnDeactivate = false
        insert.contentView = NSHostingView(rootView:
            FXInsertEditor(show: show, track: track, targets: insertionTargets, clip: clip, inserted: { [weak self] effect in
                guard let self, self.targetIsCurrent else { return }
                self.refresh(self.settings, preferred: effect)
                self.panel?.makeKeyAndOrderFront(nil)
            }, isActive: { [weak self, weak insert] in
                self?.targetIsCurrent == true && insert?.isVisible == true
            }, resize: { [weak insert] height in
                guard let insert, abs(insert.contentLayoutRect.height - height) > 1 else { return }
                let center = CGPoint(x: insert.frame.midX, y: insert.frame.midY)
                insert.setContentSize(NSSize(width: 460, height: height))
                insert.setFrameOrigin(CGPoint(x: center.x - insert.frame.width / 2, y: center.y - insert.frame.height / 2))
            }, dismiss: { [weak insert] in insert?.close() })
                .environment(\.locale, Locale(identifier: UserDefaults.standard.string(forKey: "jaras.language") ?? "en"))
                .environment(\.openFX, { [weak self] target, effect in
                    guard let self else { return }
                    FXWindows.shared.open(show: self.show, track: target, effect: effect, language: UserDefaults.standard.string(forKey: "jaras.language") ?? "en")
                }).preferredColorScheme(.dark).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(JarasTheme.panel))
        let owner = panel ?? window
        if let owner {
            insert.setFrameOrigin(CGPoint(x: owner.frame.midX - insert.frame.width / 2,
                                          y: owner.frame.midY - insert.frame.height / 2))
            owner.addChildWindow(insert, ordered: .above)
        } else { insert.center() }
        insertionPanel = insert
        insert.makeKeyAndOrderFront(nil)
    }
    @objc private func removeSelectedEffect() {
        guard let selection else { return }
        removeEffect(selection)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, rows.indices.contains(list.selectedRow) else { return }
        select(rows[list.selectedRow].effect)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard clip == nil, rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(rows[row].effect, forType: Self.dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard clip == nil, info.draggingSource as? NSTableView === list, info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard clip == nil, let effect = info.draggingPasteboard.string(forType: Self.dragType), rows.contains(where: { $0.effect == effect }) else { return false }
        show.reorderFX(track, effect: effect, before: rows.indices.contains(row) ? rows[row].effect : nil)
        return true
    }
}
#endif
