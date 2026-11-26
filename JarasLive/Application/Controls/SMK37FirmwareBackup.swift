#if os(macOS)
import Foundation
import CryptoKit

/// Portable, single-file backup. The flash image and the upstream verification
/// metadata travel together, including the device ID and its original checksum.
struct SMK37FirmwareBackup: Codable {
    let format: String
    let version: Int
    let metadata: [String: String]
    let flash: Data

    init(flash: Data, metadata: [String: String]) throws {
        self.format = "CatLive SMK37 Backup"
        self.version = 1
        self.flash = flash
        self.metadata = metadata
        try validate()
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard format == "CatLive SMK37 Backup", version == 1, flash.count == 1_048_576,
              metadata["model"] == "SMK-37 Pro / Elite",
              metadata["sha256"] == Self.hash(flash),
              let unit = metadata["unit id"], !unit.isEmpty, unit != "–" else {
            throw SMK37FirmwareError("Invalid or damaged SMK backup.")
        }
    }
    func requirePro() throws {
        guard metadata["firmware"]?.hasPrefix("SMK-37 Pro ") == true else {
            throw SMK37FirmwareError("The connected firmware could not be identified as SMK-37 Pro. Nothing was installed.")
        }
    }
    static func read(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else {
            throw SMK37FirmwareError("Invalid or damaged SMK backup.")
        }
        let value: Self
        if url.pathExtension.lowercased() == "bin" {
            let metadata = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
            value = try Self(flash: Data(contentsOf: url), metadata: metadata)
        } else {
            value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
        try value.validate()
        return value
    }
    func save(_ url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        let reread = try Self.read(url)
        guard reread.flash == flash, reread.metadata == metadata else {
            throw SMK37FirmwareError("The saved backup could not be verified.")
        }
    }
}

struct SMK37FirmwareError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { NSLocalizedString(message, comment: "SMK firmware") }
}

/// Runs off the UI/audio threads. All commands use argument arrays, never a
/// shell. A fake runner exercises failure paths without touching a USB device.
struct SMK37FirmwareFlow {
    enum Operation { case backup, install, installFile(URL) }
    typealias Runner = ([String]) throws -> String
    let resources: URL
    let work: URL
    let run: Runner
    let status: (String) -> Void

    func execute(_ operation: Operation, backupURL: URL) throws {
        let fm = FileManager.default
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("manifest.json"))) as? [String: Any]
        var package = resources.appendingPathComponent("SMK37-CatLive.fwsc")
        guard manifest?["schema"] as? Int == 1, manifest?["model"] as? String == "SMK-37 Pro",
              manifest?["sha256"] as? String == SMK37FirmwareBackup.hash(try Data(contentsOf: package)) else {
            throw SMK37FirmwareError("The bundled SMK firmware is missing or damaged.")
        }
        var restoring: SMK37FirmwareBackup?
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        if case .installFile(let source) = operation {
            guard source.standardizedFileURL != backupURL.standardizedFileURL else {
                throw SMK37FirmwareError("Choose a different file for the current firmware backup.")
            }
            if source.pathExtension.lowercased() == "fwsc" {
                let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
                try Self.validatePackageModel(bytes)
                package = work.appendingPathComponent("selected.fwsc")
                try bytes.write(to: package, options: .withoutOverwriting)
            } else {
                restoring = try .read(source)
            }
        }
        guard try run(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0.11.0" else {
            throw SMK37FirmwareError("The SMK firmware utility is not compatible.")
        }
        // Check the destination before putting the keyboard in download mode.
        let probe = backupURL.deletingLastPathComponent().appendingPathComponent(".catlive-smk-" + UUID().uuidString)
        try Data().write(to: probe, options: .withoutOverwriting)
        try fm.removeItem(at: probe)
        let found = try endpoints(run(["find"]))
        guard found.count == 1 else { throw SMK37FirmwareError("Connect only one SMK-37 Pro using a USB data cable.") }
        if found[0].hasPrefix("midi\t") {
            guard found[0].localizedCaseInsensitiveContains("smk"), !found[0].localizedCaseInsensitiveContains("elite") else {
                throw SMK37FirmwareError("Connect only one SMK-37 Pro using a USB data cable.")
            }
            status("Connecting to SMK-37 Pro…")
            _ = try run(["download-mode"])
        }
        let devices = try endpoints(run(["find"]))
        guard devices.count == 1, !devices[0].hasPrefix("midi\t"),
              let device = devices[0].split(separator: "\t").first else {
            throw SMK37FirmwareError("The keyboard did not enter USB download mode. Reconnect it and try again.")
        }
        let selector = ["--device", String(device)]
        status("Reading and verifying the current firmware…")
        _ = try run(["backup", work.path] + selector)
        let files = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bin" }
        guard files.count == 1 else { throw SMK37FirmwareError("The saved backup could not be verified.") }
        let metadataURL = files[0].deletingPathExtension().appendingPathExtension("json")
        let metadata = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: metadataURL))
        let backup = try SMK37FirmwareBackup(flash: Data(contentsOf: files[0]), metadata: metadata)
        // A complete, re-read backup at the user's chosen location is mandatory
        // before any erase/write command is allowed.
        try backup.save(backupURL)
        if case .backup = operation {
            status("Backup saved. Restarting the keyboard…")
            _ = try run(["restart"] + selector)
        } else if let restoring {
            guard restoring.metadata["unit id"] == backup.metadata["unit id"] else {
                throw SMK37FirmwareError("This backup belongs to another keyboard. Nothing was restored.")
            }
            let source = work.appendingPathComponent("restore.bin")
            try restoring.flash.write(to: source, options: .withoutOverwriting)
            try JSONEncoder().encode(restoring.metadata).write(to: source.deletingPathExtension().appendingPathExtension("json"), options: .withoutOverwriting)
            status("Restoring the backup. Keep the USB cable connected…")
            _ = try run(["restore", source.path, "--backup-dir", work.path, "--yes", "--restart"] + selector)
        } else {
            try backup.requirePro()
            status("Installing firmware. Keep the USB cable connected…")
            _ = try run(["firmware", package.path, "--backup-dir", work.path, "--yes", "--restart"] + selector)
        }
    }
    /// Identity is interleaved into the first 48-byte FWSC blocks. The helper
    /// independently checks the entire container CRC, image and device key.
    static func validatePackageModel(_ data: Data) throws {
        guard data.count >= 4096, data.count <= 16_777_216 else {
            throw SMK37FirmwareError("Choose a compatible SMK-37 Pro .fwsc firmware file.")
        }
        var identity = [UInt8]()
        for i in 0..<min(64, data.count / 48) {
            let byte = data[i * 48 + 47]
            if byte == 0x7d { break }
            identity.append(byte &- UInt8(i + 1))
        }
        let parts = String(decoding: identity, as: UTF8.self).split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "SMK-37 Pro", !parts[1].isEmpty else {
            throw SMK37FirmwareError("Choose a compatible SMK-37 Pro .fwsc firmware file.")
        }
    }
    private func endpoints(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { $0.contains("\t") }
    }
}
#endif
