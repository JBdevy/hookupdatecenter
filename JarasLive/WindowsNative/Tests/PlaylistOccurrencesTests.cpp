#include "ProjectCodec.h"
#include "../../Windows/Source/PlaylistOccurrences.h"
#include "../../Core/Transport/Engine.hpp"
#include <iostream>
#include <stdexcept>
using namespace jaras;
namespace {
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
template<class F> void rejects(F work, const char *message) {
    bool failed=false;try {work();}catch(const std::exception &){failed=true;}expect(failed,message);
}
Project fixture() {
    Project project;project.id="project";project.name="Occurrences";
    Song song;song.id="song";song.name="Grid";song.duration=90;song.bpm=120;
    song.parts={{"first","First",0,30},{"second","Second",30,60},{"third","Third",60,90}};
    Track track;track.id="track";track.name="Audio";track.role.id="other";
    AudioClip clip;clip.id="clip";clip.name="Audio";clip.duration=90;track.clips.push_back(clip);song.tracks.push_back(track);
    project.songs.push_back(song);project.setlists.push_back({"setlist","Show",{song.id}});
    RegionSetlist state;state.playlists={{"playlist","Songs",song.id,{"first","second","third"}}};
    state.selectedId="playlist";project.regionSetlist=state;return project;
}
}
int main() {
    try {
        auto project=fixture();auto &playlist=project.regionSetlist->playlists[0];
        expect(catlive::playlistOccurrences::duplicate(playlist,"first","first-copy"),"Duplicate failed");
        expect(catlive::playlistOccurrences::duplicate(playlist,"first-copy","second-copy"),"Duplicate of duplicate failed");
        expect(playlist.regionIds==std::vector<ID>{"first","first-copy","second-copy","second","third"},"Duplicate was not adjacent");
        expect(playlist.resolvedRegionId("second-copy")=="first","Nested alias was not flattened");
        expect(project.songs[0].parts.size()==3 && project.songs[0].tracks[0].clips.size()==1,"Duplicate changed grid");
        validate(project);
        project.regionSetlist->blocks=std::vector<SetlistBlock>{{"block","song","playlist","Act",0,"first-copy"}};
        const auto json=catlive::native::ProjectCodec::encode(project);
        auto restored=catlive::native::ProjectCodec::decode(json);validate(restored);
        expect(restored.regionSetlist->playlists[0].duplicates==playlist.duplicates,"Saved aliases lost");
        expect(restored.regionSetlist->playlists[0].regionIds==playlist.regionIds,"Saved occurrence order lost");
        expect(restored.regionSetlist->blocks->front().beforeRegionId=="first-copy","Block anchor lost");
        auto clone=playlist;int identity=0;
        const auto remapped=catlive::playlistOccurrences::reidentifyCopies(clone,[&]{return "clone-"+std::to_string(++identity);});
        expect(clone.regionIds[1]==remapped.at("first-copy") && clone.resolvedRegionId(clone.regionIds[2])=="first","Cloned occurrence IDs not independent");
        catlive::playlistOccurrences::remove(*restored.regionSetlist,"playlist",{"first-copy"});
        expect(restored.regionSetlist->playlists[0].containsEntry("first") && restored.regionSetlist->playlists[0].containsEntry("second-copy"),"Removing one copy removed other entries");
        expect(restored.regionSetlist->blocks->front().beforeRegionId=="second-copy","Removed copy block anchor not advanced");
        validate(restored);
        Engine engine;engine.loadProject(restored);
        rejects([&]{engine.execute({CommandKind::queueRegion,"second-copy"});},"Stopped transport accepted copied queue");
        engine.execute({CommandKind::selectRegion,"first"});engine.execute({CommandKind::play});
        rejects([&]{engine.execute({CommandKind::queueRegion,"second-copy"});},"Currently playing source accepted copied queue");
        engine.execute({CommandKind::stop});engine.execute({CommandKind::selectRegion,"second"});engine.execute({CommandKind::play});
        engine.execute({CommandKind::queueRegion,"second-copy"});
        expect(engine.transport().queuedRegionId=="first" && engine.transport().queuedPlaylistEntryId=="second-copy","Copy queue did not preserve source and occurrence");
        engine.advance(30.25);
        expect(engine.transport().regionId=="first" && engine.transport().playlistEntryId=="second-copy" && engine.transport().position<1,"Copy did not jump to existing original audio");
        std::cout<<"PLAYLIST_OCCURRENCES_TESTS_PASSED\n";return 0;
    }catch(const std::exception &error){std::cerr<<error.what()<<'\n';return 1;}
}
