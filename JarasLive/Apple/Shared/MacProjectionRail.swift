#if os(macOS)
import SwiftUI

struct MacProjectionRail: View {
    let show: ShowController
    @ObservedObject private var first = TeleprompterWindow.shared
    @ObservedObject private var second = TeleprompterWindow.second
    @State private var timerOpen = false
    var body: some View {
        VStack(spacing: 8) {
            Button { first.toggle(show: show) } label: {
                Text(verbatim: "TP1").font(.system(size: 10, weight: .bold)).frame(width: 30, height: 30)
            }.foregroundStyle(first.visible ? JarasTheme.green : Color(hex: 0xff5555))
                .accessibilityLabel("Teleprompter 1").jarasHelp("Teleprompter 1")
            Button { second.toggle(show: show) } label: {
                Text(verbatim: "TP2").font(.system(size: 10, weight: .bold)).frame(width: 30, height: 30)
            }.foregroundStyle(second.visible ? JarasTheme.green : Color(hex: 0xff5555))
                .accessibilityLabel("Teleprompter 2").jarasHelp("Teleprompter 2")
            Button { TPNoticeController.shared.open() } label: {
                Image(systemName: "text.bubble").font(.system(size: 15)).frame(width: 30, height: 30)
            }.foregroundStyle(JarasTheme.yellow).accessibilityLabel("Messages").jarasHelp("Messages")
            Button { timerOpen.toggle() } label: {
                Image(systemName: "clock").font(.system(size: 16)).frame(width: 30, height: 30)
            }.foregroundStyle(Color(hex: 0x409cff)).accessibilityLabel("Timer").jarasHelp("Timer")
                .popover(isPresented: $timerOpen, arrowEdge: .leading) {
                    TeleprompterTimerControl().padding(12).background(JarasTheme.panel).preferredColorScheme(.dark)
                }
        }.buttonStyle(.plain)
    }
}
#endif
