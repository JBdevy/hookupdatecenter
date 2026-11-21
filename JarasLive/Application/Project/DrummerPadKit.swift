import Foundation

public enum DrummerPadKind: String, CaseIterable, Sendable {
    case compact = "Drummer Pad 16", full = "Drummer Pad 48"
    public var count: Int { self == .compact ? 16 : 48 }
    public var columns: Int { self == .compact ? 4 : 8 }
}
public struct DrumPadSlot: Codable, Equatable, Sendable {
    public var name: String
    public var sample: String?
    public var note: Int?
    public var volume: Double = 1
    public init(index: Int) { name = ""; note = 36 + index }
}
public struct DrummerPadKit: Codable, Equatable, Sendable {
    public var pads: [DrumPadSlot]
    public var volume: Double = 1
    public init(_ kind: DrummerPadKind) { pads = (0..<kind.count).map(DrumPadSlot.init) }
    public mutating func map(note: Int, to index: Int) {
        guard pads.indices.contains(index), (0...127).contains(note) else { return }
        for i in pads.indices where pads[i].note == note { pads[i].note = nil }
        pads[index].note = note
    }
    public func validate(_ kind: DrummerPadKind) throws {
        let notes = pads.compactMap(\.note)
        guard (0...1).contains(volume), pads.count == kind.count, Set(notes).count == notes.count,
              notes.allSatisfy({ (0...127).contains($0) }),
              pads.allSatisfy({ (0...1).contains($0.volume) && ($0.sample.map(Self.validSample) ?? true) }) else {
            throw ProjectError.invalid("Invalid Drummer Pad kit")
        }
    }
    public static func validSample(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        return ["Native","User","Pads"].contains(parts.first ?? "") && parts.count >= 2 &&
            !path.contains("\\") && !path.contains(":") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
