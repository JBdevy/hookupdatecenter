import SwiftUI
import UniformTypeIdentifiers
import Combine
enum TimelineZoomLimits {
    static let minimum = 0.001
    static let maximum = 8192.0
    static let preciseSensitivity = 0.0021
    static let maximumPreciseSensitivity = 0.035
    static let wheelSensitivity = 0.065
}
enum TimelineTrackHeightLimits {
    static let minimum: CGFloat = 24
    static let defaultHeight: CGFloat = 64
    static let maximum: CGFloat = 240
    static let preciseSensitivity = 0.016
    static let wheelSensitivity = 0.12
    static let maximumWheelStep = 0.40
}

/// Persist navigation separately from settings observed by @AppStorage. A
/// standard-defaults write invalidates those controls even when their own keys
/// did not change, producing a second layout after a zoom gesture has stopped.
enum TimelineViewportPreferences {
    static let zoomKey = "jaras.timelineZoom"
    static let storage = UserDefaults(suiteName: "com.hookdeveloper.catlive.viewport")!
    static var zoom: Double {
        let saved = (storage.object(forKey: zoomKey) as? NSNumber)?.doubleValue
            ?? (UserDefaults.standard.object(forKey: zoomKey) as? NSNumber)?.doubleValue
            ?? 1.0
        return saved.isFinite ? min(TimelineZoomLimits.maximum, max(TimelineZoomLimits.minimum, saved)) : 1.0
    }
    static func saveZoom(_ value: Double) {
        guard value.isFinite else { return }
        let value = min(TimelineZoomLimits.maximum, max(TimelineZoomLimits.minimum, value))
        guard (storage.object(forKey: zoomKey) as? NSNumber)?.doubleValue != value else { return }
        storage.set(value, forKey: zoomKey)
    }
}
private let markerLaneHeight: CGFloat = 16
private let tempoLaneHeight = markerLaneHeight
private let barLaneHeight = markerLaneHeight

struct TimelineGridView: View {
    @ObservedObject var show: ShowController
    let documents: ProjectDocuments
    var remotePresentation = false
    var toggleMixer: () -> Void = {}
    var body: some View {
        TimelineGridContent(show: show, documents: documents, revision: show.projectRevision, mixerRevision: show.mixerPlaybackRevision, songID: show.current?.id, focusRequest: show.regionFocusRequest, selectedRegion: show.selectedTimelineRegion, editPosition: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, remotePresentation: remotePresentation, toggleMixer: toggleMixer).equatable()
    }
}
private struct TimelineLiveMixerRow<Content: View>: View {
    let show: ShowController
    @ObservedObject private var updates: ShowProjectPresentation
    let track: Track
    let index: Int
    @ViewBuilder let content: (Track) -> Content
    init(show: ShowController, track: Track, index: Int, @ViewBuilder content: @escaping (Track) -> Content) {
        self.show = show; self.track = track; self.index = index; self.content = content
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }
    var body: some View {
        let tracks = show.current?.tracks ?? []
        let current = tracks.indices.contains(index) && tracks[index].id == track.id ? tracks[index] : track
        content(current)
    }
}

