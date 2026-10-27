#ifdef NDEBUG
#undef NDEBUG // Keep protocol and failover checks active in release CI builds.
#endif
#include "../../Core/Transport/Engine.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
using namespace jaras;
static Project fixture() {
    Project p;p.id="local-project";p.name="Sync";p.projectSyncID="12345678-1234-1234-1234-123456789ABC";
    p.songs={{"song","Song",120,120,{{"track","Track",{"other"}}},{{"one","One",0,60},{"two","Two",60,120}}}};
    p.songs[0].markers=std::vector<TimelineMarker>{{"verse","Verse",10,0},{"chorus","Chorus",30,0}};
    for(auto &m:*p.songs[0].markers)m.section=true;
    p.regionSetlist=RegionSetlist{};return p;
}
template<class F> static void rejects(F f) {bool rejected=false;try{f();}catch(const std::exception&){rejected=true;}assert(rejected);}
static projectSync::Frame wire(const Engine &a) {auto bytes=projectSync::encode(a.projectSyncFrame());return projectSync::decode(bytes.data(),bytes.size());}
int main() {
    Engine a,b;a.loadProject(fixture());b.loadProject(fixture());
    a.setProjectSyncID("must-not-replace");assert(a.project().projectSyncID==fixture().projectSyncID);
    auto edited=a.project();edited.projectSyncID="wrong";a.applyProjectEdit(edited);assert(a.project().projectSyncID==fixture().projectSyncID);
    a.execute({CommandKind::selectRegion,"one"});a.execute({CommandKind::play});a.advance(4);
    auto frame=wire(a);assert(b.applyProjectSync(frame,.01,true));
    {
        auto isolated=frame;isolated.transport.exclusivePlaybackRegionId="two";
        isolated.transport.subExclusivePlaybackRegionId="one";
        isolated.setlist->subplayExclusiveTrackIDs=std::vector<ID>{"track"};
        const auto data=projectSync::encode(isolated);const auto restored=projectSync::decode(data.data(),data.size());
        assert(restored.transport.exclusivePlaybackRegionId=="two" && restored.transport.subExclusivePlaybackRegionId=="one");
        assert(restored.setlist->subplayExclusiveTrackIDs==std::vector<ID>{"track"});
    }
    assert(b.transport().playing && std::abs(b.transport().position-4.01)<1e-6);
    assert(b.project().regionSetlist->playlists.empty());
    // Mixer changes are absolute, idempotent and do not reposition a rolling transport.
    a.advance(.01); a.execute({CommandKind::volume,"",.7}); a.execute({CommandKind::pan,"",-.2});
    a.execute({CommandKind::volume,"track",.3}); a.execute({CommandKind::pan,"track",.65});
    a.execute({CommandKind::mute,"track"}); a.execute({CommandKind::solo,"track"});
    a.execute({CommandKind::mute}); a.execute({CommandKind::solo});
    bool mixerChanged=false; const auto rolling=b.transport().position;
    assert(!b.applyProjectSync(wire(a),0,false,&mixerChanged)); assert(mixerChanged);
    assert(b.transport().position==rolling && b.transport().playing);
    assert(b.project().masterVolume==.7 && b.project().masterPan==-.2 && b.project().masterMute && b.project().masterSolo);
    const auto &track=b.project().songs[0].tracks[0];
    assert(track.volume==.3 && track.pan==.65 && track.mute && track.solo);
    b.applyProjectSync(wire(a),0,false,&mixerChanged);assert(!mixerChanged && track.mute && track.solo);
    auto badMixer=wire(a);badMixer.mixer.masterVolume=.1;badMixer.mixer.tracks[0].pan=2;
    rejects([&]{b.applyProjectSync(badMixer,0,false);});assert(b.project().masterVolume==.7);
    badMixer=wire(a);badMixer.mixer.tracks.push_back(badMixer.mixer.tracks[0]);
    rejects([&]{b.applyProjectSync(badMixer,0,false);});
    badMixer=wire(a);badMixer.mixer.tracks[0].id="missing";
    rejects([&]{b.applyProjectSync(badMixer,0,false);});
    // Loading the same project with a different row order still matches each mixer by ID.
    auto reordered=fixture();auto secondTrack=reordered.songs[0].tracks[0];secondTrack.id="second";
    reordered.songs[0].tracks.insert(reordered.songs[0].tracks.begin(),secondTrack);
    Engine reorderedB;reorderedB.loadProject(reordered);reorderedB.applyProjectSync(wire(a),0,true);
    assert(reorderedB.project().songs[0].tracks[0].volume==1);
    assert(reorderedB.project().songs[0].tracks[1].volume==.3);
    auto mismatch=frame;mismatch.project="other-project";rejects([&]{b.applyProjectSync(mismatch,0,true);});
    assert(b.transport().playing && std::abs(b.transport().position-4.01)<1e-6);
    auto invalid=frame;invalid.transport.position=std::numeric_limits<double>::quiet_NaN();rejects([&]{b.applyProjectSync(invalid,0,true);});
    invalid=frame;invalid.transport.queue.songId="absent";rejects([&]{b.applyProjectSync(invalid,0,true);});
    auto bytes=projectSync::encode(frame);
    for(size_t size=0;size<bytes.size();++size)rejects([&]{projectSync::decode(bytes.data(),size);});
    bytes.push_back(0);rejects([&]{projectSync::decode(bytes.data(),bytes.size());});
    a.execute({CommandKind::subSeek,"",75});a.execute({CommandKind::subPlay});
    b.applyProjectSync(wire(a),0,true);assert(b.transport().subPlay.playing && b.transport().subPlay.position==75);
    a.execute({CommandKind::subStop});a.execute({CommandKind::queueSection,"chorus"});
    b.applyProjectSync(wire(a),0,true);assert(b.transport().queuedSectionMarkerId==a.transport().queuedSectionMarkerId);
    projectSync::following=true;
    rejects([&]{b.execute({CommandKind::stop});});
    rejects([&]{b.execute({CommandKind::volume,"track",.2});});
    rejects([&]{b.addTrack("new","New",{"other"});});
    const auto before=b.transport().position;b.advance(.5);assert(b.transport().position>before);
    // A disappearing releases only the control gate; playback and its queue survive.
    projectSync::following=false;const auto at=b.transport().position;b.advance(.5);assert(b.transport().playing && b.transport().position>at);
    b.execute({CommandKind::stop});assert(!b.transport().playing);
    a.execute({CommandKind::cancelSection});a.execute({CommandKind::seek,"",10});
    a.execute({CommandKind::loopStart,"",10});a.execute({CommandKind::loopEnd,"",12});a.execute({CommandKind::toggleLoop});
    b.applyProjectSync(wire(a),0,true);a.advance(2.5);b.advance(2.5);
    assert(std::abs(a.transport().position-b.transport().position)<1e-6);
    assert(a.transport().loop.enabled==b.transport().loop.enabled);
    // Every background project gets an independent engine clock and project identity.
    Engine other;auto p=fixture();p.projectSyncID="second-project";other.loadProject(p);
    rejects([&]{other.applyProjectSync(wire(a),0,true);});
    std::cout<<"Project Sync: identity, wire bounds, mixer, transport continuity, loops, queue, follower lock and uninterrupted failover passed\n";
}
