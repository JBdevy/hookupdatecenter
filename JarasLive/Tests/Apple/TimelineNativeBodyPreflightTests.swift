import AppKit
@MainActor final class NativeBodyYPreflightProbe {
    var calls: [(CGRect, CGSize, Double)] = []
    func project(viewport: CGRect, documentSize: CGSize, scale: Double) { calls.append((viewport, documentSize, scale)) }
}
@MainActor final class NativeBodyYPreflightFixture {
    struct Configuration {
        var extent: Double = 20
        var contentHeight: CGFloat = 1975
        var viewportSize = CGSize(width: 600, height: 260)
        var horizontalOffsetChanged: (CGFloat) -> Void = { _ in }
        var verticalOffsetChanged: (CGFloat) -> Void = { _ in }
    }
    let audioBody = NativeBodyYPreflightProbe()
    var configuration: Configuration? = Configuration()
    var preparedHorizontalOffset: CGFloat?
    var preparedVerticalOffset: CGFloat?
    var horizontal: NSClipView? = NSClipView(frame: CGRect(x: 0, y: 0, width: 600, height: 260))
    var vertical: NSClipView? = NSClipView(frame: CGRect(x: 0, y: 0, width: 600, height: 260))
    var pixelsPerSecond: CGFloat = 600
    var changed = false
    var observedViewport = CGRect.zero
    func updateHostedItems(viewport: CGRect, width: CGFloat) -> Bool { observedViewport = viewport; return changed }
__NATIVE_BODY_PREFLIGHT_METHOD__

}
MainActor.assumeIsolated {
    let fixture = NativeBodyYPreflightFixture()
    fixture.horizontal!.bounds.origin = CGPoint(x: 512, y: 0)
    fixture.vertical!.bounds.origin = CGPoint(x: 0, y: 800)
    let sameBucket = fixture.prepareHostedViewport(y: 1021)
    precondition(!sameBucket, "native band expiration inside the same512 bucket cannot force hosting layout")
    precondition(fixture.audioBody.calls.count == 1)
    let first = fixture.audioBody.calls[0]
    precondition(first.0 == CGRect(x:512,y:1021,width:600,height:260) && first.1 == CGSize(width:12000,height:1975) && first.2==600)
    precondition(fixture.vertical!.bounds.minY == 800, "native target is prepared before native bounds expose it")
    precondition(fixture.prepareHostedViewport(y:1024), "existing512 publication boundary still requests hosting layout")
    let count = fixture.audioBody.calls.count
    _ = fixture.prepareHostedViewport(x:800)
    precondition(fixture.audioBody.calls.count==count, "horizontal preflight remains unchanged")
    fixture.changed = true
    precondition(fixture.prepareHostedViewport(y:1025), "fallback gate change still requires hosting layout")
    fixture.configuration = nil
    precondition(!fixture.prepareHostedViewport(y:1400) && fixture.audioBody.calls.count==count+1)
    print("NATIVE_Y_REAL_PREFLIGHT_BEFORE_BOUNDS_SAME512_NO_HOST_LAYOUT_HORIZONTAL_UNCHANGED_GATE_AND_DETACH_OK")
}
