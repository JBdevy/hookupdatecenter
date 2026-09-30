
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let model = TPNoticeController()
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
    let loaded = TPNoticeController()
    precondition(loaded.templates[0] == "Saved message" && !loaded.appearance.window2, "templates and appearance persist")
    model.clear(); precondition(!model.active && !model.pinned && model.deadline == nil)
    model.draft = "  "; model.send(); precondition(!model.active, "empty messages are not displayed")
    for key in ["jaras.notices.appearance", "jaras.notices.templates"] { UserDefaults.standard.removeObject(forKey: key) }
    print("TP_NOTICES_SEND_PIN_RESUME_REMOVE_PRESETS_AND_SETTINGS_OK")
}
