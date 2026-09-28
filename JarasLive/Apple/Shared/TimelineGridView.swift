import SwiftUI
import UniformTypeIdentifiers
enum TimelineZoomLimits {
    static let minimum = 0.01
    static let maximum = 16.0
}
private let markerLaneHeight: CGFloat = 16

struct TimelineGridView: View {
    @ObservedObject var show: ShowController
    let documents: ProjectDocuments
    var toggleMixer: () -> Void = {}
    var body: some View {
        TimelineGridContent(show: show, documents: documents, revision: show.projectRevision, songID: show.current?.id, focusRequest: show.regionFocusRequest, editPosition: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, toggleMixer: toggleMixer).equatable()
    }
}
private struct TimelineGridContent: View, Equatable {
    let show: ShowController
    let documents: ProjectDocuments
    let revision: UInt64
    let songID: UUID?
    let focusRequest: UUID
    let editPosition: Double
    let toggleMixer: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.show === rhs.show && lhs.revision == rhs.revision && lhs.songID == rhs.songID && lhs.focusRequest == rhs.focusRequest && lhs.editPosition == rhs.editPosition
    }
    @ObservedObject private var recordingLayout = RecordingLaneLayout.shared
    @Environment(\.locale) private var locale
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @State private var zoom = UserDefaults.standard.object(forKey: "jaras.timelineZoom") as? Double ?? 1.0
    @State private var rowLayoutCache = TrackLayoutCache()
    @State private var overlapCache = RegionOverlapCache()
    @State private var horizontalScroll = TimelineScrollPosition()
    @State private var verticalScroll = TimelineVerticalScroll()
    @State private var timelineExtent = 240.0
    @State private var resizingRegion: UUID?
    @State private var resizedStart = 0.0
    @State private var resizedEnd = 0.0
    @State private var regionSnapPoints: [Double] = []
    @State private var movingRegion: UUID?
    @State private var regionDelta = 0.0
    @State private var editingRegion: UUID?
    @State private var unifyingRegion: UUID?
    @State private var editingMarker: TimelineMarker?
    @State private var regionToDelete: (project: UUID, song: UUID, region: UUID)?
    @State private var confirmingRegionDelete = false
    @State private var resizingItem: UUID?
    @State private var resizedItemStart = 0.0
    @State private var resizedItemEnd = 0.0
    @State private var itemGainPreview = ItemGainPreview()
    @State private var insertionPreview = GridInsertionPreview()
    @State private var normalizingItems = Set<UUID>()
    @State private var showingNormalize = false
    @State private var itemsToSplit = Set<UUID>()
    @State private var splitPosition = 0.0
    @State private var confirmingSplit = false
    @State private var tracksToDelete = Set<UUID>()
    @State private var confirmingTrackDelete = false
    @State private var selectedClip: UUID?
    @State private var selectedClips = Set<UUID>()
    @State private var movingClip: UUID?
    @State private var movingStart = 0.0
    @State private var movingTrack: UUID?
    @State private var selectedTrack: UUID?
    @State private var selectedTracks = Set<UUID>()
    @State private var addingTrack = false
    @State private var draggingMain = false
    @State private var draggingSub = false
    @AppStorage("jaras.trackColumnWidth") private var savedLabelWidth = Double(SidebarWidthLimits.trackMixer)
    @AppStorage("jaras.trackColumnRestoreWidth") private var restoreLabelWidth = 248.0
    @State private var resizeStart: CGFloat?
    @State private var liveLabelWidth: CGFloat?
    @State private var trackHeight: CGFloat = 64
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if let originalSong = show.current {
                    let renderKey = TimelineRenderKey(revision: revision, songID: songID, movingClip: movingClip, movingStart: movingStart, movingTrack: movingTrack, movingRegion: movingRegion, regionDelta: regionDelta, resizingRegion: resizingRegion, resizedStart: resizedStart, resizedEnd: resizedEnd, recordingRevision: recordingLayout.revision, resizingItem: resizingItem, itemStart: resizedItemStart, itemEnd: resizedItemEnd)
                    let song = previewItemEdit(previewClipMove(previewRegionResize(previewRegionMove(originalSong))))
                    let regionLanes = RegionLanes(parts: song.parts)
                    let rulerHeight = CGFloat(regionLanes.count) * 16 + markerLaneHeight + 23
                    let maximumLabelWidth = max(161, min(486.5, geometry.size.width - 260))
                    let requestedLabelWidth = liveLabelWidth ?? CGFloat(savedLabelWidth)
                    let labelWidth = requestedLabelWidth <= 0 ? 0 : min(maximumLabelWidth, max(SidebarWidthLimits.trackMixer, requestedLabelWidth))
                    let mountedLabelWidth = labelWidth > 0 ? labelWidth : min(maximumLabelWidth, max(SidebarWidthLimits.trackMixer, CGFloat(restoreLabelWidth)))
                    let row = trackHeight
                    let extent = max(timelineExtent, song.duration + 120, max(0, geometry.size.width - labelWidth - 4) / (10 * TimelineZoomLimits.minimum) + 120)
                    let pixelsPerSecond = 10.0 * zoom
                    let width = extent * pixelsPerSecond
                    let rows = rowLayoutCache.layout(song.tracks, height: row, key: renderKey)
                    let selectionItems = originalSong.tracks.enumerated().flatMap { index, track in
                        track.clips.map { clip in
                            GridSelectionItem(id: clip.id, rect: CGRect(x: clip.startTime * pixelsPerSecond + 1, y: rulerHeight + rows.offsets[index] + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3, width: max(2,clip.duration * pixelsPerSecond - 2), height: rows.laneHeights[index] - 6), gain: clip.gain ?? 1, editable: track.kind == .standard, movable: track.kind != .timecode, contextActions: track.kind == .standard || track.kind == .video, textEditable: track.kind.isText && !clip.isProjectionMedia)
                        }
                    }
                    let contentHeight = max(geometry.size.height, rulerHeight + rows.totalHeight + row * 2)
                    let importDrop: ([NSItemProvider], CGPoint) -> Bool = { providers, location in
                        guard location.y >= verticalScroll.offset + rulerHeight else { return false }
                        let y = location.y - rulerHeight
                        let index = rows.offsets.indices.first { y >= rows.offsets[$0] && y < rows.offsets[$0] + rows.heights[$0] }
                        let track = index.map { originalSong.tracks[$0].id }
                        let start = itemPosition(location.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                        return documents.importAudio(providers, start: start, track: track, song: originalSong.id)
                    }
                        GridScrollView(axis: .vertical, contentWidth: geometry.size.width, contentHeight: contentHeight) {
                            TimelineColumnsLayout(mixerWidth: labelWidth, viewportWidth: geometry.size.width, height: contentHeight) {
                                TimelineMixerLayer(position: verticalScroll.tiles, identity: TimelineMixerIdentity(revision: revision, song: songID, width: mountedLabelWidth, heights: rows.heights, selection: selectedTracks)) { visibleY in
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: rulerHeight)
                                    ForEach(Array(song.tracks.enumerated()), id: \.element.id) { index, track in
                                        let silenced = song.isSilenced(track)
                                        if mixerRowIsMounted(start: rulerHeight + rows.offsets[index], height: rows.heights[index], visibleY: visibleY, viewportHeight: geometry.size.height) {
                                            TrackMixerRow(show: show, track: mixerMetadata(track), trackSelection: selectedTracks, nextTrack: index + 1 < song.tracks.count ? song.tracks[index + 1].id : nil, number: index + 1, selected: track.kind == .standard && selectedTracks.contains(track.id), silenced: silenced, showsMeterScale: mountedLabelWidth >= 260, showsFader: mountedLabelWidth >= 180, isFolder: index + 1 < song.tracks.count && song.tracks[index + 1].parentTrackID == track.id, lastChild: index + 1 == song.tracks.count || song.tracks[index + 1].parentTrackID != track.parentTrackID, groupSelection: selectedTracks.contains(track.id) && selectedTracks.count > 1 ? { show.groupTracks(selectedTracks) } : nil, select: { selectTrack(track.id, in: song) }, importVideo: { documents.chooseVideo(track: track.id) }).equatable().frame(height: rows.heights[index])
                                        } else { Color.clear.frame(height: rows.heights[index]) }
                                    }
                                    Color.clear.frame(height: row * 2)
                                }.frame(width: mountedLabelWidth).clipped().background(JarasTheme.mixer)
                                }.equatable().frame(width: labelWidth, alignment: .leading).clipped().allowsHitTesting(labelWidth > 0)
                                Color.clear.frame(width: 4)
                                GridScrollView(axis: .horizontal, contentWidth: width, contentHeight: contentHeight, fileDrop: { urls, point in
                                    importDrop(urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }, point)
                                }, fileDropPreview: { point in
                                    guard let point, point.y >= verticalScroll.offset + rulerHeight else { insertionPreview.update(nil); return }
                                    insertionPreview.update(itemPosition(point.x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond))
                                }) {
                                    ZStack(alignment: .topLeading) {
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            TimelineDrawing(visibleRect: CGRect(x: horizontalOffset, y: visibleY, width: geometry.size.width, height: geometry.size.height), song: song, renderKey: renderKey, rowHeight: row, rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips, movingClip: movingClip, movingStart: movingStart).equatable()
                                        }.frame(width: width, height: contentHeight)
                                        TimelineViewportLayer(horizontal: horizontalScroll, vertical: verticalScroll.tiles) { horizontalOffset, visibleY in
                                            ItemGainPreviewOverlay(preview: itemGainPreview, visibleRect: CGRect(x: horizontalOffset, y: visibleY, width: geometry.size.width, height: geometry.size.height), song: song, rows: rows, renderKey: renderKey, rulerHeight: rulerHeight, extent: extent, selectedClips: selectedClips)
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
                                                let itemY = rulerHeight + rows.offsets[index] + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3
                                                ClipDragInput(originY: itemY, select: { additive in
                                                    if additive {
                                                        if selectedClips.contains(clip.id) { selectedClips.remove(clip.id) }
                                                        else { selectedClips.insert(clip.id) }
                                                        selectedClip = selectedClips.contains(clip.id) ? clip.id : selectedClips.first
                                                    } else {
                                                        selectedClip = clip.id
                                                        selectedClips = [clip.id]
                                                    }
                                                }) { translation, pointerY, ended in
                                                    // A gesture belongs to the item pressed until mouse-up.
                                                    guard track.kind != .timecode, movingClip == nil || movingClip == clip.id else { return }
                                                    movingClip = clip.id
                                                    let originalStart = clip.startTime
                                                    movingStart = abs(translation.width) < 3 ? originalStart : itemPosition(originalStart + translation.width / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                                                    movingStart = track.constrainedItemStart(movingStart, item: clip)
                                                    let targetY = pointerY - rulerHeight
                                                    let targetIndex = rows.offsets.indices.first(where: { targetY >= rows.offsets[$0] && targetY < rows.offsets[$0] + rows.heights[$0] }) ?? index
                                                    movingTrack = track.kind == .standard && originalSong.tracks[targetIndex].kind == .standard ? originalSong.tracks[targetIndex].id : track.id
                                                    insertionPreview.update(movingStart)
                                                    timelineExtent = max(extent, movingStart + clip.duration + 120)
                                                    if ended {
                                                        if abs(translation.width) >= 3 || abs(translation.height) >= 3 {
                                                            show.moveClip(clip.id, start: movingStart, track: movingTrack)
                                                        }
                                                        movingClip = nil
                                                        movingTrack = nil
                                                        insertionPreview.update(nil)
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
                                                if track.kind == .standard && clip.duration * pixelsPerSecond >= 20 {
                                                    Button { show.send(.clipMute, target: clip.id) } label: {
                                                        Text("M").font(.system(size: 9, weight: .bold))
                                                            .foregroundStyle(clip.muted == true ? Color.white : JarasTheme.text)
                                                            .frame(width: 17, height: 13)
                                                            .background(clip.muted == true ? Color.red : Color.black.opacity(0.28))
                                                            .contentShape(Rectangle())
                                                    }.buttonStyle(.plain).accessibilityLabel("Mute item \(clip.name)")
                                                        .offset(x: clip.startTime * pixelsPerSecond + 2, y: itemY)
                                                }
                                            }
                                        }
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }.frame(width: width, height: contentHeight)
                                        #endif
                                        TimelineScrollLayer(position: horizontalScroll) { horizontalOffset in
                                            let visibleStart = max(0, horizontalOffset - 1024) / pixelsPerSecond
                                            let visibleEnd = (horizontalOffset + geometry.size.width + 1536) / pixelsPerSecond
                                        TimelinePinnedLayer(position: verticalScroll.pinned, width: width, height: contentHeight) { verticalOffset in
                                            ZStack(alignment: .topLeading) {
                                        TimelineHeader(visibleRect: CGRect(x: horizontalOffset, y: 0, width: geometry.size.width, height: rulerHeight), song: song, renderKey: renderKey, extent: extent).equatable()
                                            .frame(width: width, height: rulerHeight).offset(y: verticalOffset)
                                        ForEach(Array(song.parts.enumerated()).filter { $0.element.parentRegionID == nil && ($0.element.id == editingRegion || $0.element.id == unifyingRegion || $0.element.id == movingRegion || $0.element.id == resizingRegion || ($0.element.startTime <= visibleEnd && $0.element.endTime >= visibleStart)) }, id: \.element.id) { index, part in
                                            let edgePadding: CGFloat = song.parts.contains(where: { $0.parentRegionID == part.id }) ? 0 : 10
                                            regionHitArea(part, song: originalSong, pixelsPerSecond: pixelsPerSecond, canUnify: overlapCache.regions(song: originalSong, revision: revision).contains(part.id))
                                                .frame(width: max(1, (part.endTime - part.startTime) * pixelsPerSecond) + edgePadding * 2, height: edgePadding > 0 ? 24 : 16)
                                                .popover(isPresented: Binding(get: { editingRegion == part.id }, set: { if !$0 { editingRegion = nil } })) {
                                                    RegionEditor(region: part, initialColor: part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965)) { name, color, uppercase in
                                                        show.editRegion(part.id, name: name, color: color, uppercaseName: uppercase)
                                                    }.environment(\.locale, locale)
                                                }
                                                .popover(isPresented: Binding(get: { unifyingRegion == part.id }, set: { if !$0 { unifyingRegion = nil } })) {
                                                    UnifyRegionEditor { show.unifyRegions(containing: part.id, name: $0) }.environment(\.locale, locale)
                                                }
                                                .offset(x: part.startTime * pixelsPerSecond - edgePadding, y: verticalOffset + CGFloat(regionLanes.lanes[part.id] ?? 0) * 16 - (edgePadding > 0 ? 4 : 0))
                                        }
                                        #if os(macOS)
                                        MarkerEditTargets(song: song, markers: song.markers ?? [], scale: pixelsPerSecond, viewport: CGRect(x: horizontalOffset, y: 0, width: geometry.size.width, height: rulerHeight), edit: { editingMarker = $0 }, delete: { show.deleteManualMarker($0) })
                                            .frame(width: width, height: markerLaneHeight).offset(y: verticalOffset + CGFloat(regionLanes.count) * 16)
                                        TimelineRulerInput(extend: { timelineExtent = extent + 240 }, selectTime: { first, last in
                                            TimelineAreaSelection.shared.update(song: song.id,
                                                from: itemPosition(first * extent, song: song, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true),
                                                to: itemPosition(last * extent, song: song, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true))
                                        }) { fraction, rightClick in
                                            show.send(rightClick ? .subSeek : .editSeek, value: gridPosition(fraction * extent, song: song, pixelsPerSecond: pixelsPerSecond))
                                        }.frame(width: width, height: 23).offset(y: rulerHeight - 23 + verticalOffset)
                                        #else
                                        Color.clear.frame(width: width, height: 23).contentShape(Rectangle()).offset(y: rulerHeight - 23 + verticalOffset)
                                            .gesture(SpatialTapGesture().onEnded { value in
                                                show.send(.editSeek, value: gridPosition(min(1, max(0, value.location.x / width)) * extent, song: song, pixelsPerSecond: pixelsPerSecond))
                                            })
                                        #endif
                                        TimelineAreaOverlay(song: song.id, scale: pixelsPerSecond, height: geometry.size.height, rulerHeight: rulerHeight)
                                            .offset(y: verticalOffset)
                                        TimelinePlaybackLayer(show: show) {
                                            ZStack(alignment: .topLeading) {
                                                cursor(position: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, duration: extent, width: width, height: contentHeight, color: JarasTheme.green, secondary: false, rulerHeight: rulerHeight, verticalOffset: verticalOffset)
                                                if show.snapshot.transport.playing || show.snapshot.transport.paused == true {
                                                    cursor(position: show.snapshot.transport.position, duration: extent, width: width, height: contentHeight, color: Color(hex: 0xb478ff), secondary: false, rulerHeight: rulerHeight, verticalOffset: verticalOffset, playback: true)
                                                }
                                                if show.subCursorVisible {
                                                cursor(position: show.snapshot.transport.subPlay.position, duration: extent, width: width, height: contentHeight, color: JarasTheme.yellow, secondary: true, rulerHeight: rulerHeight, verticalOffset: verticalOffset)
                                                    .modifier(SubCursorBlink())
                                                }
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }
                                        GridInsertionPreviewOverlay(preview: insertionPreview, scale: pixelsPerSecond, rulerHeight: rulerHeight, viewportHeight: geometry.size.height)
                                            .offset(y: verticalOffset).allowsHitTesting(false)
                                        RegionBoundaryOverlay(parts: song.parts, scale: pixelsPerSecond, originX: max(0, horizontalOffset - 512))
                                            .frame(width: geometry.size.width + 1024, height: geometry.size.height)
                                            .offset(x: max(0, horizontalOffset - 512), y: verticalOffset)
                                            .allowsHitTesting(false)
                                            }.frame(width: width, height: contentHeight, alignment: .topLeading)
                                        }.frame(width: width, height: contentHeight)
                                        }

                                    }
                                    #if os(macOS)
                                    .overlay(alignment: .topLeading) {
                                        NativeTimelinePinnedLayer(width: max(0, geometry.size.width - labelWidth - 4), height: geometry.size.height, pinHorizontally: true, content:
                                                GridSelectionInput(origin: .zero, headerHeight: rulerHeight, items: selectionItems, selected: selectedClips, selectionChanged: { next in
                                                    selectedClips = next
                                                    selectedClip = selectionItems.first { next.contains($0.id) }?.id
                                                }, mute: { id in if originalSong.tracks.contains(where: { $0.kind == .standard && $0.clips.contains { $0.id == id } }) { show.send(.clipMute, target: id) } }, move: { id, translation, pointerY, ended in
                                                    guard movingClip == nil || movingClip == id,
                                                          !originalSong.tracks.contains(where: { $0.kind == .timecode && $0.clips.contains { $0.id == id } }),
                                                          let source = originalSong.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
                                                          let clip = originalSong.tracks[source].clips.first(where: { $0.id == id }) else { return }
                                                    movingClip = id
                                                    movingStart = abs(translation.width) < 3 ? clip.startTime : itemPosition(clip.startTime + translation.width / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                                                    movingStart = originalSong.tracks[source].constrainedItemStart(movingStart, item: clip)
                                                    let targetY = pointerY - rulerHeight
                                                    let target = rows.offsets.indices.first { targetY >= rows.offsets[$0] && targetY < rows.offsets[$0] + rows.heights[$0] } ?? source
                                                    movingTrack = originalSong.tracks[source].kind == .standard && originalSong.tracks[target].kind == .standard ? originalSong.tracks[target].id : originalSong.tracks[source].id
                                                    insertionPreview.update(movingStart)
                                                    timelineExtent = max(extent, movingStart + clip.duration + 120)
                                                    if ended {
                                                        show.moveClip(id, start: movingStart, track: movingTrack)
                                                        movingClip = nil; movingTrack = nil; insertionPreview.update(nil)
                                                    }
                                                }, seek: { x in show.send(.editSeek, value: gridPosition(x / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)) }, createRegion: { show.regionsFromSelection(selectedClips.contains($0) ? selectedClips : [$0]) }, interactionBlocked: gridInteractionBlocked, resize: { id, left, delta, ended in
                                                    guard let clip = originalSong.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { return }
                                                    resizingItem = id
                                                    let position = itemPosition((left ? clip.startTime : clip.startTime + clip.duration) + delta / pixelsPerSecond, song: originalSong, pixelsPerSecond: pixelsPerSecond, snappingRegionEnds: true)
                                                    resizedItemStart = left ? min(max(0, position), clip.startTime + clip.duration - 0.01) : clip.startTime
                                                    resizedItemEnd = left ? clip.startTime + clip.duration : max(clip.startTime + 0.01, position)
                                                    if let track = originalSong.tracks.first(where: { $0.clips.contains { $0.id == id } }) {
                                                        (resizedItemStart, resizedItemEnd) = track.constrainedItemEdges(start: resizedItemStart, end: resizedItemEnd, item: clip)
                                                    }
                                                    timelineExtent = max(extent, resizedItemEnd + 120)
                                                    if ended { show.resizeItem(id, start: resizedItemStart, end: resizedItemEnd); resizingItem = nil }
                                                }, gain: { id, value, ended in
                                                    show.previewItemGain(id, gain: value)
                                                    if ended { show.setItemGain(id, gain: value); itemGainPreview.clear() }
                                                    else { itemGainPreview.update(id: id, gain: value) }
                                                }, fx: { id, bypass in
                                                    if bypass { show.toggleClipFXAllBypass(id) }
                                                    else { openClipFXChain(id) }
                                                }, editText: { editTextItem($0) }, normalize: { ids in
                                                    normalizingItems = Set(originalSong.tracks.filter { $0.kind == .standard }.flatMap(\.clips).filter { ids.contains($0.id) }.map(\.id))
                                                    if !normalizingItems.isEmpty { showingNormalize = true }
                                                }, split: { confirmSplit($0) })
                                                .frame(width: max(0,geometry.size.width-labelWidth-4), height: geometry.size.height)
                                        ).frame(width: width, height: contentHeight, alignment: .topLeading)
                                    }
                                    .background(TimelineWheelInput(zoom: $zoom, position: editPosition / extent, extend: { timelineExtent = extent + 240 }, horizontalOffsetChanged: { if horizontalScroll.offset != $0 { horizontalScroll.offset = $0 } }, verticalOffsetChanged: { verticalScroll.update($0) }, focusRequest: show.regionFocusRequest, focusX: show.restoredCursorPosition.map { $0 * pixelsPerSecond } ?? song.parts.first(where: { $0.id == show.focusedRegion }).map { $0.startTime * pixelsPerSecond }, interactionBlocked: gridInteractionBlocked, changeTrackHeight: { factor in
                                        trackHeight = min(240, max(54, trackHeight * factor))
                                    }))
                                    #endif
                                    .coordinateSpace(name: "timeline").frame(width: width, height: contentHeight, alignment: .topLeading)
                                    .contentShape(Rectangle())
                                    #if !os(macOS)
                                    .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: importDrop)
                                    #endif
                                }.frame(width: max(0, geometry.size.width - labelWidth - 4), height: contentHeight)
                            }.frame(width: geometry.size.width, height: contentHeight, alignment: .topLeading)
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            if labelWidth > 0 {
                                HStack(spacing: 4) {
                                    Text("Track-Mixer").lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button { addingTrack = true } label: {
                                        Text(verbatim: "Add Track").font(.system(size: 9, weight: .semibold))
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
                                .frame(width: 12, height: geometry.size.height)
                                .offset(x: labelWidth - 4)
                        }
                }
            }
        }
        #if os(macOS)
        .background(RegionShortcut(delete: { deleteSelection() }, undo: { show.undo() }, redo: { show.redo() }, create: { show.regionsFromSelection(selectedClips) }, copy: { show.copyItems(selectedClips) }, move: { show.copyItems(selectedClips, moving: true) }, paste: {
            let pasted = show.pasteItems()
            if !pasted.isEmpty { selectedClips = pasted; selectedClip = pasted.first }
        }, createMarker: {
            guard show.current != nil else { return }
            editingMarker = TimelineMarker(id: UUID(), name: "", position: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, color: [UInt32(0x51ef93), 0xffc857, 0xb478ff, 0x53cfff, 0xff7998].randomElement()!)
        }))
        #endif
        .sheet(isPresented: $showingNormalize) { ItemNormalizationEditor(show: show, documents: documents, items: normalizingItems) }
        .alert("Split selected items at the edit cursor?", isPresented: $confirmingSplit) {
            Button("Cancel", role: .cancel) { itemsToSplit = [] }
            Button("Split") { show.splitItems(itemsToSplit, at: splitPosition); itemsToSplit = [] }
        }
        .alert("Delete selected tracks?", isPresented: $confirmingTrackDelete) {
            Button("Cancel", role: .cancel) { tracksToDelete = [] }
            Button("Delete", role: .destructive) {
                show.deleteTracks(tracksToDelete); selectedTracks.subtract(tracksToDelete)
                selectedTrack = selectedTracks.first; tracksToDelete = []
            }
        }
        .alert("Delete this region?", isPresented: $confirmingRegionDelete) {
            Button("Cancel", role: .cancel) { regionToDelete = nil }
            Button("Delete", role: .destructive) {
                if let target = regionToDelete, target.project == show.snapshot.project.id, target.song == show.current?.id {
                    show.deleteRegion(target.region, playlist: nil)
                }
                regionToDelete = nil
            }
        }
        .sheet(item: $editingMarker) { marker in
            NameColorEditor(title: "Editar marcador", initialName: marker.name, initialColor: marker.color, save: { name, color in
                var edited = marker; edited.name = name; edited.color = color
                show.setMarker(edited)
            }, maximumNameLength: marker.unifiedRegionID == nil ? TimelineMarker.maximumNameLength : nil).environment(\.locale, locale)
        }
        .onChange(of: selectedTrack) { show.reportTrackSelection($0) }
        .onChange(of: show.trackSelectionRequest) { request in
            if let request { selectedTrack = request.track; selectedTracks = [request.track] }
        }
        .onChange(of: show.splitItemsRequest) { _ in confirmSplit(selectedClips) }
        .onChange(of: show.addTrackRequest) { _ in addingTrack = true }
        .onChange(of: selectedTracks) { AudioExportSelection.shared.setTracks($0, song: show.current?.id) }
        .onChange(of: selectedClips) { AudioExportSelection.shared.setClips($0, song: show.current?.id) }
        .onChange(of: show.current?.id) { _ in itemGainPreview.clear(); insertionPreview.update(nil); selectedClip = nil; selectedClips.removeAll(); selectedTrack = nil; selectedTracks.removeAll() }
        .background(JarasTheme.background).sheet(isPresented: $addingTrack) {
            CreateTrackEditor(show: show, afterTrack: selectedTrack, close: { addingTrack = false }, created: { ids in
                let selectable = show.current?.tracks.filter { $0.kind == .standard && ids.contains($0.id) }.map(\.id) ?? []
                selectedTrack = selectable.first; selectedTracks = Set(selectable)
            }).environment(\.locale, locale)
        }
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
    private func deleteSelection() {
        guard let song = show.current else { return }
        let items = selectedClips.intersection(song.tracks.flatMap(\.clips).map(\.id))
        let tracks = selectedTracks.intersection(song.tracks.filter { $0.kind == .standard }.map(\.id))
        switch GridDeleteTarget(items: items, tracks: tracks) {
        case .items(let ids): show.deleteItems(ids); selectedClips = []; selectedClip = nil
        case .tracks(let ids): tracksToDelete = ids; confirmingTrackDelete = true
        case .none: break
        }
    }
    private func selectTrack(_ id: UUID, in song: Song) {
        guard song.tracks.contains(where: { $0.id == id && $0.kind == .standard }) else { return }
        #if os(macOS)
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
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
        RegionRightClick(edit: { editingRegion = part.id }, unify: canUnify ? { requestUnification(part.id) } : nil, disunify: song.parts.contains(where: { $0.parentRegionID == part.id }) ? { show.disunifyRegion(part.id) } : nil, delete: {
            regionToDelete = (show.snapshot.project.id, song.id, part.id)
            confirmingRegionDelete = true
        }, resizable: !song.parts.contains(where: { $0.parentRegionID == part.id }), drag: { translation, ended, edge in
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
                let start = itemPosition(original.startTime + translation / pixelsPerSecond, song: song, pixelsPerSecond: pixelsPerSecond)
                movingRegion = part.id
                regionDelta = start - original.startTime
                timelineExtent = max(timelineExtent, original.endTime + regionDelta + 120)
                if ended { show.moveRegion(part.id, start: start) }
            }
            if ended { movingRegion = nil; regionDelta = 0 }
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
        var result = song
        for track in result.tracks.indices {
            for clip in result.tracks[track].clips.indices {
                let item = result.tracks[track].clips[clip]
                if item.startTime >= region.startTime - 1e-8 && item.startTime + item.duration <= region.endTime + 1e-8 {
                    result.tracks[track].clips[clip].startTime = max(0, item.startTime + regionDelta)
                }
            }
        }
        for index in result.parts.indices where result.parts[index].id == movingRegion || result.parts[index].parentRegionID == movingRegion {
            result.parts[index].startTime += regionDelta
            result.parts[index].endTime += regionDelta
            result.duration = max(result.duration, result.parts[index].endTime)
        }
        if result.markers != nil {
            for index in result.markers!.indices where result.markers![index].unifiedRegionID == movingRegion { result.markers![index].position = max(0, result.markers![index].position + regionDelta) }
        }
        return RegionLanes(parts: result.parts).count <= 2 ? result : song
    }
    private func itemPosition(_ time: Double, song: Song, pixelsPerSecond: Double, snappingRegionEnds: Bool = false) -> Double {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.shift) { return max(0, time) }
        #endif
        return TimelineTempo.snap(time, bar: song.barSeconds, beats: song.meterBeats, pixelsPerSecond: pixelsPerSecond,
                                  anchors: song.parts.lazy.map(\.startTime), additionalAnchors: snappingRegionEnds ? song.parts.lazy.map(\.endTime) : nil, cursor: editPosition)
    }
    private func gridPosition(_ time: Double, song: Song, pixelsPerSecond: Double) -> Double {
        TimelineTempo.snap(time, bar: song.barSeconds, beats: song.meterBeats, pixelsPerSecond: pixelsPerSecond,
                           anchors: song.parts.lazy.map(\.startTime))
    }

    @ViewBuilder
    private func mixerDivider(width: CGFloat, maximum: CGFloat) -> some View {
        #if os(macOS)
        MixerResizeHandle(width: width, maximum: maximum, minimum: SidebarWidthLimits.trackMixer, onStart: {
            if width > 0 { restoreLabelWidth = Double(width) }
        }, onToggle: toggleMixer, onEnd: { finalWidth in
            savedLabelWidth = Double(finalWidth)
            liveLabelWidth = nil
        }) { liveLabelWidth = $0 }
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
    private func cursor(position: Double, duration: Double, width: CGFloat, height: CGFloat, color: Color, secondary: Bool, rulerHeight: CGFloat, verticalOffset: CGFloat, playback: Bool = false) -> some View {
        let transport = show.snapshot.transport
        let merged = !playback && show.subCursorVisible && abs((transport.editPosition ?? transport.position) - transport.subPlay.position) * width / max(1, duration) < 0.5
        let displayColor = merged ? Color(hex: 0xaaee73) : color
        let dragging = !playback && (merged ? (draggingSub || draggingMain) : (secondary ? draggingSub : draggingMain))
        let playing = (playback && transport.playing) || (secondary && transport.subPlay.playing)
        let glowing = dragging || playing
        let x = min(width - 1, max(0, width * position / max(1, duration)))
        let headY: CGFloat = rulerHeight - 23 + verticalOffset
        let tipY = playback ? rulerHeight + verticalOffset : headY + 17
        let head = Path { path in
            path.move(to: CGPoint(x: 7, y: headY + 5))
            path.addLine(to: CGPoint(x: 21, y: headY + 5))
            path.addLine(to: CGPoint(x: 14, y: tipY))
            path.closeSubpath()
        }
        return ZStack(alignment: .topLeading) {
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
                if !playback {
                if merged {
                    head.fill(displayColor.opacity(0.18)).frame(width: 28, height: height)
                    head.stroke(displayColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 2])).frame(width: 28, height: height)
                } else { head.fill(displayColor).frame(width: 28, height: height) }
                }
            }
            if !playback {
            Color.clear.frame(width: 28, height: 22).contentShape(Rectangle()).offset(y: headY)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        if secondary { draggingSub = true } else { draggingMain = true }
                        if let song = show.current { show.send(secondary ? .subSeek : .editSeek, value: gridPosition(Double(value.location.x / width) * duration, song: song, pixelsPerSecond: width / duration)) }
                    }.onEnded { _ in draggingSub = false; draggingMain = false })
                .accessibilityLabel(LocalizedStringKey(secondary ? "Agulha Sub Play" : "Agulha de edição"))
            }
        }.frame(width: 28, height: height, alignment: .topLeading).offset(x: x - 14)

    }
}
/// Transport ticks repaint needles, not the imported project's track and item tree.
private struct TimelinePlaybackLayer<Content: View>: View {
    @ObservedObject var show: ShowController
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
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
            let bandHeight = max(0, height - rulerHeight + 23)
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
                .offset(x: range.start * scale, y: rulerHeight - 23).allowsHitTesting(false)
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

/// AppKit clips the mounted controls. Scrolling must not recreate faders,
/// menus and input views when the canvas advances to its next tile.
/// Column dimensions are already known. Avoid asking every mixer descendant
/// for explicit alignment guides each time the timeline scale changes.
private struct TimelineColumnsLayout: Layout {
    let mixerWidth: CGFloat
    let viewportWidth: CGFloat
    let height: CGFloat
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
                              proposal: ProposedViewSize(width: 4, height: height))
        subviews[index + 1].place(at: CGPoint(x: bounds.minX + mixerWidth + 4, y: bounds.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: max(0, viewportWidth - mixerWidth - 4), height: height))
    }
}