private struct TimelineGridContent: View, Equatable {
    let show: ShowController
    let documents: ProjectDocuments
    let revision: UInt64
    let mixerRevision: UInt64
    let songID: UUID?
    let focusRequest: UUID
    let selectedRegion: UUID?
    let editPosition: Double
    let toggleMixer: () -> Void
    let remotePresentation: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.remotePresentation == rhs.remotePresentation && lhs.show === rhs.show && lhs.revision == rhs.revision && lhs.songID == rhs.songID && lhs.focusRequest == rhs.focusRequest && lhs.selectedRegion == rhs.selectedRegion && lhs.editPosition == rhs.editPosition
    }
    @ObservedObject private var recordingLayout = RecordingLaneLayout.shared
    @Environment(\.locale) private var locale
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @State private var zoomState = TimelineZoomState()
    @State private var rowLayoutCache = TrackLayoutCache()
    #if os(macOS)
    @State private var selectionLayoutCache = TimelineSelectionLayoutCache()
    @State private var trackHeightMotion = TimelineTrackHeightMotion()
    #endif
    @State private var overlapCache = RegionOverlapCache()
    @State private var horizontalScroll = TimelineScrollPosition()
    @State private var verticalScroll = TimelineVerticalScroll()
    #if os(macOS)
    @State private var mixerScrollController = SidebarScrollController()
    @State private var mixerRowPool = TimelineMixerRowPool<UUID>()
    #endif
    @State private var timelineExtent = 240.0
    @State private var resizingRegion: UUID?
    @State private var resizedStart = 0.0
    @State private var resizedEnd = 0.0
    @State private var regionSnapPoints: [Double] = []
    @State private var movingRegion: UUID?
    @State private var regionMarkerRepulsion: RegionMarkerRepulsion?
    @State private var regionDelta = 0.0
    @State private var editingRegion: UUID?
    @State private var unifyingRegion: UUID?
    @State private var editingMarker: TimelineMarker?
    @State private var editingTempoMarker: TimelineMarker?
    @State private var regionToDelete: (project: UUID, song: UUID, region: UUID)?
    @State private var confirmingRegionDelete = false
    @State private var confirmingBPMDetection = false
    @State private var bpmRegions: [UUID] = []
    @State private var bpmWorker: Task<Void, Never>?
    @State private var reRenderWorker: Task<Void, Never>?
    @State private var glueCancellation: AudioExportCancellation?
    @State private var tuningItems: Set<UUID> = []
    @State private var showingItemTuner = false
    @State private var reRenderTitle = "Re-render"
    @StateObject private var reRenderProgress = ItemReRenderProgress()
    @State private var showingReRender = false
    @State private var resizingItem: UUID?
    @State private var resizedItemStart = 0.0
    @State private var resizedItemEnd = 0.0
    @State private var itemGainPreview = ItemGainPreview()
    @State private var insertionPreview = GridInsertionPreview()
    @State private var itemExport: ItemAudioExportRequest?
    @State private var normalizingItems = Set<UUID>()
    @State private var showingNormalize = false
    @State private var itemsToSplit = Set<UUID>()
    @State private var splitPosition = 0.0
    @State private var confirmingSplit = false
    @State private var tracksToDelete = Set<UUID>()
    @State private var trackDeletionContext: (project: UUID, song: UUID)?
    @State private var confirmingTrackDelete = false
    @State private var selectedClip: UUID?
    @State private var selectedClips = Set<UUID>()
    @State private var movingClip: UUID?
    @State private var movingStart = 0.0
    @State private var movingTrack: UUID?
    @State private var provisionalTrack: Track?
    @State private var selectedTrack: UUID?
    @State private var selectedTracks = Set<UUID>()
    @State private var addingTrack = false
    @State private var draggingMain = false
    @State private var draggingSub = false
    @AppStorage("jaras.trackColumnWidth") private var savedLabelWidth = Double(SidebarWidthLimits.trackMixer)
    @AppStorage("jaras.trackColumnRestoreWidth") private var restoreLabelWidth = 248.0
    @State private var resizeStart: CGFloat?
    @State private var mixerResizeState = SidebarResizeState()
    @State private var trackHeight: CGFloat = TimelineTrackHeightLimits.defaultHeight
    #if os(macOS)
    #endif
    init(show: ShowController, documents: ProjectDocuments, revision: UInt64, mixerRevision: UInt64, songID: UUID?, focusRequest: UUID, selectedRegion: UUID?, editPosition: Double, remotePresentation: Bool, toggleMixer: @escaping () -> Void) {
        self.show = show; self.documents = documents; self.revision = revision; self.mixerRevision = mixerRevision; self.songID = songID
        self.focusRequest = focusRequest; self.selectedRegion = selectedRegion; self.editPosition = editPosition
        self.remotePresentation = remotePresentation; self.toggleMixer = toggleMixer
        let prefix = remotePresentation ? "jaras.remote." : "jaras."
        _savedLabelWidth = AppStorage(wrappedValue: remotePresentation ? 280 : Double(SidebarWidthLimits.trackMixer), prefix + "trackColumnWidth")
        _restoreLabelWidth = AppStorage(wrappedValue: remotePresentation ? 280 : 248, prefix + "trackColumnRestoreWidth")
    }
    private var dividerWidth: CGFloat {
        #if os(macOS)
        20
        #else
        4
        #endif
    }
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if let originalSong = show.current {
                    let renderKey = TimelineRenderKey(revision: revision, songID: songID, movingClip: movingClip, movingStart: movingStart, movingTrack: movingTrack, movingRegion: movingRegion, regionDelta: regionDelta, resizingRegion: resizingRegion, resizedStart: resizedStart, resizedEnd: resizedEnd, recordingRevision: recordingLayout.revision, resizingItem: resizingItem, itemStart: resizedItemStart, itemEnd: resizedItemEnd)
                    let song = previewItemEdit(previewClipMove(previewRegionResize(previewRegionMove(originalSong))))
                    let regionLanes = rowLayoutCache.regionLanes(song.parts, key: renderKey)
                    let rulerHeight = CGFloat(regionLanes.count) * 16 + markerLaneHeight + tempoLaneHeight + barLaneHeight
                    let maximumLabelWidth = max(161, min(486.5, geometry.size.width - 260))
                    let groupDepths = song.trackGroupDepths
                    let row = trackHeight
                    let rows = rowLayoutCache.layout(song.tracks, height: row, key: renderKey)
                    let contentHeight = max(geometry.size.height, rulerHeight + rows.totalHeight + row * 2)
                    SidebarResizeLayer(state: mixerResizeState) { liveLabelWidth in
                    let requestedLabelWidth = liveLabelWidth ?? CGFloat(savedLabelWidth)
                    let labelWidth = requestedLabelWidth <= 0 ? 0 : min(maximumLabelWidth, max(SidebarWidthLimits.trackMixer, requestedLabelWidth))
                    let mountedLabelWidth = labelWidth > 0 ? labelWidth : min(maximumLabelWidth, max(SidebarWidthLimits.trackMixer, CGFloat(restoreLabelWidth)))
                    let resizeViewport = mixerResizeState.limitsWidthToVisibleRows
                        ? CGRect(x: 0, y: verticalScroll.offset, width: 0, height: geometry.size.height) : nil
                    let extent = max(timelineExtent, song.duration + 120, max(0, geometry.size.width - labelWidth - dividerWidth) / (10 * TimelineZoomLimits.minimum) + 120)
                        GridScrollView(axis: .vertical, contentWidth: geometry.size.width, contentHeight: contentHeight) {
                            TimelineColumnsContainer(mixerWidth: labelWidth, viewportWidth: geometry.size.width, height: contentHeight, dividerWidth: dividerWidth,
                                project: show.snapshot.project.id,
                                mixerIdentity: TimelineMixerIdentity(revision: revision, mixerRevision: mixerRevision, song: songID, width: mountedLabelWidth,
                                    viewportHeight: ceil(geometry.size.height / 512) * 512, heights: rows.heights, selection: selectedTracks,
                                    documentHeight: contentHeight, rulerHeight: rulerHeight, widthViewport: resizeViewport)) {
                                TimelineMixerLayer(position: verticalScroll.tiles, identity: TimelineMixerIdentity(revision: revision, mixerRevision: mixerRevision, song: songID, width: mountedLabelWidth, viewportHeight: ceil(geometry.size.height / 512) * 512, heights: rows.heights, selection: selectedTracks, documentHeight: contentHeight, rulerHeight: rulerHeight, widthViewport: resizeViewport)) { visibleY in
                                Group {
                                #if os(macOS)
                                let slots = mixerRowPool.slots(ids: song.tracks.map(\.id), offsets: rows.offsets, heights: rows.heights,
                                                               top: rulerHeight, visibleY: visibleY,
                                                               viewportHeight: ceil(geometry.size.height / 512) * 512,
                                                               width: mountedLabelWidth, widthViewport: resizeViewport, pinned: TrackSelectionRouter.shared.pinnedTracks)
                                TimelineTrackRowsContainer(width: mountedLabelWidth, height: contentHeight, top: rulerHeight,
                                                        offsets: slots.map { rows.offsets[$0.index] }, rowHeights: slots.map { $0.height },
                                                        rowWidths: slots.map { $0.width ?? mountedLabelWidth }) {
                                    ForEach(Array(slots.enumerated()), id: \.element.id) { slotIndex, slot in
                                        let index = slot.index
                                        let track = song.tracks[index]
                                            let silenced = song.isSilenced(track)
                                            TimelineLiveMixerRow(show: show, track: track, index: index) { liveTrack in
                                            TrackMixerRow(show: show, projectID: show.snapshot.project.id, track: mixerMetadata(liveTrack), trackSelection: selectedTracks, nextTrack: index + 1 < song.tracks.count ? song.tracks[index + 1].id : nil, number: index + 1, selected: track.kind == .standard && selectedTracks.contains(track.id), silenced: silenced, showsMeterScale: true, showsFader: (slot.width ?? mountedLabelWidth) >= 180, compactHeight: rows.heights[index] < 64, minimalHeight: rows.heights[index] < 56, isFolder: index + 1 < song.tracks.count && song.tracks[index + 1].parentTrackID == track.id, groupDepth: groupDepths[track.id] ?? 0, lastChild: index + 1 == song.tracks.count || song.tracks[index + 1].parentTrackID != track.parentTrackID, groupSelection: selectedTracks.contains(track.id) && selectedTracks.count > 1 ? { show.groupTracks(selectedTracks) } : nil, select: { selectTrack(track.id, in: song) }, importVideo: { documents.chooseVideo(track: track.id) }, projectDirectory: documents.currentURL?.deletingLastPathComponent(), deleteTracks: { requestTrackDeletion($0) }).equatable()
                                            }.frame(width: slot.width, height: slot.height).clipped().jarasPlaced(at: slotIndex)
                                    }
                                }
                                #else
                                TimelineTrackRowsContainer(width: mountedLabelWidth, height: contentHeight,
                                                        top: rulerHeight, offsets: rows.offsets, rowHeights: rows.heights) {
                                    ForEach(Array(song.tracks.enumerated()), id: \.element.id) { index, track in
                                        if mixerRowIsMounted(start: rulerHeight + rows.offsets[index], height: rows.heights[index], visibleY: visibleY, viewportHeight: ceil(geometry.size.height / 512) * 512) {
                                            let silenced = song.isSilenced(track)
                                            TimelineLiveMixerRow(show: show, track: track, index: index) { liveTrack in
                                            TrackMixerRow(show: show, projectID: show.snapshot.project.id, track: mixerMetadata(liveTrack), trackSelection: selectedTracks, nextTrack: index + 1 < song.tracks.count ? song.tracks[index + 1].id : nil, number: index + 1, selected: track.kind == .standard && selectedTracks.contains(track.id), silenced: silenced, showsMeterScale: true, showsFader: mountedLabelWidth >= 180, compactHeight: rows.heights[index] < 64, minimalHeight: rows.heights[index] < 56, isFolder: index + 1 < song.tracks.count && song.tracks[index + 1].parentTrackID == track.id, groupDepth: groupDepths[track.id] ?? 0, lastChild: index + 1 == song.tracks.count || song.tracks[index + 1].parentTrackID != track.parentTrackID, groupSelection: selectedTracks.contains(track.id) && selectedTracks.count > 1 ? { show.groupTracks(selectedTracks) } : nil, select: { selectTrack(track.id, in: song) }, importVideo: { documents.chooseVideo(track: track.id) }, projectDirectory: documents.currentURL?.deletingLastPathComponent(), deleteTracks: { requestTrackDeletion($0) }).equatable()
                                            }.frame(height: rows.heights[index]).clipped()
                                        } else { Color.clear.frame(height: rows.heights[index]) }
                                    }
                                }
                                #endif
                                }.frame(width: mountedLabelWidth, height: contentHeight).clipped().background(JarasTheme.mixer)
                                    .overlay(alignment: .bottomLeading) {
                                        Color.clear
                                            .frame(width: mountedLabelWidth, height: max(0, contentHeight - rulerHeight - rows.totalHeight))
                                            .contentShape(Rectangle())
                                            .onTapGesture(count: 2) { addStandardTrackAtEnd() }
                                    }
                                }.equatable().frame(width: labelWidth, alignment: .leading).clipped().allowsHitTesting(labelWidth > 0)
                                    #if os(macOS)
                                    .background(TimelineMixerHeightWheelInput { factor, smoothWheel in
                                        changeTrackHeight(factor, smoothWheel: smoothWheel)
                                    })
                                    #endif
                            } divider: {
                                JarasTheme.mixer.frame(width: dividerWidth)
                            } timeline: {
                    #if os(macOS)
                    let selectionLayout = selectionLayoutCache.layout(key: renderKey, rowHeight: row, rulerHeight: rulerHeight,
                                                                     rowOffsets: rows.offsets, laneHeights: rows.laneHeights) {
                        song.tracks.enumerated().flatMap { index, track -> [GridSelectionItem] in
                        let y = rulerHeight + rows.offsets[index]
                        return track.clips.map { clip in
                            GridSelectionItem(id: clip.id, rect: CGRect(x: clip.startTime, y: y + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3, width: clip.duration, height: rows.laneHeights[index] - 6), gain: clip.gain ?? 1, phaseInverted: clip.phaseInverted == true, pan: clip.pan ?? 0, editable: track.kind == .standard || clip.isProjectionMedia, movable: track.kind != .timecode || clip.isProjectionMedia, contextActions: track.kind == .standard || clip.isProjectionMedia, audioExportable: track.kind == .standard && clip.midi == nil && (clip.audioFile ?? track.audioFile) != nil, midiEditable: clip.midi != nil, textEditable: track.kind.isText && !clip.isProjectionMedia, name: clip.isImage ? JarasLocalization.string("Image") : track.kind == .timecode && !clip.isProjectionMedia ? (track.timecode?.mode ?? "mtc").uppercased() : clip.name, muted: clip.muted == true, hasFX: !(clip.fx?.inserted.isEmpty ?? true), fxBypassed: clip.fxBypassed == true, duration: clip.duration, fadeIn: clip.fadeIn ?? 0, fadeOut: clip.fadeOut ?? 0, trackIndex: index, laneIndex: rows.lanes[index].lanes[clip.id] ?? 0)
                        }
                    }
                    }
                    #endif
                                TimelineZoomLayer(state: zoomState) { zoom in
                                    let pixelsPerSecond = 10.0 * zoom.wrappedValue
                                    let width = extent * pixelsPerSecond
                    // Lightweight native headers follow actual scroll bounds;
                    // retain metadata so scrolling can reveal items without a
                    // SwiftUI rebuild of the waveform document.
                    let importDrop: ([NSItemProvider], CGPoint) -> Bool = { providers, location in
                        guard location.y >= verticalScroll.offset + rulerHeight else { return false }
                        let y = location.y - rulerHeight
                        let index = rows.offsets.indices.first { y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0] }
                        let track = index.map { originalSong.tracks[$0].id }
                        let start = itemPosition(location.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                        return documents.importAudio(providers, start: start, track: track, song: originalSong.id)
                    }
                                GridScrollView(axis: .horizontal, contentWidth: width, contentHeight: contentHeight, fileDrop: { urls, point in
                                    importDrop(urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }, point)
                                }, fileDropPreview: { urls, point in
                                    insertionPreview.externalSources(urls)
                                    guard let point, point.y >= verticalScroll.offset + rulerHeight else { insertionPreview.update(nil); return }
                                    insertionPreview.update(itemPosition(point.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond))
                                    let y = point.y - rulerHeight
                                    let index = rows.offsets.indices.first { y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0] }
                                    let track = index.map { song.tracks[$0] }
                                    let endY = rulerHeight + rows.totalHeight
                                    insertionPreview.targetExternal(.init(y: index.map { rulerHeight + rows.offsets[$0] } ?? endY,
                                        height: index.map { rows.laneHeights[$0] } ?? row,
                                        color: track?.color ?? Track.defaultStandardColor,
                                        newTracksY: track == nil ? endY + row : endY, newTrackHeight: row))
                                }) {
                                    ZStack(alignment: .topLeading) {
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            TimelineDrawing(visibleRect: CGRect(x: horizontalOffset, y: visibleY, width: max(0, geometry.size.width - labelWidth - dividerWidth), height: geometry.size.height), song: song, renderKey: renderKey, rowHeight: row, rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips, movingClip: movingClip, movingStart: movingStart, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), missingAudioPaths: documents.missingAudioPaths, documentWidth: width, selectedTracks: selectedTracks).equatable()
                                        }.frame(width: width, height: contentHeight)
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            ItemGainPreviewOverlay(preview: itemGainPreview, visibleRect: CGRect(x: horizontalOffset, y: visibleY, width: geometry.size.width, height: geometry.size.height), song: song, rows: rows, renderKey: renderKey, rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), documentWidth: width)
                                        }.frame(width: width, height: contentHeight).allowsHitTesting(false)
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            RecordingGridOverlay(visibleRect: CGRect(x: horizontalOffset,y: visibleY,width: geometry.size.width,height: geometry.size.height),tracks: song.tracks, offsets: rows.offsets, heights: rows.heights, rulerHeight: rulerHeight, scale: pixelsPerSecond)
                                        }.frame(width: width,height: contentHeight,alignment: .topLeading)
                                        #if !os(macOS)
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            let visibleStart = max(0, horizontalOffset - 1024) / pixelsPerSecond
                                            let visibleEnd = (horizontalOffset + geometry.size.width + 1536) / pixelsPerSecond
                                            ZStack(alignment: .topLeading) {
                                        ForEach(Array(originalSong.tracks.enumerated()).filter { index, track in track.clips.contains { $0.id == movingClip } || (rulerHeight + rows.offsets[index] + rows.heights[index] >= visibleY - 512 && rulerHeight + rows.offsets[index] <= visibleY + geometry.size.height + 1024) }, id: \.element.id) { index, track in
                                            ForEach(track.clips.filter { $0.id == movingClip || ($0.startTime <= visibleEnd && $0.startTime + $0.duration >= visibleStart) }) { clip in
                                                let lane: CGFloat = CGFloat(rows.lanes[index].lanes[clip.id] ?? 0)
                                                let itemY: CGFloat = rulerHeight + rows.offsets[index] + lane * rows.laneHeights[index] + 3
                                                tabletItemInput(clip, track: track, index: index, rows: rows, song: song, originalSong: originalSong,
                                                    pixelsPerSecond: pixelsPerSecond, itemY: itemY, rulerHeight: rulerHeight, extent: extent)
                                            }
                                        }
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }.frame(width: width, height: contentHeight)
                                        #endif
                                        TimelineScrollLayer(position: horizontalScroll) { horizontalOffset in
                                        TimelinePinnedLayer(position: verticalScroll.pinned, width: width, height: contentHeight) { verticalOffset in
                                            ZStack(alignment: .topLeading) {
                                        let headerViewport = TimelineHeaderViewport.covering(offset: horizontalOffset, width: geometry.size.width, height: geometry.size.height)
                                        TimelineStaticHeaderLayer(identity: TimelineStaticHeaderIdentity(controller: ObjectIdentifier(show), project: show.snapshot.project.id, renderKey: renderKey,
                                            documentSize: CGSize(width: width, height: contentHeight), viewport: headerViewport, rulerHeight: rulerHeight, extent: extent,
                                            verticalOffset: verticalOffset, editingRegion: editingRegion, unifyingRegion: unifyingRegion, selectedRegion: selectedRegion, locale: locale)) {
                                            let visibleStart = max(0, headerViewport.minX - 1024) / pixelsPerSecond
                                            let visibleEnd = (headerViewport.maxX + 1536) / pixelsPerSecond
                                            ZStack(alignment: .topLeading) {
                                        TimelineHeader(visibleRect: CGRect(x: headerViewport.minX, y: 0, width: headerViewport.width, height: rulerHeight), song: song, renderKey: renderKey, extent: extent, documentWidth: width).equatable()
                                            .frame(width: width, height: rulerHeight).offset(y: verticalOffset)
                                        #if !os(macOS)
                                        TimelineMarkerLane(visibleRect: CGRect(x: headerViewport.minX, y: 0, width: headerViewport.width, height: markerLaneHeight), song: song, renderKey: renderKey, extent: extent, documentWidth: width)
                                            .frame(width: width, height: markerLaneHeight).clipped()
                                            .offset(y: verticalOffset + CGFloat(regionLanes.count) * 16)
                                        #endif
                                        ForEach(Array(song.parts.enumerated()).filter { $0.element.parentRegionID == nil && ($0.element.id == editingRegion || $0.element.id == unifyingRegion || $0.element.id == movingRegion || $0.element.id == resizingRegion || ($0.element.startTime <= visibleEnd && $0.element.endTime >= visibleStart)) }, id: \.element.id) { index, part in
                                            let edgePadding: CGFloat = song.parts.contains(where: { $0.parentRegionID == part.id }) ? 0 : 10
                                            let regionWidth: CGFloat = max(1, CGFloat(part.endTime - part.startTime) * pixelsPerSecond) + edgePadding * 2
                                            regionHitArea(part, song: originalSong, pixelsPerSecond: pixelsPerSecond, canUnify: overlapCache.regions(song: originalSong, revision: revision).contains(part.id))
                                                .frame(width: regionWidth, height: edgePadding > 0 ? 24 : 16)
                                                .overlay(alignment: .center) {
                                                    if selectedRegion == part.id {
                                                        Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                                                            .padding(.horizontal, edgePadding)
                                                            .padding(.vertical, edgePadding > 0 ? 4 : 0)
                                                            .allowsHitTesting(false)
                                                    }
                                                }
                                                .background { regionEditorAnchors(part, index: index) }
                                                .offset(x: part.startTime * pixelsPerSecond - edgePadding, y: verticalOffset + CGFloat(regionLanes.lanes[part.id] ?? 0) * 16 - (edgePadding > 0 ? 4 : 0))
                                        }
                                        #if os(macOS)
                                        TimelineDraggableMarkerLayer(song: song, scale: pixelsPerSecond, renderKey: renderKey, extent: extent,
                                            viewport: CGRect(x: headerViewport.minX, y: 0, width: headerViewport.width, height: max(markerLaneHeight, geometry.size.height - CGFloat(regionLanes.count) * 16)),
                                            edit: { editingMarker = $0 }, delete: { show.deleteManualMarker($0) },
                                            seek: { show.send(.editSeek, value: $0.position) }, move: { show.setMarker($0) }, tempoOnly: false)
                                            .frame(width: width, height: max(markerLaneHeight, geometry.size.height - CGFloat(regionLanes.count) * 16))
                                            .offset(y: verticalOffset + CGFloat(regionLanes.count) * 16)
                                        TimelineRulerInput(markerCursor: { MarkerEditClickView.usesMoveCursor(for: $0) }, extend: { timelineExtent = extent + 240 }, selectTime: { first, last in
                                            TimelineAreaSelection.shared.update(song: song.id,
                                                from: itemPosition(first * extent, song: song, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true),
                                                to: itemPosition(last * extent, song: song, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true))
                                            show.updateActiveLoopArea()
                                        }, selectedTime: {
                                            guard let range = TimelineAreaSelection.shared.range, range.song == song.id else { return nil }
                                            return (range.start / extent, range.end / extent)
                                        }, resizeTime: { fraction, left in
                                            guard let range = TimelineAreaSelection.shared.range, range.song == song.id else { return }
                                            let position = itemPosition(fraction * extent, song: song, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true)
                                            TimelineAreaSelection.shared.update(song: song.id,
                                                from: left ? min(position, range.end - 0.001) : range.start,
                                                to: left ? range.end : max(position, range.start + 0.001))
                                            show.updateActiveLoopArea()
                                        }) { fraction, rightClick, freePositioning in
                                            show.send(rightClick ? .subSeek : .editSeek, value: gridPosition(fraction * extent, song: song, pixelsPerSecond: pixelsPerSecond, freePositioning: freePositioning))
                                        }.frame(width: width, height: barLaneHeight).offset(y: rulerHeight - barLaneHeight + verticalOffset)
                                        TimelineDraggableMarkerLayer(song: song, scale: pixelsPerSecond, renderKey: renderKey, extent: extent,
                                            viewport: CGRect(x: headerViewport.minX, y: 0, width: headerViewport.width, height: max(markerLaneHeight, geometry.size.height - rulerHeight + tempoLaneHeight + barLaneHeight)),
                                            edit: { editingTempoMarker = $0 }, delete: { show.deleteManualMarker($0) },
                                            seek: { show.send(.editSeek, value: $0.position) }, move: { show.setMarker($0) })
                                            .frame(width: width, height: max(markerLaneHeight, geometry.size.height - rulerHeight + tempoLaneHeight + barLaneHeight))
                                            .offset(y: rulerHeight - barLaneHeight - tempoLaneHeight + verticalOffset)
                                        #else
                                        Color.clear.frame(width: width, height: barLaneHeight).contentShape(Rectangle()).offset(y: rulerHeight - barLaneHeight + verticalOffset)
                                            .gesture(SpatialTapGesture().onEnded { value in
                                                show.send(.editSeek, value: gridPosition(min(1, max(0, value.location.x / width)) * extent, song: song, pixelsPerSecond: pixelsPerSecond))
                                            })
                                        #endif
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }.equatable()
                                        TimelineAreaOverlay(song: song.id, scale: pixelsPerSecond, height: geometry.size.height, rulerHeight: rulerHeight)
                                            .offset(y: verticalOffset)
                                        GridExternalFilePreviewOverlay(preview: insertionPreview, scale: pixelsPerSecond,
                                            viewport: CGRect(x: horizontalOffset, y: verticalOffset,
                                                width: max(1, geometry.size.width - labelWidth - dividerWidth), height: geometry.size.height), rulerHeight: rulerHeight)
                                        GridInsertionPreviewOverlay(preview: insertionPreview, scale: pixelsPerSecond, rulerHeight: rulerHeight, viewportHeight: geometry.size.height)
                                            .offset(y: verticalOffset).allowsHitTesting(false)
                                        RegionBoundaryOverlay(parts: song.parts, scale: pixelsPerSecond, originX: max(0, horizontalOffset - 512))
                                            .frame(width: geometry.size.width + 1024, height: geometry.size.height)
                                            .offset(x: max(0, horizontalOffset - 512), y: verticalOffset)
                                            .allowsHitTesting(false)
                                        // Draw needles last so coincident region/marker lines cannot cover them.
                                        #if os(macOS)
                                        NativeTimelineNeedles(show: show, width: width, height: contentHeight,
                                            rulerHeight: rulerHeight, verticalOffset: verticalOffset, extent: extent,
                                            seek: { position, secondary in
                                                if let song = show.current {
                                                    show.send(secondary ? .subSeek : .editSeek,
                                                        value: gridPosition(position, song: song, pixelsPerSecond: pixelsPerSecond))
                                                }
                                            }, marker: { tempo in if tempo { beginTempoMarker() } else { beginMarker() } })
                                            .frame(width: width, height: contentHeight)
                                        #else
                                        TimelinePlaybackLayer(show: show) { playback in
                                            ZStack(alignment: .topLeading) {
                                                cursor(position: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, duration: extent, width: width, height: contentHeight, secondary: false, rulerHeight: rulerHeight, verticalOffset: verticalOffset, subPosition: playback.subPosition)
                                                if show.snapshot.transport.playing || show.snapshot.transport.paused == true {
                                                    cursor(position: playback.mainPosition, duration: extent, width: width, height: contentHeight, secondary: false, rulerHeight: rulerHeight, verticalOffset: verticalOffset, playback: true)
                                                }
                                                if show.subCursorVisible {
                                                cursor(position: playback.subPosition, duration: extent, width: width, height: contentHeight, secondary: true, rulerHeight: rulerHeight, verticalOffset: verticalOffset, subPosition: playback.subPosition)
                                                    .modifier(SubCursorBlink())
                                                }
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }
                                        #endif
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }.frame(width: width, height: contentHeight)
                                        }

                                    }
                                    #if os(macOS)
                                    .overlay(alignment: .topLeading) {
                                        NativeTimelinePinnedLayer(width: max(0, geometry.size.width - labelWidth - dividerWidth), height: geometry.size.height, pinHorizontally: true, content:
                                                GridSelectionInput(origin: .zero, headerHeight: rulerHeight, items: [], selected: selectedClips, selectionChanged: { next in
                                                    selectedClips = next
                                                    selectedClip = selectionLayout.items.first { next.contains($0.id) }?.id
                                                }, mute: { id in if originalSong.tracks.contains(where: { $0.kind == .standard && $0.clips.contains { $0.id == id } }) { show.send(.clipMute, target: id) } }, move: { id, translation, pointerY, ended in
                                                    guard movingClip == nil || movingClip == id,
                                                          !originalSong.tracks.contains(where: { $0.kind == .timecode && $0.clips.contains { $0.id == id } }),
                                                          let source = originalSong.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
                                                          let clip = originalSong.tracks[source].clips.first(where: { $0.id == id }) else { return }
                                                    movingClip = id
                                                    movingStart = abs(translation.width) < 3 ? clip.startTime : itemPosition(clip.startTime + translation.width / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                                                    let targetY = pointerY - rulerHeight
                                                    if !pointerY.isFinite { clearClipDrag(); return }
                                                    movingTrack = dragDestination(y: targetY, source: originalSong.tracks[source], song: originalSong, rows: rows)
                                                    if movingTrack == originalSong.tracks[source].id {
                                                        movingStart = originalSong.tracks[source].constrainedItemStart(movingStart, item: clip)
                                                    }
                                                    insertionPreview.update(movingStart)
                                                    timelineExtent = max(extent, movingStart + clip.duration + 120)
                                                    if ended {
                                                        commitClipDrag(id)
                                                        clearClipDrag()
                                                    }
                                                }, seek: { x, freePositioning in show.send(.editSeek, value: gridPosition(x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond, freePositioning: freePositioning)) }, createRegion: { show.regionsFromSelection(selectedClips.contains($0) ? selectedClips : [$0]) }, indexedLayout: selectionLayout, pixelsPerSecond: pixelsPerSecond, interactionBlocked: gridInteractionBlocked, resize: { id, left, delta, ended in
                                                    guard let clip = originalSong.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { return }
                                                    resizingItem = id
                                                    let position = itemPosition((left ? clip.startTime : clip.startTime + clip.duration) + delta / pixelsPerSecond, song: originalSong, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true)
                                                    let minimumDuration = min(clip.duration, max(0.01, 16 / pixelsPerSecond))
                                                    resizedItemStart = left ? min(max(0, position), clip.startTime + clip.duration - minimumDuration) : clip.startTime
                                                    resizedItemEnd = left ? clip.startTime + clip.duration : max(clip.startTime + minimumDuration, position)
                                                    if let track = originalSong.tracks.first(where: { $0.clips.contains { $0.id == id } }) {
                                                        (resizedItemStart, resizedItemEnd) = track.constrainedItemEdges(start: resizedItemStart, end: resizedItemEnd, item: clip)
                                                    }
                                                    timelineExtent = max(extent, resizedItemEnd + 120)
                                                    if ended { show.resizeItem(id, start: resizedItemStart, end: resizedItemEnd); resizingItem = nil }
                                                }, fade: { id, left, seconds, ended in
                                                    if ended { show.setItemFade(id, fadeIn: left, seconds: seconds) }
                                                    else { show.previewItemFade(id, fadeIn: left, seconds: seconds) }
                                                }, gain: { id, value, ended in
                                                    show.previewItemGain(id, gain: value)
                                                    if ended { show.setItemGain(id, gain: value); itemGainPreview.clear() }
                                                    else { itemGainPreview.update(id: id, gain: value) }
                                                }, phase: { show.toggleItemPhase($0) }, pan: { id, value, ended in
                                                    if ended { show.setItemPan(id, pan: value) }
                                                    else { show.previewItemPan(id, pan: value) }
                                                }, fx: { id, bypass in
                                                    if bypass { show.toggleClipFXAllBypass(id) }
                                                    else { openClipFXChain(id) }
                                                }, editMIDI: { MIDIEditorWindows.shared.open(show: show, item: $0) }, createMIDI: { point, length in
                                                    let y = point.y - rulerHeight
                                                    guard let index = rows.offsets.indices.first(where: { y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0] }), song.tracks[index].kind == .standard else { return }
                                                    let range = TimelineAreaSelection.shared.range
                                                    let start = length == nil && range?.song == song.id ? range!.start : itemPosition(point.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                                                    let duration: Double? = length.map { max(0.01, itemPosition((point.x + $0) / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond) - start) } ?? (range?.song == song.id ? range!.end - range!.start : nil)
                                                    if let id = show.addMIDIItem(track: song.tracks[index].id, start: start, duration: duration) { MIDIEditorWindows.shared.open(show: show, item: id) }
                                                }, editText: { editTextItem($0) }, reRender: { reRenderItems($0) }, convert: { ids, mode in show.convertItems(ids, mode: mode) }, freezeMIDI: { ids, channels in reRenderItems(ids, midiChannels: channels) }, glue: { glueItems($0) }, tuner: { tuningItems = $0; showingItemTuner = true }, normalize: { ids in
                                                    beginNormalize(ids)
                                                }, split: { confirmSplit($0) }, export: { ids in
                                                    if let current = show.current {
                                                        itemExport = ItemAudioExportRequest(project: show.snapshot.project, song: current, items: ids, mediaDirectory: documents.currentURL?.deletingLastPathComponent())
                                                    }
                                                }, itemGuide: {
                                                    if resizingItem != nil {
                                                        return CGRect(x: resizedItemStart * pixelsPerSecond + 1, y: 0, width: max(0, (resizedItemEnd - resizedItemStart) * pixelsPerSecond - 2), height: 0)
                                                    }
                                                    if let movingClip, let clip = originalSong.tracks.lazy.flatMap(\.clips).first(where: { $0.id == movingClip }) {
                                                        return CGRect(x: movingStart * pixelsPerSecond + 1, y: 0, width: max(0, clip.duration * pixelsPerSecond - 2), height: 0)
                                                    }
                                                    return nil
                                                }())
                                                .frame(width: max(0,geometry.size.width-labelWidth-dividerWidth), height: geometry.size.height)
                                        ).frame(width: width, height: contentHeight, alignment: .topLeading)
                                    }
                                    .background(TimelineWheelInput(zoom: zoom, position: editPosition / extent, extend: { timelineExtent = extent + 240 }, horizontalOffsetChanged: { if horizontalScroll.offset != $0 { horizontalScroll.offset = $0 } }, verticalOffsetChanged: { offset in
                                        let moved = abs(verticalScroll.offset - offset) > 0.001
                                        verticalScroll.update(offset)
                                        if moved, mixerResizeState.includeWidthReserve() {
                                            mixerScrollController.scrollView?.window?.contentView?.layoutSubtreeIfNeeded()
                                        }
                                    }, focusRequest: show.regionFocusRequest, focusX: show.snapshot.transport.subPlay.playing ? nil : ((show.navigationFocusPosition ?? show.restoredCursorPosition).map { $0 * pixelsPerSecond } ?? song.parts.first(where: { $0.id == show.focusedRegion }).map { $0.startTime * pixelsPerSecond }), cursorX: editPosition * pixelsPerSecond, modelUnitWidth: extent * 10, interactionBlocked: gridInteractionBlocked, changeTrackHeight: { factor, smoothWheel in
                                        changeTrackHeight(factor, smoothWheel: smoothWheel)
                                    }, livePosition: { show.timelineZoomPosition / extent }))
                                    #endif
                                    .coordinateSpace(name: "timeline").frame(width: width, height: contentHeight, alignment: .topLeading)
                                    .contentShape(Rectangle())
                                    #if !os(macOS)
                                    .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: importDrop)
                                    #endif
                                }.frame(width: max(0, geometry.size.width - labelWidth - dividerWidth), height: contentHeight)
                                }.frame(width: max(0, geometry.size.width - labelWidth - dividerWidth), height: contentHeight)
                            }.frame(width: geometry.size.width, height: contentHeight, alignment: .topLeading)
                            #if os(macOS)
                            .background(SidebarScrollProbe(controller: mixerScrollController, prepareScroll: { offset in
                                let previous = verticalScroll.tiles.offset
                                verticalScroll.update(offset)
                                let restoreWidths = mixerResizeState.includeWidthReserve()
                                if restoreWidths {
                                    // The resize scope lives outside the native document host.
                                    // Commit it once before a simultaneous scroll exposes rows.
                                    mixerScrollController.scrollView?.window?.contentView?.layoutSubtreeIfNeeded()
                                }
                                // Existing tiles cover a band above and three below the published
                                // origin. Ordinary thumb motion stays inside this reserve;
                                // only a jump outside it needs a synchronous layout.
                                return offset < previous - 256 || offset > previous + 768 || restoreWidths
                            }))
                            #endif
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            if labelWidth > 0 {
                                HStack(spacing: 4) {
                                    Text("Track-Mixer").lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button { addingTrack = true } label: {
                                        Text(verbatim: "Add").font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(JarasTheme.accent).padding(.horizontal, 7).frame(height: 24)
                                            .background(JarasTheme.accent.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 4))
                                            .contentShape(Rectangle()).fixedSize(horizontal: true, vertical: false)
                                    }.buttonStyle(.plain).accessibilityLabel("Add Track").jarasHelp("Criar pista")
                                        .padding(.trailing, 5)
                                }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(JarasTheme.secondary)
                                .frame(width: labelWidth, height: rulerHeight).clipped().background(JarasTheme.mixer)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            mixerDivider(width: labelWidth, maximum: maximumLabelWidth)
                                .frame(width: 20, height: geometry.size.height)
                                .offset(x: labelWidth + dividerWidth / 2 - 10)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .background(RegionShortcut(hasDeletionSelection: { deleteTarget != .none }, delete: { deleteSelection() }, undo: { show.undo() }, redo: { show.redo() }, create: {
            if let range = TimelineAreaSelection.shared.range, range.song == show.current?.id {
                show.regionFromTimeSelection(song: range.song, start: range.start, end: range.end)
            } else { show.regionsFromSelection(selectedClips) }
        }, selectAll: { selectAllItems() }, copy: { copyGridItems() }, move: { copyGridItems(moving: true) }, paste: {
            switch GridMediaClipboard.shared.source() {
            case .files(let urls):
                documents.pasteMedia(urls, track: selectedTrack)
            case .items:
                let pasted = show.pasteItems()
                if !pasted.isEmpty { selectedClips = pasted; selectedClip = pasted.first }
            case .none: break
            }
        }, createMarker: {
            beginMarker()
        }, createSectionMarker: { beginMarker(section: true) }, escape: {
            let transport = show.snapshot.transport
            let cancellingTransport = transport.queuedSectionMarkerId != nil || transport.loop.enabled ||
                transport.queuedRegionId != nil || transport.queue.songId != nil
            show.send(.escape, value: TimelineAreaSelection.shared.range == nil ? 0 : 1)
            if !cancellingTransport {
                TimelineAreaSelection.shared.clear()
                selectedClip = nil; selectedClips.removeAll()
                selectedTrack = nil; selectedTracks.removeAll()
            }
        }))
        .onDisappear { trackHeightMotion.cancel() }
        .onChange(of: gridInteractionBlocked) { blocked in
            if blocked { trackHeightMotion.cancel() }
        }
        #endif
        .sheet(isPresented: $showingReRender) {
            ItemReRenderProgressView(progress: reRenderProgress, title: reRenderTitle,
                                     cancel: glueCancellation.map { cancellation in { cancellation.cancel() } }) { showingReRender = false }
        }
        .sheet(item: $itemExport) { ItemAudioExportView(request: $0) }
        .sheet(isPresented: $showingItemTuner) { ItemTunerEditor(show: show, items: tuningItems) }
        .sheet(isPresented: $showingNormalize) { ItemNormalizationEditor(show: show, documents: documents, items: normalizingItems) }
        .alert(Text(verbatim: confirmingSplit ? JarasLocalization.string("Split selected items at the edit cursor?") : ""), isPresented: $confirmingSplit) {
            Button("Cancel", role: .cancel) { itemsToSplit = [] }
            Button("Split") { show.splitItems(itemsToSplit, at: splitPosition); itemsToSplit = [] }
        }
        .alert(Text(verbatim: confirmingTrackDelete ? JarasLocalization.string("Delete selected tracks and their items?") : ""), isPresented: $confirmingTrackDelete) {
            Button("Cancel", role: .cancel) { tracksToDelete = []; trackDeletionContext = nil }
            Button("Delete", role: .destructive) {
                if let context = trackDeletionContext, context.project == show.snapshot.project.id, context.song == show.current?.id {
                    deleteTracks(tracksToDelete)
                }
                tracksToDelete = []; trackDeletionContext = nil
            }
        }
        .alert(Text(verbatim: confirmingRegionDelete ? JarasLocalization.string("Delete this region?") : ""), isPresented: $confirmingRegionDelete) {
            Button("Cancel", role: .cancel) { regionToDelete = nil }
            Button("Delete", role: .destructive) {
                if let target = regionToDelete, target.project == show.snapshot.project.id, target.song == show.current?.id {
                    show.deleteRegion(target.region, playlist: nil)
                }
                regionToDelete = nil
            }
        }
        .sheet(item: $editingMarker) { marker in
            NameColorEditor(title: marker.isSection ? "Section marker" : "Editar marcador", initialName: marker.markerEditorName, initialColor: marker.color, save: { name, color in
                var edited = marker; edited.name = name; edited.color = color
                edited.section = false; edited.loopSection = false
                show.setMarker(edited)
            }, maximumNameLength: marker.unifiedRegionID == nil ? (marker.isSection ? TimelineMarker.maximumSectionNameLength : TimelineMarker.maximumNameLength) : nil).environment(\.locale, locale)
        }
        .onChange(of: selectedTrack) { show.reportTrackSelection($0) }
        .onChange(of: show.trackSelectionRequest) { request in
            if let request { selectedTrack = request.track; selectedTracks = [request.track] }
        }
        .onReceive(show.$detectBPMRegion) { id in
            guard let id, bpmWorker == nil else { return }; bpmRegions = [id]; confirmingBPMDetection = true; show.detectBPMRegion = nil
        }
        .onReceive(show.$detectBPMRegions) { ids in
            guard !ids.isEmpty, bpmWorker == nil else { return }
            bpmRegions = ids; confirmingBPMDetection = true; show.detectBPMRegions = []
        }
        .alert(Text(verbatim: confirmingBPMDetection ? JarasLocalization.string("Detect BPM from the Click track?") : ""), isPresented: $confirmingBPMDetection) {
            Button("Cancel", role: .cancel) { bpmRegions = [] }
            Button("Detect BPM") { detectBPM() }
        }
        .onReceive(show.$tempoMarkerRequest.dropFirst()) { _ in beginTempoMarker() }
        .sheet(item: $editingTempoMarker) { marker in TempoMarkerEditor(marker: marker, save: { show.setMarker($0) }).environment(\.locale, locale) }
        .onReceive(show.$normalizeItemsRequest.dropFirst()) { _ in beginNormalize(selectedClips) }
        .onChange(of: show.splitItemsRequest) { _ in confirmSplit(selectedClips) }
        .onChange(of: show.addTrackRequest) { _ in addingTrack = true }
        .onChange(of: selectedTracks) {
            AudioExportSelection.shared.setTracks($0, song: show.current?.id)
            show.setMixerTrackSelection($0, anchor: selectedTrack)
        }
        .onChange(of: show.mixerTrackSelection) { ids in
            guard selectedTracks != ids else { return }
            selectedTrack = show.selectedTrackForActions; selectedTracks = ids
        }
        .onChange(of: selectedClips) { AudioExportSelection.shared.setClips($0, song: show.current?.id) }
        .onChange(of: show.current?.id) { _ in itemGainPreview.clear(); insertionPreview.update(nil); selectedClip = nil; selectedClips.removeAll(); selectedTrack = nil; selectedTracks.removeAll() }
        .background(JarasTheme.background).sheet(isPresented: $addingTrack) {
            CreateTrackEditor(show: show, afterTrack: selectedTrack, close: { addingTrack = false }, created: { ids in
                let selectable = show.current?.tracks.filter { $0.kind == .standard && ids.contains($0.id) }.map(\.id) ?? []
                selectedTrack = selectable.first; selectedTracks = Set(selectable)
            }).environment(\.locale, locale)
        }
    }
    #if os(macOS)
    private func changeTrackHeight(_ factor: Double, smoothWheel: Bool) {
        trackHeightMotion.change(factor: factor, current: trackHeight, smoothWheel: smoothWheel) { trackHeight = $0 }
    }
    #endif
    @ViewBuilder private func regionEditorAnchors(_ part: Part, index: Int) -> some View {
        // Closed editors must not publish anchors for every region on resize.
        if editingRegion == part.id {
            Color.clear.popover(isPresented: Binding(get: { editingRegion == part.id }, set: { if !$0 { editingRegion = nil } })) {
                RegionEditor(region: part, initialColor: part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965)) { name, color, uppercase in
                    show.editRegion(part.id, name: name, color: color, uppercaseName: uppercase)
                }.environment(\.locale, locale)
            }
        }
        if unifyingRegion == part.id {
            Color.clear.popover(isPresented: Binding(get: { unifyingRegion == part.id }, set: { if !$0 { unifyingRegion = nil } })) {
                UnifyRegionEditor { show.unifyRegions(containing: part.id, name: $0) }.environment(\.locale, locale)
            }
        }
    }
    #if !os(macOS)
    @ViewBuilder private func tabletItemInput(_ clip: AudioClip, track: Track, index: Int, rows: TrackRowLayout,
                                              song: Song, originalSong: Song, pixelsPerSecond: Double,
                                              itemY: CGFloat, rulerHeight: CGFloat, extent: Double) -> some View {
        ClipDragInput(item: GridSelectionItem(id: clip.id,
            rect: CGRect(x: clip.startTime * pixelsPerSecond + 1, y: itemY,
                width: max(2, clip.duration * pixelsPerSecond - 2), height: rows.laneHeights[index] - 6),
            editable: track.kind == .standard || clip.isProjectionMedia, movable: track.kind != .timecode || clip.isProjectionMedia,
            muted: clip.muted == true, duration: clip.duration,
            fadeIn: clip.fadeIn ?? 0, fadeOut: clip.fadeOut ?? 0), originY: itemY, click: { point in
            show.send(.editSeek, value: gridPosition(point.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond))
        }, select: { additive in
            if additive {
                if selectedClips.contains(clip.id) { selectedClips.remove(clip.id) }
                else { selectedClips.insert(clip.id) }
                selectedClip = selectedClips.contains(clip.id) ? clip.id : selectedClips.first
            } else {
                selectedClip = clip.id
                selectedClips = [clip.id]
            }
        }, resize: { left, delta, ended in
            resizingItem = clip.id
            let position = itemPosition((left ? clip.startTime : clip.startTime + clip.duration) + delta / pixelsPerSecond,
                song: song, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true)
            let minimumDuration = min(clip.duration, max(0.01, 16 / pixelsPerSecond))
            resizedItemStart = left ? min(max(0, position), clip.startTime + clip.duration - minimumDuration) : clip.startTime
            resizedItemEnd = left ? clip.startTime + clip.duration : max(clip.startTime + minimumDuration, position)
            (resizedItemStart, resizedItemEnd) = track.constrainedItemEdges(start: resizedItemStart, end: resizedItemEnd, item: clip)
            timelineExtent = max(extent, resizedItemEnd + 120)
            if ended { show.resizeItem(clip.id, start: resizedItemStart, end: resizedItemEnd); resizingItem = nil }
        }, fade: { left, seconds, ended in
            if ended { show.setItemFade(clip.id, fadeIn: left, seconds: seconds) }
            else { show.previewItemFade(clip.id, fadeIn: left, seconds: seconds) }
        }, mute: track.kind == .standard ? { show.send(.clipMute, target: clip.id) } : nil,
           cancel: { clearClipDrag(); resizingItem = nil }) { translation, pointerY, ended in
            // A gesture belongs to the item pressed until mouse-up.
            guard track.kind != .timecode, movingClip == nil || movingClip == clip.id else { return }
            movingClip = clip.id
            let originalStart = clip.startTime
            movingStart = abs(translation.width) < 3 ? originalStart : itemPosition(originalStart + translation.width / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
            let targetY = pointerY - rulerHeight
            movingTrack = dragDestination(y: targetY, source: track, song: originalSong, rows: rows)
            if movingTrack == track.id { movingStart = track.constrainedItemStart(movingStart, item: clip) }
            insertionPreview.update(movingStart)
            timelineExtent = max(extent, movingStart + clip.duration + 120)
            if ended {
                if abs(translation.width) >= 3 || abs(translation.height) >= 3 {
                    commitClipDrag(clip.id)
                }
                clearClipDrag()
            }
        }
        .frame(width: max(2, clip.duration * pixelsPerSecond), height: rows.laneHeights[index] - 6)
        .offset(x: clip.startTime * pixelsPerSecond, y: itemY)
            .contextMenu {
                if track.kind.isText && !clip.isProjectionMedia { Button("Edit") { editTextItem(clip.id) } }
                else if track.kind != .timecode { Button("Criar região do item") { show.regionsFromSelection(selectedClips.contains(clip.id) ? selectedClips : [clip.id]) } }
            }
        if track.kind.isText && !clip.isProjectionMedia && clip.duration * pixelsPerSecond >= 34 {
            Button("Edit") { editTextItem(clip.id) }
                .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 13).background(Color.black.opacity(0.28))
                .buttonStyle(.plain).offset(x: clip.startTime * pixelsPerSecond + 1, y: itemY)
        }
    }
    #endif
    private func addStandardTrackAtEnd() {
        guard let song = show.current else { return }
        let existingNames = Set(song.tracks.map(\.name))
        var number = song.tracks.count + 1
        var name = String(format: JarasLocalization.string("Track %lld"), Int64(number))
        while existingNames.contains(name) {
            number += 1
            name = String(format: JarasLocalization.string("Track %lld"), Int64(number))
        }
        let channels = TrackRecording.shared.inputChannels
        let inputs = channels > 0 ? [OutputPatch(firstChannel: 1, channelCount: min(2, channels))] : []
        guard let id = show.addTracks(name: name, role: .other, count: 1, inputPatches: inputs).first else { return }
        selectedTrack = id
        selectedTracks = [id]
    }
    private func dragDestination(y: CGFloat, source: Track, song: Song, rows: TrackRowLayout) -> UUID {
        let media = movingClip.flatMap { id in source.clips.first { $0.id == id } }?.isProjectionMedia == true
        guard source.kind == .standard || media else { provisionalTrack = nil; return source.id }
        if let index = song.tracks.indices.first(where: { y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0] }) {
            provisionalTrack = nil
            let target = song.tracks[index]
            if media, let clip = movingClip.flatMap({ id in source.clips.first { $0.id == id } }),
               target.id == source.id || target.canPlaceItem(start: movingStart, duration: clip.duration, media: true) { return target.id }
            if source.kind == .standard { return target.kind == .standard ? target.id : source.id }
            return source.id
        }
        let last = song.tracks.count - 1
        let bottom = last >= 0 ? rows.offsets[last] + rows.heights[last] : 0
        guard source.kind == .standard, y >= bottom else {
            provisionalTrack = nil
            return source.id
        }
        if provisionalTrack == nil {
            let names = Set(song.tracks.map(\.name))
            var number = song.tracks.count + 1
            var name = String(format: JarasLocalization.string("Track %lld"), Int64(number))
            while names.contains(name) {
                number += 1
                name = String(format: JarasLocalization.string("Track %lld"), Int64(number))
            }
            var track = Track(id: UUID(), name: name, role: .other, color: Track.defaultStandardColor)
            let channels = TrackRecording.shared.inputChannels
            if channels > 0 { track.inputPatch = OutputPatch(firstChannel: 1, channelCount: min(2, channels)) }
            provisionalTrack = track
        }
        return provisionalTrack!.id
    }
    private func commitClipDrag(_ id: UUID) {
        if let provisionalTrack, movingTrack == provisionalTrack.id {
            show.moveClipToNewStandardTrack(id, start: movingStart, newTrack: provisionalTrack)
        } else { show.moveClip(id, start: movingStart, track: movingTrack) }
    }
    private func clearClipDrag() {
        movingClip = nil; movingTrack = nil; provisionalTrack = nil
        insertionPreview.update(nil)
    }
    private func selectAllItems() -> Bool {
        guard let song = show.current, !selectedClips.isEmpty else { return false }
        let all = Set(song.tracks.flatMap(\.clips).map(\.id))
        guard !selectedClips.isDisjoint(with: all) else { return false }
        selectedClips = all
        if selectedClip.map(all.contains) != true { selectedClip = song.tracks.lazy.flatMap(\.clips).first?.id }
        return true
    }

    private func glueItems(_ ids: Set<UUID>) {
        guard show.canExecute(), reRenderWorker == nil, !documents.busy, let song = show.current,
              let directory = documents.currentURL?.deletingLastPathComponent() else { return }
        let groups = song.tracks.filter { $0.kind == .standard }.compactMap { track -> (Track, [AudioClip])? in
            let clips = track.clips.filter { ids.contains($0.id) }
            return clips.isEmpty ? nil : (track, clips)
        }
        guard !groups.isEmpty else { return }
        do { for (track, clips) in groups { try ItemGlue.validate(track: track, clips: clips) } }
        catch { show.message = JarasLocalization.string(error.localizedDescription); return }
        if groups.contains(where: { $0.1.contains { $0.midi == nil } }), !AudioDestinationSpace.confirm(at: directory.appendingPathComponent("Stems", isDirectory: true)) { return }
        let project = show.snapshot.project, cancellation = AudioExportCancellation(), progressModel = reRenderProgress
        let instruments = Dictionary(uniqueKeysWithValues: groups.map { ($0.0.id, ItemReRender.midiInstruments(for: $0.0)) })
        glueCancellation = cancellation; reRenderTitle = "Unify items"
        reRenderProgress.total = groups.count; reRenderProgress.index = 0
        reRenderProgress.fileName = groups[0].0.name; reRenderProgress.fraction = 0; reRenderProgress.error = nil
        documents.busy = true; showingReRender = true
        reRenderWorker = Task {
            defer { reRenderWorker = nil; glueCancellation = nil; documents.busy = false }
            do {
                let replacements = try await Task.detached(priority: .utility) {
                    try ItemReRender.glueSelection(project: project, song: song, ids: ids, directory: directory, cancellation: cancellation, instruments: instruments) { index, total, update in
                        Task { @MainActor in
                            guard glueCancellation === cancellation else { return }
                            progressModel.index = index; progressModel.total = total
                            progressModel.fileName = update.fileName; progressModel.fraction = update.fraction
                        }
                    }
                }.value
                if cancellation.cancelled {
                    ItemReRender.discardGluedAudio(replacements, directory: directory)
                    showingReRender = false; return
                }
                guard show.replaceGluedItems(replacements, project: project.id, song: song.id) else {
                    ItemReRender.discardGluedAudio(replacements, directory: directory)
                    reRenderProgress.error = JarasLocalization.string(show.message.isEmpty ? "The selected items changed while unifying." : show.message)
                    return
                }
                selectedClips = Set(replacements.map { $0.rendered.id }); selectedClip = replacements.first?.rendered.id
                showingReRender = false
            } catch is CancellationError { showingReRender = false }
            catch { reRenderProgress.error = JarasLocalization.string(error.localizedDescription) }
        }
    }

    private func reRenderItems(_ ids: Set<UUID>, midiChannels: Int? = nil) {
        guard show.canExecute(), reRenderWorker == nil, !documents.busy, let initialSong = show.current,
              let directory = documents.currentURL?.deletingLastPathComponent() else { return }
        #if os(macOS)
        if midiChannels != nil {
            // An open VST editor can hold a newer preset than the project snapshot.
            for track in initialSong.tracks where track.kind == .standard && track.clips.contains(where: { ids.contains($0.id) && $0.midi != nil }) {
                for plugin in track.fx?.externalPlugins ?? [] {
                    ExternalPluginState.capture(show: show, track: track.id, identifier: plugin.id)
                }
            }
        }
        #endif
        guard let song = show.current, song.id == initialSong.id else { return }
        let entries = song.tracks.flatMap { track in
            track.clips.filter { clip in
                ids.contains(clip.id) && !clip.isImage && (track.kind == .standard || clip.isProjectionMedia) && (midiChannels != nil ? clip.midi != nil : clip.midi == nil && (clip.audioFile ?? track.audioFile) != nil)
            }.map { (track, $0) }
        }
        guard !entries.isEmpty else { return }
        guard AudioDestinationSpace.confirm(at: directory.appendingPathComponent("Stems", isDirectory: true)) else { return }
        let project = show.snapshot.project, settings = MediaProcessingFormat.load("rerender")
        reRenderTitle = "Re-render"
        documents.busy = true
        reRenderProgress.total = entries.count; reRenderProgress.index = 0
        reRenderProgress.fileName = entries[0].1.name; reRenderProgress.fraction = 0
        reRenderProgress.error = nil; showingReRender = true
        reRenderWorker = Task {
            defer { reRenderWorker = nil; documents.busy = false }
            do {
                for (index, entry) in entries.enumerated() {
                    let (track, clip) = entry
                    reRenderProgress.index = index; reRenderProgress.fileName = clip.name
                    reRenderProgress.fraction = 0
                    let progressModel = reRenderProgress
                    let instruments = midiChannels.map { _ in ItemReRender.midiInstruments(for: track) }
                    let result = try await Task.detached(priority: .utility) {
                        if let midiChannels, let instruments {
                            return try ItemReRender.renderMIDI(project: project, song: song, track: track, clip: clip, directory: directory,
                                channels: midiChannels, instruments: instruments, cancellation: AudioExportCancellation()) { update in
                                    Task { @MainActor in
                                        guard progressModel.index == index else { return }
                                        progressModel.fileName = update.fileName
                                        progressModel.fraction = update.fraction
                                    }
                                }
                        }
                        return try ItemReRender.render(project: project, song: song, track: track, clip: clip, directory: directory,
                                                settings: settings, cancellation: AudioExportCancellation()) { update in
                            Task { @MainActor in
                                guard progressModel.index == index else { return }
                                progressModel.fileName = update.fileName
                                progressModel.fraction = update.fraction
                            }
                        }
                    }.value
                    if !show.replaceRenderedItem(result, original: clip, track: track.id, project: project.id) {
                        if let path = result.audioFile?.path { try? FileManager.default.removeItem(at: directory.appendingPathComponent(path)) }
                        showingReRender = false
                        return
                    }
                }
                showingReRender = false
            } catch { reRenderProgress.error = error.localizedDescription }
        }
    }
    private func detectBPM() {
        guard bpmWorker == nil, !bpmRegions.isEmpty, let song = show.current,
              let directory = documents.currentURL?.deletingLastPathComponent() else { return }
        let project = show.snapshot.project.id
        let regions = bpmRegions.compactMap { id in song.parts.first { $0.id == id } }
        show.message = "Detecting BPM…"
        bpmWorker = Task {
            defer { bpmWorker = nil; bpmRegions = [] }
            var failures: [String] = []
            for region in regions {
                guard show.snapshot.project.id == project, show.current?.id == song.id else { return }
                do {
                    let detection = try await Task.detached(priority: .utility) {
                        try ClickTempoDetector.markersWithMeter(song: song, region: region) { file in
                            try TimelineAudioWaveform.clickTransients(directory.appendingPathComponent(file.path)).map {
                                ClickTempoDetector.Transient(position: $0.position, peak: $0.peak, shape: $0.shape)
                            }
                        }
                    }.value
                    guard show.snapshot.project.id == project, show.current?.id == song.id else { return }
                    if detection.markers.isEmpty {
                        failures.append(region.name + ": " + JarasLocalization.string("No stable click tempo was found."))
                        continue
                    }
                    guard show.applyDetectedTempo(detection.markers, project: project, song: song.id, region: region.id) else { return }
                } catch { failures.append(region.name + ": " + error.localizedDescription) }
            }
            show.message = failures.joined(separator: " · ")
        }
    }
    private func beginTempoMarker() {
        guard !gridInteractionBlocked, let song = show.current else { return }
        let position = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        guard show.canCreateMarker(at: position, tempo: true) else { return }
        let settings = song.tempoSection(at: position)
        editingTempoMarker = TimelineMarker(id: UUID(), name: "TEMPO", position: position, color: 0x999999,
            tempoBPM: settings.bpm, tempoBeats: settings.beats, tempoUnit: settings.unit, tempoTimebase: .global)
    }
    private func beginMarker(section: Bool = false) {
        guard !gridInteractionBlocked, show.current != nil else { return }
        let position = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        guard !section || show.canCreateSectionMarker(at: position) else { return }
        guard show.canCreateMarker(at: position) else { return }
        editingMarker = TimelineMarker(id: UUID(), name: "", position: position,
            color: [UInt32(0x51ef93), 0xffc857, 0xb478ff, 0x53cfff, 0xff7998].randomElement()!, section: section ? true : nil)
    }

    private func beginNormalize(_ ids: Set<UUID>) {
        guard !gridInteractionBlocked, !showingNormalize, let song = show.current else { return }
        let eligible = Set(song.tracks.filter { $0.kind == .standard }.flatMap(\.clips)
            .filter { ids.contains($0.id) && $0.audioFile != nil }.map(\.id))
        guard !eligible.isEmpty else { return }
        normalizingItems = eligible
        showingNormalize = true
    }

    private func previewItemEdit(_ song: Song) -> Song {
        guard resizingItem != nil else { return song }
        var result = song
        for track in result.tracks.indices {
            for clip in result.tracks[track].clips.indices {
                if result.tracks[track].clips[clip].id == resizingItem {
                    if result.tracks[track].kind == .standard {
                        result.tracks[track].clips[clip] = result.tracks[track].clips[clip].resized(start: resizedItemStart, end: resizedItemEnd)
                    } else {
                        result.tracks[track].clips[clip].startTime = resizedItemStart
                        result.tracks[track].clips[clip].duration = resizedItemEnd - resizedItemStart
                    }
                }
            }
        }
        return result
    }
    private func confirmSplit(_ ids: Set<UUID>) {
        let position = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        let eligible = show.current?.tracks.filter { $0.kind != .timecode }.flatMap(\.clips).filter { ids.contains($0.id) && position > $0.startTime && position < $0.startTime + $0.duration } ?? []
        guard !eligible.isEmpty else { return }
        itemsToSplit = Set(eligible.map(\.id)); splitPosition = position; confirmingSplit = true
    }
    private var deleteTarget: GridDeleteTarget {
        guard let song = show.current else { return .none }
        let items = selectedClips.intersection(song.tracks.flatMap(\.clips).map(\.id))
        let tracks = selectedTracks.intersection(song.tracks.map(\.id))
        return GridDeleteTarget(items: items, tracks: tracks)
    }
    private func deleteSelection() {
        guard !gridInteractionBlocked, let song = show.current else { return }
        switch deleteTarget {
        case .items(let ids): show.deleteItems(ids); selectedClips = []; selectedClip = nil
        case .tracks(let ids): requestTrackDeletion(ids)
        case .none:
            guard let region = show.focusedRegion, song.parts.contains(where: { $0.id == region && $0.parentRegionID == nil }) else { return }
            regionToDelete = (show.snapshot.project.id, song.id, region)
            confirmingRegionDelete = true
        }
    }
    private func requestTrackDeletion(_ ids: Set<UUID>) {
        guard !gridInteractionBlocked, let song = show.current else { return }
        let valid = ids.intersection(song.tracks.map(\.id))
        guard !valid.isEmpty else { return }
        if show.snapshot.project.tracksContainItems(valid) {
            tracksToDelete = valid
            trackDeletionContext = (show.snapshot.project.id, song.id)
            confirmingTrackDelete = true
        } else { deleteTracks(valid) }
    }
    private func deleteTracks(_ ids: Set<UUID>) {
        show.deleteTracks(ids)
        let tracks = show.current?.tracks ?? []
        selectedTracks.formIntersection(tracks.map(\.id))
        selectedTrack = selectedTrack.flatMap { selectedTracks.contains($0) ? $0 : nil } ?? selectedTracks.first
        selectedClips.formIntersection(tracks.flatMap(\.clips).map(\.id))
        selectedClip = selectedClip.flatMap { selectedClips.contains($0) ? $0 : nil } ?? selectedClips.first
    }
    #if os(macOS)
    private func copyGridItems(moving: Bool = false) -> Bool {
        guard show.copyItems(selectedClips, moving: moving) else { return false }
        GridMediaClipboard.shared.didCopyItems()
        return true
    }
    #endif

    private func selectTrack(_ id: UUID, in song: Song) {
        guard song.tracks.contains(where: { $0.id == id && $0.kind == .standard }) else { return }
        #if os(macOS)
        let flags = TrackSelectionRouter.shared.selectionModifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectedTrack,
           let start = song.tracks.firstIndex(where: { $0.id == anchor }), let end = song.tracks.firstIndex(where: { $0.id == id }) {
            selectedTracks = Set(song.tracks[min(start, end)...max(start, end)].filter { $0.kind == .standard }.map(\.id))
            return
        }
        if flags.contains(.command) || flags.contains(.control) {
            if selectedTracks.contains(id) { selectedTracks.remove(id) } else { selectedTracks.insert(id) }
            selectedTrack = id
            return
        }
        #endif
        selectedTrack = id; selectedTracks = [id]
    }
    private func trackToggle(_ title: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .bold))
                .foregroundStyle(active ? Color.black : JarasTheme.secondary)
                .frame(width: 23, height: 24)
                .background(active ? color : Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).accessibilityValue(active ? "On" : "Off")
    }
    @ViewBuilder
    private func regionHitArea(_ part: Part, song: Song, pixelsPerSecond: Double, canUnify: Bool) -> some View {
        #if os(macOS)
        RegionRightClick(edit: { editingRegion = part.id }, unify: canUnify ? { requestUnification(part.id) } : nil, detectBPM: { show.detectBPMRegion = part.id }, disunify: song.parts.contains(where: { $0.parentRegionID == part.id }) ? { show.disunifyRegion(part.id) } : nil, delete: {
            regionToDelete = (show.snapshot.project.id, song.id, part.id)
            confirmingRegionDelete = true
        }, resizable: !song.parts.contains(where: { $0.parentRegionID == part.id }), seek: { show.selectTimelineRegion(part.id); show.send(.editSeek, value: part.startTime) }, drag: { translation, ended, edge in
            guard let original = song.parts.first(where: { $0.id == part.id }) else { return }
            if edge != 0 {
                guard original.parentRegionID == nil, !song.parts.contains(where: { $0.parentRegionID == part.id }) else {
                    resizingRegion = nil; regionSnapPoints = []; return
                }
                if abs(translation) >= 0.5 || resizingRegion == part.id {
                    if resizingRegion != part.id {
                        // Build once per gesture; lookups below are logarithmic.
                        regionSnapPoints = song.tracks.flatMap { $0.clips.flatMap { [$0.startTime, $0.startTime + $0.duration] } }
                            .filter { edge < 0 ? $0 <= original.endTime - 0.01 : $0 >= original.startTime + 0.01 }
                            .sorted()
                    }
                    let boundary = (edge < 0 ? original.startTime : original.endTime) + translation / pixelsPerSecond
                    let snapped: Double
                    if NSEvent.modifierFlags.contains(.shift) {
                        snapped = max(0, boundary)
                    } else {
                        snapped = nearestRegionItemEdge(boundary, points: regionSnapPoints, tolerance: 8 / pixelsPerSecond)
                            ?? itemPosition(boundary, song: song, pixelsPerSecond: pixelsPerSecond)
                    }
                    resizedStart = edge < 0 ? min(snapped, original.endTime - 0.01) : original.startTime
                    resizedEnd = edge > 0 ? max(snapped, original.startTime + 0.01) : original.endTime
                    resizingRegion = part.id
                    timelineExtent = max(timelineExtent, resizedEnd + 120)
                    if ended { show.resizeRegion(part.id, start: resizedStart, end: resizedEnd) }
                }
                if ended { resizingRegion = nil; regionSnapPoints = [] }
                return
            }
            if abs(translation) >= 3 {
                let proposed = itemPosition(original.startTime + translation / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                if movingRegion != part.id {
                    regionMarkerRepulsion = RegionMarkerRepulsion(song: song, region: original, minimumGap: 10 / max(0.001, pixelsPerSecond))
                }
                let start = regionMarkerRepulsion?.resolve(proposed) ?? proposed
                movingRegion = part.id
                regionDelta = start - original.startTime
                timelineExtent = max(timelineExtent, original.endTime + regionDelta + 120)
                if ended { show.moveRegion(part.id, start: start) }
            }
            if ended { movingRegion = nil; regionDelta = 0; regionMarkerRepulsion = nil }
        })
        #else
        Color.clear.contentShape(Rectangle()).onLongPressGesture { editingRegion = part.id }
        #endif
    }
    private func requestUnification(_ id: UUID) {
        let roots = show.snapshot.project.overlappingRegions(containing: id)
        if let group = roots.first(where: { root in show.current?.parts.contains(where: { $0.parentRegionID == root.id }) == true }) {
            show.unifyRegions(containing: id, name: group.name)
        } else { unifyingRegion = id }
    }
    private func previewRegionResize(_ song: Song) -> Song {
        guard let resizingRegion, let index = song.parts.firstIndex(where: { $0.id == resizingRegion }),
              song.parts[index].parentRegionID == nil, !song.parts.contains(where: { $0.parentRegionID == resizingRegion }) else { return song }
        var result = song
        result.parts[index].startTime = resizedStart
        result.parts[index].endTime = resizedEnd
        result.duration = max(result.duration, resizedEnd)
        return RegionLanes(parts: result.parts).count <= 2 ? result : song
    }
    private func previewClipMove(_ song: Song) -> Song {
        guard let movingClip else { return song }
        var result = song
        if let provisionalTrack, movingTrack == provisionalTrack.id { result.tracks.append(provisionalTrack) }
        for track in result.tracks.indices {
            if let index = result.tracks[track].clips.firstIndex(where: { $0.id == movingClip }) {
                var clip = result.tracks[track].clips.remove(at: index)
                clip.startTime = movingStart
                let destination = result.tracks.firstIndex(where: { $0.id == movingTrack }) ?? track
                result.tracks[destination].clips.append(clip)
                result.duration = max(result.duration, movingStart + clip.duration)
                return result
            }
        }
        return result
    }
    private func previewRegionMove(_ song: Song) -> Song {
        guard let movingRegion, let region = song.parts.first(where: { $0.id == movingRegion }) else { return song }
        return song.previewMovingRegion(movingRegion, to: region.startTime + regionDelta)
    }

    private func itemPosition(_ time: Double, song: Song, pixelsPerSecond: Double, snappingRegionEnds: Bool = false) -> Double {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.shift) { return max(0, time) }
        #endif
        let transport = show.snapshot.transport
        return TimelineTempo.snap(time, song: song, pixelsPerSecond: pixelsPerSecond, regionEnds: snappingRegionEnds,
                                  cursor: transport.editPosition ?? transport.position, gridTolerancePixels: 4)
    }
    private func gridPosition(_ time: Double, song: Song, pixelsPerSecond: Double, freePositioning: Bool? = nil) -> Double {
        #if os(macOS)
        let free = freePositioning ?? NSEvent.modifierFlags.contains(.shift)
        #else
        let free = freePositioning ?? false
        #endif
        return TimelineTempo.snap(time, song: song, pixelsPerSecond: pixelsPerSecond, enabled: !free)
    }

    @ViewBuilder
    private func mixerDivider(width: CGFloat, maximum: CGFloat) -> some View {
        #if os(macOS)
        MixerResizeHandle(width: width, maximum: maximum, minimum: SidebarWidthLimits.trackMixer, scrollController: mixerScrollController, onToggle: toggleMixer, onEnd: { finalWidth in
            if finalWidth > 0 { restoreLabelWidth = Double(finalWidth) }
            savedLabelWidth = Double(finalWidth)
            mixerResizeState.update(nil)
        }) { mixerResizeState.update($0) }
        #else
        Rectangle().fill(JarasTheme.line)
            .overlay { Capsule().fill(JarasTheme.secondary).frame(width: 2, height: 28) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStart == nil { resizeStart = width }
                    savedLabelWidth = Double(min(maximum, max(SidebarWidthLimits.trackMixer, (resizeStart ?? width) + value.translation.width)))
                }.onEnded { _ in resizeStart = nil })
        #endif
    }
    private func cursor(position: Double, duration: Double, width: CGFloat, height: CGFloat, secondary: Bool, rulerHeight: CGFloat, verticalOffset: CGFloat, playback: Bool = false, subPosition: Double? = nil) -> some View {
        let transport = show.snapshot.transport
        let merged = !playback && show.subCursorVisible && abs((transport.editPosition ?? transport.position) - (subPosition ?? transport.subPlay.position)) * width / max(1, duration) < 0.5
        let dragging = !playback && (merged ? (draggingSub || draggingMain) : (secondary ? draggingSub : draggingMain))
        let playing = (playback && transport.playing) || (secondary && transport.subPlay.playing)
        let glowing = dragging || playing
        let x = min(width - 1, max(0, width * position / max(1, duration)))
        let headY: CGFloat = rulerHeight - tempoLaneHeight + verticalOffset
        let tipY = playback ? rulerHeight + verticalOffset : headY + 17
        let headTop = playback ? tipY : headY + 5
        let headTip = playback ? tipY + 9 : tipY
        let head = Path { path in
            path.move(to: CGPoint(x: 7, y: headTop))
            path.addLine(to: CGPoint(x: 21, y: headTop))
            path.addLine(to: CGPoint(x: 14, y: headTip))
            path.closeSubpath()
        }
        return TimelineCursorAppearance(playback: playback, secondary: secondary, merged: merged) { displayColor in
        ZStack(alignment: .topLeading) {
            // Render the shared needle once; both cursor hit targets remain available.
            if !merged || !secondary {
                if glowing {
                    let trailWidth = min(x, playing ? 38.0 : 22.0)
                    Rectangle().fill(LinearGradient(colors: [.clear, displayColor.opacity(0.08), displayColor.opacity(0.42)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: trailWidth, height: max(0, height - tipY))
                        .offset(x: 14 - trailWidth, y: tipY).allowsHitTesting(false)
                }
                Path { path in
                    path.move(to: CGPoint(x: 14, y: tipY))
                    path.addLine(to: CGPoint(x: 14, y: max(tipY, height)))
                }
                .stroke(displayColor, style: StrokeStyle(lineWidth: 1.5, lineCap: merged ? .round : .butt, dash: merged ? [1, 3] : []))
                .shadow(color: displayColor.opacity(glowing ? 1 : 0.55), radius: glowing ? 8 : 3)
                .frame(width: 28, height: height).allowsHitTesting(false)
                if merged {
                    head.fill(displayColor.opacity(0.18)).frame(width: 28, height: height)
                    head.stroke(displayColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 2])).frame(width: 28, height: height)
                } else {
                    head.fill(displayColor).frame(width: 28, height: height)
                        .shadow(color: displayColor.opacity(playback && glowing ? 0.9 : 0), radius: 4)
                        .allowsHitTesting(false)
                }
            }
            if !playback {
            Color.clear.frame(width: 28, height: 22).contentShape(Rectangle()).offset(y: headY)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        if secondary { draggingSub = true } else { draggingMain = true }
                        if let song = show.current { show.send(secondary ? .subSeek : .editSeek, value: gridPosition(Double(value.location.x / width) * duration, song: song, pixelsPerSecond: width / duration)) }
                    }.onEnded { _ in draggingSub = false; draggingMain = false })
                .contextMenu {
                    if !secondary {
                        Button("Create marker") { beginMarker() }
                        Button("Create tempo marker") { beginTempoMarker() }
                    }
                }
                .accessibilityLabel(LocalizedStringKey(secondary ? "Agulha Sub Play" : "Agulha de edição"))
            }
        }.frame(width: 28, height: height, alignment: .topLeading).offset(x: x - 14)
        }

    }
}
#if os(macOS)
/// Moving needles update Core Animation layers without invalidating the hosted
/// track/item tree. Transport samples and their epochs stay paired between ticks.
private struct NativeTimelineNeedles: NSViewRepresentable {
    let show: ShowController
    let width: CGFloat
    let height: CGFloat
    let rulerHeight: CGFloat
    let verticalOffset: CGFloat
    let extent: Double
    let seek: (Double, Bool) -> Void
    let marker: (Bool) -> Void
    func makeNSView(context: Context) -> NativeTimelineNeedlesView { NativeTimelineNeedlesView() }
    func updateNSView(_ view: NativeTimelineNeedlesView, context: Context) {
        view.configure(show: show, size: CGSize(width: width, height: height),
            rulerHeight: rulerHeight, verticalOffset: verticalOffset, extent: extent, seek: seek, marker: marker)
    }
    static func dismantleNSView(_ view: NativeTimelineNeedlesView, coordinator: ()) { view.stop() }
}
private final class NativeTimelineNeedlesView: NSView {
    private final class Needle {
        struct Appearance: Equatable {
            let color: Int
            let top: CGFloat, tip: CGFloat, height: CGFloat, trailWidth: CGFloat
            let glowing: Bool, merged: Bool, playback: Bool
        }
        var appearance: Appearance?
        let root = CALayer(), line = CAShapeLayer(), head = CAShapeLayer(), trail = CAGradientLayer()
        init() {
            root.addSublayer(trail); root.addSublayer(line); root.addSublayer(head)
            // Disable implicit animations on these layers once. Opening and
            // committing a transaction for each needle frame flushes the window.
            let keys = ["position", "bounds", "hidden", "opacity", "path", "fillColor", "strokeColor", "lineDashPattern",
                        "lineCap", "lineWidth", "shadowColor", "shadowOpacity", "shadowRadius", "shadowOffset", "colors", "locations"]
            for layer in [root, line, head, trail] {
                layer.actions = Dictionary(uniqueKeysWithValues: keys.map { ($0, NSNull()) })
            }
            line.fillColor = nil; line.lineWidth = 1.5
            trail.startPoint = CGPoint(x: 0, y: 0.5); trail.endPoint = CGPoint(x: 1, y: 0.5)
        }
    }
    private let edit = Needle(), main = Needle(), sub = Needle()
    private let follow = TimelinePlaybackFollowView()
    private weak var show: ShowController?
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?
    private var pendingSample = false
    private var transport: TransportState?
    private var sampledAt = 0.0, duration = 0.0, extent = 1.0
    private var boundary: Double?
    private var songID: UUID?
    private var subVisible = false
    private var size = CGSize.zero
    private var rulerHeight: CGFloat = 0, verticalOffset: CGFloat = 0
    private var editX: CGFloat = 0, subX: CGFloat = 0
    private var dragging: Bool?
    private var seek: (Double, Bool) -> Void = { _, _ in }
    private var marker: (Bool) -> Void = { _ in }
    private var colors: [Int] = [TimelineAppearanceDefaults.playCursor, TimelineAppearanceDefaults.editCursor, TimelineAppearanceDefaults.subPlayCursor]
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { size }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for needle in [edit, main, sub] { layer?.addSublayer(needle.root) }
        addSubview(follow)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(show: ShowController, size: CGSize, rulerHeight: CGFloat, verticalOffset: CGFloat,
                   extent: Double, seek: @escaping (Double, Bool) -> Void, marker: @escaping (Bool) -> Void) {
        let resized = self.size != size
        self.size = size; self.rulerHeight = rulerHeight; self.verticalOffset = verticalOffset; self.extent = extent
        if resized {
            // AppKitPlatformViewHost caches the representable's fitting size.
            // Without invalidation it keeps the old wide view centered inside
            // a zoomed-out document, moving every needle outside the viewport.
            invalidateIntrinsicContentSize()
        }
        self.seek = seek; self.marker = marker
        if self.show !== show {
            subscriptions.removeAll(); self.show = show
            subscriptions.append(show.$snapshot.sink { [weak self] _ in self?.scheduleSample() })
            subscriptions.append(show.$subCursorPreview.sink { [weak self] _ in self?.scheduleSample() })
            for (index, pair) in [("jaras.timeline.playCursor", TimelineAppearanceDefaults.playCursor),
                                  ("jaras.timeline.editCursor", TimelineAppearanceDefaults.editCursor),
                                  ("jaras.timeline.subPlayCursor", TimelineAppearanceDefaults.subPlayCursor)].enumerated() {
                subscriptions.append(AppearanceColor.shared(pair.0, default: pair.1).$value.sink { [weak self] value in
                    self?.colors[index] = value
                    self?.paint()
                })
            }
        }
        sample(); paint()
    }
    private func scheduleSample() {
        guard !pendingSample else { return }
        pendingSample = true
        // @Published emits before its storage changes. Read the completed
        // snapshot after publication, and never reset an older sample's epoch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSample = false; self.sample(); self.paint()
        }
    }
    private func sample() {
        guard let show else { return }
        transport = show.snapshot.transport; sampledAt = show.timelinePlaybackSampleTime
        let song = show.current
        songID = song?.id; duration = song?.duration ?? 0; subVisible = show.subCursorVisible
        let region = song?.parts.first { $0.id == transport?.regionId }
        boundary = transport?.ignoreNextEnd ?? region?.parentRegionID.flatMap { id in song?.parts.first { $0.id == id }?.endTime } ?? region?.endTime
        manageTimer()
    }
    private func manageTimer() {
        let active = window != nil && (transport?.playing == true || transport?.subPlay.playing == true || subVisible)
        if !active { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.paint() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); manageTimer(); paint() }
    func stop() { timer?.invalidate(); timer = nil; subscriptions.removeAll(); show = nil }
    deinit { timer?.invalidate() }
    private func ink(_ value: Int) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    private func x(_ position: Double) -> CGFloat { min(max(0, size.width - 1), max(0, size.width * position / max(1, extent))) }
    private func paint() {
        guard let transport, size.width > 0, size.height > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let playback = TimelinePlaybackPresentation(transport: transport, elapsed: max(0, now - sampledAt),
            songDuration: duration, mainBoundary: boundary)
        editX = x(transport.editPosition ?? transport.position); subX = x(playback.subPosition)
        let merged = subVisible && abs(editX - subX) < 0.5
        let blended = [0, 8, 16].reduce(0) { $0 | (((((colors[1] >> $1) & 255) + ((colors[2] >> $1) & 255)) / 2) << $1) }
        draw(edit, x: editX, color: merged ? blended : colors[1], playback: false,
            glowing: dragging == false || (merged && dragging == true), merged: merged)
        main.root.isHidden = !transport.playing && transport.paused != true
        if !main.root.isHidden { draw(main, x: x(playback.mainPosition), color: colors[0], playback: true, glowing: transport.playing) }
        sub.root.isHidden = !subVisible || merged
        if !sub.root.isHidden {
            draw(sub, x: subX, color: colors[2], playback: false, glowing: transport.subPlay.playing || dragging == true)
            sub.root.opacity = now.truncatingRemainder(dividingBy: 0.9) < 0.45 ? 1 : 0.3
        }
        follow.update(position: show?.timelineFollowPaused == true ? nil : playback.followPosition, pixelsPerSecond: size.width / max(1, extent), contentWidth: size.width,
            source: "\(songID?.uuidString ?? "")-\(playback.followSource == .sub ? "sub" : "main")")
    }
    private func draw(_ needle: Needle, x: CGFloat, color value: Int, playback: Bool, glowing: Bool, merged: Bool = false) {
        let top = rulerHeight - 16 + verticalOffset
        let tip = playback ? rulerHeight + verticalOffset : top + 17
        let frame = CGRect(x: x - 14, y: 0, width: 28, height: size.height)
        if needle.root.frame != frame { needle.root.frame = frame }
        let appearance = Needle.Appearance(color: value, top: top, tip: tip, height: size.height,
            trailWidth: min(x, 38), glowing: glowing, merged: merged, playback: playback)
        guard needle.appearance != appearance else { return }
        needle.appearance = appearance
        // Shape paths alone do not establish layer bounds. Give both shapes
        // explicit geometry so the compositor cannot cull them at distant zoom.
        needle.line.frame = needle.root.bounds; needle.head.frame = needle.root.bounds
        let color = ink(value)
        let path = CGMutablePath(); path.move(to: CGPoint(x: 14, y: tip)); path.addLine(to: CGPoint(x: 14, y: max(tip, size.height)))
        needle.line.path = path; needle.line.strokeColor = color
        needle.line.shadowPath = path.copy(strokingWithWidth: 1.5, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        needle.line.lineDashPattern = merged ? [1, 3] : nil
        needle.line.lineCap = merged ? .round : .butt
        needle.line.shadowColor = color; needle.line.shadowOpacity = glowing ? 1 : 0.55
        needle.line.shadowRadius = glowing ? 8 : 3; needle.line.shadowOffset = .zero
        let head = CGMutablePath(); head.move(to: CGPoint(x: 7, y: playback ? tip : top + 5))
        head.addLine(to: CGPoint(x: 21, y: playback ? tip : top + 5)); head.addLine(to: CGPoint(x: 14, y: playback ? tip + 9 : tip)); head.closeSubpath()
        needle.head.path = head; needle.head.shadowPath = head; needle.head.fillColor = merged ? color.copy(alpha: 0.18) : color
        needle.head.strokeColor = merged ? color : nil; needle.head.lineDashPattern = merged ? [1, 2] : nil; needle.head.lineWidth = 1.5
        needle.head.shadowColor = color; needle.head.shadowOpacity = playback && glowing ? 0.9 : 0
        needle.head.shadowRadius = 4; needle.head.shadowOffset = .zero
        needle.trail.isHidden = !glowing
        needle.trail.frame = CGRect(x: 14 - min(x, 38), y: tip, width: min(x, 38), height: max(0, size.height - tip))
        needle.trail.colors = [color.copy(alpha: 0)!, color.copy(alpha: 0.08)!, color.copy(alpha: 0.42)!]
        needle.trail.locations = [0, 0.5, 1]
    }
    private func target(at point: CGPoint) -> Bool? {
        guard point.y >= rulerHeight - 16 + verticalOffset && point.y <= rulerHeight + 6 + verticalOffset else { return nil }
        if subVisible && abs(point.x - subX) <= 14 { return true }
        return abs(point.x - editX) <= 14 ? false : nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, !NativeTimelineInputGate.shared.isBlocked(window), window.attachedSheet == nil,
              target(at: convert(point, from: superview)) != nil else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        dragging = target(at: convert(event.locationInWindow, from: nil)); move(event)
    }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func mouseUp(with event: NSEvent) { dragging = nil; sample(); paint() }
    private func move(_ event: NSEvent) {
        guard let dragging else { return }
        let position = min(max(0, convert(event.locationInWindow, from: nil).x / max(1, size.width)), 1) * extent
        seek(position, dragging); sample(); paint()
    }
    override func rightMouseDown(with event: NSEvent) {
        guard target(at: convert(event.locationInWindow, from: nil)) == false else { return }
        let menu = NSMenu()
        for (title, selector) in [("Create marker", #selector(createMarker)), ("Create tempo marker", #selector(createTempoMarker))] {
            let item = NSMenuItem(title: JarasLocalization.string(title), action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func createMarker() { marker(false) }
    @objc private func createTempoMarker() { marker(true) }
}
#endif

private struct TimelineCursorAppearance<Content: View>: View {
    @ObservedObject private var play = AppearanceColor.shared("jaras.timeline.playCursor", default: TimelineAppearanceDefaults.playCursor)
    @ObservedObject private var edit = AppearanceColor.shared("jaras.timeline.editCursor", default: TimelineAppearanceDefaults.editCursor)
    @ObservedObject private var sub = AppearanceColor.shared("jaras.timeline.subPlayCursor", default: TimelineAppearanceDefaults.subPlayCursor)
    let playback: Bool
    let secondary: Bool
    let merged: Bool
    @ViewBuilder let content: (Color) -> Content
    var body: some View {
        let blended = [0,8,16].reduce(0) { result, shift in
            result | (((((edit.value >> shift) & 255) + ((sub.value >> shift) & 255)) / 2) << shift)
        }
        content(Color(hex: UInt32(merged ? blended : playback ? play.value : secondary ? sub.value : edit.value)))
    }
}
/// Transport ticks repaint needles, not the imported project's track and item tree.
private struct TimelinePlaybackLayer<Content: View>: View {
    @ObservedObject var show: ShowController
    @ViewBuilder let content: (TimelinePlaybackPresentation) -> Content
    var body: some View {
        let transport = show.snapshot.transport
        let song = show.current
        let region = song?.parts.first { $0.id == transport.regionId }
        let regionEnd = region?.parentRegionID.flatMap { id in song?.parts.first { $0.id == id }?.endTime } ?? region?.endTime
        let boundary = transport.ignoreNextEnd ?? regionEnd
        #if os(macOS)
        // Keep position and sampling time together. A later engine tick must
        // not reset elapsed time under this still-visible transport snapshot.
        let sampledAt = show.timelinePlaybackSampleTime
        // Only the small needle layer runs at display cadence. Track layout,
        // waveform data and the audio engine retain their existing update rates.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !show.isPlaying)) { _ in
            content(TimelinePlaybackPresentation(transport: transport, elapsed: max(0, ProcessInfo.processInfo.systemUptime - sampledAt),
                songDuration: song?.duration ?? 0, mainBoundary: boundary))
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        #else
        content(TimelinePlaybackPresentation(transport: transport, elapsed: 0,
            songDuration: song?.duration ?? 0, mainBoundary: boundary))
        #endif
    }
}
/// Scrolling updates the small pinned layer independently of track/item layout.
private struct TimelineAreaOverlay: View {
    @ObservedObject private var selection = TimelineAreaSelection.shared
    let song: UUID
    let scale: Double
    let height: CGFloat
    let rulerHeight: CGFloat
    var body: some View {
        if let range = selection.range, range.song == song {
            let width = (range.end - range.start) * scale
            let bandHeight = max(0, height - rulerHeight + tempoLaneHeight)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Path { path in
                    path.move(to: .zero); path.addLine(to: CGPoint(x: 0, y: bandHeight))
                    path.move(to: CGPoint(x: width, y: 0)); path.addLine(to: CGPoint(x: width, y: bandHeight))
                    path.move(to: CGPoint(x: 0, y: 10)); path.addLine(to: CGPoint(x: width, y: 10))
                    let head = min(12, width / 2)
                    path.move(to: .zero); path.addLine(to: CGPoint(x: head, y: 0)); path.addLine(to: CGPoint(x: 0, y: 12)); path.closeSubpath()
                    path.move(to: CGPoint(x: width, y: 0)); path.addLine(to: CGPoint(x: width - head, y: 0)); path.addLine(to: CGPoint(x: width, y: 12)); path.closeSubpath()
                }.stroke(JarasTheme.yellow, lineWidth: 1)
            }.frame(width: width, height: bandHeight)
                .offset(x: range.start * scale, y: rulerHeight - tempoLaneHeight).allowsHitTesting(false)
        }
    }
}


private final class TimelineScrollPosition: ObservableObject {
    @Published var offset: CGFloat = 0
}
private final class TimelineVerticalScroll {
    let pinned = TimelineScrollPosition()
    let tiles = TimelineScrollPosition()
    private(set) var offset: CGFloat = 0
    func update(_ offset: CGFloat) {
        self.offset = max(0, offset)
        #if !os(macOS)
        if abs(pinned.offset - offset) > 0.1 { pinned.offset = offset }
        #endif
        // Canvas tiles already overscan by a full tile; don't repaint each pixel.
        let bucket = floor(max(0, offset) / 512) * 512
        if tiles.offset != bucket { tiles.offset = bucket }
    }
}
private struct TimelineScrollLayer<Content: View>: View {
    @ObservedObject var position: TimelineScrollPosition
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View { content(position.offset) }
}

/// Column dimensions are already known. Avoid asking every mixer descendant
/// for explicit alignment guides each time the timeline scale changes.
private struct TimelineColumnsContainer<Mixer: View, Separator: View, Timeline: View>: View {
    let mixerWidth: CGFloat
    let viewportWidth: CGFloat
    let height: CGFloat
    var dividerWidth: CGFloat = 4
    let project: UUID
    let mixerIdentity: TimelineMixerIdentity
    @ViewBuilder let mixer: () -> Mixer
    @ViewBuilder let divider: () -> Separator
    @ViewBuilder let timeline: () -> Timeline
    var body: some View {
        #if os(macOS)
        NativeTimelineColumns(mixerWidth: mixerWidth, viewportWidth: viewportWidth, height: height,
            dividerWidth: dividerWidth, project: project, mixerIdentity: mixerIdentity,
            mixer: mixer, divider: divider, timeline: timeline)
            .frame(width: viewportWidth, height: height)
        #else
        TimelineColumnsLayout(mixerWidth: mixerWidth, viewportWidth: viewportWidth, height: height, dividerWidth: dividerWidth) {
            mixer()
            divider()
            timeline()
        }
        #endif
    }
}
@available(macOS 13, *)
private struct TimelineColumnsLayout: Layout {
    let mixerWidth: CGFloat
    let viewportWidth: CGFloat
    let height: CGFloat
    var dividerWidth: CGFloat = 4
    // These containers use explicit frames, not their children's alignment guides.
    // The default Layout implementation walks every control to merge guides.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: viewportWidth, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        if subviews.count == 3 {
            subviews[index].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: mixerWidth, height: height))
            index += 1
        }
        guard subviews.count == index + 2 else { return }
        subviews[index].place(at: CGPoint(x: bounds.minX + mixerWidth, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: dividerWidth, height: height))
        subviews[index + 1].place(at: CGPoint(x: bounds.minX + mixerWidth + dividerWidth, y: bounds.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: max(0, viewportWidth - mixerWidth - dividerWidth), height: height))
    }
}


