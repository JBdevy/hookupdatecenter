#pragma once
#include "MixerPanel.h"
#include "FloatingControlTests.h"
#include "FXSchema.h"

namespace catlive { struct HozMixerFocusTests { static void run(const File &directory); static void slotPower(); }; }
namespace catlive::hozMixerFocusTests {
using floatingControlTests::require;
template<typename Test> void registerTests(const File &directory,Test &test) {
    test("FX slot power toggles bypass without opening the editor", [] { HozMixerFocusTests::slotPower(); });
    test("Hoz-Mixer retains controls when scrolling and ignores old slots-only settings",[&] {
        HozMixerFocusTests::run(directory);
    });
}
}

namespace catlive {
inline void HozMixerFocusTests::slotPower() {
    const auto require = floatingControlTests::require;
    auto drum = object();
    put(drum, "instrumentID", "drum-kit-1");
    require(MixerPanel::Strip::effectTitle(drum, "Instruments") == "Drum Kit 1", "Legacy instrument slot lost its timbre name");
    auto instance = object(); put(instance, "id", "test"); put(instance, "kind", "Instruments"); put(instance, "settings", drum);
    auto chain = object(); put(chain, "instances", Array<var>{instance});
    require(MixerPanel::Strip::effectTitle(chain, "Native:test") == "Drum Kit 1", "Dropped instrument slot must identify the timbre");
    auto project = floatingControlTests::fixture();
    auto effects = fxschema::defaults(true);
    put(effects, "inserted", Array<var>{"EQ"});
    put(effects, "eqEnabled", true);
    project.masterFXJSON = utf8(JSON::toString(effects));
    project.songs.front().tracks.front().fxJSON = project.masterFXJSON;
    Session session;
    session.inspection = true;
    session.audio.prepareOffline(48000);
    session.restoreSnapshot(ProjectCodec::encode(project));
    session.audio.setOffline(true);
    const auto track = project.songs.front().tracks.front().id;
    String opened;
    ID openedTrack;
    MixerPanel panel(session, [&](ID id, String effect) { opened = effect; openedTrack = id; },
                     [](ID, ModifierKeys) {}, [](String text) { throw std::runtime_error(utf8(text)); },
                     [](ID, bool) {}, [](ID) { return false; }, [](ID, Point<int>) {});
    panel.refresh();
    panel.setSize(450, 430);
    for (auto *strip : {panel.master.get(), panel.strips[0]}) {
        const auto id = strip == panel.master.get() ? ID{} : track;
        const auto slots = strip->layout().slots;
        require(!slots.isEmpty(), "FX slots must be visible");
        const auto power = strip->powerBounds(0).getCentre();
        const auto now = Time::getCurrentTime();
        const auto mouse = [&](Point<int> point, Point<int> down) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(), point.toFloat(),
                              ModifierKeys(ModifierKeys::leftButtonModifier), 1, 0, 0, 0, 0,
                              strip, strip, now, down.toFloat(), now, 1, point != down);
        };
        const auto samplePoint = Point<int>(slots.getRight() - 5, slots.getY() + 8);
        const auto before = strip->createComponentSnapshot(strip->getLocalBounds()).getPixelAt(samplePoint.x, samplePoint.y);
        strip->mouseDown(mouse(power, power));
        strip->mouseUp(mouse(power, power));
        require(!fxchain::enabled(fxchain::settings(session, id), "EQ") && opened.isEmpty(),
                "The power button must bypass only the specified insert without opening its editor");
        const auto after = strip->createComponentSnapshot(strip->getLocalBounds()).getPixelAt(samplePoint.x, samplePoint.y);
        require(before.getGreen() > before.getRed() && after.getRed() > after.getGreen(), "The bypassed slot must repaint red");
        strip->mouseDown(mouse(power, power));
        strip->mouseUp(mouse(power, power));
        require(fxchain::enabled(fxchain::settings(session, id), "EQ") && opened.isEmpty(), "A second click must re-enable the effect");
        const auto name = Point<int>(slots.getCentreX(), power.y);
        strip->mouseDown(mouse(name, name));
        strip->mouseUp(mouse(name, name));
        require(opened == "EQ" && openedTrack == id, "The name must open the associated plugin");
        opened.clear();
    }
    const auto group = panel.master->layout().bypass;
    require(group.getY() == panel.strips[0]->layout().bypass.getY() &&
            group.getHeight() == MixerSlotSections::bypassRowHeight + MixerSlotSections::sessionRowHeight,
            "Hoz Main must have both bypass controls with By All Fx aligned with the tracks");
    const auto point = Point<int>(group.getCentreX(), group.getBottom()-10);
    const auto now = Time::getCurrentTime();
    const auto input = MouseEvent(Desktop::getInstance().getMainMouseSource(), point.toFloat(),
        ModifierKeys::leftButtonModifier, 1.f, 0.f, 0.f, 0.f, 0.f, panel.master.get(), panel.master.get(), now,
        point.toFloat(), now, 1, false);
    panel.master->mouseDown(input);
    require(flag(fxchain::settings(session, {}), "sessionFXBypassed") &&
            fxchain::stripBypassed(fxchain::settings(session, track)), "Hoz Main must switch the session bypass");
    panel.master->mouseUp(input);
    panel.setSize(650, 580);
    auto *main = panel.master.get();
    require(!main->layout().sends.isEmpty() && main->layout().sends.getY() == panel.strips[0]->layout().sends.getY(),
            "Main and track Sends must share one header baseline");
    require(main->sendAt(main->layout().sends.getCentre()).has_value(), "Main Sends header cannot be clicked");
    main->updateSend(main->sendSlots().front(), track);
    require(main->sendSlots().size() == 2 && main->sendSlots()[1].destination == track &&
            session.song()->tracks[0].receivesMain() && !session.song()->tracks[0].inputMonitoring.value_or(false),
            "Main Sends must create the reciprocal Main capture route");
    auto restored = ProjectCodec::decode(ProjectCodec::encode(session.project()));
    require(restored.songs[0].tracks[0].routing->mainSendOrder == 0, "Main send order must survive saving");
    main->updateSend(main->sendSlots().front(), track);
    require(main->sendSlots().size() == 2, "Main must not add a destination twice");
    main->updateSend(main->sendSlots()[1], {});
    require(!session.song()->tracks[0].receivesMain(), "Removing the Main send must clear the capture route");
}

