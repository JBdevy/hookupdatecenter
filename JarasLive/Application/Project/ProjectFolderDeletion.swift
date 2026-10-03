import Foundation

/// Captures the exact directory shown in the confirmation. Never follows a
/// document/directory alias or deletes a replacement created while it was open.
public struct ProjectFolderDeletion: Identifiable, Sendable {
    public let id = UUID()
    public let document: URL
    public let directory: URL
    public let deletesDirectory: Bool
    public var target: URL { deletesDirectory ? directory : document }
    private let directoryIdentity: String
    private let documentIdentity: String
    private let availableAt: TimeInterval
    public var remainingSeconds: Int { max(0, Int(ceil(availableAt - ProcessInfo.processInfo.systemUptime))) }

    public init(document: URL) throws {
        let document = document.standardizedFileURL
        guard document.isFileURL, document.pathExtension.lowercased() == "jl" else {
            throw ProjectError.invalid("Choose a CatLive project to delete.")
        }
        self.document = document
        directory = document.deletingLastPathComponent()
        deletesDirectory = try Self.canDeleteDirectory(document)
        _ = try ProjectDocumentCodec.decode(Data(contentsOf: document))
        directoryIdentity = try Self.identity(directory)
        documentIdentity = try Self.identity(document)
        availableAt = ProcessInfo.processInfo.systemUptime + 3
    }
    public func contains(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = target.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || (deletesDirectory && path.hasPrefix(root + "/"))
    }
    public func validate() throws {
        guard remainingSeconds == 0 else { throw ProjectError.invalid("Wait 3 seconds before deleting the project.") }
        let canDeleteDirectory = try Self.canDeleteDirectory(document)
        // Never broaden what was shown in the confirmation. A new sibling also
        // prevents a folder deletion planned before that sibling was created.
        guard !deletesDirectory || canDeleteDirectory else {
            throw ProjectError.invalid("The project folder changed. Open the confirmation again.")
        }
        guard try Self.identity(directory) == directoryIdentity,
              try Self.identity(document) == documentIdentity else {
            throw ProjectError.invalid("The project folder changed. Open the confirmation again.")
        }
    }
    public func remove() throws {
        try validate()
        try FileManager.default.removeItem(at: target)
    }
    private static func identity(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? ""):\(a[.creationDate] ?? "")"
    }
    private static func canDeleteDirectory(_ document: URL) throws -> Bool {
        let fm = FileManager.default, folder = document.deletingLastPathComponent()
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .volumeURLKey]
        let folderValues = try folder.resourceValues(forKeys: keys)
        let documentValues = try document.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        var protected = [home, fm.temporaryDirectory] + ["/", "/Users", "/Users/Shared", "/Volumes", "/Applications", "/Library", "/System", "/private", "/private/tmp", "/private/var"].map { URL(fileURLWithPath: $0) }
        for kind: FileManager.SearchPathDirectory in [.documentDirectory, .desktopDirectory, .downloadsDirectory, .musicDirectory, .moviesDirectory, .picturesDirectory, .libraryDirectory, .applicationSupportDirectory, .cachesDirectory] {
            protected += fm.urls(for: kind, in: .allDomainsMask)
        }
        if let volume = folderValues.volume { protected.append(volume) }
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              documentValues.isRegularFile == true, documentValues.isSymbolicLink != true else {
            throw ProjectError.invalid("This project is in a shared or system folder. Move it into its own folder before deleting it.")
        }
        let otherProjects = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension.lowercased() == "jl" && $0.standardizedFileURL != document }
        return !otherProjects &&
            !protected.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == canonical }) &&
            !home.path.hasPrefix(canonical.path + "/")
    }
}
