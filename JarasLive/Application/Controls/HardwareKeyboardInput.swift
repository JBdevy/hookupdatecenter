import Foundation

/// Uses the same bits as the persisted desktop keyboard bindings. UIKit's
/// caps-lock/numeric-pad flags must not change which Action a key matches.
public struct HardwareKeyboardModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue & Self.supportedBits }
    private static let supportedBits: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
    public static let shift = Self(rawValue: 1 << 17)
    public static let control = Self(rawValue: 1 << 18)
    public static let option = Self(rawValue: 1 << 19)
    public static let command = Self(rawValue: 1 << 20)
    public var label: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

public struct HardwareKeyboardEvent: Equatable, Sendable {
    public enum Phase: Sendable { case down, up }
    public var keyCode: UInt16
    public var modifiers: HardwareKeyboardModifiers
    public var characters: String
    public var isRepeat: Bool
    public var phase: Phase
    public init(keyCode: UInt16, modifiers: HardwareKeyboardModifiers = [], characters: String = "",
                isRepeat: Bool = false, phase: Phase = .down) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.characters = characters
        self.isRepeat = isRepeat; self.phase = phase
    }
    public var isModifier: Bool { [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(keyCode) }
    public var input: ControlInput {
        let name = HardwareKeyboardInput.keyLabel(keyCode) ??
            (characters.isEmpty ? "Key \(keyCode)" : characters.uppercased())
        return ControlInput(kind: "keyboard", label: modifiers.label + name,
                            key: keyCode, modifiers: modifiers.rawValue)
    }
}

/// Kept independent of UIKit so the same guard can be tested without a device.
public struct HardwareKeyboardFocusContext {
    public var enabled: Bool
    public var applicationActive: Bool
    public var textEditing: Bool
    public var modalPresented: Bool
    public var learningMapping: Bool
    public var transferringMapping: Bool
    public init(enabled: Bool = true, applicationActive: Bool = true, textEditing: Bool = false,
                modalPresented: Bool = false, learningMapping: Bool = false, transferringMapping: Bool = false) {
        self.enabled = enabled; self.applicationActive = applicationActive; self.textEditing = textEditing
        self.modalPresented = modalPresented; self.learningMapping = learningMapping
        self.transferringMapping = transferringMapping
    }
    public var permitsShortcuts: Bool {
        enabled && applicationActive && !textEditing && !transferringMapping &&
            (!modalPresented || learningMapping)
    }
}

public enum HardwareKeyboardInput {
    /// USB HID usage -> macOS virtual key code. Bindings are physical, just as
    /// on the desktop; localized characters are used only for the learn label.
    public static func keyCode(hidUsage: Int) -> UInt16? {
        switch hidUsage {
        case 0x04...0x1d:
            return [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
                    45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6][hidUsage - 0x04]
        case 0x1e...0x27: return [18, 19, 20, 21, 23, 22, 26, 28, 25, 29][hidUsage - 0x1e]
        case 0x28...0x39:
            return [36, 53, 51, 48, 49, 27, 24, 33, 30, 42, 42, 41, 39, 50, 43, 47, 44, 57][hidUsage - 0x28]
        case 0x3a...0x45: return [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][hidUsage - 0x3a]
        case 0x46...0x52: return [105, 107, 113, 114, 115, 116, 117, 119, 121, 124, 123, 125, 126][hidUsage - 0x46]
        case 0x53...0x64: return [71, 75, 67, 78, 69, 76, 83, 84, 85, 86, 87, 88, 89, 91, 92, 82, 65, 10][hidUsage - 0x53]
        case 0x67: return 81
        case 0x68...0x6f: return [105, 107, 113, 106, 64, 79, 80, 90][hidUsage - 0x68]
        case 0x87: return 93 // JIS underscore
        case 0x89: return 94 // JIS yen
        case 0x90: return 104 // JIS kana
        case 0x91: return 102 // JIS eisu
        case 0xe0...0xe7: return [59, 56, 58, 55, 62, 60, 61, 54][hidUsage - 0xe0]
        default: return nil
        }
    }
    public static func event(hidUsage: Int, modifierFlags: UInt, characters: String = "",
                             isRepeat: Bool = false, phase: HardwareKeyboardEvent.Phase = .down) -> HardwareKeyboardEvent? {
        guard let code = keyCode(hidUsage: hidUsage) else { return nil }
        return HardwareKeyboardEvent(keyCode: code, modifiers: .init(rawValue: modifierFlags),
                                     characters: characters, isRepeat: isRepeat, phase: phase)
    }
    public static func keyLabel(_ code: UInt16) -> String? {
        switch code {
        case 36, 76: return "Enter"
        case 49: return "Space"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "Delete"
        case 117: return "Forward Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 114: return "Insert"
        default:
            let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
            return functionCodes.firstIndex(of: code).map { "F\($0 + 1)" }
        }
    }
}
