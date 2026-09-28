import Foundation

public enum DAWAction: String, Codable, CaseIterable, Sendable {
    case selectTrack, muteTrack, soloTrack, volumeTrack, panTrack
    case tempoDown, tempoUp, tapTempo, playStop, pause, repeatPlayback, subPlayStop, addTrack
    case setlistUp, setlistDown, toggleAuto, splitItems, ignoreNext

    public static let visible = allCases
    public var needsTrack: Bool { [.selectTrack, .muteTrack, .soloTrack, .volumeTrack, .panTrack].contains(self) }
    public var continuous: Bool { self == .volumeTrack || self == .panTrack }
    public var fixedKeyboard: Bool { self == .setlistUp || self == .setlistDown }
    public var repeats: Bool { [.tempoDown, .tempoUp].contains(self) }
    public var title: String {
        switch self {
        case .selectTrack: return "Select Track"
        case .muteTrack: return "Mute Track"
        case .soloTrack: return "Solo Track"
        case .volumeTrack: return "Volume Track"
        case .panTrack: return "Pan Track"
        case .tempoDown: return "BPM −"
        case .tempoUp: return "BPM +"
        case .tapTempo: return "Tap Tempo"
        case .playStop: return "Play/Stop"
        case .pause: return "Pause"
        case .repeatPlayback: return "Repeat"
        case .subPlayStop: return "SubPlay/Stop"
        case .addTrack: return "Add Track"
        case .setlistUp: return "Setlist Up"
        case .setlistDown: return "Setlist Down"
        case .toggleAuto: return "Setlist Auto on/off"
        case .ignoreNext: return "Ignore Next"
        case .splitItems: return "Split stems"
        }
    }
    public var defaultKeyboard: ControlInput? {
        let command: UInt = 1 << 20, shift: UInt = 1 << 17
        let key: UInt16, modifiers: UInt, label: String
        switch self {
        case .selectTrack: (key, modifiers, label) = (17, command | shift, "⌘⇧T")
        case .muteTrack: (key, modifiers, label) = (46, 0, "M")
        case .soloTrack: (key, modifiers, label) = (1, shift, "⇧S")
        case .tempoDown: (key, modifiers, label) = (27, 0, "−")
        case .tempoUp: (key, modifiers, label) = (24, shift, "+")
        case .tapTempo: return nil
        case .playStop: (key, modifiers, label) = (49, 0, "Space")
        case .pause: return nil
        case .repeatPlayback: (key, modifiers, label) = (15, 0, "R")
        case .subPlayStop: (key, modifiers, label) = (36, 0, "Enter")
        case .addTrack: (key, modifiers, label) = (17, command, "⌘T")
        case .setlistUp: (key, modifiers, label) = (126, 0, "↑")
        case .setlistDown: (key, modifiers, label) = (125, 0, "↓")
        case .toggleAuto: return nil
        case .ignoreNext: (key, modifiers, label) = (29, 0, "0")
        case .splitItems: (key, modifiers, label) = (1, 0, "S")
        case .volumeTrack, .panTrack: return nil
        }
        return ControlInput(kind: "keyboard", label: label, key: key, modifiers: modifiers)
    }
}

public struct DAWActionBinding: Codable, Equatable, Identifiable {
    public var action: DAWAction
    /// nil uses the selected audio track, falling back to the first audio track.
    public var trackNumber: Int?
    public var keyboard: ControlInput?
    public var midi: ControlInput?
    public var id: String { action.rawValue }
    public init(action: DAWAction) { self.action = action; keyboard = action.defaultKeyboard }
    public func matches(_ input: ControlInput) -> Bool {
        if keyboard?.matches(input) == true || midi?.matches(input) == true { return true }
        guard input.kind == "keyboard", keyboard == action.defaultKeyboard else { return false }
        // Default aliases stop working as soon as the user changes that shortcut.
        switch action {
        case .addTrack: return input.key == 17 && input.modifiers == 1 << 18
        case .ignoreNext: return input.key == 82 && input.modifiers == 0
        case .subPlayStop: return input.key == 76 && input.modifiers == 0
        case .tempoUp: return input.key == 69 && input.modifiers == 0
        case .tempoDown: return input.key == 78 && input.modifiers == 0
        default: return false
        }
    }
}

public struct DAWActionBindings: Codable, Equatable {
    public private(set) var entries: [DAWActionBinding]
    public init(stored: [DAWActionBinding] = []) {
        entries = DAWAction.allCases.map { action in
            var binding = stored.first { $0.action == action } ?? DAWActionBinding(action: action)
            if action.fixedKeyboard { binding.keyboard = action.defaultKeyboard }
            if action.continuous { binding.keyboard = nil }
            return binding
        }
    }
    public func binding(_ action: DAWAction) -> DAWActionBinding { entries.first { $0.action == action }! }
    public func matching(_ input: ControlInput) -> DAWAction? { entries.first { $0.matches(input) }?.action }
    public mutating func setInput(_ input: ControlInput?, action: DAWAction, kind: String) {
        guard let index = entries.firstIndex(where: { $0.action == action }) else { return }
        if kind == "keyboard" { guard !action.fixedKeyboard && !action.continuous else { return }; entries[index].keyboard = input } else {
            guard !action.continuous || input == nil || (input?.kind == "midi" && input?.status == 0xb0) else { return }
            entries[index].midi = input
        }
    }
    public mutating func setTrack(_ number: Int?, action: DAWAction) {
        guard let index = entries.firstIndex(where: { $0.action == action }) else { return }
        entries[index].trackNumber = number.map { min(400, max(1, $0)) }
    }
    public mutating func reset(_ action: DAWAction) {
        if let index = entries.firstIndex(where: { $0.action == action }) { entries[index] = DAWActionBinding(action: action) }
    }
    public func conflict(_ input: ControlInput, excluding action: DAWAction) -> DAWAction? {
        entries.first { $0.action != action && $0.matches(input) }?.action
    }
}

public enum DAWActionValue {
    public static func pan(_ value: UInt8) -> Double {
        let clamped = min(127, value)
        return clamped < 64 ? Double(Int(clamped) - 64) / 64 : Double(Int(clamped) - 64) / 63
    }
}
