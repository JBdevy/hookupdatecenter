import Foundation

public enum DAWAction: String, Codable, CaseIterable, Sendable {
    case saveProject, toggleFullscreen
    case previousProjectTab, nextProjectTab
    case transportFadeout
    case selectTrack, muteTrack, soloTrack, volumeTrack, panTrack
    case trackVolumeDown, trackVolumeUp, trackPanLeft, trackPanRight
    case muteMaster, soloMaster, volumeMaster
    case tempoDown, tempoUp, tapTempo, playStop, play, stop, pause, repeatPlayback, subPlayStop, subPlay, addTrack
    case tunerDown, tunerUp, partsUp, partsDown, parts1, parts2, toggleParts, cancelSection
    case setlistUp, setlistDown, toggleAuto, splitItems, ignoreNext
    case projectStart, projectEnd, nextRegion, previousRegion, nextTimelinePoint, previousTimelinePoint
    case toggleVideo, toggleTeleprompter, togglePreview, normalizeItems, reRenderItems, unifyAudioItems, createRegionsFromItems, createTempoMarker
    case toggleFocus, toggleLibrary, toggleSelectedInputMonitor, toggleSelectedStripFXBypass, toggleSessionFXBypass
    case toggleTracks, toggleBarMixer, toggleSetlist, toggleMultiLoopBypass
    case insertElasticPoint

