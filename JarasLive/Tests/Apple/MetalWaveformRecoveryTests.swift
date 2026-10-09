import AppKit
import Metal
import QuartzCore

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let size = CGSize(width: 128, height: 128)
let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 128, height: 128),
    styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let surface = MetalWaveformSurface()
surface.frame = NSRect(origin: .zero, size: size)
window.contentView = surface
window.orderBack(nil)

func settle(_ seconds: Double = 0.15) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
func check(_ value: Bool, _ message: String = "Recovery assertion failed") {
    guard value else { fputs(message + "\n", stderr); exit(1) }
}
func awaitValue(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), message)
}
awaitValue("Metal pipeline must become available") { MetalWaveformRenderer.isSupported }
let item = MetalTimelineItem(rect: CGRect(x: 10, y: 10, width: 108, height: 108),
    topColor: SIMD4(1, 0, 0, 1), bottomColor: SIMD4(1, 0, 0, 1), borderColor: .zero, headerHeight: 17)
let block = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2<Float>(0, 0), SIMD2<Float>(1, 0)]],
    start: 0, end: 1, step: 1, rate: 1, key: "drawable-recovery")
let stroke = MetalWaveformStroke(block: block, channel: 0, scale: SIMD2(100, 1), translation: SIMD2(14, 64),
    clip: CGRect(origin: .zero, size: size), color: SIMD4(repeating: 1), itemRect: CGRect(origin: .zero, size: size))
let firstItem = MetalTimelineItem(rect: CGRect(x: 10, y: 10, width: 108, height: 40),
    topColor: SIMD4(1, 0, 0, 1), bottomColor: SIMD4(1, 0, 0, 1), borderColor: .zero, headerHeight: 17)
let newItem = MetalTimelineItem(rect: CGRect(x: 10, y: 70, width: 108, height: 40),
    topColor: SIMD4(0, 1, 0, 1), bottomColor: SIMD4(0, 1, 0, 1), borderColor: .zero, headerHeight: 17)
let cases: [(String, MetalWaveformFrame, MetalWaveformFrame?)] = [
    ("fill", MetalWaveformFrame(size: size, strokes: [], items: [item]), nil),
    ("waveform", MetalWaveformFrame(size: size, strokes: [stroke]), nil),
    ("expanded-fill", MetalWaveformFrame(size: size, strokes: [], items: [firstItem, newItem]),
        MetalWaveformFrame(size: size, strokes: [], items: [firstItem]))
]
for (name, scene, previous) in cases {
    surface.submit(MetalWaveformFrame(size: size, strokes: []))
    settle()
    check(surface.subviews.first?.alphaValue == 0)
    if let previous {
        surface.submit(previous)
        awaitValue("initial partial scene must present") { surface.presentedForRecoveryTest?.hasSameContent(as: previous) == true }
        settle()
    }
    let before = surface.submittedFrameCount
    let firstAttempt = MetalDrawableRecoveryProbe.attempts
    MetalDrawableRecoveryProbe.blocked = true
    surface.submit(scene)
    awaitValue("initial acquisition and bounded retry must both run") { MetalDrawableRecoveryProbe.attempts >= firstAttempt + 2 }
    settle()
    check(surface.pendingForRecoveryTest && surface.submittedFrameCount == before)
    check(surface.subviews.first?.alphaValue == (previous == nil ? 0 : 1), "failed acquisition must preserve the prior surface visibility")
    if let previous {
        check(surface.presentedForRecoveryTest?.hasSameContent(as: previous) == true,
            "a failed update can leave only the earlier subset of items visible")
    }
    let exhaustedAttempts = MetalDrawableRecoveryProbe.attempts
    settle()
    check(MetalDrawableRecoveryProbe.attempts == exhaustedAttempts, "a failed acquisition must not start an idle retry loop")

    MetalDrawableRecoveryProbe.blocked = false
    surface.submit(scene)
    settle()
    check(surface.submittedFrameCount == before + 1 && !surface.pendingForRecoveryTest,
        "an identical unpresented \(name) scene must retry after the drawable becomes available")
    check(surface.subviews.first?.alphaValue == 1, "successful retry restores the visible surface")
    check(surface.presentedForRecoveryTest?.hasSameContent(as: scene) == true, "all items must be present after recovery")
    let recoveredAttempts = MetalDrawableRecoveryProbe.attempts
    for _ in 0..<100 { surface.submit(scene) }
    settle()
    check(surface.submittedFrameCount == before + 1 && MetalDrawableRecoveryProbe.attempts == recoveredAttempts,
        "identical already-presented scenes must stay idle")
    print("METAL_\(name.uppercased())_PENDING_RETRY_RECOVERY_AND_PRESENTED_IDLE_OK")
}
// NativeTimelineAudioBodyView retains identical projections and may never call
// submit again. Visibility must recover the pending scene on its own.
for restoreWindow in [true, false] {
    surface.submit(MetalWaveformFrame(size: size, strokes: []))
    settle()
    if restoreWindow { window.orderOut(nil) } else { surface.isHidden = true }
    settle()
    MetalDrawableRecoveryProbe.blocked = true
    let firstAttempt = MetalDrawableRecoveryProbe.attempts
    let before = surface.submittedFrameCount
    let scene = MetalWaveformFrame(size: size, strokes: [], items: [item])
    surface.submit(scene)
    awaitValue("hidden scene must exhaust its bounded drawable retry") { MetalDrawableRecoveryProbe.attempts >= firstAttempt + 2 }
    settle()
    check(surface.pendingForRecoveryTest && surface.submittedFrameCount == before)
    MetalDrawableRecoveryProbe.blocked = false
    if restoreWindow { window.orderBack(nil) } else { surface.isHidden = false }
    settle()
    check(surface.submittedFrameCount == before + 1 && !surface.pendingForRecoveryTest,
        "\(restoreWindow ? "window visibility" : "view unhide") must recover pending content without submit or zoom")
    let presentedCount = surface.submittedFrameCount
    if restoreWindow {
        window.orderOut(nil); settle(); window.orderBack(nil)
    } else {
        surface.isHidden = true; settle(); surface.isHidden = false
    }
    settle()
    check(surface.submittedFrameCount == presentedCount, "visibility changes must not resubmit already-presented content")
    print("METAL_\(restoreWindow ? "WINDOW" : "VIEW")_VISIBILITY_PENDING_RECOVERY_WITHOUT_SUBMIT_AND_READY_IDLE_OK")
}
// A cached projection is still valid when AppKit asks Metal to rebuild its
// backing contents. No new item data or scroll event accompanies that request.
for (name, scene, _) in cases {
    surface.submit(scene); settle()
    let before = surface.submittedFrameCount
    surface.invalidateDrawableForRecoveryTest()
    settle()
    check(surface.submittedFrameCount > before,
        "system display invalidation must redraw retained \(name) without scroll or a new projection")
    check(!surface.pendingForRecoveryTest && surface.presentedForRecoveryTest?.hasSameContent(as: scene) == true)
    let repaired = surface.submittedFrameCount
    settle(0.3)
    for _ in 0..<100 { surface.submit(scene) }
    settle()
    check(surface.submittedFrameCount == repaired, "redraw recovery must not create continuous GPU work")
    print("METAL_\(name.uppercased())_SYSTEM_INVALIDATION_RECOVERS_CACHED_SCENE_WITHOUT_SCROLL_OK")
}
window.close()
