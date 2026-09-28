import Foundation

public struct OutputPatch: Codable, Equatable, Hashable, Sendable {
    /// -2 = group, -1 = none, 0 = Master; hardware channels are one-based.
    public var firstChannel: Int
    public var channelCount: Int
    public static let none = OutputPatch(firstChannel: -1, channelCount: 2)
    public static let masterGroup = OutputPatch(firstChannel: -2, channelCount: 2)
    public static let master = OutputPatch(firstChannel: 0, channelCount: 2)
    public static let stereo = OutputPatch(firstChannel: 1, channelCount: 2)
    public var title: String { firstChannel == -2 ? "Master Group" : firstChannel == -1 ? "None" : firstChannel == 0 ? "Master" : channelCount == 2 ? "\(firstChannel)+\(firstChannel + 1)" : "\(firstChannel)" }
    public func validate(allowMaster: Bool, allowGroup: Bool = false, allowNone: Bool = false) throws {
        if firstChannel == -1 && allowNone && channelCount == 2 { return }
        if firstChannel == -2 && allowGroup && channelCount == 2 { return }
        guard (1...2).contains(channelCount), firstChannel >= (allowMaster ? 0 : 1), firstChannel <= 1024,
              firstChannel != 0 || channelCount == 2 else { throw ProjectError.invalid("Invalid output patch") }
    }
    public static func choices(channels: Int, includeMaster: Bool, includeGroup: Bool = false, includeNone: Bool = false) -> [OutputPatch] {
        var result: [OutputPatch] = includeNone ? [.none] : []
        if includeGroup { result.append(.masterGroup) }
        if includeMaster { result.append(.master) }
        guard channels > 0 else { return result }
        for first in stride(from: 1, through: channels, by: 2) {
            if first < channels { result.append(OutputPatch(firstChannel: first, channelCount: 2)) }
            result.append(OutputPatch(firstChannel: first, channelCount: 1))
            if first < channels { result.append(OutputPatch(firstChannel: first + 1, channelCount: 1)) }
        }
        return result
    }
}