private struct TimelineMixerIdentity: Equatable {
    let revision: UInt64
    let song: UUID?
    let width: CGFloat
    let heights: [CGFloat]
    let selection: Set<UUID>
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
        #if os(macOS)
        content(0)
        #else
        TimelineScrollLayer(position: position, content: content)
        #endif
    }
}

private func mixerRowIsMounted(start: CGFloat, height: CGFloat, visibleY: CGFloat, viewportHeight: CGFloat) -> Bool {
    #if os(macOS)
    return true
    #else
    return start + height >= visibleY - 512 && start <= visibleY + viewportHeight + 1024
    #endif
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

private struct TimelineViewportLayer<Content: View>: View {
    @ObservedObject var horizontal: TimelineScrollPosition
    @ObservedObject var vertical: TimelineScrollPosition
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content
    var body: some View { content(horizontal.offset, vertical.offset) }
}

struct TimelineDrawing: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visibleRect == rhs.visibleRect && lhs.renderKey == rhs.renderKey && lhs.rowHeight == rhs.rowHeight && lhs.rulerHeight == rhs.rulerHeight && lhs.extent == rhs.extent && lhs.selectedClips == rhs.selectedClips && lhs.movingClip == rhs.movingClip && lhs.movingStart == rhs.movingStart && lhs.colorScheme == rhs.colorScheme
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
    @State private var rowLayoutCache = TrackLayoutCache()
    var body: some View {
        let rows = rowLayoutCache.layout(song.tracks, height: rowHeight, key: renderKey)
        ViewportTimelineCanvas(visibleRect: visibleRect, identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, rowHeight: rowHeight, rulerHeight: rulerHeight, selectedClips: selectedClips)) { context, size, tile in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(JarasTheme.grid))
            let scale = size.width / extent
            let barSeconds = song.barSeconds
            let bars = Int(ceil(extent / barSeconds))
            let gridStep = Int(pow(2, max(0, ceil(log2(4 / max(0.001, barSeconds * scale))))))
            let firstBar = max(0, Int(floor(tile.minX / (barSeconds * scale))) / gridStep * gridStep)
            let lastBar = max(firstBar, min(bars, Int(ceil(tile.maxX / (barSeconds * scale)))))
            for bar in stride(from: firstBar, through: lastBar, by: gridStep) {
                let x = CGFloat(bar) * barSeconds * scale
                if (bar / gridStep) % 2 == 0 { context.fill(Path(CGRect(x: x, y: rulerHeight, width: barSeconds * scale * Double(gridStep), height: size.height - rulerHeight)), with: .color(.white.opacity(0.022))) }
                var line = Path(); line.move(to: CGPoint(x: x, y: rulerHeight)); line.addLine(to: CGPoint(x: x, y: size.height)); context.stroke(line, with: .color(.black.opacity(0.55)), lineWidth: 1)

                if barSeconds * scale > 28 {
                    for beat in 1..<song.meterBeats { let bx = x + CGFloat(beat) * barSeconds * scale / Double(song.meterBeats); var minor = Path(); minor.move(to: CGPoint(x: bx, y: rulerHeight)); minor.addLine(to: CGPoint(x: bx, y: size.height)); context.stroke(minor, with: .color(.black.opacity(0.22)), lineWidth: 0.5) }
                }
            }
            // Empty space keeps the same grid spacing without creating or stretching tracks.
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
                context.stroke(emptyLines, with: .color(.black.opacity(0.6)), lineWidth: 1)
            }
            let hasSolo = song.tracks.contains { $0.solo }
            for (index, track) in song.tracks.enumerated() {
                let trackSilenced = track.mute || (hasSolo && !track.solo)
                let y = rulerHeight + rows.offsets[index]
                if y > tile.maxY || y + rows.heights[index] < tile.minY { continue }
                var rowLine = Path(); rowLine.move(to: CGPoint(x: 0, y: y)); rowLine.addLine(to: CGPoint(x: size.width, y: y)); context.stroke(rowLine, with: .color(.black.opacity(0.6)), lineWidth: 1)
                for clip in track.clips {
                    let silenced = trackSilenced || clip.muted == true
                    let selected = selectedClips.contains(clip.id)
                    let rect = CGRect(x: clip.startTime * scale + 1, y: y + CGFloat(rows.lanes[index].lanes[clip.id] ?? 0) * rows.laneHeights[index] + 3, width: max(2, clip.duration * scale - 2), height: rows.laneHeights[index] - 6)
                    guard rect.intersects(tile.insetBy(dx: -6, dy: -6)) else { continue }
                    drawTimelineItem(clip, track: track, rect: rect, selected: selected, silenced: silenced, scale: scale, tile: tile, context: &context)
                }
            }
            // Static marker lines share the tiled grid surface; no per-frame overlay work.
            for marker in song.markers ?? [] {
                let x = marker.position * scale
                guard x >= tile.minX - 3, x <= tile.maxX + 3 else { continue }
                let color = Color(hex: marker.color)
                var line = Path()
                line.move(to: CGPoint(x: x, y: rulerHeight))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(color.opacity(0.16)), lineWidth: 5)
                context.stroke(line, with: .color(color), lineWidth: 1)
            }
        }
    }
}

