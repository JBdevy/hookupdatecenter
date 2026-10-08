import Foundation

public enum DAWAction: String, Codable, CaseIterable, Sendable {
    case selectTrack, muteTrack, soloTrack, volumeTrack, panTrack
    case muteMaster, soloMaster, volumeMaster
    case tempoDown, tempoUp, tapTempo, playStop, pause, repeatPlayback, subPlayStop, addTrack
    case setlistUp, setlistDown, toggleAuto, splitItems, ignoreNext
    case projectStart, projectEnd, nextRegion, previousRegion, nextTimelinePoint, previousTimelinePoint
    case toggleVideo, toggleTeleprompter, normalizeItems, createTempoMarker
    case toggleTracks, toggleSetlist, toggleMultiLoopBypass

    public static let visible = allCases
    public var needsTrack: Bool { [.selectTrack, .muteTrack, .soloTrack, .volumeTrack, .panTrack].contains(self) }
    public var continuous: Bool { self == .volumeTrack || self == .panTrack || self == .volumeMaster }
    public var supportsMIDI: Bool { self != .normalizeItems && self != .createTempoMarker }
    public var fixedKeyboard: Bool { self == .setlistUp || self == .setlistDown }
    public var repeats: Bool { [.tempoDown, .tempoUp, .nextRegion, .previousRegion, .nextTimelinePoint, .previousTimelinePoint].contains(self) }
    public var title: String {
        switch self {
        case .selectTrack: return "Select Track"
        case .muteTrack: return "Mute Track"
        case .soloTrack: return "Solo Track"
        case .volumeTrack: return "Volume Track"
        case .panTrack: return "Pan Track"
        case .muteMaster: return "Mute Master"
        case .soloMaster: return "Solo Master"
        case .volumeMaster: return "Volume Master"
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
        case .normalizeItems: return "Normalize selected items"
        case .createTempoMarker: return "Create tempo marker"
        case .projectStart: return "Go to project start"
        case .projectEnd: return "Go to project end"
        case .nextRegion: return "Go to next region"
        case .previousRegion: return "Go to previous region"
        case .nextTimelinePoint: return "Next marker or region boundary"
        case .previousTimelinePoint: return "Previous marker or region boundary"
        case .toggleVideo: return "Video window on/off"
        case .toggleTeleprompter: return "Teleprompter window on/off"
        case .toggleTracks: return "Tracks show/hide"
        case .toggleSetlist: return "Setlist show/hide"
        case .toggleMultiLoopBypass: return "Multiloops BYPASS on/off"
        }
    }
    public var defaultKeyboard: ControlInput? {
        let command: UInt = 1 << 20, shift: UInt = 1 << 17, option: UInt = 1 << 19
        let key: UInt16, modifiers: UInt, label: String
        switch self {
        case .selectTrack, .toggleMultiLoopBypass: return nil
        case .muteTrack: (key, modifiers, label) = (46, 0, "M")
        case .soloTrack: (key, modifiers, label) = (1, shift, "⇧S")
        case .tempoDown: (key, modifiers, label) = (27, 0, "−")
        case .tempoUp: (key, modifiers, label) = (24, shift, "+")
        case .tapTempo: return nil
        case .playStop: (key, modifiers, label) = (49, 0, "Space")
        case .pause: return nil
        case .repeatPlayback: (key, modifiers, label) = (15, 0, "R")
        case .subPlayStop: (key, modifiers, label) = (49, shift, "⇧Space")
        case .addTrack: (key, modifiers, label) = (17, command, "⌘T")
        case .setlistUp: (key, modifiers, label) = (126, 0, "↑")
        case .setlistDown: (key, modifiers, label) = (125, 0, "↓")
        case .toggleAuto: return nil
        case .ignoreNext: (key, modifiers, label) = (29, 0, "0")
        case .splitItems: (key, modifiers, label) = (1, 0, "S")
        case .normalizeItems: (key, modifiers, label) = (45, 0, "N")
        case .createTempoMarker: (key, modifiers, label) = (17, command | shift, "⌘⇧T")
        case .projectStart: (key, modifiers, label) = (12, 0, "Q")
        case .projectEnd: (key, modifiers, label) = (33, 0, "[")
        case .nextRegion: (key, modifiers, label) = (2, 0, "D")
        case .previousRegion: (key, modifiers, label) = (0, 0, "A")
        case .nextTimelinePoint: (key, modifiers, label) = (13, 0, "W")
        case .previousTimelinePoint: (key, modifiers, label) = (14, 0, "E")
        case .toggleVideo: (key, modifiers, label) = (9, option | shift, "⌥⇧V")
        case .toggleTeleprompter: (key, modifiers, label) = (17, option | shift, "⌥⇧T")
        case .toggleTracks: (key, modifiers, label) = (122, 0, "F1")
        case .toggleSetlist: (key, modifiers, label) = (120, 0, "F2")
        case .volumeTrack, .panTrack, .muteMaster, .soloMaster, .volumeMaster: return nil
        }
        return ControlInput(kind: "keyboard", label: label, key: key, modifiers: modifiers)
    }
    public static func quickMapping(command: String, master: Bool) -> Self? {
        switch command {
        case "mute": return master ? .muteMaster : .muteTrack
        case "solo": return master ? .soloMaster : .soloTrack
        case "volume": return master ? .volumeMaster : .volumeTrack
        case "pan": return master ? nil : .panTrack
        case "tempoUp": return .tempoUp
        case "tempoDown": return .tempoDown
        default: return nil
        }
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
        case .createTempoMarker: return input.key == 17 && input.modifiers == (1 << 18 | 1 << 17)
        case .ignoreNext: return input.key == 82 && input.modifiers == 0
        case .tempoUp: return input.key == 69 && input.modifiers == 0
        case .tempoDown: return input.key == 78 && input.modifiers == 0
        default: return false
        }
    }
}

