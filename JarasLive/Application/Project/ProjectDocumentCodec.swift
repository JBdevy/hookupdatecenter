import Foundation
import CryptoKit

/// Each CatLive document owns its media and backup directory exclusively.
public enum ProjectDirectoryPolicy {
    public static func validate(_ document: URL) throws {
        guard document.pathExtension.lowercased() == "jl" else { return }
        let fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        guard fm.fileExists(atPath: folder.path) else { return }
        let others = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension.lowercased() == "jl" && $0.standardizedFileURL != document.standardizedFileURL }
        guard !others else {
            throw ProjectError.invalid("This folder already contains another CatLive project. Choose or create a separate folder so Stems and backups are not shared.")
        }
    }
}
/// Portable application document protection, not a user-password vault.
/// The application key is shared by installations so projects remain transferable.
public enum ProjectDocumentCodec {
    private static let header = Data([0x4a, 0x41, 0x52, 0x41, 0x53, 0x4a, 0x4c, 0x00, 0x01])
    private static let key = SymmetricKey(data: Data([0xce, 0x9a, 0x3a, 0xb3, 0xab, 0x54, 0x63, 0x22, 0x5a, 0x93, 0xd8, 0x65, 0xdd, 0xe0, 0x49, 0xce, 0x38, 0x56, 0xde, 0x29, 0x9a, 0x12, 0x29, 0x44, 0x07, 0x41, 0xf7, 0x37, 0x0f, 0x49, 0x69, 0xfd]))

    public static func encode(_ project: Project) throws -> Data {
        try project.validate()
        let plaintext = try JSONEncoder().encode(project)
        // CryptoKit generates a fresh random nonce on every save.
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let sealed = box.combined else { throw ProjectError.invalid("Unable to encrypt project") }
        return header + sealed
    }
    public static func decode(_ data: Data) throws -> Project {
        let plaintext: Data
        if data.starts(with: header) {
            do {
                let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(header.count)))
                plaintext = try AES.GCM.open(box, using: key, authenticating: header)
            } catch { throw ProjectError.invalid("Project is damaged or could not be decrypted.") }
        } else if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 {
            // Read existing development documents; all subsequent writes are encrypted.
            plaintext = data
        } else { throw ProjectError.invalid("Invalid or unsupported .jl project.") }
        var project = try JSONDecoder().decode(Project.self, from: plaintext)
        project.promoteLoopSectionMarkers()
        try project.validate()
        return project
    }
    public static func writeEncoded(_ data: Data, to url: URL, exclusive: Bool = false) throws {
        try ProjectDirectoryPolicy.validate(url)
        try data.write(to: url, options: exclusive ? .withoutOverwriting : .atomic)
        ProjectDocumentAppearance.apply(to: url)
    }
    public static func write(_ project: Project, to url: URL, exclusive: Bool = false) throws {
        try writeEncoded(encode(project), to: url, exclusive: exclusive)
    }
}
