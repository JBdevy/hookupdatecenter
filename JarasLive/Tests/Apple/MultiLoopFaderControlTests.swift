@MainActor func verifyMultiLoopFaders() {
    let show = ShowController(), project = UUID(), track = UUID(), other = UUID()
    let horizontal = DirectVolumeSliderView(frame: NSRect(x: 0, y: 0, width: 180, height: 27))
    let vertical = DirectVolumeSliderView(frame: .zero)
    let master = DirectVolumeSliderView(frame: .zero)
    let untouched = DirectVolumeSliderView(frame: .zero)
    let label = FooterMixerGainLabel(frame: .zero)
    var writes = 0, updates = 0
    for (view, id, manual) in [(horizontal, Optional(track), 0.7), (vertical, Optional(track), 0.7), (master, nil, 1.0), (untouched, Optional(other), 1.4)] {
        view.rebind(project: project, track: id); view.synchronizeModel(20 * log10(manual)); view.bindAutomation(show)
        view.changed = { _ in writes += 1 }; view.editingChanged = { _, _ in writes += 1 }
    }
    vertical.vertical = true
    label.bind(identity: TrackControlIdentity(project: project, track: track), gain: 0.7, show: show)
    let subscription = show.multiLoopFaders.$frame.sink { _ in updates += 1 }
    func frame(_ amount: Double) { show.multiLoopFaders.update(project: project, amount: amount, targets: [track: 0.1, nil: 0.25]) }
    frame(0.5)
    precondition(abs(horizontal.doubleValue - 20 * log10(0.4)) < 0.00001)
    precondition(vertical.doubleValue == horizontal.doubleValue && label.stringValue == "-8.0 dB", "Both mixers and readout must follow the incoming frame, not the previous one")
    precondition(abs(master.doubleValue - 20 * log10(0.625)) < 0.00001)
    precondition(abs(untouched.doubleValue - 20 * log10(1.4)) < 0.00001)
    let count = updates; frame(0.5)
    precondition(count == updates, "A steady envelope must not invalidate the UI repeatedly")
    horizontal.synchronizeModel(20 * log10(0.7)); horizontal.bindAutomation(show)
    precondition(abs(horizontal.doubleValue - 20 * log10(0.4)) < 0.00001, "A retained row must keep its audible gain")
    frame(1); precondition(abs(horizontal.doubleValue + 20) < 0.00001)
    frame(0.25); precondition(abs(horizontal.doubleValue - 20 * log10(0.55)) < 0.00001, "Release returns toward the manual gain")
    show.transportFadeout.configure(enabled: true, duration: 2, tracks: [track])
    precondition(show.transportFadeout.start(project: project, song: UUID(), volumes: [track: 0.7], at: 0))
    show.transportFadeout.advance(to: 1)
    precondition(abs(horizontal.doubleValue - 20 * log10(0.275)) < 0.00001, "Transport fade multiplies the loop envelope once")
    show.transportFadeout.cancel()
    show.automation[track] = (20 * log10(0.5) + 96) / 108
    horizontal.bindAutomation(show)
    frame(0.5)
    precondition(abs(horizontal.doubleValue - 20 * log10(0.3)) < 0.00001, "Loop gain follows volume automation")
    show.automation.removeAll(); horizontal.bindAutomation(show)
    show.multiLoopFaders.reset()
    precondition(abs(horizontal.doubleValue - 20 * log10(0.7)) < 0.00001 && label.stringValue == "-3.1 dB", "Stop/bypass restores the unchanged manual gain")
    frame(1)
    horizontal.rebind(project: UUID(), track: track); horizontal.synchronizeModel(-3); horizontal.bindAutomation(show)
    precondition(abs(horizontal.doubleValue + 3) < 0.00001, "An envelope cannot leak into a recycled row from another project")
    precondition(writes == 0, "Visual feedback must never write mixer commands or automation points")
    withExtendedLifetime(subscription) {}
    print("MULTILOOP_NATIVE_FADER_READOUT_MASTER_AUTOMATION_RELEASE_AND_REUSE_OK")
}
MainActor.assumeIsolated { verifyMultiLoopFaders() }
