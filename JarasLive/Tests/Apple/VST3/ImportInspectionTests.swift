// Appended by test-reaper-vst3-import.sh to the actual import resolver source.
let pluginURL = URL(fileURLWithPath: CommandLine.arguments[1])
let ownExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-import-resolver-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let ini = scratch.appendingPathComponent("reaper.ini")
try "[REAPER]\nvstpath_arm64=\(pluginURL.deletingLastPathComponent().path)\n".write(to: ini, atomically: true, encoding: .utf8)
let session = ReaperVST3ImportSession(executable: ownExecutable, catalog: [], paths: [], reaperConfiguration: ini)
var source = ExternalPlugin(classID: "1234123456785678ABCDEF0012345678", name: "Gain fixture", path: "GainFixture.vst3", category: "Fx")
source.componentState = "SOE6PwAAAAAAAAAA"; source.controllerState = source.componentState
let resolved = try session.resolve(.init(plugin: source, parameterIndices: [0, 1]))
precondition(resolved?.plugin.path == pluginURL.standardizedFileURL.path, "uncatalogued VST3 must be found in REAPER's configured directory: \(String(describing: resolved?.plugin.path)) expected \(pluginURL.standardizedFileURL.path)")
precondition(resolved?.parameterIDs == [0: 0, 1: 1])
precondition(resolved?.plugin.componentState == source.componentState)
precondition(session.discovered.contains { $0.classID == source.classID && $0.path == pluginURL.standardizedFileURL.path })
let input = scratch.appendingPathComponent("input.json"), output = scratch.appendingPathComponent("output.json")
var spec = source; spec.path = pluginURL.path
var dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as! [String: Any]
dictionary["strictImportState"] = true
try JSONSerialization.data(withJSONObject: dictionary).write(to: input)
let child = Process(); child.executableURL = ownExecutable
child.arguments = ["--inspect-vst3", input.path, output.path]
try child.run(); child.waitUntilExit()
precondition(child.terminationStatus == 0)
let report = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
let parameters = report["parameters"] as! [[String: Any]]
precondition(abs((parameters[0]["value"] as! Double) - 0.73) < 0.000001, "restored REAPER preset must reach the plugin")
source.componentState = "AQ=="
do { _ = try session.resolve(.init(plugin: source)); fatalError("truncated processor state must not silently load the default preset") }
catch ProjectError.invalid(let message) { precondition(message.contains("rejected the imported processor state")) }
print("REAPER VST3 discovery, preset restoration, ParamID mapping and rejected-state handling passed")
