#pragma once
#include "MixerPanel.h"
#include "FloatingControlTests.h"

namespace catlive { struct HozMixerFocusTests { static void run(const File &directory); }; }
namespace catlive::hozMixerFocusTests {
using floatingControlTests::require;
template<typename Test> void registerTests(const File &directory,Test &test) {
    test("Hoz-Mixer focus requires deliberate Shift-wheel travel and rejects jitter, inertia and repeated toggles",[] {
        HozMixerFocusGesture gesture;
        require(std::abs(HozMixerFocusGesture::wheelDelta(0,60./256.,false)-.1)<1e-9,
                "A physical Win32 wheel notch is not normalized to forty gesture units");
        require(std::abs(HozMixerFocusGesture::wheelDelta(60./256.,0,false)-.1)<1e-9,
                "Driver-remapped discrete Shift-wheel is ignored");
        require(HozMixerFocusGesture::wheelDelta(.2,0,true)==0 && HozMixerFocusGesture::wheelDelta(.2,.001,true)==0,
                "A smooth horizontal swipe changes the vertical focus gesture");
        for(int i=0;i<1;++i) require(!gesture.update(.1,i*.05),"Short wheel travel changed the Hoz-Mixer layout");
        require(gesture.update(.1,.1)==std::optional<bool>(true),"Two upward notches did not focus FX slots");
        for(int i=1;i<20;++i)require(!gesture.update(.1,.1+i*.05),"One continuous gesture triggered multiple actions");
        for(int i=0;i<1;++i)require(!gesture.update(-.1,1.5+i*.05),"Direction reversal retained earlier wheel travel");
        require(gesture.update(-.1,1.6)==std::optional<bool>(false),"Downward gesture did not restore the normal layout");
        gesture.reset();
        for(int i=0;i<1;++i)require(!gesture.update(.1,3+i*.05),"Partial post-reset gesture fired");
        require(!gesture.update(.1,4),"A gesture after the idle gap retained earlier wheel travel");
        gesture.reset();
        for(int i=0;i<40;++i)require(!gesture.update(i%2?.1:-.1,5+i*.03),"Alternating wheel jitter changed layout");
        gesture.reset();require(!gesture.update(100,7),"A single driver spike changed layout");
        gesture.reset();
        for(int i=0;i<20;++i)require(!gesture.update(.1,8+i*.03,true),"Momentum scrolling changed layout");
        for(int i=0;i<1;++i)require(!gesture.update(.1,9+i*.05),"Momentum contributed to the next deliberate gesture");
        require(gesture.update(.1,9.1)==std::optional<bool>(true),"Intentional input stopped working after ignored inertia");
    });
    test("Hoz-Mixer focus hides all controls except FX slots and names, persists globally and never changes audio",[&] {
        HozMixerFocusTests::run(directory);
    });
}
}

