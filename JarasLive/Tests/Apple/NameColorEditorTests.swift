extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
}
func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, $0) }
}
@MainActor func runEditorTests() {
    for weight in ["Regular", "Bold", "Medium", "SemiBold"] {
        let url = URL(fileURLWithPath: "Resources/Fonts/Inter/Inter-\(weight).ttf")
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    let previousApp = NSWorkspace.shared.frontmostApplication
    _ = NSApplication.shared
    let activeCapture = ProcessInfo.processInfo.environment["CATLIVE_EDITOR_ACTIVE"] == "1"
    if activeCapture { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    defer { if activeCapture { previousApp?.activate(options: []) } }
    NSApp.appearance = NSAppearance(named: .darkAqua)
    func button(_ view: NSView, _ name: String) -> NSButton {
        descendants(NSButton.self, view).first { $0.accessibilityIdentifier() == "name-color-" + name }!
    }
    func name(_ view: NSView) -> NSTextField { descendants(NSTextField.self, view).first { $0.isEditable }! }
    func edit(_ field: NSTextField, _ value: String) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func swatch(_ view: NSView, _ value: String) -> NSButton {
        descendants(NSButton.self, view).first { $0.accessibilityLabel() == value }!
    }
    var saved: [(String, UInt32)] = [], previews: [UInt32] = [], closes = 0, symbol = false, uppercase = true
    var config = NameColorEditor(title: "Edit song", initialName: "Original", initialColor: 0x704250,
        save: { saved.append(($0, $1)) }, symbol: Binding(get: { symbol }, set: { symbol = $0 }),
        uppercaseName: Binding(get: { uppercase }, set: { uppercase = $0 }), maximumNameLength: 8,
        previewColor: { previews.append($0) })
    let form = NativeNameColorEditorView(editor: config, locale: "en", finish: { closes += 1 })
    form.layoutSubtreeIfNeeded()
    precondition(form.intrinsicContentSize == NSSize(width: 300, height: 433))
    precondition(descendants(NSSlider.self, form).count == 3)
    precondition(descendants(NSButton.self, form).filter { $0.accessibilityLabel()?.hasPrefix("#") == true }.count == 24)
    edit(name(form), "  Música longa  ")
    precondition(name(form).stringValue == "  Música", "The length cap respects composed characters")
    edit(name(form), "  Solo ")
    swatch(form, "#287BFF").performClick(nil)
    precondition(previews == [0x287bff], "A preset previews immediately")
    button(form, "symbol").performClick(nil); button(form, "uppercase").performClick(nil)
    precondition(symbol && !uppercase, "Both optional toggles edit their bindings")
    config = NameColorEditor(title: "Edit song", initialName: "Parent update", initialColor: 0x287bff,
        save: { saved.append(($0, $1)) }, symbol: Binding(get: { symbol }, set: { symbol = $0 }),
        uppercaseName: Binding(get: { uppercase }, set: { uppercase = $0 }), maximumNameLength: 8,
        previewColor: { previews.append($0) })
    form.update(editor: config, locale: "en", finish: { closes += 1 })
    precondition(name(form).stringValue == "  Solo ", "Parent updates preserve the active draft")
    let red = descendants(NSSlider.self, form).first { $0.tag == 0 }!
    red.doubleValue = 19.6; _ = red.sendAction(red.action, to: red.target)
    precondition(previews.last == 0x147bff, "RGB channels round once and preview during the drag")
    button(form, "save").performClick(nil); form.restorePreviewIfNeeded()
    precondition(saved.count == 1 && saved[0].0 == "Solo" && saved[0].1 == 0x147bff && closes == 1)
    precondition(previews.last == 0x147bff, "Saving does not restore the preview")

    let cancelForm = NativeNameColorEditorView(editor: config, locale: "en", finish: { closes += 1 })
    swatch(cancelForm, "#F44336").performClick(nil)
    var changedParent = config; changedParent = NameColorEditor(title: "Edit song", initialName: "Other", initialColor: 0xf44336,
        save: { saved.append(($0, $1)) }, previewColor: { previews.append($0) })
    cancelForm.update(editor: changedParent, locale: "en", finish: { closes += 1 })
    button(cancelForm, "cancel").performClick(nil); cancelForm.restorePreviewIfNeeded()
    precondition(previews.suffix(2) == [0xf44336, 0x287bff] && closes == 2 && saved.count == 1,
        "Cancel restores the color captured at presentation, once, despite parent preview updates")
    let dismissed = NativeNameColorEditorView(editor: config, locale: "en", finish: { closes += 1 })
    swatch(dismissed, "#000000").performClick(nil)
    NativeNameColorEditor.dismantleNSView(dismissed, coordinator: ())
    precondition(previews.suffix(2) == [0, 0x287bff] && closes == 2, "Outside dismissal rolls back without requesting another close")

    let empty = NativeNameColorEditorView(editor: NameColorEditor(title: "Marker", initialName: "", initialColor: 1, save: { saved.append(($0, $1)) }), locale: "en", finish: { closes += 1 })
    precondition(!button(empty, "save").isEnabled)
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    precondition(empty.performKeyEquivalent(with: enter) && saved.count == 1, "Return never commits an empty name")
    let colorOnly = NativeNameColorEditorView(editor: NameColorEditor(title: "Track colors", initialName: "", initialColor: 4, save: { saved.append(($0, $1)) }, nameEditable: false, showsName: false), locale: "en", finish: { closes += 1 })
    precondition(colorOnly.intrinsicContentSize.height == 331 && name(colorOnly).isHidden && !name(colorOnly).isEnabled)
    button(colorOnly, "save").performClick(nil)
    precondition(saved.count == 2 && saved.last!.0 == "", "Color-only editing accepts a hidden empty name")
    print("NAME_COLOR_DRAFT_RGB_PRESETS_BINDINGS_SAVE_CANCEL_AND_DISMISS_OK")

    var timings: [Double] = []
    for iteration in 0..<(activeCapture ? 1 : 7) {
        let start = ProcessInfo.processInfo.systemUptime
        let host = NSHostingView(rootView: NameColorEditor(title: "Edit song", initialName: "ABERTURA 2026", initialColor: 0x704250, save: { _, _ in }, uppercaseName: .constant(true)).background(Color(white: 0.115)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: 200), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); if activeCapture { window.setFrameOrigin(NSPoint(x: 400, y: 200)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }; host.layoutSubtreeIfNeeded()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        if iteration > 0 { timings.append(elapsed) }
        print("NAME_COLOR_OPEN iteration=\(iteration) elapsed_ms=\(elapsed) size=\(size)")
        for _ in 0..<3 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)); host.layoutSubtreeIfNeeded() }
        if activeCapture { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7)); print("ACTIVE", NSApp.isActive, window.isKeyWindow, window.defaultButtonCell as Any) }
        let field = name(host)
        precondition(window.firstResponder === field.currentEditor(), "The name receives focus on presentation")
        precondition((field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: field.stringValue.utf16.count), "The original name is selected for immediate replacement")
        if iteration == 0, let path = ProcessInfo.processInfo.environment["CATLIVE_EDITOR_SCREENSHOT"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try! process.run(); process.waitUntilExit()
        }
        window.close()
    }
    print("NAME_COLOR_FOCUS_SELECT_ALL_AND_HOST_LAYOUT_OK mean_ms=\(timings.reduce(0, +) / Double(timings.count))")
}
MainActor.assumeIsolated { runEditorTests() }
