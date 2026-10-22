#if os(iOS)
import SwiftUI

/// Native workspace controls use the desktop preferences and project actions.
/// The remote-only workspace does not mount this toolbar.
struct IpadTimelineToolbar: View {
    let show: ShowController
    let addTrack: () -> Void
    @Binding private var editing: Bool
    @ObservedObject private var updates: ShowProjectPresentation
    @AppStorage(TimelineSnapPreference.key) private var snapEnabled = true
    @State private var showingVisibility = false
    @State private var pendingTimebase: TimebaseRequest?

    private struct TimebaseRequest {
        let project: UUID
        let song: UUID
        let relative: Bool
    }

    init(show: ShowController, addTrack: @escaping () -> Void, editing: Binding<Bool>) {
        self.show = show
        self.addTrack = addTrack
        _editing = editing
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }

    private var relativeTimebase: Bool { show.current?.projectTime.timebase == .relative }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                editButton
                timelineButtons
                addButton
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    editButton
                    Spacer(minLength: 0)
                    addButton
                }
                HStack(spacing: 4) { timelineButtons }
            }
        }
        .padding(.horizontal, 4)
        .font(.jarasSystem(size: 11, weight: .semibold))
        .foregroundStyle(JarasTheme.text)
        .sheet(isPresented: $showingVisibility) {
            TrackVisibilityEditor(show: show, close: { showingVisibility = false })
        }
        .alert(Text(verbatim: JarasLocalization.string(pendingTimebase?.relative == true ? "Enable relative timebase?" : "Disable relative timebase?")),
               isPresented: Binding(get: { pendingTimebase != nil }, set: { if !$0 { pendingTimebase = nil } }),
               presenting: pendingTimebase) { request in
            Button("Cancel", role: .cancel) { }
            Button(request.relative ? "Enable" : "Disable") {
                guard request.project == show.snapshot.project.id,
                      let song = show.current, song.id == request.song else { return }
                var settings = song.projectTime
                settings.timebase = request.relative ? .relative : .free
                if show.configureProjectTime(bpm: song.bpm, beats: song.meterBeats, unit: song.meterUnit, settings: settings) {
                    GlobalProjectTiming(bpm: song.bpm, beats: song.meterBeats, unit: song.meterUnit, settings: settings).save()
                }
            }
        } message: { request in
            Text(LocalizedStringKey(request.relative
                ? "Relative timebase: changing the project BPM adjusts item duration and playback speed to follow the tempo. With Free timebase, changing the project BPM preserves item duration and playback speed. Tempo markers with their own timebase keep their individual settings."
                : "Free timebase: changing the project BPM changes the grid without stretching or shortening items. Item duration and playback speed are preserved. Tempo markers with their own timebase keep their individual settings."))
        }
        .onChange(of: show.snapshot.project.id) { _ in
            showingVisibility = false
            pendingTimebase = nil
        }
    }

    private var editButton: some View {
        Button { editing.toggle() } label: {
            Text(editing ? "Done" : "Edit")
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: editing ? JarasTheme.green : JarasTheme.text))
            .accessibilityIdentifier("native-track-edit")
    }

    private var addButton: some View {
        Button(action: addTrack) {
            Text(verbatim: "Add").frame(width: 36, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: JarasTheme.accent))
            .accessibilityLabel("Add Track")
            .accessibilityIdentifier("native-add-track")
    }

    @ViewBuilder private var timelineButtons: some View {
        Button { snapEnabled.toggle() } label: {
            TimelineMagnetIcon().stroke(lineWidth: 1.5).frame(width: 17, height: 17)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: snapEnabled ? JarasTheme.accent : JarasTheme.secondary))
            .accessibilityLabel("Timeline snapping")
            .accessibilityIdentifier("timeline-snap")
            .accessibilityValue(snapEnabled ? "On" : "Off")
        Button { showingVisibility = true } label: {
            Image(systemName: "eye").frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: JarasTheme.text))
            .accessibilityLabel("Visibilidade das pistas")
            .accessibilityIdentifier("native-track-visibility")
        Button {
            guard show.canControl(), let song = show.current else { return }
            pendingTimebase = TimebaseRequest(project: show.snapshot.project.id, song: song.id,
                                              relative: song.projectTime.timebase != .relative)
        } label: {
            Image(systemName: "arrow.left.and.right").frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: relativeTimebase ? JarasTheme.green : .yellow))
            .accessibilityLabel("Relative timebase")
            .accessibilityIdentifier("timeline-timebase")
            .accessibilityValue(relativeTimebase ? "Enabled" : "Disabled")
            .disabled(show.current == nil)
        Button { show.setTimelineMovementLocked(!show.timelineMovementLocked) } label: {
            Image(systemName: show.timelineMovementLocked ? "lock.fill" : "lock.open")
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: show.timelineMovementLocked ? .black : JarasTheme.text,
                                                    background: show.timelineMovementLocked ? JarasTheme.yellow : nil))
            .accessibilityLabel("Lock timeline movement")
            .accessibilityIdentifier("timeline-movement-lock")
            .accessibilityValue(show.timelineMovementLocked ? "Locked" : "Unlocked")
    }
}

private struct IpadTimelineToolbarButtonStyle: ButtonStyle {
    let color: Color
    var background: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(color)
            .background((background ?? JarasTheme.text.opacity(0.07)).opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}
#endif