inline void HozMixerFocusTests::run(const File &directory) {
    const auto require=floatingControlTests::require;
    auto project=floatingControlTests::fixture();
    for(int i=3;i<14;++i){auto track=project.songs[0].tracks[0];track.id=uuid();track.name="Track "+std::to_string(i);project.songs[0].tracks.push_back(track);}
    const auto preferences=directory.getNonexistentChildFile("hoz-focus-appearance",".json");
    constexpr float notch=60.f/256.f;
    require(Appearance(preferences).set("catlive.hozMixer.slotsOnly", true).wasOk(), "Could not create legacy settings");
    auto wheel=[&](Component &target,float delta,double seconds,int modifiers=ModifierKeys::shiftModifier,bool remapped=false) {
        const auto point=target.getLocalBounds().toFloat().getCentre(); const Time time((int64)std::llround(seconds*1000));
        MouseEvent event(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(modifiers),1,0,0,0,0,&target,&target,time,point,time,1,false);
        MouseWheelDetails details{};if(remapped)details.deltaX=delta;else details.deltaY=delta;target.mouseWheelMove(event,details);
    };
    auto check=[&](MixerPanel &panel,bool rendered=true) {
        if(!rendered) {
            require(!panel.isVisible() && panel.getHeight()==0,"The inactive docked Hoz-Mixer should be hidden with no allocated height");
            return;
        }
        for(auto *strip:{panel.master.get(),panel.strips[0]}) {
            const auto layout=strip->layout();
            require(strip->getLocalBounds().contains(layout.name),"Hoz-Mixer track name escaped the strip");
            require(strip->fader.isVisible() && strip->pan.isVisible() && strip->fx.isVisible() && strip->peak->isVisible(),
                    "Scrolling must leave the mixer controls visible");
            const auto fader = strip->fader.getBounds();
            require(strip->fader.isVertical() && strip->getLocalBounds().contains(fader),
                    "The vertical fader and its integrated meter fit inside the strip");
            strip->fader.setMeterLevels({.25f, .75f});
            require(strip->fader.meterLevels() == std::array<float, 2>{.25f, .75f},
                    "The fader retains independent left and right audio levels");
        }
    };
    {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);session.dirty=false;
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,preferences);
        workspace.setSize(1366,900);workspace.setlistVisible=true;workspace.footerMixerVisible=false;workspace.resized();
        const auto* setlist = uiFeatureTests::find(workspace, "setlistPanel");
        require(setlist, "Setlist panel is missing");
        const int setlistHeight = setlist->getHeight();
        workspace.footerMixerVisible = true;
        for (const auto placement : {Workspace::SetlistPlacement::left, Workspace::SetlistPlacement::right}) {
            workspace.setlistPlacement = placement;
            workspace.resized();
            require(setlist->getHeight() == setlistHeight && setlist->getBottom() == workspace.footerBounds.getY(),
                    "The Setlist must keep its full height with a docked Hoz Mixer");
            require(!workspace.dockViewport.getBounds().intersects(setlist->getBounds()),
                    "The Hoz Mixer dock must stop at the Setlist divider");
        }
        auto &panel=*workspace.footerMixer;panel.setSize(640,350);check(panel);
        {
            FileOutputStream screenshot(directory.getChildFile("hoz-mixer-fader-meter.png"));
            require(screenshot.openedOk() && PNGImageFormat().writeImageToStream(panel.createComponentSnapshot(panel.getLocalBounds()),screenshot),
                    "Cannot save Hoz-Mixer meter layout screenshot");
        }
        auto *farStrip=panel.strips.getLast();
        for(int height=351;height<390;++height)panel.setSize(640,height);
        require(farStrip->controlLayoutPending,"Offscreen controls were relaid out for every height change");
        require(farStrip->getHeight()==panel.content.getHeight(),"Deferred controls must retain exact strip geometry");
        const auto farID=farStrip->id;
        panel.viewport.setViewPosition(panel.content.getWidth(),0);
        require(!farStrip->controlLayoutPending && farStrip->fader.isVisible() &&
                farStrip->getLocalBounds().contains(farStrip->fader.getBounds()),
                "Scrolling after resize must restore controls before drawing the newly exposed track");
        panel.viewport.setViewPosition(0,0);
        require(panel.strips.getLast()==farStrip && farStrip->id==farID,
                "Resizing or scrolling rebuilt a retained mixer strip");
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
        // Repeated Shift-wheel scrolls retain the full controls in both presentations.
        const std::vector<Component*> targets{&fader,&pan,&panel.strips[0]->mute,&panel.horizontal,&panel.viewport};
        for (size_t i = 0; i < targets.size(); ++i) {
            wheel(*targets[i], -notch, 10 + i * .05);
            check(panel);
        }
        require(fader.getValue() == gain && pan.getValue() == panValue, "Scrolling changed track controls");
        workspace.showDetachedMixer();
        auto *floating=dynamic_cast<MixerPanel*>(workspace.floatingWindows.at("Mixer")->getContentComponent());
        require(floating,"Detached Hoz-Mixer was not created");
        for (int i = 0; i < 4; ++i) wheel(floating->horizontal, -notch, 12 + i * .05, ModifierKeys::shiftModifier, true);
        check(*floating); check(panel, false);
        workspace.floatingWindows.at("Mixer")->setVisible(false);
        workspace.mixerDetached=false;workspace.footerMixerVisible=true;workspace.resized();check(panel);
        require(!session.dirty && session.revision==revision && session.canUndo()==undo && session.canRedo()==redo &&
                JSON::toString(session.snapshot())==snapshot,"Hoz-Mixer presentation modified the project, Undo, or audio settings");
    }
    auto otherProject=project;otherProject.id=uuid();otherProject.name="Different project";
    Session restored;restored.inspection=true;restored.audio.prepareOffline(48000);
    restored.restoreSnapshot(ProjectCodec::encode(otherProject));restored.audio.setOffline(true);
    Auth auth;Lighting lighting(restored);Workspace reopened(restored,auth,lighting,false,preferences);
    reopened.setSize(1366,900);reopened.footerMixerVisible=true;reopened.resized();check(*reopened.footerMixer);
}
}
