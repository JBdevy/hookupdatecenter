import SwiftUI
import UniformTypeIdentifiers
import Combine
import CoreText
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
    let show: ShowController
    @StateObject private var updates: ShowTimelinePresentationObserver
    let documents: ProjectDocuments
    var remotePresentation = false
    var toggleMixer: () -> Void = {}
    init(show: ShowController, documents: ProjectDocuments, remotePresentation: Bool = false, toggleMixer: @escaping () -> Void = {}) {
        self.show = show; self.documents = documents
        self.remotePresentation = remotePresentation; self.toggleMixer = toggleMixer
        _updates = StateObject(wrappedValue: ShowTimelinePresentationObserver(show: show))
    }
    var body: some View {
        TimelineGridContent(show: show, documents: documents, presentation: updates.state, revision: show.projectRevision, mixerRevision: show.mixerPlaybackRevision, songID: show.current?.id, focusRequest: show.regionFocusRequest, selectedRegion: show.selectedTimelineRegion, editPosition: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, remotePresentation: remotePresentation, toggleMixer: toggleMixer).equatable()
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
    let presentation: ShowTimelinePresentationState
    let revision: UInt64
    let mixerRevision: UInt64
    let songID: UUID?
    let focusRequest: UUID
    let selectedRegion: UUID?
    let editPosition: Double
    let toggleMixer: () -> Void
    let remotePresentation: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.remotePresentation == rhs.remotePresentation && lhs.show === rhs.show && lhs.presentation == rhs.presentation
    }
    @ObservedObject private var recordingLayout = RecordingLaneLayout.shared
    @Environment(\.locale) private var locale
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @State private var zoomState = TimelineZoomState()
    @State private var hostedItemsGate = TimelineHostedItemsGate()
    @State private var rowLayoutCache = TrackLayoutCache()
    @State private var renderMetadataCache = TimelineRenderMetadataCache()
    #if os(macOS)
    @State private var selectionLayoutCache = TimelineSelectionLayoutCache()
    @State private var nativeBase = NativeTimelineBaseController()
    @ObservedObject private var metalRenderer = MetalWaveformRenderer.shared
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
    @State private var regionExport: RegionAudioExportRequest?
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
    @State private var trackHeightPreview: [UUID: Double] = [:]
    #if os(macOS)
    #endif
    init(show: ShowController, documents: ProjectDocuments, presentation: ShowTimelinePresentationState, revision: UInt64, mixerRevision: UInt64, songID: UUID?, focusRequest: UUID, selectedRegion: UUID?, editPosition: Double, remotePresentation: Bool, toggleMixer: @escaping () -> Void) {
        self.presentation = presentation
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
                    let projectID = show.snapshot.project.id
                    let renderKey = TimelineRenderKey(revision: revision, songID: songID, movingClip: movingClip, movingStart: movingStart, movingTrack: movingTrack, movingRegion: movingRegion, regionDelta: regionDelta, resizingRegion: resizingRegion, resizedStart: resizedStart, resizedEnd: resizedEnd, recordingRevision: recordingLayout.revision, resizingItem: resizingItem, itemStart: resizedItemStart, itemEnd: resizedItemEnd, projectID: projectID)
                    let song = previewTrackHeights(previewItemEdit(previewClipMove(previewRegionResize(previewRegionMove(originalSong)))))
                    let renderMetadata = renderMetadataCache.metadata(song: song, key: renderKey)
                    let regionLanes = rowLayoutCache.regionLanes(song.parts, key: renderKey)
                    let rulerHeight = CGFloat(regionLanes.count) * 16 + markerLaneHeight + tempoLaneHeight + barLaneHeight
                    let maximumLabelWidth = max(161, min(486.5, geometry.size.width - 260))
                    let groupDepths = song.trackGroupDepths
                    let rows = rowLayoutCache.layout(song.tracks, height: trackHeight, key: renderKey)
                    let row = rows.baseHeight
                    let contentHeight = max(geometry.size.height, rulerHeight + rows.totalHeight + row * 2)
                    SidebarResizeLayer(state: mixerResizeState) { liveLabelWidth in
                    let requestedLabelWidth = liveLabelWidth ?? CGFloat(savedLabelWidth)
                    let labelWidth = requestedLabelWidth <= 0 ? 0 : min(maximumLabelWidth, max(SidebarWidthLimits.trackMixer, requestedLabelWidth))
                    let mountedLabelWidth = labelWidth > 0 ? labelWidth : min(maximumLabelWidth, max(SidebarWidthLimits.trackMixer, CGFloat(restoreLabelWidth)))
                    let resizeViewport = mixerResizeState.limitsWidthToVisibleRows
                        ? CGRect(x: 0, y: verticalScroll.offset, width: 0, height: geometry.size.height) : nil
                    let extent = max(timelineExtent, song.duration + 120, max(0, geometry.size.width - labelWidth - dividerWidth) / (10 * TimelineZoomLimits.minimum) + 120)
                    #if os(macOS)
                    let nativeAudioBody = NativeTimelineAudioBodyConfiguration.make(song: song, rows: rows,
                        metadata: renderMetadata, rulerHeight: rulerHeight, selectedClips: selectedClips,
                        mediaDirectory: documents.currentURL?.deletingLastPathComponent(),
                        missingAudioPaths: documents.missingAudioPaths,
                        identity: [renderKey.hashValue, focusRequest.hashValue, selectedClips.hashValue,
                            geometry.size.width.hashValue, geometry.size.height.hashValue, labelWidth.hashValue].hashValue)
                    let hostedItems = renderMetadata.hasItems && (nativeAudioBody?.hasFallbackItems ?? true)
                    let hostedItemCoverage = nativeAudioBody.map { TimelineHostedItemCoverage(items: $0.fallbackItems, identity: $0.fallbackIdentity) }
                    let nativeAudioItems = nativeAudioBody?.itemIDs ?? []
                    let hostedMetalRequired = nativeAudioBody?.hasFallbackWaveforms ?? true
                    #else
                    let hostedItems = renderMetadata.hasItems
                    let nativeAudioItems: Set<UUID> = []
                    let hostedMetalRequired = true
                    let hostedItemCoverage: TimelineHostedItemCoverage? = nil
                    #endif
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
                                    changeTrackHeight(factor, smoothWheel: smoothWheel, rows: rows)
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
                    let selectionInput = makeSelectionInput(originalSong: originalSong, song: song, rows: rows,
                        rulerHeight: rulerHeight, extent: extent, selectionLayout: selectionLayout)
                    #endif
                    // The scroll host is structural. Only its inner rendering
                    // scope observes scale; native document extent is committed
                    // by GridDocumentSizeInput after that scope updates.
                    let documentViewportWidth = max(0, geometry.size.width - labelWidth - dividerWidth)
                    let initialDocumentWidth = extent * 10 * zoomState.value
                    #if os(macOS)
                    let hostedHeaderRequired = editingRegion != nil || unifyingRegion != nil
                    #else
                    let hostedHeaderRequired = !song.parts.isEmpty || !(song.markers ?? []).isEmpty
                    #endif
                    // Lightweight native headers follow actual scroll bounds;
                    // retain metadata so scrolling can reveal items without a
                    // SwiftUI rebuild of the waveform document.
                    let importDrop: ([NSItemProvider], CGPoint) -> Bool = { providers, location in
                        guard location.y >= verticalScroll.offset + rulerHeight else { return false }
                        let pixelsPerSecond = 10 * zoomState.value
                        let y = location.y - rulerHeight
                        let index = rows.offsets.indices.first { y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0] }
                        let track = index.map { originalSong.tracks[$0].id }
                        let start = itemPosition(location.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                        return documents.importAudio(providers, start: start, track: track, song: originalSong.id)
                    }
                                GridScrollView(axis: .horizontal, contentWidth: initialDocumentWidth, contentHeight: contentHeight, fileDrop: { urls, point in
                                    importDrop(urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }, point)
                                }, fileDropPreview: { urls, point in
                                    let pixelsPerSecond = 10 * zoomState.value
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
                                TimelineCoordinatePlaneLayer(state: zoomState, extent: extent) { layoutWidth in
                                    ZStack(alignment: .topLeading) {
                                        TimelineItemsScaleLayer(state: zoomState, extent: extent, hasItems: hostedItems,
                                            gate: hostedItemsGate, coverage: hostedItemCoverage) { _, width, pixelsPerSecond in
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            let viewportWidth: CGFloat = max(0, geometry.size.width - labelWidth - dividerWidth)
                                            let viewport = CGRect(x: horizontalOffset, y: visibleY, width: viewportWidth, height: geometry.size.height)
                                            makeTimelineDrawing(viewport: viewport, song: song, rows: rows, renderKey: renderKey,
                                                rulerHeight: rulerHeight, extent: extent, documentWidth: width, metadata: renderMetadata,
                                                nativeAudioItems: nativeAudioItems, hostedMetalRequired: hostedMetalRequired).equatable()
                                        }
                                        }.frame(width: layoutWidth, height: contentHeight)
                                        TimelineGainScaleLayer(state: zoomState, extent: extent, preview: itemGainPreview) { _, width, pixelsPerSecond in
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            ItemGainPreviewOverlay(preview: itemGainPreview, visibleRect: CGRect(x: horizontalOffset, y: visibleY, width: geometry.size.width, height: geometry.size.height), song: song, rows: rows, renderKey: renderKey, rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips, mediaDirectory: documents.currentURL?.deletingLastPathComponent(), documentWidth: width, renderMetadata: renderMetadata)
                                        }
                                        }.frame(width: layoutWidth, height: contentHeight).allowsHitTesting(false)
                                        TimelineRecordingScaleLayer(state: zoomState, extent: extent) { _, width, pixelsPerSecond in
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            RecordingGridOverlay(visibleRect: CGRect(x: horizontalOffset,y: visibleY,width: geometry.size.width,height: geometry.size.height),tracks: song.tracks, offsets: rows.offsets, heights: rows.heights, rulerHeight: rulerHeight, scale: pixelsPerSecond)
                                        }
                                        }.frame(width: layoutWidth,height: contentHeight,alignment: .topLeading)
                                        #if !os(macOS)
                                        TimelineScaleLayer(state: zoomState, extent: extent) { _, width, pixelsPerSecond in
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
                                            }.frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                        }.frame(width: layoutWidth, height: contentHeight)
                                        }
                                        #endif
                                        TimelinePinnedLayer(position: verticalScroll.pinned, width: layoutWidth, height: contentHeight) { verticalOffset in
                                        ZStack(alignment: .topLeading) {
                                        #if os(macOS)
                                        NativeTimelineBaseSlot(controller: nativeBase, kind: .ruler)
                                            .frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                        #endif
                                        TimelineHeaderScaleLayer(state: zoomState, extent: extent, song: song.id,
                                            hasContent: hostedHeaderRequired, preview: insertionPreview) { _, width, pixelsPerSecond in
                                        TimelineScrollLayer(position: horizontalScroll) { horizontalOffset in
                                            ZStack(alignment: .topLeading) {
                                        let headerViewport = TimelineHeaderViewport.covering(offset: horizontalOffset, width: geometry.size.width, height: geometry.size.height)
                                        TimelineStaticHeaderLayer(identity: TimelineStaticHeaderIdentity(controller: ObjectIdentifier(show), project: show.snapshot.project.id, renderKey: renderKey,
                                            documentSize: CGSize(width: width, height: contentHeight), viewport: headerViewport, rulerHeight: rulerHeight, extent: extent,
                                            verticalOffset: verticalOffset, editingRegion: editingRegion, unifyingRegion: unifyingRegion, selectedRegion: selectedRegion, locale: locale)) {
                                            let visibleStart = max(0, headerViewport.minX - 1024) / pixelsPerSecond
                                            let visibleEnd = (headerViewport.maxX + 1536) / pixelsPerSecond
                                            ZStack(alignment: .topLeading) {
                                        #if !os(macOS)
                                        TimelineHeader(visibleRect: CGRect(x: headerViewport.minX, y: 0, width: headerViewport.width, height: rulerHeight), song: song, renderKey: renderKey, extent: extent, documentWidth: width, cachedLanes: regionLanes, cachedParentIDs: renderMetadata.regionParentIDs, cachedTempoSections: renderMetadata.sections(until: extent)).equatable()
                                            .frame(width: layoutWidth, height: rulerHeight).offset(y: verticalOffset)
                                        TimelineMarkerLane(visibleRect: CGRect(x: headerViewport.minX, y: 0, width: headerViewport.width, height: markerLaneHeight), song: song, renderKey: renderKey, extent: extent, documentWidth: width)
                                            .frame(width: layoutWidth, height: markerLaneHeight).clipped()
                                            .offset(y: verticalOffset + CGFloat(regionLanes.count) * 16)
                                        #endif
                                        #if os(macOS)
                                        ForEach(Array(song.parts.enumerated()).filter { $0.element.parentRegionID == nil && ($0.element.id == editingRegion || $0.element.id == unifyingRegion) }, id: \.element.id) { index, part in
                                            let edgePadding: CGFloat = renderMetadata.regionParentIDs.contains(part.id) ? 0 : 10
                                            Color.clear
                                                .frame(width: max(1, (part.endTime - part.startTime) * pixelsPerSecond) + edgePadding * 2, height: edgePadding > 0 ? 24 : 16)
                                                .background { regionEditorAnchors(part, index: index) }
                                                .alignmentGuide(.leading) { _ in 0 }
                                                .alignmentGuide(.top) { _ in 0 }
                                                .offset(x: part.startTime * pixelsPerSecond - edgePadding, y: verticalOffset + CGFloat(regionLanes.lanes[part.id] ?? 0) * 16 - (edgePadding > 0 ? 4 : 0))
                                        }
                                        #else
                                        ForEach(Array(song.parts.enumerated()).filter { $0.element.parentRegionID == nil && ($0.element.id == editingRegion || $0.element.id == unifyingRegion || $0.element.id == movingRegion || $0.element.id == resizingRegion || ($0.element.startTime <= visibleEnd && $0.element.endTime >= visibleStart)) }, id: \.element.id) { index, part in
                                            let edgePadding: CGFloat = renderMetadata.regionParentIDs.contains(part.id) ? 0 : 10
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
                                                .alignmentGuide(.leading) { _ in 0 }
                                                .alignmentGuide(.top) { _ in 0 }
                                                .offset(x: part.startTime * pixelsPerSecond - edgePadding, y: verticalOffset + CGFloat(regionLanes.lanes[part.id] ?? 0) * 16 - (edgePadding > 0 ? 4 : 0))
                                        }
                                        #endif
                                        #if !os(macOS)
                                        Color.clear.frame(width: layoutWidth, height: barLaneHeight).contentShape(Rectangle()).offset(y: rulerHeight - barLaneHeight + verticalOffset)
                                            .gesture(SpatialTapGesture().onEnded { value in
                                                show.send(.editSeek, value: gridPosition(min(1, max(0, value.location.x / width)) * extent, song: song, pixelsPerSecond: pixelsPerSecond))
                                            })
                                        #endif
                                            }.frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                        }.equatable()
                                        // This fixed coordinate plane has its own origin; parent alignment
                                        // does not depend on the independently positioned header descendants.
                                        .alignmentGuide(.leading) { _ in 0 }
                                        .alignmentGuide(.top) { _ in 0 }
                                        TimelineAreaOverlay(song: song.id, scale: pixelsPerSecond, height: geometry.size.height, rulerHeight: rulerHeight)
                                            .offset(y: verticalOffset)
                                        GridExternalFilePreviewOverlay(preview: insertionPreview, scale: pixelsPerSecond,
                                            viewport: CGRect(x: horizontalOffset, y: verticalOffset,
                                                width: max(1, geometry.size.width - labelWidth - dividerWidth), height: geometry.size.height), rulerHeight: rulerHeight)
                                        GridInsertionPreviewOverlay(preview: insertionPreview, scale: pixelsPerSecond, rulerHeight: rulerHeight, viewportHeight: geometry.size.height)
                                            .offset(y: verticalOffset).allowsHitTesting(false)
                                        #if !os(macOS)
                                        RegionBoundaryOverlay(parts: song.parts, scale: pixelsPerSecond, originX: max(0, horizontalOffset - 512), lanes: regionLanes)
                                            .frame(width: geometry.size.width + 1024, height: geometry.size.height)
                                            .offset(x: max(0, horizontalOffset - 512), y: verticalOffset)
                                            .allowsHitTesting(false)
                                        // Draw needles last so coincident region/marker lines cannot cover them.
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
                                            }.frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                        }
                                        #endif
                                            }.frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                        }
                                        }.frame(width: layoutWidth, height: contentHeight)
                                        }
                                        }

                                    }
                                    #if os(macOS)
                                    .overlay(alignment: .topLeading) {
                                        NativeTimelineBaseSlot(controller: nativeBase, kind: .foreground)
                                            .frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                    }
                                    .background {
                                        NativeTimelineBaseBackground(controller: nativeBase, state: zoomState,
                                            configuration: makeNativeBaseConfiguration(song: song, originalSong: originalSong,
                                                rows: rows, metadata: renderMetadata, selectionInput: selectionInput,
                                                extent: extent, rulerHeight: rulerHeight, regionLanes: regionLanes,
                                                contentHeight: contentHeight, layoutWidth: layoutWidth,
                                                viewportSize: CGSize(width: documentViewportWidth, height: geometry.size.height),
                                                audioBody: nativeAudioBody))
                                            .frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                    }
                                    #endif
                                    #if !os(macOS)
                                    .coordinateSpace(name: "timeline")
                                    #endif
                                    .frame(width: layoutWidth, height: contentHeight, alignment: .topLeading)
                                    .contentShape(Rectangle())
                                    #if !os(macOS)
                                    .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: importDrop)
                                    #endif
                                }
                                }.frame(width: documentViewportWidth, height: contentHeight)
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
                                // Match the smaller GPU preparation reserve. A jump outside
                                // it must lay out the destination before revealing its pixels.
                                let leading = MetalWaveformRenderer.isSupported ? TimelineWaveformCoverage.guardBand : 256
                                let trailing = MetalWaveformRenderer.isSupported ? TimelineWaveformCoverage.trailingReserve : 768
                                return offset < previous - leading || offset > previous + trailing || restoreWidths
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
                            #if os(macOS)
                            TimelineTrackHeightResizeInput(project: projectID, song: song.id,
                                tracks: song.tracks.map(\.id), offsets: rows.offsets, heights: rows.heights,
                                laneCounts: rows.lanes.map(\.count), scales: rows.scales, baseHeight: row,
                                top: rulerHeight, verticalOffset: verticalScroll.offset,
                                scrollView: { mixerScrollController.scrollView },
                                excludedX: labelWidth...(labelWidth + dividerWidth), interactionBlocked: gridInteractionBlocked,
                                change: { id, scale, ended in
                                    if ended {
                                        show.setTrackHeightScale(id, scale: scale, project: projectID, song: song.id)
                                        trackHeightPreview.removeAll()
                                    } else {
                                        if trackHeightPreview.isEmpty { trackHeightMotion.cancel(); trackHeight = row }
                                        trackHeightPreview[id] = scale
                                    }
                                }, cancel: { trackHeightPreview.removeAll() })
                            #endif
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
            if NativeTimelineInputGate.shared.cancelActiveResize(for: NSApp.currentEvent?.window) { return }
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
        .onDisappear { trackHeightMotion.cancel(); trackHeightPreview.removeAll() }
        .onChange(of: gridInteractionBlocked) { blocked in
            if blocked { trackHeightMotion.cancel(); trackHeightPreview.removeAll() }
        }
        #endif
        .sheet(isPresented: $showingReRender) {
            ItemReRenderProgressView(progress: reRenderProgress, title: reRenderTitle,
                                     cancel: glueCancellation.map { cancellation in { cancellation.cancel() } }) { showingReRender = false }
        }
        .sheet(item: $regionExport) { request in
            AudioExportView(project: request.project, song: request.song, mediaDirectory: request.mediaDirectory,
                            regionSelection: request.regions)
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
        .onChange(of: show.current?.id) { _ in trackHeightPreview.removeAll(); itemGainPreview.clear(); insertionPreview.update(nil); selectedClip = nil; selectedClips.removeAll(); selectedTrack = nil; selectedTracks.removeAll() }
        .background(JarasTheme.background).sheet(isPresented: $addingTrack) {
            CreateTrackEditor(show: show, afterTrack: selectedTrack, close: { addingTrack = false }, created: { ids in
                let selectable = show.current?.tracks.filter { $0.kind == .standard && ids.contains($0.id) }.map(\.id) ?? []
                selectedTrack = selectable.first; selectedTracks = Set(selectable)
            }).environment(\.locale, locale)
        }
    }
    #if os(macOS)
    private func makeNativeBaseConfiguration(song: Song, originalSong: Song, rows: TrackRowLayout,
                                             metadata: TimelineRenderMetadata, selectionInput: GridSelectionInput,
                                             extent: Double, rulerHeight: CGFloat, regionLanes: RegionLanes,
                                             contentHeight: CGFloat, layoutWidth: CGFloat,
                                             viewportSize: CGSize, audioBody: NativeTimelineAudioBodyConfiguration?) -> NativeTimelineBaseConfiguration {
        let controller = nativeBase
        let bands = song.tracks.enumerated().compactMap { index, track -> TimelineNativeGridBand? in
            guard track.kind == .standard, selectedTracks.contains(track.id) else { return nil }
            return TimelineNativeGridBand(rect: CGRect(x: 0, y: rulerHeight + rows.offsets[index], width: 0, height: rows.heights[index]),
                color: NSColor(JarasTheme.track(track, emphasized: true).opacity(0.12)).cgColor)
        }
        let originalParts = Dictionary(uniqueKeysWithValues: originalSong.parts.map { ($0.id, $0) })
        let unifiable = overlapCache.regions(song: originalSong, revision: revision)
        let regionTargets = song.parts.compactMap { part -> NativeTimelineRegionTarget? in
            guard part.parentRegionID == nil, let original = originalParts[part.id] else { return nil }
            let hasChildren = metadata.regionParentIDs.contains(part.id)
            return NativeTimelineRegionTarget(id: part.id, start: part.startTime, end: part.endTime,
                lane: regionLanes.lanes[part.id] ?? 0, edgePadding: hasChildren ? 0 : 10,
                selected: selectedRegion == part.id,
                pinned: part.id == editingRegion || part.id == unifyingRegion || part.id == movingRegion || part.id == resizingRegion,
                input: nativeRegionInput(original, song: originalSong, canUnify: unifiable.contains(part.id), hasChildren: hasChildren))
        }
        return NativeTimelineBaseConfiguration(show: show, extent: extent, contentHeight: contentHeight,
            layoutWidth: layoutWidth, viewportSize: viewportSize, rulerHeight: rulerHeight,
            regionLanes: regionLanes.count,
            header: NativeTimelineHeaderConfiguration(song: song, lanes: regionLanes,
                parentIDs: metadata.regionParentIDs, regionTargets: regionTargets,
                edit: { marker in if marker.isTempo { editingTempoMarker = marker } else { editingMarker = marker } },
                delete: { show.deleteManualMarker($0) }, seek: { show.send(.editSeek, value: $0.position) }, move: { show.setMarker($0) }),
            rows: rows, sections: metadata.sections(until: extent),
            divisions: song.projectTime.divisions, bands: bands, audioBody: audioBody, input: selectionInput,
            hostedItemsGate: hostedItemsGate,
            hostedItemCoverage: audioBody.map { TimelineHostedItemCoverage(items: $0.fallbackItems, identity: $0.fallbackIdentity) },
            hasHostedItems: metadata.hasItems && (audioBody?.hasFallbackItems ?? true),
            hasHostedProjection: {
                editingRegion != nil || unifyingRegion != nil ||
                itemGainPreview.state != nil || !LiveRecordingPreview.shared.takes.isEmpty ||
                insertionPreview.time != nil || TimelineAreaSelection.shared.range?.song == song.id
            },
            itemGuide: { scale in
                if resizingItem != nil {
                    return CGRect(x: resizedItemStart * scale + 1, y: 0, width: max(0, (resizedItemEnd - resizedItemStart) * scale - 2), height: 0)
                }
                if let movingClip, let clip = originalSong.tracks.lazy.flatMap(\.clips).first(where: { $0.id == movingClip }) {
                    return CGRect(x: movingStart * scale + 1, y: 0, width: max(0, clip.duration * scale - 2), height: 0)
                }
                return nil
            }, editPosition: editPosition, focusRequest: show.regionFocusRequest,
            focusTime: show.snapshot.transport.subPlay.playing ? nil : (show.navigationFocusPosition ?? show.restoredCursorPosition ?? song.parts.first(where: { $0.id == show.focusedRegion })?.startTime),
            interactionBlocked: gridInteractionBlocked, extend: { timelineExtent = extent + 240 },
            horizontalOffsetChanged: { if horizontalScroll.offset != $0 { horizontalScroll.offset = $0 } },
            verticalOffsetChanged: { offset in
                let moved = abs(verticalScroll.offset - offset) > 0.001
                verticalScroll.update(offset)
                if moved, mixerResizeState.includeWidthReserve() {
                    mixerScrollController.scrollView?.window?.contentView?.layoutSubtreeIfNeeded()
                }
            }, changeTrackHeight: { factor, smoothWheel in
                changeTrackHeight(factor, smoothWheel: smoothWheel, rows: rows)
            }, livePosition: { show.timelineZoomPosition / extent },
            selectTime: { first, last in
                let scale = controller.pixelsPerSecond
                TimelineAreaSelection.shared.update(song: song.id,
                    from: itemPosition(first * extent, song: song, pixelsPerSecond: scale, snappingRegionEnds: true),
                    to: itemPosition(last * extent, song: song, pixelsPerSecond: scale, snappingRegionEnds: true))
                show.updateActiveLoopArea()
            }, selectedTime: {
                guard let range = TimelineAreaSelection.shared.range, range.song == song.id else { return nil }
                return (range.start / extent, range.end / extent)
            }, resizeTime: { fraction, left in
                guard let range = TimelineAreaSelection.shared.range, range.song == song.id else { return }
                let position = itemPosition(fraction * extent, song: song, pixelsPerSecond: controller.pixelsPerSecond, snappingRegionEnds: true)
                TimelineAreaSelection.shared.update(song: song.id,
                    from: left ? min(position, range.end - 0.001) : range.start,
                    to: left ? range.end : max(position, range.start + 0.001))
                show.updateActiveLoopArea()
            }, rulerSeek: { fraction, secondary, free in
                show.send(secondary ? .subSeek : .editSeek,
                    value: gridPosition(fraction * extent, song: song, pixelsPerSecond: controller.pixelsPerSecond, freePositioning: free))
            }, needleSeek: { position, secondary in
                guard let current = show.current else { return }
                show.send(secondary ? .subSeek : .editSeek,
                    value: gridPosition(position, song: current, pixelsPerSecond: controller.pixelsPerSecond))
            }, marker: { tempo in if tempo { beginTempoMarker() } else { beginMarker() } })
    }

    /// Editing actions change with project/selection state, not each zoom frame.
    /// Read the scale committed to the native input, so an in-flight zoom
    /// cannot make editing jump ahead of the displayed geometry.
    private func makeSelectionInput(originalSong: Song, song: Song, rows: TrackRowLayout,
                                    rulerHeight: CGFloat, extent: Double,
                                    selectionLayout: GridSelectionLayout) -> GridSelectionInput {
        let projection = GridSelectionProjection()
        return GridSelectionInput(origin: .zero, headerHeight: rulerHeight, items: [], selected: selectedClips, selectionChanged: { next in
            selectedClips = next
            selectedClip = selectionLayout.items.first { next.contains($0.id) }?.id
        }, mute: { id in if originalSong.tracks.contains(where: { $0.kind == .standard && $0.clips.contains { $0.id == id } }) { show.send(.clipMute, target: id) } }, move: { id, translation, pointerY, ended in
            let pixelsPerSecond = projection.pixelsPerSecond

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
        }, seek: { x, freePositioning in
            let pixelsPerSecond = projection.pixelsPerSecond
            show.send(.editSeek, value: gridPosition(x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond, freePositioning: freePositioning)) }, createRegion: { show.regionsFromSelection(selectedClips.contains($0) ? selectedClips : [$0]) }, indexedLayout: selectionLayout, pixelsPerSecond: 1, projection: projection, interactionBlocked: gridInteractionBlocked, resize: { id, left, delta, ended in
            let pixelsPerSecond = projection.pixelsPerSecond

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
            let pixelsPerSecond = projection.pixelsPerSecond

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
        }, selectRow: { position in
            let y = position - rulerHeight
            guard let index = rows.offsets.indices.first(where: {
                y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0]
            }), song.tracks.indices.contains(index) else { return }
            let id = song.tracks[index].id
            selectedTrack = id
            selectedTracks = [id]
        })
    }
    #endif
    private func makeTimelineDrawing(viewport: CGRect, song: Song, rows: TrackRowLayout,
                                     renderKey: TimelineRenderKey, rulerHeight: CGFloat,
                                     extent: Double, documentWidth: CGFloat,
                                     metadata: TimelineRenderMetadata, nativeAudioItems: Set<UUID> = [],
                                     hostedMetalRequired: Bool = true) -> TimelineDrawing {
        var drawing = TimelineDrawing(visibleRect: viewport, song: song, renderKey: renderKey,
            rowHeight: rows.baseHeight, rulerHeight: rulerHeight, extent: extent,
            selectedClips: selectedClips, movingClip: movingClip, movingStart: movingStart)
        drawing.mediaDirectory = documents.currentURL?.deletingLastPathComponent()
        drawing.missingAudioPaths = documents.missingAudioPaths
        drawing.documentWidth = documentWidth
        drawing.selectedTracks = selectedTracks
        drawing.trackHeightScales = rows.scales
        drawing.cachedRows = rows
        drawing.renderMetadata = metadata
        drawing.nativeAudioItems = nativeAudioItems
        drawing.hostedMetalRequired = hostedMetalRequired
        return drawing
    }
    #if os(macOS)
    private func changeTrackHeight(_ factor: Double, smoothWheel: Bool, rows: TrackRowLayout) {
        guard trackHeightPreview.isEmpty else { return }
        trackHeightMotion.change(factor: factor, current: rows.baseHeight, smoothWheel: smoothWheel,
                                limits: rows.globalLimits) { trackHeight = $0 }
    }
    #endif
    private func previewTrackHeights(_ source: Song) -> Song {
        guard !trackHeightPreview.isEmpty else { return source }
        var song = source
        for index in song.tracks.indices {
            if let value = trackHeightPreview[song.tracks[index].id] { song.tracks[index].heightScale = value }
        }
        return song
    }
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
                .font(.system(size: 8 * GridSelectionItem.headerScale, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30 * GridSelectionItem.headerScale, height: GridSelectionItem.headerHeight).background(Color.black.opacity(0.28))
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
                    if result.tracks[track].kind == .standard || result.tracks[track].kind.isText || result.tracks[track].clips[clip].isProjectionMedia {
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
    #if os(macOS)
    /// Commands are retained across scale changes; geometry still updates every
    /// display frame and drag math reads the current native projection.
    private func nativeRegionInput(_ part: Part, song: Song, canUnify: Bool, hasChildren: Bool? = nil) -> RegionRightClick {
        let unified = hasChildren ?? song.parts.contains(where: { $0.parentRegionID == part.id })
        return RegionRightClick(edit: { editingRegion = part.id }, unify: canUnify ? { requestUnification(part.id) } : nil, detectBPM: { show.detectBPMRegion = part.id }, disunify: unified ? { show.disunifyRegion(part.id) } : nil, delete: {
            regionToDelete = (show.snapshot.project.id, song.id, part.id)
            confirmingRegionDelete = true
        }, exportAudio: {
            guard let current = show.current, current.id == song.id,
                  current.parts.contains(where: { $0.id == part.id }) else { return }
            regionExport = RegionAudioExportRequest(project: show.snapshot.project, song: current,
                regions: [part.id], mediaDirectory: documents.currentURL?.deletingLastPathComponent())
        }, resizable: !unified, seek: { show.selectTimelineRegion(part.id); show.send(.editSeek, value: part.startTime) }, drag: { translation, ended, edge in
            let pixelsPerSecond = nativeBase.pixelsPerSecond
            let original = part
            if edge != 0 {
                guard original.parentRegionID == nil, !unified else {
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
                        let target = itemPosition(boundary, song: song, pixelsPerSecond: pixelsPerSecond, excludingRegion: part.id)
                        snapped = nearestRegionItemEdge(boundary, points: regionSnapPoints, tolerance: abs(target - boundary)) ?? target
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
                let proposed = itemPosition(original.startTime + translation / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond, excludingRegion: part.id)
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
    }
    #endif
    @ViewBuilder
    private func regionHitArea(_ part: Part, song: Song, pixelsPerSecond: Double, canUnify: Bool) -> some View {
        #if os(macOS)
        nativeRegionInput(part, song: song, canUnify: canUnify)
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

    private func itemPosition(_ time: Double, song: Song, pixelsPerSecond: Double, snappingRegionEnds: Bool = true, excludingRegion: UUID? = nil) -> Double {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.shift) { return max(0, time) }
        #endif
        let transport = show.snapshot.transport
        return TimelineTempo.snap(time, song: song, pixelsPerSecond: pixelsPerSecond, regionEnds: snappingRegionEnds,
                                  cursor: transport.editPosition ?? transport.position,
                                  otherCursors: [transport.position] + (transport.subPlay.playing ? [transport.subPlay.position] : []),
                                  excludingRegion: excludingRegion)
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
/// Audio decorations and source geometry can share the native scale projection.
/// Text and simple media decorations use the same retained native projection.
/// MIDI and generated click bodies keep their existing specialized drawing.
@MainActor private struct NativeTimelineAudioBodyConfiguration {
    struct Palette {
        let normal: SIMD4<Float>
        let selected: SIMD4<Float>
    }
    let song: Song
    let rows: TrackRowLayout
    let metadata: TimelineRenderMetadata
    let rulerHeight: CGFloat
    let selectedClips: Set<UUID>
    let mediaDirectory: URL
    let itemIDs: Set<UUID>
    let palettes: [Palette]
    let decorations: [UUID: NativeTimelineItemBodyInkView.Content]
    let hasFallbackItems: Bool
    let hasFallbackWaveforms: Bool
    let fallbackItems: [CGRect]
    let fallbackIdentity: Int

    static func make(song: Song, rows: TrackRowLayout, metadata: TimelineRenderMetadata,
                     rulerHeight: CGFloat, selectedClips: Set<UUID>, mediaDirectory: URL?,
                     missingAudioPaths: Set<String>, identity: Int = 0) -> Self? {
        guard MetalWaveformRenderer.isSupported, let mediaDirectory else { return nil }
        var ids = Set<UUID>(), hasFallbackItems = false, hasFallbackWaveforms = false
        var fallbackItems: [CGRect] = []
        var decorations: [UUID: NativeTimelineItemBodyInkView.Content] = [:]
        for (index, track) in song.tracks.enumerated() {
            for clip in track.clips {
                let hasAudio = (clip.audioFile ?? track.audioFile).map { !missingAudioPaths.contains($0.path) } ?? false
                let waveform = track.kind == .standard && clip.midi == nil && hasAudio
                let decoration = NativeTimelineItemBodyInkView.content(clip: clip, track: track,
                    missing: (clip.audioFile ?? track.audioFile).map { missingAudioPaths.contains($0.path) } ?? false)
                if waveform && !clip.isProjectionMedia { ids.insert(clip.id) }
                else if let decoration {
                    ids.insert(clip.id); decorations[clip.id] = decoration
                } else {
                    hasFallbackItems = true; hasFallbackWaveforms = hasFallbackWaveforms || waveform
                    fallbackItems.append(CGRect(x: clip.startTime,
                        y: rulerHeight + rows.offsets[index] + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3,
                        width: clip.duration, height: rows.laneHeights[index] - 6))
                }
            }
        }
        guard !ids.isEmpty else { return nil }
        let palettes = song.tracks.map { track in
            func color(_ selected: Bool) -> SIMD4<Float> {
                let rgb = TrackNameContrast.components(track.color ?? JarasTheme.roleHex(track.role), emphasized: selected)
                return SIMD4(Float(rgb.red), Float(rgb.green), Float(rgb.blue), 1)
            }
            return Palette(normal: color(false), selected: color(true))
        }
        return Self(song: song, rows: rows, metadata: metadata, rulerHeight: rulerHeight,
            selectedClips: selectedClips, mediaDirectory: mediaDirectory, itemIDs: ids, palettes: palettes, decorations: decorations,
            hasFallbackItems: hasFallbackItems, hasFallbackWaveforms: hasFallbackWaveforms, fallbackItems: fallbackItems, fallbackIdentity: identity)
    }
}

/// Text/media item bodies do not need to invalidate the hosted SwiftUI tree
/// for every zoom sample. Immutable text is prepared with the project revision;
/// only visible rectangles change. The existing native item view owns all input.
@MainActor private final class NativeTimelineItemBodyInkView: NSView {
    enum Content {
        case text(NSAttributedString)
        case label(NSAttributedString)
        case emptyWaveform(channels: Int)

        func isVisible(in rect: CGRect) -> Bool {
            guard rect.height > 26 else { return false }
            switch self {
            case .text(let text): return rect.width > 16 && text.length > 0
            case .label: return rect.width >= 18 && rect.height - GridSelectionItem.headerHeight >= 12
            case .emptyWaveform: return true
            }
        }
    }
    struct Item {
        let content: Content
        let rect: CGRect
        let silenced: Bool
        let rgb: SIMD4<Float>
        var firstSeamX: CGFloat? = nil
        var repeatSpacing: CGFloat? = nil

        func clippingPath(visible: CGRect) -> CGPath {
            let path = CGMutablePath()
            if rect.width < 20 { path.addRect(rect) }
            else { path.addRoundedRect(in: rect, cornerWidth: 3, cornerHeight: 3) }
            if let firstSeamX, let repeatSpacing, repeatSpacing > 0 {
                let radius: CGFloat = rect.width < 20 ? 0 : 3
                let start = max(firstSeamX, firstSeamX + ceil((visible.minX - 4 - firstSeamX) / repeatSpacing) * repeatSpacing)
                let end = min(rect.maxX - radius, visible.maxX + 4)
                for x in stride(from: start, through: end, by: repeatSpacing) where x > rect.minX + radius && x < rect.maxX - radius {
                    path.move(to: CGPoint(x: x - 4, y: rect.maxY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY - min(5, rect.height / 3)))
                    path.addLine(to: CGPoint(x: x + 4, y: rect.maxY))
                    path.closeSubpath()
                }
            }
            return path
        }
    }
    private var items: [Item] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func content(clip: AudioClip, track: Track, missing: Bool) -> Content? {
        // Keep MIDI and generated click visualization on their dedicated path.
        guard clip.midi == nil else { return nil }
        func label(_ name: String) -> Content {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            return .label(NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white, .paragraphStyle: style]))
        }
        if missing { return label(JarasLocalization.string("Not found")) }
        if track.kind == .timecode && !clip.isProjectionMedia { return label("TIMECODE") }
        if track.kind.isText && !clip.isProjectionMedia {
            return .text(NSAttributedString(string: clip.text ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black]))
        }
        // Standard-track video can also have a waveform. Leave that combined
        // path untouched here; text/video tracks only show a media decoration.
        if track.kind == .video {
            let ext = URL(fileURLWithPath: clip.audioFile?.path ?? "").pathExtension
            let image = UTType(filenameExtension: ext)?.conforms(to: .image) == true
            return label(image ? JarasLocalization.string("Image") : "VIDEO")
        }
        if track.kind.isText && clip.isProjectionMedia {
            let ext = URL(fileURLWithPath: clip.audioFile?.path ?? "").pathExtension.lowercased()
            if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) { return label("VIDEO") }
            if clip.isImage && clip.waveform.isEmpty && (clip.waveformChannels ?? []).allSatisfy(\.isEmpty) {
                return .emptyWaveform(channels: max(1, clip.waveformChannels?.count ?? 1))
            }
        }
        return nil
    }
    func update(_ items: [Item]) {
        let hadItems = !self.items.isEmpty
        self.items = items
        if hadItems || !items.isEmpty { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for item in items where item.rect.height > 26 && item.rect.intersects(dirtyRect) {
            let rect = item.rect
            context.saveGState()
            context.addPath(item.clippingPath(visible: bounds)); context.clip(using: .evenOdd)
            switch item.content {
            case .text(let text):
                if rect.width > 16, text.length > 0 {
                    let area = CGRect(x: rect.minX + 5, y: rect.minY + 17, width: rect.width - 10, height: rect.height - 20)
                    context.clip(to: area)
                    text.draw(with: area, options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
            case .label(let text):
                let area = CGRect(x: rect.minX + 4, y: rect.minY + GridSelectionItem.headerHeight,
                    width: rect.width - 8, height: rect.height - GridSelectionItem.headerHeight)
                if area.width >= 10, area.height >= 12 {
                    let height = text.size().height
                    text.draw(in: CGRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height))
                }
            case .emptyWaveform(let channels):
                let waveTop = rect.minY + min(GridSelectionItem.bodyInset, rect.height)
                let channelHeight = max(1, rect.maxY - waveTop - 2) / CGFloat(channels)
                let luminance = 0.2126 * item.rgb.x + 0.7152 * item.rgb.y + 0.0722 * item.rgb.z
                let gray: CGFloat = item.silenced ? 0.78 : luminance > 0.68 ? 0.52 : luminance > 0.42 ? 0.9 : 0.8
                context.setStrokeColor(NSColor(white: gray, alpha: 1).cgColor)
                context.setLineWidth(1)
                for channel in 0..<channels {
                    context.saveGState()
                    context.clip(to: CGRect(x: rect.minX, y: waveTop + channelHeight * CGFloat(channel) + 0.5,
                        width: rect.width, height: max(0, channelHeight - 1)))
                    let middle = waveTop + channelHeight * (CGFloat(channel) + 0.5)
                    context.move(to: CGPoint(x: max(bounds.minX, rect.minX), y: middle))
                    context.addLine(to: CGPoint(x: min(bounds.maxX, rect.maxX), y: middle))
                    context.strokePath()
                    context.restoreGState()
                }
            }
            context.restoreGState()
        }
    }
}

/// One retained fill surface sits below the retained waveform surface. Waveform
/// maximum blending remains isolated from the alpha-blended item decoration.
@MainActor private final class NativeTimelineAudioBodyView: NSView {
    private let fills = MetalWaveformSurface()
    private let waveforms = MetalWaveformSurface()
    private let bodyInk = NativeTimelineItemBodyInkView()
    private var configuration: NativeTimelineAudioBodyConfiguration?
    private var sourceOwner = TimelineWaveformVertexOwner()
    private let mediaURLs = TimelineMediaURLCache()
    private var readiness: AnyCancellable?
    private var readinessPending = false
    private var contentRevision = 0
    private struct Projection: Equatable {
        let viewport: CGRect
        let scale: Double
        let revision: Int
    }
    private var projection: Projection?
    private var waveformProjection: Projection?
    private var waveformReadinessRevision: UInt64?
    private var verticalViewportHeight: CGFloat?
    private var visibleWaveforms: [TimelineWaveformItem] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(fills); addSubview(waveforms); addSubview(bodyInk)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ value: NativeTimelineAudioBodyConfiguration?) {
        configuration = value
        bodyInk.update([])
        mediaURLs.prepareClipRevision(directory: value?.mediaDirectory)
        contentRevision &+= 1
        projection = nil
        waveformProjection = nil
        waveformReadinessRevision = nil
        verticalViewportHeight = nil
        if value == nil {
            readiness = nil
            visibleWaveforms.removeAll()
            sourceOwner = TimelineWaveformVertexOwner()
            fills.submit(MetalWaveformFrame(size: bounds.size, strokes: []))
            waveforms.submit(MetalWaveformFrame(size: bounds.size, strokes: []))
            isHidden = true
        } else {
            isHidden = false
            if readiness == nil {
                readiness = TimelineAudioWaveform.shared.$revision.dropFirst().sink { [weak self] _ in
                    self?.scheduleWaveforms()
                }
            }
        }
    }

    func project(viewport: CGRect, documentSize: CGSize, scale: Double) {
        #if CATLIVE_RENDER_DIAGNOSTICS
        if TimelineRenderDiagnosticBypass.contains("body") { return }
        #endif
        guard let value = configuration, scale.isFinite, scale > 0 else { return }
        // Horizontal coverage still follows the hosted publication buckets.
        // Native vertical scrolling supplies every destination before exposure,
        // so retain a smaller independent band across zoom and small pans.
        let bucket = TimelineWaveformCoverage.scrollBucket
        let coveredViewport = CGRect(x: floor(max(0, viewport.minX) / bucket) * bucket,
            y: floor(max(0, viewport.minY) / bucket) * bucket,
            width: viewport.width, height: viewport.height)
        var tile = TimelineWaveformCoverage.preparedRect(visibleRect: coveredViewport, documentSize: documentSize)
        let top = max(0, min(documentSize.height, viewport.minY))
        let bottom = max(top, min(documentSize.height, viewport.maxY))
        let requiredTop = max(0, top - 64)
        let requiredBottom = min(documentSize.height, bottom + 64)
        if let retained = projection?.viewport, verticalViewportHeight == viewport.height,
           retained.minY <= requiredTop, retained.maxY >= requiredBottom,
           retained.maxY <= documentSize.height {
            tile.origin.y = retained.minY
            tile.size.height = retained.height
        } else {
            let first = max(0, floor((top - 256) / 64) * 64)
            let last = min(documentSize.height, ceil((bottom + 256) / 64) * 64)
            tile.origin.y = first
            tile.size.height = max(0, last - first)
        }
        verticalViewportHeight = viewport.height
        let next = Projection(viewport: tile, scale: scale, revision: contentRevision)
        guard projection != next else { return }
        projection = next
        if frame != tile { frame = tile }
        let local = CGRect(origin: .zero, size: tile.size)
        if fills.frame != local { fills.frame = local }
        if waveforms.frame != local { waveforms.frame = local }
        if bodyInk.frame != local { bodyInk.frame = local }
        var ink: [NativeTimelineItemBodyInkView.Item] = []
        var items: [MetalTimelineItem] = []
        visibleWaveforms.removeAll(keepingCapacity: true)
        for (index, track) in value.song.tracks.enumerated() {
            let y = value.rulerHeight + value.rows.offsets[index]
            guard y <= tile.maxY, y + value.rows.heights[index] >= tile.minY else { continue }
            let trackSilenced = track.mute || (value.metadata.hasSolo && !track.solo)
            for clipIndex in value.metadata.clipIndices(inTrack: index,
                from: Double(tile.minX - 9) / scale, through: Double(tile.maxX + 9) / scale) {
                let clip = track.clips[clipIndex]
                guard value.itemIDs.contains(clip.id) else { continue }
                let rect = CGRect(x: clip.startTime * scale + 1,
                    y: y + CGFloat(value.rows.lanes[index].lanes[clip.id] ?? 0) * value.rows.laneHeights[index] + 3,
                    width: max(2, clip.duration * scale - 2), height: value.rows.laneHeights[index] - 6)
                guard rect.width > 0, rect.height > 0, rect.intersects(tile.insetBy(dx: -6, dy: -6)) else { continue }
                let selected = value.selectedClips.contains(clip.id), silenced = trackSilenced || clip.muted == true
                let compact = rect.width < 20
                let palette = value.palettes[index]
                let rgb = selected ? palette.selected : palette.normal
                let color = silenced ? SIMD4<Float>(repeating: selected ? 0.7 : 0.55) : rgb
                func alpha(_ color: SIMD4<Float>, _ value: Float) -> SIMD4<Float> { SIMD4(color.x, color.y, color.z, value) }
                let top = alpha(color, compact ? (silenced ? 0.55 : 0.88) : (silenced ? 0.55 : 1))
                let bottom = alpha(color, compact ? top.w : (silenced ? 0.25 : selected ? 1 : 0.78))
                let border = selected ? SIMD4<Float>(105.0 / 255, 237.0 / 255, 145.0 / 255, 1) : alpha(color, 0.75)
                var item = MetalTimelineItem(rect: rect.offsetBy(dx: -tile.minX, dy: -tile.minY),
                    topColor: top, bottomColor: bottom, borderColor: border,
                    cornerRadius: compact ? 0 : 3, borderWidth: selected ? 1.5 : compact ? 0 : 0.6,
                    headerHeight: compact ? 0 : Float(rect.height <= 26 ? rect.height : min(GridSelectionItem.headerHeight, rect.height)))
                if let length = clip.loopLength, length.isFinite, length > 0, clip.audioRate.isFinite, clip.audioRate > 0 {
                    var seams = ClipRepetitionBoundaries(clip: clip,
                        visible: max(clip.startTime, (tile.minX - 4) / scale)...max(clip.startTime, (tile.maxX + 4) / scale),
                        minimumSpacing: 10 / scale).makeIterator()
                    item.firstSeamX = seams.next().map { CGFloat($0 * scale - tile.minX) }
                    if item.firstSeamX != nil {
                        item.repeatSpacing = CGFloat(max(1, ceil(10 / (length / clip.audioRate * scale))) * length / clip.audioRate * scale)
                    }
                }
                items.append(item)
                if let decoration = value.decorations[clip.id] {
                    if decoration.isVisible(in: item.rect) {
                        ink.append(.init(content: decoration, rect: item.rect, silenced: silenced, rgb: rgb,
                            firstSeamX: item.firstSeamX, repeatSpacing: item.repeatSpacing))
                    }
                } else if rect.height > 26, let file = clip.audioFile ?? track.audioFile {
                    let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                    let gray: Float = silenced ? 0.78 : luminance > 0.68 ? 0.52 : luminance > 0.42 ? 0.9 : 0.8
                    guard let mediaSource = mediaURLs.resolveClipSource(clip.id, path: file.path) else { continue }
                    visibleWaveforms.append(TimelineWaveformItem(clip: clip,
                        fragments: value.metadata.fragments(for: clip),
                        url: mediaSource.url, rect: rect, gray: gray, sourcePath: mediaSource.path, mediaSource: mediaSource))
                }
            }
        }
        let coordinates = MetalWaveformCoordinateSpace(documentOrigin: tile.origin, pixelsPerSecond: scale, contentRevision: contentRevision)
        fills.submit(MetalWaveformFrame(size: tile.size, strokes: [], coordinateSpace: coordinates, items: items))
        bodyInk.update(ink)
        submitWaveforms()
    }
    private func scheduleWaveforms() {
        guard !readinessPending else { return }
        readinessPending = true
        // @Published emits before the revision changes. Owner coverage must
        // see its new value before deciding whether to probe ready blocks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readinessPending = false
            self.submitWaveforms()
        }
    }
    private func submitWaveforms() {
        #if CATLIVE_RENDER_DIAGNOSTICS
        if TimelineRenderDiagnosticBypass.contains("waveforms") { return }
        #endif
        guard configuration != nil, let projection else { return }
        let revision = TimelineAudioWaveform.shared.revision
        // A zoom frame may already have consumed the ready blocks before the
        // deferred readiness callback runs. Do not rebuild and submit that
        // identical scene a second time; new geometry or source data still does.
        guard waveformProjection != projection || waveformReadinessRevision != revision else { return }
        waveformProjection = projection
        waveformReadinessRevision = revision
        waveforms.submit(TimelineMetalWaveformFrameBuilder.make(items: visibleWaveforms,
            viewport: projection.viewport, scale: projection.scale, cache: .shared,
            owner: sourceOwner, contentRevision: projection.revision))
    }
}

/// Structural data changes with the project, settings or selection. Scale is
/// delivered directly to the retained native views without a SwiftUI layout.
@MainActor private struct NativeTimelineBaseConfiguration {
    let show: ShowController
    let extent: Double
    let contentHeight: CGFloat
    let layoutWidth: CGFloat
    let viewportSize: CGSize
    let rulerHeight: CGFloat
    let regionLanes: Int
    let header: NativeTimelineHeaderConfiguration
    let rows: TrackRowLayout
    let sections: [TimelineTempoSection]
    let divisions: Int
    let bands: [TimelineNativeGridBand]
    let audioBody: NativeTimelineAudioBodyConfiguration?
    let input: GridSelectionInput
    let hostedItemsGate: TimelineHostedItemsGate
    let hostedItemCoverage: TimelineHostedItemCoverage?
    let hasHostedItems: Bool
    let hasHostedProjection: () -> Bool
    let itemGuide: (CGFloat) -> CGRect?
    let editPosition: Double
    let focusRequest: UUID
    let focusTime: Double?
    let interactionBlocked: Bool
    let extend: () -> Void
    let horizontalOffsetChanged: (CGFloat) -> Void
    let verticalOffsetChanged: (CGFloat) -> Void
    let changeTrackHeight: (Double, Bool) -> Void
    let livePosition: () -> Double
    let selectTime: (Double, Double) -> Void
    let selectedTime: () -> (Double, Double)?
    let resizeTime: (Double, Bool) -> Void
    let rulerSeek: (Double, Bool, Bool) -> Void
    let needleSeek: (Double, Bool) -> Void
    let marker: (Bool) -> Void
}

/// The closed header owns no SwiftUI zoom graph. Text is rasterized only when
/// its displayed string/backing scale changes; projection never stretches it.
@MainActor private struct NativeTimelineHeaderConfiguration {
    let song: Song
    let lanes: RegionLanes
    let parentIDs: Set<UUID>
    let regionTargets: [NativeTimelineRegionTarget]
    let edit: (TimelineMarker) -> Void
    let delete: (UUID) -> Void
    let seek: (TimelineMarker) -> Void
    let move: (TimelineMarker) -> Void
}

/// Preserve the original NSColor conversion (including its color space), but
/// keep ColorSync/string comparisons out of each projected drawing primitive.
@MainActor private enum NativeTimelineHeaderColors {
    private struct Key: Hashable {
        let hex: UInt32
        let alpha: CGFloat?
    }
    private static var cache: [Key: CGColor] = [:]
    static func color(_ hex: UInt32, alpha: CGFloat? = nil) -> CGColor {
        let key = Key(hex: hex, alpha: alpha)
        if let color = cache[key] { return color }
        let base = NSColor(Color(hex: hex))
        let color = (alpha.map { base.withAlphaComponent($0) } ?? base).cgColor
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = color
        return color
    }
}

private final class NativeTimelineHeaderText: NSObject {
    private static let cache: NSCache<NSString, NativeTimelineHeaderText> = {
        let cache = NSCache<NSString, NativeTimelineHeaderText>()
        cache.countLimit = 4096; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    let image: CGImage
    let size: CGSize
    let width: CGFloat
    private init?(text: String, color: UInt32, scale: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor(Color(hex: color))
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        size = CGSize(width: max(1, ceil(width) + 2), height: max(1, ceil(ascent + descent + leading)))
        let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
        guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.setShouldAntialias(true); bitmap.setShouldSmoothFonts(false)
        bitmap.textPosition = CGPoint(x: 1, y: size.height - ascent)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        self.image = image
    }
    static func label(_ text: String, color: UInt32, scale: CGFloat) -> NativeTimelineHeaderText? {
        let scale = min(4, max(1, scale))
        let key = "\(color)|\(scale)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let value = NativeTimelineHeaderText(text: text, color: color, scale: scale) else { return nil }
        cache.setObject(value, forKey: key, cost: value.image.bytesPerRow * value.image.height)
        return value
    }
    static func draw(_ image: CGImage, size: CGSize, at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y + size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }
}

@MainActor private final class NativeTimelineHeaderView: NSView, NativeTimelineInputObserver {
    private struct Region {
        let part: Part
        let lane: Int
        let color: UInt32
        let fill: CGColor
        let boundaries: [(width: CGFloat, color: CGColor)]
        let name: String
        let identifier: String
    }
    private struct MarkerColors {
        let fill: CGColor
        let stem: CGColor
    }
    private struct MarkerLane {
        let labels: [UUID: String]
        let geometry: NativeTimelineMarkerLayout
        let colors: [UUID: MarkerColors]
        let top: CGFloat
        let tempo: Bool
    }
    private struct ProjectedMarker {
        let marker: TimelineMarker
        let label: String
        let colors: MarkerColors
        let rect: CGRect
        let top: CGFloat
        let tempo: Bool
    }
    /// Only text owns pixels, at its original point size. Masks are at most the
    /// label's size; no backing surface follows the full document or viewport.
    private final class LabelLayer {
        let layer = CALayer()
        private let clipping = CAShapeLayer()
        private var image: CGImage?
        private var oldClip: CGRect?
        private var oldRadius: CGFloat = -1
        func update(image: CGImage, size: CGSize, point: CGPoint, clip: CGRect, radius: CGFloat, scale: CGFloat) {
            let frame = CGRect(origin: point, size: size)
            if layer.frame != frame { layer.frame = frame }
            if self.image !== image { self.image = image; layer.contents = image }
            if layer.contentsScale != scale { layer.contentsScale = scale }
            if layer.isHidden { layer.isHidden = false }
            // Most labels fit wholly between the rounded corners. Avoid a
            // mask in that case; partially clipped text keeps the exact path.
            let inside = clip.contains(frame) && (radius == 0 ||
                (frame.minX >= clip.minX + radius && frame.maxX <= clip.maxX - radius) ||
                (frame.minY >= clip.minY + radius && frame.maxY <= clip.maxY - radius))
            if inside {
                if layer.mask != nil { layer.mask = nil }
                return
            }
            let localClip = clip.offsetBy(dx: -point.x, dy: -point.y)
            let maskBounds = CGRect(origin: .zero, size: size)
            if oldClip != localClip || oldRadius != radius || clipping.frame != maskBounds {
                clipping.frame = maskBounds
                clipping.path = radius == 0 ? CGPath(rect: localClip, transform: nil)
                    : CGPath(roundedRect: localClip, cornerWidth: radius, cornerHeight: radius, transform: nil)
                oldClip = localClip; oldRadius = radius
            }
            if clipping.contentsScale != scale { clipping.contentsScale = scale }
            if layer.mask !== clipping { layer.mask = clipping }
        }
        func hide() { if !layer.isHidden { layer.isHidden = true } }
    }
    private final class RegionLayers {
        let root = CALayer()
        let fill = CALayer()
        let identifier = LabelLayer()
        let name = LabelLayer()
        init() {
            root.addSublayer(fill); root.addSublayer(identifier.layer); root.addSublayer(name.layer)
        }
    }
    private final class MarkerLayers {
        let root = CALayer()
        let stem = CAShapeLayer()
        let flag = CAShapeLayer()
        let outline = CAShapeLayer()
        let name = LabelLayer()
        private var stemSize = CGSize.zero
        private var flagRect = CGRect.null
        private var flagKind = -1
        private var stemTempo: Bool?
        init() {
            stem.fillColor = nil; stem.lineWidth = 1
            flag.strokeColor = nil; outline.fillColor = nil
            root.addSublayer(stem); root.addSublayer(flag); root.addSublayer(outline); root.addSublayer(name.layer)
        }
        func updateStem(frame: CGRect, tempo: Bool, color: CGColor, scale: CGFloat) {
            let hidden = frame.height <= 0
            if stem.isHidden != hidden { stem.isHidden = hidden }
            if stem.frame != frame { stem.frame = frame }
            if stemSize != frame.size {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0.5, y: 0)); path.addLine(to: CGPoint(x: 0.5, y: frame.height))
                stem.path = path; stemSize = frame.size
            }
            if stem.strokeColor !== color { stem.strokeColor = color }
            if stem.contentsScale != scale { stem.contentsScale = scale }
            if stemTempo != tempo { stem.lineDashPattern = tempo ? [2, 3] : nil; stemTempo = tempo }
        }
        func updateFlag(rect: CGRect, visible: CGRect, kind: Int, fill: CGColor, stroke: CGColor?, scale: CGFloat) {
            let frame = rect.intersection(visible)
            let hidden = frame.isNull || frame.isEmpty
            if flag.isHidden != hidden { flag.isHidden = hidden }
            let outlineHidden = hidden || stroke == nil
            if outline.isHidden != outlineHidden { outline.isHidden = outlineHidden }
            guard !hidden else { return }
            if flag.frame != frame { flag.frame = frame }
            if outline.frame != frame { outline.frame = frame }
            let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            if flagRect != local || flagKind != kind {
                let path: CGPath
                switch kind {
                case 1:
                    let section = CGMutablePath()
                    section.move(to: CGPoint(x: local.minX, y: local.midY))
                    section.addLine(to: CGPoint(x: local.minX + min(7, local.width / 2), y: local.minY))
                    section.addLine(to: CGPoint(x: local.maxX, y: local.minY)); section.addLine(to: CGPoint(x: local.maxX, y: local.maxY))
                    section.addLine(to: CGPoint(x: local.minX + min(7, local.width / 2), y: local.maxY)); section.closeSubpath()
                    path = section
                case 2: path = CGPath(roundedRect: local.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 3, cornerHeight: 3, transform: nil)
                case 3: path = CGPath(roundedRect: local.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
                default: path = CGPath(rect: local, transform: nil)
                }
                flag.path = path; outline.path = path; flagRect = local; flagKind = kind
            }
            // Match the original separate fill/stroke compositing, including
            // partially covered corner pixels. The tile clips both only once.
            if flag.fillColor !== fill { flag.fillColor = fill }
            if outline.strokeColor !== stroke { outline.strokeColor = stroke }
            let lineWidth: CGFloat = kind == 2 ? 1.2 : 1
            if outline.lineWidth != lineWidth { outline.lineWidth = lineWidth }
            if flag.contentsScale != scale { flag.contentsScale = scale }
            if outline.contentsScale != scale { outline.contentsScale = scale }
        }
        func hideStem() { if !stem.isHidden { stem.isHidden = true } }
        func hideFlag() {
            if !flag.isHidden { flag.isHidden = true }
            if !outline.isHidden { outline.isHidden = true }
        }
    }
    private final class BoundaryLayers {
        let root = CALayer()
        let strokes = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
        private var edges: [CGFloat] = []
        private var size = CGSize.zero
        init() {
            root.masksToBounds = true
            for stroke in strokes { stroke.fillColor = nil; root.addSublayer(stroke) }
        }
        func update(frame: CGRect, edges: [CGFloat], colors: [(width: CGFloat, color: CGColor)], scale: CGFloat) {
            if root.frame != frame { root.frame = frame }
            let localEdges = edges.map { $0 - frame.minX }
            if self.edges != localEdges || size != frame.size {
                let path = CGMutablePath()
                for x in localEdges {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: frame.height))
                }
                for stroke in strokes { stroke.frame = CGRect(origin: .zero, size: frame.size); stroke.path = path }
                self.edges = localEdges; size = frame.size
            }
            for (stroke, color) in zip(strokes, colors) {
                if stroke.lineWidth != color.width { stroke.lineWidth = color.width }
                if stroke.strokeColor !== color.color { stroke.strokeColor = color.color }
                if stroke.contentsScale != scale { stroke.contentsScale = scale }
            }
        }
    }
    private let drawingLayer = CALayer()
    private let regionLayer = CALayer()
    private let markerLayer = CALayer()
    private let boundaryLayer = CALayer()
    private var regionLayers: [UUID: RegionLayers] = [:]
    private var markerLayers: [UUID: MarkerLayers] = [:]
    private var boundaryLayers: [UUID: BoundaryLayers] = [:]
    private var regionLayerOrder: [UUID] = []
    private var markerLayerOrder: [UUID] = []
    private var boundaryLayerOrder: [UUID] = []
    private let regionsInput = NativeTimelineRegionTargetsView()
    private let displayColor = NSColor(JarasTheme.display).cgColor
    private let lineColor = NSColor(JarasTheme.line).cgColor
    private let linkedOutlineColor = NSColor(JarasTheme.yellow).cgColor
    private var configuration: NativeTimelineHeaderConfiguration?
    private var regions: [Region] = []
    private var lanes: [MarkerLane] = []
    private var projectedMarkers: [ProjectedMarker] = []
    private var markerInputs: [UUID: MarkerEditClickView] = [:]
    private var inputOrder: [UUID] = []
    private var markerInputRanks: [UUID: Int] = [:]
    private var markerOrderIsDirty = false
    private var markerLastUsed: [UUID: UInt64] = [:]
    private var inputGeneration: UInt64 = 0
    private var hoveredMarkerID: UUID?
    private var markerTracking: NSTrackingArea?
    private var markerBandTop: CGFloat = 0
    private var preview: TimelineMarker?
    private var scale: CGFloat = 0
    private var displayScale: CGFloat = 1
    private var viewport = CGRect.zero
    private var tile = CGRect.zero
    private var layoutWidth: CGFloat = 0
    private struct Projection: Equatable {
        let tile: CGRect
        let scale: CGFloat
        let layoutWidth: CGFloat
        let displayScale: CGFloat
        let contentRevision: UInt64
    }
    private var contentRevision: UInt64 = 0
    private var lastProjection: Projection?
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        // Input subviews stay above the retained drawing, including selection.
        drawingLayer.zPosition = -1; drawingLayer.masksToBounds = true
        layer?.addSublayer(drawingLayer)
        for group in [regionLayer, markerLayer, boundaryLayer] { drawingLayer.addSublayer(group) }
        addSubview(regionsInput)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { NativeTimelineInputGate.shared.add(self) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = markerCursorBand.intersection(bounds)
        guard markerTracking?.rect != rect else { return }
        if let markerTracking { removeTrackingArea(markerTracking) }
        guard !rect.isNull, !rect.isEmpty else { markerTracking = nil; return }
        let area = NSTrackingArea(rect: rect,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); markerTracking = area
    }
    private var markerCursorBand: CGRect {
        CGRect(x: 0, y: markerBandTop, width: bounds.width, height: configuration == nil ? 0 : markerLaneHeight * 2)
    }
    override func resetCursorRects() {
        guard !NativeTimelineInputGate.shared.isBlocked(window), window?.attachedSheet == nil else { return }
        let visible = markerCursorBand.intersection(bounds).intersection(visibleRect)
        if !visible.isEmpty { addCursorRect(visible, cursor: .arrow) }
    }
    private func clearMarkerPointer() {
        guard let id = hoveredMarkerID else { return }
        if window?.isKeyWindow == true { markerInputs[id]?.updateProjectedPointer(at: nil) }
        hoveredMarkerID = nil
        // A region may already have projected its resize cursor this frame.
        // Restore that owner after clearing the previous marker's cursor.
        regionsInput.refreshProjectedPointer()
    }
    private func refreshMarkerPointer(_ event: NSEvent? = nil) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window), !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream, from: nil)
        guard markerCursorBand.intersection(bounds).intersection(visibleRect).contains(point) else {
            if !(hoveredMarkerID.flatMap { markerInputs[$0] }?.hasActiveProjectedGesture ?? false) { clearMarkerPointer() }
            return
        }
        guard !markerInputs.values.contains(where: { $0.hasActiveProjectedGesture }) else { return }
        let id = inputOrder.reversed().first { markerInputs[$0]?.clickBounds.contains(point) == true }
        if id != hoveredMarkerID { clearMarkerPointer(); hoveredMarkerID = id }
        if let id { markerInputs[id]?.updateProjectedPointer(at: point) }
    }
    override func mouseMoved(with event: NSEvent) { refreshMarkerPointer(event) }
    override func mouseEntered(with event: NSEvent) { refreshMarkerPointer(event) }
    override func cursorUpdate(with event: NSEvent) { refreshMarkerPointer(event) }
    override func mouseExited(with event: NSEvent) {
        guard !markerInputs.values.contains(where: { $0.hasActiveProjectedGesture }) else { return }
        clearMarkerPointer()
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { clearMarkerPointer() }
        guard blocked, preview != nil else { return }
        preview = nil; prepareMarkers(); reproject()
    }
    func configure(_ value: NativeTimelineHeaderConfiguration?) {
        if configuration?.song.id != value?.song.id || !(value?.song.markers ?? []).contains(where: { $0.id == preview?.id }) {
            preview = nil
        }
        let nextIDs = Set((value?.song.markers ?? []).map(\.id))
        for id in Array(markerInputs.keys) where !nextIDs.contains(id) {
            if hoveredMarkerID == id { clearMarkerPointer() }
            markerInputs.removeValue(forKey: id)?.removeFromSuperview()
            markerLastUsed.removeValue(forKey: id)
        }
        configuration = value
        let nextTop = CGFloat(value?.lanes.count ?? 0) * 16
        if markerBandTop != nextTop { markerBandTop = nextTop; window?.invalidateCursorRects(for: self) }
        updateTrackingAreas()
        regionsInput.configure(value?.regionTargets ?? [])
        regions = value.map { value in
            value.song.parts.enumerated().compactMap { index, part in
                guard part.parentRegionID == nil else { return nil }
                let color = part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965)
                return Region(part: part, lane: value.lanes.lanes[part.id] ?? 0,
                    color: color, fill: NativeTimelineHeaderColors.color(color),
                    boundaries: [(6, NativeTimelineHeaderColors.color(color, alpha: 0.14)),
                        (3, NativeTimelineHeaderColors.color(color, alpha: 0.30)),
                        (2, NativeTimelineHeaderColors.color(color, alpha: 1))], name: part.displayName,
                    identifier: value.parentIDs.contains(part.id) ? JarasLocalization.string("Special") : String(format: "%dst  %02d", part.semitones, index + 1))
            }
        } ?? []
        prepareMarkers()
        if value == nil {
            for view in markerInputs.values { view.removeFromSuperview() }
            clearMarkerPointer()
            markerInputs.removeAll(); markerLastUsed.removeAll(); inputOrder.removeAll(); projectedMarkers.removeAll()
            updateTrackingAreas()
            updateDrawingLayers()
        }
    }
    private func prepareMarkers() {
        // Structural configuration, local drag previews and cancellation all
        // invalidate the retained drawing, even if its geometry stays fixed.
        contentRevision &+= 1
        guard let value = configuration else { lanes.removeAll(); return }
        let top = CGFloat(value.lanes.count) * 16
        let ordered = [false, true].flatMap { tempo in (value.song.markers ?? []).filter { $0.isTempo == tempo } }
        markerInputRanks = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        markerOrderIsDirty = true
        lanes = [false, true].map { tempo in
            let markers = (value.song.markers ?? []).filter { $0.isTempo == tempo }.map { marker in
                preview?.id == marker.id ? preview! : marker
            }
            var displayedSong = value.song; displayedSong.markers = markers
            let labels = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, value.song.markerLabel($0)) })
            let widths = Dictionary(uniqueKeysWithValues: markers.map { marker in
                (marker.id, Double(ceil(NativeTimelineHeaderText.label(labels[marker.id] ?? "", color: 0xffffff, scale: displayScale)?.width ?? 0)))
            })
            let colors = Dictionary(uniqueKeysWithValues: markers.map { marker in
                (marker.id, MarkerColors(fill: NativeTimelineHeaderColors.color(marker.color),
                    stem: NativeTimelineHeaderColors.color(tempo ? 0x999999 : marker.color,
                        alpha: marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)))
            })
            let ends = tempo ? [:] : displayedSong.markerRegionEnds
            let inputWidths = Dictionary(uniqueKeysWithValues: markers.map {
                ($0.id, MarkerTargetLabelWidths.shared.width(labels[$0.id] ?? ""))
            })
            return MarkerLane(labels: labels, geometry: NativeTimelineMarkerLayout(markers, drawingWidths: widths,
                    inputWidths: inputWidths, regionEnds: ends),
                colors: colors, top: top + (tempo ? markerLaneHeight : 0), tempo: tempo)
        }
    }
    private func reproject() {
        project(scale: scale, viewport: viewport, layoutWidth: layoutWidth, displayScale: displayScale)
    }
    func project(scale: CGFloat, viewport: CGRect, layoutWidth: CGFloat, displayScale: CGFloat) {
        #if CATLIVE_RENDER_DIAGNOSTICS
        if TimelineRenderDiagnosticBypass.contains("markers") { return }
        #endif
        guard scale.isFinite, scale > 0 else { return }
        self.scale = scale; self.viewport = viewport; self.layoutWidth = layoutWidth
        if self.displayScale != displayScale { self.displayScale = displayScale; prepareMarkers() }
        // The trailing reserve covers every unpublished position in this
        // bucket; changing zoom/anchor inside it must not resize the backing.
        let nextTile = TimelineHeaderViewport.covering(offset: floor(viewport.minX / 512) * 512,
            width: viewport.width, height: viewport.height)
        let projection = Projection(tile: nextTile, scale: scale, layoutWidth: layoutWidth,
            displayScale: displayScale, contentRevision: contentRevision)
        // Keep the live viewport above for a later preview/cancel rerender, but
        // reuse pixels and input commands during continuous in-bucket scrolling.
        guard lastProjection != projection else { return }
        lastProjection = projection
        tile = nextTile
        // Keep the AppKit container in document coordinates. Moving an ancestor
        // NSView for each prepared tile invalidates tracking throughout the
        // window; only the bounded drawing layer needs the tile translation.
        let inputFrame = CGRect(x: 0, y: 0, width: layoutWidth, height: viewport.height)
        if frame != inputFrame { frame = inputFrame }
        if regionsInput.frame != inputFrame { regionsInput.frame = inputFrame }
        regionsInput.project(scale: scale, viewport: tile)
        projectedMarkers.removeAll(keepingCapacity: true)
        var visibleInputs: [(MarkerTargetGeometry, CGFloat)] = []
        for lane in lanes {
            lane.geometry.forEachProjection(scale: scale, viewport: tile, draggingID: preview?.id) { marker, x, width, target in
                let rect = CGRect(x: x, y: lane.top + 1, width: width, height: markerLaneHeight - 2)
                if rect.intersects(tile) || (x >= tile.minX - 1 && x <= tile.maxX + 1) {
                    if let colors = lane.colors[marker.id] {
                        projectedMarkers.append(ProjectedMarker(marker: marker, label: lane.labels[marker.id] ?? "",
                            colors: colors, rect: rect, top: lane.top, tempo: lane.tempo))
                    }
                }
                #if CATLIVE_RENDER_DIAGNOSTICS
                if let target, !TimelineRenderDiagnosticBypass.contains("marker-inputs") { visibleInputs.append((target, lane.top)) }
                #else
                if let target { visibleInputs.append((target, lane.top)) }
                #endif
            }
        }
        let visibleIDs = visibleInputs.map { $0.0.id }, keep = Set(visibleIDs)
        inputGeneration &+= 1
        var inactive: [UUID] = []
        for (id, view) in markerInputs where !keep.contains(id) {
            if hoveredMarkerID == id, !view.hasActiveProjectedGesture { clearMarkerPointer() }
            view.projectInput(.null, stableSize: inputFrame.size)
            if !view.hasActiveProjectedGesture { inactive.append(id) }
        }
        // Retain a bounded pool across zoom/culling. An inactive logical target
        // has no cursor/input area and causes no AppKit hierarchy mutation.
        if inactive.count > 128 {
            inactive.sort { (markerLastUsed[$0] ?? 0) < (markerLastUsed[$1] ?? 0) }
            for id in inactive.prefix(inactive.count - 128) {
                if hoveredMarkerID == id { clearMarkerPointer() }
                markerInputs.removeValue(forKey: id)?.removeFromSuperview()
                markerLastUsed.removeValue(forKey: id)
                markerOrderIsDirty = true
            }
        }
        for (target, top) in visibleInputs {
            let view: MarkerEditClickView
            if let existing = markerInputs[target.id] { view = existing }
            else {
                view = MarkerEditClickView()
                view.projectInput(.null, stableSize: inputFrame.size)
                markerInputs[target.id] = view; addSubview(view)
                markerOrderIsDirty = true
            }
            let rect = CGRect(x: target.left, y: top, width: target.width, height: markerLaneHeight)
            view.projectInput(rect, stableSize: inputFrame.size)
            markerLastUsed[target.id] = inputGeneration
            configure(view, marker: target.marker, scale: scale)
        }
        let ids = markerOrderIsDirty
            ? markerInputs.keys.sorted { (markerInputRanks[$0] ?? -1) < (markerInputRanks[$1] ?? -1) } : inputOrder
        markerOrderIsDirty = false
        if inputOrder != ids {
            var order = Dictionary(uniqueKeysWithValues: ids.enumerated().compactMap { index, id in
                markerInputs[id].map { (ObjectIdentifier($0), index + 1) }
            })
            order[ObjectIdentifier(regionsInput)] = 0
            withUnsafeMutablePointer(to: &order) { pointer in
                sortSubviews({ left, right, context in
                    let order = context!.assumingMemoryBound(to: [ObjectIdentifier: Int].self).pointee
                    let a = order[ObjectIdentifier(left)] ?? 0, b = order[ObjectIdentifier(right)] ?? 0
                    return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
                }, context: pointer)
            }
            inputOrder = ids
        }
        refreshMarkerPointer()
        updateDrawingLayers()
    }
    private func configure(_ view: MarkerEditClickView, marker: TimelineMarker, scale: CGFloat) {
        guard let value = configuration else { return }
        view.action = { value.edit(marker) }
        view.optionClick = {
            if marker.unifiedRegionID == nil, marker.sourceRegionID == nil { value.delete(marker.id) }
        }
        view.seek = { value.seek(marker) }
        view.drag = value.song.canDragMarker(marker) ? { [weak self] delta, ended in
            guard let self else { return }
            var moved = marker
            moved.position = value.song.markerDragPosition(marker, to: max(0, marker.position + Double(delta) / scale),
                pixelsPerSecond: scale, free: NSEvent.modifierFlags.contains(.shift))
            if ended { value.move(moved); self.preview = nil }
            else { self.preview = moved }
            self.prepareMarkers(); self.reproject()
        } : nil
    }
    private func updateDrawingLayers() {
        // Join the existing frame transaction, just like the native ruler.
        // No synchronous commit, display-list recording or viewport bitmap.
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        let visible = CGRect(origin: .zero, size: tile.size)
        if drawingLayer.frame != tile { drawingLayer.frame = tile }
        for group in [regionLayer, markerLayer, boundaryLayer] {
            if group.frame != visible { group.frame = visible }
        }
        var regionOrder: [UUID] = [], markerOrder: [UUID] = [], boundaryOrder: [UUID] = []
        for region in regions {
            let part = region.part
            let rect = CGRect(x: part.startTime * scale, y: CGFloat(region.lane) * 16,
                width: max(1, (part.endTime - part.startTime) * scale), height: 16).offsetBy(dx: -tile.minX, dy: 0)
            guard rect.intersects(visible) else { continue }
            let node = regionLayers[part.id] ?? RegionLayers()
            regionLayers[part.id] = node; regionOrder.append(part.id)
            let fillRect = rect.intersection(visible)
            if node.fill.frame != fillRect { node.fill.frame = fillRect }
            if node.fill.backgroundColor !== region.fill { node.fill.backgroundColor = region.fill }
            if let identifier = TimelineStaticText.label(region.identifier, style: .regionIdentifier, displayScale: displayScale), rect.width >= identifier.width + 8 {
                let point = CGPoint(x: rect.maxX - 4 - identifier.width - 1, y: rect.minY + 2)
                if CGRect(origin: point, size: identifier.size).intersects(visible) {
                    node.identifier.update(image: identifier.image, size: identifier.size,
                        point: point, clip: rect, radius: 0, scale: displayScale)
                } else { node.identifier.hide() }
                projectName(region.name, rect: CGRect(x: rect.minX, y: rect.minY,
                    width: max(0, rect.width - identifier.width - 8), height: rect.height),
                    color: 0xffffff, centered: false, into: node.name)
            } else { node.identifier.hide(); node.name.hide() }
        }
        for item in projectedMarkers {
            let x = item.marker.position * scale - tile.minX
            let node = markerLayers[item.marker.id] ?? MarkerLayers()
            markerLayers[item.marker.id] = node; markerOrder.append(item.marker.id)
            if x >= -1, x <= visible.maxX + 1 {
                let top = item.top + markerLaneHeight
                node.updateStem(frame: CGRect(x: x - 0.5, y: top, width: 1, height: max(0, tile.height - top)),
                    tempo: item.tempo, color: item.colors.stem, scale: displayScale)
            } else { node.hideStem() }
            let rect = item.rect.offsetBy(dx: -tile.minX, dy: 0)
            guard rect.intersects(visible) else { node.hideFlag(); node.name.hide(); continue }
            let linked = item.marker.sourceRegionID != nil || item.marker.unifiedRegionID != nil
            let kind = item.tempo ? 3 : (item.marker.isSection ? 1 : (linked ? 2 : 0))
            node.updateFlag(rect: rect, visible: visible, kind: kind,
                fill: item.tempo ? displayColor : item.colors.fill,
                stroke: item.tempo ? lineColor : (kind == 2 ? linkedOutlineColor : nil), scale: displayScale)
            projectName(item.label, rect: rect, color: item.tempo ? 0xffffff : 0, centered: item.tempo, into: node.name)
        }
        for region in regions {
            let left = CGFloat(region.part.startTime) * scale - tile.minX
            let right = CGFloat(region.part.endTime) * scale - tile.minX
            let edges = [left, right].filter { $0 >= -6 && $0 <= visible.maxX + 6 }
            guard !edges.isEmpty else { continue }
            let top = CGFloat(region.lane + 1) * 16
            let clip = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, tile.height - top)).intersection(visible)
            guard !clip.isNull, !clip.isEmpty else { continue }
            let node = boundaryLayers[region.part.id] ?? BoundaryLayers()
            boundaryLayers[region.part.id] = node; boundaryOrder.append(region.part.id)
            node.update(frame: clip, edges: edges, colors: region.boundaries, scale: displayScale)
        }
        let regionSet = Set(regionOrder), markerSet = Set(markerOrder), boundarySet = Set(boundaryOrder)
        for id in Array(regionLayers.keys) where !regionSet.contains(id) { regionLayers.removeValue(forKey: id)?.root.removeFromSuperlayer() }
        for id in Array(markerLayers.keys) where !markerSet.contains(id) { markerLayers.removeValue(forKey: id)?.root.removeFromSuperlayer() }
        for id in Array(boundaryLayers.keys) where !boundarySet.contains(id) { boundaryLayers.removeValue(forKey: id)?.root.removeFromSuperlayer() }
        if regionLayerOrder != regionOrder {
            regionLayer.sublayers = regionOrder.compactMap { regionLayers[$0]?.root }; regionLayerOrder = regionOrder
        }
        if markerLayerOrder != markerOrder {
            markerLayer.sublayers = markerOrder.compactMap { markerLayers[$0]?.root }; markerLayerOrder = markerOrder
        }
        if boundaryLayerOrder != boundaryOrder {
            boundaryLayer.sublayers = boundaryOrder.compactMap { boundaryLayers[$0]?.root }; boundaryLayerOrder = boundaryOrder
        }
    }
    private func projectName(_ name: String, rect: CGRect, color: UInt32, centered: Bool, into node: LabelLayer) {
        let available = rect.width - 8
        guard available >= 10, rect.intersects(CGRect(origin: .zero, size: tile.size)) else { node.hide(); return }
        let measure: (String) -> CGFloat = { NativeTimelineHeaderText.label($0, color: color, scale: self.displayScale)?.width ?? 0 }
        let metrics = TimelineNameMetrics.metrics(name, measure: measure)
        guard centered || rect.minX + 4 + min(available, metrics.fullWidth) >= 0,
              let displayed = metrics.fitting(name, width: available, measure: measure),
              let label = NativeTimelineHeaderText.label(displayed, color: color, scale: displayScale) else { node.hide(); return }
        let point = centered ? CGPoint(x: rect.midX - label.width / 2 - 1, y: rect.midY - label.size.height / 2)
            : CGPoint(x: rect.minX + 3, y: rect.minY + 2)
        node.update(image: label.image, size: label.size, point: point, clip: rect, radius: 3, scale: displayScale)
    }
}