/// During a gain gesture only this bounded surface is invalidated. The base grid,
/// headers, mixer and lane geometry keep their existing render and layout.
private struct ItemGainPreviewOverlay: View {
    @ObservedObject var preview: ItemGainPreview
    let visibleRect: CGRect
    let song: Song
    let rows: TrackRowLayout
    let renderKey: TimelineRenderKey
    let rulerHeight: CGFloat
    let extent: Double
    let selectedClips: Set<UUID>
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
            ViewportTimelineCanvas(visibleRect: visibleRect, identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light, gainPreview: state)) { context, size, tile in
                let scale = size.width / extent
                let rect = CGRect(x: source.startTime * scale + 1, y: y, width: max(2, source.duration * scale - 2), height: height)
                guard rect.intersects(tile) else { return }
                // Restore the opaque backing under this one item before repainting
                // its translucent fill, so the original waveform never shows through.
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(JarasTheme.grid))
                let stripe = Int(floor(source.startTime / song.barSeconds))
                if stripe % 2 == 0 { context.fill(path, with: .color(.white.opacity(0.022))) }
                drawTimelineItem(clip, track: track, rect: rect, selected: selectedClips.contains(source.id), silenced: silenced, scale: scale, tile: tile, context: &context)
            }
        }
    }
}

