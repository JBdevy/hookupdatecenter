@MainActor func verifyItemSilencing() {
    let scrolling = RemoteTrackScrollController()
    let clip = DAWRemoteState.Clip(id: UUID(), name: "Audio", start: 0, duration: 10)
    let audible = RemoteNativeGridItem(clip: clip, width: 240, height: 90, color: 0xff3000, nameColor: 0xffffff,
        scrolling: scrolling, sourceFraction: 0, visibleFraction: 1, mute: {}, setGain: { _ in }, local: true)
    var silenced = audible
    silenced.trackSilenced = true
    precondition(audible != silenced, "Track Mute/Solo must invalidate the cached item")
    func pixel(_ item: RemoteNativeGridItem) -> NSColor {
        let renderer = ImageRenderer(content: item.background(Color.black))
        guard let image = renderer.cgImage,
              let color = NSBitmapImageRep(cgImage: image).colorAt(x: 120, y: 60)?.usingColorSpace(.deviceRGB) else {
            preconditionFailure("Could not render the actual item view")
        }
        return color
    }
    func checkGray(_ item: RemoteNativeGridItem) {
        let c = pixel(item)
        precondition(abs(c.redComponent - c.greenComponent) < 0.005 && abs(c.greenComponent - c.blueComponent) < 0.005,
                     "Silenced item body must be grayscale: \(c)")
    }
    let original = pixel(audible)
    precondition(original.redComponent > original.greenComponent * 2, "Audible item retains track color")
    checkGray(silenced)
    var itemMuted = audible
    itemMuted = RemoteNativeGridItem(clip: .init(id: clip.id, name: clip.name, start: 0, duration: 10, muted: true),
        width: 240, height: 90, color: 0xff3000, nameColor: 0xffffff, scrolling: scrolling,
        sourceFraction: 0, visibleFraction: 1, mute: {}, setGain: { _ in }, local: true)
    checkGray(itemMuted)
    silenced.trackSilenced = false
    precondition(audible == silenced, "Unmute/clearing Solo restores the same item presentation")
    precondition(pixel(silenced) == original, "Clearing Mute/Solo restores original color")
    print("IPAD_ACTUAL_GRID_ITEM_RENDER_MUTE_SOLO_GRAYSCALE_AND_RESTORE_OK")
}
MainActor.assumeIsolated { verifyItemSilencing() }
