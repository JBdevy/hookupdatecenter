import Foundation

/// Additive exchange: iPad owns all existing state; desktop contributes identities absent
/// from its inventory. FX insert identities are additions too, never parameter updates.
enum PartialProjectPackage {
    typealias Record = PortableProjectPackage.FileRecord
    static let limits = PortableProjectPackage.Limits()
    struct Snapshot: Codable {
        var format = "catlive-jlpartial"
        var version = 1
        var id = UUID()
        var createdAt = ISO8601DateFormatter().string(from: Date())
        var project: Project
        var files: [Record]
        var instruments: [String: String]
    }
    struct Delta: Codable {
        var format = "catlive-partial-additions"
        var version = 1
        var id = UUID()
        var createdAt = ISO8601DateFormatter().string(from: Date())
        var baselineID: UUID
        var existingSongs: [UUID]
        var existingTracks: [UUID]
        var existingClips: [UUID]
        var existingSetlists: [UUID]
        var existingRegionPlaylists: [UUID]
        var project: Project
    }
    struct Manifest: Codable {
        var format = "catlive-ziplivepartial"
        var version = 1
        var projectID: UUID
        var deltaID: UUID
        var document = "Partial.json"
        var files: [Record]
        var reused: [Record]
        var instruments: [String: String]
    }
    static func invalid(_ message: String) -> ProjectError { .invalid(message) }
    static func fileName(_ name: String, extension ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy"
        let clean = String(name.map { "/\\:\0<>\"|?*".contains($0) ? "_" : $0 }.prefix(100))
        return (clean.isEmpty ? "CatLive" : clean) + "-" + formatter.string(from: date) + "." + ext
    }
    static func readSnapshot(_ url: URL) throws -> Snapshot {
        guard url.pathExtension.lowercased() == "jlpartial" else { throw invalid("Selecione o arquivo .jlpartial exportado no iPad.") }
        try PortableProjectPackage.validateRegularFile(url)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limits.maximumDocumentBytes else { throw invalid("Inventário parcial muito grande.") }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.format == "catlive-jlpartial", snapshot.version == 1 else { throw invalid("Formato de inventário parcial não suportado.") }
        try snapshot.project.validate()
        try validateRecords(snapshot.files)
        guard Set(snapshot.files.map(\.path)) == snapshot.project.mediaPaths.union(snapshot.instruments.values),
              Set(snapshot.instruments.keys) == PortableProjectPackage.instrumentIDs(in: snapshot.project) else { throw invalid("Inventário parcial incompleto.") }
        try validateInstruments(snapshot.instruments)
        return snapshot
    }
    static func validateRecords(_ records: [Record]) throws {
        guard records.count <= limits.maximumFiles else { throw invalid("Arquivos demais no pacote parcial.") }
        var paths = Set<String>(), bytes: UInt64 = 0
        for record in records {
            try PortableProjectPackage.validatePath(record.path)
            guard paths.insert(PortableProjectPackage.pathKey(record.path)).inserted,
                  record.sha256.count == 64, record.sha256.allSatisfy(\.isHexDigit),
                  record.bytes <= limits.maximumBytes - bytes else { throw invalid("Inventário de arquivos inválido.") }
            bytes += record.bytes
        }
    }
    static func validateInstruments(_ paths: [String: String]) throws {
        for (id, path) in paths {
            guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), path == "Instruments/" + id + ".sf2" else { throw invalid("Instrumento nativo inválido.") }
            try PortableProjectPackage.validatePath(path)
        }
    }
    static func checkedFile(_ path: String, root: URL) throws -> URL {
        try PortableProjectPackage.validatePath(path)
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw invalid("Caminho de mídia inválido.") }
        try PortableProjectPackage.validateRegularFile(file)
        return file
    }
    static func exportSnapshot(project: Project, directory: URL, instruments: [String: URL], to destination: URL,
                               progress: @Sendable (Double) -> Void = { _ in }) throws {
        try project.validate()
        guard destination.pathExtension.lowercased() == "jlpartial" else { throw invalid("Use a extensão .jlpartial.") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let paths = project.mediaPaths.sorted(), ids = PortableProjectPackage.instrumentIDs(in: project).sorted()
        var records: [Record] = [], banks: [String: String] = [:]
        for path in paths {
            var record = try PortableProjectPackage.fingerprint(checkedFile(path, root: root)); record.path = path; records.append(record)
            progress(Double(records.count) / Double(max(1, paths.count + ids.count)))
        }
        for id in ids {
            guard let file = instruments[id] else { throw invalid("Instrumento nativo não encontrado: " + id) }
            try PortableProjectPackage.validateRegularFile(file)
            var record = try PortableProjectPackage.fingerprint(file); record.path = "Instruments/" + id + ".sf2"
            banks[id] = record.path
            if let existing = records.first(where: { $0.path == record.path }) {
                guard existing == record else { throw invalid("Instrumentos com caminhos conflitantes.") }
            } else { records.append(record) }
        }
        try validateInstruments(banks); try validateRecords(records)
        let data = try JSONEncoder().encode(Snapshot(project: project, files: records, instruments: banks))
        guard data.count <= limits.maximumDocumentBytes else { throw invalid("Inventário parcial muito grande.") }
        try Task.checkCancellation(); try data.write(to: destination, options: .atomic); progress(1)
    }
    static func newFX(_ source: NativeFXSettings?, comparedTo baseline: NativeFXSettings?) -> NativeFXSettings? {
        guard let source else { return nil }
        let known = Set(baseline?.inserted ?? [])
        var aliases = Set<String>()
        // Reordering a legacy chain creates one instance per old legacy stage.
        // Skip only that promoted stage, not additional copies of the same FX.
        for kind in known where !kind.hasPrefix("Native:") && !source.inserted.contains(kind) {
            let candidates = (source.instances ?? []).filter { $0.kind == kind && source.inserted.contains($0.effectKey) && !known.contains($0.effectKey) }
            if let promoted = candidates.first(where: { $0.legacyOrigin == kind }) ?? candidates.first { aliases.insert(promoted.effectKey) }
        }
        for key in source.inserted where !key.hasPrefix("Native:") && !known.contains(key) {
            if baseline?.instances?.contains(where: { $0.kind == key && known.contains($0.effectKey) && !source.inserted.contains($0.effectKey) }) == true { aliases.insert(key) }
        }
        var result = NativeFXSettings()
        for key in source.inserted where !known.contains(key) && !key.hasPrefix("External:") {
            if aliases.contains(key) { continue }
            appendFX(key, from: source, to: &result)
        }
        return result.inserted.isEmpty ? nil : result
    }
    static func appendFX(_ key: String, from source: NativeFXSettings, to target: inout NativeFXSettings) {
        guard !target.inserted.contains(key), !key.hasPrefix("External:") else { return }
        if let instance = source.instances?.first(where: { $0.effectKey == key }) {
            target.instances = (target.instances ?? []).filter { $0.effectKey != key } + [instance]
        } else {
            target = target.merging(effect: key, from: source)
            if key == "Instruments" { target.instrumentBypassed = source.instrumentBypassed }
        }
        target.inserted.append(key)
    }
    static func mergeFX(_ source: NativeFXSettings?, into target: inout NativeFXSettings?) {
        guard let source, !source.inserted.isEmpty else { return }
        var value = target ?? NativeFXSettings()
        for key in source.inserted { appendFX(key, from: source, to: &value) }
        target = value
    }
    static func additions(from original: Project, baseline: Snapshot) throws -> Delta {
        guard original.id == baseline.project.id else { throw invalid("O .jlpartial pertence a outro projeto. Exporte o inventário do projeto correspondente no iPad.") }
        try original.validate()
        var project = PortableProjectPackage.portableCopy(original)
        let base = baseline.project
        var delta = Delta(baselineID: baseline.id, existingSongs: [], existingTracks: [], existingClips: [], existingSetlists: base.setlists.map(\.id), existingRegionPlaylists: base.regionSetlist?.playlists.map(\.id) ?? [], project: project)
        project.masterFX = newFX(project.masterFX, comparedTo: base.masterFX)
        project.masterAutomation = nil; project.reductionDraft = nil
        project.songs = project.songs.compactMap { incoming in
            guard let old = base.songs.first(where: { $0.id == incoming.id }) else { return incoming }
            var song = incoming
            song.parts = incoming.parts.filter { part in !old.parts.contains { $0.id == part.id } }
            song.markers = (incoming.markers ?? []).filter { marker in !(old.markers ?? []).contains { $0.id == marker.id } }
            song.tracks = incoming.tracks.compactMap { incoming in
                guard let previous = old.tracks.first(where: { $0.id == incoming.id }) else { return incoming }
                var track = incoming
                track.fx = newFX(incoming.fx, comparedTo: previous.fx)
                track.clips = incoming.clips.compactMap { incomingClip in
                    var clip = incomingClip
                    if let previousClip = previous.clips.first(where: { $0.id == clip.id }) {
                        clip.fx = newFX(clip.fx, comparedTo: previousClip.fx)
                        guard clip.fx != nil else { return nil }
                        clip.audioFile = nil
                        delta.existingClips.append(clip.id)
                    } else if clip.audioFile == nil { clip.audioFile = incoming.audioFile }
                    return clip
                }
                track.programChanges = (incoming.programChanges ?? []).filter { marker in !(previous.programChanges ?? []).contains { $0.id == marker.id } }
                track.audioFile = nil; track.clickSound = nil; track.automation = nil
                guard !track.clips.isEmpty || !(track.programChanges ?? []).isEmpty || track.fx != nil else { return nil }
                delta.existingTracks.append(track.id)
                return track
            }
            guard !song.tracks.isEmpty || !song.parts.isEmpty || !(song.markers ?? []).isEmpty else { return nil }
            delta.existingSongs.append(song.id)
            return song
        }
        project.setlists = project.setlists.compactMap { incoming in
            guard let old = base.setlists.first(where: { $0.id == incoming.id }) else { return incoming }
            var list = incoming; list.songIds.removeAll { old.songIds.contains($0) }; return list.songIds.isEmpty ? nil : list
        }
        if var state = project.regionSetlist {
            state.playlists = state.playlists.compactMap { incoming in
                guard let old = base.regionSetlist?.playlists.first(where: { $0.id == incoming.id }) else { return incoming }
                var list = incoming; list.regionIds.removeAll { old.regionIds.contains($0) }
                list.duplicates = (list.duplicates ?? []).filter { duplicate in !(old.duplicates ?? []).contains { $0.id == duplicate.id } }
                return list.regionIds.isEmpty ? nil : list
            }
            state.blocks = (state.blocks ?? []).filter { block in !(base.regionSetlist?.blocks ?? []).contains { $0.id == block.id } }
            project.regionSetlist = state
        }
        delta.project = project
        _ = try merge(delta, into: base)
        return delta
    }
    static func appendUnique<T: Identifiable>(_ incoming: [T], to current: inout [T]) where T.ID: Hashable {
        var ids = Set(current.map(\.id))
        for item in incoming where ids.insert(item.id).inserted { current.append(item) }
    }
    static func merge(_ delta: Delta, into original: Project) throws -> Project {
        guard delta.format == "catlive-partial-additions", delta.version == 1, delta.project.id == original.id else { throw invalid("Este parcial pertence a outro projeto ou usa formato não suportado.") }
        if (original.partialImportIDs ?? []).contains(delta.id) { return original }
        var result = original
        mergeFX(delta.project.masterFX, into: &result.masterFX)
        for song in delta.project.songs {
            guard let s = result.songs.firstIndex(where: { $0.id == song.id }) else {
                guard !delta.existingSongs.contains(song.id) else { throw invalid("Uma música de destino foi removida do iPad. Exporte um novo .jlpartial.") }
                result.songs.append(song); continue
            }
            for track in song.tracks {
                guard let t = result.songs[s].tracks.firstIndex(where: { $0.id == track.id }) else {
                    guard !delta.existingTracks.contains(track.id) else { throw invalid("Uma pista de destino foi removida do iPad. Exporte um novo .jlpartial.") }
                    if let parent = track.parentTrackID {
                        guard let index = result.songs[s].tracks.firstIndex(where: { $0.id == parent }) else { throw invalid("O grupo de uma pista nova não existe no iPad. Exporte um novo .jlpartial.") }
                        var insertion = index + 1, descendants: Set<UUID> = [parent]
                        while insertion < result.songs[s].tracks.count,
                              let ancestor = result.songs[s].tracks[insertion].parentTrackID, descendants.contains(ancestor) {
                            descendants.insert(result.songs[s].tracks[insertion].id); insertion += 1
                        }
                        result.songs[s].tracks.insert(track, at: insertion)
                    } else { result.songs[s].tracks.append(track) }
                    continue
                }
                if delta.existingTracks.contains(track.id) { mergeFX(track.fx, into: &result.songs[s].tracks[t].fx) }
                for clip in track.clips {
                    if delta.existingClips.contains(clip.id) {
                        if let c = result.songs[s].tracks[t].clips.firstIndex(where: { $0.id == clip.id }) {
                            mergeFX(clip.fx, into: &result.songs[s].tracks[t].clips[c].fx)
                        }
                    } else if !result.songs[s].tracks[t].clips.contains(where: { $0.id == clip.id }) {
                        result.songs[s].tracks[t].clips.append(clip)
                    }
                }
                var changes = result.songs[s].tracks[t].programChanges ?? []
                appendUnique(track.programChanges ?? [], to: &changes)
                if !changes.isEmpty { result.songs[s].tracks[t].programChanges = changes }
            }
            appendUnique(song.parts, to: &result.songs[s].parts)
            var markers = result.songs[s].markers ?? []; appendUnique(song.markers ?? [], to: &markers)
            if !markers.isEmpty { result.songs[s].markers = markers }
            result.songs[s].duration = max(result.songs[s].duration, song.duration)
        }
        for list in delta.project.setlists {
            if let index = result.setlists.firstIndex(where: { $0.id == list.id }) {
                for id in list.songIds where !result.setlists[index].songIds.contains(id) { result.setlists[index].songIds.append(id) }
            } else if !delta.existingSetlists.contains(list.id) { result.setlists.append(list) }
        }
        if let additions = delta.project.regionSetlist {
            var state = result.regionSetlist ?? RegionSetlist()
            for list in additions.playlists {
                if let index = state.playlists.firstIndex(where: { $0.id == list.id }) {
                    for id in list.regionIds where !state.playlists[index].regionIds.contains(id) { state.playlists[index].regionIds.append(id) }
                    var aliases = state.playlists[index].duplicates ?? []; appendUnique(list.duplicates ?? [], to: &aliases)
                    if !aliases.isEmpty { state.playlists[index].duplicates = aliases }
                } else if !delta.existingRegionPlaylists.contains(list.id) { state.playlists.append(list) }
            }
            var blocks = state.blocks ?? []; appendUnique(additions.blocks ?? [], to: &blocks)
            if !blocks.isEmpty { state.blocks = blocks }
            if result.regionSetlist != nil || !state.playlists.isEmpty || !blocks.isEmpty { result.regionSetlist = state }
        }
        result.partialImportIDs = (original.partialImportIDs ?? []) + [delta.id]
        try result.validate()
        return result
    }
    static func remap(_ project: inout Project, _ mapping: [String: String]) {
        func file(_ file: inout AudioFile?) { if let path = file?.path, let mapped = mapping[path] { file?.path = mapped } }
        for s in project.songs.indices { for t in project.songs[s].tracks.indices {
            file(&project.songs[s].tracks[t].audioFile); file(&project.songs[s].tracks[t].clickSound)
            for c in project.songs[s].tracks[t].clips.indices { file(&project.songs[s].tracks[t].clips[c].audioFile) }
        }}
        project.remapFXSamples(mapping)
    }
    static func export(project: Project, directory: URL, baselineURL: URL, instruments: [String: URL], to destination: URL,
                       progress: @Sendable (Double) -> Void = { _ in }) throws {
        let baseline = try readSnapshot(baselineURL)
        var delta = try additions(from: project, baseline: baseline)
        guard destination.pathExtension.lowercased() == "ziplivepartial" else { throw invalid("Use a extensão .ziplivepartial.") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var mapping: [String: String] = [:], sources: [String: URL] = [:], records: [String: Record] = [:], reused: [String: Record] = [:]
        let media = delta.project.mediaPaths.sorted()
        var total: UInt64 = 0
        for (index, path) in media.enumerated() {
            let source = try checkedFile(path, root: root)
            var record = try PortableProjectPackage.fingerprint(source)
            if let existing = baseline.files.first(where: { $0.bytes == record.bytes && $0.sha256 == record.sha256 && !baseline.instruments.values.contains($0.path) }) {
                mapping[path] = existing.path; reused[existing.path] = existing
            } else {
                let target = "Stems/Partial-" + delta.id.uuidString + "/" + String(index + 1) + "-" + source.lastPathComponent
                try PortableProjectPackage.validatePath(target)
                record.path = target; mapping[path] = target; records[target] = record; sources[target] = source
                guard record.bytes <= limits.maximumBytes - total else { throw invalid("Pacote parcial muito grande.") }
                total += record.bytes
            }
            progress(0.2 * Double(index + 1) / Double(max(1, media.count)))
        }
        var banks: [String: String] = [:]
        for id in PortableProjectPackage.instrumentIDs(in: delta.project).sorted() {
            guard let source = instruments[id] else { throw invalid("Instrumento nativo não encontrado: " + id) }
            try PortableProjectPackage.validateRegularFile(source)
            var record = try PortableProjectPackage.fingerprint(source); record.path = "Instruments/" + id + ".sf2"; banks[id] = record.path
            if let oldPath = baseline.instruments[id], let old = baseline.files.first(where: { $0.path == oldPath }) {
                guard old.sha256 == record.sha256, old.bytes == record.bytes else { throw invalid("O instrumento " + id + " tem conteúdo diferente no iPad. Use outro identificador para o instrumento novo.") }
                reused[old.path] = old
            } else {
                guard record.bytes <= limits.maximumBytes - total else { throw invalid("Pacote parcial muito grande.") }
                records[record.path] = record; sources[record.path] = source; total += record.bytes
            }
        }
        remap(&delta.project, mapping)
        let document = try JSONEncoder().encode(delta)
        guard document.count <= limits.maximumDocumentBytes else { throw invalid("Dados parciais muito grandes.") }
        records["Partial.json"] = PortableProjectPackage.record("Partial.json", data: document)
        try validateInstruments(banks); try validateRecords(Array(records.values) + Array(reused.values))
        let manifest = Manifest(projectID: project.id, deltaID: delta.id, files: records.values.sorted { $0.path < $1.path }, reused: reused.values.sorted { $0.path < $1.path }, instruments: banks)
        let metadata = try JSONEncoder().encode(manifest)
        guard metadata.count <= limits.maximumManifestBytes else { throw invalid("Inventário parcial muito grande.") }
        let parent = destination.deletingLastPathComponent()
        guard parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else { throw invalid("Escolha uma pasta sem links simbólicos.") }
        if FileManager.default.fileExists(atPath: destination.path) { try PortableProjectPackage.validateRegularFile(destination) }
        let temp = parent.appendingPathComponent(".catlive-partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try StoredProjectZIPWriter(url: temp)
        try writer.add(path: "Partial.json", data: document)
        var copied: UInt64 = 0
        for path in sources.keys.sorted() {
            try writer.add(path: path, source: sources[path]!, expected: records[path]!) { count in progress(0.2 + 0.79 * Double(copied + count) / Double(max(1, total))) }
            copied += records[path]!.bytes
        }
        try writer.add(path: "manifest.json", data: metadata); try writer.finish(); try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: destination) }
        progress(1)
    }
    final class PreparedImport {
        let project: Project
        let staging: URL
        let directory: URL
        let files: [Record]
        var installed: [URL] = []
        init(project: Project, staging: URL, directory: URL, files: [Record]) { self.project = project; self.staging = staging; self.directory = directory; self.files = files }
        deinit { try? FileManager.default.removeItem(at: staging) }
        func install() throws {
            do {
                for record in files {
                    let destination = directory.appendingPathComponent(record.path)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try PortableProjectPackage.validateRegularFile(destination)
                        let actual = try PortableProjectPackage.fingerprint(destination)
                        guard actual.sha256 == record.sha256 && actual.bytes == record.bytes else { throw invalid("Um arquivo do iPad ocupa o destino do parcial. Nenhum arquivo existente será substituído.") }
                    } else {
                        let parent = destination.deletingLastPathComponent()
                        guard parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else { throw invalid("Destino de mídia inválido.") }
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: staging.appendingPathComponent(record.path), to: destination)
                        installed.append(destination)
                    }
                }
            } catch { rollback(); throw error }
        }
        func rollback() { for file in installed { try? FileManager.default.removeItem(at: file) }; installed = [] }
    }
    static func prepareImport(_ archive: URL, project: Project, directory: URL, instruments: [String: URL],
                              progress: @Sendable (Double) -> Void = { _ in }) throws -> PreparedImport {
        guard archive.pathExtension.lowercased() == "ziplivepartial" else { throw invalid("Selecione um arquivo .ziplivepartial.") }
        try PortableProjectPackage.validateRegularFile(archive)
        let zip = try StoredProjectZIPReader(url: archive, limits: limits)
        let manifest = try JSONDecoder().decode(Manifest.self, from: zip.data("manifest.json", maximum: limits.maximumManifestBytes))
        guard manifest.format == "catlive-ziplivepartial", manifest.version == 1, manifest.projectID == project.id, manifest.document == "Partial.json" else { throw invalid("Este pacote parcial pertence a outro projeto ou usa um formato não suportado.") }
        guard !(project.partialImportIDs ?? []).contains(manifest.deltaID) else { throw invalid("Este parcial já foi importado neste projeto.") }
        try validateRecords(manifest.files + manifest.reused); try validateInstruments(manifest.instruments)
        guard Set(zip.entries.keys) == Set(manifest.files.map(\.path)).union(["manifest.json"]), let documentRecord = manifest.files.first(where: { $0.path == manifest.document }) else { throw invalid("Inventário parcial incompleto.") }
        let data = try zip.data(manifest.document, maximum: limits.maximumDocumentBytes)
        guard PortableProjectPackage.record(manifest.document, data: data) == documentRecord else { throw invalid("O documento parcial está corrompido.") }
        let delta = try JSONDecoder().decode(Delta.self, from: data)
        guard delta.id == manifest.deltaID, PortableProjectPackage.portableCopy(delta.project) == delta.project,
              Set(manifest.instruments.keys) == PortableProjectPackage.instrumentIDs(in: delta.project),
              Set((manifest.files + manifest.reused).map(\.path)) == delta.project.mediaPaths.union(manifest.instruments.values).union([manifest.document]) else { throw invalid("O pacote parcial contém dados ou arquivos não esperados.") }
        for record in manifest.files where record.path != manifest.document {
            guard record.path.hasPrefix("Stems/Partial-" + delta.id.uuidString + "/") || manifest.instruments.values.contains(record.path) else { throw invalid("Destino de mídia parcial inválido.") }
        }
        let merged = try merge(delta, into: project)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        for record in manifest.reused {
            let id = manifest.instruments.first { $0.value == record.path }?.key
            let source: URL
            if let id, let bank = instruments[id] { source = bank; try PortableProjectPackage.validateRegularFile(source) }
            else { source = try checkedFile(record.path, root: root) }
            let actual = try PortableProjectPackage.fingerprint(source)
            guard actual.sha256 == record.sha256 && actual.bytes == record.bytes else { throw invalid("Uma mídia existente mudou no iPad. Exporte um novo .jlpartial.") }
        }
        if let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           UInt64(max(0, available)) < zip.totalBytes { throw invalid("Não há espaço suficiente para importar o parcial.") }
        let staging = root.appendingPathComponent(".partial-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var success = false; defer { if !success { try? FileManager.default.removeItem(at: staging) } }
        var copied: UInt64 = 0
        let files = manifest.files.filter { $0.path != manifest.document }
        for record in files {
            guard let entry = zip.entries[record.path], entry.size == record.bytes else { throw invalid("Tamanho de mídia inválido.") }
            let file = staging.appendingPathComponent(record.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.extract(record.path, to: file, expected: record) { count in progress(Double(copied + count) / Double(max(1, zip.totalBytes))) }
            copied += record.bytes
            if manifest.instruments.values.contains(record.path) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let header = try handle.read(upToCount: 12) ?? Data()
                guard header.count == 12, String(data: header.prefix(4), encoding: .ascii) == "RIFF", String(data: header.suffix(4), encoding: .ascii) == "sfbk" else { throw invalid("Banco de instrumento nativo inválido.") }
            }
        }
        try Task.checkCancellation(); success = true
        return PreparedImport(project: merged, staging: staging, directory: root, files: files)
    }
}
