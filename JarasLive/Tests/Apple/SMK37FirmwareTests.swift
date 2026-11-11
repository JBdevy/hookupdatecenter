import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection") } catch {}
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("smk-firmware-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let flash = Data(repeating: 0x5a, count: 1_048_576)
let metadata = ["model":"SMK-37 Pro / Elite", "firmware":"SMK-37 Pro 016 (stock)", "unit id":"TEST-UNIT", "sha256":SMK37FirmwareBackup.hash(flash)]
let backup = try SMK37FirmwareBackup(flash: flash, metadata: metadata)
let saved = root.appendingPathComponent("backup com espaços.smkbackup")
try backup.save(saved)
expect(try! SMK37FirmwareBackup.read(saved).flash == flash, "Backup round trip")
var damaged = metadata; damaged["sha256"] = String(repeating:"0",count:64)
rejects { _ = try SMK37FirmwareBackup(flash: flash, metadata: damaged) }
rejects { _ = try SMK37FirmwareBackup(flash: flash.dropLast(), metadata: metadata) }

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let package = try Data(contentsOf: resources.appendingPathComponent("SMK37-CatLive.fwsc"))
try SMK37FirmwareFlow.validatePackageModel(package)
rejects { try SMK37FirmwareFlow.validatePackageModel(Data(repeating: 0, count: 8192)) }
var wrongModel = package
let identity = Array("SMK-37 Elite_016".utf8)
for i in 0..<32 { wrongModel[i * 48 + 47] = i < identity.count ? identity[i] &+ UInt8(i+1) : 0x7d }
rejects { try SMK37FirmwareFlow.validatePackageModel(wrongModel) }

func exercise(_ operation: SMK37FirmwareFlow.Operation, corrupt: Bool = false, failBackup: Bool = false,
              multiple: Bool = false, refuseWrite: Bool = false, expectedFailure: Bool = false) throws -> [[String]] {
    let work = root.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent(UUID().uuidString + ".smkbackup")
    var commands = [[String]](); var downloaded = false
    let flow = SMK37FirmwareFlow(resources: resources, work: work, run: { args in
        commands.append(args)
        switch args[0] {
        case "--version": return "0.11.0\n"
        case "find":
            if multiple { return "usb1\tdisk\nusb2\tdisk\n" }
            return downloaded ? "usb1\tWL82 UBOOT\n" : "midi\tSMK-37 Pro (running)\n"
        case "download-mode": downloaded = true; return ""
        case "backup":
            if failBackup { throw SMK37FirmwareError("Cancelled authorization") }
            try flash.write(to: work.appendingPathComponent("read.bin"))
            try JSONEncoder().encode(corrupt ? damaged : metadata).write(to: work.appendingPathComponent("read.json"))
            return ""
        case "firmware", "restore":
            expect(FileManager.default.fileExists(atPath: destination.path), "Write started before saved backup")
            expect(try! SMK37FirmwareBackup.read(destination).flash == flash, "Write started before verified backup")
            expect(args.contains("--device") && args.contains("usb1"), "Write did not pin the selected device")
            expect(!args.contains("--board") && !args.contains("--with-bootloader"), "Installer forced board or bootloader")
            if refuseWrite { throw SMK37FirmwareError("Write verification failed") }
            return ""
        case "restart": return ""
        default: fatalError("Unexpected command")
        }
    }, status: { _ in })
    if expectedFailure { rejects { try flow.execute(operation, backupURL: destination) } }
    else { try flow.execute(operation, backupURL: destination) }
    if corrupt || failBackup || multiple {
        expect(!commands.contains { ["firmware","restore"].contains($0[0]) }, "Failed backup allowed a write")
    }
    return commands
}
let onlyBackup = try exercise(.backup)
expect(!onlyBackup.contains { $0[0] == "firmware" || $0[0] == "restore" }, "Backup changed flash")
_ = try exercise(.install)
_ = try exercise(.installFile(resources.appendingPathComponent("SMK37-CatLive.fwsc")))
_ = try exercise(.installFile(saved))
_ = try exercise(.install, corrupt: true, expectedFailure: true)
_ = try exercise(.install, failBackup: true, expectedFailure: true)
_ = try exercise(.install, multiple: true, expectedFailure: true)
_ = try exercise(.install, refuseWrite: true, expectedFailure: true)
var other = metadata; other["unit id"] = "OTHER-UNIT"
let otherFile = root.appendingPathComponent("other.smkbackup")
try SMK37FirmwareBackup(flash:flash,metadata:other).save(otherFile)
let refused = try exercise(.installFile(otherFile), expectedFailure:true)
expect(!refused.contains { $0[0] == "restore" }, "Restored a different unit backup")
if CommandLine.arguments.count > 2 {
    try backup.save(URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("SMK firmware: backup integrity, destinations, package models, installation/restore ordering and failures passed")
