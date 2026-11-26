#if os(macOS)
import XCTest
@testable import JarasApplication

final class WindowsDAWImportParityTests: XCTestCase {
    // Imports the exact binary Logic and textual VS Hook/REAPER inputs that
    // Windows exercised, through the current Mac implementation.
    func testWindowsImportFixturesOnMac() throws {
        guard let path = ProcessInfo.processInfo.environment["CATLIVE_WINDOWS_IMPORT_FIXTURES"] else {
            throw XCTSkip("Set CATLIVE_WINDOWS_IMPORT_FIXTURES to the Windows import regression directory")
        }
        let root = URL(fileURLWithPath: path)
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity-cases.json"))) as? [[String: Any]])
        let output = root.appendingPathComponent("mac-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let input = root.appendingPathComponent(try XCTUnwrap(entry["source"] as? String))
            let succeeds = try XCTUnwrap(entry["success"] as? Bool)
            do {
                let result = try input.pathExtension == "logicx" ? LogicProjectImporter.read(input) : ReaperProjectImporter.read(input)
                XCTAssertTrue(succeeds, "Mac accepted an input rejected on Windows: \(name)")
                if succeeds { try JSONEncoder().encode(result.project).write(to: output.appendingPathComponent(name + ".json")) }
            } catch {
                if succeeds { XCTFail("Mac import failed for \(name): \(error)") }
            }
        }
    }
}
#endif
