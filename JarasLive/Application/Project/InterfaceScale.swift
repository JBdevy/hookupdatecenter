import Foundation

public enum InterfaceScale {
    public static let key = "jaras.interface.scale"
    public static let percentages = [75, 100, 125]
    public static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 100 }
        return Int((min(1.25, max(0.75, value)) * 4).rounded()) * 25
    }
    public static func factor(_ value: Double) -> Double { Double(percent(value)) / 100 }
}
