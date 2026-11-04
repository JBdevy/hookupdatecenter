#include "../../Core/Project/MatrixPatch.hpp"
#include <iostream>
#include <cassert>
using namespace jaras;
int main() {
    Project project; project.id="project";project.name="Matrix";
    Song song;song.id="song";song.name="Song";song.duration=100;
    Track a;a.id="a";a.name="A";
    Track b;b.id="b";b.name="B";
    song.tracks={a,b};project.songs={song};validate(project);
    auto edit=[&](const ID& from,const ID& to){auto candidate=project;matrixPatch::toggleConnection(candidate.songs[0],from,to);validate(candidate);project=std::move(candidate);};
    edit("a","b");assert(matrixPatch::connection(project.songs[0].tracks[0],project.songs[0].tracks[1]));
    bool rejected=false;try{edit("b","a");}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
    assert(!matrixPatch::connection(project.songs[0].tracks[1],project.songs[0].tracks[0]));
    project.songs[0].tracks[1].routing=TrackRouting{};project.songs[0].tracks[1].routing->receives={"a","a"};
    edit("a","b");assert(!matrixPatch::connection(project.songs[0].tracks[0],project.songs[0].tracks[1]));
    assert(project.songs[0].tracks[1].routing->receives.empty());
    // A folder destination is the existing parent route, not a second send.
    project.songs[0].tracks[1].parentTrackID="a";
    project.songs[0].tracks[1].outputs=std::vector<OutputPatch>{{-2,2},{5,2}};
    project.songs[0].tracks[1].routing->transmitters={"a"};
    edit("b","a");assert(project.songs[0].tracks[1].parentTrackID=="a");
    assert(project.songs[0].tracks[1].outputPatches().size()==1);
    assert(matrixPatch::contains(project.songs[0].tracks[1].outputPatches(),{5,2}));
    assert(!matrixPatch::connection(project.songs[0].tracks[1],project.songs[0].tracks[0]));
    edit("b","a");assert(matrixPatch::contains(project.songs[0].tracks[1].outputPatches(),{-2,2}));
    rejected=false;try{edit("a","b");}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
    rejected=false;try{edit("a","a");}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
    assert(matrixPatch::toggled({{1,2},{1,2}},{1,2}).empty());
    const auto outputs=matrixPatch::toggled({{-1,2},{3,2}},{1,1});
    assert(outputs.size()==2 && matrixPatch::contains(outputs,{3,2}) && matrixPatch::contains(outputs,{1,1}));
    std::cout<<"Matrix Patch: routing, duplicate representations, groups, hardware and feedback passed\n";
}
