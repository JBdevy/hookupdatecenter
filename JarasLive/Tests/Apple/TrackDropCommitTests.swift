// Exercise the production drop handler without relying on asynchronous
// NSItemProvider String loading. The internal session supplies the identity.
private struct DropInfo {
    var location: CGPoint
    var containsTrack = true
    func hasItemsConforming(to types: [UTType]) -> Bool { containsTrack }
}
private final class DropCommitShow {
    var allowed = true
    var moves: [(UUID, UUID, UUID?, Bool)] = []
    func canDropTrack(_ id: UUID, on target: UUID, after: Bool) -> Bool { allowed && id != target }
    func dropTrack(_ id: UUID, on target: UUID, before: UUID?, outsideGroup: Bool) {
        moves.append((id, target, before, outsideGroup))
    }
}
private struct DropCommitFixture {
    let show: DropCommitShow
    let track: UUID
    let nextTrack: UUID?
    let height: CGFloat
    let state: TrackReorderState
    var horizontal = false
    // PRODUCTION_DROP_METHODS
}
private func verifyInternalDropCommit() {
    let state = TrackReorderState(), show = DropCommitShow()
    let source = UUID(), target = UUID(), next = UUID()
    let drop = DropCommitFixture(show: show, track: target, nextTrack: next, height: 80, state: state)
    state.begin(track: source)
    precondition(drop.performDrop(info: DropInfo(location: CGPoint(x: 60, y: 60))))
    precondition(show.moves.count == 1 && show.moves[0].0 == source && show.moves[0].1 == target && show.moves[0].2 == next && !show.moves[0].3,
                 "Drop must apply immediately, with no pasteboard callback/run-loop dependency")
    precondition(!state.active && state.draggedTrack == nil)
    precondition(!drop.performDrop(info: DropInfo(location: .zero)) && show.moves.count == 1,
                 "A finished session cannot apply the same move twice")
    state.begin(track: source)
    precondition(drop.performDrop(info: DropInfo(location: CGPoint(x: 5, y: 10))))
    precondition(show.moves.last!.2 == target && show.moves.last!.3, "Upper gutter drop preserves detach intent")
    state.begin(track: source); show.allowed = false
    precondition(!drop.performDrop(info: DropInfo(location: .zero)) && show.moves.count == 2 && !state.active)
    state.begin(track: source); show.allowed = true
    precondition(!drop.performDrop(info: DropInfo(location: .zero, containsTrack: false)) && show.moves.count == 2,
                 "Unrelated external content must never use an internal track session")
    state.begin(track: source); state.finish() // closing/switching the project cancels the session
    precondition(!drop.performDrop(info: DropInfo(location: .zero)) && show.moves.count == 2)
    print("TRACK_DROP_SYNCHRONOUS_COMMIT_ORDER_GROUP_GUTTER_REJECTION_AND_CANCEL_OK")
}
verifyInternalDropCommit()