/// A fixed placement layout avoids remeasuring the entire mixer stack whenever
/// the horizontal document changes width during a zoom gesture. Rows near the
/// viewport stay mounted, preserving their live controls during scrolling.
private struct TimelineTrackRowsContainer<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let top: CGFloat
    let offsets: [CGFloat]
    let rowHeights: [CGFloat]
    var rowWidths: [CGFloat]? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy {
            TimelineTrackRowsLayout(width: width, height: height, top: top, offsets: offsets,
                                    rowHeights: rowHeights, rowWidths: rowWidths) { content() }
        } else {
            JarasFixedPlacement(size: CGSize(width: width, height: height), frames: offsets.indices.map { index in
                CGRect(x: 0, y: top + offsets[index], width: rowWidths.flatMap { index < $0.count ? $0[index] : nil } ?? width,
                       height: rowHeights[index])
            }, content: content)
        }
    }
}
@available(macOS 13, *)
private struct TimelineTrackRowsLayout: Layout {
    let width: CGFloat
    let height: CGFloat
    let top: CGFloat
    let offsets: [CGFloat]
    let rowHeights: [CGFloat]
    var rowWidths: [CGFloat]? = nil
    // These containers use explicit frames, not their children's alignment guides.
    // The default Layout implementation walks every control to merge guides.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == offsets.count, offsets.count == rowHeights.count else { return }
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top + offsets[index]),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: rowWidths.flatMap { index < $0.count ? $0[index] : nil } ?? width, height: rowHeights[index]))
        }
    }
}

