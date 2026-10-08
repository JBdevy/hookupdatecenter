// Compare production control markup with the original geometry-transparent
// SwiftUI pulse modifiers. Every model command and unopened editor is stubbed.
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    @MainActor func frames<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, locale: String) -> [String: CGRect] {
        let root = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: locale)))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        root.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)); root.layoutSubtreeIfNeeded()
        return Dictionary(uniqueKeysWithValues: descendants(root, PulseSizingProbeView.self).map {
            ($0.name, $0.convert($0.bounds, to: root))
        })
    }
    func compare(_ actual: [String: CGRect], _ baseline: [String: CGRect], required: Set<String>, context: String) {
        expect(Set(actual.keys) == required && Set(baseline.keys) == required, "missing production geometry probe in \(context)")
        for name in required.sorted() {
            let lhs = actual[name]!, rhs = baseline[name]!
            expect(abs(lhs.minX - rhs.minX) < 0.1 && abs(lhs.minY - rhs.minY) < 0.1 &&
                abs(lhs.width - rhs.width) < 0.1 && abs(lhs.height - rhs.height) < 0.1,
                "\(context) \(name) changed geometry: native=\(lhs), original=\(rhs)")
        }
    }
    let headerNames: Set<String> = ["choose", "create", "search", "auto", "blocks", "stop", "header", "first"]
    let transportNames: Set<String> = ["playback", "metronome", "tempo", "timer", "tp1", "tp2", "messages", "preview", "video", "remote", "save", "setlist"]
    for locale in ["en", "pt_BR"] {
        for width: CGFloat in [SidebarWidthLimits.setlist, 320, SidebarWidthLimits.setlistDefault, 450] {
            let baseline = frames(LegacyHeaderFixture(active: false, width: width), width: width, height: 650, locale: locale)
            for active in [false, true] {
                let actual = frames(NativeHeaderFixture(active: active, width: width), width: width, height: 650, locale: locale)
                compare(actual, baseline, required: headerNames, context: "setlist \(locale) width=\(width) blink=\(active)")
            }
        }
        for width: CGFloat in [1296, 1366, 1440, 1664, 2048] {
            for active in [false, true] {
                TrackRecording.shared.recording = active
                for pending in [false, true] {
                    let baseline = frames(LegacyTransportFixture(active: active, pending: pending, width: width), width: width, height: 86, locale: locale)
                    let actual = frames(NativeTransportFixture(active: active, pending: pending, width: width), width: width, height: 86, locale: locale)
                    compare(actual, baseline, required: transportNames,
                        context: "transport \(locale) width=\(width) repeat/record=\(active) save=\(pending)")
                    let ordered = ["playback", "tempo", "timer", "tp1", "tp2", "messages", "preview", "video", "remote", "save", "setlist"]
                    var previousRight: CGFloat = 0
                    for name in ordered {
                        let frame = actual[name]!
                        expect(frame.minX >= previousRight - 0.1 && frame.maxX <= width + 0.1,
                            "control overlaps or leaves the transport at width \(width): \(name) \(frame)")
                        previousRight = frame.maxX
                    }
                    expect(actual["tp2"]!.minX - actual["tp1"]!.maxX >= 7.9 &&
                        actual["messages"]!.minX - actual["tp2"]!.maxX >= 7.9,
                        "teleprompter controls need a visible gap")
                    if width >= 1664 {
                        for name in ["tp1", "tp2", "messages", "preview", "video", "remote", "save", "setlist"] {
                            expect(actual[name]!.width >= 80, "extra window space did not widen \(name)")
                        }
                    }
                }
            }
        }
    }
    print("NATIVE_CONTROL_REAL_HEADER_TRANSPORT_ORIGINAL_GEOMETRY_WIDTHS_LOCALES_PULSE_STATES_AND_PEERS_OK")
}
