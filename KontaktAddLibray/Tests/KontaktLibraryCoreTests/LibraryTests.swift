import XCTest
@testable import KontaktLibraryCore

final class LibraryTests: XCTestCase {
    var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }
    func fixture(_ path: String, name: String = "Metais &amp; Acordeão", key: String = "Metais", fields: String = "") throws -> URL {
        let file = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data(repeating: 0, count: 128)
        bytes.replaceSubrange(66..<71, with: Data("1.2.3".utf8))
        bytes.append(Data("<ProductHints><Product><Name>\(name)</Name><RegKey>\(key)</RegKey><SNPID>123</SNPID>\(fields)</Product></ProductHints>".utf8))
        bytes.append(Data([0, 255, 0, 127]))
        try bytes.write(to: file)
        return file
    }
    func testRecursiveScanPrefersNICNTAndContinuesAfterMalformedFile() throws {
        _ = try fixture("Nested/Metais/library.NICNT")
        _ = try fixture("Nested/Metais/library_info.nkx")
        try Data("invalid".utf8).write(to: temp.appendingPathComponent("bad.nicnt"))
        let result = try LibraryScanner.scan(temp)
        XCTAssertEqual(result.libraries.count, 1); XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.libraries.first?.name, "Metais & Acordeão")
        XCTAssertEqual(result.libraries.first?.version, "1.2.3")
    }
    func testPreservesOriginalMetadataAndCompletesMissingFields() throws {
        let source = try fixture("Library/library.nicnt", fields: "<ProductSpecific><HU>original</HU><JDX>original-jdx</JDX><Visibility type=\"Number\">2</Visibility></ProductSpecific>")
        let parsed = try Library.read(source)
        XCTAssertEqual(try parsed.preferences()["HU"] as? String, "original")
        XCTAssertEqual(try parsed.preferences()["Visibility"] as? Int, 2)
        let plain = try Library.read(fixture("Other/other.nicnt", key: "Other"))
        XCTAssertFalse((try plain.preferences()["HU"] as? String ?? "").isEmpty)
        XCTAssertEqual(try plain.preferences()["Visibility"] as? Int, 3)
        XCTAssertTrue((try plain.preferences()["ContentDir"] as? String ?? "").hasSuffix(":"))
    }
    func testDuplicateRegistryDoesNotOverwriteEarlierLibrary() throws {
        _ = try fixture("A/first.nicnt")
        _ = try fixture("B/second.nicnt", name: "Other", key: "metais")
        let result = try LibraryScanner.scan(temp)
        XCTAssertEqual(result.libraries.count, 1); XCTAssertEqual(result.errors.count, 1)
    }
    func testRejectsTraversalAndExternalEntities() throws {
        let file = try fixture("Bad/path.nicnt", key: "../../escape")
        XCTAssertThrowsError(try Library.read(file))
        let external = Data("<!DOCTYPE ProductHints [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><ProductHints><Name>&x;</Name><RegKey>test</RegKey></ProductHints>".utf8)
        XCTAssertThrowsError(try Library.parse(source: file, data: external))
    }
    func testInstallationPreservesSettingsAndBacksUpBothFiles() throws {
        let root = temp.appendingPathComponent("LibraryRoot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try fixture("Samples/O'Brien & Pads/library.nicnt", key: "O'Brien $Pads")
        let originalSource = try Data(contentsOf: source)
        let library = try Library.read(source)
        let installer = LibraryInstaller(libraryRoot: root)
        try installer.install(library)
        let plist = root.appendingPathComponent("Preferences/com.native-instruments.\(library.regKey).plist")
        var values = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        values["UserSetting"] = "keep"
        let original = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try original.write(to: plist)
        try installer.install(library)
        let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(current["UserSetting"] as? String, "keep")
        let files = FileManager.default.enumerator(at: installer.backupRoot, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertTrue(files.contains { $0.lastPathComponent == plist.lastPathComponent && (try? Data(contentsOf: $0)) == original })
        XCTAssertTrue(files.contains { $0.pathExtension == "xml" })
        XCTAssertEqual(try Data(contentsOf: source), originalSource)
    }
    func testSymlinkDestinationCannotRedirectWrites() throws {
        let root = temp.appendingPathComponent("Root"), outside = temp.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Preferences"), withDestinationURL: outside)
        let library = try Library.read(fixture("Samples/test.nicnt"))
        XCTAssertThrowsError(try LibraryInstaller(libraryRoot: root).install(library))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testCancelAndStableFingerprint() throws {
        let file = try fixture("test.nicnt")
        XCTAssertEqual(try Library.read(file).fingerprint, try Library.read(file).fingerprint)
        XCTAssertThrowsError(try LibraryScanner.scan(temp, cancelled: { true }))
        XCTAssertThrowsError(try Library.read(file, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testVolumeQualifiedPathWithSpecialCharacters() throws {
        let source = try fixture("Samples/Órgão:Studio/organ.nicnt")
        let library = try Library.read(source)
        let folder = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let volume = try folder.resourceValues(forKeys: [.volumeNameKey])
        let path = try XCTUnwrap(library.preferences()["ContentDir"] as? String)
        XCTAssertTrue(path.hasPrefix(try XCTUnwrap(volume.volumeName) + ":"))
        XCTAssertTrue(path.hasSuffix(":Samples:Órgão/Studio:"))
        XCTAssertFalse(path.hasPrefix(":"))
    }
    func testInvalidExistingRegistryIsPreserved() throws {
        let root = temp.appendingPathComponent("Root")
        let prefs = root.appendingPathComponent("Preferences")
        let service = root.appendingPathComponent("Application Support/Native Instruments/Service Center")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        let original = Data("invalid plist".utf8)
        let plist = prefs.appendingPathComponent("com.native-instruments.Metais.plist")
        let xml = service.appendingPathComponent("Metais & Acordeão.xml")
        try original.write(to: plist); try Data("keep".utf8).write(to: xml)
        let library = try Library.read(fixture("Samples/test.nicnt"))
        XCTAssertThrowsError(try LibraryInstaller(libraryRoot: root).install(library))
        XCTAssertEqual(try Data(contentsOf: plist), original)
        XCTAssertEqual(try String(contentsOf: xml), "keep")
    }
    func testAuthorizedInstallDoesNotReopenProtectedSourceFolder() throws {
        let source = try fixture("Protected Documents/Library/test.nicnt")
        let original = try Library.read(source)
        let request = try ImportRequest(folder: source.deletingLastPathComponent(), libraries: [original])
        let decoded = try JSONDecoder().decode(ImportRequest.self, from: JSONEncoder().encode(request))
        let payload = try XCTUnwrap(decoded.libraries.first)
        // Simulates the helper being unable to read the user's Documents directory.
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let root = temp.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let validated = try Library.parse(source: payload.library.source, data: payload.library.xml, version: payload.library.version)
        try LibraryInstaller(libraryRoot: root).install(validated, contentDirectory: payload.contentDirectory)
        let path = root.appendingPathComponent("Preferences/com.native-instruments.Metais.plist")
        let stored = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as! [String: Any]
        XCTAssertEqual(stored["ContentDir"] as? String, payload.contentDirectory)
        XCTAssertEqual(stored["ContentVersion"] as? String, "1.2.3")
        XCTAssertEqual(validated.name, original.name)
    }
}