/// Region commands are structural; their geometry follows the native projection.
/// Keep the existing input view (and its captured drag callback) across zoom frames.
@MainActor private struct NativeTimelineRegionTarget {
    let id: UUID
    let start: Double
    let end: Double
    let lane: Int
    let edgePadding: CGFloat
    let selected: Bool
    let pinned: Bool
    let input: RegionRightClick

    func frame(scale: CGFloat) -> CGRect {
        CGRect(x: start * scale - edgePadding,
            y: CGFloat(lane) * 16 - (edgePadding > 0 ? 4 : 0),
            width: max(1, (end - start) * scale) + edgePadding * 2,
            height: edgePadding > 0 ? 24 : 16)
    }
}

@MainActor private final class NativeTimelineRegionTargetsView: NSView, NativeTimelineInputObserver {
    private struct Mounted {
        let view: RegionRightClickView
        let selection: CAShapeLayer
    }
    private var targets: [NativeTimelineRegionTarget] = []
    private var mounted: [UUID: Mounted] = [:]
    private var mountedOrder: [UUID] = []
    private var inactive: [Mounted] = []
    private static let inactiveLimit = 64
    private var activeDrags: Set<UUID> = []
    private var hoveredID: UUID?
    private var tracking: NSTrackingArea?
    private var cursorBandHeight: CGFloat = 0
    private var scale: CGFloat = 0
    private var viewport = CGRect.zero
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activeDrags.removeAll()
        if window != nil { NativeTimelineInputGate.shared.add(self) }
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { activeDrags.removeAll(); clearProjectedPointer() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = cursorBand.intersection(bounds)
        guard tracking?.rect != rect else { return }
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: rect,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); tracking = area
    }
    private var cursorBand: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: cursorBandHeight)
    }
    override func resetCursorRects() {
        guard !NativeTimelineInputGate.shared.isBlocked(window), window?.attachedSheet == nil else { return }
        let visible = visibleRect.intersection(bounds).intersection(cursorBand)
        if !visible.isEmpty { addCursorRect(visible, cursor: .arrow) }
    }
    private func clearProjectedPointer() {
        if let hoveredID { mounted[hoveredID]?.view.updateProjectedPointer(at: nil) }
        hoveredID = nil
    }
    fileprivate func refreshProjectedPointer(_ event: NSEvent? = nil) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window), !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream, from: nil)
        guard cursorBand.intersection(bounds).intersection(visibleRect).contains(point) else {
            // Zooming from the body must not scan every region just to discover
            // that the pointer is outside their lane. Keep an active drag's
            // cursor while its captured mouse is outside that lane.
            let hoveredGesture = hoveredID.flatMap { mounted[$0] }?.view.hasActiveProjectedGesture ?? false
            if activeDrags.isEmpty, !hoveredGesture { clearProjectedPointer() }
            return
        }
        guard !mounted.values.contains(where: { $0.view.hasActiveProjectedGesture }) else { return }
        let id = mountedOrder.reversed().first { mounted[$0]?.view.projectedInputBounds.contains(point) == true }
        if id != hoveredID { clearProjectedPointer(); hoveredID = id }
        if let id { mounted[id]?.view.updateProjectedPointer(at: point) }
    }
    override func mouseMoved(with event: NSEvent) { refreshProjectedPointer(event) }
    override func mouseEntered(with event: NSEvent) { refreshProjectedPointer(event) }
    override func cursorUpdate(with event: NSEvent) { refreshProjectedPointer(event) }
    override func mouseExited(with event: NSEvent) {
        guard !mounted.values.contains(where: { $0.view.hasActiveProjectedGesture }) else { return }
        clearProjectedPointer()
    }
    func configure(_ targets: [NativeTimelineRegionTarget]) {
        let oldBand = cursorBand
        self.targets = targets
        cursorBandHeight = targets.reduce(CGFloat.zero) { max($0, $1.frame(scale: 1).maxY) }
        if cursorBand != oldBand { updateTrackingAreas(); window?.invalidateCursorRects(for: self) }
        let keep = Set(targets.map(\.id))
        activeDrags.formIntersection(keep)
        for id in Array(mounted.keys) where !keep.contains(id) {
            // Structural removal cancels a captured drag. An open menu keeps
            // its old action target reserved until its modal loop finishes.
            mounted[id]?.view.timelineInputGateChanged(blocked: true)
            retire(id)
        }
        // Replace live commands only on a structural update. RegionRightClickView
        // deliberately keeps the callback captured at mouseDown during previews.
        for target in targets {
            if let entry = mounted[target.id] { configure(entry.view, for: target) }
        }
        if targets.isEmpty { clearProjectedPointer(); mountedOrder.removeAll() }
        trimInactive()
    }
    private func retire(_ id: UUID) {
        guard let entry = mounted[id], !entry.view.hasActiveProjectedGesture else { return }
        if hoveredID == id { clearProjectedPointer() }
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        let reusable = entry.view.deactivateProjectedInput()
        entry.selection.isHidden = true
        entry.selection.path = nil
        guard reusable else { return }
        mounted.removeValue(forKey: id)
        inactive.append(entry)
    }
    private func trimInactive() {
        let excess = inactive.count - Self.inactiveLimit
        guard excess > 0 else { return }
        for entry in inactive.prefix(excess) { entry.view.removeFromSuperview() }
        inactive.removeFirst(excess)
    }
    private func configure(_ view: RegionRightClickView, for target: NativeTimelineRegionTarget) {
        let input = target.input
        view.edit = input.edit; view.detectBPM = input.detectBPM
        view.unify = input.unify; view.disunify = input.disunify
        view.delete = input.delete; view.exportAudio = input.exportAudio; view.seek = input.seek; view.resizable = input.resizable
        view.projectedInteractionEnded = { [weak self] in
            guard let self else { return }
            self.project(scale: self.scale, viewport: self.viewport)
        }
        view.drag = { [weak self] delta, ended, edge in
            self?.activeDrags.insert(target.id)
            input.drag(delta, ended, edge)
            if ended, let self {
                self.activeDrags.remove(target.id)
                self.project(scale: self.scale, viewport: self.viewport)
            }
        }
    }
    func project(scale: CGFloat, viewport: CGRect) {
        #if CATLIVE_RENDER_DIAGNOSTICS
        if TimelineRenderDiagnosticBypass.contains("region-inputs") { return }
        #endif
        guard scale.isFinite, scale > 0 else { return }
        self.scale = scale; self.viewport = viewport
        let first = max(0, viewport.minX - 1024) / scale
        let last = (viewport.maxX + 1536) / scale
        let visible = targets.filter {
            $0.pinned || activeDrags.contains($0.id) ||
                mounted[$0.id]?.view.isReservedForProjectionReuse == true ||
                ($0.start <= last && $0.end >= first)
        }
        let ids = visible.map(\.id), keep = Set(ids)
        for id in Array(mounted.keys) where !keep.contains(id) {
            retire(id)
        }
        let oldActions = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(oldActions) }
        for target in visible {
            let entry: Mounted
            if let retained = mounted[target.id] { entry = retained }
            else {
                if let retained = inactive.popLast() { entry = retained }
                else {
                    let view = RegionRightClickView()
                    view.wantsLayer = true
                    view.layer?.masksToBounds = true
                    let selection = CAShapeLayer()
                    selection.fillColor = nil
                    selection.strokeColor = NSColor.white.cgColor
                    selection.lineWidth = 1.5
                    view.layer?.addSublayer(selection)
                    entry = Mounted(view: view, selection: selection)
                }
                mounted[target.id] = entry
                configure(entry.view, for: target)
                if entry.view.superview !== self { addSubview(entry.view) }
            }
            let frame = target.frame(scale: scale)
            entry.view.projectRegion(frame: frame, viewport: viewport, stableInputSize: bounds.size)
            entry.selection.isHidden = !target.selected
            if target.selected {
                // Retain the complete outline in local coordinates and clip it
                // at the bounded input layer. No border is invented where the
                // actual region continues beyond the prepared header tile.
                let input = entry.view.projectedInputBounds
                let rect = CGRect(x: frame.minX - input.minX + target.edgePadding,
                    y: target.edgePadding > 0 ? 4 : 0,
                    width: max(1, frame.width - target.edgePadding * 2), height: 16).insetBy(dx: 0.75, dy: 0.75)
                if entry.selection.frame != input { entry.selection.frame = input }
                entry.selection.masksToBounds = true
                entry.selection.path = CGPath(rect: rect, transform: nil)
            }
        }
        trimInactive()
        if mountedOrder != ids {
            // Preserve creation-order overlap precedence when panning reveals a
            // region before an already-mounted one, without remounting its view.
            var order = Dictionary(uniqueKeysWithValues: ids.enumerated().compactMap { index, id in
                mounted[id].map { (ObjectIdentifier($0.view), index) }
            })
            withUnsafeMutablePointer(to: &order) { pointer in
                sortSubviews({ left, right, context in
                    let order = context!.assumingMemoryBound(to: [ObjectIdentifier: Int].self).pointee
                    let a = order[ObjectIdentifier(left)] ?? 0, b = order[ObjectIdentifier(right)] ?? 0
                    return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
                }, context: pointer)
            }
            mountedOrder = ids
        }
        refreshProjectedPointer()
    }
}

