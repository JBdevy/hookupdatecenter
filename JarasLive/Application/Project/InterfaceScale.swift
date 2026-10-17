import Foundation

public enum InterfaceScale {
    public static let key = "jaras.interface.scale"
    public static let percentages = Array(stride(from: 60, through: 120, by: 10))
    public static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 100 }
        return Int((min(1.2, max(0.6, value)) * 10).rounded()) * 10
    }
    public static func factor(_ value: Double) -> Double { Double(percent(value)) / 100 }
}