private func drawTimelineItem(_ clip: AudioClip, track: Track, rect: CGRect, selected: Bool, silenced: Bool, scale: Double, tile: CGRect, context: inout GraphicsContext) {
    let color = silenced ? Color(white: selected ? 0.7 : 0.55) : JarasTheme.track(track, emphasized: selected)
    let path = Path(roundedRect: rect, cornerRadius: 3)
    context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(silenced ? 0.55 : 1), color.opacity(silenced ? 0.25 : selected ? 1 : 0.78)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
    context.stroke(path, with: .color(selected ? JarasTheme.green : color.opacity(0.75)), lineWidth: selected ? 1.5 : 0.6)
    var titleContext = context
    titleContext.clip(to: path)
    titleContext.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(13, rect.height))), with: .color(.black.opacity(0.16)))
    let controls = GridSelectionItem(id: clip.id, rect: rect, gain: clip.gain ?? 1, editable: track.kind == .standard, textEditable: track.kind.isText && !clip.isProjectionMedia)
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
            var glyph = Path()
            glyph.move(to: CGPoint(x: x, y: y + 7))
            glyph.addLine(to: CGPoint(x: x, y: y))
            glyph.addLine(to: CGPoint(x: x + 3.5, y: y + 4))
            glyph.addLine(to: CGPoint(x: x + 7, y: y))
            glyph.addLine(to: CGPoint(x: x + 7, y: y + 7))
            titleContext.stroke(glyph, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }
    if let fxRect = controls.fxRect, fxRect.intersects(tile) {
        let inserted = !(clip.fx?.inserted.isEmpty ?? true)
        titleContext.fill(Path(fxRect), with: .color(clip.fxBypassed == true ? .red : .black.opacity(0.28)))
        let x = fxRect.midX - 6, y = fxRect.midY - 3.5
        var glyph = Path()
        glyph.move(to: CGPoint(x: x, y: y + 7)); glyph.addLine(to: CGPoint(x: x, y: y)); glyph.addLine(to: CGPoint(x: x + 4, y: y))
        glyph.move(to: CGPoint(x: x, y: y + 3)); glyph.addLine(to: CGPoint(x: x + 3.5, y: y + 3))
        glyph.move(to: CGPoint(x: x + 6, y: y)); glyph.addLine(to: CGPoint(x: x + 12, y: y + 7))
        glyph.move(to: CGPoint(x: x + 12, y: y)); glyph.addLine(to: CGPoint(x: x + 6, y: y + 7))
        titleContext.stroke(glyph, with: .color(clip.fxBypassed == true ? .white : inserted ? JarasTheme.green : .white), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }
    if let knob = controls.gainKnobRect, knob.intersects(tile) {
        let center = CGPoint(x: knob.midX, y: knob.midY)
        let radius: CGFloat = 4.5, angle = 135 + controls.gainPosition * 270
        var ring = Path(); ring.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
        titleContext.stroke(ring, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        if controls.gainPosition > 0 {
            var fill = Path(); fill.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(angle), clockwise: false)
            titleContext.stroke(fill, with: .color(JarasTheme.green), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        let radians = angle * .pi / 180
        var needle = Path(); needle.move(to: center); needle.addLine(to: CGPoint(x: center.x + cos(radians) * 3.5, y: center.y + sin(radians) * 3.5))
        titleContext.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
    #endif
    let titleInset = controls.titleInset
    let title = track.kind == .timecode ? (track.timecode?.mode ?? "mtc").uppercased() : clip.name
    drawTimelineName(title, in: CGRect(x: rect.minX + titleInset, y: rect.minY, width: max(0, rect.width - titleInset), height: min(13, rect.height)), visibleRect: tile, context: &context)
    if track.kind == .timecode {
        let body = CGRect(x: rect.minX, y: rect.minY + 13, width: rect.width, height: max(0, rect.height - 13))
        if body.height >= 12 {
            drawTimelineName("TIMECODE", in: body, visibleRect: tile, centered: true, context: &context)
        }
        return
    }
    if track.kind.isText && !clip.isProjectionMedia {
        if let text = clip.text, !text.isEmpty, rect.width > 16, rect.height > 26 {
            let textRect = CGRect(x: rect.minX + 5, y: rect.minY + 17, width: rect.width - 10, height: rect.height - 20)
            titleContext.clip(to: Path(textRect))
            titleContext.draw(Text(verbatim: text).font(.system(size: 12, weight: .semibold)).foregroundColor(.black), in: textRect)
        }
        return
    }
    var wave = Path()
    let channels = clip.waveformChannels.flatMap { $0.isEmpty ? nil : $0 } ?? [clip.waveform]
    let waveTop = rect.minY + min(14, rect.height * 0.35)
    let channelHeight = max(1, rect.maxY - waveTop - 2) / CGFloat(channels.count)
    for (channel, peaks) in channels.enumerated() {
    let middle = waveTop + channelHeight * (CGFloat(channel) + 0.5), amplitude = channelHeight * 0.43 * min(1, max(0, clip.gain ?? 1))
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
        let intervals = CGFloat(max(1, peaks.count - 1))
        let first = max(0, min(peaks.count - 1, Int(floor((tile.minX - rect.minX) / rect.width * intervals))))
        let last = max(first, min(peaks.count - 1, Int(ceil((tile.maxX - rect.minX) / rect.width * intervals))))
        let step = max(1, Int(floor(CGFloat(peaks.count) / max(1, rect.width))))
        for sample in stride(from: first, through: last, by: step) {
            let end = min(peaks.count, sample + step)
            let peak = peaks[sample..<end].max() ?? 0
            let x = rect.minX + CGFloat(sample) / intervals * rect.width
            wave.move(to: CGPoint(x: x, y: middle - peak * amplitude)); wave.addLine(to: CGPoint(x: x, y: middle + peak * amplitude))
        }
    }
    }
    context.stroke(wave, with: .color(.black.opacity(silenced ? 0.48 : 0.72)), lineWidth: 0.7)
    if track.kind == .standard, clip.loopLength != nil {
        let visible = max(clip.startTime, Double(tile.minX / scale))...max(clip.startTime, Double(tile.maxX / scale))
        var seams = Path()
        for boundary in ClipRepetitionBoundaries(clip: clip, visible: visible, minimumSpacing: 3 / scale) {
            let x = boundary * scale
            seams.move(to: CGPoint(x: x, y: waveTop))
            seams.addLine(to: CGPoint(x: x, y: rect.maxY - 1))
        }
        var seamContext = context
        seamContext.clip(to: path)
        seamContext.stroke(seams, with: .color(.black.opacity(0.65)), lineWidth: 2)
        seamContext.stroke(seams, with: .color(.white.opacity(0.8)), lineWidth: 0.8)
    }
    if track.kind == .standard && rect.width >= 28 && rect.height >= 30 {
        let gain = clip.gain ?? 1
        let label = gain <= 0 ? "−∞ dB" : String(format: "%+.1f dB", 20 * log10(gain))
        let labelWidth = ceil(TimelineResolvedName.label(label, context: titleContext).width) + 8
        let labelRect = CGRect(x: rect.minX + 1, y: rect.minY + 17, width: min(labelWidth, rect.width - 2), height: 13)
        if labelRect.intersects(tile) {
            titleContext.fill(Path(roundedRect: labelRect, cornerRadius: 3), with: .color(.black.opacity(0.38)))
            drawTimelineName(label, in: labelRect, visibleRect: tile, context: &titleContext)
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
        view.onStart = onStart
        view.onToggle = onToggle
        view.onEnd = onEnd
    }
}
final class MixerDividerView: ResizeHoverIndicatorView {
    var columnWidth: CGFloat = 138
    var maximum: CGFloat = 486.5
    var minimum: CGFloat = 0
    var direction: CGFloat = 1
    var onStart: (() -> Void)?
    var onToggle: (() -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    private var latestWidth: CGFloat = 0
    var onResize: ((CGFloat) -> Void)?
    private var startingWidth: CGFloat = 0
    private var startingX: CGFloat = 0
    private var mouseIsDown = false
    private var didDrag = false
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSRect(x: bounds.midX - 2, y: bounds.minY, width: 4, height: bounds.height).fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 14, width: 2, height: 28), xRadius: 1, yRadius: 1).fill()
        super.draw(dirtyRect)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { mouseIsDown = false; onToggle?(); return }
        mouseIsDown = true
        didDrag = false
        onStart?()
        startingWidth = columnWidth
        latestWidth = columnWidth
        startingX = event.locationInWindow.x
    }
    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown else { return }
        if abs(event.locationInWindow.x - startingX) >= 3 { didDrag = true }
        guard didDrag else { return }
        let width = min(maximum, max(minimum, startingWidth + direction * (event.locationInWindow.x - startingX)))
        latestWidth = width
        onResize?(latestWidth)
    }
    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseDragged(with: event)
        mouseIsDown = false
        if didDrag { onEnd?(latestWidth) }
        if !didDrag && startingWidth == 0 { onToggle?() }
    }
}
#endif

