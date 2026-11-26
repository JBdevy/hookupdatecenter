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
}
DispatchQueue.main.async { do { try run(); exit(0) } catch { print(error); exit(1) } }
RunLoop.main.run()
