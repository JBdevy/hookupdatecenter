
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
    print("TP_NOTICES_SEND_PIN_RESUME_REMOVE_PRESETS_AND_SETTINGS_OK")
}