namespace catlive {
inline void HozMixerFocusTests::run(const File &directory) {
    const auto require=floatingControlTests::require;
    auto project=floatingControlTests::fixture();
    for(int i=3;i<14;++i){auto track=project.songs[0].tracks[0];track.id=uuid();track.name="Track "+std::to_string(i);project.songs[0].tracks.push_back(track);}
    const auto preferences=directory.getNonexistentChildFile("hoz-focus-appearance",".json");
    constexpr float notch=60.f/256.f;
    auto wheel=[&](Component &target,float delta,double seconds,int modifiers=ModifierKeys::shiftModifier,bool remapped=false) {
        const auto point=target.getLocalBounds().toFloat().getCentre(); const Time time((int64)std::llround(seconds*1000));
        MouseEvent event(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(modifiers),1,0,0,0,0,&target,&target,time,point,time,1,false);
        MouseWheelDetails details{};if(remapped)details.deltaX=delta;else details.deltaY=delta;target.mouseWheelMove(event,details);
    };
    auto check=[&](MixerPanel &panel,bool focused,bool rendered=true) {
        require(panel.isSlotsOnly()==focused,"Docked/detached Hoz-Mixer does not share the saved focus mode");
        if(!rendered) {
            require(!panel.isVisible() && panel.getHeight()==0,"The inactive docked Hoz-Mixer should be hidden with no allocated height");
            return;
        }
        for(auto *strip:{panel.master.get(),panel.strips[0]}) {
            const auto layout=strip->layout();
            require(strip->getLocalBounds().contains(layout.name),"Hoz-Mixer track name escaped the strip");
            if(focused) {
                require(!layout.slots.isEmpty() && strip->getLocalBounds().contains(layout.slots) &&
                        layout.slots.getBottom()<layout.name.getY() && layout.name.getBottom()>=strip->getHeight()-5 &&
                        strip->slotAt({layout.slots.getCentreX(),layout.slots.getY()+5})==0,
                        "Focused FX slots and bottom name overlap, clip, or cannot be activated");
                for(auto *child:strip->getChildren())require(!child->isVisible(),"A fader, pan, meter or other control remains visible in slots-only mode");
            } else require(strip->fader.isVisible() && strip->pan.isVisible() && strip->fx.isVisible() && strip->peak->isVisible(),
                           "Returning to normal mode did not restore mixer controls");
        }
    };
    {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);session.dirty=false;
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,preferences);
        workspace.setSize(1366,900);workspace.footerMixerVisible=true;workspace.resized();
        auto &panel=*workspace.footerMixer;panel.setSize(640,350);check(panel,false);
        // A saved oversized height must not push controls below the dock.
        workspace.mixerHeightSetting=724;workspace.resized();
        require(panel.getHeight()<=workspace.dockViewport.getHeight(),"Hoz-Mixer escaped the visible dock at maximum height");
        for(auto *strip:panel.strips)require(strip->getLocalBounds().contains(strip->layout().name),"Resizing clips the track name");
        panel.setSize(640,350);
        const auto firstID=project.songs[0].tracks[0].id,secondID=project.songs[0].tracks[1].id;
        workspace.selectedTracks={firstID,secondID};workspace.selectedTrack=firstID;
        auto *firstStrip=panel.strips[0];const auto point=firstStrip->layout().name.getCentre().toFloat();
        const Time now=Time::getCurrentTime();
        MouseEvent press(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,firstStrip,firstStrip,now,point,now,1,false);
        firstStrip->mouseDown(press);
        require(workspace.selectedTracks.size()==2,"Mouse-down collapsed the track selection before a drag");
        firstStrip->mouseUp(press);
        require(workspace.selectedTracks==std::set<ID>{firstID},"Click release did not select only the clicked track");
        const auto snapshot=JSON::toString(session.snapshot());const auto revision=session.revision;
        const auto undo=session.canUndo(),redo=session.canRedo();
        auto &fader=panel.strips[0]->fader;auto &pan=panel.strips[0]->pan;
        const auto gain=fader.getValue(),panValue=pan.getValue();
        // Real child-to-parent wheel routing: this must not enter Slider's
        // value edit path or move the horizontal mixer scrollbar.
        const std::vector<Component*> targets{&fader,&pan,&panel.strips[0]->mute,&panel.horizontal,&panel.viewport};
        wheel(*targets[0],notch,10);check(panel,false);
        wheel(*targets[1],notch,10.05);check(panel,true);
        for(int i=2;i<5;++i){wheel(*targets[(size_t)i],notch,10+i*.05);check(panel,true);}
        require(panel.scrollX()==0 && fader.getValue()==gain && pan.getValue()==panValue,
                "Shift-wheel over a child parameter changed audio or scrolled tracks");
        require((bool)Appearance(preferences).value("catlive.hozMixer.slotsOnly",false),"Hoz-Mixer focus was not saved globally");
        for(const auto size:{Point<int>{360,232},Point<int>{1000,480}}){panel.setSize(size.x,size.y);check(panel,true);}
        FileOutputStream image(directory.getChildFile("hoz-mixer-slots-only.png"));
        require(image.openedOk() && PNGImageFormat().writeImageToStream(panel.createComponentSnapshot(panel.getLocalBounds()),image),
                "Cannot save focused Hoz-Mixer screenshot");
        workspace.showDetachedMixer();
        auto *floating=dynamic_cast<MixerPanel*>(workspace.floatingWindows.at("Mixer")->getContentComponent());
        require(floating,"Detached Hoz-Mixer was not created");check(*floating,true);
        for(int i=0;i<2;++i)wheel(floating->horizontal,-notch,12+i*.05,ModifierKeys::shiftModifier,true);
        check(*floating,false);check(panel,false,false);
        require(!(bool)Appearance(preferences).value("catlive.hozMixer.slotsOnly",true),"Normal Hoz-Mixer layout did not persist");
        // An unmodified wheel retains the old horizontal scrolling behavior.
        wheel(floating->strips[0]->fader,-.1,13,0);
        require(floating->scrollX()==32,"Ordinary wheel scrolling changed with the new Shift gesture");
        for(int i=0;i<2;++i)wheel(floating->viewport,notch,14+i*.05);
        check(panel,true,false);check(*floating,true);
        // Same state transition as the Dock mixer action: restoring allocation
        // must also restore valid geometry after the hidden panel had height 0.
        workspace.floatingWindows.at("Mixer")->setVisible(false);
        workspace.mixerDetached=false;workspace.footerMixerVisible=true;workspace.resized();check(panel,true);
        require(!session.dirty && session.revision==revision && session.canUndo()==undo && session.canRedo()==redo &&
                JSON::toString(session.snapshot())==snapshot,"Hoz-Mixer presentation modified the project, Undo, or audio settings");
    }
    auto otherProject=project;otherProject.id=uuid();otherProject.name="Different project";
    Session restored;restored.inspection=true;restored.audio.prepareOffline(48000);
    restored.restoreSnapshot(ProjectCodec::encode(otherProject));restored.audio.setOffline(true);
    Auth auth;Lighting lighting(restored);Workspace reopened(restored,auth,lighting,false,preferences);
    reopened.setSize(1366,900);reopened.footerMixerVisible=true;reopened.resized();check(*reopened.footerMixer,true);
}
}
