// Release-mode CPU projection benchmark. Uses the production region/marker
// drawing and input targets, with fixed density and no project/audio mutation.
@MainActor private func benchmarkZoomHeader() {
    _ = NSApplication.shared
    for count in (ProcessInfo.processInfo.environment["CATLIVE_ZOOM_PROFILE"] == "1" ? [5000] : [100, 1000, 5000]) {
        let parts = (0..<count).map { index in
            Part(id: UUID(), name: "Region \(index)", startTime: Double(index) * 180,
                 endTime: Double(index) * 180 + 170, color: 0x705264)
        }
        let markers = parts.flatMap { part in (0..<4).map { n in
            TimelineMarker(id: UUID(), name: "Section \(n)", position: part.startTime + Double(n) * 40,
                           color: 0x40a050, section: true)
        } }
        let song = Song(id: UUID(), name: "Zoom benchmark", duration: Double(count) * 180,
            bpm: 120, tracks: [], parts: parts, markers: markers)
        let lanes = RegionLanes(parts: parts)
        let targets = parts.map { NativeTimelineRegionTarget(id: $0.id, start: $0.startTime, end: $0.endTime,
            lane: lanes.lanes[$0.id] ?? 0, edgePadding: 10, selected: false, pinned: false,
            input: RegionRightClick(edit: {})) }
        let header = NativeTimelineHeaderView()
        header.configure(.init(song: song, lanes: lanes, parentIDs: [], regionTargets: targets,
            edit: { _ in }, delete: { _ in }, convert: { _ in }, seek: { _ in }, move: { _ in }))
        for distant in (ProcessInfo.processInfo.environment["CATLIVE_ZOOM_PROFILE"] == "1" ? [true] : [false, true]) {
            var timings: [Double] = []
            let before = header.markerConfigurationsForTest
            for frame in 0..<(ProcessInfo.processInfo.environment["CATLIVE_ZOOM_PROFILE"] == "1" ? 1500 : 100) {
                let scale = (distant ? 0.012 : 4) * exp(sin(Double(frame) / 17) * 0.6)
                let viewport = CGRect(x: max(0, song.duration * 0.5 * scale - 550), y: 0, width: 1100, height: 720)
                let start = ProcessInfo.processInfo.systemUptime
                header.project(scale: scale, viewport: viewport, layoutWidth: song.duration * 12, displayScale: 2)
                if frame > 5 { timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
            }
            timings.sort()
            print("ZOOM_HEADER regions=\(count) markers=\(markers.count) distant=\(distant) medianMS=\(timings[timings.count/2]) p95MS=\(timings[Int(Double(timings.count-1)*0.95)]) commandUpdates=\(header.markerConfigurationsForTest-before)")
        }
        header.configure(nil)
    }
}
MainActor.assumeIsolated { benchmarkZoomHeader() }
