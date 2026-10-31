#if os(macOS)
import SwiftUI

struct MacProjectionRail: View {
    let show: ShowController
    var body: some View {
        HStack(spacing: 6) {
            Button { TPNoticeController.shared.open() } label: {
                Image(systemName: "text.bubble").font(.jarasSystem(size: 15)).frame(width: 26, height: 24)
            }.foregroundStyle(JarasTheme.yellow).accessibilityLabel("Messages").desktopIconTooltip("Messages")

        }.buttonStyle(.plain)
    }
}
#endif