private struct TimelineMixerIdentity: Equatable {
    let revision: UInt64
    let mixerRevision: UInt64
    let song: UUID?
    let width: CGFloat
    let viewportHeight: CGFloat
    let heights: [CGFloat]
    let selection: Set<UUID>
    var documentHeight: CGFloat = 0
    var rulerHeight: CGFloat = 0
    var widthViewport: CGRect? = nil
}

private struct TimelineMixerLayer<Content: View>: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let identity = lhs.identity else { return false }
        return identity == rhs.identity
    }
    let position: TimelineScrollPosition
    var identity: TimelineMixerIdentity? = nil
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View {
        TimelineScrollLayer(position: position, content: content)
    }
}

/// Keep a bounded set of native row controls alive while their track bindings
/// move through the document. Stable slot IDs avoid rebuilding every slider,
/// button and meter when a scrollbar jump enters a distant group of tracks.
private struct TimelineMixerSlot: Identifiable {
    let id: Int
    let index: Int
    var width: CGFloat? = nil
    var height: CGFloat
}
private final class TimelineMixerRowPool<Key: Hashable> {
    private var bindings: [Key] = []
    private var widths: [Key: CGFloat] = [:]
    private var renderedHeights: [Key: CGFloat] = [:]

    func slots(ids: [Key], offsets: [CGFloat], heights: [CGFloat], top: CGFloat,
               visibleY: CGFloat, viewportHeight: CGFloat, width: CGFloat? = nil, widthViewport: CGRect? = nil, pinned: Set<Key> = []) -> [TimelineMixerSlot] {
        guard !ids.isEmpty, ids.count == offsets.count, ids.count == heights.count else {
            bindings.removeAll()
            widths.removeAll()
            renderedHeights.removeAll()
            return []
        }
        let indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        let minimumHeight = max(1, heights.min() ?? 1)
        let required = ids.indices.filter {
            mixerRowIsMounted(start: top + offsets[$0], height: heights[$0], visibleY: visibleY, viewportHeight: viewportHeight)
        }
        let pinnedIndices = pinned.compactMap { indexByID[$0] }
        // Fully bind the reserve at the first viewport, including the rows below
        // it. A distant first drag can then reuse controls instead of creating
        // the lower overscan in the middle of that gesture.
        let reserve = min(ids.count, Int(ceil((max(0, viewportHeight) + 1536) / minimumHeight)) + 2)
        let requiredSet = Set(required).union(pinnedIndices)
        let capacity = min(ids.count, max(bindings.count, reserve, requiredSet.count))
        let first = min(max(0, (required.first ?? 0) - 1), ids.count - capacity)
        var desired = requiredSet
        for index in first..<(first + capacity) where desired.count < capacity { desired.insert(index) }
        if desired.count < capacity {
            for index in ids.indices where desired.count < capacity { desired.insert(index) }
        }
        let wanted = Set(desired.map { ids[$0] })
        var retained = Set<Key>()
        var next = bindings.prefix(capacity).map { key -> Key? in
            guard wanted.contains(key), retained.insert(key).inserted else { return nil }
            return key
        }
        while next.count < capacity { next.append(nil) }
        var incoming = desired.sorted().map { ids[$0] }.filter { !retained.contains($0) }.makeIterator()
        for slot in next.indices where next[slot] == nil { next[slot] = incoming.next() }
        bindings = next.compactMap { $0 }
        var currentWidths: [Key: CGFloat] = [:]
        var currentHeights: [Key: CGFloat] = [:]
        let result = bindings.enumerated().compactMap { slot, key -> TimelineMixerSlot? in
            guard let index = indexByID[key] else { return nil }
            // Native controls in the warm reserve stay mounted at their last
            // width. While dragging, resize only the rows actually on screen.
            // Releasing (or starting a vertical gesture) restores the full warm
            // interval before another scroll can expose deferred widths.
            let widthTop = widthViewport?.minY ?? visibleY
            let widthBottom = widthViewport?.maxY ?? (visibleY + viewportHeight + 512)
            let nearViewport = top + offsets[index] + heights[index] >= widthTop &&
                top + offsets[index] <= widthBottom
            let rowWidth = nearViewport ? width : (widths[key] ?? width)
            if let rowWidth { currentWidths[key] = rowWidth }
            // Keep warm controls at their existing height until their row can
            // enter the next scroll bucket. Shrinking then expanding otherwise
            // resizes the entire retained pool (up to ~100 native control trees)
            // on every wheel event, although only a few tracks are visible.
            // Use the larger old/new extent so a tall overlapping row above the
            // viewport cannot leave stale controls protruding into the screen.
            let oldHeight = renderedHeights[key] ?? heights[index]
            let heightIsVisible = top + offsets[index] + max(oldHeight, heights[index]) >= visibleY &&
                top + offsets[index] <= visibleY + viewportHeight + 512
            let rowHeight = heightIsVisible || pinned.contains(key) ? heights[index] : oldHeight
            currentHeights[key] = rowHeight
            return TimelineMixerSlot(id: slot, index: index, width: rowWidth, height: rowHeight)
        }
        widths = currentWidths
        renderedHeights = currentHeights
        return result
    }
}

