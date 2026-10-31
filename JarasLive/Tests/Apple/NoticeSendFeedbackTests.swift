extension TPNoticeController {
    func testAttachHiddenNoticeWindow(_ window: NSWindow) {
        precondition(panel == nil)
        panel = window
        window.delegate = self
    }
    var testHasNoticeWindow: Bool { panel != nil }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let feedback = NoticeSendFeedback(successDuration: 40_000_000, failureDuration: 60_000_000)
    let first = feedback.begin(), second = feedback.begin()
    feedback.complete(first, result: .accepted)
    precondition(feedback.phase == .sending, "an earlier tap cannot confirm a later send")
    feedback.complete(second, result: .accepted)
    precondition(feedback.phase.accepted && feedback.phase.message == "Message sent.")
    RunLoop.main.run(until: Date().addingTimeInterval(0.07))
    precondition(feedback.phase == .idle, "confirmation dismisses without blocking input")
    let third = feedback.begin(); feedback.complete(third, result: .accepted)
    let fourth = feedback.begin()
    RunLoop.main.run(until: Date().addingTimeInterval(0.07))
    precondition(feedback.phase == .sending, "a previous dismissal cannot hide a newer pending send")
    feedback.complete(fourth, result: .unconfirmed)
    precondition(feedback.phase.failed && !feedback.phase.accepted)
    feedback.complete(fourth, result: .accepted)
    precondition(feedback.phase == .finished(.unconfirmed), "duplicate completion cannot rewrite delivery status")
    feedback.reset()
    let removed = feedback.begin(); feedback.reset(); feedback.complete(removed, result: .accepted)
    precondition(feedback.phase == .idle, "a dismissed sender ignores old receipt callbacks")

    let suite = "catlive-notice-feedback-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = TPNoticeController(defaults: defaults)
    model.draft = "  "
    precondition(!model.send() && !model.active, "desktop does not confirm an empty notice")
    model.draft = "Ready"
    precondition(model.send() && model.active && model.message == "Ready", "desktop confirms only accepted controller send")
    let firstDate = model.sentAt
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    precondition(model.send() && model.sentAt > firstDate, "sending identical text again refreshes the notice and may confirm again")
    model.clear(); model.select(0); model.draft = ""
    model.images[0] = Data([1, 2, 3])
    precondition(!model.send(), "invalid image-only notice is rejected")
    let image = NSImage(size: CGSize(width: 1, height: 1))
    image.lockFocus(); NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1, height: 1).fill(); image.unlockFocus()
    model.images[0] = image.tiffRepresentation
    precondition(model.send() && model.active && model.image != nil, "valid image-only preset receives success too")
    model.clear()
    let project = UUID(), nextProject = UUID(), song = UUID()
    var presentation = RemoteNoticePresentation(project: project)
    let withdrawal = presentation.dismiss(project: project, song: song)
    precondition(withdrawal?.action == .noticeClear && withdrawal?.project == project && withdrawal?.song == song,
                 "closing withdraws even when the last state has not yet acknowledged an active message")
    precondition(presentation.dismiss(project: project, song: song) == nil,
                 "explicit close followed by onDisappear sends exactly one withdrawal")
    presentation = RemoteNoticePresentation(project: project)
    presentation.observe(project: nextProject)
    precondition(presentation.dismiss(project: nextProject, song: song) == nil,
                 "an old editor must not clear a message in the newly opened project")
    presentation = RemoteNoticePresentation(project: project)
    precondition(presentation.dismiss(project: nil, song: nil) == nil)
    presentation.observe(project: project)
    precondition(presentation.dismiss(project: project, song: song) == nil,
                 "closing offline never queues a withdrawal for a later connection")
    presentation = RemoteNoticePresentation()
    presentation.observe(project: project)
    precondition(presentation.dismiss(project: project, song: song) != nil,
                 "a panel opened before its first state captures that state once")
    presentation = RemoteNoticePresentation(project: project)
    precondition(presentation.dismiss(project: project, song: song) != nil, "reopening permits a new withdrawal")

    presentation = RemoteNoticePresentation(project: project)
    precondition(presentation.dismiss(project: project, song: song, preserveStoppedNotice: true) == nil,
                 "closing Remote preserves the captured automatic Stop notice")
    precondition(presentation.dismissed && presentation.dismiss(project: project, song: song) == nil,
                 "onDisappear cannot withdraw an automatic notice after explicit close")

    model.select(-1); model.draft = "Keep the draft"; model.templates[0] = "Keep the preset"
    precondition(model.send()); model.togglePin()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    model.testAttachHiddenNoticeWindow(window)
    // A different utility window closing does not withdraw this panel's notice.
    let unrelated = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    unrelated.isReleasedWhenClosed = false
    model.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: unrelated))
    precondition(model.active && model.pinned && model.testHasNoticeWindow)
    window.close()
    precondition(!model.active && !model.pinned && model.deadline == nil && !model.flashing && !model.testHasNoticeWindow,
                 "the real NSWindow close notification withdraws pinned notices and cancels their timers")
    precondition(model.draft == "Keep the draft" && model.templates[0] == "Keep the preset",
                 "closing preserves drafts and saved messages")
    unrelated.close()
    print("NOTICE_CLOSE_PROJECT_GUARD_OFFLINE_NO_REPLAY_IDEMPOTENCE_AND_NATIVE_WINDOW_CLOSE_OK")
    print("NOTICE_SENDER_FEEDBACK_REPEATED_ACK_TIMEOUT_DISMISSAL_AND_DESKTOP_ACCEPTANCE_OK")
}