#if os(macOS)
private struct RegionShortcut: NSViewRepresentable {
    let delete: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let create: () -> Void
    let copy: () -> Bool
    let move: () -> Bool
    let paste: () -> Void
    let createMarker: () -> Void
    func makeNSView(context: Context) -> RegionShortcutView { RegionShortcutView() }
    func updateNSView(_ view: RegionShortcutView, context: Context) { view.create = create; view.createMarker = createMarker; view.delete = delete; view.undoEdit = undo; view.redoEdit = redo; view.copyItems = copy; view.moveItems = move; view.pasteItems = paste }
}
private final class RegionShortcutView: NSView {
    var create: (() -> Void)?
    var createMarker: (() -> Void)?
    var delete: (() -> Void)?
    var undoEdit: (() -> Void)?
    var redoEdit: (() -> Void)?
    var copyItems: (() -> Bool)?
    var moveItems: (() -> Bool)?
    var pasteItems: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if ControlMappings.shared.handleKey(event) { return nil }
            guard let self, event.window === self.window, self.window?.isKeyWindow == true,
                  self.window?.attachedSheet == nil,
                  !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField) else { return event }
            let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
            if flags == .command || flags == .control {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": if event.isARepeat || self.copyItems?() == true { return nil }
                case "x": if event.isARepeat || self.moveItems?() == true { return nil }
                case "v": if !event.isARepeat { self.pasteItems?() }; return nil
                default: break
                }
            }
            if event.keyCode == 53, flags.isEmpty { TimelineAreaSelection.shared.clear(); return nil }
            if [51,117].contains(event.keyCode), flags.isEmpty {
                if SetlistKeyView.handleDelete(event) { return nil }
                if !event.isARepeat { self.delete?() }; return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "z",
               flags == .command || flags == .control || flags == [.command,.shift] || flags == [.control,.shift] {
                if !event.isARepeat { if flags.contains(.shift) { self.redoEdit?() } else { self.undoEdit?() } }; return nil
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

@MainActor private final class TrackLayoutCache {
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
        lhs.visibleRect == rhs.visibleRect && lhs.renderKey == rhs.renderKey && lhs.extent == rhs.extent && lhs.colorScheme == rhs.colorScheme
    }
    @Environment(\.colorScheme) private var colorScheme
    let visibleRect: CGRect
    let song: Song
    let renderKey: TimelineRenderKey
    let extent: Double
    var body: some View {
        ViewportTimelineCanvas(visibleRect: visibleRect, identity: TimelineTileIdentity(renderKey: renderKey, extent: extent, light: colorScheme == .light)) { context, size, tile in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(JarasTheme.panel))
            let scale = size.width / extent
            let lanes = RegionLanes(parts: song.parts)
            let regionHeight = CGFloat(lanes.count) * 16
            for (index, part) in song.parts.enumerated() {
                guard part.parentRegionID == nil else { continue }
                let rect = CGRect(x: part.startTime * scale, y: CGFloat(lanes.lanes[part.id] ?? 0) * 16, width: max(1, (part.endTime - part.startTime) * scale), height: 16)
                guard rect.intersects(tile) else { continue }
                context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(Color(hex: part.color ?? (index % 2 == 0 ? 0x705264 : 0x885965))))
                var labelContext = context
                labelContext.clip(to: Path(roundedRect: rect, cornerRadius: 6))
                // Parts are stored in creation order; moving a region keeps its number.
                let identifier = labelContext.resolve(Text(verbatim: song.parts.contains(where: { $0.parentRegionID == part.id }) ? JarasLocalization.string("Special") : String(format: "%dst  %02d", part.semitones, index + 1))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.white))
                let identifierWidth = ceil(identifier.measure(in: CGSize(width: 1000, height: 16)).width)
                if rect.width >= identifierWidth + 8 {
                    labelContext.draw(identifier, at: CGPoint(x: rect.maxX - 4, y: rect.minY + 2), anchor: .topTrailing)
                    let nameRect = CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - identifierWidth - 8), height: rect.height)
                    drawTimelineName(part.displayName, in: nameRect, color: .white, visibleRect: tile, context: &labelContext)
                }
            }
            let markers = song.markers ?? []
            let labels = Dictionary(uniqueKeysWithValues: markers.map { marker in
                (marker.id, context.resolve(Text(verbatim: song.markerLabel(marker)).font(.system(size: 9, weight: .semibold)).foregroundColor(Color.black)))
            })
            let widths = labels.mapValues { Double(ceil($0.measure(in: CGSize(width: 1000, height: 23)).width)) }
            let flagWidths = TimelineMarker.flagWidths(markers, scale: scale, widths: widths)
            for marker in markers {
                let x = marker.position * scale
                guard x + (widths[marker.id] ?? 0) + 24 >= tile.minX, x - 5 <= tile.maxX else { continue }
                let color = Color(hex: marker.color)
                var stem = Path(); stem.move(to: CGPoint(x: x, y: regionHeight + 1)); stem.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(stem, with: .color(color.opacity(0.16)), lineWidth: 5)
                context.stroke(stem, with: .color(color), lineWidth: 1)
                if let flagWidth = flagWidths[marker.id] {
                    let rect = CGRect(x: x, y: regionHeight + 1, width: flagWidth, height: markerLaneHeight - 2)
                    context.fill(Path(rect), with: .color(color))
                    drawTimelineName(song.markerLabel(marker), in: rect, color: .black, visibleRect: tile, context: &context)
                }
            }
            for y in (0...lanes.count).map { CGFloat($0) * 16 + 0.5 } + [regionHeight + markerLaneHeight + 0.5, size.height - 0.5] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(JarasTheme.line), lineWidth: 1)
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