private func mixerRowIsMounted(start: CGFloat, height: CGFloat, visibleY: CGFloat, viewportHeight: CGFloat) -> Bool {
    // A full tile above and two below keep incoming controls ready before they
    // enter the viewport. Offscreen native faders/meters no longer participate
    // in every window resize or keep receiving display updates.
    return start + height >= visibleY - 512 && start <= visibleY + viewportHeight + 1024
}

/// Move the existing header surface with AppKit instead of rebuilding its views
/// for every pixel of vertical scrolling.
private struct TimelinePinnedLayer<Content: View>: View {
    let position: TimelineScrollPosition
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View {
        #if os(macOS)
        NativeTimelinePinnedLayer(width: width, height: height, content: content(0))
        #else
        TimelineScrollLayer(position: position, content: content)
        #endif
    }
}

/// Header pixels and hit targets use a covered viewport, so resizing a sidebar
/// inside one bucket does not rebuild every region/marker or its input callbacks.
/// AppKit clips this reserve to the exact visible bounds.
private enum TimelineHeaderViewport {
    static func covering(offset: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        let start = max(0, floor(offset / 512) * 512 - 512)
        let end = max(start, ceil((max(0, offset) + max(0, width)) / 512) * 512 + 512)
        return CGRect(x: start, y: 0, width: end - start, height: height)
    }
}
private struct TimelineStaticHeaderIdentity: Equatable {
    let controller: ObjectIdentifier
    let project: UUID
    let renderKey: TimelineRenderKey
    let documentSize: CGSize
    let viewport: CGRect
    let rulerHeight: CGFloat
    let extent: Double
    let verticalOffset: CGFloat
    let editingRegion: UUID?
    let unifyingRegion: UUID?
    var selectedRegion: UUID? = nil
    let locale: Locale
}
private struct TimelineStaticHeaderLayer<Content: View>: View, Equatable {
    let identity: TimelineStaticHeaderIdentity
    @ViewBuilder let content: () -> Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View { content() }
}

/// Only the horizontal document observes zoom; the outer scroll and mixer keep
/// their existing content and layout during a horizontal scale gesture.
private final class TimelineZoomState: ObservableObject {
    @Published var value = TimelineViewportPreferences.zoom
}
private struct TimelineZoomLayer<Content: View>: View {
    @ObservedObject var state: TimelineZoomState
    @ViewBuilder let content: (Binding<Double>) -> Content
    var body: some View { content($state.value) }
}

private struct TimelineViewportLayer<Content: View>: View {
    @ObservedObject var horizontal: TimelineScrollPosition
    @ObservedObject var vertical: TimelineScrollPosition
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content
    var body: some View { content(horizontal.offset, vertical.offset) }
}

struct TimelineDrawing: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedTracks == rhs.selectedTracks && lhs.documentWidth == rhs.documentWidth && lhs.visibleRect == rhs.visibleRect && lhs.renderKey == rhs.renderKey && lhs.rowHeight == rhs.rowHeight && lhs.rulerHeight == rhs.rulerHeight && lhs.extent == rhs.extent && lhs.selectedClips == rhs.selectedClips && lhs.movingClip == rhs.movingClip && lhs.movingStart == rhs.movingStart && lhs.colorScheme == rhs.colorScheme && lhs.mediaDirectory == rhs.mediaDirectory && lhs.missingAudioPaths == rhs.missingAudioPaths
    }
    @Environment(\.colorScheme) private var colorScheme
    let visibleRect: CGRect
    let song: Song
    let renderKey: TimelineRenderKey
    let rowHeight: CGFloat; let rulerHeight: CGFloat
    let extent: Double
    let selectedClips: Set<UUID>
    let movingClip: UUID?
    let movingStart: Double
    var mediaDirectory: URL? = nil
    var missingAudioPaths: Set<String> = []
    var documentWidth: CGFloat? = nil
    var selectedTracks: Set<UUID> = []
    @ObservedObject private var audioWaveform = TimelineAudioWaveform.shared
    @ObservedObject private var metalRenderer = MetalWaveformRenderer.shared
    @State private var rowLayoutCache = TrackLayoutCache()
    var body: some View {
        let rows = rowLayoutCache.layout(song.tracks, height: rowHeight, key: renderKey)
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, batchesViewport: MetalWaveformRenderer.isSupported, diagnosticName: "items", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, rowHeight: rowHeight, rulerHeight: rulerHeight, selectedClips: selectedClips, waveformRevision: 0, missingAudioPaths: missingAudioPaths, mediaDirectory: mediaDirectory), tileIdentity: { tile, size in
            var identity = TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, rowHeight: rowHeight, rulerHeight: rulerHeight, selectedClips: selectedClips, missingAudioPaths: missingAudioPaths, mediaDirectory: mediaDirectory)
            if MetalWaveformRenderer.isSupported { return identity }
            let scale = size.width / extent
            var fingerprint = Hasher()
            if let mediaDirectory, !MetalWaveformRenderer.isSupported {
                var visitedFiles = Set<String>()
                for (index, track) in song.tracks.enumerated() where rulerHeight + rows.offsets[index] <= tile.maxY && rulerHeight + rows.offsets[index] + rows.heights[index] >= tile.minY {
                    for clip in track.clips where clip.startTime * scale <= tile.maxX && (clip.startTime + clip.duration) * scale >= tile.minX {
                        if let file = clip.audioFile ?? track.audioFile, visitedFiles.insert(file.path).inserted {
                            fingerprint.combine(file.path)
                            fingerprint.combine(audioWaveform.version(mediaDirectory.appendingPathComponent(file.path, isDirectory: false)))
                        }
                    }
                }
            }
            identity.waveformRevision = UInt64(bitPattern: Int64(fingerprint.finalize()))
            return identity
        }) { context, size, tile, waveformOwner in
            let scale = size.width / extent
            // Empty space keeps the same grid spacing without creating or stretching tracks.
            let tempoSections = !MetalWaveformRenderer.isSupported && song.tempoMarkersAffectAudio ? song.tempoSections(until: song.duration) : []
            let clickTiming = song.tracks.contains(where: { $0.kind == .click }) ? song.tempoSections(until: song.duration) : []
            let emptyStart = rulerHeight + rows.totalHeight
            let firstEmptyRow = max(0, Int(floor((tile.minY - emptyStart) / rowHeight)))
            let lastEmptyRow = max(firstEmptyRow, Int(ceil((min(size.height, tile.maxY) - emptyStart) / rowHeight)))
            if emptyStart <= min(size.height, tile.maxY) {
                var emptyLines = Path()
                for row in firstEmptyRow...lastEmptyRow {
                    let y = emptyStart + CGFloat(row) * rowHeight
                    guard y <= size.height else { break }
                    emptyLines.move(to: CGPoint(x: tile.minX, y: y))
                    emptyLines.addLine(to: CGPoint(x: tile.maxX, y: y))
                }
                context.stroke(emptyLines, with: .color(JarasTheme.line.opacity(0.8)), lineWidth: 1)
            }
            let hasSolo = song.tracks.contains { $0.solo }
            for (index, track) in song.tracks.enumerated() {
                let trackSilenced = track.mute || (hasSolo && !track.solo)
                let y = rulerHeight + rows.offsets[index]
                if y > tile.maxY || y + rows.heights[index] < tile.minY { continue }
                var rowLine = Path(); rowLine.move(to: CGPoint(x: 0, y: y)); rowLine.addLine(to: CGPoint(x: size.width, y: y)); context.stroke(rowLine, with: .color(JarasTheme.line.opacity(0.8)), lineWidth: 1)
                for clip in track.clips {
                    let silenced = trackSilenced || clip.muted == true
                    let selected = selectedClips.contains(clip.id)
                    let rect = CGRect(x: clip.startTime * scale + 1, y: y + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3, width: max(2, clip.duration * scale - 2), height: rows.laneHeights[index] - 6)
                    guard rect.intersects(tile.insetBy(dx: -6, dy: -6)) else { continue }
                    drawTimelineItem(clip, track: track, rect: rect, selected: selected, silenced: silenced, scale: scale, tile: tile, context: &context, mediaDirectory: mediaDirectory, tempoSegments: tempoSections.isEmpty ? nil : song.tempoAudioSegments(clip, sections: tempoSections), missingAudio: (clip.audioFile ?? track.audioFile).map { missingAudioPaths.contains($0.path) } ?? false, waveformOwner: waveformOwner, drawWaveform: !MetalWaveformRenderer.isSupported, clickTiming: track.kind == .click ? clickTiming : [])
                }
            }
            // On macOS, marker flags and lines use a separate drag layer.
            for marker in song.markers ?? [] {
                #if os(macOS)
                continue // Marker lines are drawn by TimelineDraggableMarkerLayer.
                #endif
                let x = marker.position * scale
                guard x >= tile.minX - 3, x <= tile.maxX + 3 else { continue }
                let color = Color(hex: marker.color).opacity(marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)
                var line = Path()
                line.move(to: CGPoint(x: x, y: rulerHeight))
                line.addLine(to: CGPoint(x: x, y: size.height))
                if !marker.isTempo { context.stroke(line, with: .color(color.opacity(0.16)), lineWidth: 5) }
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: marker.isTempo ? [2, 3] : []))
            }
        }.overlay(alignment: .topLeading) {
            if MetalWaveformRenderer.isSupported, let mediaDirectory {
                TimelineMetalWaveformLayer(visibleRect: visibleRect, song: song, rows: rows, renderKey: renderKey,
                    rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips,
                    mediaDirectory: mediaDirectory, missingAudioPaths: missingAudioPaths, documentWidth: documentWidth)
            }
        }.background {
            TimelineBackdrop(visibleRect: visibleRect, song: song, rows: rows, renderKey: renderKey,
                rowHeight: rowHeight, rulerHeight: rulerHeight, extent: extent,
                documentWidth: documentWidth, selectedTracks: selectedTracks)
        }
    }
}

/// One GPU surface batches all visible audio, including a bounded overscan for
/// native scrolling. It never allocates a texture as large as the whole project.
private struct TimelineMetalWaveformLayer: View {
    @State private var mediaURLs = TimelineMediaURLCache()
    @State private var sourceOwner = TimelineWaveformVertexOwner()
    @ObservedObject private var waveformCache = TimelineAudioWaveform.shared
    let visibleRect: CGRect
    let song: Song
    let rows: TrackRowLayout
    let renderKey: TimelineRenderKey
    let rulerHeight: CGFloat
    let extent: Double
    let selectedClips: Set<UUID>
    let mediaDirectory: URL
    var missingAudioPaths: Set<String> = []
    var documentWidth: CGFloat? = nil
    var preview: AudioClip? = nil
    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: documentWidth ?? geometry.size.width, height: geometry.size.height)
            let viewport = TimelineCanvasCoverage.preparedRect(visibleRect: visibleRect, documentSize: size)
            let scale = size.width / extent
            MetalWaveformView(frame: waveformFrame(viewport: viewport, scale: scale))
                .frame(width: viewport.width, height: viewport.height)
                .offset(x: viewport.minX, y: viewport.minY)
        }.allowsHitTesting(false)
    }
    private func waveformFrame(viewport: CGRect, scale: Double) -> MetalWaveformFrame {
        TimelineMetalWaveformFrameBuilder.make(items: visibleItems(viewport: viewport, scale: scale),
            viewport: viewport, scale: scale, cache: waveformCache, owner: sourceOwner, contentRevision: contentRevision)
    }
    private var contentRevision: Int {
        var key = Hasher()
        key.combine(renderKey)
        key.combine(rows.heights)
        key.combine(rulerHeight)
        key.combine(selectedClips)
        key.combine(missingAudioPaths)
        key.combine(preview?.gain)
        return key.finalize()
    }
    private func visibleItems(viewport: CGRect, scale: Double) -> [TimelineWaveformItem] {
        let sections = song.tempoMarkersAffectAudio ? song.tempoSections(until: song.duration) : []
        let hasSolo = song.tracks.contains { $0.solo }
        var items: [TimelineWaveformItem] = []
        for (index, track) in song.tracks.enumerated() where track.kind == .standard {
            let y = rulerHeight + rows.offsets[index]
            guard y <= viewport.maxY, y + rows.heights[index] >= viewport.minY else { continue }
            for source in track.clips {
                if let preview, source.id != preview.id { continue }
                let clip = preview ?? source
                let rect = CGRect(x: clip.startTime * scale + 1,
                    y: y + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3,
                    width: max(2, clip.duration * scale - 2), height: rows.laneHeights[index] - 6)
                guard clip.midi == nil, rect.height > 26, rect.intersects(viewport), let file = clip.audioFile ?? track.audioFile,
                      !missingAudioPaths.contains(file.path) else { continue }
                let silenced = track.mute || (hasSolo && !track.solo) || clip.muted == true
                let rgb = TrackNameContrast.components(track.color ?? JarasTheme.roleHex(track.role), emphasized: selectedClips.contains(clip.id))
                let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
                let gray: Float = silenced ? 0.78 : luminance > 0.68 ? 0.52 : luminance > 0.42 ? 0.9 : 0.8
                items.append(TimelineWaveformItem(clip: clip,
                    fragments: sections.isEmpty ? [clip] : song.tempoAudioSegments(clip, sections: sections),
                    url: mediaURLs.resolve(file.path, directory: mediaDirectory), rect: rect, gray: gray))
            }
        }
        return items
    }
}

private struct TimelineBackdrop: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var backgroundColor = AppearanceColor.shared("jaras.timeline.background", default: TimelineAppearanceDefaults.background)
    @ObservedObject private var primaryGridColor = AppearanceColor.shared("jaras.timeline.primaryGrid", default: TimelineAppearanceDefaults.primaryGrid)
    @ObservedObject private var secondaryGridColor = AppearanceColor.shared("jaras.timeline.secondaryGrid", default: TimelineAppearanceDefaults.secondaryGrid)
    @AppStorage("jaras.timeline.gridlines") private var gridlines = GlobalProjectTiming.load()?.settings.divisions != 0
    let visibleRect: CGRect
    let song: Song
    let rows: TrackRowLayout
    let renderKey: TimelineRenderKey
    let rowHeight: CGFloat
    let rulerHeight: CGFloat
    let extent: Double
    let documentWidth: CGFloat?
    let selectedTracks: Set<UUID>
    var body: some View {
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth,
            diagnosticName: "backdrop", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: false, rowHeight: rowHeight,
                rulerHeight: rulerHeight, selectedTracks: selectedTracks,
                gridStyle: [backgroundColor.value, primaryGridColor.value, secondaryGridColor.value, gridlines ? 1 : 0])) { context, size, tile, waveformOwner in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: UInt32(backgroundColor.value))))
            for (index, track) in song.tracks.enumerated() where track.kind == .standard && selectedTracks.contains(track.id) {
                let band = CGRect(x: tile.minX, y: rulerHeight + rows.offsets[index], width: tile.width, height: rows.heights[index])
                guard band.intersects(tile) else { continue }
                context.fill(Path(band), with: .color(JarasTheme.track(track, emphasized: true).opacity(0.12)))
                context.fill(Path(band), with: .color(.white.opacity(0.025)))
            }
            let scale = size.width / extent
            if gridlines {
                let marks = TimelineTimeRuler.ticks(in: song.tempoSections(until: extent),
                    from: max(0, Double(tile.minX / scale)), to: Double(tile.maxX / scale),
                    pixelsPerSecond: scale, divisions: song.projectTime.divisions, labels: false)
                let pixel = 1 / displayScale
                var primaryLines = Path(), secondaryLines = Path()
                for mark in marks {
                    let x = floor(mark.time * scale * displayScale) / displayScale + pixel / 2
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: rulerHeight))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    if mark.primary { primaryLines.addPath(line) } else { secondaryLines.addPath(line) }
                }
                context.stroke(primaryLines, with: .color(Color(hex: UInt32(primaryGridColor.value))), lineWidth: pixel)
                context.stroke(secondaryLines, with: .color(Color(hex: UInt32(secondaryGridColor.value)).opacity(0.85)), lineWidth: pixel)
            }
        }
    }
}

/// During a gain gesture only this bounded surface is invalidated. The base grid,
/// headers, mixer and lane geometry keep their existing render and layout.
private struct ItemGainPreviewOverlay: View {
    @ObservedObject private var backgroundColor = AppearanceColor.shared("jaras.timeline.background", default: TimelineAppearanceDefaults.background)
    @ObservedObject var preview: ItemGainPreview
    @ObservedObject private var audioWaveform = TimelineAudioWaveform.shared
    @ObservedObject private var metalRenderer = MetalWaveformRenderer.shared
    let visibleRect: CGRect
    let song: Song
    let rows: TrackRowLayout
    let renderKey: TimelineRenderKey
    let rulerHeight: CGFloat
    let extent: Double
    let selectedClips: Set<UUID>
    let mediaDirectory: URL?
    var documentWidth: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let state = preview.state,
           let index = song.tracks.firstIndex(where: { $0.clips.contains { $0.id == state.id } }),
           let source = song.tracks[index].clips.first(where: { $0.id == state.id }) {
            let track = song.tracks[index]
            let lane = CGFloat(rows.lanes[index].lanes[source.id] ?? 0)
            let y = rulerHeight + rows.offsets[index] + lane * rows.laneHeights[index] + 3
            let height = rows.laneHeights[index] - 6
            let clip = state.applying(to: source)
            let silenced = song.isSilenced(track) || source.muted == true
            ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, diagnosticName: "gain-preview", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, gainPreview: state, waveformRevision: audioWaveform.revision, mediaDirectory: mediaDirectory, gridStyle: [backgroundColor.value])) { context, size, tile, waveformOwner in
                let scale = size.width / extent
                let rect = CGRect(x: source.startTime * scale + 1, y: y, width: max(2, source.duration * scale - 2), height: height)
                guard rect.intersects(tile) else { return }
                // Restore the opaque backing under this one item before repainting
                // its translucent fill, so the original waveform never shows through.
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(Color(hex: UInt32(backgroundColor.value))))
                let clickTiming = track.kind == .click ? song.tempoSections(until: song.duration) : []
                drawTimelineItem(clip, track: track, rect: rect, selected: selectedClips.contains(source.id), silenced: silenced, scale: scale, tile: tile, context: &context, mediaDirectory: mediaDirectory, waveformOwner: waveformOwner, drawWaveform: !MetalWaveformRenderer.isSupported, clickTiming: track.kind == .click ? clickTiming : [])
            }.overlay(alignment: .topLeading) {
                if MetalWaveformRenderer.isSupported, let mediaDirectory {
                    TimelineMetalWaveformLayer(visibleRect: visibleRect, song: song, rows: rows, renderKey: renderKey,
                        rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips,
                        mediaDirectory: mediaDirectory, documentWidth: documentWidth, preview: clip)
                }
            }
        }
    }
}

