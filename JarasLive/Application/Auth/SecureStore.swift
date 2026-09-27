import Foundation
import Security
public protocol SecureStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(_ key: String) throws
}
public struct KeychainStore: SecureStore {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ key: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] }
    public func read(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.status(status) }; return result as? Data
    }
    public func write(_ data: Data, key: String) throws {
        let q = query(key)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.status(status) }
    }
    public func delete(_ key: String) throws { let status = SecItemDelete(query(key) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.status(status) } }
}
public enum StoreError: LocalizedError { case status(OSStatus); public var errorDescription: String? { "Não foi possível acessar o armazenamento seguro." } }
public final class MemorySecureStore: SecureStore, @unchecked Sendable {
    private var data: [String: Data] = [:]; private let lock = NSLock()
    public init() {}
    public func read(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return data[key] }
    public func write(_ value: Data, key: String) { lock.lock(); defer { lock.unlock() }; data[key] = value }
    public func delete(_ key: String) { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: key) }
}