@MainActor private struct NativeTimelineBaseStyle {
    let displayScale: CGFloat
    let gridlines: Bool
    let background: CGColor
    let primary: CGColor
    let secondary: CGColor
    let panel: CGColor
    let row: CGColor
    let headerLine: CGColor
}

private struct NativeTimelineBaseBackground: View {
    let controller: NativeTimelineBaseController
    let state: TimelineZoomState
    let configuration: NativeTimelineBaseConfiguration
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var background = AppearanceColor.shared("jaras.timeline.background", default: TimelineAppearanceDefaults.background)
    @ObservedObject private var primary = AppearanceColor.shared("jaras.timeline.primaryGrid", default: TimelineAppearanceDefaults.primaryGrid)
    @ObservedObject private var secondary = AppearanceColor.shared("jaras.timeline.secondaryGrid", default: TimelineAppearanceDefaults.secondaryGrid)
    @AppStorage("jaras.timeline.gridlines") private var gridlines = GlobalProjectTiming.load()?.settings.divisions != 0
    var body: some View {
        NativeTimelineBaseBackgroundMount(controller: controller, state: state, configuration: configuration,
            style: NativeTimelineBaseStyle(displayScale: displayScale, gridlines: gridlines,
                background: NSColor(Color(hex: UInt32(background.value))).cgColor,
                primary: NSColor(Color(hex: UInt32(primary.value))).cgColor,
                secondary: NSColor(Color(hex: UInt32(secondary.value)).opacity(0.85)).cgColor,
                panel: NSColor(JarasTheme.panel).cgColor, row: NSColor(JarasTheme.line.opacity(0.8)).cgColor,
                headerLine: NSColor(JarasTheme.line).cgColor))
    }
}

