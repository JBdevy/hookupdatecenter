import AppKit
import ApplicationServices

// This separate process triggers SwiftUI's lazy AX tree, which local queries
// leave empty even in the baseline. CI without AX permission skips this check.
guard AXIsProcessTrusted() else { print("FOOTER_EXTERNAL_AX_SKIPPED_NOT_AUTHORIZED"); exit(77) }
let application = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 40 else { return [] }
    return [element] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { descendants($0, depth: depth + 1) }
}
func elements() -> [AXUIElement] {
    (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap { descendants($0) }
}
func text(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(element, $0) as? String }.joined(separator: " ")
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("\(message)\n".utf8)); exit(1) }
func waitFor(_ expected: String) {
    for _ in 0..<100 {
        if elements().contains(where: { text($0).contains(expected) }) { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
    fail("Missing external AX element: \(expected)")
}
func press(_ expected: String) {
    waitFor(expected)
    guard let element = elements().first(where: { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains(expected) }),
          AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { fail("AX press failed: \(expected)") }
    Thread.sleep(forTimeInterval: 0.06)
}
waitFor("Baseline CPU")
for label in ["Native CPU", "Native Audio Settings", "Playlist duration", "Next song label", "Queued", "Native FX", "Native Edit track", "Native Locale pt_BR"] { waitFor(label) }
press("Native FX"); press("Native Edit track"); press("Native Audio Settings")
press("Refresh callbacks")
press("Native FX"); press("Native Edit track")
press("Prepare resize")
for label in ["Native CPU", "Native Audio Settings", "Playlist duration", "Native FX", "Native Edit track"] { waitFor(label) }
press("Verify and close")
print("FOOTER_EXTERNAL_AX_BASELINE_NATIVE_DISPLAY_MIXER_ACTIONS_AND_POST_RESIZE_TREE_OK")