private func drawTimelineAudioWaveform(_ clip: AudioClip, url: URL, rect: CGRect, waveTop: CGFloat, scale: Double, tile: CGRect, waveColor: Color, context: inout GraphicsContext, waveformOwner: TimelineAudioWaveform.PresentationStore? = nil) {
    // A fixed vertical tile may contain only this item's name strip, or only
    // one stereo channel. Avoid preparing/stroking geometry clipped away by
    // the tile; retain a pixel of margin for antialiasing at its boundary.
    let visibleTile = tile.insetBy(dx: 0, dy: -1)
    let waveRect = CGRect(x: rect.minX, y: waveTop, width: rect.width, height: max(0, rect.maxY - waveTop - 2))
    guard waveRect.intersects(visibleTile) else { return }
    let cache = TimelineAudioWaveform.shared
    guard let header = cache.header(url, refresh: clip.recordingLane != nil), header.channels > 0 else { return }
    // Keep vertices near the viewport origin even at sample-level zoom far into
    // a show. Large absolute coordinates lose precision in GPU tessellation.
    var drawingContext = context
    drawingContext.translateBy(x: tile.minX, y: 0)
    let localRect = rect.offsetBy(dx: -tile.minX, dy: 0)
    let mode = clip.channelMode ?? 0
    let displayChannels = mode == 0 ? header.channels : 1
    func sourceChannel(_ channel: Int) -> Int { mode == 1 ? 0 : mode == 2 ? min(1, header.channels - 1) : mode == 3 && header.channels > 1 ? header.channels : channel }
    let height = max(0, rect.maxY - waveTop - 2) / CGFloat(displayChannels)
    let rate = clip.audioRate
    let sourceScale = scale / rate
    // Broaden the same sample curve gradually as multiple cycles share a pixel.
    // Opaque ink avoids darker stripes where compressed strokes overlap.
    let waveStroke = 2.0
    let first = max(clip.startTime, Double(max(rect.minX, tile.minX) / scale))
    let last = min(clip.startTime + clip.duration, Double(min(rect.maxX, tile.maxX) / scale))
    guard last > first else { return }
    if let length = clip.loopLength, length > 0, length * sourceScale < 1 {
        // Repetitions smaller than a pixel form a continuous band. Inspect one
        // period's real audio once, rather than iterating every repetition.
        let loopStart = max(0, clip.loopStart ?? 0)
        let loopEnd = min(Double(header.frames) / header.rate, loopStart + length)
        let loopScale = 128 / length
        let loopStep = TimelineAudioWaveform.step(rate: header.rate, pixelsPerSecond: loopScale)
        let loopSpan = TimelineAudioWaveform.span(step: loopStep)
        let firstBlock = Int(loopStart * header.rate) / loopSpan
        let lastBlock = max(firstBlock, Int(max(loopStart, loopEnd - 1 / header.rate) * header.rate) / loopSpan)
        let geometries = (firstBlock...lastBlock).compactMap { cache.geometry(url, header: header, block: $0, pixelsPerSecond: loopScale) }
        for channel in 0..<displayChannels {
            let channelRect = CGRect(x: rect.minX, y: waveTop + height * CGFloat(channel) + 0.5, width: rect.width, height: max(0, height - 1))
            guard channelRect.intersects(visibleTile) else { continue }
            var minimum: CGFloat = 0, maximum: CGFloat = 0
            for geometry in geometries where sourceChannel(channel) < geometry.paths.count {
                geometry.paths[sourceChannel(channel)].forEach { element in
                    let point: CGPoint
                    switch element {
                    case .move(to: let p), .line(to: let p): point = p
                    default: return
                    }
                    let source = Double(geometry.start) / header.rate + point.x
                    guard source >= loopStart - Double(loopStep) / header.rate, source <= loopEnd else { return }
                    minimum = min(minimum, point.y); maximum = max(maximum, point.y)
                }
            }
            let middle = waveTop + height * (CGFloat(channel) + 0.5)
            let amplitude = height * 0.49 * 2 * min(pow(10, 24.0 / 20), max(0, clip.gain ?? 1))
            var waveContext = drawingContext
            waveContext.clip(to: Path(roundedRect: localRect, cornerRadius: 3))
            waveContext.clip(to: Path(channelRect.offsetBy(dx: -tile.minX, dy: 0)))
            let band = CGRect(x: first * scale - tile.minX, y: middle + minimum * amplitude, width: (last - first) * scale, height: max(0.5, (maximum - minimum) * amplitude))
            waveContext.fill(Path(band), with: .color(waveColor))
        }
        return
    }
    var position = first
    // One visible interval may cross a repeated source boundary.
    while position < last {
        let relativeSource = clip.sourceOffset + (position - clip.startTime) * rate
        let source: Double, end: Double
        if let length = clip.loopLength, length > 0 {
            let origin = clip.loopStart ?? 0
            let rawPhase = ((relativeSource - origin).truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
            let tolerance = min(length * 1e-6, max(abs(position).ulp * rate * 8, abs(relativeSource).ulp * 8, length.ulp * 8))
            let phase = rawPhase <= tolerance || length - rawPhase <= tolerance ? 0 : rawPhase
            source = origin + phase
            end = min(last, position + (length - phase) / rate)
        } else { source = relativeSource; end = last }
        guard end > position else { break }
        let sourceEnd = min(Double(header.frames) / header.rate, source + (end - position) * rate)
        let segment = CGRect(x: position * scale, y: waveTop, width: (end - position) * scale, height: max(0, rect.maxY - waveTop - 2))
        if sourceEnd > source {
            let repetition = clip.loopLength.flatMap { $0 > 0 ? floor((relativeSource - (clip.loopStart ?? 0)) / $0) : nil } ?? 0
            let presentationID = "\(clip.startTime):\(clip.sourceOffset):\(rect.minY):\(tile.minX):\(tile.minY):\(repetition)"
            let sourcePadding = min(2, (sourceEnd - source) / 2)
            let loopStart = clip.loopStart ?? 0
            let requestStart = max(clip.loopLength == nil ? 0 : loopStart, source - sourcePadding)
            let requestEnd = min(Double(header.frames) / header.rate,
                                 clip.loopLength.map { loopStart + $0 } ?? .infinity,
                                 sourceEnd + sourcePadding)
            let familyID = "\(clip.id):\(clip.startTime):\(clip.sourceOffset):\(rect.minY):\(repetition)"
            let layers = cache.drawingLayers(url, header: header, start: requestStart, end: requestEnd,
                                             pixelsPerSecond: sourceScale, presentationID: presentationID, familyID: familyID, owner: waveformOwner)
            for channel in 0..<displayChannels {
                    let channelRect = CGRect(x: rect.minX, y: waveTop + height * CGFloat(channel) + 0.5, width: rect.width, height: max(0, height - 1))
                    guard channelRect.intersects(visibleTile) else { continue }
                    let middle = waveTop + height * (CGFloat(channel) + 0.5)
                    let amplitude = height * 0.49 * 2 * min(pow(10, 24.0 / 20), max(0, clip.gain ?? 1))
                    var waveContext = drawingContext
                    waveContext.clip(to: Path(roundedRect: localRect, cornerRadius: 3))
                    waveContext.clip(to: Path(segment.offsetBy(dx: -tile.minX, dy: 0)))
                    waveContext.clip(to: Path(channelRect.offsetBy(dx: -tile.minX, dy: 0)))
                    // Composite the cached resolutions inside one isolated layer.
                    // Additive premultiplied coverage keeps the ink unchanged where
                    // both curves overlap; normal alpha-over would darken it.
                    func strokeLayers(_ blended: inout GraphicsContext) {
                        for layer in layers {
                            let drawing = layer.drawing
                            guard sourceChannel(channel) < drawing.cgPaths.count else { continue }
                            let x = position * scale - tile.minX + (Double(drawing.origin) / header.rate - source) * sourceScale
                            var transform = CGAffineTransform(a: sourceScale, b: 0, c: 0, d: amplitude, tx: x, ty: middle)
                            let wave = Path(drawing.cgPaths[sourceChannel(channel)].copy(using: &transform) ?? drawing.cgPaths[sourceChannel(channel)])
                            blended.opacity = layer.opacity
                            blended.stroke(wave, with: .color(waveColor), style: StrokeStyle(lineWidth: waveStroke, lineCap: .round, lineJoin: .round))
                        }
                    }
                    if layers.count == 1 { strokeLayers(&waveContext) }
                    else {
                        waveContext.drawLayer { blended in
                            blended.blendMode = .plusLighter
                            strokeLayers(&blended)
                        }
                    }
                    // Keep the straight channel centerline; it is not a
                    // simplified substitute for the source waveform.
                    var center = Path()
                    center.move(to: CGPoint(x: segment.minX - tile.minX, y: middle)); center.addLine(to: CGPoint(x: segment.maxX - tile.minX, y: middle))
                    waveContext.stroke(center, with: .color(waveColor.opacity(0.5)), lineWidth: 0.5)
            }
        }
        position = end
    }
}

private enum TimelineItemGlyphs {
    static let mute: Path = {
        var glyph = Path()
        glyph.move(to: CGPoint(x: 0, y: 7)); glyph.addLine(to: .zero)
        glyph.addLine(to: CGPoint(x: 3.5, y: 4)); glyph.addLine(to: CGPoint(x: 7, y: 0))
        glyph.addLine(to: CGPoint(x: 7, y: 7))
        return glyph
    }()
    static let fx: Path = {
        var glyph = Path()
        glyph.move(to: CGPoint(x: 0, y: 7)); glyph.addLine(to: .zero); glyph.addLine(to: CGPoint(x: 4, y: 0))
        glyph.move(to: CGPoint(x: 0, y: 3)); glyph.addLine(to: CGPoint(x: 3.5, y: 3))
        glyph.move(to: CGPoint(x: 6, y: 0)); glyph.addLine(to: CGPoint(x: 12, y: 7))
        glyph.move(to: CGPoint(x: 12, y: 0)); glyph.addLine(to: CGPoint(x: 6, y: 7))
        return glyph
    }()
}
private func drawTimelineItem(_ clip: AudioClip, track: Track, rect: CGRect, selected: Bool, silenced: Bool, scale: Double, tile: CGRect, context: inout GraphicsContext, mediaDirectory: URL? = nil, tempoSegments: [AudioClip]? = nil, missingAudio: Bool = false, waveformOwner: TimelineAudioWaveform.PresentationStore? = nil, drawWaveform: Bool = true, clickTiming: [TimelineTempoSection] = []) {
    let color = silenced ? Color(white: selected ? 0.7 : 0.55) : JarasTheme.track(track, emphasized: selected)
    let compact = rect.width < 20
    var path = compact ? Path(rect) : Path(roundedRect: rect, cornerRadius: 3)
    if track.kind == .standard, clip.loopLength != nil {
        // Screen-point dimensions stay visible at every horizontal zoom level.
        let halfWidth: CGFloat = 4, depth: CGFloat = min(5, rect.height / 3)
        let radius: CGFloat = compact ? 0 : 3
        let visible = max(clip.startTime, Double((tile.minX - halfWidth) / scale))...max(clip.startTime, Double((tile.maxX + halfWidth) / scale))
        let seams = ClipRepetitionBoundaries(clip: clip, visible: visible, minimumSpacing: 10 / scale)
        path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        for boundary in Array(seams).reversed() {
            let x = CGFloat(boundary * scale)
            guard x > rect.minX + radius, x < rect.maxX - radius else { continue }
            path.addLine(to: CGPoint(x: min(rect.maxX - radius, x + halfWidth), y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY - depth))
            path.addLine(to: CGPoint(x: max(rect.minX + radius, x - halfWidth), y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: rect.origin)
        path.closeSubpath()
    }
    if compact {
        context.fill(path, with: .color(color.opacity(silenced ? 0.55 : 0.88)))
        if selected { context.stroke(path, with: .color(JarasTheme.green), lineWidth: 1.5) }
    } else {
        context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(silenced ? 0.55 : 1), color.opacity(silenced ? 0.25 : selected ? 1 : 0.78)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
        context.stroke(path, with: .color(selected ? JarasTheme.green : color.opacity(0.75)), lineWidth: selected ? 1.5 : 0.6)
    }
    var titleContext = context
    if !compact {
    titleContext.clip(to: path)
    titleContext.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height <= 26 ? rect.height : min(13, rect.height))), with: .color(.black.opacity(0.16)))
    #if !os(macOS)
    let controls = GridSelectionItem(id: clip.id, rect: rect, gain: clip.gain ?? 1, phaseInverted: clip.phaseInverted == true, pan: clip.pan ?? 0, editable: track.kind == .standard || clip.isProjectionMedia, textEditable: track.kind.isText && !clip.isProjectionMedia)
    #if os(macOS)
    if let editRect = controls.editRect, editRect.intersects(tile) {
        titleContext.fill(Path(editRect), with: .color(.black.opacity(0.28)))
        let label = Text("Edit").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
        titleContext.draw(label, at: CGPoint(x: editRect.midX, y: editRect.midY), anchor: .center)
    }
    if let muteRect = controls.muteRect {
        if muteRect.intersects(tile) {
            titleContext.fill(Path(muteRect), with: .color(clip.muted == true ? .red : .black.opacity(0.28)))
            // A fixed M glyph needs no text shaping during zoom.
            let x = muteRect.midX - 3.5, y = muteRect.midY - 3.5
            titleContext.stroke(TimelineItemGlyphs.mute.applying(CGAffineTransform(translationX: x, y: y)), with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }
    if let fxRect = controls.fxRect, fxRect.intersects(tile) {
        let inserted = !(clip.fx?.inserted.isEmpty ?? true)
        titleContext.fill(Path(fxRect), with: .color(clip.fxBypassed == true ? .red : .black.opacity(0.28)))
        let x = fxRect.midX - 6, y = fxRect.midY - 3.5
        titleContext.stroke(TimelineItemGlyphs.fx.applying(CGAffineTransform(translationX: x, y: y)), with: .color(clip.fxBypassed == true ? .white : inserted ? JarasTheme.green : .white), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }
    if let knob = controls.gainKnobRect, knob.intersects(tile) {
        let center = CGPoint(x: knob.midX, y: knob.midY)
        let radius: CGFloat = 4.5, angle = 135 + controls.gainPosition * 270
        titleContext.fill(Path(ellipseIn: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)), with: .color(.black))
        var ring = Path(); ring.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
        titleContext.stroke(ring, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        if controls.gainPosition > 0 {
            var fill = Path(); fill.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(angle), clockwise: false)
            titleContext.stroke(fill, with: .color(JarasTheme.green), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        let radians = angle * .pi / 180
        var needle = Path(); needle.move(to: center); needle.addLine(to: CGPoint(x: center.x + cos(radians) * 3.5, y: center.y + sin(radians) * 3.5))
        titleContext.stroke(needle, with: .color(JarasTheme.green), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
    #endif
    if let phase = controls.phaseRect {
        titleContext.fill(Path(phase), with: .color(clip.phaseInverted == true ? .yellow : .black.opacity(0.28)))
        let center = CGPoint(x: phase.midX, y: phase.midY)
        var symbol = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        symbol.move(to: CGPoint(x: center.x-4.5, y: center.y+4.5)); symbol.addLine(to: CGPoint(x: center.x+4.5, y: center.y-4.5))
        titleContext.stroke(symbol, with: .color(clip.phaseInverted == true ? .black : .white), lineWidth: 1.2)
    }
    if let pan = controls.panKnobRect {
        let center = CGPoint(x: pan.midX, y: pan.midY)
        let ring = Path(ellipseIn: CGRect(x: center.x-4.5, y: center.y-4.5, width: 9, height: 9))
        titleContext.fill(ring, with: .color(.black))
        titleContext.stroke(ring, with: .color(.white), lineWidth: 1.5)
        let angle = (135 + controls.panPosition * 270) * .pi / 180
        var needle = Path(); needle.move(to: center); needle.addLine(to: CGPoint(x: center.x+cos(angle)*3.5, y: center.y+sin(angle)*3.5))
        titleContext.stroke(needle, with: .color(JarasTheme.green), lineWidth: 2)
    }
    if let gainLabel = controls.gainLabelRect {
        drawTimelineName(controls.gainLabel, in: gainLabel, visibleRect: tile, context: &titleContext)
    }
    let titleInset = controls.titleInset
    let title = clip.isImage ? JarasLocalization.string("Image") : track.kind == .timecode && !clip.isProjectionMedia ? (track.timecode?.mode ?? "mtc").uppercased() : clip.name
    drawTimelineName(title, in: CGRect(x: rect.minX + titleInset, y: rect.minY, width: max(0, rect.width - titleInset), height: min(13, rect.height)), visibleRect: tile, context: &context)
    #endif
    }
    if rect.height <= 26 { return } // Collapsed tracks show only the item bar.
    if let midi = clip.midi {
        let body = CGRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: max(0, rect.height - 16))
        var ink = context; ink.clip(to: Path(body.intersection(tile)))
        let low = max(0, (midi.notes.map(\.pitch).min() ?? 60) - 2), high = min(127, (midi.notes.map(\.pitch).max() ?? 72) + 2)
        let step = body.height / CGFloat(max(12, high - low + 1))
        for note in (tempoSegments ?? [clip]).flatMap({ $0.midiPlaybackNotes() }) {
            let rectangle = CGRect(x: note.start * scale, y: body.maxY - CGFloat(note.pitch - low + 1) * step,
                                   width: max(1, (note.end - note.start) * scale), height: max(1, step * 0.75))
            if rectangle.intersects(tile) { ink.fill(Path(rectangle), with: .color(.white.opacity(silenced ? 0.45 : 0.85))) }
        }
        return
    }
    if missingAudio {
        let body = CGRect(x: rect.minX, y: rect.minY + 13, width: rect.width, height: max(0, rect.height - 13))
        if body.height >= 12 { drawTimelineName(JarasLocalization.string("Not found"), in: body, visibleRect: tile, centered: true, context: &context) }
        return
    }
    if track.kind == .click && !clip.isProjectionMedia {
        let body = CGRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: max(0, rect.height - 16))
        let visible = body.intersection(tile)
        guard !visible.isEmpty else { return }
        var wave = Path()
        let middle = body.midY, amplitude = body.height * 0.45
        let pulses = ClickTrackProgram.visibleBeats(sections: clickTiming, start: clip.startTime, end: clip.startTime + clip.duration,
            visibleStart: Double(visible.minX) / scale, visibleEnd: Double(visible.maxX) / scale, pixelsPerSecond: scale)
        for time in pulses {
            let x = CGFloat(time * scale)
            let tail = max(1, min(CGFloat(0.08 * scale), 16))
            wave.move(to: CGPoint(x: x, y: middle - amplitude))
            wave.addLine(to: CGPoint(x: x + tail, y: middle))
            wave.addLine(to: CGPoint(x: x, y: middle + amplitude))
            wave.closeSubpath()
        }
        var waveContext = context; waveContext.clip(to: Path(visible))
        waveContext.fill(wave, with: .color(Color(white: 0.88).opacity(silenced ? 0.5 : 0.9)))
        return
    }
    if (track.kind == .timecode && !clip.isProjectionMedia) || track.kind == .video || (clip.isProjectionMedia && ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(URL(fileURLWithPath: clip.audioFile?.path ?? "").pathExtension.lowercased())) {
        let body = CGRect(x: rect.minX, y: rect.minY + 13, width: rect.width, height: max(0, rect.height - 13))
        if body.height >= 12 {
            let fileExtension = URL(fileURLWithPath: clip.audioFile?.path ?? "").pathExtension
            let isImage = UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true
            let label = track.kind == .timecode && !clip.isProjectionMedia ? "TIMECODE" : isImage ? JarasLocalization.string("Image") : "VIDEO"
            drawTimelineName(label, in: body, visibleRect: tile, centered: true, context: &context)
        }
        return
    }
    if track.kind.isText && !clip.isProjectionMedia {
        if let text = clip.text, !text.isEmpty, rect.width > 16, rect.height > 26 {
            let textRect = CGRect(x: rect.minX + 5, y: rect.minY + 17, width: rect.width - 10, height: rect.height - 20)
            if compact { titleContext.clip(to: path) }
            titleContext.clip(to: Path(textRect))
            titleContext.draw(Text(verbatim: text).font(.system(size: 12, weight: .semibold)).foregroundColor(.black), in: textRect)
        }
        return
    }
    guard drawWaveform || track.kind != .standard || mediaDirectory == nil || (clip.audioFile ?? track.audioFile) == nil else { return }
    let waveTop = rect.minY + min(14, rect.height * 0.35)
    let rgb = TrackNameContrast.components(track.color ?? JarasTheme.roleHex(track.role), emphasized: selected)
    let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    // Neutral gray ink follows the item brightness, without becoming black.
    let waveColor = Color(white: silenced ? 0.78 : luminance > 0.68 ? 0.52 : luminance > 0.42 ? 0.9 : 0.8)
    if let mediaDirectory, let file = clip.audioFile ?? track.audioFile, track.kind == .standard {
        for fragment in tempoSegments ?? [clip] {
            var waveformContext = context
            waveformContext.clip(to: path)
            drawTimelineAudioWaveform(fragment, url: mediaDirectory.appendingPathComponent(file.path, isDirectory: false), rect: rect, waveTop: waveTop, scale: scale, tile: tile, waveColor: waveColor, context: &waveformContext, waveformOwner: waveformOwner)
        }
    } else {
    let channels = clip.waveformChannels.flatMap { $0.isEmpty ? nil : $0 } ?? [clip.waveform]
    let channelHeight = max(1, rect.maxY - waveTop - 2) / CGFloat(channels.count)
    for (channel, peaks) in channels.enumerated() {
    var wave = Path()
    // Visual magnification only; each channel keeps its own drawing bounds.
    let middle = waveTop + channelHeight * (CGFloat(channel) + 0.5), amplitude = channelHeight * 0.49 * 2 * min(pow(10, 24.0 / 20), max(0, clip.gain ?? 1))
    wave.move(to: CGPoint(x: max(rect.minX, tile.minX), y: middle))
    wave.addLine(to: CGPoint(x: min(rect.maxX, tile.maxX), y: middle))
    if !peaks.isEmpty, let loopLength = clip.loopLength, loopLength > 0 {
        let firstX = max(rect.minX, tile.minX), lastX = min(rect.maxX, tile.maxX)
        for x in stride(from: firstX, through: lastX, by: 1.5) {
            let source = clip.sourceOffset - (clip.loopStart ?? 0) + (Double(x / scale) - clip.startTime) * clip.audioRate
            let phase = ((source.truncatingRemainder(dividingBy: loopLength) + loopLength).truncatingRemainder(dividingBy: loopLength)) / loopLength
            let peak = peaks[min(peaks.count - 1, Int(phase * Double(peaks.count)))]
            wave.move(to: CGPoint(x: x, y: middle - peak * amplitude)); wave.addLine(to: CGPoint(x: x, y: middle + peak * amplitude))
        }
    } else if !peaks.isEmpty {
        appendTimelineWaveform(peaks, rect: rect, middle: middle, amplitude: amplitude, tile: tile, path: &wave)
    }
    var waveContext = context
    waveContext.clip(to: path)
    waveContext.clip(to: Path(CGRect(x: rect.minX, y: waveTop + channelHeight * CGFloat(channel) + 0.5, width: rect.width, height: max(0, channelHeight - 1))))
    waveContext.stroke(wave, with: .color(waveColor), lineWidth: 1)
    }
    }

}

#if os(macOS)
import AppKit
struct MixerResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let maximum: CGFloat
    var minimum: CGFloat = 0
    var direction: CGFloat = 1
    var scrollController: SidebarScrollController? = nil
    var onStart: () -> Void = {}
    var onToggle: () -> Void = {}
    var onEnd: (CGFloat) -> Void = { _ in }
    let onResize: (CGFloat) -> Void
    func makeNSView(context: Context) -> MixerDividerView {
        let view = MixerDividerView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Resize mixer")
        return view
    }
    func updateNSView(_ view: MixerDividerView, context: Context) {
        view.columnWidth = width
        view.maximum = maximum
        view.minimum = minimum
        view.onResize = onResize
        view.direction = direction
        view.scrollController = scrollController
        view.onStart = onStart
        view.onToggle = onToggle
        view.onEnd = onEnd
    }
}
final class MixerDividerView: NSView {
    var columnWidth: CGFloat = 138
    var maximum: CGFloat = 486.5
    var minimum: CGFloat = 0
    var direction: CGFloat = 1
    var onStart: (() -> Void)?
    var onToggle: (() -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var scrollController: SidebarScrollController? {
        didSet {
            guard oldValue !== scrollController else { return }
            if let scrollObserver { oldValue?.removeObserver(scrollObserver) }
            scrollObserver = scrollController?.observe { [weak self] in self?.refreshIndicator() }
            refreshIndicator()
        }
    }
    private var scrollObserver: UUID?
    private var hoverArea: NSTrackingArea?
    private var pointerCursorMonitor: Any?
    private static weak var pointerCursorOwner: MixerDividerView?
    var scrollIndicatorVisible: Bool { scrollController?.metrics.canScroll == true }
    private var pendingScroll: CGFloat?
    private var hasScrolledInDrag = false
    private var cancelScrollDisplayLink: (() -> Void)?
    private var scrollFrameTimer: Timer?
    private var latestWidth: CGFloat = 0
    private var resizeLayoutInProgress = false
    var resizeLayout: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    private var startingWidth: CGFloat = 0
    private var startingX: CGFloat = 0
    private var startingY: CGFloat = 0
    private var startingScroll: CGFloat = 0
    private var scrollPerPoint: CGFloat = 0
    private var mouseIsDown = false
    private enum DragAxis { case pending, resize, scroll }
    private var dragAxis = DragAxis.pending
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var scrollThumbRect: NSRect {
        let metrics = scrollController?.metrics ?? SidebarScrollMetrics()
        guard metrics.canScroll else { return .zero }
        let height = max(0, bounds.height - 4)
        let thumb = min(height, max(24, height * metrics.viewportHeight / max(1, metrics.documentHeight)))
        let travel = height - thumb
        let width = min(6, bounds.width)
        return NSRect(x: bounds.midX - width / 2, y: bounds.minY + 2 + travel * metrics.offset / metrics.maximumOffset, width: width, height: thumb)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    private static let moveCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let points: [(CGFloat, CGFloat)] = [(12,1),(17,6),(14,6),(14,10),(18,10),(18,7),
                (23,12),(18,17),(18,14),(14,14),(14,18),(17,18),(12,23),(7,18),(10,18),
                (10,14),(6,14),(6,17),(1,12),(6,7),(6,10),(10,10),(10,6),(7,6)]
            let path = NSBezierPath()
            path.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
            path.close(); path.lineWidth = 1.1; path.lineJoinStyle = .round
            NSColor.white.setFill(); path.fill(); NSColor.black.setStroke(); path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: Self.moveCursor) }
    private func releasePointerCursor() {
        guard Self.pointerCursorOwner === self else { return }
        Self.pointerCursorOwner = nil
        if NSCursor.current == Self.moveCursor { NSCursor.arrow.set() }
    }
    private func updatePointerCursor() {
        if let owner = Self.pointerCursorOwner, owner.mouseIsDown { return }
        guard let window else { releasePointerCursor(); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(point) {
            Self.pointerCursorOwner = self
            Self.moveCursor.set()
        } else { releasePointerCursor() }
    }
    override func cursorUpdate(with event: NSEvent) { updatePointerCursor() }
    override func mouseExited(with event: NSEvent) {
        if !mouseIsDown { releasePointerCursor() }
    }
    override func mouseEntered(with event: NSEvent) { updatePointerCursor() }
    override func mouseMoved(with event: NSEvent) { if !mouseIsDown { updatePointerCursor() } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pointerCursorMonitor { NSEvent.removeMonitor(pointerCursorMonitor); self.pointerCursorMonitor = nil }
        if window == nil {
            mouseIsDown = false; stopScrollUpdates()
            releasePointerCursor()
        } else {
            // Tracking exits can be lost when a drag changes hosting/clip bounds.
            // Recheck the actual pointer instead of retaining the resize cursor.
            pointerCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self, !self.mouseIsDown, event.window === self.window else { return event }
                self.updatePointerCursor()
                return event
            }
        }
    }
    private func refreshIndicator() { needsDisplay = true }
    private func queueScroll(to offset: CGFloat) {
        // AppKit coalesces mouse-drag events already. Waiting for a newly-created
        // display link here made the thumb lag one frame behind every movement.
        pendingScroll = offset
        hasScrolledInDrag = true
        flushPendingScroll()
    }
    private func scheduleScrollFrame() {
        guard cancelScrollDisplayLink == nil, scrollFrameTimer == nil else { return }
        if #available(macOS 14.0, *), window?.isVisible == true {
            let target = SidebarScrollFrameTarget { [weak self] in self?.advanceScrollFrame() }
            let link = displayLink(target: target, selector: #selector(SidebarScrollFrameTarget.tick))
            link.add(to: .main, forMode: .common)
            cancelScrollDisplayLink = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: false) { [weak self] _ in self?.advanceScrollFrame() }
            timer.tolerance = 0
            scrollFrameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    /// One latest target per display frame; mouse-up flushes without waiting.
    func advanceScrollFrame() {
        cancelScrollDisplayLink?(); cancelScrollDisplayLink = nil
        scrollFrameTimer?.invalidate(); scrollFrameTimer = nil
        guard mouseIsDown, window != nil else { pendingScroll = nil; return }
        flushPendingScroll()
    }
    private func flushPendingScroll() {
        guard let offset = pendingScroll else { return }
        pendingScroll = nil
        scrollController?.scroll(to: offset)
    }
    private func stopScrollUpdates() {
        cancelScrollDisplayLink?(); cancelScrollDisplayLink = nil
        scrollFrameTimer?.invalidate(); scrollFrameTimer = nil
        pendingScroll = nil; hasScrolledInDrag = false
    }
    private func commitResizeLayout() {
        guard !resizeLayoutInProgress, let content = window?.contentView else { return }
        resizeLayoutInProgress = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit(); resizeLayoutInProgress = false }
        if let resizeLayout { resizeLayout(); return }
        // The mixer lives inside its own native workspace host. Commit that
        // boundary without visiting the transport or the sibling setlist host.
        var ancestor = superview
        while let view = ancestor {
            if let boundary = view as? SidebarResizeLayoutBoundary {
                boundary.commitSidebarResizeLayout(); return
            }
            ancestor = view.superview
        }
        content.layoutSubtreeIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSRect(x: bounds.midX - 2, y: bounds.minY, width: 4, height: bounds.height).fill()
        if scrollIndicatorVisible {
            NSColor(calibratedRed: 0.22, green: 1, blue: 0.55, alpha: 0.25).setFill()
            NSRect(x: bounds.midX - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
            if !scrollThumbRect.isEmpty {
                NSColor(calibratedRed: 0.22, green: 1, blue: 0.55, alpha: 1).setFill()
                NSBezierPath(roundedRect: scrollThumbRect, xRadius: 3, yRadius: 3).fill()
            }
        } else {
            NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 14, width: 2, height: 28), xRadius: 1, yRadius: 1).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        stopScrollUpdates()
        Self.pointerCursorOwner = self
        Self.moveCursor.set()
        if event.clickCount == 2 {
            mouseIsDown = false; dragAxis = .pending; onToggle?()
            releasePointerCursor(); window?.invalidateCursorRects(for: self); updatePointerCursor()
            return
        }
        mouseIsDown = true
        dragAxis = .pending
        startingWidth = columnWidth
        latestWidth = columnWidth
        startingX = event.locationInWindow.x
        startingY = event.locationInWindow.y
        scrollController?.refresh()
        let metrics = scrollController?.metrics ?? SidebarScrollMetrics()
        startingScroll = metrics.offset
        let travel = max(0, bounds.height - 4 - scrollThumbRect.height)
        scrollPerPoint = metrics.canScroll && travel > 0 ? metrics.maximumOffset / travel : 0
    }
    override func mouseDragged(with event: NSEvent) { updateDrag(with: event, layoutResize: true) }
    private func updateDrag(with event: NSEvent, layoutResize: Bool) {
        guard mouseIsDown else { return }
        let dx = event.locationInWindow.x - startingX
        let dy = startingY - event.locationInWindow.y
        if dragAxis == .pending {
            guard max(abs(dx), abs(dy)) >= 3 else { return }
            if abs(dy) > abs(dx), scrollPerPoint > 0 { dragAxis = .scroll }
            else if abs(dx) >= abs(dy) { dragAxis = .resize; onStart?() }
            else { return }
        }
        if dragAxis == .scroll {
            Self.moveCursor.set()
            queueScroll(to: startingScroll + dy * scrollPerPoint)
            return
        }
        Self.moveCursor.set()
        let width = min(maximum, max(minimum, startingWidth + direction * (event.locationInWindow.x - startingX)))
        latestWidth = width
        // Horizontal width must reach the pointer in this event. Waiting for a
        // new display link here added an entire frame to every subsequent drag.
        onResize?(width)
        if layoutResize { commitResizeLayout() }
    }
    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        updateDrag(with: event, layoutResize: false)
        let finishedAxis = dragAxis
        flushPendingScroll()
        stopScrollUpdates()
        mouseIsDown = false
        dragAxis = .pending
        if finishedAxis == .resize {
            onEnd?(latestWidth)
            // Persist and clear transient state before the single final layout.
            commitResizeLayout()
        }
        if finishedAxis == .pending && startingWidth == 0 { onToggle?() }
        releasePointerCursor()
        window?.invalidateCursorRects(for: self)
        updatePointerCursor()
    }
    deinit {
        if let pointerCursorMonitor { NSEvent.removeMonitor(pointerCursorMonitor) }
        cancelScrollDisplayLink?(); scrollFrameTimer?.invalidate()
        if let controller = scrollController, let id = scrollObserver {
            Task { @MainActor in controller.removeObserver(id) }
        }
    }
}
private final class SidebarScrollFrameTarget: NSObject {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func tick() { callback() }
}

#endif

#if os(macOS)
private struct RegionShortcut: NSViewRepresentable {
    let hasDeletionSelection: () -> Bool
    let delete: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let create: () -> Void
    let selectAll: () -> Bool
    let copy: () -> Bool
    let move: () -> Bool
    let paste: () -> Void
    let createMarker: () -> Void
    let createSectionMarker: () -> Void
    let escape: () -> Void
    func makeNSView(context: Context) -> RegionShortcutView { RegionShortcutView() }
    func updateNSView(_ view: RegionShortcutView, context: Context) { view.hasDeletionSelection = hasDeletionSelection; view.escape = escape; view.create = create; view.createMarker = createMarker; view.createSectionMarker = createSectionMarker; view.delete = delete; view.undoEdit = undo; view.redoEdit = redo; view.selectAllItems = selectAll; view.copyItems = copy; view.moveItems = move; view.pasteItems = paste }
}
final class RegionShortcutView: NSView {
    private static let owners = NSHashTable<RegionShortcutView>.weakObjects()
    var hasDeletionSelection: (() -> Bool)?
    /// Both native event monitors consult the same priority before the setlist.
    /// Window-scoped owners avoid stale selections from another project window.
    static func handleSelectedObjectsDelete(_ event: NSEvent) -> Bool {
        guard [51,117].contains(event.keyCode), event.modifierFlags.intersection([.shift,.command,.control,.option]).isEmpty,
              let owner = owners.allObjects.first(where: { $0.window != nil && $0.window === event.window && $0.acceptsDelete }),
              owner.hasDeletionSelection?() == true else { return false }
        if !event.isARepeat { owner.delete?() }
        return true
    }
    private var acceptsDelete: Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window), ControlMappings.shared.editing == nil else { return false }
        return !(window.firstResponder is NSTextView) && !(window.firstResponder is NSTextField)
    }
    var create: (() -> Void)?
    var createMarker: (() -> Void)?
    var createSectionMarker: (() -> Void)?
    var escape: (() -> Void)?
    var delete: (() -> Void)?
    var undoEdit: (() -> Void)?
    var redoEdit: (() -> Void)?
    var selectAllItems: (() -> Bool)?
    var copyItems: (() -> Bool)?
    var moveItems: (() -> Bool)?
    var pasteItems: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        Self.owners.remove(self)
        guard window != nil else { return }
        Self.owners.add(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.isKeyWindow == true,
                  self.window?.attachedSheet == nil,
                  !NativeTimelineInputGate.shared.isBlocked(self.window),
                  !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField) else { return event }
            let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
            if (flags == .command || flags == .control), event.charactersIgnoringModifiers?.lowercased() == "a",
               !event.isARepeat, self.selectAllItems?() == true { return nil }
            if Self.handleSelectedObjectsDelete(event) { return nil }
            if ControlMappings.shared.handleKey(event) { return nil }
            if flags == .command || flags == .control {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": if event.isARepeat || self.copyItems?() == true { return nil }
                case "x": if event.isARepeat || self.moveItems?() == true { return nil }
                case "v": if !event.isARepeat { self.pasteItems?() }; return nil
                default: break
                }
            }
            if event.keyCode == 53, flags.isEmpty { if !event.isARepeat { self.escape?() }; return nil }
            if [51,117].contains(event.keyCode), flags.isEmpty {
                if Self.handleSelectedObjectsDelete(event) { return nil }
                if SetlistKeyView.handleDelete(event) { return nil }
                if !event.isARepeat { self.delete?() }; return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "z",
               flags == .command || flags == .control || flags == [.command,.shift] || flags == [.control,.shift] {
                if !event.isARepeat { if flags.contains(.shift) { self.redoEdit?() } else { self.undoEdit?() } }; return nil
            }
            if event.keyCode == 46, flags == .option {
                if !event.isARepeat { self.createSectionMarker?() }; return nil
            }
            guard ["r", "m"].contains(event.charactersIgnoringModifiers?.lowercased() ?? ""), flags == .shift else { return event }
            if !event.isARepeat {
                if event.charactersIgnoringModifiers?.lowercased() == "m" { self.createMarker?() } else { self.create?() }
            }
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
#endif

#if os(macOS)
@MainActor private final class TimelineSelectionLayoutCache {
    private var key: TimelineRenderKey?
    private var rowHeight: CGFloat = 0
    private var rulerHeight: CGFloat = 0
    private var value: GridSelectionLayout?
    func layout(key: TimelineRenderKey, rowHeight: CGFloat, rulerHeight: CGFloat,
                rowOffsets: [CGFloat], laneHeights: [CGFloat],
                makeItems: () -> [GridSelectionItem]) -> GridSelectionLayout {
        if let value, self.key == key, self.rowHeight == rowHeight, self.rulerHeight == rulerHeight { return value }
        let value: GridSelectionLayout
        if let previous = self.value, self.key == key {
            value = previous.projectingRows(offsets: rowOffsets, laneHeights: laneHeights, top: rulerHeight)
        } else {
            value = GridSelectionLayout(items: makeItems(), timeCoordinates: true)
        }
        self.key = key; self.rowHeight = rowHeight; self.rulerHeight = rulerHeight; self.value = value
        return value
    }
}
#endif

@MainActor private final class TrackLayoutCache {
    private var regionKey: TimelineRenderKey?
    private var regions: RegionLanes?
    func regionLanes(_ parts: [Part], key: TimelineRenderKey) -> RegionLanes {
        if regionKey == key, let regions { return regions }
        let next = RegionLanes(parts: parts)
        regionKey = key; regions = next
        return next
    }
    private var key: TimelineRenderKey?
    private var height: CGFloat = 0
    private var rows: TrackRowLayout?
    func layout(_ tracks: [Track], height: CGFloat, key: TimelineRenderKey) -> TrackRowLayout {
        if self.key == key, self.height == height, let rows { return rows }
        let rows: TrackRowLayout
        if self.key == key, let previous = self.rows {
            rows = TrackRowLayout(lanes: previous.lanes, baseHeight: height)
        } else {
            rows = TrackRowLayout(tracks: tracks, baseHeight: height)
        }
        self.key = key; self.height = height; self.rows = rows
        return rows
    }
}
@MainActor private final class RegionOverlapCache {
    private var song: UUID?
    private var revision: UInt64?
    private var overlapping: Set<UUID> = []
    func regions(song: Song, revision: UInt64) -> Set<UUID> {
        if self.song == song.id && self.revision == revision { return overlapping }
        self.song = song.id; self.revision = revision
        overlapping = []
        var cluster: [UUID] = [], end = -Double.infinity
        for region in song.parts.filter({ $0.parentRegionID == nil }).sorted(by: { $0.startTime < $1.startTime }) {
            if region.startTime >= end {
                if cluster.count > 1 { overlapping.formUnion(cluster) }
                cluster = []; end = region.endTime
            }
            cluster.append(region.id); end = max(end, region.endTime)
        }
        if cluster.count > 1 { overlapping.formUnion(cluster) }
        return overlapping
    }
}

@MainActor private struct TrackRowLayout {
    let lanes: [TrackLanes]
    let laneHeights: [CGFloat]
    let heights: [CGFloat]
    let offsets: [CGFloat]
    let totalHeight: CGFloat
    init(tracks: [Track], baseHeight: CGFloat) {
        let lanes = tracks.map { track in
            var layout = TrackLanes(track: track)
            layout.count = RecordingLaneLayout.shared.count(for: track.id, existing: layout.count)
            return layout
        }
        self.init(lanes: lanes, baseHeight: baseHeight)
    }
    init(lanes: [TrackLanes], baseHeight: CGFloat) {
        self.lanes = lanes
        laneHeights = lanes.map { $0.count == 1 ? baseHeight : max(26, baseHeight * 0.7) }
        heights = zip(lanes, laneHeights).map { CGFloat($0.0.count) * $0.1 }
        var running: CGFloat = 0
        offsets = heights.map { value in defer { running += value }; return running }
        totalHeight = running
    }
}

private struct TimelineHeader: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.documentWidth == rhs.documentWidth && lhs.visibleRect == rhs.visibleRect && lhs.renderKey == rhs.renderKey && lhs.extent == rhs.extent && lhs.colorScheme == rhs.colorScheme
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    let visibleRect: CGRect
    let song: Song
    let renderKey: TimelineRenderKey
    let extent: Double
    var documentWidth: CGFloat? = nil
    var body: some View {
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, diagnosticName: "header", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light)) { context, size, tile, waveformOwner in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(JarasTheme.panel))
            let scale = size.width / extent
            let lanes = RegionLanes(parts: song.parts)
            let regionHeight = CGFloat(lanes.count) * 16
            for (index, part) in song.parts.enumerated() {
                guard part.parentRegionID == nil else { continue }
                let rect = CGRect(x: part.startTime * scale, y: CGFloat(lanes.lanes[part.id] ?? 0) * 16, width: max(1, (part.endTime - part.startTime) * scale), height: 16)
                guard rect.intersects(tile) else { continue }
                context.fill(Path(rect), with: .color(Color(hex: part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965))))
                var labelContext = context
                labelContext.clip(to: Path(rect))
                // Parts are stored in creation order; moving a region keeps its number.
                let identifierText = song.parts.contains(where: { $0.parentRegionID == part.id }) ? JarasLocalization.string("Special") : String(format: "%dst  %02d", part.semitones, index + 1)
                let identifier = TimelineStaticText.label(identifierText, style: .regionIdentifier, displayScale: displayScale)
                let identifierWidth = identifier?.width ?? 1000
                if rect.width >= identifierWidth + 8 {
                    identifier?.draw(at: CGPoint(x: rect.maxX - 4, y: rect.minY + 2), trailing: true, context: &labelContext)
                    let nameRect = CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - identifierWidth - 8), height: rect.height)
                    drawTimelineName(part.displayName, in: nameRect, color: .white, visibleRect: tile, context: &labelContext)
                }
            }
            let markers = song.markers ?? []
            for marker in markers {
                #if os(macOS)
                continue // Marker lines are drawn by TimelineDraggableMarkerLayer.
                #endif
                let x = marker.position * scale
                guard x + 5 >= tile.minX, x - 5 <= tile.maxX else { continue }
                let color = Color(hex: marker.isTempo ? 0x999999 : marker.color).opacity(marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)
                var stem = Path(); stem.move(to: CGPoint(x: x, y: marker.isTempo ? regionHeight + markerLaneHeight : regionHeight + 1)); stem.addLine(to: CGPoint(x: x, y: size.height))
                if !marker.isTempo { context.stroke(stem, with: .color(color.opacity(0.16)), lineWidth: 5) }
                context.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: marker.isTempo ? [2, 3] : []))
            }
            for y in (0...lanes.count).map { CGFloat($0) * 16 + 0.5 } +
                [regionHeight + markerLaneHeight + 0.5, regionHeight + markerLaneHeight + tempoLaneHeight + 0.5, size.height - 0.5] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(JarasTheme.line), lineWidth: 1)
            }
            let barTop = regionHeight + markerLaneHeight + tempoLaneHeight
            let sample = TimelineTimeRuler.labelSample(through: extent)
            let labelWidth = TimelineStaticText.label(sample, style: .barNumber, displayScale: displayScale).map { Double($0.size.width) }
            let labelSpacing = TimelineTimeRuler.labelSpacing(through: extent, measuredWidth: labelWidth, pixelsPerSecond: scale)
            let ticks = TimelineTimeRuler.ticks(in: song.tempoSections(until: extent),
                from: max(0, Double((tile.minX - labelSpacing) / scale)), to: Double(tile.maxX / scale),
                pixelsPerSecond: scale, divisions: song.projectTime.divisions, minimumLabelSpacing: labelSpacing)
            let pixel = 1 / displayScale
            for mark in ticks {
                let x = floor(mark.time * scale * displayScale) / displayScale + pixel / 2
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: barTop + 1))
                tick.addLine(to: CGPoint(x: x, y: barTop + (mark.primary ? 7 : 4)))
                context.stroke(tick, with: .color(TimelineStaticText.rulerColor), lineWidth: pixel)
                if !mark.label.isEmpty {
                    TimelineStaticText.label(mark.label, style: .barNumber, displayScale: displayScale)?
                        .draw(at: CGPoint(x: x + 3, y: barTop + 2), context: &context)
                }
            }
        }
    }
}

