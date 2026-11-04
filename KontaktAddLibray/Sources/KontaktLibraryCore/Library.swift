import Foundation
import CryptoKit

public struct LibraryFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Library: Codable, Identifiable {
    public let source: URL
    public let name: String
    public let regKey: String
    public let xml: Data
    public let version: String?
    public var id: String { source.path }
    public var fingerprint: String { SHA256.hash(data: xml).map { String(format: "%02x", $0) }.joined() }

    public static func validateFileName(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 190,
              !value.contains("/"), !value.contains(":"), !value.contains("\\"),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LibraryFailure("Nome de biblioteca ou RegKey inválido: \(value)")
        }
    }

    /// Read only the embedded metadata, not the sample payload of a large NKX.
    public static func read(_ file: URL, cancelled: () -> Bool = { false }) throws -> Library {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let opening = Data("<ProductHints".utf8), closing = Data("</ProductHints>".utf8)
        var buffer = Data(), found = false, version: String?
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            if cancelled() { throw CancellationError() }
            if buffer.isEmpty && !found && file.pathExtension.lowercased() == "nicnt", chunk.count >= 76 {
                let value = String(decoding: chunk[66..<76].filter { $0 != 0 }, as: UTF8.self)
                if let range = value.range(of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                    version = String(value[range])
                }
            }
            buffer.append(chunk)
            if !found, let start = buffer.range(of: opening) { buffer = Data(buffer[start.lowerBound...]); found = true }
            if found, let end = buffer.range(of: closing) {
                return try parse(source: file, data: Data(buffer[..<end.upperBound]), version: version)
            }
            if found && buffer.count > 262144 { throw LibraryFailure("Metadados muito grandes: \(file.lastPathComponent)") }
            if !found { buffer = Data(buffer.suffix(opening.count)) }
        }
        throw LibraryFailure("Não foi encontrado um ProductHints completo em \(file.lastPathComponent).")
    }

    public static func parse(source: URL, data: Data, version: String? = nil) throws -> Library {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw LibraryFailure("O XML da biblioteca contém uma declaração externa não permitida.")
        }
        let document = try XMLDocument(data: data, options: [])
        guard document.rootElement()?.name == "ProductHints" else { throw LibraryFailure("ProductHints inválido.") }
        func value(_ key: String) -> String { (try? document.nodes(forXPath: "//" + key).first?.stringValue) ?? "" }
        let name = value("Name"), regKey = value("RegKey")
        try validateFileName(name); try validateFileName(regKey)
        // Preserve the metadata completion behavior of the supplied script.
        if value("HU").isEmpty && value("JDX").isEmpty {
            let product = (try? document.nodes(forXPath: "//SNPID").first?.parent as? XMLElement)
                ?? document.rootElement()?.elements(forName: "Product").first ?? document.rootElement()!
            let specific = (try? document.nodes(forXPath: "//ProductSpecific").first as? XMLElement) ?? XMLElement(name: "ProductSpecific")
            if specific.parent == nil { product.addChild(specific) }
            specific.addChild(XMLElement(name: "HU", stringValue: "6C70AC13E02414D1A552685A1301D859"))
            specific.addChild(XMLElement(name: "JDX", stringValue: "023733942B73318EAEAD914E3981EC68BE72519A2F5738F828A6A028C4E1DBAC"))
            if specific.elements(forName: "Visibility").isEmpty {
                let visibility = XMLElement(name: "Visibility", stringValue: "3")
                visibility.addAttribute(XMLNode.attribute(withName: "type", stringValue: "Number") as! XMLNode)
                specific.addChild(visibility)
            }
        }
        document.characterEncoding = "UTF-8"
        return Library(source: source, name: name, regKey: regKey, xml: document.xmlData(options: .nodePrettyPrint), version: version)
    }

    public func preferences(contentDirectory: String? = nil) throws -> [String: Any] {
        let document = try XMLDocument(data: xml, options: [])
        var result: [String: Any] = [:]
        for key in ["RegKey", "SNPID", "Name", "HU", "JDX", "UPID", "AuthSystem"] {
            if let value = try document.nodes(forXPath: "//" + key).first?.stringValue, !value.isEmpty { result[key] = value }
        }
        let visibility = try document.nodes(forXPath: "//ProductSpecific/Visibility").first?.stringValue ?? "3"
        guard let number = Int(visibility) else { throw LibraryFailure("Visibility inválido em \(name).") }
        result["Visibility"] = number
        if let version { result["ContentVersion"] = version }
        let path = try contentDirectory ?? self.contentDirectory()
        guard !path.isEmpty, !path.hasPrefix(":"), path.hasSuffix(":"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LibraryFailure("ContentDir inválido em \(name).")
        }
        result["ContentDir"] = path
        return result
    }

    /// Resolve the volume while running as the user who selected the folder.
    /// The authorized helper must not reopen files in protected user folders.
    public func contentDirectory() throws -> String {
        let folder = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let volume = try folder.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey])
        guard let root = (volume.allValues[.volumeURLKey] as? URL)?.standardizedFileURL,
              let name = volume.volumeName, !name.isEmpty else {
            throw LibraryFailure("Não foi possível determinar o caminho de \(name).")
        }
        let components = folder.standardizedFileURL.pathComponents
        let prefix = root.pathComponents
        guard components.starts(with: prefix) else {
            throw LibraryFailure("A pasta da biblioteca não pertence ao volume informado pelo macOS.")
        }
        // Kontakt's ContentDir uses a volume-qualified HFS path, including on APFS.
        // A colon in a POSIX filename is represented by a slash in that format.
        return ([name] + components.dropFirst(prefix.count))
            .map { $0.replacingOccurrences(of: ":", with: "/") }.joined(separator: ":") + ":"
    }
}

public struct ScanResult {
    public var libraries: [Library] = []
    public var errors: [String] = []
    public init() {}
}

public enum LibraryScanner {
    public static func scan(_ folder: URL, cancelled: () -> Bool = { false }, progress: (String) -> Void = { _ in }) throws -> ScanResult {
        let root = folder.resolvingSymlinksInPath()
        var result = ScanResult(), files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
            result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)"); return true
        }) else { throw LibraryFailure("Não foi possível abrir a pasta selecionada.") }
        for case let url as URL in enumerator {
            if cancelled() { throw CancellationError() }
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".nicnt") || name.hasSuffix("_info.nkx") else { continue }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isRegularFile == true && info.isSymbolicLink != true { files.append(url) }
        }
        let nicntFolders = Set(files.filter { $0.pathExtension.lowercased() == "nicnt" }.map { $0.deletingLastPathComponent() })
        files = files.filter { $0.pathExtension.lowercased() == "nicnt" || !nicntFolders.contains($0.deletingLastPathComponent()) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var keys = Set<String>(), names = Set<String>()
        for file in files {
            if cancelled() { throw CancellationError() }
            progress(file.deletingLastPathComponent().lastPathComponent)
            do {
                let library = try Library.read(file, cancelled: cancelled)
                guard !keys.contains(library.regKey.lowercased()), !names.contains(library.name.lowercased()) else {
                    throw LibraryFailure("Registro duplicado: \(library.name). A primeira biblioteca foi mantida.")
                }
                keys.insert(library.regKey.lowercased()); names.insert(library.name.lowercased())
                result.libraries.append(library)
            } catch is CancellationError { throw CancellationError() }
            catch { result.errors.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }
}