    public var legacyTransportMapping: Bool { self == .play || self == .stop || self == .subPlay }
    public static var visible: [Self] {
        #if os(iOS)
        return allCases.filter { !$0.legacyTransportMapping && $0 != .toggleFullscreen }
        #else
        return allCases.filter { !$0.legacyTransportMapping }
        #endif
    }
    public var needsTrack: Bool { [.selectTrack, .muteTrack, .soloTrack, .volumeTrack, .panTrack, .trackVolumeDown, .trackVolumeUp, .trackPanLeft, .trackPanRight].contains(self) }
    public var continuous: Bool { self == .volumeTrack || self == .panTrack || self == .volumeMaster }
    public var keyboardTrackAdjustment: Bool { [.trackVolumeDown, .trackVolumeUp, .trackPanLeft, .trackPanRight].contains(self) }
    public var supportsMIDI: Bool { !keyboardTrackAdjustment && ![.normalizeItems, .reRenderItems, .unifyAudioItems, .createRegionsFromItems, .createTempoMarker, .toggleFullscreen, .insertElasticPoint].contains(self) }
    public var fixedKeyboard: Bool { self == .setlistUp || self == .setlistDown }
    public var repeats: Bool { keyboardTrackAdjustment || [.tempoDown, .tempoUp, .nextRegion, .previousRegion, .nextTimelinePoint, .previousTimelinePoint].contains(self) }
    public var title: String {
        switch self {
        case .saveProject: return "Salvar projeto"
        case .toggleFullscreen: return "Toggle fullscreen"
        case .previousProjectTab: return "Previous project tab"
        case .nextProjectTab: return "Next project tab"
        case .transportFadeout: return "Fadeout"
        case .selectTrack: return "Select Track"
        case .muteTrack: return "Mute Track"
        case .soloTrack: return "Solo Track"
        case .volumeTrack: return "Volume Track"
        case .panTrack: return "Pan Track"
        case .trackVolumeDown: return "Track volume down"
        case .trackVolumeUp: return "Track volume up"
        case .trackPanLeft: return "Track pan left"
        case .trackPanRight: return "Track pan right"
        case .muteMaster: return "Mute Master"
        case .soloMaster: return "Solo Master"
        case .volumeMaster: return "Volume Master"
        case .tempoDown: return "BPM −"
        case .tempoUp: return "BPM +"
        case .tapTempo: return "Tap Tempo"
        case .play: return "Play"
        case .stop: return "Stop"
        case .subPlay: return "Sub Play"
        case .tunerDown: return "Tuner −"
        case .tunerUp: return "Tuner +"
        case .partsUp: return "Parts Up"
        case .partsDown: return "Parts Down"
        case .parts1: return "Parts 1"
        case .parts2: return "Parts 2"
        case .toggleParts: return "Parts show/hide"
        case .cancelSection: return "Cancel queued section"
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
        case .reRenderItems: return "Re-render selected items"
        case .unifyAudioItems: return "Unify selected audio items"
        case .createRegionsFromItems: return "Create region from selected items"
        case .createTempoMarker: return "Create tempo marker"
        case .insertElasticPoint: return "Insert Elastic Point"
        case .projectStart: return "Go to project start"
        case .projectEnd: return "Go to project end"
        case .nextRegion: return "Go to next region"
        case .previousRegion: return "Go to previous region"
        case .nextTimelinePoint: return "Next marker or region boundary"
        case .previousTimelinePoint: return "Previous marker or region boundary"
        case .togglePreview: return "Preview on/off"
        case .toggleVideo: return "Video window on/off"
        case .toggleTeleprompter: return "Teleprompter window on/off"
        case .toggleFocus: return "Track - I show/hide"
        case .toggleLibrary: return "Library show/hide"
        case .toggleSelectedInputMonitor: return "Input Monitor · Selected track"
        case .toggleSelectedStripFXBypass: return "By All Fx · Selected track"
        case .toggleSessionFXBypass: return "By Fx Session"
        case .toggleTracks: return "Track Mixer show/hide"
        case .toggleBarMixer: return "Hoz-Mixer show/hide"
        case .toggleSetlist: return "Setlist show/hide"
        case .toggleMultiLoopBypass: return "Multiloops BYPASS on/off"
        }
    }
    public var defaultKeyboard: ControlInput? {
        let command: UInt = 1 << 20, shift: UInt = 1 << 17, option: UInt = 1 << 19
        let key: UInt16, modifiers: UInt, label: String
        switch self {
        case .toggleFocus, .toggleLibrary, .toggleSelectedInputMonitor, .toggleSelectedStripFXBypass, .toggleSessionFXBypass, .togglePreview, .previousProjectTab, .nextProjectTab, .transportFadeout, .selectTrack, .toggleMultiLoopBypass, .play, .stop, .subPlay, .tunerDown, .tunerUp, .partsUp, .partsDown, .parts1, .parts2, .toggleParts, .cancelSection, .reRenderItems, .unifyAudioItems: return nil
        case .saveProject: (key, modifiers, label) = (1, command, "⌘S")
        case .toggleFullscreen: (key, modifiers, label) = (103, command, "⌘F11")
        case .muteTrack: (key, modifiers, label) = (46, 0, "M")
        case .soloTrack: (key, modifiers, label) = (1, shift, "⇧S")
        case .tempoDown: (key, modifiers, label) = (27, 0, "−")
        case .tempoUp: (key, modifiers, label) = (24, shift, "+")
        case .tapTempo: return nil
        case .playStop: (key, modifiers, label) = (49, 0, "Space")
        case .pause: (key, modifiers, label) = (49, option, "⌥Space")
        case .repeatPlayback: (key, modifiers, label) = (15, 0, "R")
        case .subPlayStop: (key, modifiers, label) = (49, shift, "⇧Space")
        case .addTrack: (key, modifiers, label) = (17, command, "⌘T")
        case .setlistUp: (key, modifiers, label) = (126, 0, "↑")
        case .setlistDown: (key, modifiers, label) = (125, 0, "↓")
        case .toggleAuto: return nil
        case .ignoreNext: (key, modifiers, label) = (29, 0, "0")
        case .splitItems: (key, modifiers, label) = (1, 0, "S")
        case .normalizeItems: (key, modifiers, label) = (45, 0, "N")
        case .createRegionsFromItems: (key, modifiers, label) = (15, shift, "⇧R")
        case .createTempoMarker: (key, modifiers, label) = (17, command | shift, "⌘⇧T")
        case .insertElasticPoint: (key, modifiers, label) = (14, option | shift, "⌥⇧E")
        case .projectStart: (key, modifiers, label) = (12, 0, "Q")
        case .projectEnd: (key, modifiers, label) = (33, 0, "[")
        case .nextRegion: (key, modifiers, label) = (2, 0, "D")
        case .previousRegion: (key, modifiers, label) = (0, 0, "A")
        case .nextTimelinePoint: (key, modifiers, label) = (13, 0, "W")
        case .previousTimelinePoint: (key, modifiers, label) = (14, 0, "E")
        case .toggleVideo: (key, modifiers, label) = (9, option | shift, "⌥⇧V")
        case .toggleTeleprompter: (key, modifiers, label) = (17, option | shift, "⌥⇧T")
        case .toggleTracks: (key, modifiers, label) = (17, option, "⌥T")
        case .toggleBarMixer: (key, modifiers, label) = (4, option, "⌥H")
        case .toggleSetlist: (key, modifiers, label) = (1, option, "⌥S")
        case .volumeTrack, .panTrack, .trackVolumeDown, .trackVolumeUp, .trackPanLeft, .trackPanRight, .muteMaster, .soloMaster, .volumeMaster: return nil
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

/// An explicit tab request, separate from transport and setlist selection.
/// Its identity lets views ignore replays while accepting repeated mappings.
public struct PartsTabSelectionRequest: Equatable, Sendable {
    public let id = UUID()
    public let secondary: Bool
    public let panel: SMK37Navigation.Panel?
    public init(secondary: Bool, panel: SMK37Navigation.Panel? = nil) { self.secondary = secondary; self.panel = panel }
}

public struct DAWActionBinding: Codable, Equatable, Identifiable {
    public var action: DAWAction
    /// A nil target uses the selected track. A number targets a mixer position.
    public var trackNumber: Int?
    public var keyboard: ControlInput?
    public var midi: ControlInput?
    public var id: String { trackNumber.map { action.rawValue + ":" + String($0) } ?? action.rawValue }
    public init(action: DAWAction, trackNumber: Int? = nil) {
        self.action = action; self.trackNumber = trackNumber
        keyboard = trackNumber == nil ? action.defaultKeyboard : nil
    }
    public func matches(_ input: ControlInput) -> Bool {
        if keyboard?.matches(input) == true || midi?.matches(input) == true { return true }
        guard trackNumber == nil, input.kind == "keyboard", keyboard == action.defaultKeyboard else { return false }
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
        // Retain the combined binding first; otherwise move the old Play/Stop
        // (or Sub Play) input to its toggle. Legacy cases remain decodable only.
        for (target, sources) in [(DAWAction.playStop, [DAWAction.play, .stop]), (.subPlayStop, [.subPlay])] {
            var binding = stored.first { $0.action == target } ?? DAWActionBinding(action: target)
            for source in sources {
                guard let old = stored.first(where: { $0.action == source }) else { continue }
                if binding.midi == nil { binding.midi = old.midi }
                if binding.keyboard == nil { binding.keyboard = old.keyboard }
            }
            if stored.contains(where: { sources.contains($0.action) }) {
                stored.removeAll { sources.contains($0.action) || $0.action == target }
                stored.append(binding)
            }
        }
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
        // Upgrade the previous panel defaults without replacing custom mappings.
        for (action, oldKey, oldModifiers) in [(DAWAction.toggleTracks, UInt16(122), UInt(0)), (.toggleSetlist, 120, 0), (.toggleBarMixer, 11, 1 << 19)] {
            if let index = stored.firstIndex(where: { $0.action == action }),
               stored[index].keyboard?.key == oldKey, stored[index].keyboard?.modifiers == oldModifiers,
               let replacement = action.defaultKeyboard,
               !stored.contains(where: { $0.action != action && $0.matches(replacement) }) {
                stored[index].keyboard = replacement
            }
        }
        entries = DAWAction.allCases.map { action in
            var binding = stored.first { $0.action == action && (!action.needsTrack || $0.trackNumber == nil) } ?? DAWActionBinding(action: action)
            if action.fixedKeyboard { binding.keyboard = action.defaultKeyboard }
            if action.continuous { binding.keyboard = nil }
            if !action.supportsMIDI { binding.midi = nil }
            // Existing global shortcuts take precedence over defaults introduced
            // in a later version of the action list.
            if !stored.contains(where: { $0.action == action && (!action.needsTrack || $0.trackNumber == nil) }), let input = binding.keyboard,
               stored.contains(where: { $0.id != binding.id && $0.matches(input) }) {
                binding.keyboard = nil
            }
            return binding
        }
        for var binding in stored where binding.action.needsTrack && (binding.trackNumber ?? 0) > 0 {
            if binding.action.continuous { binding.keyboard = nil }
            if !entries.contains(where: { $0.id == binding.id }) { entries.append(binding) }
        }
        if let index = entries.firstIndex(where: { $0.action == .transportFadeout }), let input = entries[index].keyboard,
           Self.reservedForFadeout(input) || entries.contains(where: { $0.action != .transportFadeout && $0.matches(input) }) {
            entries[index].keyboard = nil
        }
    }
    /// Fadeout never takes over a standard editing/transport shortcut, even
    /// when that shortcut has been reassigned in Actions.
    public static func reservedForFadeout(_ input: ControlInput) -> Bool {
        guard input.kind == "keyboard", let key = input.key else { return false }
        if key == 49 { return true }
        if DAWAction.allCases.filter({ $0 != .transportFadeout }).contains(where: { DAWActionBinding(action: $0).matches(input) }) { return true }
        let flags = input.modifiers ?? 0
        let command: UInt = 1 << 20, control: UInt = 1 << 18, shift: UInt = 1 << 17, option: UInt = 1 << 19
        if (flags == command || flags == control || flags == command | shift || flags == control | shift),
           [0,1,2,4,6,7,8,9,12,13,17,31,35,45,43,44,46].contains(key) { return true }
        if flags == 0, [36,48,51,53,76,115,116,117,119,121,123,124,125,126].contains(key) { return true }
        if flags == shift && [15, 46].contains(key) { return true }
        if key == 46 && flags == option { return true }
        if key == 3 && flags == command | control { return true }
        if key == 4 && flags == command | option { return true }
        return false
    }
    public func binding(_ action: DAWAction, trackNumber: Int? = nil) -> DAWActionBinding {
        let target = DAWActionBinding(action: action, trackNumber: trackNumber)
        return entries.first { $0.action == action && (!action.needsTrack || $0.trackNumber == trackNumber) } ?? target
    }
    public func matchingBinding(_ input: ControlInput) -> DAWActionBinding? { entries.first { $0.matches(input) } }
    public func matching(_ input: ControlInput) -> DAWAction? { matchingBinding(input)?.action }
    @discardableResult public mutating func setInput(_ input: ControlInput?, action: DAWAction, kind: String, trackNumber: Int? = nil) -> Bool {
        guard !action.legacyTransportMapping, trackNumber.map({ action.needsTrack && $0 > 0 }) ?? true,
              input == nil || conflict(input!, excluding: action, trackNumber: trackNumber) == nil else { return false }
        if action == .transportFadeout, let input, Self.reservedForFadeout(input) { return false }
        var binding = binding(action, trackNumber: trackNumber)
        if kind == "keyboard" {
            guard !action.fixedKeyboard && !action.continuous else { return false }
            binding.keyboard = input
        } else {
            guard action.supportsMIDI, !action.continuous || input == nil || (input?.kind == "midi" && input?.status == 0xb0) else { return false }
            binding.midi = input
        }
        if let index = entries.firstIndex(where: { $0.id == binding.id }) {
            if trackNumber != nil && binding.keyboard == nil && binding.midi == nil { entries.remove(at: index) }
            else { entries[index] = binding }
        } else if input != nil { entries.append(binding) }
        return true
    }
    @discardableResult public mutating func transferInput(_ input: ControlInput, action: DAWAction, kind: String, trackNumber: Int? = nil) -> Bool {
        guard input.kind == kind,
              kind != "keyboard" || (!action.fixedKeyboard && !action.continuous),
              kind != "midi" || (action.supportsMIDI && (!action.continuous || input.status == 0xb0)) else { return false }
        let id = binding(action, trackNumber: trackNumber).id
        let conflicts = entries.filter { $0.id != id && $0.matches(input) }
        if action == .transportFadeout, kind == "keyboard", Self.reservedForFadeout(input) || !conflicts.isEmpty { return false }
        guard kind != "keyboard" || !conflicts.contains(where: { $0.action.fixedKeyboard }) else { return false }
        for conflict in conflicts { setInput(nil, action: conflict.action, kind: kind, trackNumber: conflict.trackNumber) }
        return setInput(input, action: action, kind: kind, trackNumber: trackNumber)
    }
    public mutating func reset(_ action: DAWAction, kind: String? = nil, trackNumber: Int? = nil) {
        if kind != "midi" { setInput(trackNumber == nil ? action.defaultKeyboard : nil, action: action, kind: "keyboard", trackNumber: trackNumber) }
        if kind != "keyboard" { setInput(nil, action: action, kind: "midi", trackNumber: trackNumber) }
    }
    public func conflict(_ input: ControlInput, excluding action: DAWAction, trackNumber: Int? = nil) -> DAWAction? {
        let id = binding(action, trackNumber: trackNumber).id
        return entries.first { $0.id != id && $0.matches(input) }?.action
    }

}
public enum DAWActionValue {
    public static func pan(_ value: UInt8) -> Double {
        let clamped = min(127, value)
        return clamped < 64 ? Double(Int(clamped) - 64) / 64 : Double(Int(clamped) - 64) / 63
    }
}

/// Shared action organization; iPad exposes performance controls, desktop also
/// exposes the editing shortcuts used with a keyboard.
public enum DAWActionCategory: String, CaseIterable, Identifiable {
    case transport = "Transport", volume = "Volume", mute = "Mute", solo = "Solo", setlist = "Setlist", shortcuts = "Shortcuts"
    public var id: String { rawValue }
    public var actions: [DAWAction] { DAWAction.visible.filter { $0.category == self } }
}
extension DAWAction {
    public var category: DAWActionCategory {
        switch self {
        case .transportFadeout, .playStop, .play, .stop, .pause, .subPlay, .subPlayStop, .repeatPlayback, .tempoDown, .tempoUp, .tapTempo, .tunerDown, .tunerUp: return .transport
        case .volumeMaster, .volumeTrack, .panTrack, .trackVolumeDown, .trackVolumeUp, .trackPanLeft, .trackPanRight: return .volume
        case .muteMaster, .muteTrack: return .mute
        case .soloMaster, .soloTrack: return .solo
        case .setlistUp, .setlistDown, .toggleAuto, .ignoreNext, .toggleSetlist, .toggleMultiLoopBypass, .partsUp, .partsDown, .parts1, .parts2, .toggleParts, .cancelSection: return .setlist
        default: return .shortcuts
        }
    }
}

public enum ProjectTabNavigation {
    public static func destination(current: Int, count: Int, direction: Int) -> Int? {
        guard count > 1, current >= 0, current < count, direction != 0 else { return nil }
        let next = current + (direction < 0 ? -1 : 1)
        return (0..<count).contains(next) ? next : nil
    }
}