/// Flags and their input targets occupy the same dedicated, clipped lane.
/// Its origin follows the number of region rows, including overlapping regions.
private struct TimelineMarkerLane: View {
    let visibleRect: CGRect
    let song: Song
    let renderKey: TimelineRenderKey
    let extent: Double
    var documentWidth: CGFloat? = nil
    var tempoOnly = false
    var body: some View {
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, diagnosticName: "marker-lane", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: false)) { context, size, tile, waveformOwner in
            let scale = size.width / extent
            let markers = (song.markers ?? []).filter { $0.isTempo == tempoOnly }
            let widths = Dictionary(uniqueKeysWithValues: markers.map { marker in
                let label = TimelineResolvedName.label(song.markerLabel(marker), context: context)
                return (marker.id, Double(ceil(label.width)))
            })
            let flags = TimelineMarker.flagWidths(markers, scale: scale, widths: widths, regionEnds: tempoOnly ? [:] : song.markerRegionEnds)
            // Keep drawing coordinates near the viewport even in long projects.
            context.translateBy(x: tile.minX, y: 0)
            let visible = tile.offsetBy(dx: -tile.minX, dy: 0)
            for marker in markers {
                guard let width = flags[marker.id] else { continue }
                let x = marker.position * scale
                let rect = CGRect(x: x - tile.minX,
                                  y: 1, width: width, height: markerLaneHeight - 2)
                guard rect.intersects(visible) else { continue }
                if tempoOnly {
                    let display = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
                    context.fill(display, with: .color(JarasTheme.display))
                    context.stroke(display, with: .color(JarasTheme.line), lineWidth: 1)
                    drawTimelineName(song.markerLabel(marker), in: rect, color: JarasTheme.text, visibleRect: visible, centered: true, context: &context)
                } else {
                    drawMarkerFlag(marker, rect: rect, context: &context)
                    drawTimelineName(song.markerLabel(marker), in: rect, color: .black, visibleRect: visible, context: &context)
                }
            }
        }
    }
}

/// Keep every backing surface below GPU texture limits, even at maximum zoom
/// or after extending the timeline. Drawing coordinates stay in timeline space.
private final class TimelineResolvedName: NSObject {
    static let cache: NSCache<NSString, TimelineResolvedName> = {
        let cache = NSCache<NSString, TimelineResolvedName>()
        cache.countLimit = 4096; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    let text: GraphicsContext.ResolvedText
    let width: CGFloat
    init(_ text: GraphicsContext.ResolvedText) {
        self.text = text
        width = text.measure(in: CGSize(width: 100_000, height: 20)).width
    }
    static func label(_ name: String, context: GraphicsContext) -> TimelineResolvedName {
        if let value = cache.object(forKey: name as NSString) { return value }
        let value = TimelineResolvedName(context.resolve(Text(verbatim: name).font(.system(size: 9, weight: .medium))))
        cache.setObject(value, forKey: name as NSString, cost: name.utf8.count * 16 + 128)
        return value
    }
}
private final class TimelineNameMetrics: NSObject {
    static let cache: NSCache<NSString, TimelineNameMetrics> = {
        let cache = NSCache<NSString, TimelineNameMetrics>(); cache.countLimit = 2048; cache.totalCostLimit = 4 * 1024 * 1024; return cache
    }()
    let fullWidth: CGFloat
    private let characters: [Character]
    private var shortened: [Int: (String, CGFloat)] = [:]
    private let lock = NSLock()
    init(name: String, measure: (String) -> CGFloat) {
        fullWidth = measure(name)
        characters = Array(name)
    }
    static func metrics(_ name: String, measure: (String) -> CGFloat) -> TimelineNameMetrics {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let value = TimelineNameMetrics(name: name, measure: measure)
        cache.setObject(value, forKey: name as NSString, cost: name.utf8.count * 16 + 128)
        return value
    }
    private func prefix(_ length: Int, measure: (String) -> CGFloat) -> (String, CGFloat) {
        if let value = shortened[length] { return value }
        let text = String(characters.prefix(length)) + "…"
        let value = (text, measure(text))
        shortened[length] = value
        return value
    }
    func fitting(_ name: String, width: CGFloat, measure: (String) -> CGFloat) -> String? {
        lock.lock(); defer { lock.unlock() }
        if fullWidth <= width { return name }
        guard !characters.isEmpty, prefix(0, measure: measure).1 <= width else { return nil }
        // Measure only the prefixes visited by the search. Eagerly shaping every
        // prefix of every newly visible item stalls the first zoom frame.
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if prefix(middle, measure: measure).1 <= width { low = middle } else { high = middle - 1 }
        }
        return prefix(low, measure: measure).0
    }
}
private func drawTimelineName(_ name: String, in rect: CGRect, color: Color = JarasTheme.text, visibleRect: CGRect, centered: Bool = false, context: inout GraphicsContext) {
    let available = rect.width - 8
    guard available >= 10, rect.intersects(visibleRect) else { return }
    let drawingContext = context
    let measure: (String) -> CGFloat = { TimelineResolvedName.label($0, context: drawingContext).width }
    let metrics = TimelineNameMetrics.metrics(name, measure: measure)
    guard centered || rect.minX + 4 + min(available, metrics.fullWidth) >= visibleRect.minX,
          let displayed = metrics.fitting(name, width: available, measure: measure) else { return }
    var clipped = context
    clipped.clip(to: Path(roundedRect: rect, cornerRadius: 3))
    var label = TimelineResolvedName.label(displayed, context: context).text
    label.shading = .color(color)
    clipped.draw(label, at: centered ? CGPoint(x: rect.midX, y: rect.midY) : CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: centered ? .center : .topLeading)
}

