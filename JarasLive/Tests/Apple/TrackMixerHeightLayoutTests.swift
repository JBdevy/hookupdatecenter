import SwiftUI
import AppKit

private final class Counts { var made = 0; var removed = 0 }
private final class ProbeView: NSView { let counts: Counts; let slot: Int; init(_ counts: Counts, _ slot: Int) { self.counts = counts; self.slot = slot; super.init(frame: .zero) }; required init?(coder: NSCoder) { fatalError() } }
private struct Probe: NSViewRepresentable {
    let counts: Counts; let slot: Int
    func makeNSView(context: Context) -> ProbeView { counts.made += 1; return ProbeView(counts, slot) }
    func updateNSView(_ view: ProbeView, context: Context) {}
    static func dismantleNSView(_ view: ProbeView, coordinator: Void) { view.counts.removed += 1 }
}
private struct Fixture: View {
    let height: CGFloat; let counts: Counts
    var body: some View {
            TrackMixerContinuousLayout(meterWidth: 40, standard: true, lowerTitle: true) {
                ForEach(0..<7) { slot in
                    Probe(counts: counts, slot: slot)
                }
            }.frame(width: 248, height: height)
    }
}
private func probes(_ view: NSView) -> [ProbeView] { (view as? ProbeView).map { [$0] } ?? view.subviews.flatMap(probes) }
_ = NSApplication.shared
private let counts = Counts()
private let host = NSHostingView(rootView: Fixture(height: 64, counts: counts))
let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 248,height: 240), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false; window.contentView = host
func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)); host.layoutSubtreeIfNeeded() }
settle()
host.rootView = Fixture(height: 64, counts: counts); settle()
let identities = probes(host).sorted { $0.slot < $1.slot }.map(ObjectIdentifier.init)
precondition(identities.count == 7)
let warmed = counts.made
for height in [80.0,64.1,64,63.9,56.1,56,55.9,48,40.1,40,39.9,24,39.9,40,40.1,55.9,56,56.1,63.9,64,64.1,80] {
    host.rootView = Fixture(height: height, counts: counts); settle()
    precondition(probes(host).sorted { $0.slot < $1.slot }.map(ObjectIdentifier.init) == identities, "height thresholds must retain every native control")
}
precondition(counts.made == warmed && counts.removed == 0, "no faders/meters/titles are recreated while collapsing or expanding")
for lowerTitle in [false,true] {
    for height in stride(from: 24.0, through: 80.0, by: 0.05) {
        let frames = TrackMixerHeightGeometry.frames(width: 248,height: height,meterWidth: 40,standard: true,lowerTitle: lowerTitle,controlsWidth: 100 + 42*TrackMixerHeightGeometry.progress(height))
        precondition(frames.allSatisfy { $0.width >= 0 && $0.height >= 0 })
        precondition(frames[2].minY >= 0 && frames[2].maxY <= height, "Track name must fit at every intermediate/stacked-lane height")
        if lowerTitle {
            precondition(frames[4].height == 0 || frames[4].maxY <= frames[2].minY + 0.001, "volume cannot cover the moving title")
        }
    }
}

