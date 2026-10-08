
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let suite = "catlive-notice-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = TPNoticeController(defaults: defaults)
    model.draft = "Live message"; model.send()
    precondition(model.active && model.message == "Live message" && model.remaining() > 19 && model.flashing)
    model.togglePin()
    let remaining = model.remaining()
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    precondition(model.pinned && model.remaining() == remaining && !model.flashing, "pin pauses expiry and initial flashing settles")
    model.togglePin()
    precondition(!model.pinned && model.deadline != nil, "unpin resumes the remaining duration")
    model.select(0); model.draft = "Saved message"; model.templates[0] = model.draft
    model.select(-1); precondition(model.draft == "Live message", "global draft survives preset selection")
    model.appearance.window2 = false
    let loaded = TPNoticeController(defaults: defaults)
    precondition(loaded.templates[0] == "Saved message" && !loaded.appearance.window2, "templates and appearance persist")
    model.clear(); precondition(!model.active && !model.pinned && model.deadline == nil)
    model.draft = "  "; model.send(); precondition(!model.active, "empty messages are not displayed")
    model.select(0)
    defaults.set(try! JSONEncoder().encode(TPNoticeAppearance(window1: false, window2: true, font: "Trebuchet MS", scale: 65)), forKey: "jaras.notices.appearance")
    defaults.set(["Imported 1", "Imported 2", "Imported 3"], forKey: "jaras.notices.templates")
    model.reload()
    precondition(!model.appearance.window1 && model.appearance.font == "Trebuchet MS" && model.appearance.scale == 65)
    precondition(model.templates == ["Imported 1", "Imported 2", "Imported 3"] && model.draft == "Imported 1")
    let reloaded = TPNoticeController(defaults: defaults)
    precondition(reloaded.templates == model.templates && reloaded.appearance.font == model.appearance.font && !reloaded.active)
    func pixels(index: Int) -> Data {
        let view = NSHostingView(rootView: Color.green.overlay(TPNoticeOverlay(model: model, index: index)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04)); view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let result = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        window.orderOut(nil); window.contentView = nil; window.close()
        return result
    }
    model.select(-1); model.appearance = TPNoticeAppearance()
    model.draft = "Teste do recado"; model.send(); model.togglePin()
    RunLoop.main.run(until: Date().addingTimeInterval(1.1))
    let base = model.appearance
    for index in 1...2 {
        let original = pixels(index: index)
        for change: (inout TPNoticeAppearance) -> Void in [
            { $0.font = "Georgia" }, { $0.scale = 50 }, { $0.text = 0xff0000 }, { $0.background = 0x0000ff },
            { $0.emojiEnabled = true }, { $0.emojiEnabled = true; $0.emoji = "🎹" }, { $0.cleanDisplay = false },
            { if index == 1 { $0.window1 = false } else { $0.window2 = false } }
        ] {
            model.appearance = base; change(&model.appearance)
            precondition(pixels(index: index) != original, "every global message appearance control affects TP-\(index)")
        }
        model.appearance = base
    }
    model.send()
    let flash = pixels(index: 1); model.appearance.flash = 0xff0000
    precondition(pixels(index: 1) != flash, "flash color controls the real message flash")
    model.clear()
    print("PASS: rendered global message font, scale, colors, flash, emoji, clean display and independent destinations")
    print("TP_NOTICES_SEND_PIN_RESUME_REMOVE_PRESETS_AND_SETTINGS_OK")
}
