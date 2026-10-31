
// Exercise both production notice renderers inside the actual projection layout.
// A notice must remove the clock/media subtree, not just paint over its center.
MainActor.assumeIsolated {
    let suite = "catlive-notice-projection-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = TPNoticeController(defaults: defaults)
    model.appearance = TPNoticeAppearance()
    model.draft = "CENTER"; model.send(); model.togglePin()
    RunLoop.main.run(until: Date().addingTimeInterval(1.1))
    let project = UUID()
    var timerCalls = 0, mediaCalls = 0
    func timerValue() -> (text: String, opacity: Double, expired: Bool) { timerCalls += 1; return ("12 : 34 : 56", 1, false) }
    func media() -> Color { mediaCalls += 1; return .red }
    @MainActor func render(remote: Bool, size: CGSize, active: Bool = true, preview: Bool = false,
                border: Bool = false, clean: Bool = false, clear: Bool = false) -> NSBitmapImageRep {
        var settings = TeleprompterSettings()
        settings.clockEnabled = true; settings.localClockEnabled = true
        settings.songNameEnabled = true; settings.queueNameEnabled = true
        settings.chordsEnabled = true; settings.progressEnabled = true
        settings.windowBorderEnabled = border; settings.rgbWindowBorderEnabled = false
        settings.borderColor = 0xff0000; settings.clearMode = clear
        settings.previewEnabled = true
        let content = DAWRemoteTeleprompter(index: 1, text: "LYRICS", chords: "C / G", song: "SONG", queued: "NEXT",
            progress: 0.5, style: .init(), preview: preview,
            blocks: [.init(id: UUID(), name: "PREVIEW", color: 0x0000ff,
                rows: [.init(id: UUID(), name: "FIRST", color: 0x00ff00, duration: 12)])], settings: settings)
        let notice = DAWRemoteNotices(templates: ["", "", ""], imageSlots: [false, false, false],
            message: "CENTER", active: true, pinned: true, remaining: 20, window1: true, window2: true,
            textColor: 0xffffff, backgroundColor: 0x000000, flashColor: 0x000000, font: "Arial", scale: 100,
            emoji: "", cleanDisplay: clean, sentAt: 0)
        model.appearance.cleanDisplay = clean
        timerCalls = 0; mediaCalls = 0
        let stage = TeleprompterNoticeStage(settings: settings, preview: preview, noticeActive: active) {
            TeleprompterProjectionLayout(content: content, fullscreen: true, timerValue: timerValue, media: media)
        } notice: {
            if remote { RemoteNativeNoticeOverlay(notice: notice, project: project) }
            else { TPNoticeOverlay(model: model, index: 1) }
        }
        let host = NSHostingView(rootView: stage)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000)); window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil); window.contentView = nil; window.close()
        return bitmap
    }
    func data(_ bitmap: NSBitmapImageRep) -> Data { Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
    for remote in [false, true] {
        for size in [CGSize(width: 800, height: 450), CGSize(width: 390, height: 844)] {
            let centered = render(remote: remote, size: size)
            precondition(timerCalls == 0 && mediaCalls == 0, "A notice must unmount clocks and media")
            var minX = centered.pixelsWide, minY = centered.pixelsHigh, maxX = 0, maxY = 0, white = 0
            for y in 0..<centered.pixelsHigh {
                for x in 0..<centered.pixelsWide {
                    let c = centered.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if c.redComponent > 0.7 && c.greenComponent > 0.7 && c.blueComponent > 0.7 {
                        white += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    } else {
                        precondition(abs(c.redComponent - c.greenComponent) < 0.02 && abs(c.greenComponent - c.blueComponent) < 0.02,
                            "Timer, lyric decorations or media leaked behind the notice")
                    }
                }
            }
            precondition(white > 30, "Notice text must be visible")
            precondition(abs(Double(minX + maxX) / 2 - Double(centered.pixelsWide) / 2) < 12,
                         "Notice must be horizontally centered")
            precondition(abs(Double(minY + maxY) / 2 - Double(centered.pixelsHigh) / 2) < 12,
                         "Notice must be vertically centered")
            precondition(data(render(remote: remote, size: size, clean: true)) == data(centered), "Legacy cleanDisplay cannot change notice placement")
            precondition(data(render(remote: remote, size: size, clear: true)) == data(centered), "Active notice takes precedence over Clear mode")
            let outlined = render(remote: remote, size: size, border: true)
            let edge = outlined.colorAt(x: outlined.pixelsWide / 2, y: 1)!.usingColorSpace(.sRGB)!
            // AppKit screenshots use the display profile (including HDR),
            // so test red dominance rather than raw source RGB equality.
            precondition(edge.redComponent > 0.7 && edge.redComponent - edge.greenComponent > 0.5 && edge.redComponent - edge.blueComponent > 0.5,
                         "Enabled TP border stays above the notice")
            let normal = render(remote: remote, size: size, active: false)
            precondition(timerCalls > 0 && mediaCalls > 0 && data(normal) != data(centered), "Removing the notice restores clock and media")
            let preview = render(remote: remote, size: size, preview: true)
            precondition(timerCalls > 0 && mediaCalls == 0 && data(preview) != data(centered), "Preview remains above a retained active notice")
        }
    }
    print("TP_NOTICE_MAC_NATIVE_REMOTE_CENTERED_EXCLUSIVE_CLOCK_MEDIA_HIDDEN_BORDER_AND_PREVIEW_PRIORITY_OK")
}