// Env added a seventh control in the top row. At the minimum sidebar width
// the old folder action overlapped it; folder/title must own separate hit areas.
for width: CGFloat in [184, 212, 232, 248.6796875, 400] {
    for meterWidth: CGFloat in [12, 40, 52] {
        for height: CGFloat in [64, 64.1, 80, 240] {
            let frames = TrackMixerHeightGeometry.frames(width: width, height: height,
                meterWidth: meterWidth, standard: true, lowerTitle: true, controlsWidth: 210, folder: true)
            let folder = frames[5]
            precondition(folder.width == 28 && folder.height == 16 && folder.maxY <= height)
            precondition(!folder.intersects(frames[3]), "folder action must not cover Patch or another top-row control")
            precondition(!folder.intersects(frames[4]), "folder action must not cover volume controls")
            precondition(folder.maxX + 4 <= frames[2].minX, "folder action reserves space before the group name")
            precondition(frames[2].maxX <= width && frames[2].width > 0)
        }
    }
}
for height: CGFloat in [64, 80, 160] {
    let frames = TrackMixerHeightGeometry.frames(width: 248, height: height, meterWidth: 52,
        standard: true, lowerTitle: true, controlsWidth: 210)
    precondition(frames[0].width == 52 && frames[1].minX == 14 && frames[1].width == 4,
        "Four points separate MIDI from the ten-point stereo bars")
    precondition(frames[1].minY == frames[0].minY && frames[1].maxY == frames[0].maxY,
        "Audio and MIDI keep matching full-height bars")
    precondition(frames[4].minX == 56, "Volume does not overlap the peak readout")
}
print("MIXER_AUDIO_MIDI_GAP_AND_SIDE_PEAK_OK")
private struct FolderFixture: View {
    let counts: Counts
    var body: some View {
        TrackMixerContinuousLayout(meterWidth: 40, standard: true, lowerTitle: true, folder: true) {
            ForEach(0..<7) { slot in
                Probe(counts: counts, slot: slot)
                    .frame(width: slot == 3 ? 210 : nil, height: slot == 5 ? 16 : nil)
            }
        }.frame(width: 232, height: 64)
    }
}
private let folderHost = NSHostingView(rootView: FolderFixture(counts: Counts()))
folderHost.frame = CGRect(x: 0, y: 0, width: 232, height: 64)
window.contentView = folderHost
folderHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)); folderHost.layoutSubtreeIfNeeded()
let folderSlots = Dictionary(uniqueKeysWithValues: probes(folderHost).map { ($0.slot, $0.convert($0.bounds, to: folderHost)) })
precondition(!folderSlots[5]!.intersects(folderSlots[3]!) && !folderSlots[5]!.intersects(folderSlots[4]!))
precondition(folderSlots[5]!.maxX + 4 <= folderSlots[2]!.minX)
print("MIXER_GROUP_FOLDER_PATCH_TITLE_AND_VOLUME_HIT_AREAS_SEPARATED_OK")

// Exercise the real AppKit title, whose intrinsic 28px height used to override
// the layout's 16–21px slot and clip its text in compressed overlap rows.
private struct TitleFixture: View {
    let height: CGFloat
    let state = TrackReorderState()
    var body: some View {
        TrackMixerContinuousLayout(height: height, meterWidth: 40, standard: true, lowerTitle: true) {
            Color.clear
            Color.clear
            TrackDragTitle(title: "04 CLICK", foreground: 0xffffff, project: UUID(), track: UUID(), state: state, select: {})
            Color.clear.frame(width: 145, height: 24)
            Color.clear
            Color.clear
            Color.clear
        }.frame(width: 248, height: height)
    }
}
private func titles(_ view: NSView) -> [TrackDragTitleView] { (view as? TrackDragTitleView).map { [$0] } ?? view.subviews.flatMap(titles) }
private let titleHost = NSHostingView(rootView: TitleFixture(height: 56))
window.contentView = titleHost
for height in [24.0, 36, 40, 48, 52, 55, 56, 58, 60, 63, 64, 78.4, 89.6] {
    titleHost.rootView = TitleFixture(height: height)
    titleHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)); titleHost.layoutSubtreeIfNeeded()
    let title = titles(titleHost).first!
    precondition(abs(title.bounds.height - TrackMixerHeightGeometry.titleHeight(height)) < 1.1, "Actual native title must respect its proposed height: \(height), got \(title.bounds.height)")
    precondition(title.bounds.height >= 14, "A full line of text remains visible")
}
print("MIXER_HEIGHT_STABLE_NATIVE_CONTROLS_AND_DIRECT_LAYOUT_OK")
window.close()
