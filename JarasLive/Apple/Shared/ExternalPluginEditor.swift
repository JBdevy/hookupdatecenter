#if os(macOS)
import SwiftUI
import AppKit
@MainActor enum ExternalPluginState {
    static func capture(show: ShowController, track: UUID?, identifier: String) {
        guard let chain = StemAudioPlayback.shared.effects(for: track), let node = chain.externalNode(identifier), let state = JarasVST3.state(node, identifier: identifier) else { return }
        var settings = show.fxSettings(track)
        guard let index = settings.externalPlugins?.firstIndex(where: { $0.id == identifier }) else { return }
        let before = settings
        settings.externalPlugins?[index].componentState = state["componentState"] as? String
        settings.externalPlugins?[index].controllerState = state["controllerState"] as? String
        guard settings != before else { return }
        show.previewFX(track, settings: settings); show.commitFX()
    }
    static func captureAll(show: ShowController) {
        let targets: [UUID?] = [nil] + (show.current?.tracks.filter { $0.kind == .standard }.map { Optional($0.id) } ?? [])
        for target in targets { for plugin in show.fxSettings(target).externalPlugins ?? [] { capture(show: show, track: target, identifier: plugin.id) } }
    }
}
struct ExternalPluginEditor: View {
    let show: ShowController
    let track: UUID?
    let effect: String
    @State private var parameters: [[AnyHashable: Any]] = []
    @State private var values: [UInt32: Double] = [:]
    @State private var failure = ""
    private var plugin: ExternalPlugin? { show.fxSettings(track).externalPlugins?.first { $0.effectKey == effect } }
    static func nativeEditor(show: ShowController, track: UUID?, effect: String) -> NSView? {
        guard let plugin = show.fxSettings(track).externalPlugins?.first(where: { $0.effectKey == effect }),
              let chain = StemAudioPlayback.shared.effects(for: track), chain.externalError == nil, let node = chain.externalNode(plugin.id) else { return nil }
        JarasVST3.onEdit(node, identifier: plugin.id) { [weak show] in
            guard let show else { return }
            ExternalPluginState.capture(show: show, track: track, identifier: plugin.id)
        }
        return JarasVST3.editor(node, identifier: plugin.id)
    }
    var body: some View {
        VStack(spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !failure.isEmpty { Text(LocalizedStringKey(failure)).foregroundStyle(.red) }
                        ForEach(Array(parameters.enumerated()), id: \.offset) { _, parameter in
                            if let id = parameter["id"] as? UInt32, let name = parameter["name"] as? String {
                                HStack {
                                    Text(verbatim: name).frame(width: 190, alignment: .leading).lineLimit(1)
                                    Slider(value: Binding(get: { values[id] ?? 0 }, set: { value in
                                        values[id] = value
                                        guard let plugin, let chain = StemAudioPlayback.shared.effects(for: track), let node = chain.externalNode(plugin.id) else { return }
                                        JarasVST3.setParameter(node, identifier: plugin.id, parameter: id, value: value)
                                    }), in: 0...1, onEditingChanged: { editing in if !editing, let plugin { ExternalPluginState.capture(show: show, track: track, identifier: plugin.id) } })
                                }
                            }
                        }
                    }.padding(18)
                }.scrollIndicators(.hidden)
        }.background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear {
                guard let plugin else { failure = "Plugin settings are unavailable"; return }
                guard let chain = StemAudioPlayback.shared.effects(for: track) else { failure = "Audio track is not prepared"; return }
                if let error = chain.externalError { failure = error.localizedDescription; return }
                guard let node = chain.externalNode(plugin.id) else { failure = "Plugin is not loaded"; return }
                JarasVST3.onEdit(node, identifier: plugin.id) { [weak show] in
                    guard let show else { return }
                    ExternalPluginState.capture(show: show, track: track, identifier: plugin.id)
                }
                parameters = JarasVST3.parameters(node, identifier: plugin.id)
                if parameters.isEmpty { failure = "This plugin does not expose controls" }
                for parameter in parameters { if let id = parameter["id"] as? UInt32 { values[id] = parameter["value"] as? Double ?? 0 } }
            }
            .onDisappear { if let plugin { ExternalPluginState.capture(show: show, track: track, identifier: plugin.id) } }
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
    private weak var panel: NSPanel?
    private let list = FXChainTableView()
    private let scroll = NSScrollView()
    private let editorArea = NSView()
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
    init(show: ShowController, track: UUID?, effect: String, panel: NSPanel) {
        self.show = show; self.track = track; self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: preferredContentSize))
        wantsLayer = true; layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor
        let enabled = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled")); enabled.width = 30; enabled.minWidth = 30; enabled.maxWidth = 30
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.width = 148
        list.addTableColumn(enabled); list.addTableColumn(name); list.headerView = nil
        list.rowHeight = 28; list.intercellSpacing = NSSize(width: 2, height: 2)
        list.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1); list.style = .plain
        list.dataSource = self; list.delegate = self; list.allowsEmptySelection = false
        list.bypassRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row), self.rows[row].effect != "CatStemSeparation 5" else { return }
            self.show.toggleFXBypass(self.track, effect: self.rows[row].effect)
        }
        list.removeRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row), self.rows[row].effect != "CatStemSeparation 5" else { return }
            self.show.removeFX(self.track, effect: self.rows[row].effect)
        }
        list.registerForDraggedTypes([Self.dragType]); list.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = list; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        addButton.title = JarasLocalization.string("Add"); addButton.bezelStyle = .rounded; addButton.target = self; addButton.action = #selector(addEffect)
        removeButton.title = JarasLocalization.string("Remove"); removeButton.bezelStyle = .rounded; removeButton.target = self; removeButton.action = #selector(removeSelectedEffect)
        footer.addSubview(addButton); footer.addSubview(removeButton)
        addSubview(scroll); addSubview(editorArea); addSubview(footer)
        refresh(show.fxSettings(track), preferred: effect)
        observation = show.$snapshot.map { snapshot in
            track.flatMap { id in snapshot.project.songs.lazy.flatMap(\.tracks).first(where: { $0.id == id })?.fx }
                ?? (track == nil ? snapshot.project.masterFX : nil) ?? NativeFXSettings()
        }.removeDuplicates().sink { [weak self] settings in self?.refresh(settings) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: max(0, bounds.height - 40))
        footer.frame = NSRect(x: 0, y: max(0, bounds.height - 40), width: sidebarWidth, height: 40)
        addButton.frame = NSRect(x: 6, y: 6, width: 84, height: 28)
        removeButton.frame = NSRect(x: 96, y: 6, width: 88, height: 28)
        editorArea.frame = NSRect(x: sidebarWidth, y: 0, width: max(1, bounds.width - sidebarWidth), height: bounds.height)
        editor?.frame = editorArea.bounds
    }
    private func refresh(_ settings: NativeFXSettings, preferred: String? = nil) {
        var next = settings.effectKeys.map { effect in
            Row(effect: effect, name: settings.externalPlugins?.first(where: { $0.effectKey == effect })?.name
                ?? (settings.kind(of: effect) == "Instruments" ? InstrumentLibrary.displayName(settings.settings(for: effect).instrumentID) : JarasLocalization.string(settings.kind(of: effect))), enabled: settings.isEnabled(effect))
        }
        if track != nil { next.append(Row(effect: "CatStemSeparation 5", name: "CatStemSeparation 5", enabled: true)) }
        if next != rows { rows = next; refreshing = true; list.reloadData(); refreshing = false }
        let selected = preferred.flatMap { value in rows.first(where: { $0.effect == value })?.effect }
            ?? selection.flatMap { value in rows.first(where: { $0.effect == value })?.effect } ?? rows.first?.effect
        removeButton.isEnabled = selected != nil && selected != "CatStemSeparation 5"
        guard let selected else { editor?.removeFromSuperview(); editor = nil; selection = nil; return }
        select(selected)
        if let index = rows.firstIndex(where: { $0.effect == selected }) {
            refreshing = true; list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); refreshing = false
        }
    }
    func select(_ effect: String) {
        guard rows.contains(where: { $0.effect == effect }), selection != effect else { return }
        if let previous = selection, let plugin = show.fxSettings(track).externalPlugins?.first(where: { $0.effectKey == previous }) {
            ExternalPluginState.capture(show: show, track: track, identifier: plugin.id)
        }
        selection = effect; removeButton.isEnabled = effect != "CatStemSeparation 5"; editor?.removeFromSuperview()
        let content: NSView
        let size: NSSize
        if effect.hasPrefix("External:"), let native = ExternalPluginEditor.nativeEditor(show: show, track: track, effect: effect) {
            content = native; size = native.frame.size
            panel?.contentMinSize = NSSize(width: sidebarWidth + 64, height: 64)
        } else {
            let language = UserDefaults.standard.string(forKey: "jaras.language") ?? "en"
            if effect == "CatStemSeparation 5" {
                content = NSHostingView(rootView: CatStemFXEditor(show: show, track: track).preferredColorScheme(.dark))
            } else if effect.hasPrefix("External:") {
                content = NSHostingView(rootView: ExternalPluginEditor(show: show, track: track, effect: effect).environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark))
            } else {
                content = NSHostingView(rootView: FXEditor(show: show, track: track, effect: effect, close: { [weak panel] in panel?.close() }).environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark))
            }
            size = NSSize(width: 740, height: 560)
            panel?.contentMinSize = NSSize(width: sidebarWidth + 640, height: 540)
        }
        editor = content; editorArea.addSubview(content)
        preferredContentSize = NSSize(width: size.width + sidebarWidth, height: size.height)
        panel?.setContentSize(preferredContentSize); needsLayout = true
        if let index = rows.firstIndex(where: { $0.effect == effect }) {
            refreshing = true; list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); refreshing = false
        }
    }
    func suspendAudioEditor() {
        guard selection?.hasPrefix("External:") == true else { return }
        editor?.removeFromSuperview(); editor = nil
    }
    func restoreAudioEditor() {
        guard editor == nil, let selected = selection else { return }
        selection = nil; select(selected)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row]
        if tableColumn?.identifier.rawValue == "enabled" {
            if value.effect == "CatStemSeparation 5" { return NSTextField(labelWithString: "") }
            let button = NSButton(title: "By", target: self, action: #selector(toggle(_:)))
            button.isBordered = false; button.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            button.identifier = NSUserInterfaceItemIdentifier(value.effect)
            button.wantsLayer = true; button.layer?.cornerRadius = 3
            button.layer?.backgroundColor = (value.enabled ? NSColor.white.withAlphaComponent(0.12) : NSColor.systemRed.withAlphaComponent(0.75)).cgColor
            button.contentTintColor = value.enabled ? .secondaryLabelColor : .white
            button.setAccessibilityLabel("Bypass · " + value.name)
            button.toolTip = JarasLocalization.string("Bypass") + " · " + value.name
            return button
        }
        let text = NSTextField(labelWithString: value.name); text.lineBreakMode = .byTruncatingTail
        text.font = NSFont.systemFont(ofSize: 12); text.textColor = value.enabled ? .labelColor : .secondaryLabelColor
        return text
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let effect = sender.identifier?.rawValue else { return }
        show.toggleFXBypass(track, effect: effect)
    }
    @objc private func addEffect() {
        if let insertionPanel, insertionPanel.isVisible { insertionPanel.makeKeyAndOrderFront(nil); return }
        let insert = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        insert.title = JarasLocalization.string("Insert effect")
        insert.isFloatingPanel = true
        insert.hidesOnDeactivate = false
        insert.contentView = NSHostingView(rootView:
            FXInsertEditor(show: show, track: track, targets: [track], resize: { [weak insert] height in
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
        guard let selection, selection != "CatStemSeparation 5" else { return }
        show.removeFX(track, effect: selection)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, rows.indices.contains(list.selectedRow) else { return }
        select(rows[list.selectedRow].effect)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), rows[row].effect != "CatStemSeparation 5" else { return nil }
        let item = NSPasteboardItem(); item.setString(rows[row].effect, forType: Self.dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === list, info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let effect = info.draggingPasteboard.string(forType: Self.dragType), effect != "CatStemSeparation 5", rows.contains(where: { $0.effect == effect }) else { return false }
        show.reorderFX(track, effect: effect, before: rows.indices.contains(row) && rows[row].effect != "CatStemSeparation 5" ? rows[row].effect : nil)
        return true
    }
}
#endif
