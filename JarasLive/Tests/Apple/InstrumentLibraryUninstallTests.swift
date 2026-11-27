import Foundation

@MainActor func run() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("CatLive-instrument-uninstall-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let library = InstrumentLibrary(directory: root.appendingPathComponent("Library"))
    let project = root.appendingPathComponent("Project", isDirectory: true)
    let bundled = project.appendingPathComponent("Instruments/astoria-grand.sf2")
    try fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("RIFF0000sfbk".utf8)
    try bytes.write(to: library.file("astoria-grand"))
    try bytes.write(to: bundled)
    library.setProjectDirectory(project)
    precondition(library.installed.contains("astoria-grand") && library.downloaded.contains("astoria-grand"))
    library.uninstall("astoria-grand")
    precondition(!library.installed.contains("astoria-grand"))
    precondition(library.downloaded.contains("astoria-grand"), "Portable project must remain usable")
    let preserved = try Data(contentsOf: bundled)
    precondition(preserved == bytes, "Uninstall must preserve the project's SF2")
    library.setProjectDirectory(nil)
    precondition(!library.downloaded.contains("astoria-grand"), "Library selection must update immediately")
    library.uninstall("astoria-grand") // Already removed is harmless.
    let outside = root.appendingPathComponent("outside.sf2")
    try bytes.write(to: outside)
    library.uninstall("../outside")
    precondition(fm.fileExists(atPath: outside.path), "Uninstall accepts only catalog identities")
    try bytes.write(to: library.file("astoria-grand"))
    library.refresh()
    precondition(library.installed.contains("astoria-grand") && library.downloaded.contains("astoria-grand"), "Reinstallation becomes available")
    print("INSTRUMENT_UNINSTALL_PRESERVES_PROJECT_AND_REFRESHES_CATALOG_OK")

    let users = library.directory.appendingPathComponent("User", isDirectory: true)
    let banks = bundled.deletingLastPathComponent()
    try fm.createDirectory(at: users, withIntermediateDirectories: true)
    let sharedID = "user-UGlhbm8" // Piano
    let projectID = "user-QmFzcw" // Bass
    let sharedFile = sharedID + ".sf2"
    try bytes.write(to: users.appendingPathComponent(sharedFile))
    try bytes.write(to: banks.appendingPathComponent(sharedFile))
    try bytes.write(to: banks.appendingPathComponent(projectID + ".sf2"))
    let mixedCaseBank = library.directory.appendingPathComponent("BrIGht-GrAnd.SF2")
    try bytes.write(to: mixedCaseBank)
    try fm.createSymbolicLink(at: library.file("c7-grand"), withDestinationURL: outside)
    try fm.createSymbolicLink(at: library.file("cfx-premium"), withDestinationURL: root.appendingPathComponent("missing.sf2"))
    library.setProjectDirectory(project)
    precondition(Set(library.imported.map(\.id)) == [sharedID, projectID])
    precondition(library.installed.contains(sharedID) && !library.installed.contains(projectID))
    precondition(library.downloaded.contains(sharedID) && library.downloaded.contains(projectID))
    precondition(library.resolvedFile(sharedID, projectDirectory: project) == banks.appendingPathComponent(sharedFile))
    precondition(library.installed.contains("bright-grand") == fm.fileExists(atPath: library.file("bright-grand").path))
    precondition(library.installed.contains("c7-grand") && !library.installed.contains("cfx-premium"))
    try fm.removeItem(at: banks.appendingPathComponent(sharedFile))
    library.refresh()
    precondition(library.resolvedFile(sharedID, projectDirectory: project) == users.appendingPathComponent(sharedFile))
    try fm.setAttributes([.posixPermissions: 0o111], ofItemAtPath: library.directory.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.directory.path) }
    library.refresh()
    precondition(library.installed.contains("astoria-grand"), "An unlistable directory still resolves a known bank")
    print("INSTRUMENT_REFRESH_CASE_SYMLINKS_PROJECT_PRECEDENCE_AND_SEARCH_ONLY_DIRECTORY_OK")
}
DispatchQueue.main.async { do { try run(); exit(0) } catch { print(error); exit(1) } }
RunLoop.main.run()
