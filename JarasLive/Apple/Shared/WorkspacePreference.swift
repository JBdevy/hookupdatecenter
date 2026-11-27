import SwiftUI
import Combine

#if os(macOS)
/// AppStorage invalidates every reader of a defaults suite on some macOS
/// versions. Workspace roots subscribe to the value of their own key instead.
@MainActor private protocol DesktopPreferenceObserver: AnyObject {
    func refresh()
}

@MainActor private final class DesktopPreferenceEntry<Value: Hashable>: ObservableObject, DesktopPreferenceObserver {
    @Published private(set) var value: Value
    private let read: () -> Value
    private let write: (Value) -> Void

    init(read: @escaping () -> Value, write: @escaping (Value) -> Void) {
        self.read = read
        self.write = write
        value = read()
    }

    func refresh() {
        let latest = read()
        if value != latest { value = latest }
    }

    func save(_ newValue: Value) {
        write(newValue)
        refresh()
    }
}

@MainActor private final class DesktopPreferenceCache {
    static let shared = DesktopPreferenceCache()
    private struct Key: Hashable {
        let domain: ObjectIdentifier
        let name: String
        let type: ObjectIdentifier
        let fallback: AnyHashable
    }
    private var entries: [Key: DesktopPreferenceObserver] = [:]

    private init() {
        for name in [UserDefaults.didChangeNotification, NSApplication.didBecomeActiveNotification] {
            // Defaults notifications can arrive on the writer's thread.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refresh() }
                } else {
                    DispatchQueue.main.async { self?.refresh() }
                }
            }
        }
    }

    private func refresh() {
        // Separate UserDefaults instances can address the same suite. Read each
        // unique workspace setting once, regardless of how many rows display it.
        for entry in entries.values { entry.refresh() }
    }

    func entry<Value: Hashable>(for key: String, store: UserDefaults, fallback: Value,
                                decode: @escaping (UserDefaults, String) -> Value?, encode: @escaping (Value) -> Any) -> DesktopPreferenceEntry<Value> {
        let identity = Key(domain: ObjectIdentifier(store), name: key, type: ObjectIdentifier(Value.self), fallback: AnyHashable(fallback))
        if let cached = entries[identity] as? DesktopPreferenceEntry<Value> { return cached }
        let entry = DesktopPreferenceEntry(read: { decode(store, key) ?? fallback },
                                           write: { store.set(encode($0), forKey: key) })
        entries[identity] = entry
        return entry
    }
}

@MainActor @propertyWrapper struct WorkspacePreference<Value: Hashable>: DynamicProperty {
    @ObservedObject private var entry: DesktopPreferenceEntry<Value>

    private init(_ fallback: Value, _ key: String, _ store: UserDefaults,
                 read: @escaping (UserDefaults, String) -> Value?, write: @escaping (Value) -> Any) {
        entry = DesktopPreferenceCache.shared.entry(for: key, store: store, fallback: fallback, decode: read, encode: write)
    }

    // Use the same typed conversions as AppStorage for older defaults written
    // as integers or strings. Missing values keep the declaring view's fallback.
    private init(_ fallback: Value, _ key: String, _ store: UserDefaults,
                 scalar: @escaping (UserDefaults, String) -> Value) {
        self.init(fallback, key, store, read: { $0.object(forKey: $1) == nil ? nil : scalar($0, $1) }, write: { $0 })
    }

    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value == Double {
        self.init(wrappedValue, key, store, scalar: { $0.double(forKey: $1) })
    }
    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value == Bool {
        self.init(wrappedValue, key, store, scalar: { $0.bool(forKey: $1) })
    }
    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value == Int {
        self.init(wrappedValue, key, store, scalar: { $0.integer(forKey: $1) })
    }
    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value == String {
        self.init(wrappedValue, key, store, read: { $0.string(forKey: $1) }, write: { $0 })
    }
    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value == Data {
        self.init(wrappedValue, key, store, read: { $0.data(forKey: $1) }, write: { $0 })
    }

    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value: RawRepresentable, Value.RawValue == String {
        self.init(wrappedValue, key, store, read: { $0.string(forKey: $1).flatMap(Value.init(rawValue:)) }, write: { $0.rawValue })
    }

    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) where Value: RawRepresentable, Value.RawValue == Int {
        self.init(wrappedValue, key, store, read: { store, key in
            guard store.object(forKey: key) != nil else { return nil }
            return Value(rawValue: store.integer(forKey: key))
        }, write: { $0.rawValue })
    }

    var wrappedValue: Value {
        get { entry.value }
        nonmutating set { entry.save(newValue) }
    }

    var projectedValue: Binding<Value> { Binding(get: { entry.value }, set: { entry.save($0) }) }
    var values: AnyPublisher<Value, Never> { entry.$value.eraseToAnyPublisher() }
}
#else
typealias WorkspacePreference<Value> = AppStorage<Value>
#endif
