import Foundation

public enum InterfaceScale {
    public static let key = "jaras.interface.scale"
    // Retain compatibility with existing preferences, but never apply their
    // former custom zoom. System display scaling remains managed by the OS.
    public static let percentages = [100]
    public static func percent(_ value: Double) -> Int { 100 }
    public static func factor(_ value: Double) -> Double { 1 }
}