private struct TimelineTileIdentity: Equatable {
    let renderKey: TimelineRenderKey
    let extent: Double
    let light: Bool
    var rowHeight: CGFloat = 0
    var rulerHeight: CGFloat = 0
    var selectedClips: Set<UUID> = []
    var gainPreview: ItemGainPreview.State? = nil
}
/// A bounded backing surface keeps its drawing while it remains in the viewport.
private struct TimelineCanvasSurface: View, Equatable {
    let identity: TimelineTileIdentity
    let size: CGSize
    let tile: CGRect
    let draw: (inout GraphicsContext, CGSize, CGRect) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tile == rhs.tile && lhs.size == rhs.size && lhs.identity == rhs.identity
    }
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            var translated = context
            translated.translateBy(x: -tile.minX, y: -tile.minY)
            translated.clip(to: Path(tile))
            draw(&translated, size, tile)
        }
    }
}

private struct ViewportTimelineCanvas: View {
    let visibleRect: CGRect
    let identity: TimelineTileIdentity
    let draw: (inout GraphicsContext, CGSize, CGRect) -> Void
    private let bucket: CGFloat = 512
    // Stable vertical strips reuse the existing drawing during scrolling.
    // Horizontal surfaces remain wide to limit view count during timeline zoom.
    private let maximumSurface: CGFloat = 3072
    private let verticalSurface: CGFloat = 1024
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let left = min(size.width, max(0, floor(visibleRect.minX / bucket) * bucket - bucket))
            let top = min(size.height, max(0, floor(visibleRect.minY / bucket) * bucket - bucket))
            let right = min(size.width, ceil(visibleRect.maxX / bucket) * bucket + bucket)
            let bottom = min(size.height, ceil(visibleRect.maxY / bucket) * bucket + bucket)
            let columns = max(1, Int(ceil(max(0, right - left) / maximumSurface)))
            let firstRow = Int(floor(top / verticalSurface))
            let lastRow = max(firstRow + 1, Int(ceil(bottom / verticalSurface)))
            ZStack(alignment: .topLeading) {
                ForEach(firstRow..<lastRow, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        let x = left + CGFloat(column) * maximumSurface
                        let y = CGFloat(row) * verticalSurface
                        let tile = CGRect(x: x, y: y,
                                          width: max(0, min(maximumSurface, right - x)),
                                          height: max(0, min(verticalSurface, size.height - y)))
                        TimelineCanvasSurface(identity: identity, size: size, tile: tile, draw: draw).equatable()
                            .frame(width: tile.width, height: tile.height)
                            .clipped().offset(x: tile.minX, y: tile.minY)
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
    @State private var selecting = false
    let originY: CGFloat
    let select: (Bool) -> Void
    let update: (CGSize, CGFloat, Bool) -> Void
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged {
                    if !selecting { select(false); selecting = true }
                    update($0.translation, $0.location.y, false)
                }
                .onEnded { update($0.translation, $0.location.y, true); selecting = false })
    }
}
#endif

