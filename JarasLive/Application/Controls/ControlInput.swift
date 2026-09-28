import Foundation

public struct ControlInput: Codable, Equatable {
    public var kind: String
    public var label: String
    public var key: UInt16?
    public var modifiers: UInt?
    public var device: Int32?
    public var channel: UInt8?
    public var status: UInt8?
    public var number: UInt8?
    public init(kind: String, label: String, key: UInt16? = nil, modifiers: UInt? = nil, device: Int32? = nil, channel: UInt8? = nil, status: UInt8? = nil, number: UInt8? = nil) {
        self.kind = kind; self.label = label; self.key = key; self.modifiers = modifiers
        self.device = device; self.channel = channel; self.status = status; self.number = number
    }
    public func matches(_ other: ControlInput) -> Bool {
        kind == other.kind && key == other.key && modifiers == other.modifiers && device == other.device && channel == other.channel && status == other.status && number == other.number
    }
}