private struct NativeTimelineBaseBackgroundMount: NSViewRepresentable {
    let controller: NativeTimelineBaseController
    let state: TimelineZoomState
    let configuration: NativeTimelineBaseConfiguration
    let style: NativeTimelineBaseStyle
    func makeNSView(context: Context) -> NativeTimelineBaseMountView { controller.makeMount(.background) }
    func updateNSView(_ view: NativeTimelineBaseMountView, context: Context) {
        controller.configure(configuration, style: style, state: state)
        controller.observeScroll()
    }
}
private struct NativeTimelineBaseSlot: NSViewRepresentable {
    let controller: NativeTimelineBaseController
    let kind: NativeTimelineBaseMountView.Kind
    func makeNSView(context: Context) -> NativeTimelineBaseMountView { controller.makeMount(kind) }
    func updateNSView(_ view: NativeTimelineBaseMountView, context: Context) { controller.observeScroll() }
}
private final class NativeTimelineBaseMountView: NSView {
    enum Kind { case background, ruler, foreground }
    weak var controller: NativeTimelineBaseController?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    // The controller positions its children in document coordinates. The last
    // assigned frame is not a minimum size: deleting regions can shrink the
    // document, and retaining that minimum centers/clips the old native plane.
    override var fittingSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.observeScroll()
        if window == nil { controller?.detachIfUnused() }
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); controller?.observeScroll() }
}

