#pragma once
#include "FloatingControlTests.h"
#include "TrackVisibilityPanel.h"
#include "ModalSheet.h"

namespace catlive {
struct TrackVisibilityTests {
    using Panel=TrackVisibility::Panel;
    static void require(bool value,const char *message) {if(!value)throw std::runtime_error(message);}
    struct Fixture {
        jaras::Project project;
        ID timecode=uuid(),click=uuid(),group=uuid(),first=uuid(),second=uuid(),outside=uuid();
        ID firstItem=uuid(),secondItem=uuid(),outsideItem=uuid();
        Fixture() {
            project.id=uuid();project.name="Track visibility";
            jaras::Song song;song.id=uuid();song.name="Song";song.duration=4;
            auto track=[&](ID id,const char *name,const char *role) {
                jaras::Track value;value.id=id;value.name=name;value.role.id=role;return value;
            };
            song.tracks={track(timecode,"Timecode","timecode"),track(click,"Click","generatedClick"),
                track(group,"Group","group"),track(first,"First","other"),
                track(second,"Second","other"),track(outside,"Outside","other")};
            song.tracks[3].parentTrackID=group;song.tracks[4].parentTrackID=group;
            song.tracks[0].mute=true;song.tracks[1].mute=true;
            for(int i=3;i<6;++i) {
                jaras::AudioClip clip;clip.id=i==3?firstItem:i==4?secondItem:outsideItem;
                clip.duration=4;clip.audioFile=jaras::AudioFile{"tone.wav",{}};clip.muted=i!=3;
                song.tracks[(size_t)i].clips={clip};
            }
            song.parts={{uuid(),"Music",0,4}};project.songs={song};
            project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        }
    };
    static void preferences(const File &directory) {
        Fixture fixture;const auto &song=fixture.project.songs[0];
        const auto path=directory.getNonexistentChildFile("track-visibility-preferences",".json");
        Appearance settings(path);TrackVisibility visibility;visibility.load(settings,fixture.project.id);
        require(visibility.set(settings,fixture.project.id,Panel::trackMixer,fixture.second,false).wasOk() &&
                visibility.set(settings,fixture.project.id,Panel::trackMixer,fixture.group,false).wasOk() &&
                visibility.set(settings,fixture.project.id,Panel::barMixer,fixture.outside,false).wasOk(),
                "Cannot save independent track visibility choices");
        require(!visibility.visible(song,Panel::trackMixer,fixture.first) &&
                visibility.ownVisible(Panel::trackMixer,fixture.first) &&
                !visibility.ownVisible(Panel::trackMixer,fixture.second) &&
                visibility.visible(song,Panel::barMixer,fixture.first) &&
                visibility.visible(song,Panel::trackMixer,fixture.outside),
                "Hiding a group overwrote its children's choices or crossed mixer panels");
        Appearance reopened(path);TrackVisibility restored;restored.load(reopened,fixture.project.id);
        require(!restored.visible(song,Panel::trackMixer,fixture.first) &&
                !restored.visible(song,Panel::barMixer,fixture.outside),"Visibility choices did not survive reloading preferences");
        require(restored.set(reopened,fixture.project.id,Panel::trackMixer,fixture.group,true).wasOk() &&
                restored.visible(song,Panel::trackMixer,fixture.first) &&
                !restored.visible(song,Panel::trackMixer,fixture.second),
                "Showing the group did not restore the child's independent hidden choice");
        const auto anotherProject=uuid();restored.load(reopened,anotherProject);
        require(restored.visible(song,Panel::trackMixer,fixture.second) &&
                restored.visible(song,Panel::barMixer,fixture.outside),"Another project inherited hidden tracks with reused IDs");
        restored.load(reopened,fixture.project.id);
        require(!restored.visible(song,Panel::trackMixer,fixture.second) &&
                !restored.visible(song,Panel::barMixer,fixture.outside),"Changing projects lost the original project's choices");
    }
    static void workspace(const File &directory) {
        Fixture fixture;
        const auto folder=directory.getNonexistentChildFile("track-visibility-audio","");
        require(folder.createDirectory().wasOk(),"Cannot create visibility audio fixture directory");
        auto stream=folder.getChildFile("tone.wav").createOutputStream();WavAudioFormat format;
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(),48000,2,24,{},0));
        require(bool(writer),"Cannot create visibility audio fixture");stream.release();
        AudioBuffer<float> tone(2,48000*4);
        for(int sample=0;sample<tone.getNumSamples();++sample)
            for(int channel=0;channel<2;++channel)
                tone.setSample(channel,sample,.2f*std::sin(sample*2*MathConstants<double>::pi*440/48000));
        require(writer->writeFromAudioSampleBuffer(tone,0,tone.getNumSamples()),"Cannot write visibility audio fixture");writer.reset();
        Session session;session.inspection=true;session.mediaDirectory=folder;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(fixture.project));session.audio.setOffline(true);session.dirty=false;
        Auth auth;Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("track-visibility-ui",".json"));
        w.setSize(1600,1000);w.footerMixerVisible=true;w.resized();
        session.command(jaras::CommandKind::play);
        const auto original=JSON::toString(session.snapshot());const auto revision=session.revision;
        const bool undo=session.canUndo(),redo=session.canRedo();
        const auto audible=[&] {
            AudioBuffer<float> output(2,512);float peak=0;
            for(int block=0;block<4;++block) {
                session.audio.render(output.getArrayOfWritePointers(),2,output.getNumSamples());
                peak=std::max(peak,output.getMagnitude(0,output.getNumSamples()));
            }
            require(session.audio.state().playing && peak>.01f,"Hiding a playing track/group stopped or silenced its audio");
        };
        audible();
        auto *open=dynamic_cast<Button *>(uiFeatureTests::find(w,"trackVisibilityManager"));
        require(open && open->onClick,"Track visibility manager button missing");open->onClick();
        auto *panel=uiFeatureTests::find(w,"trackVisibilityPanel");require(panel,"Visibility button did not open its panel");
        open->onClick();
        int sheets=0;for(auto *child:w.getChildren())if(dynamic_cast<ModalSheet*>(child))++sheets;
        require(sheets==1,"Opening visibility twice duplicated the manager");
        auto checkbox=[&](Panel which,const ID &id) {
            auto *control=dynamic_cast<ToggleButton *>(uiFeatureTests::find(*panel,
                "trackVisibility:"+TrackVisibility::panelName(which)+":"+text(id)));
            require(control,"Visibility checkbox missing");return control;
        };
        auto change=[&](Panel which,const ID &id,bool visible) {
            auto *control=checkbox(which,id);require(control->isEnabled(),"Visibility checkbox unexpectedly inherited a hidden group");
            control->setToggleState(visible,dontSendNotification);control->onClick();
        };
        auto hidden=[&](const ID &id){return w.rowHidden((int)trackTree::index(*session.song(),id));};
        auto strip=[&](const ID &id){return uiFeatureTests::find(*w.footerMixer,"mixerStrip:"+text(id));};
        w.selectedTrack=fixture.second;w.selectedTracks={fixture.second};w.trackSelectionAnchor=fixture.second;
        w.selectedClip=fixture.secondItem;w.selectedClips={fixture.secondItem};
        change(Panel::trackMixer,fixture.second,false);
        require(hidden(fixture.second) && w.rowHeight((int)trackTree::index(*session.song(),fixture.second))==0 &&
                strip(fixture.second) && w.selectedTracks.empty() && w.selectedClips.empty(),
                "Hiding a Track Mixer row did not remove its grid height/selection, or also hid its Hoz-Mixer strip");
        change(Panel::trackMixer,fixture.group,false);
        require(hidden(fixture.group) && hidden(fixture.first) && hidden(fixture.second) &&
                !checkbox(Panel::trackMixer,fixture.first)->isEnabled() && checkbox(Panel::trackMixer,fixture.first)->getToggleState() &&
                !checkbox(Panel::trackMixer,fixture.second)->isEnabled() && !checkbox(Panel::trackMixer,fixture.second)->getToggleState(),
                "Group hiding lost child choices or allowed editing an inherited hidden row");
        audible();
        auto *barTab=dynamic_cast<Button *>(uiFeatureTests::find(*panel,"trackVisibilityBarTab"));
        require(barTab && barTab->onClick,"Hoz-Mixer visibility tab missing");barTab->onClick();
        require(!uiFeatureTests::find(*panel,"trackVisibility:barMixer:"+text(fixture.timecode)) &&
                checkbox(Panel::barMixer,fixture.click)->isEnabled(),"Hoz-Mixer visibility listed an unavailable special track or omitted Click");
        change(Panel::barMixer,fixture.outside,false);change(Panel::barMixer,fixture.group,false);
        require(!strip(fixture.outside) && !strip(fixture.group) && !strip(fixture.first) && !strip(fixture.second) &&
                strip(fixture.click) && !hidden(fixture.outside) && uiFeatureTests::find(*w.footerMixer,"mixerMaster"),
                "Hoz-Mixer hiding changed the grid, retained a hidden child strip or removed Master");
        audible();
        auto *trackTab=dynamic_cast<Button *>(uiFeatureTests::find(*panel,"trackVisibilityTrackTab"));
        require(trackTab && trackTab->onClick,"Track Mixer visibility tab missing");trackTab->onClick();
        change(Panel::trackMixer,fixture.group,true);
        require(!hidden(fixture.group) && !hidden(fixture.first) && hidden(fixture.second) &&
                checkbox(Panel::trackMixer,fixture.first)->isEnabled() &&
                !checkbox(Panel::trackMixer,fixture.second)->getToggleState() && !strip(fixture.first),
                "Showing Track Mixer group reset a hidden child or changed Hoz-Mixer visibility");
        ModalSheet::dismiss(*panel);floatingControlTests::pump();
        w.selectAllTracks(false);
        require(w.selectedTracks==std::set<ID>{fixture.click,fixture.group,fixture.first,fixture.outside},
                "Track Mixer Select All included hidden rows or omitted visible editable tracks");
        w.selectAllTracks(true);require(w.selectedTracks==std::set<ID>{fixture.click},
                "Hoz-Mixer Select All selected hidden tracks");
        w.selectMixerTrack(fixture.first,{});w.selectMixerTrack(fixture.outside,ModifierKeys(ModifierKeys::shiftModifier));
        require(w.selectedTracks==std::set<ID>{fixture.first,fixture.outside},"Shift selection included a hidden track between visible endpoints");
        // Loading a Timecode track creates one native item for the fixture's
        // region. It is visible and belongs in Select All alongside the audio.
        const auto &timecode=session.song()->tracks[trackTree::index(*session.song(),fixture.timecode)];
        require(timecode.clips.size()==1,"Visibility fixture did not generate its region Timecode item");
        w.selectAllGridItems();
        require(!w.selectedClips.count(fixture.secondItem),"Grid Select All selected an item on a hidden track");
        require(w.selectedClips==std::set<ID>{fixture.firstItem,fixture.outsideItem,timecode.clips[0].id},
                "Grid Select All omitted visible audio/Timecode or selected an unrelated item");
        const auto items=list(get(get(w.diagnostics(),"timeline"),"visibleItems"));
        bool firstDrawn=false,outsideDrawn=false;
        for(const auto &item:items) {
            require(get(item,"id").toString()!=text(fixture.secondItem),"Hidden track's item remained drawn in the timeline");
            firstDrawn|=get(item,"id").toString()==text(fixture.firstItem);
            outsideDrawn|=get(item,"id").toString()==text(fixture.outsideItem);
        }
        require(firstDrawn && outsideDrawn,"Visible tracks lost their grid items when another row was hidden");
        require(!session.dirty && session.canUndo()==undo && session.canRedo()==redo && session.revision==revision &&
                JSON::toString(session.snapshot())==original,"Visibility changes edited the project, audio routing or Undo history");
        audible();session.command(jaras::CommandKind::stopAll);
    }
};
template <typename Test> void addTrackVisibilityTests(const File &directory,Test &test) {
    test("Track visibility persists by project and mixer without overwriting child choices",[&]{TrackVisibilityTests::preferences(directory);});
    test("Track visibility manager hides only its presentation, filters selections and keeps hidden audio playing",[&]{TrackVisibilityTests::workspace(directory);});
}
} // namespace catlive
