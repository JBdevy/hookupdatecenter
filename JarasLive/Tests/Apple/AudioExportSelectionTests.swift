import Foundation
import Combine

@main
struct AudioExportSelectionTests {
    @MainActor static func main() {
        let selection = AudioExportSelection.shared
        selection.clear()
        let song = UUID(), otherSong = UUID(), first = UUID(), second = UUID()
        var updates = 0
        let subscription = selection.objectWillChange.sink { updates += 1 }

        selection.setTracks([first, second], song: song)
        precondition(selection.tracks(song) == [first, second], "Opening export must retain the whole mixer selection")
        precondition(updates == 1, "Open export views must observe mixer changes")
        selection.setTracks([first, second], song: song)
        precondition(updates == 1, "Unchanged mixer refresh must not reset manual export choices")
        selection.setTracks([second], song: song)
        precondition(selection.tracks(song) == [second] && updates == 2, "Deselecting a track must publish immediately")
        selection.setTracks([], song: song)
        precondition(selection.tracks(song).isEmpty && updates == 3, "Deselecting all must clear export, not select everything")

        selection.setTracks([first], song: song)
        selection.setTracks([second], song: otherSong)
        precondition(selection.tracks(song) == [first] && selection.tracks(otherSong) == [second], "Project tabs must not share track selections")
        let before = updates
        selection.setTracks([first], song: nil)
        precondition(updates == before, "A missing song must not mutate another project's selection")
        selection.clear()
        precondition(selection.tracks(song).isEmpty && selection.tracks(otherSong).isEmpty, "Closing a project must discard stale selection")
        withExtendedLifetime(subscription) {}
        print("PASS: export observes full mixer selections, deselection, unchanged refresh and project isolation")
    }
}
