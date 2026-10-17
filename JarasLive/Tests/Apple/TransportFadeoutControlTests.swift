@MainActor func verifyFadeoutControls() {
    let show = ShowController(), project = UUID(), song = UUID(), selected = UUID(), other = UUID()
    let fader = DirectVolumeSliderView(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
    let untouched = DirectVolumeSliderView(frame: .zero)
    let label = FooterMixerGainLabel(frame: .zero)
    fader.rebind(project: project, track: selected); fader.synchronizeModel(20 * log10(0.7)); fader.bindAutomation(show)
    untouched.rebind(project: project, track: other); untouched.synchronizeModel(20 * log10(1.4)); untouched.bindAutomation(show)
    label.bind(identity: TrackControlIdentity(project: project, track: selected), gain: 0.7, show: show)
    var writes = 0
    fader.changed = { _ in writes += 1 }; fader.editingChanged = { _, _ in writes += 1 }
    show.transportFadeout.configure(enabled: true, duration: 5, tracks: [selected])
    precondition(show.transportFadeout.start(project: project, song: song, volumes: [selected: 0.7], at: 100))
    show.transportFadeout.advance(to: 102.5)
    precondition(abs(fader.doubleValue - 20 * log10(0.35)) < 0.00001, "Selected native fader did not follow temporary gain")
    precondition(abs(untouched.doubleValue - 20 * log10(1.4)) < 0.00001, "Unselected fader moved")
    precondition(label.stringValue == "-9.1 dB", "Footer value does not follow the fader")
    // A retained row rebind must not flash its unfaded saved value.
    fader.synchronizeModel(20 * log10(0.7)); fader.bindAutomation(show)
    precondition(abs(fader.doubleValue - 20 * log10(0.35)) < 0.00001)
    show.transportFadeout.advance(to: 105)
    precondition(fader.doubleValue == -60 && label.stringValue == "−∞ dB")
    show.transportFadeout.cancel()
    precondition(abs(fader.doubleValue - 20 * log10(0.7)) < 0.00001 && label.stringValue == "-3.1 dB", "Cancel did not restore native fader/readout")
    precondition(writes == 0, "Presentation wrote a volume edit or automation point")
    fader.bindAutomation(nil)
    print("TRANSPORT_FADEOUT_NATIVE_FADER_READOUT_TRANSIENT_NO_MODEL_WRITES_OK")
}
MainActor.assumeIsolated { verifyFadeoutControls() }
