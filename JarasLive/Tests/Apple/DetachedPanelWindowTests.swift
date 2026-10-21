@main struct Test { @MainActor static func main() {
let app = NSApplication.shared
let show = ShowController()
let mixer = DetachedMixerWindow(), parts = DetachedPartsWindow()
func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
for name in ["Mixer", "Parts"] {
    @MainActor func open() { if name == "Mixer" { mixer.open(show: show, openFX: {_,_ in}, editTrack: {_ in}) } else { parts.open(show: show) } }
    @MainActor func close() { if name == "Mixer" { mixer.close() } else { parts.close() } }
    @MainActor func hide() { if name == "Mixer" { mixer.hide() } else { parts.hide() } }
    func current() -> NSWindow { app.windows.first { $0.isVisible && $0.title == (name == "Mixer" ? "CatLive · Hoz-Mixer" : "CatLive · Parts") }! }
    open(); pump()
    let frame = NSRect(x: 80, y: 90, width: 620, height: 410)
    current().setFrame(frame, display: true); pump(); hide(); open(); pump()
    precondition(current().frame == frame, "Hidden window must retain frame")
    close(); open(); pump()
    precondition(current().frame == frame, "Recreated window must restore frame and dimensions")
    if name == "Mixer" { mixer.close(preserveState: true) } else { parts.close(preserveState: true) }
    precondition(UserDefaults.standard.bool(forKey: "jaras.testlayout." + name.lowercased() + ".detached"), "Project teardown must not overwrite the global detached preference")
    for suffix in [".detached", ".visible"] { UserDefaults.standard.removeObject(forKey: "jaras.testlayout." + name.lowercased() + suffix) }
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame CatLiveTestDetached" + name)
}
print("DETACHED_MIXER_PARTS_HIDE_RECREATE_GEOMETRY_OK")

}}
