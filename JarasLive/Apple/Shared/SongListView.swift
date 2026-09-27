import SwiftUI
struct SongListView: View {
    @ObservedObject var show: ShowController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("REPERTÓRIO").font(.system(size: 10, weight: .bold, design: .monospaced)); Spacer(); Text("\(show.snapshot.project.songs.count)").foregroundStyle(JarasTheme.secondary) }.padding(12)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(Array(show.snapshot.project.songs.enumerated()), id: \.element.id) { index, song in
                        let selected = show.snapshot.transport.songId == song.id
                        let queued = show.snapshot.transport.queue.songId == song.id
                        Button { show.choose(song) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Text(String(format: "%02d", index + 1)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(selected ? JarasTheme.green : JarasTheme.secondary)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(song.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    HStack { Text(clockText(song.duration)); Spacer(); Text("\(Int(song.bpm)) BPM") }.font(.system(size: 9, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                                    if queued { Text("NA FILA").font(.system(size: 8, weight: .bold)).foregroundStyle(JarasTheme.yellow) }
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(selected ? JarasTheme.green.opacity(0.10) : queued ? JarasTheme.yellow.opacity(0.10) : JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? JarasTheme.green.opacity(0.6) : queued ? JarasTheme.yellow.opacity(0.6) : .clear))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Text("Ao tocar durante o play, a música entra na fila.").font(.system(size: 10)).foregroundStyle(JarasTheme.secondary).padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0x151b22))
    }
}
struct SongListPreview: PreviewProvider { static var previews: some View { SongListView(show: try! AppContainer(preview: true).show).frame(height: 560).preferredColorScheme(.dark) } }
