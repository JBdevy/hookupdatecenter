#if os(macOS)
import SwiftUI

struct MacProjectionRail: View {
    let show: ShowController
    @ObservedObject private var notices = TPNoticeController.shared
    var body: some View {
        HStack(spacing: 6) {
            Button { notices.open() } label: {
                DesktopToolbarLabel(title: "Messages", systemImage: "text.bubble", active: notices.editorOpen)
            }.accessibilityLabel("Messages").help(Text("Messages"))

        }.buttonStyle(.plain)
    }
}
#endif