private struct SubCursorBlink: ViewModifier {
    @State private var dimmed = false
    func body(content: Content) -> some View {
        content.opacity(dimmed ? 0.3 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { dimmed = true } }
            .onDisappear { dimmed = false }
    }
}

struct TimelineRenderKey: Equatable {
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
private struct MarkerEditTargets: View {
    let song: Song
    let markers: [TimelineMarker]
    let scale: Double
    let viewport: CGRect
    let edit: (TimelineMarker) -> Void
    let delete: (UUID) -> Void
    var body: some View {
        let measured = Dictionary(uniqueKeysWithValues: markers.map { marker in
            (marker.id, Double((song.markerLabel(marker) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).width))
        })
        let widths = TimelineMarker.flagWidths(markers, scale: scale, widths: measured)
        ZStack(alignment: .topLeading) {
            ForEach(markers.filter { $0.position * scale + max(8, widths[$0.id] ?? 0) >= viewport.minX && $0.position * scale <= viewport.maxX }) { marker in
                MarkerEditAnchor(edit: { edit(marker) }, delete: {
                    if marker.unifiedRegionID == nil, marker.sourceRegionID == nil { delete(marker.id) }
                })
                    .frame(width: max(8, widths[marker.id] ?? 0), height: markerLaneHeight)
                    .offset(x: marker.position * scale)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
