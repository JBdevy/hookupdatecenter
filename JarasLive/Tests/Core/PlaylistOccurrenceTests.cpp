#include "../../Core/Transport/Engine.hpp"
#include "../../Windows/Source/PlaylistOccurrences.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <type_traits>
using namespace jaras;
static_assert(std::is_nothrow_move_constructible_v<Engine> && std::is_nothrow_move_assignable_v<Engine>,
              "Engine must be nothrow movable for asynchronous project publication");
static void expect(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
template<class F> static void rejects(F action, const char* why) {
    try { action(); } catch (const std::invalid_argument&) { return; }
    throw std::runtime_error(why);
}
static Project fixture(bool automatic = false, bool live = false) {
    Project p; p.id="project"; p.name="Occurrences"; p.projectSyncID="sync";
    p.songs={{"song","Grid",100,120,{},{{"a","A",0,20},{"b","B",30,50},{"c","C",60,80}}}};
    RegionSetlist s; s.selectedId="playlist"; s.autoAdvance=automatic; s.liveEnabled=live;
    RegionPlaylist list{"playlist","Show","song",{"a","b","a-copy","c"}};
    list.duplicates=std::vector<RegionPlaylistDuplicate>{{"a-copy","a"}};
    s.playlists={list}; p.regionSetlist=s; return p;
}
static void start(Engine& e, const ID& id) { e.execute({CommandKind::selectRegion,id}); e.execute({CommandKind::play}); }
static bool marked(const Engine& e,const ID& id) {
    const auto& ids=e.project().regionSetlist->playedLiveRegionIDs;
    return ids && std::find(ids->begin(),ids->end(),id)!=ids->end();
}
static void validation() {
    auto p=fixture(); validate(p);
    expect(p.songs[0].parts.size()==3 && p.songs[0].tracks.empty(),"occurrence must not add grid regions or tracks");
    expect(p.regionSetlist->playlists[0].resolvedRegionId("a-copy")=="a","alias resolves physical source");
    auto bad=p; bad.regionSetlist->playlists[0].duplicates->front().regionId="missing";
    rejects([&]{validate(bad);},"missing physical source must fail");
    bad=p; bad.regionSetlist->playlists[0].duplicates->front().regionId="a-copy";
    rejects([&]{validate(bad);},"alias cannot refer to itself");
    bad=p; bad.regionSetlist->playlists[0].regionIds.push_back("a");
    rejects([&]{validate(bad);},"row IDs remain unique");
    bad=p; bad.regionSetlist->playlists[0].regionIds.erase(bad.regionSetlist->playlists[0].regionIds.begin()+2);
    rejects([&]{validate(bad);},"orphan duplicate mapping must fail");
    bad=p; bad.regionSetlist->playlists[0].duplicates->front().id="b";
    rejects([&]{validate(bad);},"alias cannot collide with physical IDs");
    auto legacy=p; legacy.regionSetlist->playlists[0].regionIds={"a","b","c"}; legacy.regionSetlist->playlists[0].duplicates.reset(); validate(legacy);
}
static void manual() {
    Engine e; e.loadProject(fixture());
    e.execute({CommandKind::selectRegion,"a-copy"});
    expect(!e.transport().playing && e.transport().regionId=="a" && e.transport().playlistEntryId=="a-copy", "stopped copy selects its source without warning");
    e.execute({CommandKind::queueRegion,"a-copy"});
    expect(!e.transport().playing && e.transport().playlistEntryId=="a-copy", "stopped copy can prepare playback");
    e.execute({CommandKind::editSeek,{},25}); e.execute({CommandKind::play});
    e.execute({CommandKind::queueRegion,"a-copy"});
    expect(e.transport().queuedRegionId=="a", "playing outside a region must allow the copy");
    e.execute({CommandKind::stop}); start(e,"a");
    rejects([&]{e.execute({CommandKind::queueRegion,"a-copy"});},"alias of playing physical song must fail");
    e.execute({CommandKind::queueRegion,"a"}); expect(!e.transport().queuedRegionId,"playing original cannot queue itself");
    e.execute({CommandKind::stop}); start(e,"b");
    e.execute({CommandKind::selectRegion,"a-copy"});
    expect(e.transport().regionId=="b" && e.transport().queuedRegionId=="a" && e.transport().queuedPlaylistEntryId=="a-copy", "alias click must queue without seeking");
    e.execute({CommandKind::queueRegion,"a"});
    expect(e.transport().queuedRegionId=="a" && e.transport().queuedPlaylistEntryId=="a","another occurrence of queued physical song replaces queue");
    e.execute({CommandKind::queueRegion,"a-copy"}); e.advance(20);
    expect(e.transport().regionId=="a" && e.transport().playlistEntryId=="a-copy" && e.transport().position==0,"promote physical source and duplicate identity together");
    auto edit=e.project(); edit.name="Renamed"; e.applyProjectEdit(edit);
    expect(e.transport().playlistEntryId=="a-copy" && e.transport().playing,"project edit preserves active occurrence");
    e.execute({CommandKind::stop}); start(e,"b"); e.execute({CommandKind::queueRegion,"a-copy"}); e.execute({CommandKind::stop});
    expect(!e.transport().playing && e.transport().regionId=="a" && e.transport().playlistEntryId=="a-copy","Stop prepares queued duplicate");
    e.execute({CommandKind::play}); expect(e.transport().playing && e.transport().playlistEntryId=="a-copy","general Play remains usable for prepared duplicate");
}
static void automatic() {
    Engine e; e.loadProject(fixture(true)); start(e,"a");
    expect(e.transport().queuedPlaylistEntryId=="b","first occurrence queues following row");
    e.advance(20); expect(e.transport().regionId=="b" && e.transport().queuedPlaylistEntryId=="a-copy","B queues repeated A occurrence");
    e.advance(20); expect(e.transport().playlistEntryId=="a-copy" && e.transport().queuedPlaylistEntryId=="c","duplicate auto advances after its own row");
    e.advance(20); expect(e.transport().regionId=="c" && !e.transport().queuedRegionId,"final occurrence has no wraparound queue");
    auto p=fixture(true); p.regionSetlist->playlists[0].regionIds={"a","a-copy","b","c"};
    Engine skip; skip.loadProject(p); start(skip,"a"); expect(skip.transport().queuedPlaylistEntryId=="b","auto skips repeated current physical song");
    p.regionSetlist->autoUntilBlockEnd=true;
    p.regionSetlist->blocks=std::vector<SetlistBlock>{{"block","song","playlist","Boundary",0,"a-copy"}};
    Engine blocked; blocked.loadProject(p); start(blocked,"a"); expect(!blocked.transport().queuedRegionId,"block before skipped copy remains boundary");
    auto prepared=fixture(true); prepared.regionSetlist->prepareWithoutPlayback=true;
    Engine prepare; prepare.loadProject(prepared); start(prepare,"b"); prepare.advance(20);
    expect(!prepare.transport().playing && prepare.transport().playlistEntryId=="a-copy","prepare without playback keeps duplicate row identity");
    auto sub=fixture(true); sub.regionSetlist->automaticSubplay=true; sub.regionSetlist->automaticSubplaySeconds=2;
    Engine overlap; overlap.loadProject(sub); start(overlap,"b"); overlap.advance(19); overlap.advance(1);
    expect(overlap.transport().playing && overlap.transport().playlistEntryId=="a-copy" && overlap.transport().position==2,"Subplay promotion preserves duplicate identity and consumed lead");
}
static void removal() {
    Engine e; e.loadProject(fixture()); start(e,"b"); e.execute({CommandKind::queueRegion,"a-copy"});
    auto state=*e.project().regionSetlist; state.playlists[0].regionIds={"a","b","c"}; state.playlists[0].duplicates.reset(); e.configureRegionSetlist(state);
    expect(!e.transport().queuedRegionId && e.transport().regionId=="b" && e.transport().playing,"removing queued row cancels only its queue");
    expect(e.project().songs[0].parts.size()==3,"remove duplicate leaves physical grid intact");
    state=*fixture().regionSetlist; e.configureRegionSetlist(state); e.execute({CommandKind::queueRegion,"a-copy"}); e.advance(20);
    state.playlists[0].regionIds={"a","b","c"}; state.playlists[0].duplicates.reset(); e.configureRegionSetlist(state);
    expect(e.transport().regionId=="a" && e.transport().playlistEntryId=="a" && e.transport().playing,"removing playing occurrence keeps source running");
    e.execute({CommandKind::stop}); e.configureRegionSetlist(*fixture().regionSetlist); start(e,"b"); e.execute({CommandKind::queueRegion,"a-copy"});
    state=*e.project().regionSetlist; state.selectedId.reset(); e.configureRegionSetlist(state);
    expect(!e.transport().queuedRegionId && !e.transport().playlistEntryId,"changing to All regions clears occurrence-specific queue");
    auto pre=fixture(true); pre.regionSetlist->automaticSubplay=true;
    Engine scheduled; scheduled.loadProject(pre); start(scheduled,"b"); scheduled.advance(19);
    expect(scheduled.transport().subPlay.playing,"fixture starts automatic duplicate pre-roll");
    state=*scheduled.project().regionSetlist; state.playlists[0].regionIds={"a","b","c"}; state.playlists[0].duplicates.reset();
    scheduled.configureRegionSetlist(state);
    expect(scheduled.transport().playing && scheduled.transport().regionId=="b" && !scheduled.transport().subPlay.playing &&
        scheduled.transport().queuedRegionId=="c","removing duplicate retracts its automatic pre-roll and resolves next row");
}
static void sync() {
    Engine a,b; a.loadProject(fixture()); b.loadProject(fixture()); start(a,"b"); a.execute({CommandKind::queueRegion,"a-copy"});
    auto bytes=projectSync::encode(a.projectSyncFrame()); auto frame=projectSync::decode(bytes.data(),bytes.size());
    expect(frame.transport.playlistEntryId=="b" && frame.transport.queuedPlaylistEntryId=="a-copy","ProjectSync wire carries both occurrences");
    b.applyProjectSync(frame,0,true);
    expect(b.transport().queuedPlaylistEntryId=="a-copy","ProjectSync follower retains queue occurrence");
    auto bad=frame; bad.transport.queuedPlaylistEntryId="c";
    rejects([&]{b.applyProjectSync(bad,0,true);},"ProjectSync must reject occurrence/source mismatch");
    projectSync::Writer legacy; std::uint64_t version=2; legacy(version); projectSync::archive(legacy,frame,2);
    auto decoded=projectSync::decode(legacy.bytes.data(),legacy.bytes.size());
    expect(!decoded.transport.playlistEntryId && !decoded.transport.queuedPlaylistEntryId && decoded.transport.queuedRegionId=="a","old sync frame decodes physical transport");
}
static void blockRemoval() {
    auto project = fixture();
    auto &state = *project.regionSetlist;
    state.playlists.push_back({"other", "Other show", "song", {"a", "b"}});
    state.blocks = std::vector<SetlistBlock>{
        {"first", "song", "playlist", "Opening", 0, "a"},
        {"second", "song", "playlist", "Final", 0, "c"},
        {"other-block", "song", "other", "Other", 0, "b"},
        {"global", "song", std::nullopt, "All regions", 0, "b"}};
    validate(project);
    Engine engine; engine.loadProject(project); start(engine, "b");
    engine.execute({CommandKind::queueRegion, "a-copy"});
    const auto entries = state.playlists[0].regionIds;
    catlive::playlistOccurrences::removeBlocks(state, "song", "playlist", {"first", "second", "other-block", "global", "a"});
    expect(state.blocks->size() == 2 && state.blocks->front().id == "other-block" && state.blocks->back().id == "global",
           "block removal must stay within the selected song and playlist");
    expect(state.playlists[0].regionIds == entries && state.playlists[0].duplicates->front().id == "a-copy",
           "block removal must preserve songs and duplicate occurrences");
    engine.configureRegionSetlist(state);
    expect(engine.project().songs[0].parts.size() == 3 && engine.transport().playing &&
           engine.transport().regionId == "b" && engine.transport().queuedPlaylistEntryId == "a-copy",
           "deleting headers must preserve the physical timeline and playing/queued songs");
    catlive::playlistOccurrences::removeBlocks(state, "foreign-song", std::nullopt, {"global"});
    expect(state.blocks->size() == 2, "block deletion must reject a different song");
    catlive::playlistOccurrences::removeBlocks(state, "song", std::nullopt, {"global"});
    expect(state.blocks->size() == 1 && state.blocks->front().id == "other-block", "legacy All Regions header can be deleted alone");
}
static void blockReordering() {
    auto project = fixture();
    auto &state = *project.regionSetlist;
    state.playlists.push_back({"other", "Other show", "song", {"a", "b"}});
    state.blocks = std::vector<SetlistBlock>{{"first", "song", "playlist", "Opening", 0, "a"},
        {"second", "song", "playlist", "Second", 0, "b"},
        {"foreign", "song", "other", "Other", 0, "b"}};
    const auto originalSongs = state.playlists[0].regionIds;
    auto block = [&](const ID &id) -> const SetlistBlock & {
        return *std::find_if(state.blocks->begin(), state.blocks->end(), [&](const auto &item) { return item.id == id; });
    };
    using catlive::playlistOccurrences::moveEntries;
    expect(moveEntries(state, "song", "playlist", {"first"}, "b"), "a block must move between songs");
    expect(block("first").beforeRegionId == "b" && state.blocks->front().id == "second" &&
           state.playlists[0].regionIds == originalSongs, "moving a block alone must not carry its songs");
    expect(moveEntries(state, "song", "playlist", {"first"}, "second"), "a block must move before another block");
    expect(state.blocks->front().id == "first" && block("first").beforeRegionId == "b" && block("second").beforeRegionId == "b",
           "blocks sharing a song anchor must keep their explicit row order");
    expect(moveEntries(state, "song", "playlist", {"second"}, std::nullopt), "a block must move to the playlist end");
    expect(!block("second").beforeRegionId && state.playlists[0].regionIds == originalSongs, "tail block must follow the final song");
    expect(moveEntries(state, "song", "playlist", {"first", "b"}, "a"), "mixed block/song drag must move both selected rows");
    expect(state.playlists[0].regionIds == std::vector<ID>({"b", "a", "a-copy", "c"}) && block("first").beforeRegionId == "b",
           "mixed drag must preserve relative row order and duplicate identities");
    expect(block("foreign").beforeRegionId == "b" && state.playlists[1].regionIds == std::vector<ID>({"a", "b"}),
           "moving rows must not alter another playlist");
    expect(!moveEntries(state, "song", "playlist", {"first"}, "b"), "dropping a block in its current slot must be a no-op");
    expect(!moveEntries(state, "different-song", "playlist", {"first"}, "c"), "drag cannot cross songs");
    expect(!moveEntries(state, "song", "playlist", {"first"}, "foreign"), "drag cannot target a foreign playlist block");
    validate(project);
}
static void live() {
    Engine e; e.loadProject(fixture(false,true)); start(e,"a"); e.advance(4); e.execute({CommandKind::pause}); e.advance(30);
    expect(!marked(e,"a"),"paused time is not Live played time");
    e.execute({CommandKind::play}); e.advance(3); e.execute({CommandKind::stop}); e.advance(30); start(e,"a"); e.advance(2.9);
    expect(!marked(e,"a"),"Live accumulates below threshold across stop without premature mark"); e.advance(.1);
    expect(marked(e,"a") && !marked(e,"a-copy"),"ten real seconds marks only physical region, aliases project that state");
    e.execute({CommandKind::stop}); start(e,"b"); e.execute({CommandKind::seek,{},48}); e.advance(1);
    expect(!marked(e,"b"),"seek distance must not count toward Live");
    auto disabled=*e.project().regionSetlist; disabled.liveEnabled=false; e.configureRegionSetlist(disabled); expect(marked(e,"a"),"disabling collection preserves supplied portable history");
    disabled.playedLiveRegionIDs=std::vector<ID>{}; e.configureRegionSetlist(disabled); expect(!marked(e,"a"),"UI toggle explicitly clears Live history");
    disabled.liveEnabled=true; e.configureRegionSetlist(disabled); e.execute({CommandKind::stop}); start(e,"b"); e.advance(9);
    expect(!marked(e,"b"),"disabling Live also clears partial counters"); e.advance(1); expect(marked(e,"b"),"Live enabled again records playback");
    Engine two; two.loadProject(fixture(false,true)); start(two,"a"); two.execute({CommandKind::subSeek,{},0}); two.execute({CommandKind::subPlay}); two.advance(6);
    expect(!marked(two,"a"),"two simultaneous heads cannot double count the same physical region"); two.advance(4); expect(marked(two,"a"),"two heads still reach threshold after ten real seconds");
    auto p=fixture(false,true); p.songs[0].parts[0].endTime=30;
    Part child1{"a-child1","One",0,15}; child1.parentRegionID="a";
    Part child2{"a-child2","Two",15,30}; child2.parentRegionID="a";
    p.songs[0].parts.push_back(child1); p.songs[0].parts.push_back(child2);
    Engine group; group.loadProject(p); start(group,"a"); group.advance(10);
    expect(marked(group,"a-child1") && !marked(group,"a"),"unified wrapper waits for all children"); group.advance(5); group.advance(10);
    expect(marked(group,"a-child2") && marked(group,"a"),"all played children mark physical unified wrapper");
    auto saved=group.project(); group.execute({CommandKind::stopAll}); group.loadProject(saved);
    expect(marked(group,"a"),"saved Live physical marks survive reopening");
    Engine fresh; fresh.loadProject(fixture(false,true)); start(fresh,"a"); fresh.advance(7); fresh.execute({CommandKind::stop}); fresh.loadProject(fixture(false,true)); start(fresh,"a"); fresh.advance(4);
    expect(!marked(fresh,"a"),"load resets runtime partial counters");
}
int main() { try { validation(); manual(); automatic(); removal(); sync(); blockRemoval(); blockReordering(); live(); std::cout<<"CATLIVE_PLAYLIST_OCCURRENCES_OK\n"; } catch (const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; } }
