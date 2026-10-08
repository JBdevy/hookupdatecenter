
struct LiveTeleprompterSettingsFixture: View {
    @ObservedObject var preferences: TeleprompterPreferences
    var body: some View {
        TeleprompterProjectionLayout(content: .init(index: 1, text: "Atualização ao vivo", chords: "", song: "", queued: "", progress: 0,
                                                    style: .init(), settings: preferences.settings), fullscreen: false,
                                    timerValue: { ("00 : 00 : 10", 1, false) }, media: { EmptyView() })
    }
}
// Exercise the actual SwiftUI projection, rather than only asserting that a
// preference stores a value. Each exposed setting must change rendered pixels
// in the content mode to which it belongs, for both projection indices.
MainActor.assumeIsolated {
    _ = NSApplication.shared
    func fixture(_ settings: TeleprompterSettings, index: Int = 1, preview: Bool = false) -> DAWRemoteTeleprompter {
        .init(index: index, text: "Minha letra\nSegunda linha", chords: "Cm / G7", song: "Minha música", queued: "Na fila",
              progress: 0.42, style: .init(), preview: preview,
              blocks: [.init(id: UUID(), name: "Repertório", color: 0x4488ff,
                             rows: [.init(id: UUID(), name: "Primeira música", color: 0x44ff88, duration: 123),
                                    .init(id: UUID(), name: "Segunda música", color: 0xff4488, duration: 234)])], settings: settings)
    }
    func pixels(_ content: DAWRemoteTeleprompter, expired: Bool = false) -> Data {
        let view = NSHostingView(rootView: TeleprompterProjectionLayout(content: content, fullscreen: false,
            timerValue: { ("00 : 12 : 34", 1, expired) }, media: {
                // Nonuniform media makes the actual scale transform observable.
                HStack(spacing: 0) { Color.blue; Color.red; Color.green }.frame(width: 300, height: 200)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        window.orderOut(nil); window.contentView = nil; window.close()
        return data
    }
    var base = TeleprompterSettings()
    base.songNameEnabled = true; base.progressEnabled = true
    base.textCase = "original"
    var checked = 0
    for index in 1...2 {
        for field in TPSettingField.all {
            let before = base
            var after = base
            let preview = field.id.hasPrefix("preview") || field.id == "ignorePreview"
            let expired = field.id == "clockExpiredColor"
            // These two settings act on the decoder/content selection, not on
            // typography; their integration is covered in the media/protocol tests.
            if field.id == "mediaStretch" || field.id == "progressMode" { continue }
            switch field {
            case .color(_, _, let path): after[keyPath: path] = 0x9c27ff
            case .range(_, _, let path, let limits): after[keyPath: path] = limits.lowerBound
            case .choice(_, _, let path, let options): after[keyPath: path] = options.last { $0.value != before[keyPath: path] }!.value
            case .toggle(_, _, let path): after[keyPath: path].toggle()
            }
            if field.id == "textCase" { after.textCase = "uppercase" }
            if field.id == "localClockPosition" { after.localClockPosition = "left" }
            precondition(pixels(fixture(before, index: index, preview: preview), expired: expired) != pixels(fixture(after, index: index, preview: preview), expired: expired),
                         "TP-\(index): \(field.id) must change the real display")
            checked += 1
        }
        for edge in ["left", "right"] {
            base.clockPosition = edge + "-top"
            var next = base; next.localClockPosition = edge == "left" ? "right" : "left"
            base.localClockPosition = edge
            precondition(pixels(fixture(base, index: index)) != pixels(fixture(next, index: index)), "local clock edge must not be overridden by timer edge")
        }
        for field in TPSettingField.all {
            guard case .choice(_, _, let path, let options) = field, field.id.hasSuffix("FontFamily") || field.id == "fontFamily" else { continue }
            let preview = field.id == "previewFontFamily"
            var defaults = base; defaults[keyPath: path] = "system"
            let original = pixels(fixture(defaults, index: index, preview: preview))
            for option in options where option.value != "system" {
                var selected = defaults; selected[keyPath: path] = option.value
                precondition(pixels(fixture(selected, index: index, preview: preview)) != original, "\(field.id): \(option.value) must use a font distinct from Default")
                checked += 1
            }
        }
        var ignored = base; ignored.ignoresPreview = true
        precondition(pixels(fixture(ignored, index: index, preview: true)) == pixels(fixture(ignored, index: index, preview: false)), "Ignore Preview must preserve normal lyrics, chords and media")
        var clear = base; clear.isClear = true
        var scaledClear = clear; scaledClear.mediaScale = 50
        precondition(pixels(fixture(clear, index: index)) != pixels(fixture(scaledClear, index: index)), "media scale also works in media-only mode")
    }
    let suite = "catlive-tp-live-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = TeleprompterPreferences(defaults: defaults), second = TeleprompterPreferences(defaults: defaults, key: "tp2")
    let live = NSHostingView(rootView: LiveTeleprompterSettingsFixture(preferences: first))
    let liveWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    liveWindow.isReleasedWhenClosed = false; liveWindow.contentView = live; liveWindow.orderFrontRegardless()
    func livePixels() -> Data {
        RunLoop.main.run(until: Date().addingTimeInterval(0.04)); live.layoutSubtreeIfNeeded()
        let bitmap = live.bitmapImageRepForCachingDisplay(in: live.bounds)!
        live.cacheDisplay(in: live.bounds, to: bitmap)
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    var displayed = livePixels()
    first.set(\.textScale, 45)
    var updated = livePixels(); precondition(updated != displayed, "scale changes an already-open projection without replacing its host")
    displayed = updated; first.set(\.textColor, 0xff0000)
    updated = livePixels(); precondition(updated != displayed, "color changes an already-open projection")
    displayed = updated; first.set(\.fontFamily, "mono")
    updated = livePixels(); precondition(updated != displayed, "font changes an already-open projection")
    liveWindow.orderOut(nil); liveWindow.contentView = nil; liveWindow.close()
    first.set(\.textScale, 45); second.set(\.clockScale, 135)
    first.select(.day); first.set(\.textScale, 80); first.select(.night)
    precondition(first.settings.textScale == 45 && second.settings.textScale == 100, "independent windows and presets")
    let reopened = TeleprompterPreferences(defaults: defaults)
    precondition(reopened.settings.textScale == 45 && reopened.selected == .night, "appearance survives reopening")
    reopened.select(.day); precondition(reopened.settings.textScale == 80, "day appearance survives reopening")
    print("PASS: \(checked) rendered TP setting checks, same-edge clocks, clear-media scale, live updates, independent windows/presets and persistence")
}
