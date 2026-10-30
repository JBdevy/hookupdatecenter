#if os(macOS)
import SwiftUI

struct MacProjectionRail: View {
    let show: ShowController
    @State private var timerOpen = false
    var body: some View {
        HStack(spacing: 6) {
            Button { TPNoticeController.shared.open() } label: {
                Image(systemName: "text.bubble").font(.jarasSystem(size: 15)).frame(width: 26, height: 24)
            }.foregroundStyle(JarasTheme.yellow).accessibilityLabel("Messages").jarasHelp("Messages")
            Button { timerOpen.toggle() } label: {
                Image(systemName: "clock").font(.jarasSystem(size: 16)).frame(width: 26, height: 24)
            }.foregroundStyle(Color(hex: 0x409cff)).accessibilityLabel("Timer").jarasHelp("Timer")
                .popover(isPresented: $timerOpen, arrowEdge: .top) {
                    TeleprompterTimerControl().padding(12).background(JarasTheme.panel).preferredColorScheme(.dark)
                }
        }.buttonStyle(.plain)
    }
}
#endif
