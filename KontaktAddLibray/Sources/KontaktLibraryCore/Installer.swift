import Foundation

public struct ImportEntry: Codable, Identifiable {
    public var source: URL
    public var name: String
    public var fingerprint: String
    public var state: String = "pending"
    public var detail: String = "Aguardando"
    public var id: String { source.path }
    public init(_ library: Library) { source = library.source; name = library.name; fingerprint = library.fingerprint }
}
public struct ImportLibrary: Codable {
    public let library: Library
    public let contentDirectory: String
    public init(_ library: Library) throws {
        self.library = library
        contentDirectory = try library.contentDirectory()
    }
}
public struct ImportRequest: Codable {
    public let folder: URL
    public let libraries: [ImportLibrary]
    public init(folder: URL, libraries: [Library]) throws {
        self.folder = folder; self.libraries = try libraries.map(ImportLibrary.init)
    }
}
public struct ImportStatus: Codable {
    public var entries: [ImportEntry]
    public var finished: Bool
    public init(entries: [ImportEntry], finished: Bool = false) { self.entries = entries; self.finished = finished }
}

public struct LibraryInstaller {
    public let libraryRoot: URL
    public let backupRoot: URL
    public init(libraryRoot: URL = URL(fileURLWithPath: "/Library")) {
        self.libraryRoot = libraryRoot.resolvingSymlinksInPath()
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        self.backupRoot = self.libraryRoot.appendingPathComponent("Application Support/Kontakt Add Libray/Backups/\(date)-\(UUID().uuidString)")
    }
    private func directory(_ url: URL) throws {
        let fm = FileManager.default
        guard url.path.hasPrefix(libraryRoot.path + "/") else { throw LibraryFailure("Destino inválido.") }
        let relative = url.path.dropFirst(libraryRoot.path.count + 1)
        var current = libraryRoot
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if fm.fileExists(atPath: current.path) {
                guard try fm.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw LibraryFailure("O destino não é uma pasta regular: \(current.path)")
                }
            } else { try fm.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
        }
    }
    private func existing(_ path: URL) throws -> Data? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }
        guard try fm.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType == .typeRegular else {
            throw LibraryFailure("O registro existente não é um arquivo regular: \(path.lastPathComponent)")
        }
        return try Data(contentsOf: path)
    }
    public func install(_ library: Library, contentDirectory: String? = nil) throws {
        try Library.validateFileName(library.name); try Library.validateFileName(library.regKey)
        let preferences = libraryRoot.appendingPathComponent("Preferences")
        let service = libraryRoot.appendingPathComponent("Application Support/Native Instruments/Service Center")
        try directory(preferences); try directory(service)
        let plist = preferences.appendingPathComponent("com.native-instruments.\(library.regKey).plist")
        let xml = service.appendingPathComponent(library.name + ".xml")
        let oldPlist = try existing(plist), oldXML = try existing(xml)
        var values: [String: Any] = [:]
        if let oldPlist {
            guard let parsed = try PropertyListSerialization.propertyList(from: oldPlist, options: [], format: nil) as? [String: Any] else {
                throw LibraryFailure("O registro existente de \(library.name) não pôde ser lido; ele foi preservado.")
            }
            values = parsed
        }
        values.merge(try library.preferences(contentDirectory: contentDirectory)) { _, new in new }
        let encoded = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        if oldPlist != nil || oldXML != nil {
            let backup = backupRoot.appendingPathComponent(UUID().uuidString)
            try directory(backup)
            if let oldPlist { try oldPlist.write(to: backup.appendingPathComponent(plist.lastPathComponent), options: .atomic) }
            if let oldXML { try oldXML.write(to: backup.appendingPathComponent(xml.lastPathComponent), options: .atomic) }
        }
        do {
            try library.xml.write(to: xml, options: .atomic)
            try encoded.write(to: plist, options: .atomic)
            for path in [plist, xml] { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
        } catch {
            let failure = error
            // Roll back both records if any part of this library cannot commit.
            do {
                if let oldXML { try oldXML.write(to: xml, options: .atomic) }
                else if FileManager.default.fileExists(atPath: xml.path) { try FileManager.default.removeItem(at: xml) }
                if let oldPlist { try oldPlist.write(to: plist, options: .atomic) }
                else if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
            } catch { throw LibraryFailure("\(failure.localizedDescription) Falha ao restaurar o registro; o backup está em \(backupRoot.path).") }
            throw failure
        }
    }
}
