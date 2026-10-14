let controls = IpadTransportControl.allCases
precondition(controls == [.play, .pause, .subPlay, .repeatPlayback, .record, .metronome, .bpm, .tuner])
for mask in 0..<(1 << controls.count) {
    let hidden = controls.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element.rawValue }.joined(separator: ",")
    let visible = IpadTransportControl.visible(hidden: hidden)
    for available in [368.0, 620, 850, 1400] {
        let widths = controls.map { IpadTransportControl.width($0, available: available, hidden: hidden) }
        precondition(widths.allSatisfy { $0.isFinite && $0 >= 0 })
        if visible.isEmpty { precondition(widths.allSatisfy { $0 == 0 }); continue }
        let used = widths.reduce(0, +) + Double(visible.count - 1) * 4
        precondition(abs(used - available) < 0.000001, "every visibility combination fills the transport without unused space")
        for control in visible {
            let hiddenAgain = hidden + "," + control.rawValue
            for other in visible where other != control {
                precondition(IpadTransportControl.width(other, available: available, hidden: hiddenAgain) > IpadTransportControl.width(other, available: available, hidden: hidden), "remaining controls grow immediately")
            }
        }
    }
}
precondition(IpadTransportControl.visible(hidden: "unknown,repeatPlayback,repeatPlayback") == controls.filter { $0 != .repeatPlayback })
precondition(IpadTransportControl.width(.repeatPlayback, available: 620, hidden: "") > 30, "Repeat gains a wider touch area with all controls shown")
print("IPAD_TRANSPORT_ALL_256_VISIBILITY_LAYOUTS_AND_SPACE_REDISTRIBUTION_OK")