public struct DAWActionBindings: Codable, Equatable {
    public private(set) var entries: [DAWActionBinding]
    public init(stored: [DAWActionBinding] = []) {
        var stored = stored
        if let index = stored.firstIndex(where: { $0.action == .selectTrack }),
           stored[index].keyboard?.key == 17, stored[index].keyboard?.modifiers == (1 << 20 | 1 << 17) {
            stored[index].keyboard = nil
        }
        let oldSubPlayDefault = ControlInput(kind: "keyboard", label: "Enter", key: 36, modifiers: 0)
        if let index = stored.firstIndex(where: { $0.action == .subPlayStop }),
           stored[index].keyboard == oldSubPlayDefault, let replacement = DAWAction.subPlayStop.defaultKeyboard,
           !stored.contains(where: { $0.action != .subPlayStop && $0.matches(replacement) }) {
            // Move the old default only when the replacement is free. Keep
            // custom/unbound shortcuts and both bindings when a conflict exists.
            stored[index].keyboard = replacement
        }
        entries = DAWAction.allCases.map { action in
            var binding = stored.first { $0.action == action } ?? DAWActionBinding(action: action)
            if action.fixedKeyboard { binding.keyboard = action.defaultKeyboard }
            if action.continuous { binding.keyboard = nil }
            if !action.supportsMIDI { binding.midi = nil }
            // Existing global shortcuts take precedence over defaults introduced
            // in a later version of the action list.
            if !stored.contains(where: { $0.action == action }), let input = binding.keyboard,
               stored.contains(where: { $0.action != action && $0.matches(input) }) {
                binding.keyboard = nil
            }
            return binding
        }
    }
    public func binding(_ action: DAWAction) -> DAWActionBinding { entries.first { $0.action == action }! }
    public func matching(_ input: ControlInput) -> DAWAction? { entries.first { $0.matches(input) }?.action }
    @discardableResult public mutating func setInput(_ input: ControlInput?, action: DAWAction, kind: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.action == action }), input == nil || conflict(input!, excluding: action) == nil else { return false }
        if kind == "keyboard" { guard !action.fixedKeyboard && !action.continuous else { return false }; entries[index].keyboard = input } else {
            guard action.supportsMIDI, !action.continuous || input == nil || (input?.kind == "midi" && input?.status == 0xb0) else { return false }
            entries[index].midi = input
        }
        return true
    }
    @discardableResult public mutating func transferInput(_ input: ControlInput, action: DAWAction, kind: String) -> Bool {
        guard input.kind == kind,
              kind != "keyboard" || (!action.fixedKeyboard && !action.continuous),
              kind != "midi" || (action.supportsMIDI && (!action.continuous || input.status == 0xb0)) else { return false }
        let conflicts = entries.filter { $0.action != action && $0.matches(input) }
        guard kind != "keyboard" || !conflicts.contains(where: { $0.action.fixedKeyboard }) else { return false }
        for conflict in conflicts { setInput(nil, action: conflict.action, kind: kind) }
        return setInput(input, action: action, kind: kind)
    }
    public mutating func setTrack(_ number: Int?, action: DAWAction) {
        guard let index = entries.firstIndex(where: { $0.action == action }) else { return }
        entries[index].trackNumber = number.map { max(1, $0) }
    }
    public mutating func reset(_ action: DAWAction, kind: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.action == action }) else { return }
        if kind != "midi", let input = action.defaultKeyboard, conflict(input, excluding: action) != nil { return }
        if kind == "keyboard" { entries[index].keyboard = action.defaultKeyboard }
        else if kind == "midi" { entries[index].midi = nil }
        else { entries[index] = DAWActionBinding(action: action) }
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
