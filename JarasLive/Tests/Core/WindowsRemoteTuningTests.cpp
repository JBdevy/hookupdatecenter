#include "RemotePitchForTest.h"
#include <cassert>
#include <iostream>
#include <map>
#include <variant>
using jaras::ID;
namespace regionPitch = catlive::regionPitch;
using String = std::string;
using State = std::map<std::string,std::variant<std::string,int>>;
inline ID wireID(const ID &id) { return id; }
template<class Value> void put(State &state,const char *key,Value value) { state[key]=value; }
struct Command { ID target; double value=0; };
// Capture the native Session API boundary. Production Windows tests also cover
// the audio mutation and undo/redo through the complete Remote Presentation.
struct Session {
    jaras::Song model;
    jaras::TransportState state;
    int tempoCalls=0,pitchCalls=0;
    double requestedTempo=0;
    int requestedPitch=0;
    ID requestedRegion;
    std::vector<ID> requestedTracks,requestedGroups;
    const jaras::TransportState &transport() const { return state; }
    void setTempo(double value) { ++tempoCalls;requestedTempo=value; }
    void setRegionPitch(const ID &region,int value,std::vector<ID> tracks,std::vector<ID> groups) {
        ++pitchCalls;requestedRegion=region;requestedPitch=value;
        requestedTracks=std::move(tracks);requestedGroups=std::move(groups);
    }
};
struct Presentation {
    Session &session;
    State snapshot() {
        const auto *song=&session.model;
        State result;
// INSERT_PITCH_SNAPSHOT
        return result;
    }
    bool apply(const String &a,const Command &c) {
        const auto *song=&session.model;
// INSERT_TUNING_COMMANDS
        return false;
    }
};
int main() {
    Session session;
    auto &song=session.model;
    song.parts={{"first","First",0,10},{"second","Second",10,20},
                {"unified","Unified",20,40},{"child-a","Child A",20,30},{"child-b","Child B",30,40}};
    song.parts[3].parentRegionID="unified";song.parts[4].parentRegionID="unified";
    jaras::Track group;group.id="group";group.role.id="other";
    auto track=group;track.id="keys";track.parentTrackID="group";
    auto click=group;click.id="click";click.role.id="generatedClick";
    song.tracks={group,track,click};
    Presentation remote{session};
    assert(remote.snapshot().empty());
    assert(!remote.apply("pitch",{"first",3}));
    session.state.regionId="first";
    auto state=remote.snapshot();
    assert(std::get<std::string>(state.at("pitchRegion"))=="first");
    assert(std::get<int>(state.at("pitchSemitones"))==0);
    assert(remote.apply("pitch",{"first",3}));
    assert(session.pitchCalls==1 && session.requestedRegion=="first" && session.requestedPitch==3);
    assert(session.requestedTracks==std::vector<ID>{"keys"});
    assert(session.requestedGroups==std::vector<ID>{"group"});
    song.parts[0].pitchTrackIDs=std::vector<ID>{};
    song.parts[0].pitchGroupIDs=std::vector<ID>{"group"};
    song.parts[0].pitchSemitones=-4;
    assert(std::get<int>(remote.snapshot().at("pitchSemitones"))==-4);
    assert(remote.apply("pitch",{"first",-5}));
    assert(session.requestedTracks.empty() && session.requestedGroups==std::vector<ID>{"group"});
    session.state.regionId="second";
    assert(!remote.apply("pitch",{"first",3}));
    assert(session.pitchCalls==2);
    assert(remote.apply("pitch",{"second",12}));
    session.state.regionId="unified";
    assert(std::get<std::string>(remote.snapshot().at("pitchRegion"))=="child-a");
    assert(!remote.apply("pitch",{"unified",2}));
    assert(remote.apply("pitch",{"child-a",2}));
    session.state.playing=true;session.state.position=32;
    assert(std::get<std::string>(remote.snapshot().at("pitchRegion"))=="child-b");
    assert(!remote.apply("pitch",{"child-a",2}));
    assert(remote.apply("pitch",{"child-b",2}));
    session.state.ignoreNextRegionId="child-a";
    assert(std::get<std::string>(remote.snapshot().at("pitchRegion"))=="child-a");
    assert(remote.apply("pitch",{"child-a",2}));
    for(double bpm:{141.,142.,141.}) assert(remote.apply("tempo",{{},bpm}));
    assert(session.tempoCalls==3 && session.requestedTempo==141);
    std::cout << "WINDOWS_REMOTE_TUNER_SNAPSHOT_TARGETS_UNIFIED_PLAYBACK_STALE_GUARDS_AND_TEMPO_ROUTING_OK\n";
}
