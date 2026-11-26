#if os(macOS)
import SwiftUI
import AppKit

@MainActor final class SMK37FirmwareTask: ObservableObject {
    static let shared = SMK37FirmwareTask()
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var error = ""
    @Published private(set) var savedURL: URL?
    @Published private(set) var logURL: URL?

    func start(_ operation: SMK37FirmwareFlow.Operation, destination: URL) {
        guard !busy else { return }
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("SMK37"),
              let helper = Bundle.main.resourceURL?.appendingPathComponent("SMK37Tools/M-Flasher"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            error = NSLocalizedString("The SMK firmware utility is missing. Reinstall CatLive.", comment: "")
            return
        }
        busy = true; error = ""; message = "Preparing firmware backup…"; savedURL = nil
        SMK37Link.shared.setFirmwareMaintenance(true)
        let work = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatLive/SMK37/" + UUID().uuidString, isDirectory: true)
        let log = work.appendingPathComponent("operation.log")
        logURL = log
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let writer = try FileHandle(forWritingTo: log)
                defer { try? writer.close() }
                let runner: SMK37FirmwareFlow.Runner = { arguments in
                    let process = Process(), pipe = Pipe()
                    process.executableURL = helper; process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe; process.standardError = pipe
                    try process.run()
                    // Drain while the helper runs; no UI/audio-thread waits or
                    // timeout that could kill a flash write halfway through.
                    var output = Data()
                    while true {
                        let bytes = pipe.fileHandleForReading.availableData
                        if bytes.isEmpty { break }
                        output.append(bytes)
                        // A full log disk must not abandon a running flash write.
                        try? writer.write(contentsOf: bytes)
                    }
                    process.waitUntilExit()
                    let text = String(decoding: output, as: UTF8.self)
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                        throw SMK37FirmwareError(text.isEmpty ? "The SMK firmware utility failed." : String(text.suffix(2400)))
                    }
                    return text
                }
                let flow = SMK37FirmwareFlow(resources: resources, work: work, run: runner, status: { value in
                    DispatchQueue.main.async { self.message = value }
                })
                try flow.execute(operation, backupURL: destination)
            } catch { failure = error.localizedDescription }
            let finishedError = failure
            DispatchQueue.main.async {
                self.busy = false
                SMK37Link.shared.setFirmwareMaintenance(false)
                self.error = finishedError ?? ""
                self.message = finishedError == nil ? "Operation completed. The firmware backup is saved." : "Operation stopped. See the details below."
                if (try? SMK37FirmwareBackup.read(destination)) != nil { self.savedURL = destination }
            }
        }
    }
}

struct SMK37FirmwareView: View {
    let isLocked: () -> Bool
    private var locked: Bool { isLocked() }
    @ObservedObject private var task = SMK37FirmwareTask.shared
    @State private var choosing = false
    private var disabled: Bool { locked || task.busy || choosing }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect one SMK-37 Pro using a USB data cable. Firmware operations are unavailable during playback or recording.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
            Button("Backup Firmware SMK-37 Pro") { chooseDestination(.backup) }
                .disabled(disabled)
            Button("Install SMK Integration") { confirm(.install) }
                .disabled(disabled)
            Button("Install Backup/Firmware…") { chooseSource() }
                .disabled(disabled)
            Text("Choose where to save your backup. Installing firmware first saves and verifies the current firmware at the location you select. Keep the USB cable connected until the operation finishes.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            Text("Supported files: .smkbackup, .fwsc, and full .bin backups with their matching .json file. Only compatible SMK-37 Pro firmware is accepted.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            if task.busy { ProgressView().controlSize(.small) }
            if !task.message.isEmpty { Text(LocalizedStringKey(task.message)).font(.jarasCallout) }
            if !task.error.isEmpty {
                Text(verbatim: task.error).font(.jarasCaption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let url = task.savedURL {
                Button("Show saved backup") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let url = task.logURL, !task.busy {
                Button("Show operation log") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Firmware licenses and source") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("SMK37") { NSWorkspace.shared.open(url) }
            }.font(.jarasCaption)
        }
    }
    private func confirm(_ operation: SMK37FirmwareFlow.Operation) {
        guard !disabled, let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Install firmware on SMK-37 Pro?", comment: "")
        alert.informativeText = NSLocalizedString("This replaces the keyboard firmware and can change its controls, sounds and settings. Choose where to save the current firmware backup before continuing.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        choosing = true
        alert.beginSheetModal(for: window) { reply in
            choosing = false
            if reply == .alertFirstButtonReturn { chooseDestination(operation) }
        }
    }
    private func chooseSource() {
        guard !disabled, let window = NSApp.keyWindow else { return }
        let picker = NSOpenPanel()
        picker.title = NSLocalizedString("Install Backup/Firmware…", comment: "")
        picker.allowedFileTypes = ["smkbackup", "fwsc", "bin"]
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false
        choosing = true
        picker.beginSheetModal(for: window) { reply in
            choosing = false
            if reply == .OK, let url = picker.url { confirm(.installFile(url)) }
        }
    }
    private func chooseDestination(_ operation: SMK37FirmwareFlow.Operation) {
        guard !disabled, let window = NSApp.keyWindow else { return }
        let picker = NSSavePanel()
        picker.title = NSLocalizedString("Save current firmware backup", comment: "")
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd-HHmmss"
        picker.nameFieldStringValue = "SMK37-Pro-Backup-" + date.string(from: Date()) + ".smkbackup"
        picker.allowedFileTypes = ["smkbackup"]; picker.canCreateDirectories = true
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        choosing = true
        picker.beginSheetModal(for: window) { reply in
            choosing = false
            if reply == .OK, let url = picker.url, !locked { task.start(operation, destination: url) }
        }
    }
}
#endif
