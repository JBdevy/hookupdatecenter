#if os(iOS)
import SwiftUI

/// Native workspace controls use the desktop preferences and project actions.
/// The remote-only workspace does not mount this toolbar.
struct IpadTimelineToolbar: View {
    let show: ShowController
    let addTrack: () -> Void
    @Binding private var editing: Bool
    @ObservedObject private var updates: ShowProjectPresentation
    @State private var showingVisibility = false
    @State private var showingLocks = false

    init(show: ShowController, addTrack: @escaping () -> Void, editing: Binding<Bool>) {
        self.show = show
        self.addTrack = addTrack
        _editing = editing
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal, showsIndicators: false) { controls }
        }
        .padding(.horizontal, 4)
        .font(.jarasSystem(size: 11, weight: .semibold))
        .foregroundStyle(JarasTheme.text)
        .onChange(of: show.snapshot.project.id) { _ in
            showingVisibility = false
        }
    }

    private let addControlWidth: CGFloat = 36

    private var controls: some View {
        HStack(spacing: 4) {
            editButton
            timelineButtons
            addButton
        }
    }

    private var editButton: some View {
        Button { editing.toggle() } label: {
            Text(verbatim: editing ? "Done" : "Edit")
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: editing ? JarasTheme.green : JarasTheme.text))
            .accessibilityIdentifier("native-track-edit")
    }

    private var addButton: some View {
        Button(action: addTrack) {
            Text(verbatim: "Add").frame(width: addControlWidth, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: JarasTheme.accent))
            .accessibilityLabel("Add Track")
            .accessibilityIdentifier("native-add-track")
    }

    @ViewBuilder private var timelineButtons: some View {
        TrackMixerVUButton(size: 32)
        TrackMixerComponentsPresetButton(size: 32)
        Button { showingVisibility = true } label: {
            ControlIcon(name: "eye", active: showingVisibility).frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: JarasTheme.text))
            .accessibilityLabel("Visibilidade das pistas")
            .accessibilityIdentifier("native-track-visibility").help(Text(verbatim: "Hide/View-Tracks"))
            .popover(isPresented: $showingVisibility, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                let editor = TrackVisibilityEditor(show: show, close: { showingVisibility = false })
                    .preferredColorScheme(.dark)
                if #available(iOS 16.4, *) {
                    editor.presentationCompactAdaptation(.popover).presentationBackground(JarasTheme.panel)
                } else {
                    editor
                }
            }
        Button { show.setTimelineMovementLocked(!show.timelineMovementLocked) } label: {
            ControlIcon(name: show.timelineMovementLocked ? "lock" : "unlock", active: show.timelineMovementLocked)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(IpadTimelineToolbarButtonStyle(color: show.timelineMovementLocked ? .black : JarasTheme.text,
                                                    background: show.timelineMovementLocked ? JarasTheme.yellow : nil))
            .accessibilityLabel("Lock timeline movement")
            .accessibilityIdentifier("timeline-movement-lock").help(Text(verbatim: "Lock- Timeline"))
            .onLongPressGesture { showingLocks = true }
            .popover(isPresented: $showingLocks) { TimelineLockOptionsView(show: show) }
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