@MainActor private final class NativeTimelineBaseController {
    private let backdrop = TimelineNativeGridView()
    private let audioBody = NativeTimelineAudioBodyView()
    private let ruler = TimelineNativeRulerView()
    private let rulerInput = TimelineRulerView()
    private let header = NativeTimelineHeaderView()
    private let needles = NativeTimelineNeedlesView()
    private let selection = GridSelectionView()
    private let wheel = TimelineWheelView()
    private let documentSize = GridDocumentSizeView()
    private let selectionPin = NativeTimelinePinnedView()
    private let needlePin = NativeTimelinePinnedView()
    private weak var backgroundMount: NativeTimelineBaseMountView?
    private weak var rulerMount: NativeTimelineBaseMountView?
    private weak var foregroundMount: NativeTimelineBaseMountView?
    private weak var horizontal: NSClipView?
    private weak var vertical: NSClipView?
    private var scrollObservers: [NSObjectProtocol] = []
    private weak var zoomState: TimelineZoomState?
    private var zoomSubscription: AnyCancellable?
    private var configuration: NativeTimelineBaseConfiguration?
    private var style: NativeTimelineBaseStyle?
    private var zoom = TimelineViewportPreferences.zoom
    private var updating = false
    private var configuring = false
    private var preparedHorizontalOffset: CGFloat?
    private var preparedVerticalOffset: CGFloat?
    private struct Projection: Equatable {
        let revision: UInt64
        let zoom: Double
        let viewport: CGRect
    }
    private var revision: UInt64 = 0
    private var lastProjection: Projection?
    private var lastBackdropProjection: Projection?
    private var lastRulerProjection: Projection?
    private(set) var pixelsPerSecond: CGFloat = 10 * TimelineViewportPreferences.zoom

