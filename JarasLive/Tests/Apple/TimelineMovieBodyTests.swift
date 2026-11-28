@MainActor private func checkMovieRows(_ song: Song, directory: URL, pixelsPerSecond: Double) {
    let rows = TrackRowLayout(tracks: song.tracks, baseHeight: 84)
    let cache = TimelineAudioWaveform.shared
    let body = NativeTimelineAudioBodyView()
    let inputs = song.tracks.prefix(2).map { directory.appendingPathComponent($0.clips[0].audioFile!.path) }
    let viewport = CGRect(x: 0, y: 0, width: 1000, height: 320)
    var revision: UInt64 = 0
    for inverted in [true, false] {
        for solo: Int? in [nil, 0, 1, nil] {
            var playing = song
            for row in playing.tracks.indices { playing.tracks[row].solo = row == solo }
            let metadata = TimelineRenderMetadata(song: playing)
            revision += 1
            let key = TimelineRenderKey(revision: revision, songID: song.id, movingClip: nil, movingStart: 0, movingTrack: nil,
                movingRegion: nil, regionDelta: 0, resizingRegion: nil, resizedStart: 0, resizedEnd: 0)
            let value = NativeTimelineAudioBodyConfiguration.make(song: playing, key: key, rows: rows, metadata: metadata,
                rulerHeight: 55, selectedClips: [], mediaDirectory: directory, missingAudioPaths: [], invertWaveformColors: inverted)!
            precondition(value.itemIDs.isSuperset(of: song.tracks.prefix(2).map { $0.clips[0].id }))
            body.configure(value)
            // Ready notifications alone must finish drawing the first frame at the restored scale.
            body.project(viewport: viewport, documentSize: CGSize(width: 4200, height: 400), scale: pixelsPerSecond)
            let deadline = Date().addingTimeInterval(15)
            var verified = false
            while Date() < deadline {
                if let fills = body.fillsForTest?.items, let frame = body.waveformsForTest, fills.count >= 2 {
                    let peaks = frame.strokes.filter { $0.block.key != "timeline-centerline-unit" }
                    verified = inputs.indices.allSatisfy { row in
                        let fill = fills[row]
                        guard let header = cache.header(inputs[row]), let prefix = header.cachePrefix else { return false }
                        let source = Data(prefix.precomposedStringWithCanonicalMapping.utf8).base64EncodedString()
                        let rowPeaks = peaks.filter { $0.itemRect == fill.rect }
                        return !rowPeaks.isEmpty && rowPeaks.allSatisfy {
                            $0.block.key.contains(source) && $0.color != fill.topColor &&
                            $0.clip.minY >= fill.rect.minY && $0.clip.maxY <= fill.rect.maxY + 0.01
                        }
                    }
                    if verified {
                        if fills.count == 3 {
                            precondition(peaks.allSatisfy { $0.itemRect != fills[2].rect }, "Silent movie borrowed another row's samples")
                        }
                        break
                    }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(verified, "Movie waveform source, visibility or row changed with Solo at the saved zoom")
        }
    }
    body.configure(nil)
}

try MainActor.assumeIsolated {
    let projectFolder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-movie-rows-" + UUID().uuidString)
    let media = projectFolder.appendingPathComponent("Videos", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projectFolder) }
    let fixture = try makeWaveformMovies(in: media)
    var project = Project.empty(name: "Movie rows")
    let urls = fixture.movies + [fixture.silent]
    for (index, url) in urls.enumerated() {
        var track = Track(id: UUID(), name: "Movie \(index + 1)", role: TrackRole(rawValue: index == 2 ? "video" : "other"))
        if let name = track.fixedName { track.name = name }
        track.color = [0xc57238, 0x36ad9b, 0x899fe9][index]
        track.clips = [AudioClip(id: UUID(), name: url.lastPathComponent, startTime: 0, duration: 0.8,
            audioFile: AudioFile(path: "Videos/" + url.lastPathComponent))]
        project.songs[0].tracks.append(track)
    }
    let document = projectFolder.appendingPathComponent("Movie rows.jl")
    try ProjectDocumentCodec.write(project, to: document)
    let reopened = try ProjectDocumentCodec.decode(Data(contentsOf: document))
    checkMovieRows(reopened.songs[0], directory: projectFolder, pixelsPerSecond: 285.029215)
    var videoTrackSong = reopened.songs[0]
    videoTrackSong.tracks[1].role = TrackRole(rawValue: "video")
    checkMovieRows(videoTrackSong, directory: projectFolder, pixelsPerSecond: 285.029215)
    print("MOVIE_WAVEFORMS_REOPEN_WITHOUT_ZOOM_CORRECT_SOURCES_ROWS_AND_COLORS_BOTH_SOLOS_AND_SILENT_MOVIE_OK")
}
