#if os(macOS)
import SwiftUI

struct MacProjectionRail: View {
    let show: ShowController
    @ObservedObject private var presentation = TPNoticeController.shared.editorPresentation
    var body: some View {
        HStack(spacing: 6) {
            Button { TPNoticeController.shared.open() } label: {
                DesktopToolbarLabel(title: "Messages", systemImage: "text.bubble", active: presentation.isOpen)
            }.accessibilityLabel("Messages").help(Text("Messages"))

        }.buttonStyle(.plain)
    }
}
#endif
