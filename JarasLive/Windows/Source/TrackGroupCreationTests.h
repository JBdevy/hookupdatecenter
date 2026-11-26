#pragma once
#include "TrackEditing.h"
namespace catlive::trackGroupCreationTests {
inline void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
inline jaras::Track track(const char *name) {
    jaras::Track value; value.id = uuid(); value.name = name; value.role.id = "other"; return value;
}
template <typename Test> inline void run(Test &&test) {
    test("Create group includes all following roots and preserves nested group output", [] {
        jaras::Song song; song.id = uuid();
        auto before = track("Before"), master = track("Master"), nested = track("Nested"), inner = track("Inner"), child = track("Child"), last = track("Last");
        master.outputs = std::vector<jaras::OutputPatch>{{0,2},{3,2}};
        nested.outputs = std::vector<jaras::OutputPatch>{{0,2},{7,2}};
        inner.parentTrackID = nested.id; inner.patch = jaras::OutputPatch{-2,2};
        child.parentTrackID = inner.id; child.patch = jaras::OutputPatch{-2,2};
        last.outputs = std::vector<jaras::OutputPatch>{};
        song.tracks = {before,master,nested,inner,child,last};
        expect(trackEditing::canCreateGroup(song,master.id),"Root track cannot create group");
        trackEditing::createGroup(song,master.id);
        expect(!song.tracks[0].parentTrackID && !song.tracks[1].parentTrackID,"Group changed tracks above its children");
        expect(song.tracks[2].parentTrackID == master.id && song.tracks[5].parentTrackID == master.id,"Following roots did not join group");
        expect(song.tracks[3].parentTrackID == nested.id && song.tracks[4].parentTrackID == inner.id,"Nested tree was flattened");
        expect(song.tracks[2].outputPatches()[0].firstChannel == -2 && song.tracks[5].outputPatches()[0].firstChannel == -2,"Nested folder or empty output does not route to parent");
        expect(song.tracks[2].outputPatches().size()==2 && song.tracks[2].outputPatches()[1].firstChannel==7,"Auxiliary output was lost");
        expect(song.tracks[1].outputPatches()[0].firstChannel==0 && song.tracks[1].outputPatches()[1].firstChannel==3,"Group master output changed");
        expect(song.tracks[3].outputPatches()[0].firstChannel==-2 && song.tracks[4].outputPatches()[0].firstChannel==-2,"Inner audio routing changed");
    });
    test("Create group is unavailable for members special tracks and the final root", [] {
        jaras::Song song; song.id = uuid();
        auto click = track("Click"), pads = track("VINHETAS-FX"), master = track("Master"), child = track("Child"), last = track("Last");
        click.role.id="generatedClick";pads.role.id="vinhetas";child.parentTrackID=master.id;child.patch=jaras::OutputPatch{-2,2};
        song.tracks={pads,click,master,child,last};
        for(const auto &id:{pads.id,click.id,child.id,last.id,uuid()}) {
            expect(!trackEditing::canCreateGroup(song,id),"Unsupported track has create group action");
            trackEditing::createGroup(song,id);
        }
        expect(!song.tracks.back().parentTrackID,"Unavailable group action changed document");
        trackEditing::createGroup(song,master.id);
        expect(!song.tracks[0].parentTrackID && !song.tracks[1].parentTrackID,"Special track entered group");
        expect(song.tracks[3].parentTrackID==master.id && song.tracks[4].parentTrackID==master.id,"Existing and new children lost group");
    });
    test("Create group preserves linked children and rejects linked master", [] {
        jaras::Song song; song.id=uuid();
        auto master=track("Master"),left=track("Left"),right=track("Right"),last=track("Last");
        left.stereoLinkPartner=right.id;right.stereoLinkPartner=left.id;
        song.tracks={master,left,right,last};
        expect(!trackEditing::canCreateGroup(song,left.id),"Stereo linked track can become folder");
        trackEditing::createGroup(song,master.id);
        expect(song.tracks[1].parentTrackID==master.id && song.tracks[2].parentTrackID==master.id,"Linked pair separated");
        expect(song.tracks[1].stereoLinkPartner==right.id && song.tracks[2].stereoLinkPartner==left.id,"Group action removed stereo link");
    });
}
}