private struct RegionBoundaryOverlay: View {
    let parts: [Part]
    let scale: Double
    let originX: CGFloat
    var body: some View {
        Canvas { context, size in
            let lanes = RegionLanes(parts: parts)
            for (index, part) in parts.enumerated() {
                guard part.parentRegionID == nil else { continue }
                let left = part.startTime * scale - originX, right = part.endTime * scale - originX
                guard right >= -6, left <= size.width + 6 else { continue }
                let top = CGFloat((lanes.lanes[part.id] ?? 0) + 1) * 16
                let color = Color(hex: part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965))
                var path = Path()
                for x in [left, right] where x >= -6 && x <= size.width + 6 {
                    path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                var layer = context
                layer.clip(to: Path(CGRect(x: left, y: top, width: right - left, height: max(0, size.height - top))))
                layer.stroke(path, with: .color(color.opacity(0.14)), lineWidth: 6)
                layer.stroke(path, with: .color(color.opacity(0.30)), lineWidth: 3)
                layer.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
    }
}

/// Cache normalized vector geometry, not a stretched bitmap. Names remain
/// separately measured/drawn and waveform gain/zoom only transform these paths.
private final class TimelineWaveformGeometry: NSObject {
    static let cache: NSCache<NSString, TimelineWaveformGeometry> = {
        let cache = NSCache<NSString, TimelineWaveformGeometry>()
        cache.totalCostLimit = 16 * 1024 * 1024; cache.countLimit = 2048
        return cache
    }()
    // Retaining the COW storage makes its address a stable identity. Replacing
    // or editing samples creates different storage, including recordings/undo.
    private let samples: [Double]
    let path: Path
    private init(samples: [Double], step: Int, chunk: Int) {
        self.samples = samples
        let first = chunk * 128 * step
        let last = min(samples.count, first + 128 * step)
        let intervals = CGFloat(max(1, samples.count - 1))
        var path = Path()
        for sample in stride(from: first, to: last, by: step) {
            let peak = samples[sample..<min(samples.count, sample + step)].max() ?? 0
            let x = CGFloat(sample) / intervals
            path.move(to: CGPoint(x: x, y: -peak)); path.addLine(to: CGPoint(x: x, y: peak))
        }
        self.path = path
    }
    static func geometry(_ samples: [Double], step: Int, chunk: Int) -> TimelineWaveformGeometry {
        let storage = samples.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
        let key = "\(storage):\(samples.count):\(step):\(chunk)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let value = TimelineWaveformGeometry(samples: samples, step: step, chunk: chunk)
        cache.setObject(value, forKey: key, cost: samples.count * 8 + 128 * 64)
        return value
    }
}
private func appendTimelineWaveform(_ samples: [Double], rect: CGRect, middle: CGFloat, amplitude: CGFloat, tile: CGRect, path: inout Path) {
    guard !samples.isEmpty, rect.width > 0 else { return }
    // Powers of two reuse the same peak-preserving detail level through many
    // small zoom changes. A block contains at most 128 vertical segments.
    let step = 1 << max(0, Int(floor(log2(max(1, CGFloat(samples.count) / max(1, rect.width))))))
    let intervals = CGFloat(max(1, samples.count - 1))
    let first = max(0, min(samples.count - 1, Int(floor((tile.minX - rect.minX) / rect.width * intervals))))
    let last = max(first, min(samples.count - 1, Int(ceil((tile.maxX - rect.minX) / rect.width * intervals))))
    let transform = CGAffineTransform(a: rect.width, b: 0, c: 0, d: amplitude, tx: rect.minX, ty: middle)
    for chunk in (first / (128 * step))...(last / (128 * step)) {
        path.addPath(TimelineWaveformGeometry.geometry(samples, step: step, chunk: chunk).path, transform: transform)
    }
}

private struct TimelineTileIdentity: Equatable {
    let renderKey: TimelineRenderKey
    let extent: Double
    let light: Bool
    var rowHeight: CGFloat = 0
    var rulerHeight: CGFloat = 0
    var selectedClips: Set<UUID> = []
    var gainPreview: ItemGainPreview.State? = nil
    var waveformRevision: UInt64 = 0
    var missingAudioPaths: Set<String> = []
    var mediaDirectory: URL? = nil
    var selectedTracks: Set<UUID> = []
    var gridStyle: [Int] = []
}
/// A bounded backing surface keeps its drawing while it remains in the viewport.
private struct TimelineCanvasSurface: View, Equatable {
    // Item pixels must commit with the new document scale and viewport origin;
    // independent asynchronous tiles can otherwise show different zoom frames.
    var synchronized = false
    var diagnosticName = "canvas"
    let identity: TimelineTileIdentity
    let size: CGSize
    let tile: CGRect
    let drawingRect: CGRect
    @State private var waveformOwner = TimelineAudioWaveform.PresentationStore()
    @Environment(\.displayScale) private var displayScale
    let draw: (inout GraphicsContext, CGSize, CGRect, TimelineAudioWaveform.PresentationStore) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.synchronized == rhs.synchronized && lhs.diagnosticName == rhs.diagnosticName && lhs.tile == rhs.tile && lhs.drawingRect == rhs.drawingRect && lhs.size == rhs.size && lhs.identity == rhs.identity
    }
    var body: some View {
        Canvas(rendersAsynchronously: !synchronized) { context, canvasSize in
            guard !drawingRect.isNull, !drawingRect.isEmpty else { return }
            let began = TimelineRenderDiagnostics.enabled ? ProcessInfo.processInfo.systemUptime : 0
            defer {
                if TimelineRenderDiagnostics.enabled {
                    TimelineRenderDiagnostics.record("canvas." + diagnosticName,
                        width: canvasSize.width, height: canvasSize.height, scale: displayScale,
                        milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                }
            }
            var translated = context
            translated.translateBy(x: -tile.minX, y: -tile.minY)
            translated.clip(to: Path(drawingRect))
            waveformOwner.beginFrame()
            defer { waveformOwner.endFrame() }
            draw(&translated, size, drawingRect, waveformOwner)
        }
    }
}

/// The native scroll position moves continuously, while vertical tile updates
/// arrive in 512-point buckets. Cover the whole unpublished interval plus one
/// band of lookahead; a one-band overscan alone leaves up to 255 points blank.
private enum TimelineCanvasCoverage {
    static let horizontalBucket: CGFloat = 512
    static let verticalBand: CGFloat = 256
    static let verticalPublishStep: CGFloat = 512
    static func preparedRect(visibleRect: CGRect, documentSize: CGSize) -> CGRect {
        let left = min(documentSize.width, max(0, floor(visibleRect.minX / horizontalBucket) * horizontalBucket - horizontalBucket))
        let top = min(documentSize.height, max(0, floor(visibleRect.minY / verticalBand) * verticalBand - verticalBand))
        let right = min(documentSize.width, ceil(visibleRect.maxX / horizontalBucket) * horizontalBucket + horizontalBucket)
        let bottom = min(documentSize.height, ceil(visibleRect.maxY / verticalBand) * verticalBand + verticalPublishStep + verticalBand)
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}

private struct ViewportTimelineCanvas: View {
    let visibleRect: CGRect
    var synchronized = false
    var documentWidth: CGFloat? = nil
    var batchesViewport = false
    var diagnosticName = "canvas"
    let identity: TimelineTileIdentity
    var tileIdentity: ((CGRect, CGSize) -> TimelineTileIdentity)? = nil
    let draw: (inout GraphicsContext, CGSize, CGRect, TimelineAudioWaveform.PresentationStore) -> Void
    // Stable vertical strips reuse the existing drawing during scrolling.
    // Horizontal surfaces remain wide to limit view count during timeline zoom.
    private let maximumSurface: CGFloat = 1536
    private let verticalSurface = TimelineCanvasCoverage.verticalBand
    var body: some View {
        GeometryReader { geometry in
            // Do not derive zoom independently from each hosting view's rounded
            // or intermediate width. Header, items and hit targets share this
            // exact logical width from the same zoom state.
            let size = CGSize(width: documentWidth ?? geometry.size.width, height: geometry.size.height)
            let prepared = TimelineCanvasCoverage.preparedRect(visibleRect: visibleRect, documentSize: size)
            let left = prepared.minX, top = prepared.minY, right = prepared.maxX, bottom = prepared.maxY
            let firstColumn = Int(floor(left / maximumSurface))
            let lastColumn = max(firstColumn + 1, Int(ceil(right / maximumSurface)))
            let firstRow = Int(floor(top / verticalSurface))
            let lastRow = max(firstRow + 1, Int(ceil(bottom / verticalSurface)))
            ZStack(alignment: .topLeading) {
                if batchesViewport || tileIdentity == nil {
                    // Background, ruler and marker layers contain no per-tile
                    // waveform cache. Draw their bounded viewport once instead
                    // of maintaining and laying out many identical Canvas hosts.
                    TimelineCanvasSurface(synchronized: synchronized, diagnosticName: diagnosticName, identity: identity, size: size,
                        tile: prepared, drawingRect: prepared, draw: draw).equatable()
                        .frame(width: prepared.width, height: prepared.height)
                        .clipped().offset(x: prepared.minX, y: prepared.minY)
                } else {
                ForEach(firstRow..<lastRow, id: \.self) { row in
                    ForEach(firstColumn..<lastColumn, id: \.self) { column in
                        // A tile keeps its document origin when the viewport
                        // crosses a bucket; cached pixels never slide elsewhere.
                        let x = CGFloat(column) * maximumSurface
                        let y = CGFloat(row) * verticalSurface
                        let tile = CGRect(x: x, y: y,
                                          width: max(0, min(maximumSurface, size.width - x)),
                                          height: max(0, min(verticalSurface, size.height - y)))
                        // Prepare the whole mounted surface. Changing its clipped source
                        // interval at each 512-point scroll bucket invalidates an
                        // already visible waveform and starts another async request.
                        let drawingRect = tile
                        TimelineCanvasSurface(synchronized: synchronized, diagnosticName: diagnosticName, identity: tileIdentity?(drawingRect, size) ?? identity, size: size, tile: tile, drawingRect: drawingRect, draw: draw).equatable()
                            .frame(width: tile.width, height: tile.height)
                            .clipped().offset(x: tile.minX, y: tile.minY)
                    }
                }
                }
            }
        }.allowsHitTesting(false)
    }
}

/// Search sorted item boundaries without scanning every item on each pointer event.
private func nearestRegionItemEdge(_ time: Double, points: [Double], tolerance: Double) -> Double? {
    var low = 0
    var high = points.count
    while low < high {
        let middle = (low + high) / 2
        if points[middle] < time { low = middle + 1 } else { high = middle }
    }
    var nearest: Double?
    if low < points.count { nearest = points[low] }
    if low > 0, nearest == nil || abs(points[low - 1] - time) <= abs(nearest! - time) {
        nearest = points[low - 1]
    }
    guard let nearest, abs(nearest - time) <= tolerance else { return nil }
    return nearest
}

#if os(macOS)
private struct ClipDragInput: NSViewRepresentable {
    let originY: CGFloat
    let select: (Bool) -> Void
    let update: (CGSize, CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> ClipDragView { ClipDragView() }
    func updateNSView(_ view: ClipDragView, context: Context) {
        view.originY = originY
        view.select = select
        view.updateDrag = update
    }
}
private final class ClipDragView: NSView {
    override var isFlipped: Bool { true }
    var originY: CGFloat = 0
    var select: ((Bool) -> Void)?
    var updateDrag: ((CGSize, CGFloat, Bool) -> Void)?
    private var startPoint: NSPoint?
    private var startTimelineY: CGFloat = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let additive = !event.modifierFlags.intersection([.command, .control]).isEmpty
        select?(additive)
        // Modified clicks toggle one item without starting a move gesture.
        if additive { startPoint = nil; return }
        startPoint = event.locationInWindow
        startTimelineY = originY + convert(event.locationInWindow, from: nil).y
        updateDrag?(.zero, startTimelineY, false)
    }
    override func mouseDragged(with event: NSEvent) { deliver(event, ended: false) }
    override func mouseUp(with event: NSEvent) { deliver(event, ended: true) }
    private func deliver(_ event: NSEvent, ended: Bool) {
        guard let startPoint else { return }
        let delta = CGSize(width: event.locationInWindow.x - startPoint.x,
                           height: startPoint.y - event.locationInWindow.y)
        // Window coordinates stay stable when preview lanes change size.
        // AppKit keeps sending this mouse sequence to the original view.
        if ended { self.startPoint = nil }
        updateDrag?(delta, startTimelineY + delta.height, ended)
    }
}
#else
private struct ClipDragInput: View {
    @GestureState private var touching = false
    @State private var active: TimelineItemTouchGesture?
    @State private var liveFadeIn: Double?
    @State private var liveFadeOut: Double?
    let item: GridSelectionItem
    let originY: CGFloat
    var click: (CGPoint) -> Void = { _ in }
    let select: (Bool) -> Void
    let resize: (Bool, CGFloat, Bool) -> Void
    let fade: (Bool, Double, Bool) -> Void
    var mute: (() -> Void)? = nil
    var cancel: () -> Void = {}
    let update: (CGSize, CGFloat, Bool) -> Void
    private var localItem: GridSelectionItem {
        var result = item
        result.rect.origin = CGPoint(x: 1, y: 0)
        result.fadeIn = liveFadeIn ?? item.fadeIn; result.fadeOut = liveFadeOut ?? item.fadeOut
        return result
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).gesture(input())
            if let mute, let rect = localItem.muteRect {
                Button(action: mute) {
                    Text("M").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: rect.width, height: rect.height)
                        .background(item.muted ? Color.red : Color.black.opacity(0.28)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Mute item")
                    .offset(x: rect.minX, y: rect.minY)
            }
            if item.editable, item.duration > 0 {
                if localItem.fadeIn > 0 || localItem.fadeOut > 0 { TimelineTouchFadeCurves(item: localItem) }
                ForEach([true, false], id: \.self) { left in
                    if let handle = localItem.fadeHandleRect(left) {
                        Path { path in
                            path.move(to: CGPoint(x: left ? 0 : 7, y: 0))
                            path.addLine(to: CGPoint(x: left ? 7 : 0, y: 0))
                            path.addLine(to: CGPoint(x: left ? 0 : 7, y: 7)); path.closeSubpath()
                        }.fill(.white.opacity(0.95)).frame(width: 7, height: 7)
                            .contentShape(Rectangle()).gesture(input(fadeSide: left))
                            .accessibilityLabel(left ? "Fade in" : "Fade out")
                            .offset(x: handle.minX, y: handle.minY)
                    }
                }
            }
        }.onChange(of: touching) { if !$0 { cancelActive() } }
            .onDisappear { cancelActive() }
    }
    private func input(fadeSide: Bool? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if active == nil {
                    active = TimelineItemTouchGesture(item: item, start: value.startLocation, fadeSide: fadeSide)
                    if case .fade = active!.action {} else { select(false) }
                }
                active?.advance(value.translation)
                if let active, active.hasDragged { deliver(active, translation: value.translation, pointerY: value.location.y, ended: false) }
            }
            .onEnded { value in
                guard var gesture = active else { return }
                gesture.advance(value.translation)
                active = nil
                if gesture.hasDragged { deliver(gesture, translation: value.translation, pointerY: value.location.y, ended: true) }
                else if gesture.shouldSeek { click(gesture.start) }
                liveFadeIn = nil; liveFadeOut = nil
            }
    }
    private func cancelActive() {
        guard let gesture = active else { return }
        active = nil; liveFadeIn = nil; liveFadeOut = nil
        if case let .fade(left) = gesture.action, gesture.hasDragged {
            fade(left, left ? gesture.item.fadeIn : gesture.item.fadeOut, false)
        }
        cancel()
    }
    private func deliver(_ gesture: TimelineItemTouchGesture, translation: CGSize, pointerY: CGFloat, ended: Bool) {
        switch gesture.action {
        case .move: if gesture.item.movable { update(translation, pointerY, ended) }
        case let .resize(left): resize(left, translation.width, ended)
        case let .fade(left):
            let value = gesture.fadeValue(translation: translation) ?? 0
            if left { liveFadeIn = value } else { liveFadeOut = value }
            fade(left, value, ended)
        }
    }
}
#endif

private struct SubCursorBlink: ViewModifier {
    func body(content: Content) -> some View { content.modifier(JarasBlink(active: true, interval: 0.45, lowOpacity: 0.3)) }
}

struct TimelineRenderKey: Equatable, Hashable {
    let revision: UInt64
    let songID: UUID?
    let movingClip: UUID?
    let movingStart: Double
    let movingTrack: UUID?
    let movingRegion: UUID?
    let regionDelta: Double
    let resizingRegion: UUID?
    let resizedStart: Double
    let resizedEnd: Double
    var recordingRevision: UInt64 = 0
    var resizingItem: UUID? = nil
    var itemStart = 0.0, itemEnd = 0.0
}
/// Controls do not need sample arrays, so SwiftUI never diffs them for each fader.
private func mixerMetadata(_ source: Track) -> Track {
    var track = source
    track.clips = []
    return track
}

#if os(macOS)
/// Local preview state invalidates only marker flags and their lines.
/// Grid, waveform tiles and audio are updated once, when the drag is released.
private struct TimelineDraggableMarkerLayer: View {
    let song: Song
    let scale: Double
    let renderKey: TimelineRenderKey
    let extent: Double
    let viewport: CGRect
    let edit: (TimelineMarker) -> Void
    let delete: (UUID) -> Void
    let seek: (TimelineMarker) -> Void
    let move: (TimelineMarker) -> Void
    var tempoOnly = true
    @State private var preview: TimelineMarker?
    var body: some View {
        let markers = (song.markers ?? []).filter { $0.isTempo == tempoOnly }.map { marker in
            preview?.id == marker.id ? preview! : marker
        }
        var displayedSong = song
        displayedSong.markers = markers
        let ends = tempoOnly ? [:] : displayedSong.markerRegionEnds
        var key = renderKey
        key.resizingItem = preview?.id
        key.itemStart = preview?.position ?? 0
        return ZStack(alignment: .topLeading) {
            ViewportTimelineCanvas(visibleRect: viewport, synchronized: true, documentWidth: extent * scale, diagnosticName: "marker-lines", identity: TimelineTileIdentity(renderKey: key, extent: extent, light: false)) { context, size, tile, waveformOwner in
                let widths = Dictionary(uniqueKeysWithValues: markers.map { marker in
                    (marker.id, Double(ceil(TimelineResolvedName.label(song.markerLabel(marker), context: context).width)))
                })
                let displays = TimelineMarker.flagWidths(markers, scale: scale, widths: widths, regionEnds: ends)
                let visible = tile
                for marker in markers {
                    let x = marker.position * scale
                    if x >= tile.minX - 1, x <= tile.maxX + 1 {
                        var line = Path(); line.move(to: CGPoint(x: x, y: markerLaneHeight)); line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: .color(Color(hex: tempoOnly ? 0x999999 : marker.color).opacity(marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)), style: StrokeStyle(lineWidth: 1, dash: tempoOnly ? [2, 3] : []))
                    }
                    let headWidth = displays[marker.id] ?? 0
                    let rect = CGRect(x: x,
                                      y: 1, width: headWidth, height: markerLaneHeight - 2)
                    guard rect.intersects(visible) else { continue }
                    if tempoOnly {
                        let display = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
                        context.fill(display, with: .color(JarasTheme.display))
                        context.stroke(display, with: .color(JarasTheme.line), lineWidth: 1)
                    } else { drawMarkerFlag(marker, rect: rect, context: &context) }
                    drawTimelineName(song.markerLabel(marker), in: rect, color: tempoOnly ? JarasTheme.text : .black, visibleRect: visible, centered: tempoOnly, context: &context)
                }
            }.allowsHitTesting(false)
            MarkerEditTargets(song: displayedSong, markers: markers, scale: scale, viewport: viewport, facesLeft: false,
                edit: edit, delete: delete, seek: seek, draggingID: preview?.id, drag: { marker, delta, ended in
                    guard song.canDragMarker(marker) else { return }
                    var moved = marker
                    let position = max(0, marker.position + Double(delta) / scale)
                    moved.position = song.markerDragPosition(marker, to: position, pixelsPerSecond: scale, free: NSEvent.modifierFlags.contains(.shift))
                    if ended { move(moved); preview = nil }
                    else { preview = moved }
                })
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: markerLaneHeight)
        }.onChange(of: song.id) { _ in preview = nil }
    }
}

/// Hit targets use one fixed font, so zoom and scrolling do not change these
/// metrics. Bound the shared cache; edited labels naturally receive a new key.
private final class MarkerTargetLabelWidths {
    static let shared = MarkerTargetLabelWidths()
    private let cache = NSCache<NSString, NSNumber>()
    private let measure: (String) -> Double
    init(measure: @escaping (String) -> Double = { label in
        Double((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).width)
    }) {
        self.measure = measure
        cache.countLimit = 4096
        cache.totalCostLimit = 1024 * 1024
    }
    func width(_ label: String) -> Double {
        let key = label as NSString
        if let value = cache.object(forKey: key) { return value.doubleValue }
        let value = measure(label)
        cache.setObject(NSNumber(value: value), forKey: key, cost: label.utf8.count * 2 + 64)
        return value
    }
}

private struct MarkerTargetGeometry: Identifiable {
    let marker: TimelineMarker
    let left: Double
    let width: Double
    var id: UUID { marker.id }

    static func visible(_ markers: [TimelineMarker], scale: Double, viewport: CGRect,
                        facesLeft: Bool, regionEnds: [UUID: Double], draggingID: UUID?,
                        labels: MarkerTargetLabelWidths = .shared,
                        label: (TimelineMarker) -> String) -> [Self] {
        let ordered = markers.enumerated().sorted {
            $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position
        }
        var candidates = Set<UUID>()
        var needsMeasurement = Set<UUID>()
        for (index, entry) in ordered.enumerated() {
            let marker = entry.element, x = marker.position * scale
            let potentiallyVisible: Bool
            if !facesLeft || marker.position == 0 {
                let nextX = index + 1 < ordered.count ? ordered[index + 1].element.position * scale : .infinity
                let regionEnd = facesLeft ? Double.infinity : (regionEnds[marker.id] ?? .infinity) * scale
                // A right-facing flag cannot cross the next marker or region
                // end. Keep the eight-point minimum target even for short flags.
                let rightLimit = max(x + 8, min(nextX - 3, regionEnd))
                potentiallyVisible = x <= viewport.maxX && rightLimit >= viewport.minX
            } else {
                // Left-facing flags cannot cross the previous marker. At zero
                // its right-facing width contributes to the next marker's gap;
                // zero is a conservative lower bound until that label is read.
                let previousX = index > 0 ? ordered[index - 1].element.position * scale : 0
                let leftLimit = max(0, min(x - 8, previousX + 3))
                potentiallyVisible = max(8, x) >= viewport.minX && leftLimit <= viewport.maxX
            }
            guard potentiallyVisible || marker.id == draggingID else { continue }
            candidates.insert(marker.id)
            needsMeasurement.insert(marker.id)
            if facesLeft, index > 0, marker.position > 0, ordered[index - 1].element.position == 0 {
                needsMeasurement.insert(ordered[index - 1].element.id)
            }
        }
        let measured = Dictionary(uniqueKeysWithValues: markers.filter { needsMeasurement.contains($0.id) }.map {
            ($0.id, labels.width(label($0)))
        })
        // Retain all neighbours when constraining widths; culling them first
        // would grow flags near a viewport edge or change tied-marker ordering.
        let widths = TimelineMarker.flagWidths(markers, scale: scale, widths: measured,
            regionEnds: regionEnds, facesLeft: facesLeft)
        return markers.compactMap { marker in
            guard candidates.contains(marker.id) else { return nil }
            let x = marker.position * scale, width = max(8, widths[marker.id] ?? 0)
            let left = facesLeft && marker.position > 0 ? max(0, x - width) : x
            guard marker.id == draggingID || left + width >= viewport.minX && left <= viewport.maxX else { return nil }
            return Self(marker: marker, left: left, width: width)
        }
    }
}

private struct MarkerEditTargets: View {
    let song: Song
    let markers: [TimelineMarker]
    let scale: Double
    let viewport: CGRect
    let facesLeft: Bool
    let edit: (TimelineMarker) -> Void
    let delete: (UUID) -> Void
    let seek: (TimelineMarker) -> Void
    var draggingID: UUID? = nil
    var drag: ((TimelineMarker, CGFloat, Bool) -> Void)? = nil
    var body: some View {
        let targets = MarkerTargetGeometry.visible(markers, scale: scale, viewport: viewport, facesLeft: facesLeft,
            regionEnds: markers.first?.isTempo == true ? [:] : song.markerRegionEnds,
            draggingID: draggingID, label: song.markerLabel)
        ZStack(alignment: .topLeading) {
            ForEach(targets) { target in
                let marker = target.marker
                MarkerEditAnchor(edit: { edit(marker) }, delete: {
                    if marker.unifiedRegionID == nil, marker.sourceRegionID == nil { delete(marker.id) }
                }, seek: { seek(marker) }, drag: song.canDragMarker(marker) ? drag.map { action in { delta, ended in action(marker, delta, ended) } } : nil)
                    .frame(width: target.width, height: markerLaneHeight)
                    .offset(x: target.left)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif

func drawMarkerFlag(_ marker: TimelineMarker, rect: CGRect, context: inout GraphicsContext) {
    if marker.isSection {
        var shape = Path()
        shape.move(to: CGPoint(x: rect.minX, y: rect.midY))
        shape.addLine(to: CGPoint(x: rect.minX + min(7, rect.width / 2), y: rect.minY))
        shape.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        shape.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        shape.addLine(to: CGPoint(x: rect.minX + min(7, rect.width / 2), y: rect.maxY))
        shape.closeSubpath()
        context.fill(shape, with: .color(Color(hex: marker.color)))
    } else if marker.sourceRegionID != nil || marker.unifiedRegionID != nil {
        let shape = Path(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 3)
        context.fill(shape, with: .color(Color(hex: marker.color)))
        context.stroke(shape, with: .color(JarasTheme.yellow), lineWidth: 1.2)
    } else { context.fill(Path(rect), with: .color(Color(hex: marker.color))) }
}

private struct ItemTunerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var show: ShowController
    let items: Set<UUID>
    private var clips: [AudioClip] {
        (show.current?.tracks ?? []).filter { $0.kind == .standard }.flatMap(\.clips)
            .filter { items.contains($0.id) && $0.midi == nil }
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(verbatim: "Tuner").font(.title3.bold())
                Spacer()
                Text(verbatim: "±12 st").font(.caption).foregroundStyle(JarasTheme.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(clips) { clip in
                        let pitch = clip.pitchSemitones ?? 0
                        HStack(spacing: 8) {
                            Text(verbatim: clip.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { show.setItemPitch(clip.id, semitones: max(-12, pitch - 1)) } label: {
                                Image(systemName: "minus").frame(width: 28, height: 28)
                            }.disabled(pitch <= -12).accessibilityLabel("Lower pitch")
                            Text(verbatim: String(format: "%+.2g st", pitch)).monospacedDigit()
                                .foregroundStyle(JarasTheme.green).frame(width: 48)
                            Button { show.setItemPitch(clip.id, semitones: min(12, pitch + 1)) } label: {
                                Image(systemName: "plus").frame(width: 28, height: 28)
                            }.disabled(pitch >= 12).accessibilityLabel("Raise pitch")
                        }.padding(10).background(JarasTheme.display).cornerRadius(7)
                    }
                }
            }.frame(height: min(300, CGFloat(max(1, clips.count)) * 58))
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 440).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}
