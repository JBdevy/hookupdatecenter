#if os(macOS)
import AppKit
import Combine

/// Shared host toolbar, including plugins that provide their own Cocoa editor.
@MainActor final class FXPresetBar: NSView {
    private let selector = NSPopUpButton()
    private let save = NSButton(title: "Salvar preset…", target: nil, action: nil)
    private let useDefault = NSButton(title: "Usar como padrão", target: nil, action: nil)
    private let readSettings: () -> NativeFXSettings
    private let capture: (String) throws -> NativeFXSettings
    private let apply: (NativeFXSettings) -> Void
    private let report: (String) -> Void
    private var observation: AnyCancellable?
    private var effect: String?
    private var library = FXPresetLibrary()
    private var currentID: String?
    private var factoryState: FXPreset?
    private var pluginID = ""
    init(read: @escaping () -> NativeFXSettings, capture: @escaping (String) throws -> NativeFXSettings,
         apply: @escaping (NativeFXSettings) -> Void, report: @escaping (String) -> Void) {
        readSettings = read; self.capture = capture; self.apply = apply; self.report = report
        super.init(frame: .zero)
        for view in [selector, save, useDefault] { addSubview(view); view.font = .jarasSystemFont(ofSize: 11); view.controlSize = .small }
        selector.target = self; selector.action = #selector(loadPreset)
        selector.setAccessibilityLabel("Preset")
        save.target = self; save.action = #selector(savePreset)
        useDefault.target = self; useDefault.action = #selector(makeDefault)
        save.bezelStyle = .rounded; useDefault.bezelStyle = .rounded
        do { library = try FXPresetStore.shared.read() } catch { report(error.localizedDescription) }
        observation = NotificationCenter.default.publisher(for: FXPresetStore.didChange)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, notification.object as? URL == FXPresetStore.shared.url else { return }
                do { self.library = try FXPresetStore.shared.read(); self.refresh(effect: self.effect, settings: self.readSettings()) }
                catch { self.report(error.localizedDescription) }
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        selector.frame = NSRect(x: 10, y: 7, width: max(100, bounds.width - 278), height: 22)
        save.frame = NSRect(x: max(120, bounds.width - 258), y: 7, width: 112, height: 22)
        useDefault.frame = NSRect(x: max(232, bounds.width - 146), y: 7, width: 136, height: 22)
    }
    func refresh(effect: String?, settings: NativeFXSettings) {
        self.effect = effect
        guard let effect, settings.inserted.contains(effect) else { isHidden = true; return }
        isHidden = false
        let identity = FXPreset.identity(settings, effect: effect)
        if identity != pluginID { factoryState = nil; pluginID = identity }
        let entries = library.entries(for: identity)
        currentID = entries.first(where: { $0.matches(settings, effect: effect) })?.id
        selector.removeAllItems()
        selector.addItem(withTitle: "Default" + (library.defaults[identity] == nil ? " ★" : ""))
        selector.lastItem?.representedObject = ""
        for preset in entries {
            selector.addItem(withTitle: preset.name + (library.defaults[identity] == preset.id ? " ★" : ""))
            selector.lastItem?.representedObject = preset.id
        }
        if let currentID, let index = entries.firstIndex(where: { $0.id == currentID }) { selector.selectItem(at: index + 1) }
        else {
            let factory = factoryState ?? nativeFactory(settings, effect: effect)
            if factory?.matches(settings, effect: effect) == true { currentID = ""; selector.selectItem(at: 0) }
            else { selector.addItem(withTitle: "Personalizado"); selector.lastItem?.isEnabled = false; selector.selectItem(at: selector.numberOfItems - 1) }
        }
        useDefault.isEnabled = currentID != nil
        useDefault.title = currentID == (library.defaults[identity] ?? "") ? "Padrão selecionado" : "Usar como padrão"
        useDefault.setAccessibilityHelp("Aplicar este preset às novas inserções deste plugin em qualquer pista.")
    }
    private func nativeFactory(_ settings: NativeFXSettings, effect: String) -> FXPreset? {
        guard !effect.hasPrefix("External:") else { return nil }
        let kind = settings.kind(of: effect)
        var factory = NativeFXSettings()
        factory.appendNative(kind, instrument: settings.settings(for: effect).instrumentID,
                             parameters: kind == "Instruments" ? InstrumentLibrary.parameters(settings.settings(for: effect).instrumentID) : nil)
        return try? FXPreset(name: "Factory", settings: factory, effect: kind)
    }
    @objc private func loadPreset() {
        guard let effect, let id = selector.selectedItem?.representedObject as? String else { return }
        do {
            let settings = readSettings()
            let preset: FXPreset
            if id.isEmpty {
                if let native = nativeFactory(settings, effect: effect) { preset = native }
                else {
                    guard let plugin = settings.externalPlugins?.first(where: { $0.effectKey == effect }) else { return }
                    var fresh = ExternalPlugin(classID: plugin.classID, name: plugin.name, path: plugin.path, category: plugin.category)
                    let preparation = NativeEffectsChain(); defer { preparation.releaseExternal() }
                    let node = try preparation.prepareExternal(fresh)
                    guard let state = JarasVST3.state(node, identifier: fresh.id) else { throw ProjectError.invalid("Could not read the default plugin state") }
                    fresh.componentState = state["componentState"] as? String; fresh.controllerState = state["controllerState"] as? String
                    var value = NativeFXSettings(); value.externalPlugins = [fresh]; value.inserted = [fresh.effectKey]
                    preset = try FXPreset(name: "Factory", settings: value, effect: fresh.effectKey)
                }
                factoryState = preset
            } else {
                guard let saved = library.presets.first(where: { $0.id == id }) else { return }
                preset = saved
            }
            apply(try preset.applying(to: settings, effect: effect))
            refresh(effect: effect, settings: readSettings())
        } catch { report(error.localizedDescription); refresh(effect: effect, settings: readSettings()) }
    }
    @objc private func savePreset() {
        guard let effect, let window else { return }
        let alert = NSAlert(); alert.messageText = "Salvar preset"; alert.informativeText = "Nome da configuração deste plugin"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field; alert.addButton(withTitle: "Salvar"); alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.effect == effect else { return }
            do {
                let preset = try FXPreset(name: field.stringValue, settings: self.capture(effect), effect: effect)
                var library = try FXPresetStore.shared.read()
                try library.save(preset); try FXPresetStore.shared.write(library)
                self.library = library
                self.refresh(effect: effect, settings: try self.capture(effect))
            } catch { self.report(error.localizedDescription) }
        }
        alert.window.initialFirstResponder = field
    }
    @objc private func makeDefault() {
        guard let currentID else { return }
        do {
            var library = try FXPresetStore.shared.read()
            try library.setDefault(currentID.isEmpty ? nil : currentID, plugin: pluginID)
            try FXPresetStore.shared.write(library); self.library = library
            refresh(effect: effect, settings: readSettings())
        } catch { report(error.localizedDescription) }
    }
}
#endif