    init() {
        selectionPin.pinHorizontally = true; selectionPin.hostHandlesInput = true
        selectionPin.host = selection; selectionPin.addSubview(selection)
        needlePin.hostHandlesInput = true
        needlePin.host = needles; needlePin.addSubview(needles)
    }
    func makeMount(_ kind: NativeTimelineBaseMountView.Kind) -> NativeTimelineBaseMountView {
        let mount = NativeTimelineBaseMountView()
        mount.controller = self
        switch kind {
        case .background:
            backgroundMount = mount
            mount.addSubview(backdrop); mount.addSubview(audioBody); mount.addSubview(wheel); mount.addSubview(documentSize)
        case .ruler:
            rulerMount = mount
            mount.addSubview(ruler); mount.addSubview(header); mount.addSubview(rulerInput)
        case .foreground:
            foregroundMount = mount
            mount.addSubview(selectionPin); mount.addSubview(needlePin)
        }
        return mount
    }
    func configure(_ value: NativeTimelineBaseConfiguration, style: NativeTimelineBaseStyle, state: TimelineZoomState) {
        configuring = true
        defer { configuring = false }
        revision &+= 1
        configuration = value; self.style = style
        documentSize.hostedProjectionDidLayout = { [weak self] in self?.commitHostedProjection() ?? true }
        audioBody.configure(value.audioBody)
        header.configure(value.header)
        zoom = state.value; pixelsPerSecond = zoom * 10
        value.input.projected(pixelsPerSecond: pixelsPerSecond, itemGuide: value.itemGuide(pixelsPerSecond)).apply(to: selection)
        wheel.horizontalOffsetChanged = value.horizontalOffsetChanged
        wheel.verticalOffsetChanged = value.verticalOffsetChanged
        wheel.interactionBlocked = value.interactionBlocked
        wheel.extend = value.extend
        wheel.position = value.editPosition / value.extent
        wheel.livePosition = value.livePosition
        wheel.modelUnitWidth = value.extent * 10
        wheel.changeTrackHeight = { [weak self] factor, smooth in
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { self?.configuration?.changeTrackHeight(factor, smooth) }
        }
        wheel.changeZoom = { [weak self, weak state] next, offset in
            guard let self, let state else { return }
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.configuration?.horizontalOffsetChanged(floor(offset / 512) * 512)
                state.value = next
            }
        }
        rulerInput.markerCursor = { MarkerEditClickView.usesMoveCursor(for: $0) }
        rulerInput.extend = value.extend; rulerInput.selectTime = value.selectTime
        rulerInput.selectedTime = value.selectedTime; rulerInput.resizeTime = value.resizeTime
        rulerInput.seek = value.rulerSeek
        needles.configure(show: value.show, size: CGSize(width: value.extent * pixelsPerSecond, height: value.contentHeight),
            rulerHeight: value.rulerHeight, verticalOffset: 0, extent: value.extent, seek: value.needleSeek, marker: value.marker)
        if zoomState !== state {
            zoomSubscription = nil; zoomState = state
            zoomSubscription = state.$value.removeDuplicates().sink { [weak self] next in
                // @Published emits before its stored property changes.
                self?.project(zoom: next)
            }
        } else { project(zoom: state.value) }
        observeScroll()
        wheel.focus(request: value.focusRequest, x: value.focusTime.map { $0 * pixelsPerSecond })
    }
    func observeScroll() {
        // Representable updates and native mount/layout callbacks arrive here.
        // Their graph is still being evaluated, so publish gate changes later.
        let wasConfiguring = configuring
        configuring = true
        defer { configuring = wasConfiguring }
        guard let mount = backgroundMount else { return }
        var scrolls: [NSScrollView] = [], ancestor = mount.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { scrolls.append(scroll) }
            ancestor = view.superview
        }
        let nextHorizontal = scrolls.first?.contentView
        let nextVertical = scrolls.count > 1 ? scrolls.last?.contentView : nil
        if horizontal !== nextHorizontal || vertical !== nextVertical {
            for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
            scrollObservers.removeAll()
            horizontal = nextHorizontal; vertical = nextVertical
            for clip in [nextHorizontal, nextVertical].compactMap({ $0 }) {
                clip.postsBoundsChangedNotifications = true
                scrollObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Bounds may be delivered from NSScrollView.tile while
                        // hosting lays out. User scrolls already prepare the gate.
                        let wasConfiguring = self.configuring
                        self.configuring = true
                        defer { self.configuring = wasConfiguring }
                        if let x = self.preparedHorizontalOffset, abs((self.horizontal?.bounds.minX ?? 0) - x) < 0.001 {
                            self.preparedHorizontalOffset = nil
                        }
                        if let y = self.preparedVerticalOffset, abs((self.vertical?.bounds.minY ?? 0) - y) < 0.001 {
                            self.preparedVerticalOffset = nil
                        }
                        self.project(zoom: self.zoom)
                    }
                })
            }
        }
        wheel.observeHorizontalScroll(); wheel.observeVerticalScroll()
        (horizontal?.superview as? GridNativeScrollView)?.prepareHostedHorizontalScroll = { [weak self] x in
            self?.prepareHostedViewport(x: x) ?? false
        }
        (vertical?.superview as? GridNativeScrollView)?.prepareHostedVerticalScroll = { [weak self] y in
            self?.prepareHostedViewport(y: y) ?? false
        }
        selectionPin.observeScroll(); needlePin.observeScroll(); selection.observeHeaderScroll()
        project(zoom: zoom)
    }
    func detachIfUnused() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundMount?.window == nil, self.rulerMount?.window == nil, self.foregroundMount?.window == nil else { return }
            self.zoomSubscription = nil; self.zoomState = nil
            self.configuration = nil; self.style = nil
            self.documentSize.hostedProjectionDidLayout = nil
            (self.horizontal?.superview as? GridNativeScrollView)?.prepareHostedHorizontalScroll = nil
            (self.vertical?.superview as? GridNativeScrollView)?.prepareHostedVerticalScroll = nil
            self.preparedHorizontalOffset = nil; self.preparedVerticalOffset = nil
            self.audioBody.configure(nil)
            self.header.configure(nil)
            self.wheel.horizontalOffsetChanged = nil; self.wheel.verticalOffsetChanged = nil
            self.wheel.extend = nil; self.wheel.livePosition = nil; self.wheel.changeTrackHeight = nil; self.wheel.changeZoom = nil
            self.rulerInput.extend = nil; self.rulerInput.seek = nil; self.rulerInput.selectTime = nil
            self.rulerInput.selectedTime = nil; self.rulerInput.resizeTime = nil
            GridSelectionInput(origin: .zero, headerHeight: 0, items: [], selected: [],
                selectionChanged: { _ in }, mute: { _ in }, move: { _, _, _, _ in }, seek: { _, _ in }, createRegion: { _ in }).apply(to: self.selection)
            self.needles.stop()
            for observer in self.scrollObservers { NotificationCenter.default.removeObserver(observer) }
            self.scrollObservers.removeAll(); self.horizontal = nil; self.vertical = nil
        }
    }
    /// Runs before native scrolling exposes the destination. Keep these target
    /// origins through any hosting configure/layout that still sees old bounds.
    @discardableResult private func prepareHostedViewport(x: CGFloat? = nil, y: CGFloat? = nil) -> Bool {
        guard let value = configuration else { return false }
        let oldX = preparedHorizontalOffset ?? horizontal?.bounds.minX ?? 0
        let oldY = preparedVerticalOffset ?? vertical?.bounds.minY ?? 0
        if let x { preparedHorizontalOffset = x; value.horizontalOffsetChanged(floor(max(0, x) / 512) * 512) }
        if let y { preparedVerticalOffset = y; value.verticalOffsetChanged(y) }
        let viewport = CGRect(x: preparedHorizontalOffset ?? oldX, y: preparedVerticalOffset ?? oldY,
            width: horizontal?.bounds.width ?? value.viewportSize.width, height: value.viewportSize.height)
        let changed = updateHostedItems(viewport: viewport, width: value.extent * pixelsPerSecond)
        if y != nil {
            // A native band can expire inside a hosted 512-point bucket.
            // Prepare its destination synchronously without forcing host layout.
            audioBody.project(viewport: viewport,
                documentSize: CGSize(width: value.extent * pixelsPerSecond, height: value.contentHeight),
                scale: pixelsPerSecond)
        }
        let bucketChanged = x.map { floor(max(0, $0) / 512) != floor(max(0, oldX) / 512) } ??
            y.map { floor(max(0, $0) / 512) != floor(max(0, oldY) / 512) } ?? false
        return changed || bucketChanged
    }
    @discardableResult private func updateHostedItems(viewport: CGRect, width: CGFloat) -> Bool {
        guard let value = configuration else { return false }
        let active = value.hasHostedItems && (value.hostedItemCoverage?.containsItems(viewport: viewport,
            documentSize: CGSize(width: width, height: value.contentHeight), scale: pixelsPerSecond) ?? true)
        return value.hostedItemsGate.update(coverage: value.hostedItemCoverage, active: active, deferred: configuring)
    }
    private func requiresHostedProjection(width: CGFloat) -> Bool {
        guard let value = configuration else { return false }
        return value.hostedItemsGate.requiresHosted(coverage: value.hostedItemCoverage) ||
            value.hasHostedProjection() || width > value.layoutWidth
    }
    /// GridHostingView invokes this only after its complete SwiftUI graph has
    /// laid out. A stale layout cannot retire pixels or accept a newer anchor.
    private func commitHostedProjection() -> Bool {
        guard let value = configuration else { return true }
        let committed = value.hostedItemsGate.commitHostedProjection()
        documentSize.waitsForHostedProjection = requiresHostedProjection(width: value.extent * pixelsPerSecond)
        return committed
    }
    private func project(zoom: Double) {
        guard !updating, zoom.isFinite, zoom > 0, let value = configuration, let style else { return }
        updating = true
        defer { updating = false }
        if self.zoom != zoom { preparedHorizontalOffset = nil }
        self.zoom = zoom; pixelsPerSecond = zoom * 10
        let width = value.extent * pixelsPerSecond
        let nativeBounds = horizontal?.bounds ?? CGRect(origin: .zero, size: value.viewportSize)
        var left = max(0, preparedHorizontalOffset ?? nativeBounds.minX)
        let scroll = horizontal?.superview as? GridNativeScrollView
        if let anchor = scroll?.zoomAnchor {
            left = min(max(0, CGFloat(anchor.fraction) * width - anchor.screenX), max(0, width - nativeBounds.width))
        }
        let viewport = CGRect(x: left, y: max(0, preparedVerticalOffset ?? vertical?.bounds.minY ?? 0),
            width: max(0, nativeBounds.width), height: value.viewportSize.height)
        updateHostedItems(viewport: viewport, width: width)
        let projection = Projection(revision: revision, zoom: zoom, viewport: viewport)
        guard lastProjection != projection else { return }
        lastProjection = projection
        let fullFrame = CGRect(x: 0, y: 0, width: value.layoutWidth, height: value.contentHeight)
        if wheel.frame != fullFrame { wheel.frame = fullFrame }
        if selectionPin.frame != fullFrame { selectionPin.frame = fullFrame }
        if needlePin.frame != fullFrame { needlePin.frame = fullFrame }
        let selectionSize = value.viewportSize
        if selection.frame.size != selectionSize { selection.setFrameSize(selectionSize) }
        value.input.applyProjection(to: selection, pixelsPerSecond: pixelsPerSecond, itemGuide: value.itemGuide(pixelsPerSecond))
        let needleSize = CGSize(width: width, height: value.contentHeight)
        if needles.frame.size != fullFrame.size { needles.setFrameSize(fullFrame.size) }
        needles.updateProjection(size: needleSize, rulerHeight: value.rulerHeight, extent: value.extent)
        rulerInput.documentWidth = width
        let rulerFrame = CGRect(x: 0, y: value.rulerHeight - barLaneHeight, width: fullFrame.width, height: barLaneHeight)
        if rulerInput.frame != rulerFrame { rulerInput.frame = rulerFrame }
        documentSize.documentSize = CGSize(width: width, height: value.contentHeight)
        documentSize.hostingWidth = max(width, value.layoutWidth)
        let nativeOnly = !requiresHostedProjection(width: width)
        documentSize.waitsForHostedProjection = !nativeOnly
        documentSize.applyDocumentSize()
        wheel.cursorX = value.editPosition * pixelsPerSecond
        wheel.acceptRenderedZoom(zoom)
        let tile = TimelineCanvasCoverage.preparedRect(visibleRect: viewport, documentSize: CGSize(width: width, height: value.contentHeight))
        let backdropProjection = Projection(revision: revision, zoom: zoom, viewport: tile)
        // Native scrolling translates the prepared tile. Rebuild its grid only
        // when coverage, scale or structural/style content actually changes.
        #if CATLIVE_RENDER_DIAGNOSTICS
        let bypassBackdrop = TimelineRenderDiagnosticBypass.contains("backdrop")
        #else
        let bypassBackdrop = false
        #endif
        if !bypassBackdrop, lastBackdropProjection != backdropProjection {
            lastBackdropProjection = backdropProjection
            if backdrop.frame != tile { backdrop.frame = tile }
            let marks = style.gridlines ? TimelineTimeRuler.ticks(in: value.sections,
                from: max(0, Double(tile.minX / pixelsPerSecond)), to: Double(tile.maxX / pixelsPerSecond),
                pixelsPerSecond: pixelsPerSecond, divisions: value.divisions, labels: false) : []
            let bands = value.bands.compactMap { band -> TimelineNativeGridBand? in
                let rect = CGRect(x: tile.minX, y: band.rect.minY, width: tile.width, height: band.rect.height)
                return rect.intersects(tile) ? TimelineNativeGridBand(rect: rect, color: band.color) : nil
            }
            var rowLines = value.rows.offsets.map { value.rulerHeight + $0 }.filter { $0 >= tile.minY && $0 <= tile.maxY }
            let emptyStart = value.rulerHeight + value.rows.totalHeight
            let bottom = min(value.contentHeight, tile.maxY)
            if emptyStart <= bottom {
                let first = max(0, Int(floor((tile.minY - emptyStart) / value.rows.baseHeight)))
                let last = max(first, Int(ceil((bottom - emptyStart) / value.rows.baseHeight)))
                for row in first...last {
                    let y = emptyStart + CGFloat(row) * value.rows.baseHeight
                    if y <= bottom { rowLines.append(y) }
                }
            }
            backdrop.update(TimelineNativeGridBackdrop(viewport: tile, rulerHeight: value.rulerHeight, displayScale: style.displayScale,
                primary: marks.filter(\.primary).map { $0.time * pixelsPerSecond }, secondary: marks.filter { !$0.primary }.map { $0.time * pixelsPerSecond },
                bands: bands, background: style.background, primaryColor: style.primary, secondaryColor: style.secondary,
                horizontal: rowLines, rowColor: style.row))
        }
        let headerViewport = TimelineHeaderViewport.covering(offset: left, width: nativeBounds.width, height: value.rulerHeight)
        header.project(scale: pixelsPerSecond,
            viewport: CGRect(x: left, y: 0, width: nativeBounds.width, height: value.viewportSize.height),
            layoutWidth: value.layoutWidth, displayScale: style.displayScale)
        let headerTile = TimelineCanvasCoverage.preparedRect(visibleRect: headerViewport, documentSize: CGSize(width: width, height: value.rulerHeight))
        let rulerProjection = Projection(revision: revision, zoom: zoom, viewport: headerTile)
        #if CATLIVE_RENDER_DIAGNOSTICS
        let bypassRuler = TimelineRenderDiagnosticBypass.contains("ruler")
        #else
        let bypassRuler = false
        #endif
        if !bypassRuler, lastRulerProjection != rulerProjection {
            lastRulerProjection = rulerProjection
            if ruler.frame != headerTile { ruler.frame = headerTile }
            let regionHeight = CGFloat(value.regionLanes) * 16
            let barTop = regionHeight + markerLaneHeight + tempoLaneHeight
            let sample = TimelineTimeRuler.labelSample(through: value.extent)
            let labelWidth = TimelineStaticText.label(sample, style: .barNumber, displayScale: style.displayScale).map { Double($0.size.width) }
            let spacing = TimelineTimeRuler.labelSpacing(through: value.extent, measuredWidth: labelWidth, pixelsPerSecond: pixelsPerSecond)
            let ticks = TimelineTimeRuler.ticks(in: value.sections,
                from: max(0, Double((headerTile.minX - spacing) / pixelsPerSecond)), to: Double(headerTile.maxX / pixelsPerSecond),
                pixelsPerSecond: pixelsPerSecond, divisions: value.divisions, minimumLabelSpacing: spacing)
            let lines = (0...value.regionLanes).map { CGFloat($0) * 16 + 0.5 } +
                [regionHeight + markerLaneHeight + 0.5, barTop + 0.5, value.rulerHeight - 0.5]
            ruler.update(TimelineNativeRuler(viewport: headerTile, displayScale: style.displayScale, barTop: barTop,
                ticks: ticks.map { .init(x: $0.time * pixelsPerSecond, primary: $0.primary, text: $0.label) }, rows: lines,
                background: style.panel, lineColor: style.headerLine))
        }
        audioBody.project(viewport: viewport, documentSize: CGSize(width: width, height: value.contentHeight), scale: pixelsPerSecond)
        selectionPin.observeScroll(); needlePin.observeScroll()
        // Fully native content has finished this scale in the same transaction.
        // Mixed Canvas bodies and hosted headers still wait for hosting layout.
        if nativeOnly { scroll?.applyZoomAnchor() }
    }
    deinit { for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) } }
}
#endif

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
    private var pendingImmediatePaint = false
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
            subscriptions.append(show.$snapshot.sink { [weak self, weak show] snapshot in
                guard let self else { return }
                // @Published calls this while the controller's tick flag is
                // still set. Commands and engine state transitions keep their
                // immediate presentation; routine samples join the 60 Hz clock.
                self.scheduleSample(immediate: show?.timelinePlaybackIsPublishingTick != true ||
                    self.requiresImmediateSample(snapshot.transport))
            })
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
    func updateProjection(size: CGSize, rulerHeight: CGFloat, extent: Double) {
        // Scrolling keeps this geometry unchanged. Repainting here would feed
        // the follow scroll back into another paint between transport ticks.
        guard self.size != size || self.rulerHeight != rulerHeight || self.extent != extent else { return }
        self.size = size; self.rulerHeight = rulerHeight; self.extent = extent
        paint()
    }
    private func requiresImmediateSample(_ next: TransportState) -> Bool {
        guard let previous = transport else { return true }
        return previous.playing != next.playing || previous.paused != next.paused ||
            previous.songId != next.songId || previous.editPosition != next.editPosition ||
            previous.subPlay.playing != next.subPlay.playing || previous.subPlayPromotion != next.subPlayPromotion ||
            previous.sectionJumpSerial != next.sectionJumpSerial || previous.regionId != next.regionId ||
            previous.loop != next.loop || previous.ignoreNextEnd != next.ignoreNextEnd ||
            previous.multiLoop?.id != next.multiLoop?.id || previous.multiLoop?.start != next.multiLoop?.start ||
            previous.multiLoop?.end != next.multiLoop?.end || previous.multiLoop?.released != next.multiLoop?.released ||
            next.position < previous.position || next.subPlay.position < previous.subPlay.position
    }
    private func scheduleSample(immediate: Bool = true) {
        pendingImmediatePaint = pendingImmediatePaint || immediate || timer == nil
        guard !pendingSample else { return }
        pendingSample = true
        // @Published emits before its storage changes. Read the completed
        // snapshot after publication, and never reset an older sample's epoch.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingSample else { return }
            let immediate = self.pendingImmediatePaint
            self.pendingSample = false; self.pendingImmediatePaint = false
            guard self.show != nil else { return }
            self.sample()
            // Sampling keeps the latest transport/epoch pair ready. Painting
            // ordinary 30 Hz samples here would add a second stream of frames
            // between the existing 60 Hz timer's interpolated presentations.
            if immediate || self.timer == nil { self.paint() }
        }
    }
    private func sample() {
        guard let show else { return }
        transport = show.timelinePlaybackTransport; sampledAt = show.timelinePlaybackSampleTime
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
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sample(); manageTimer(); paint() }
    func stop() {
        timer?.invalidate(); timer = nil; subscriptions.removeAll(); show = nil
        pendingSample = false; pendingImmediatePaint = false
        seek = { _, _ in }; marker = { _ in }
    }
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
        // Playback changes only position. Setting frame also asks Core Animation
        // to set unchanged bounds on every tick; resize the shape only as needed.
        let bounds = CGRect(x: 0, y: 0, width: 28, height: size.height)
        if needle.root.bounds != bounds { needle.root.bounds = bounds }
        let position = CGPoint(x: x, y: size.height / 2)
        if needle.root.position != position { needle.root.position = position }
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
        let transport = show.timelinePlaybackTransport
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

/// Item time intervals retain exact row/lane geometry. Query the existing
/// preparation reserves before subscribing the fallback Canvas to live scale.
private struct TimelineHostedItemCoverage: Equatable {
    let items: [CGRect]
    var identity: Int = 0
    func containsItems(viewport: CGRect, documentSize: CGSize, scale: CGFloat) -> Bool {
        guard scale.isFinite, scale > 0 else { return true }
        let bucket = CGRect(x: floor(max(0, viewport.minX) / 512) * 512,
            y: floor(max(0, viewport.minY) / 512) * 512,
            width: viewport.width, height: viewport.height)
        let canvas = TimelineCanvasCoverage.preparedRect(visibleRect: bucket, documentSize: documentSize)
        let waveform = TimelineWaveformCoverage.preparedRect(visibleRect: bucket, documentSize: documentSize)
        let prepared = canvas.union(waveform).insetBy(dx: -6, dy: -6)
        return items.contains { item in
            CGRect(x: item.minX * scale + 1, y: item.minY,
                width: max(2, item.width * scale - 2), height: item.height).intersects(prepared)
        }
    }
}

/// Only visibility transitions invalidate SwiftUI. Retiring a hosted surface
/// remains a hosted projection until the matching graph has completed layout.
@MainActor private final class TimelineHostedItemsGate: ObservableObject {
    struct Snapshot: Equatable {
        let generation: UInt64
        let coverage: TimelineHostedItemCoverage?
        let active: Bool
    }
    @Published private(set) var published = Snapshot(generation: 0, coverage: nil, active: true)
    private(set) var requested = Snapshot(generation: 0, coverage: nil, active: true)
    private var staged: Snapshot?
    private var acknowledged: Snapshot?
    private var publicationQueued = false
    var needsCommit: Bool { acknowledged != requested }
    func requiresHosted(coverage: TimelineHostedItemCoverage?) -> Bool {
        requested.coverage != coverage || requested.active || needsCommit
    }
    @discardableResult func update(coverage: TimelineHostedItemCoverage?, active: Bool, deferred: Bool) -> Bool {
        let changed = requested.coverage != coverage || requested.active != active
        if changed {
            requested = Snapshot(generation: requested.generation &+ 1, coverage: coverage, active: active)
        }
        guard published != requested else { return changed }
        if deferred {
            if !publicationQueued {
                publicationQueued = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.publicationQueued = false
                    self.publishRequested()
                }
            }
        } else { publishRequested() }
        return changed
    }
    private func publishRequested() {
        guard published != requested else { return }
        published = requested
    }
    func stage(_ snapshot: Snapshot, coverage: TimelineHostedItemCoverage?) {
        // A render of the previous structural configuration cannot acknowledge
        // either a newly mounted fallback or the retirement of its old pixels.
        guard snapshot == requested, snapshot.coverage == coverage else { return }
        staged = snapshot
    }
    @discardableResult func commitHostedProjection() -> Bool {
        if staged == requested { acknowledged = requested }
        return !needsCommit
    }
}

#if os(macOS)
private struct TimelineHostedItemsCommit: NSViewRepresentable {
    let gate: TimelineHostedItemsGate
    let snapshot: TimelineHostedItemsGate.Snapshot
    let coverage: TimelineHostedItemCoverage?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { gate.stage(snapshot, coverage: coverage) }
}
#endif

