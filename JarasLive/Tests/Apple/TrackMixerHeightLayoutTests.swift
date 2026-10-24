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
        precondition(frames[0].width >= 10 && frames[0].height > 0 && frames[0].maxY <= height,
            "Audio meters remain inside the track at every height, including its minimum")
        precondition(min(10, frames[0].width) < frames[2].minX && frames[1].maxX < frames[2].minX, "The small meter cannot cover the name")
        if height < 64 { precondition(frames[1].width == 0, "Only MIDI activity disappears in a collapsed row") }
        precondition(frames[2].minY >= 0 && frames[2].maxY <= height, "Track name must fit at every intermediate/stacked-lane height")
        if lowerTitle {
            precondition(frames[4].height == 0 || frames[4].maxY <= frames[2].minY + 0.001, "volume cannot cover the moving title")
        }
    }
}

// The minimum is the width chosen by the user. The group action belongs to
// the Patch row, with independent hit areas even after group indentation.
precondition(SidebarWidthLimits.trackMixer == 280.7578125)
for width: CGFloat in [SidebarWidthLimits.trackMixer - 16, SidebarWidthLimits.trackMixer, 400] {
    for meterWidth: CGFloat in [12, 40, 52] {
        for height: CGFloat in [64, 64.1, 80, 240] {
            let frames = TrackMixerHeightGeometry.frames(width: width, height: height,
                meterWidth: meterWidth, standard: true, lowerTitle: true, controlsWidth: 210, folder: true)
            let folder = frames[5]
            precondition(folder.width == 28 && folder.height == 20 && folder.maxY <= height && folder.minX >= 0)
            precondition(!folder.intersects(frames[3]), "folder action must not cover Patch or another top-row control")
            precondition(!folder.intersects(frames[4]), "folder action must not cover volume controls")
            precondition(folder.minX == 20 && folder.maxX + 3 <= frames[3].minX && folder.midY == frames[3].midY,
                "folder action must remain anchored left when the sidebar width changes")
            precondition(!folder.intersects(frames[2]), "folder action must not cover the group name")
            precondition(!folder.intersects(frames[1]), "the folder cannot cover the MIDI meter")
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
                    .frame(width: slot == 3 ? 210 : nil, height: slot == 5 ? 20 : nil)
            }
        }.frame(width: SidebarWidthLimits.trackMixer, height: 64)
    }
}
private let folderHost = NSHostingView(rootView: FolderFixture(counts: Counts()))
folderHost.frame = CGRect(x: 0, y: 0, width: SidebarWidthLimits.trackMixer, height: 64)
window.contentView = folderHost
folderHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)); folderHost.layoutSubtreeIfNeeded()
let folderSlots = Dictionary(uniqueKeysWithValues: probes(folderHost).map { ($0.slot, $0.convert($0.bounds, to: folderHost)) })
precondition(!folderSlots[5]!.intersects(folderSlots[3]!) && !folderSlots[5]!.intersects(folderSlots[4]!))
precondition(abs(folderSlots[5]!.minX - 20) < 1 && folderSlots[5]!.maxX + 3 <= folderSlots[3]!.minX + 0.01,
    "the actual AppKit folder frame stays anchored without covering Patch")
precondition(!folderSlots[5]!.intersects(folderSlots[2]!))
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

// Adding the first icon must extend the sidebar, retaining the real native
// control frames. Exercise grouped rows and persisted resize widths as well.
private struct IconColumnFixture: View {
    let width: CGFloat
    let icons: Bool
    let child: Bool
    var body: some View {
        let columns = TrackMixerColumnGeometry(requestedWidth: width, maximum: 486.5, showsIcons: icons)
        HStack(spacing: TrackMixerColumnGeometry.spacing) {
            if child { Color.clear.frame(width: 12) }
            TrackMixerContinuousLayout(meterWidth: 52, standard: true, lowerTitle: true, folder: true) {
                ForEach(0..<7) { slot in
                    Probe(counts: Counts(), slot: slot)
                        .frame(width: slot == 3 ? 210 : nil, height: slot == 5 ? 20 : nil)
                }
            }
            if icons { Color.clear.frame(width: TrackMixerColumnGeometry.iconWidth) }
        }.frame(width: columns.totalWidth, height: 80)
    }
}
for width: CGFloat in [SidebarWidthLimits.trackMixer, 350, 486.5] {
    for child in [false, true] {
        let iconHost = NSHostingView(rootView: IconColumnFixture(width: width, icons: false, child: child))
        window.contentView = iconHost
        func frames(_ icons: Bool) -> [CGRect] {
            let columns = TrackMixerColumnGeometry(requestedWidth: width, maximum: 486.5, showsIcons: icons)
            window.setContentSize(NSSize(width: columns.totalWidth, height: 80))
            iconHost.rootView = IconColumnFixture(width: width, icons: icons, child: child)
            iconHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)); iconHost.layoutSubtreeIfNeeded()
            return probes(iconHost).sorted { $0.slot < $1.slot }.map { $0.convert($0.bounds, to: iconHost) }
        }
        let before = frames(false), withIcons = frames(true), after = frames(false)
        precondition(before.count == 7 && before == withIcons && before == after,
            "Adding/removing icons must preserve meter, Patch, folder, title and fader frames")
        let columns = TrackMixerColumnGeometry(requestedWidth: width, maximum: 486.5, showsIcons: true)
        precondition(columns.storedWidth(for: columns.totalWidth + 10) == width + 10,
            "Resizing must save only the control width, without accumulating icon widths")
        precondition(TrackMixerColumnGeometry(requestedWidth: 0, maximum: 486.5, showsIcons: true).totalWidth == 0,
            "Hiding the mixer must also hide the icon column")
    }
}
print("MIXER_ICONS_EXTEND_SIDEBAR_WITHOUT_MOVING_NATIVE_CONTROLS_OK")
window.close()

for width: CGFloat in [265,281,400,700] {
    for height: CGFloat in [24,40,63.9,64,80,240] {
        let frames = TrackMixerHeightGeometry.frames(width: width,height: height,meterWidth: 52,
            standard: true,lowerTitle: true,controlsWidth: 210,folder: true)
        precondition(frames[2].minX == 22, "Track number must keep its left anchor across sizes")
        if height >= 64 { precondition(frames[5].minX == 20, "Folder must keep its left anchor") }
    }
}
