import Foundation
private struct Track: Equatable { var id = UUID(); var value = 0; var instrumentIcon: String? }
private typealias NativeFXSettings = Int
private struct OutputPatch: Equatable { var firstChannel: Int; var channelCount: Int }
private enum TrackInstrumentIcon: String { case piano }
// INSERT_RENDER_STATE
// INSERT_STRIP_VERSIONS
private let tracks = (0..<100).map { _ in Track() }
let project = UUID()
private func state(_ selection: Set<UUID>, items: [Track] = tracks) -> FooterMixerRenderState {
    FooterMixerRenderState(project: project, tracks: items, masterFX: nil, masterVolume: 1, masterPan: 0,
                          masterMute: false, masterSolo: false, masterMono: false, masterColor: nil, selection: selection)
}
private let versions = FooterMixerStripVersions()
let original = versions.update(state([]), active: true, locale: "pt_BR")
let master = versions.masterVersion
let selectedA = versions.update(state([tracks[2].id]), active: true, locale: "pt_BR")
precondition(original.indices.filter { original[$0] != selectedA[$0] } == [2],
             "selecting one channel cannot replace 100 unrelated hosting roots")
let selectedB = versions.update(state([tracks[5].id]), active: true, locale: "pt_BR")
precondition(original.indices.filter { selectedA[$0] != selectedB[$0] } == [2, 5],
             "moving a selection updates only the former and new channel")
let group = versions.update(state([tracks[5].id, tracks[9].id]), active: true, locale: "pt_BR")
precondition(original.indices.filter { group[$0] != selectedB[$0] } == [5, 9],
             "all selected channels refresh their current group action targets")
precondition(versions.masterVersion == master, "track selection cannot replace the Master root")
private var routed = state([tracks[5].id, tracks[9].id]); routed.masterOutputs = [.init(firstChannel: 3, channelCount: 2)]
let routeChanged = versions.update(routed, active: true, locale: "pt_BR")
precondition(routeChanged == group && versions.masterVersion != master, "Master output changes must refresh its routing slots without replacing track controls")
let translated = versions.update(state([tracks[5].id, tracks[9].id]), active: true, locale: "en")
precondition(original.indices.allSatisfy { translated[$0] != group[$0] }, "locale changes still update every channel")
print("FOOTER_SELECTION_UPDATES_ONLY_AFFECTED_CHANNELS_AND_PRESERVES_CURRENT_GROUP_TARGETS_OK")
private let insertedTrack = Track()
private let inserted = Array(tracks.prefix(3)) + [insertedTrack] + Array(tracks.dropFirst(3))
let afterInsertion = versions.update(state([tracks[5].id, tracks[9].id], items: inserted), active: true, locale: "en")
for (index, track) in tracks.enumerated() {
    precondition(afterInsertion[inserted.firstIndex { $0.id == track.id }!] == translated[index],
                 "Inserting a track cannot invalidate every later channel")
}
let reordered = versions.update(state([tracks[5].id, tracks[9].id], items: Array(inserted.reversed())), active: true, locale: "en")
precondition(reordered == afterInsertion.reversed(), "Reordering preserves versions by track identity")
print("FOOTER_INSERTION_AND_REORDER_RETAIN_UNCHANGED_TRACK_VERSIONS_OK")
private let numberedVersions = FooterMixerStripVersions()
private var numbered = state([])
numbered.trackNumbers = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset + 1) })
let initialNumbers = numberedVersions.update(numbered, active: true, locale: "pt_BR")
// Hiding a channel preserves project numbering. Inserting/reordering tracks
// must refresh just the numbers that changed, even when metadata is identical.
let projectNumbers = numbered.trackNumbers
numbered = state([], items: Array(tracks.dropFirst()))
numbered.trackNumbers = projectNumbers
let hiddenFirst = numberedVersions.update(numbered, active: true, locale: "pt_BR")
precondition(hiddenFirst == Array(initialNumbers.dropFirst()))
numbered.trackNumbers[tracks[2].id] = 4
let renumbered = numberedVersions.update(numbered, active: true, locale: "pt_BR")
precondition(hiddenFirst.indices.filter { hiddenFirst[$0] != renumbered[$0] } == [1])
print("FOOTER_NUMBERING_PRESERVES_HIDDEN_TRACK_POSITIONS_AND_REFRESHES_CHANGED_NUMBERS_OK")