/// Only the horizontal document observes zoom; the outer scroll and mixer keep
/// their existing content and layout during a horizontal scale gesture.
private final class TimelineCoordinatePlane: ObservableObject {
    private(set) var width: CGFloat = 1
    func prepare(_ proposed: CGFloat) {
        #if os(macOS)
        width = max(width, proposed)
        #else
        width = proposed
        #endif
    }
    func update(_ proposed: CGFloat) {
        guard proposed.isFinite, proposed > 0 else { return }
        #if os(macOS)
        guard proposed > width else { return }
        let next = max(proposed, width * 2)
        #else
        guard proposed != width else { return }
        let next = proposed
        #endif
        objectWillChange.send()
        width = next
    }
}
private final class TimelineZoomState: ObservableObject {
    @Published var value = TimelineViewportPreferences.zoom {
        didSet { coordinatePlane.update(extent * 10 * value) }
    }
    let coordinatePlane = TimelineCoordinatePlane()
    private var extent: Double = 1
    func preparePlane(extent: Double) {
        self.extent = extent
        coordinatePlane.prepare(extent * 10 * value)
    }
}
private struct TimelineCoordinatePlaneLayer<Content: View>: View {
    @ObservedObject private var plane: TimelineCoordinatePlane
    let content: (CGFloat) -> Content
    init(state: TimelineZoomState, extent: Double, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        state.preparePlane(extent: extent)
        self.plane = state.coordinatePlane
        self.content = content
    }
    var body: some View { content(plane.width) }
}
private struct TimelineScaleLayer<Content: View>: View {
    @ObservedObject var state: TimelineZoomState
    let extent: Double
    @ViewBuilder let content: (Binding<Double>, CGFloat, Double) -> Content
    var body: some View { content($state.value, extent * 10 * state.value, 10 * state.value) }
}
/// Empty layers keep their content subscriptions without subscribing to scale.
/// An edit/recording/selection mounts its zoom scope only while it draws pixels.
private struct TimelineItemsScaleLayer<Content: View>: View {
    let state: TimelineZoomState
    let extent: Double
    let hasItems: Bool
    @ObservedObject var gate: TimelineHostedItemsGate
    let coverage: TimelineHostedItemCoverage?
    @ViewBuilder let content: (Binding<Double>, CGFloat, Double) -> Content
    var body: some View {
        #if os(macOS)
        let snapshot = gate.published
        ZStack(alignment: .topLeading) {
            // A structural edit can introduce visible fallback before its native
            // configuration is reconciled. Keep that new content conservative.
            if hasItems && (snapshot.coverage != coverage || snapshot.active) {
                TimelineScaleLayer(state: state, extent: extent, content: content)
            }
            TimelineHostedItemsCommit(gate: gate, snapshot: snapshot, coverage: coverage)
                .frame(width: 0, height: 0)
        }
        #else
        TimelineScaleLayer(state: state, extent: extent, content: content)
        #endif
    }
}
private struct TimelineGainScaleLayer<Content: View>: View {
    let state: TimelineZoomState
    let extent: Double
    @ObservedObject var preview: ItemGainPreview
    @ViewBuilder let content: (Binding<Double>, CGFloat, Double) -> Content
    var body: some View {
        if preview.state != nil { TimelineScaleLayer(state: state, extent: extent, content: content) }
    }
}
private struct TimelineRecordingScaleLayer<Content: View>: View {
    let state: TimelineZoomState
    let extent: Double
    @ObservedObject private var preview = LiveRecordingPreview.shared
    @ViewBuilder let content: (Binding<Double>, CGFloat, Double) -> Content
    var body: some View {
        if !preview.takes.isEmpty { TimelineScaleLayer(state: state, extent: extent, content: content) }
    }
}
private struct TimelineHeaderScaleLayer<Content: View>: View {
    let state: TimelineZoomState
    let extent: Double
    let song: UUID
    let hasContent: Bool
    @ObservedObject var preview: GridInsertionPreview
    @ObservedObject private var area = TimelineAreaSelection.shared
    @ViewBuilder let content: (Binding<Double>, CGFloat, Double) -> Content
    var body: some View {
        #if os(macOS)
        if hasContent || preview.time != nil || area.range?.song == song {
            TimelineScaleLayer(state: state, extent: extent, content: content)
        }
        #else
        TimelineScaleLayer(state: state, extent: extent, content: content)
        #endif
    }
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
        guard lhs.nativeAudioItems == rhs.nativeAudioItems, lhs.hostedMetalRequired == rhs.hostedMetalRequired else { return false }
        return lhs.trackHeightScales == rhs.trackHeightScales && lhs.selectedTracks == rhs.selectedTracks && lhs.documentWidth == rhs.documentWidth && lhs.visibleRect == rhs.visibleRect && lhs.renderKey == rhs.renderKey && lhs.rowHeight == rhs.rowHeight && lhs.rulerHeight == rhs.rulerHeight && lhs.extent == rhs.extent && lhs.selectedClips == rhs.selectedClips && lhs.movingClip == rhs.movingClip && lhs.movingStart == rhs.movingStart && lhs.colorScheme == rhs.colorScheme && lhs.mediaDirectory == rhs.mediaDirectory && lhs.missingAudioPaths == rhs.missingAudioPaths
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
    var nativeAudioItems: Set<UUID> = []
    var hostedMetalRequired = true
    var documentWidth: CGFloat? = nil
    var selectedTracks: Set<UUID> = []
    var trackHeightScales: [Double] = []
    fileprivate var cachedRows: TrackRowLayout? = nil
    fileprivate var renderMetadata: TimelineRenderMetadata? = nil
    @ObservedObject private var metalRenderer = MetalWaveformRenderer.shared
    @State private var rowLayoutCache = TrackLayoutCache()
    @State private var metadataCache = TimelineRenderMetadataCache()
    var body: some View {
        let rows = cachedRows ?? rowLayoutCache.layout(song.tracks, height: rowHeight, key: renderKey)
        let metadata = renderMetadata ?? metadataCache.metadata(song: song, key: renderKey)
        #if os(macOS)
        let needsItems = metadata.hasItems
        #else
        let needsItems = true
        #endif
        ZStack(alignment: .topLeading) {
        if needsItems {
        TimelineWaveformReadinessLayer(observesWaveforms: !MetalWaveformRenderer.isSupported) { waveformRevision in
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, batchesViewport: MetalWaveformRenderer.isSupported, diagnosticName: "items", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, rowHeight: rowHeight, trackHeights: rows.heights, rulerHeight: rulerHeight, selectedClips: selectedClips, waveformRevision: waveformRevision, missingAudioPaths: missingAudioPaths, mediaDirectory: mediaDirectory), tileIdentity: { tile, size in
            var identity = TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, rowHeight: rowHeight, trackHeights: rows.heights, rulerHeight: rulerHeight, selectedClips: selectedClips, missingAudioPaths: missingAudioPaths, mediaDirectory: mediaDirectory)
            if MetalWaveformRenderer.isSupported { return identity }
            let scale = size.width / extent
            var fingerprint = Hasher()
            if let mediaDirectory, !MetalWaveformRenderer.isSupported {
                var visitedFiles = Set<String>()
                for (index, track) in song.tracks.enumerated() where rulerHeight + rows.offsets[index] <= tile.maxY && rulerHeight + rows.offsets[index] + rows.heights[index] >= tile.minY {
                    for clip in track.clips where clip.startTime * scale <= tile.maxX && (clip.startTime + clip.duration) * scale >= tile.minX {
                        if let file = clip.audioFile ?? track.audioFile, visitedFiles.insert(file.path).inserted {
                            fingerprint.combine(file.path)
                            fingerprint.combine(TimelineAudioWaveform.shared.version(mediaDirectory.appendingPathComponent(file.path, isDirectory: false)))
                        }
                    }
                }
            }
            identity.waveformRevision = UInt64(bitPattern: Int64(fingerprint.finalize()))
            return identity
        }) { context, size, tile, waveformOwner in
            let scale = size.width / extent
            // Empty space keeps the same grid spacing without creating or stretching tracks.
            let clickTiming = metadata.hasClickTrack ? metadata.sections(until: song.duration) : []
            #if !os(macOS)
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
            #endif
            let hasSolo = metadata.hasSolo
            for (index, track) in song.tracks.enumerated() {
                let trackSilenced = track.mute || (hasSolo && !track.solo)
                let y = rulerHeight + rows.offsets[index]
                if y > tile.maxY || y + rows.heights[index] < tile.minY { continue }
                #if !os(macOS)
                var rowLine = Path(); rowLine.move(to: CGPoint(x: 0, y: y)); rowLine.addLine(to: CGPoint(x: size.width, y: y)); context.stroke(rowLine, with: .color(JarasTheme.line.opacity(0.8)), lineWidth: 1)
                #endif
                // Include the pixel overscan and the minimum two-pixel body;
                // an extremely short item can extend past its time interval.
                for clipIndex in metadata.clipIndices(inTrack: index,
                    from: Double(tile.minX - 9) / scale, through: Double(tile.maxX + 9) / scale) {
                    let clip = track.clips[clipIndex]
                    guard !nativeAudioItems.contains(clip.id) else { continue }
                    let silenced = trackSilenced || clip.muted == true
                    let selected = selectedClips.contains(clip.id)
                    let rect = CGRect(x: clip.startTime * scale + 1, y: y + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3, width: max(2, clip.duration * scale - 2), height: rows.laneHeights[index] - 6)
                    guard rect.intersects(tile.insetBy(dx: -6, dy: -6)) else { continue }
                    drawTimelineItem(clip, track: track, rect: rect, selected: selected, silenced: silenced, scale: scale, tile: tile, context: &context, mediaDirectory: mediaDirectory, tempoSegments: !MetalWaveformRenderer.isSupported && metadata.affectsAudio ? metadata.fragments(for: clip) : nil, missingAudio: (clip.audioFile ?? track.audioFile).map { missingAudioPaths.contains($0.path) } ?? false, waveformOwner: waveformOwner, drawWaveform: !MetalWaveformRenderer.isSupported, clickTiming: track.kind == .click ? clickTiming : [])
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
            if MetalWaveformRenderer.isSupported, hostedMetalRequired, let mediaDirectory {
                TimelineMetalWaveformLayer(visibleRect: visibleRect, song: song, rows: rows, renderKey: renderKey,
                    rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips,
                    mediaDirectory: mediaDirectory, missingAudioPaths: missingAudioPaths, documentWidth: documentWidth,
                    excludedClips: nativeAudioItems, metadata: metadata)
            }
        }
        }
        }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background {
            #if !os(macOS)
            TimelineBackdrop(visibleRect: visibleRect, song: song, rows: rows, renderKey: renderKey,
                rowHeight: rowHeight, rulerHeight: rulerHeight, extent: extent,
                documentWidth: documentWidth, selectedTracks: selectedTracks, metadata: metadata)
            #endif
        }
    }
}

/// Metal owns its readiness observer. Only the Canvas fallback needs to rebuild
/// item drawing when asynchronously prepared waveform blocks become available.
private struct TimelineWaveformReadinessLayer<Content: View>: View {
    let observesWaveforms: Bool
    @ViewBuilder let content: (UInt64) -> Content
    var body: some View {
        if observesWaveforms {
            TimelineObservedWaveformReadinessLayer(content: content)
        } else {
            content(0)
        }
    }
}
private struct TimelineObservedWaveformReadinessLayer<Content: View>: View {
    @ObservedObject private var waveform = TimelineAudioWaveform.shared
    @ViewBuilder let content: (UInt64) -> Content
    var body: some View { content(waveform.revision) }
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
    var excludedClips: Set<UUID> = []
    let metadata: TimelineRenderMetadata
    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: documentWidth ?? geometry.size.width, height: geometry.size.height)
            #if os(macOS)
            let viewport = TimelineWaveformCoverage.preparedRect(visibleRect: visibleRect, documentSize: size)
            #else
            let viewport = TimelineCanvasCoverage.preparedRect(visibleRect: visibleRect, documentSize: size)
            #endif
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
        let hasSolo = metadata.hasSolo
        var items: [TimelineWaveformItem] = []
        for (index, track) in song.tracks.enumerated() where track.kind == .standard {
            let y = rulerHeight + rows.offsets[index]
            guard y <= viewport.maxY, y + rows.heights[index] >= viewport.minY else { continue }
            let visibleIndices: [Int]
            if let preview {
                // Preview may carry changed bounds. Find its source without
                // culling against the unchanged snapshot's interval.
                visibleIndices = track.clips.firstIndex(where: { $0.id == preview.id }).map { [$0] } ?? []
            } else {
                visibleIndices = metadata.clipIndices(inTrack: index,
                    from: Double(viewport.minX - 3) / scale, through: Double(viewport.maxX + 3) / scale)
            }
            for clipIndex in visibleIndices {
                let source = track.clips[clipIndex]
                guard !excludedClips.contains(source.id) else { continue }
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
                let mediaSource = mediaURLs.resolveSource(file.path, directory: mediaDirectory)
                items.append(TimelineWaveformItem(clip: clip,
                    fragments: metadata.fragments(for: clip, preview: preview != nil),
                    url: mediaSource.url, rect: rect, gray: gray, sourcePath: mediaSource.path, mediaSource: mediaSource))
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
    let metadata: TimelineRenderMetadata
    var body: some View {
        #if os(macOS)
        GeometryReader { geometry in
            let size = CGSize(width: documentWidth ?? geometry.size.width, height: geometry.size.height)
            let tile = TimelineCanvasCoverage.preparedRect(visibleRect: visibleRect, documentSize: size)
            let scale = size.width / extent
            let marks = gridlines ? TimelineTimeRuler.ticks(in: metadata.sections(until: extent),
                from: max(0, Double(tile.minX / scale)), to: Double(tile.maxX / scale),
                pixelsPerSecond: scale, divisions: song.projectTime.divisions, labels: false) : []
            let bands = song.tracks.enumerated().compactMap { index, track -> TimelineNativeGridBand? in
                guard track.kind == .standard, selectedTracks.contains(track.id) else { return nil }
                let rect = CGRect(x: tile.minX, y: rulerHeight + rows.offsets[index], width: tile.width, height: rows.heights[index])
                guard rect.intersects(tile) else { return nil }
                return TimelineNativeGridBand(rect: rect, color: NSColor(JarasTheme.track(track, emphasized: true).opacity(0.12)).cgColor)
            }
            TimelineNativeGridBackdrop(viewport: tile, rulerHeight: rulerHeight, displayScale: displayScale,
                primary: marks.filter(\.primary).map { $0.time * scale },
                secondary: marks.filter { !$0.primary }.map { $0.time * scale }, bands: bands,
                background: NSColor(Color(hex: UInt32(backgroundColor.value))).cgColor,
                primaryColor: NSColor(Color(hex: UInt32(primaryGridColor.value))).cgColor,
                secondaryColor: NSColor(Color(hex: UInt32(secondaryGridColor.value)).opacity(0.85)).cgColor,
                horizontal: horizontalRows(in: tile, height: size.height), rowColor: NSColor(JarasTheme.line.opacity(0.8)).cgColor)
                .frame(width: tile.width, height: tile.height).offset(x: tile.minX, y: tile.minY)
        }.allowsHitTesting(false)
        #else
        canvas
        #endif
    }
    private func horizontalRows(in tile: CGRect, height: CGFloat) -> [CGFloat] {
        var lines = rows.offsets.map { rulerHeight + $0 }.filter { $0 >= tile.minY && $0 <= tile.maxY }
        let emptyStart = rulerHeight + rows.totalHeight
        let bottom = min(height, tile.maxY)
        if emptyStart <= bottom {
            let first = max(0, Int(floor((tile.minY - emptyStart) / rowHeight)))
            let last = max(first, Int(ceil((bottom - emptyStart) / rowHeight)))
            for row in first...last {
                let y = emptyStart + CGFloat(row) * rowHeight
                if y <= bottom { lines.append(y) }
            }
        }
        return lines
    }
    private var canvas: some View {
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth,
            diagnosticName: "backdrop", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: false, rowHeight: rowHeight,
                trackHeights: rows.heights, rulerHeight: rulerHeight, selectedTracks: selectedTracks,
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
                let marks = TimelineTimeRuler.ticks(in: metadata.sections(until: extent),
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

#if os(macOS)
private struct TimelineNativeGridBand {
    let rect: CGRect
    let color: CGColor
}
/// Grid lines have reusable native layers. Rescaling updates their small vector
/// paths instead of creating a new Canvas display list and GPU surface.
private struct TimelineNativeGridBackdrop: NSViewRepresentable {
    let viewport: CGRect
    let rulerHeight: CGFloat
    let displayScale: CGFloat
    let primary: [CGFloat]
    let secondary: [CGFloat]
    let bands: [TimelineNativeGridBand]
    let background: CGColor
    let primaryColor: CGColor
    let secondaryColor: CGColor
    var horizontal: [CGFloat] = []
    var rowColor: CGColor = CGColor(gray: 0, alpha: 1)
    func makeNSView(context: Context) -> TimelineNativeGridView { TimelineNativeGridView() }
    func updateNSView(_ view: TimelineNativeGridView, context: Context) {
        view.update(self)
    }
}
private final class TimelineNativeGridView: NSView {
    private let primary = CAShapeLayer()
    private let secondary = CAShapeLayer()
    private let rows = CAShapeLayer()
    private let selections = CALayer()
    private var previousRows: [CGFloat] = []
    private var previousRowSize: CGSize = .zero
    private var previousRowOrigin: CGFloat = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = true
        layer?.masksToBounds = true
        layer?.addSublayer(selections)
        for line in [primary, secondary, rows] {
            line.fillColor = nil
            layer?.addSublayer(line)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ content: TimelineNativeGridBackdrop) {
        // Join the frame's implicit transaction; a root commit here would
        // flush layout/cursor tracking before the other timeline layers update.
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        let tile = content.viewport
        let scale = max(1, content.displayScale)
        let pixel = 1 / scale
        layer?.backgroundColor = content.background
        let local = CGRect(origin: .zero, size: tile.size)
        selections.frame = local
        // Keep selection layers through zoom; only changing selected tracks
        // changes their count. Empty grids allocate no selection layers.
        while (selections.sublayers?.count ?? 0) > content.bands.count * 2 {
            selections.sublayers?.last?.removeFromSuperlayer()
        }
        while (selections.sublayers?.count ?? 0) < content.bands.count * 2 {
            selections.addSublayer(CALayer())
        }
        for (index, band) in content.bands.enumerated() {
            let rect = band.rect.offsetBy(dx: -tile.minX, dy: -tile.minY)
            let layers = selections.sublayers!
            layers[index * 2].frame = rect
            layers[index * 2].backgroundColor = band.color
            layers[index * 2 + 1].frame = rect
            layers[index * 2 + 1].backgroundColor = CGColor(gray: 1, alpha: 0.025)
        }
        func apply(_ layer: CAShapeLayer, positions: [CGFloat], color: CGColor) {
            let path = CGMutablePath()
            let top = max(0, content.rulerHeight - tile.minY)
            for position in positions {
                let x = floor(position * scale) / scale + pixel / 2 - tile.minX
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: tile.height))
            }
            layer.frame = local
            layer.contentsScale = scale
            layer.lineWidth = pixel
            layer.strokeColor = color
            layer.path = path
        }
        apply(primary, positions: content.primary, color: content.primaryColor)
        apply(secondary, positions: content.secondary, color: content.secondaryColor)
        rows.frame = local; rows.contentsScale = scale
        rows.strokeColor = content.rowColor; rows.lineWidth = 1
        // Horizontal zoom does not change track heights. Retain these paths
        // until a vertical scroll, resize or track edit actually changes them.
        if previousRows != content.horizontal || previousRowSize != tile.size || previousRowOrigin != tile.minY {
            let path = CGMutablePath()
            for y in content.horizontal {
                path.move(to: CGPoint(x: 0, y: y - tile.minY))
                path.addLine(to: CGPoint(x: tile.width, y: y - tile.minY))
            }
            rows.path = path
            previousRows = content.horizontal; previousRowSize = tile.size; previousRowOrigin = tile.minY
        }
    }
}
#endif

/// Content snapshots outlive their Canvas callbacks. Zoom and scrolling share
/// their lazy timing work; edits install a new snapshot rather than clearing one
/// that an older draw may still be using. The lock also covers async Canvas use.
private final class TimelineRenderMetadata {
    let song: Song
    let affectsAudio: Bool
    let hasClickTrack: Bool
    let hasSolo: Bool
    let hasItems: Bool
    let regionParentIDs: Set<UUID>
    private let visibleClips: [TimelineVisibleClipIndex]
    private let lock = NSLock()
    private var timing: [Double: [TimelineTempoSection]] = [:]
    private struct FragmentEntry {
        let source: AudioClip
        let fragments: [AudioClip]
    }
    private var audio: [UUID: FragmentEntry] = [:]
    private var gainPreview: FragmentEntry?
    init(song: Song) {
        self.song = song
        affectsAudio = song.tempoMarkersAffectAudio
        hasClickTrack = song.tracks.contains { $0.kind == .click }
        hasSolo = song.tracks.contains { $0.solo }
        hasItems = song.tracks.contains { !$0.clips.isEmpty }
        regionParentIDs = Set(song.parts.compactMap(\.parentRegionID))
        visibleClips = song.tracks.map { track in
            TimelineVisibleClipIndex(intervals: track.clips.map { ($0.startTime, $0.startTime + $0.duration) })
        }
    }
    func clipIndices(inTrack index: Int, from start: Double, through end: Double) -> [Int] {
        guard visibleClips.indices.contains(index) else { return [] }
        return visibleClips[index].indices(from: start, through: end)
    }
    func sections(until end: Double) -> [TimelineTempoSection] {
        lock.lock(); defer { lock.unlock() }
        return sectionsLocked(until: end)
    }
    private func sectionsLocked(until end: Double) -> [TimelineTempoSection] {
        if let value = timing[end] { return value }
        let value = song.tempoSections(until: end)
        // Normally duration and ruler extent are the only two entries. Bound
        // old extents if the user keeps extending the empty timeline.
        if timing.count >= 4 { timing.removeAll(keepingCapacity: true) }
        timing[end] = value
        return value
    }
    func fragments(for clip: AudioClip, preview: Bool = false) -> [AudioClip] {
        guard affectsAudio else { return [clip] }
        lock.lock(); defer { lock.unlock() }
        let cached = preview ? gainPreview : audio[clip.id]
        // Preview gain is deliberately outside the document render key. Check
        // the full clip so every preview field reaches the waveform fragments.
        if let cached, cached.source == clip { return cached.fragments }
        let sections = sectionsLocked(until: song.duration)
        let fragments = sections.isEmpty ? [clip] : song.tempoAudioSegments(clip, sections: sections)
        let entry = FragmentEntry(source: clip, fragments: fragments)
        if preview { gainPreview = entry } else { audio[clip.id] = entry }
        return fragments
    }
}

@MainActor private final class TimelineRenderMetadataCache {
    private var key: TimelineRenderKey?
    private var value: TimelineRenderMetadata?
    func metadata(song: Song, key: TimelineRenderKey) -> TimelineRenderMetadata {
        if self.key == key, let value, value.song.id == song.id { return value }
        let value = TimelineRenderMetadata(song: song)
        self.key = key; self.value = value
        return value
    }
}

/// During a gain gesture only this bounded surface is invalidated. The base grid,
/// headers, mixer and lane geometry keep their existing render and layout.
private struct ItemGainPreviewOverlay: View {
    @ObservedObject private var backgroundColor = AppearanceColor.shared("jaras.timeline.background", default: TimelineAppearanceDefaults.background)
    @ObservedObject var preview: ItemGainPreview
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
    let renderMetadata: TimelineRenderMetadata
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
            TimelineWaveformReadinessLayer(observesWaveforms: !MetalWaveformRenderer.isSupported) { waveformRevision in
            ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, diagnosticName: "gain-preview", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, trackHeights: rows.heights, gainPreview: state, waveformRevision: waveformRevision, mediaDirectory: mediaDirectory, gridStyle: [backgroundColor.value])) { context, size, tile, waveformOwner in
                let scale = size.width / extent
                let rect = CGRect(x: source.startTime * scale + 1, y: y, width: max(2, source.duration * scale - 2), height: height)
                guard rect.intersects(tile) else { return }
                // Restore the opaque backing under this one item before repainting
                // its translucent fill, so the original waveform never shows through.
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(Color(hex: UInt32(backgroundColor.value))))
                let clickTiming = track.kind == .click ? renderMetadata.sections(until: song.duration) : []
                drawTimelineItem(clip, track: track, rect: rect, selected: selectedClips.contains(source.id), silenced: silenced, scale: scale, tile: tile, context: &context, mediaDirectory: mediaDirectory, tempoSegments: !MetalWaveformRenderer.isSupported && renderMetadata.affectsAudio ? renderMetadata.fragments(for: clip, preview: true) : nil, waveformOwner: waveformOwner, drawWaveform: !MetalWaveformRenderer.isSupported, clickTiming: clickTiming)
            }.overlay(alignment: .topLeading) {
                if MetalWaveformRenderer.isSupported, let mediaDirectory {
                    TimelineMetalWaveformLayer(visibleRect: visibleRect, song: song, rows: rows, renderKey: renderKey,
                        rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips,
                        mediaDirectory: mediaDirectory, documentWidth: documentWidth, preview: clip, metadata: renderMetadata)
                }
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
    // A close view uses a fine sample curve; compressed views keep their wider
    // stroke. Source scale includes playback rate, matching the Metal renderer.
    let waveStroke = TimelineWaveformStrokeStyle.lineWidth(sampleRate: header.rate, pixelsPerSecond: sourceScale)
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
    if clip.loopLength != nil {
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
    titleContext.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height <= 26 ? rect.height : min(GridSelectionItem.headerHeight, rect.height))), with: .color(.black.opacity(0.16)))
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
        var symbol = Path(ellipseIn: CGRect(x: center.x - 3.5 * GridSelectionItem.headerScale, y: center.y - 3.5 * GridSelectionItem.headerScale, width: 7 * GridSelectionItem.headerScale, height: 7 * GridSelectionItem.headerScale))
        symbol.move(to: CGPoint(x: center.x-4.5 * GridSelectionItem.headerScale, y: center.y+4.5 * GridSelectionItem.headerScale)); symbol.addLine(to: CGPoint(x: center.x+4.5 * GridSelectionItem.headerScale, y: center.y-4.5 * GridSelectionItem.headerScale))
        titleContext.stroke(symbol, with: .color(clip.phaseInverted == true ? .black : .white), lineWidth: 1.2)
    }
    if let pan = controls.panKnobRect {
        let center = CGPoint(x: pan.midX, y: pan.midY)
        let ring = Path(ellipseIn: CGRect(x: center.x-4.5 * GridSelectionItem.headerScale, y: center.y-4.5 * GridSelectionItem.headerScale, width: 9 * GridSelectionItem.headerScale, height: 9 * GridSelectionItem.headerScale))
        titleContext.fill(ring, with: .color(.black))
        titleContext.stroke(ring, with: .color(.white), lineWidth: 1.5)
        let angle = (135 + controls.panPosition * 270) * .pi / 180
        var needle = Path(); needle.move(to: center); needle.addLine(to: CGPoint(x: center.x+cos(angle)*3.5 * GridSelectionItem.headerScale, y: center.y+sin(angle)*3.5 * GridSelectionItem.headerScale))
        titleContext.stroke(needle, with: .color(JarasTheme.green), lineWidth: 2)
    }
    if let panLabel = controls.panLabelRect {
        drawTimelineName(controls.panLabel, in: panLabel, visibleRect: tile, fontSize: GridSelectionItem.headerReadoutFontSize, context: &titleContext)
    }
    if let gainLabel = controls.gainLabelRect {
        drawTimelineName(controls.gainLabel, in: gainLabel, visibleRect: tile, fontSize: GridSelectionItem.headerReadoutFontSize, context: &titleContext)
    }
    let titleInset = controls.titleInset
    let title = clip.isImage ? JarasLocalization.string("Image") : track.kind == .timecode && !clip.isProjectionMedia ? (track.timecode?.mode ?? "mtc").uppercased() : clip.name
    drawTimelineName(title, in: CGRect(x: rect.minX + titleInset, y: rect.minY, width: max(0, rect.width - titleInset), height: min(GridSelectionItem.headerHeight, rect.height)), visibleRect: tile, fontSize: GridSelectionItem.headerFontSize, context: &context)
    #endif
    }
    if rect.height <= 26 { return } // Collapsed tracks show only the item bar.
    if let midi = clip.midi {
        let body = CGRect(x: rect.minX, y: rect.minY + GridSelectionItem.bodyInset, width: rect.width, height: max(0, rect.height - GridSelectionItem.bodyInset - 2))
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
        let body = CGRect(x: rect.minX, y: rect.minY + GridSelectionItem.headerHeight, width: rect.width, height: max(0, rect.height - GridSelectionItem.headerHeight))
        if body.height >= 12 { drawTimelineName(JarasLocalization.string("Not found"), in: body, visibleRect: tile, centered: true, context: &context) }
        return
    }
    if track.kind == .click && !clip.isProjectionMedia {
        let body = CGRect(x: rect.minX, y: rect.minY + GridSelectionItem.bodyInset, width: rect.width, height: max(0, rect.height - GridSelectionItem.bodyInset - 2))
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
        let body = CGRect(x: rect.minX, y: rect.minY + GridSelectionItem.headerHeight, width: rect.width, height: max(0, rect.height - GridSelectionItem.headerHeight))
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
    let waveTop = rect.minY + min(GridSelectionItem.bodyInset, rect.height)
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
    private static let resizeCursor = NSCursor.resizeLeftRight
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: Self.resizeCursor) }
    private func releasePointerCursor() {
        guard Self.pointerCursorOwner === self else { return }
        Self.pointerCursorOwner = nil
        if NSCursor.current == Self.resizeCursor { NSCursor.arrow.set() }
    }
    private func updatePointerCursor() {
        if let owner = Self.pointerCursorOwner, owner.mouseIsDown { return }
        guard let window else { releasePointerCursor(); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(point) {
            Self.pointerCursorOwner = self
            Self.resizeCursor.set()
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
        Self.resizeCursor.set()
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
            Self.resizeCursor.set()
            queueScroll(to: startingScroll + dy * scrollPerPoint)
            return
        }
        Self.resizeCursor.set()
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
    /// Menu commands and keyboard events must reach the same window-scoped
    /// editor, including when AppKit dispatches a key equivalent before keyDown.
    static func performClipboard(_ key: String) {
        guard let window = NSApp.keyWindow else { return }
        if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
            let selectors = ["c": "copy:", "x": "cut:", "v": "paste:"]
            if let action = selectors[key] { NSApp.sendAction(NSSelectorFromString(action), to: nil, from: nil) }
            return
        }
        guard window.attachedSheet == nil, window.sheetParent == nil, NSApp.modalWindow == nil,
              !NativeTimelineInputGate.shared.isBlocked(window), ControlMappings.shared.editing == nil,
              let owner = owners.allObjects.first(where: { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }) else { return }
        switch key {
        case "c": _ = owner.copyItems?()
        case "x": _ = owner.moveItems?()
        case "v": owner.pasteItems?()
        default: break
        }
    }

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
            if event.keyCode == 53, flags.isEmpty, NativeTimelineInputGate.shared.cancelActiveResize(for: event.window) { return nil }
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
    private var rowOffsets: [CGFloat] = []
    private var laneHeights: [CGFloat] = []
    private var value: GridSelectionLayout?
    func layout(key: TimelineRenderKey, rowHeight: CGFloat, rulerHeight: CGFloat,
                rowOffsets: [CGFloat], laneHeights: [CGFloat],
                makeItems: () -> [GridSelectionItem]) -> GridSelectionLayout {
        if let value, self.key == key, self.rowHeight == rowHeight, self.rulerHeight == rulerHeight,
           self.rowOffsets == rowOffsets, self.laneHeights == laneHeights { return value }
        let value: GridSelectionLayout
        if let previous = self.value, self.key == key {
            value = previous.projectingRows(offsets: rowOffsets, laneHeights: laneHeights, top: rulerHeight)
        } else {
            value = GridSelectionLayout(items: makeItems(), timeCoordinates: true)
        }
        self.key = key; self.rowHeight = rowHeight; self.rulerHeight = rulerHeight; self.value = value
        self.rowOffsets = rowOffsets; self.laneHeights = laneHeights
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
    private var scales: [Double] = []
    private var rows: TrackRowLayout?
    func layout(_ tracks: [Track], height: CGFloat, key: TimelineRenderKey) -> TrackRowLayout {
        let scales = tracks.map { TrackHeightGeometry.scale($0.heightScale) }
        if self.key == key, self.height == height, self.scales == scales, let rows { return rows }
        let rows: TrackRowLayout
        if self.key == key, let previous = self.rows {
            rows = TrackRowLayout(lanes: previous.lanes, baseHeight: height, scales: scales)
        } else {
            rows = TrackRowLayout(tracks: tracks, baseHeight: height)
        }
        self.key = key; self.height = height; self.rows = rows
        self.scales = scales
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
    let baseHeight: CGFloat
    let globalLimits: ClosedRange<CGFloat>
    let scales: [Double]
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
        self.init(lanes: lanes, baseHeight: baseHeight, scales: tracks.map { TrackHeightGeometry.scale($0.heightScale) })
    }
    init(lanes: [TrackLanes], baseHeight: CGFloat, scales: [Double]) {
        self.lanes = lanes
        self.scales = scales
        let limits = TrackHeightGeometry.globalLimits(scales: scales, laneCounts: lanes.map(\.count), current: Double(baseHeight))
        globalLimits = CGFloat(limits.lowerBound)...CGFloat(limits.upperBound)
        let displayedHeight = min(globalLimits.upperBound, max(globalLimits.lowerBound, baseHeight))
        self.baseHeight = displayedHeight
        laneHeights = lanes.enumerated().map { index, lane in
            CGFloat(TrackHeightGeometry.laneHeight(base: Double(displayedHeight), scale: scales[index], count: lane.count))
        }
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
    var cachedLanes: RegionLanes? = nil
    var cachedParentIDs: Set<UUID>? = nil
    var cachedTempoSections: [TimelineTempoSection]? = nil
    var body: some View {
        #if os(macOS)
        if !song.parts.isEmpty { canvas }
        #else
        canvas
        #endif
    }
    #if os(macOS)
    private var nativeRuler: some View {
        GeometryReader { geometry in
            let size = CGSize(width: documentWidth ?? geometry.size.width, height: geometry.size.height)
            let tile = TimelineCanvasCoverage.preparedRect(visibleRect: visibleRect, documentSize: size)
            let scale = size.width / extent
            let lanes = cachedLanes ?? RegionLanes(parts: song.parts)
            let regionHeight = CGFloat(lanes.count) * 16
            let barTop = regionHeight + markerLaneHeight + tempoLaneHeight
            let sample = TimelineTimeRuler.labelSample(through: extent)
            let labelWidth = TimelineStaticText.label(sample, style: .barNumber, displayScale: displayScale).map { Double($0.size.width) }
            let spacing = TimelineTimeRuler.labelSpacing(through: extent, measuredWidth: labelWidth, pixelsPerSecond: scale)
            let ticks = TimelineTimeRuler.ticks(in: cachedTempoSections ?? song.tempoSections(until: extent),
                from: max(0, Double((tile.minX - spacing) / scale)), to: Double(tile.maxX / scale),
                pixelsPerSecond: scale, divisions: song.projectTime.divisions, minimumLabelSpacing: spacing)
            let lines = (0...lanes.count).map { CGFloat($0) * 16 + 0.5 } +
                [regionHeight + markerLaneHeight + 0.5, barTop + 0.5, size.height - 0.5]
            TimelineNativeRuler(viewport: tile, displayScale: displayScale, barTop: barTop,
                ticks: ticks.map { .init(x: $0.time * scale, primary: $0.primary, text: $0.label) }, rows: lines,
                background: NSColor(JarasTheme.panel).cgColor, lineColor: NSColor(JarasTheme.line).cgColor)
                .frame(width: tile.width, height: tile.height).offset(x: tile.minX, y: tile.minY)
        }.allowsHitTesting(false)
    }
    #endif
    private var canvas: some View {
        ViewportTimelineCanvas(visibleRect: visibleRect, synchronized: true, documentWidth: documentWidth, diagnosticName: "header", identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light)) { context, size, tile, waveformOwner in
            #if !os(macOS)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(JarasTheme.panel))
            #endif
            let scale = size.width / extent
            let lanes = cachedLanes ?? RegionLanes(parts: song.parts)
            let parentIDs = cachedParentIDs ?? Set(song.parts.compactMap(\.parentRegionID))
            let regionHeight = CGFloat(lanes.count) * 16
            for (index, part) in song.parts.enumerated() {
                guard part.parentRegionID == nil else { continue }
                let rect = CGRect(x: part.startTime * scale, y: CGFloat(lanes.lanes[part.id] ?? 0) * 16, width: max(1, (part.endTime - part.startTime) * scale), height: 16)
                guard rect.intersects(tile) else { continue }
                context.fill(Path(rect), with: .color(Color(hex: part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965))))
                var labelContext = context
                labelContext.clip(to: Path(rect))
                // Parts are stored in creation order; moving a region keeps its number.
                let identifierText = parentIDs.contains(part.id) ? JarasLocalization.string("Special") : String(format: "%dst  %02d", part.semitones, index + 1)
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
            #if !os(macOS)
            for y in (0...lanes.count).map { CGFloat($0) * 16 + 0.5 } +
                [regionHeight + markerLaneHeight + 0.5, regionHeight + markerLaneHeight + tempoLaneHeight + 0.5, size.height - 0.5] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(JarasTheme.line), lineWidth: 1)
            }
            let barTop = regionHeight + markerLaneHeight + tempoLaneHeight
            let sample = TimelineTimeRuler.labelSample(through: extent)
            let labelWidth = TimelineStaticText.label(sample, style: .barNumber, displayScale: displayScale).map { Double($0.size.width) }
            let labelSpacing = TimelineTimeRuler.labelSpacing(through: extent, measuredWidth: labelWidth, pixelsPerSecond: scale)
            let ticks = TimelineTimeRuler.ticks(in: cachedTempoSections ?? song.tempoSections(until: extent),
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
            #endif
        }
    }
}

