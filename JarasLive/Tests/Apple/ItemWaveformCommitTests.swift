import Foundation
import SwiftUI

@main struct PreviewCommitTests {
    @MainActor static func main() async {
        let preview=ItemWaveformPreview()
        var clip=AudioClip(id:UUID(),name:"Tone",startTime:0,duration:1); clip.gain=1
        var track=Track(id:UUID(),name:"Audio",role:.other); track.clips=[clip]
        var song=Project.empty(name:"Preview").songs[0]; song.tracks=[track]
        preview.update(id:clip.id,gain:2)
        clip.gain=2; preview.finish(committed:clip)
        preview.didPresent(song)
        await Task.yield()
        precondition(preview.state != nil, "an old base frame must not retire the final drag")
        song.tracks[0].clips[0]=clip
        preview.didPresent(song)
        try? await Task.sleep(nanoseconds:10_000_000)
        precondition(preview.state == nil, "the committed frame releases the preview")
        preview.update(id:clip.id,gain:2); preview.finish(committed:clip); preview.didPresent(song)
        preview.update(id:clip.id,gain:3)
        try? await Task.sleep(nanoseconds:10_000_000)
        precondition(preview.state?.applying(to:clip).gain == 3, "a pending acknowledgment cannot erase a newer gesture")
        preview.finish(committed:nil)
        precondition(preview.state == nil, "rejected or deleted edits release the preview")
        print("ITEM_GAIN_PREVIEW_COMMIT_HANDOFF_OK")
    }
}
