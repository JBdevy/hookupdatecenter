import AppKit
import SwiftUI

// INSERT_FOOTER_SONG_DISPLAYS

@MainActor private func footerBitmap<V: View>(_ content: V, width: CGFloat, height: CGFloat) -> NSBitmapImageRep {
    let view = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: "en_US")))
    view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: CGRect(x: -12000, y: -12000, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    // This offscreen fixture never takes key status or activates the app.
    window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    for _ in 0..<3 {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

private func footerInk(_ bitmap: NSBitmapImageRep, width: CGFloat, height: CGFloat, column: Int) -> (heading: ClosedRange<CGFloat>, song: ClosedRange<CGFloat>) {
    precondition(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4)
    let pixels = bitmap.bitmapData!, scaleX = CGFloat(bitmap.pixelsWide) / width, scaleY = CGFloat(bitmap.pixelsHigh) / height
    let columnWidth = (width - 2) * 0.45, left = CGFloat(column) * (columnWidth + 1)
    let firstX = Int((left + 8) * scaleX), lastX = Int((left + columnWidth - 8) * scaleX)
    var heading: [CGFloat] = [], song: [CGFloat] = []
    for y in 0..<bitmap.pixelsHigh {
        var hasHeading = false, hasSong = false
        for x in firstX..<lastX {
            let offset = y * bitmap.bytesPerRow + x * 4
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            if r > 150 && g > 120 && b < 110 { hasSong = true }
            if r > 110 && abs(r - g) < 5 && abs(g - b) < 5 { hasHeading = true }
        }
        if hasHeading { heading.append(CGFloat(y) / scaleY) }
        if hasSong { song.append(CGFloat(y) / scaleY) }
    }
    precondition(!heading.isEmpty && !song.isEmpty, "heading and song must both remain visible")
    return (heading.first!...heading.last!, song.first!...song.last!)
}

// Frozen compact renderer: changing the desktop footer must not alter the
// transport's or remote's existing single-line pixels.
private struct FooterInlineReference: View {
    let title: String
    let name: String?
    let bpm: Double?
    var body: some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(title)).font(.system(size: 10, weight: .bold, design: .rounded)).italic()
                .foregroundStyle(JarasTheme.secondary).fixedSize()
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: (name ?? "—") + (bpm.map { " - " + String(format: "%g", $0) + " bpm" } ?? ""))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.yellow)
                .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).clipped()
    }
}
private func footerPixels(_ bitmap: NSBitmapImageRep) -> Data {
    Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}

@MainActor private func runFooterSongDisplayLayoutTests() {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    let name = "UMA CANÇÃO COM UM NOME MUITO LONGO PARA CONFERIR A QUEBRA DE LINHAS E O ESPAÇO DISPONÍVEL NO DISPLAY"
    for width: CGFloat in [640, 1000] {
        for height: CGFloat in [25, 80, 159] {
            let bitmap = footerBitmap(FooterSongDisplays(next: name, nextBPM: 120, queued: name, queuedBPM: nil,
                subPlaying: false, duration: "01:45:32", height: height, stackedSongNames: true), width: width, height: height)
            for column in 0...1 {
                let ink = footerInk(bitmap, width: width, height: height, column: column)
                precondition(ink.heading.lowerBound < 12, "footer labels remain at the top when height grows")
                precondition(ink.heading.upperBound < ink.song.lowerBound, "song is always below its heading")
                precondition(ink.song.upperBound < height - 1, "minimum and expanded displays do not clip the last text row")
                if height > 25 {
                    precondition(ink.song.upperBound - ink.song.lowerBound > height * 0.4,
                        "long song names wrap over several lines and use the added height")
                }
            }
        }
    }
    let empty = footerBitmap(FooterSongDisplays(next: nil, nextBPM: nil, queued: nil, queuedBPM: nil,
        subPlaying: true, duration: "00:00:00", height: 25, stackedSongNames: true), width: 1000, height: 25)
    for column in 0...1 {
        let ink = footerInk(empty, width: 1000, height: 25, column: column)
        precondition(ink.heading.upperBound < ink.song.lowerBound, "empty names retain the heading and dash below")
    }
    for title in ["Selected song", "Next song label", "Queued"] {
        let actual = footerBitmap(SongNameDisplay(title: title, name: name, bpm: 120), width: 500, height: 25)
        let reference = footerBitmap(FooterInlineReference(title: title, name: name, bpm: 120), width: 500, height: 25)
        precondition(footerPixels(actual) == footerPixels(reference), "shared compact song display must remain pixel-identical")
    }
    let compact = footerBitmap(FooterSongDisplays(next: name, nextBPM: 120, queued: nil, queuedBPM: nil,
        subPlaying: false, duration: "01:45:32"), width: 1000, height: 25)
    let reference = footerBitmap(GeometryReader { geometry in
        let width = max(0, geometry.size.width - 2)
        HStack(spacing: 0) {
            FooterInlineReference(title: "Next song label", name: name, bpm: 120).frame(width: width * 0.45)
            Rectangle().fill(JarasTheme.line).frame(width: 1)
            FooterInlineReference(title: "Queued", name: nil, bpm: nil).frame(width: width * 0.45)
            Rectangle().fill(JarasTheme.line).frame(width: 1)
            Text(verbatim: "01:45:32").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(JarasTheme.yellow).lineLimit(1).minimumScaleFactor(0.3)
                .frame(width: width * 0.10, height: 25).accessibilityLabel("Playlist duration")
        }
    }.frame(height: 25).background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false)), width: 1000, height: 25)
    precondition(footerPixels(compact) == footerPixels(reference), "remote footer keeps its inline layout and45/45/10 divisions")
    print("FOOTER_INLINE_TRANSPORT_REMOTE_PIXELS_UNCHANGED_OK")
    print("FOOTER_HEADINGS_AND_MULTILINE_NAMES_OK minimum27/expanded80/161 width640/1000 empty/subplay")
}
MainActor.assumeIsolated { runFooterSongDisplayLayoutTests() }
