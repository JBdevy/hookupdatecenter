import Foundation
import Darwin
#if SWIFT_PACKAGE
import KontaktLibraryCore
#endif

@main struct InstallerMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install", geteuid() == 0 else {
                throw LibraryFailure("Abra Kontakt Add Libray para adicionar bibliotecas.")
            }
            let manifest = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
            let workspace = manifest.deletingLastPathComponent()
            guard manifest.lastPathComponent == "request.json", workspace.lastPathComponent.hasPrefix("KontaktAddLibray-") else {
                throw LibraryFailure("Solicitação de importação inválida.")
            }
            let request = try JSONDecoder().decode(ImportRequest.self, from: Data(contentsOf: manifest))
            var status = ImportStatus(entries: request.libraries.map { ImportEntry($0.library) })
            let installer = LibraryInstaller()
            func report() throws {
                let path = workspace.appendingPathComponent("status.json")
                try JSONEncoder().encode(status).write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
            }
            let root = request.folder.standardizedFileURL.path
            for index in status.entries.indices {
                if FileManager.default.fileExists(atPath: workspace.appendingPathComponent("cancel").path) {
                    status.entries[index].state = "cancelled"; status.entries[index].detail = "Cancelado"; continue
                }
                status.entries[index].state = "working"; status.entries[index].detail = "Adicionando…"; try report()
                do {
                    let item = status.entries[index]
                    let path = item.source.standardizedFileURL
                    guard path.path.hasPrefix(root == "/" ? "/" : root + "/") else { throw LibraryFailure("Arquivo fora da pasta selecionada.") }
                    let payload = request.libraries[index]
                    // The user process already read these bytes through NSOpenPanel.
                    // Root only validates the transferred XML and writes /Library.
                    let library = try Library.parse(source: path, data: payload.library.xml, version: payload.library.version)
                    guard library.name == item.name, library.regKey == payload.library.regKey else {
                        throw LibraryFailure("Metadados da biblioteca não correspondem à solicitação.")
                    }
                    try installer.install(library, contentDirectory: payload.contentDirectory)
                    status.entries[index].state = "added"; status.entries[index].detail = "Adicionada"
                } catch is CancellationError {
                    status.entries[index].state = "cancelled"; status.entries[index].detail = "Cancelado"
                } catch {
                    status.entries[index].state = "failed"; status.entries[index].detail = error.localizedDescription
                }
                try report()
            }
            status.finished = true; try report()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
