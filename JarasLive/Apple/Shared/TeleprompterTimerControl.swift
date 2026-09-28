import SwiftUI
import Combine

#if os(macOS)
/// Only this small control redraws with the independent timer clock.
@MainActor struct TeleprompterTimerControl: View {
    @ObservedObject private var timer: TeleprompterTimerController
    @State private var tick = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var digits = ["00", "05", "00"]
    private var draft: String { digits.joined(separator: ":") }
    @State private var invalid = false
    @State private var shake = 0.0
    @FocusState private var focused: Int?
    init() { timer = .shared }
    init(timer: TeleprompterTimerController) { self.timer = timer }
    var body: some View {
        HStack(spacing: 3) {
            timerField(at: tick)
            timerButton
        }.fixedSize(horizontal: true, vertical: false)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.55), lineWidth: 1).allowsHitTesting(false))
            .onReceive(clock) { if timer.running { tick = $0 } }
            .onAppear(perform: refresh)
            .onChange(of: timer.targetSeconds) { _ in if focused == nil { refresh() } }
            .onChange(of: timer.mode) { _ in if focused == nil { refresh() } }
            .onChange(of: timer.running) { _ in refresh() }
            .onChange(of: focused) { value in if value == nil, !timer.running { _ = commit() } }
    }
    private func timerField(at date: Date) -> some View {
        // Capture changing display values outside ForEach so each stable field
        // receives the new text and blink state on every timeline update.
        let values = timer.displayText().components(separatedBy: ":")
        let expired = timer.expired()
        let opacity = timer.displayOpacity()
        return HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Group {
                    if timer.running {
                        TimerReadout(text: values.indices.contains(index) ? values[index] : "00", expired: expired)
                            .opacity(opacity)
                    } else {
                        TextField("00", text: $digits[index])
                            .textFieldStyle(.plain).focused($focused, equals: index)
                            .onSubmit { if commit() { focused = nil } }
                            .onExitCommand { refresh(); focused = nil }
                    }
                }
                .multilineTextAlignment(.center).frame(width: 28, height: 32)
                .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : JarasTheme.line))
                .accessibilityLabel(LocalizedStringKey(["Hours", "Minutes", "Seconds"][index]))
                .immediateRightClick { timer.showConfiguration() }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .modifier(InputValidationShake(animatableData: shake))
        .jarasHelp("Timer settings · Right-click")
    }
    private var timerButton: some View {
        Button {
            if timer.running { timer.stopAndReset(); refresh() }
            else if commit() { focused = nil; timer.start() }
        } label: {
            Text(LocalizedStringKey(timer.running ? "Stop" : "Start"))
                .font(.system(size: 11, weight: .semibold)).frame(width: 48, height: 32)
                .foregroundStyle(timer.running ? Color.white : JarasTheme.green)
                .background(timer.running ? Color.red.opacity(0.65) : JarasTheme.display)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(timer.running ? Color.red : JarasTheme.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(timer.running ? "Timer Stop" : "Timer Play")
            .jarasHelp(timer.running ? "Timer Stop" : "Timer Play")
            .immediateRightClick { timer.showConfiguration() }
    }
    private func refresh() {
        digits = timer.targetText.components(separatedBy: ":")
        invalid = false
    }
    @discardableResult private func commit() -> Bool {
        guard timer.setTargetText(draft) else {
            invalid = true
            withAnimation(.linear(duration: 0.3)) { shake += 1 }
            return false
        }
        digits = timer.targetText.components(separatedBy: ":"); invalid = false
        return true
    }
}
private struct TimerReadout: NSViewRepresentable {
    let text: String
    let expired: Bool
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.textColor = expired ? .systemRed : NSColor(JarasTheme.green)
    }
}
#endif