/// Flags and their input targets occupy the same dedicated, clipped lane.
/// Its origin follows the number of region rows, including overlapping regions.
#if os(macOS)
/// Persistent ruler primitives: zoom moves cached label images and paths instead
/// of rasterizing a new SwiftUI Canvas and issuing its drawing commands per frame.
private struct TimelineNativeRuler: NSViewRepresentable {
    struct Tick { let x: CGFloat; let primary: Bool; let text: String }
    let viewport: CGRect
    let displayScale: CGFloat
    let barTop: CGFloat
    let ticks: [Tick]
    let rows: [CGFloat]
    let background: CGColor
    let lineColor: CGColor
    func makeNSView(context: Context) -> TimelineNativeRulerView { TimelineNativeRulerView() }
    func updateNSView(_ view: TimelineNativeRulerView, context: Context) { view.update(self) }
}
private final class TimelineNativeRulerView: NSView {
    private let ticksLayer = CAShapeLayer()
    private let rowsLayer = CAShapeLayer()
    private var labels: [CALayer] = []
    private var labelImages: [CGImage] = []
    private var oldRows: [CGFloat] = []
    private var oldRowSize = CGSize.zero
    private var oldRowOriginY = CGFloat.nan
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        for shape in [rowsLayer, ticksLayer] {
            shape.fillColor = nil; layer?.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ value: TimelineNativeRuler) {
        guard let root = layer else { return }
        let scale = max(1, value.displayScale), pixel = 1 / scale
        let rect = CGRect(origin: .zero, size: value.viewport.size)
        let top = value.barTop - value.viewport.minY
        // Join the frame's implicit transaction; a root commit here would
        // flush layout/cursor tracking before the other timeline layers update.
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        root.backgroundColor = value.background
        rowsLayer.frame = rect; rowsLayer.strokeColor = value.lineColor; rowsLayer.lineWidth = 1
        if oldRows != value.rows || oldRowSize != rect.size || oldRowOriginY != value.viewport.minY {
            let path = CGMutablePath()
            for y in value.rows {
                path.move(to: CGPoint(x: 0, y: y - value.viewport.minY))
                path.addLine(to: CGPoint(x: rect.width, y: y - value.viewport.minY))
            }
            rowsLayer.path = path
            oldRows = value.rows; oldRowSize = rect.size; oldRowOriginY = value.viewport.minY
        }
        let path = CGMutablePath()
        var count = 0
        for tick in value.ticks {
            // Round in document coordinates, then translate, matching the grid.
            let x = floor(tick.x * scale) / scale + pixel / 2 - value.viewport.minX
            if x >= -1 && x <= rect.width + 1 {
                path.move(to: CGPoint(x: x, y: top + 1))
                path.addLine(to: CGPoint(x: x, y: top + (tick.primary ? 7 : 4)))
            }
            guard !tick.text.isEmpty,
                  let text = TimelineStaticText.label(tick.text, style: .barNumber, displayScale: scale),
                  x + 2 + text.size.width >= 0, x + 2 < rect.width else { continue }
            let label: CALayer
            if count == labels.count {
                label = CALayer(); labels.append(label); labelImages.append(text.image)
                label.contents = text.image; root.addSublayer(label)
            } else {
                label = labels[count]
                if labelImages[count] !== text.image { label.contents = text.image; labelImages[count] = text.image }
            }
            label.contentsScale = scale
            label.frame = CGRect(origin: CGPoint(x: x + 2, y: top + 2), size: text.size)
            count += 1
        }
        while labels.count > count { labels.removeLast().removeFromSuperlayer(); labelImages.removeLast() }
        ticksLayer.frame = rect; ticksLayer.lineWidth = pixel
        ticksLayer.strokeColor = NSColor(TimelineStaticText.rulerColor).cgColor
        ticksLayer.path = path
    }
}
#endif

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
    static func label(_ name: String, context: GraphicsContext, fontSize: CGFloat = 9) -> TimelineResolvedName {
        let key = "\(fontSize):\(name)" as NSString
        if let value = cache.object(forKey: key) { return value }
        let value = TimelineResolvedName(context.resolve(Text(verbatim: name).font(.system(size: fontSize, weight: .medium))))
        cache.setObject(value, forKey: key, cost: name.utf8.count * 16 + 128)
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
    static func metrics(_ name: String, fontSize: CGFloat = 9, measure: (String) -> CGFloat) -> TimelineNameMetrics {
        let key = "\(fontSize):\(name)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let value = TimelineNameMetrics(name: name, measure: measure)
        cache.setObject(value, forKey: key, cost: name.utf8.count * 16 + 128)
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
private func drawTimelineName(_ name: String, in rect: CGRect, color: Color = JarasTheme.text, visibleRect: CGRect, centered: Bool = false, fontSize: CGFloat = 9, context: inout GraphicsContext) {
    let available = rect.width - 8
    guard available >= 10, rect.intersects(visibleRect) else { return }
    let drawingContext = context
    let measure: (String) -> CGFloat = { TimelineResolvedName.label($0, context: drawingContext, fontSize: fontSize).width }
    let metrics = TimelineNameMetrics.metrics(name, fontSize: fontSize, measure: measure)
    guard centered || rect.minX + 4 + min(available, metrics.fullWidth) >= visibleRect.minX,
          let displayed = metrics.fitting(name, width: available, measure: measure) else { return }
    var clipped = context
    clipped.clip(to: Path(roundedRect: rect, cornerRadius: 3))
    var label = TimelineResolvedName.label(displayed, context: context, fontSize: fontSize).text
    label.shading = .color(color)
    clipped.draw(label, at: centered ? CGPoint(x: rect.midX, y: rect.midY) : CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: centered ? .center : .topLeading)
}

private struct RegionBoundaryOverlay: View {
    let parts: [Part]
    let scale: Double
    let originX: CGFloat
    let lanes: RegionLanes
    var body: some View {
        if !parts.isEmpty {
        Canvas { context, size in
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
    var trackHeights: [CGFloat] = []
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
                    Text("M").font(.system(size: 9 * GridSelectionItem.headerScale, weight: .bold)).foregroundStyle(.white)
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
    var projectID: UUID? = nil
}
/// Controls do not need sample arrays, so SwiftUI never diffs them for each fader.
private func mixerMetadata(_ source: Track) -> Track {
    var track = source
    track.clips = []
    track.heightScale = nil
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
            // An empty marker lane has no pixels or hit targets. Keeping a
            // transparent Canvas here still creates a display list on every
            // zoom frame, including completely empty projects.
            if !markers.isEmpty {
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
            }
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

/// Native header lanes retain their stable neighbours and both text metrics.
/// Drawing uses the raster label's medium font; input keeps the original
/// semibold measurement. Only positions and width constraints depend on zoom.
private struct NativeTimelineMarkerLayout {
    private struct Entry {
        let marker: TimelineMarker
        let drawingWidth: Double
        let inputWidth: Double
        let nextPosition: Double
        let regionEnd: Double
    }
    private let entries: [Entry]

    init(_ markers: [TimelineMarker], drawingWidths: [UUID: Double],
         inputWidths: [UUID: Double], regionEnds: [UUID: Double]) {
        let ordered = markers.indices.sorted {
            markers[$0].position == markers[$1].position ? $0 < $1 : markers[$0].position < markers[$1].position
        }
        var nextPositions = Array(repeating: Double.infinity, count: markers.count)
        for index in ordered.indices.dropLast() {
            nextPositions[ordered[index]] = markers[ordered[index + 1]].position
        }
        entries = markers.indices.map { index in
            let marker = markers[index]
            return Entry(marker: marker, drawingWidth: drawingWidths[marker.id] ?? 0,
                inputWidth: inputWidths[marker.id] ?? 0, nextPosition: nextPositions[index],
                regionEnd: regionEnds[marker.id] ?? .infinity)
        }
    }

    func forEachProjection(scale: Double, viewport: CGRect, draggingID: UUID?,
                           _ visit: (TimelineMarker, Double, Double, MarkerTargetGeometry?) -> Void) {
        for entry in entries {
            let marker = entry.marker, x = marker.position * scale
            let nextX = entry.nextPosition * scale, endX = entry.regionEnd * scale
            // Keep the operation order and 18-point flag/8-point input gates
            // identical to TimelineMarker.flagWidths and MarkerTargetGeometry.
            let drawingWidth = min(entry.drawingWidth + 10, nextX - x - 3, endX - x)
            var target: MarkerTargetGeometry?
            let rightLimit = max(x + 8, min(nextX - 3, endX))
            if marker.id == draggingID || x <= viewport.maxX && rightLimit >= viewport.minX {
                let measuredWidth = min(entry.inputWidth + 10, nextX - x - 3, endX - x)
                let width = max(8, measuredWidth >= 18 ? measuredWidth : 0)
                if marker.id == draggingID || x + width >= viewport.minX && x <= viewport.maxX {
                    target = MarkerTargetGeometry(marker: marker, left: x, width: width)
                }
            }
            visit(marker, x, drawingWidth >= 18 ? drawingWidth : 0, target)
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
