#pragma once
#include "MixerPanel.h"
#include "Workspace.h"
#include "UIFeatureTests.h"
namespace catlive { struct MasterMixerTests { static void run(const File &directory); }; }
namespace catlive::masterMixerTests {
inline void require(bool condition,const char *message) {if(!condition)throw std::runtime_error(message);}
template<typename Test> void registerTests(const File &directory,Test &test) {
    test("Mixer Master stays fixed and wider while only track strips scroll",[&] {
        jaras::Project p;p.id=uuid();p.name="Pinned master";
        jaras::Song song;song.id=uuid();song.name="Song";song.duration=30;
        for(int i=0;i<14;++i){jaras::Track t;t.id=uuid();t.name="Track "+std::to_string(i);t.role.id="other";song.tracks.push_back(t);}
        p.songs={song};p.savedCursor=jaras::SavedProjectCursor{song.id,0};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(p));session.audio.setOffline(true);
        String failure;ID openedTrack="unset",contextTrack="unset";String openedEffect;int selected=0,contextMenus=0;
        MixerPanel mixer(session,[&](ID id,String effect){openedTrack=id;openedEffect=effect;},
            [&](ID,ModifierKeys){++selected;},[&](String error){failure=error;},
            [&](ID id,bool remove){fxchain::change(session,{id},remove);},[](ID){return false;},[&](ID id,Point<int>){contextTrack=id;++contextMenus;});
        mixer.setSize(640,350);
        auto *master=uiFeatureTests::find(mixer,"mixerMaster");
        auto *track=uiFeatureTests::find(mixer,"mixerStrip:"+text(song.tracks[0].id));
        auto *view=dynamic_cast<Viewport*>(uiFeatureTests::find(mixer,"mixerTracksViewport"));
        auto *scroll=dynamic_cast<ScrollBar*>(uiFeatureTests::find(mixer,"mixerHorizontalScroll"));
        require(master&&track&&view&&scroll,"Mixer fixed or scrollable strips missing");
        const auto fixed=master->getBounds();
        require(std::abs(master->getWidth()-track->getWidth()*1.25)<1 && master->getX()==0 &&
                master->getParentComponent()==&mixer && master->getRight()<view->getX() && scroll->getX()>=view->getX(),
                "Master width or parent shares the scrolling track area");
        scroll->setCurrentRangeStart(500,sendNotificationSync);
        require(mixer.scrollX()>400 && master->getBounds()==fixed && track->getParentComponent()==view->getViewedComponent(),
                "Horizontal scrolling moved Master or failed to move ordinary tracks");
        for(const auto size:{Point<int>{360,240},Point<int>{1100,480}}) {
            mixer.setSize(size.x,size.y);
            require(master->getX()==0 && master->getWidth()==fixed.getWidth() &&
                    mixer.getLocalBounds().contains(master->getBounds()) && scroll->getX()>master->getRight(),
                    "Docked/detached resize clipped Master or moved its scrollbar over it");
        }
        mixer.setSize(640,350);
        mixer.setMasterRight(true);
        require(master->getRight()==mixer.getWidth() && master->getWidth()==fixed.getWidth() &&
                view->getX()==0 && view->getRight()<master->getX() && scroll->getRight()<=view->getRight(),
                "Moving Master right did not exclude its fixed strip from the scrollbar and viewport");
        const auto fixedRight=master->getBounds();scroll->setCurrentRangeStart(500,sendNotificationSync);
        require(mixer.scrollX()>400 && master->getBounds()==fixedRight,"Scrolling moved the right-hand Master");
        for(const auto size:{Point<int>{360,240},Point<int>{1100,480}}) {
            mixer.setSize(size.x,size.y);
            require(master->getRight()==mixer.getWidth() && master->getWidth()==fixed.getWidth() &&
                    mixer.getLocalBounds().contains(master->getBounds()) && scroll->getRight()<master->getX(),
                    "Right-hand Master resize changed its width or overlapped the track scrollbar");
        }
        mixer.setSize(640,350);mixer.setMasterRight(false);
        require(master->getBounds()==fixed && view->getX()>master->getRight(),"Returning Master left lost its original geometry");
        auto control=[&](const char *id){auto *c=uiFeatureTests::find(*master,id);require(c,"Master control missing");return c;};
        require(!control("mixerRecord")->isVisible()&&!control("mixerPhase")->isVisible(),"Master exposes track-only recording or phase controls");
        auto *fader=dynamic_cast<Slider*>(control("mixerFader"));auto *pan=dynamic_cast<Slider*>(control("mixerPan"));
        require(fader&&pan&&pan->getSliderStyle()==Slider::RotaryHorizontalVerticalDrag,"Master lacks fader or pan knob");
        fader->setValue(.5,dontSendNotification);fader->onValueChange();pan->setValue(-.4,dontSendNotification);pan->onValueChange();
        auto click=[&](const char *id){auto *b=dynamic_cast<Button*>(control(id));require(b&&bool(b->onClick),"Master action missing");b->onClick();};
        click("mixerMute");click("mixerSolo");click("mixerMono");click("mixerFX");mixer.refresh();
        require(std::abs(session.project().masterVolume-.5)<.001 && std::abs(session.project().masterPan+.4)<.001 &&
                session.project().masterMute&&session.project().masterSolo&&session.project().masterMono&&openedTrack.empty(),
                "Pinned Master controls did not address the global master bus");
        require(control("mixerMono")->getProperties()["icon"].toString()=="mono","Master mono must use the icon");
        for(const auto &t:session.song()->tracks)require(t.volume==1&&t.pan==0&&!t.mute&&!t.solo,"Master controls changed an ordinary track");
        auto effects=object();put(effects,"inserted",Array<var>{"EQ","Compressor"});put(effects,"eqEnabled",true);put(effects,"compressorEnabled",true);
        session.configureEffects(ID{},effects);mixer.refresh();
        auto event=[&](Point<float> at,Point<float> anchor,int modifiers,bool dragged=false){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(modifiers),1,0,0,0,0,master,master,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);};
        const Point<float> name{master->getWidth()*.5f,(float)master->getHeight()-12};
        const auto beforeMenu=JSON::toString(session.snapshot());
        master->mouseDown(event(name,name,ModifierKeys::rightButtonModifier));master->mouseUp(event(name,name,0));
        require(contextMenus==1&&contextTrack.empty()&&selected==0&&JSON::toString(session.snapshot())==beforeMenu,
                "Master background context did not reach the global Master menu or changed the selection/project");
        master->mouseDown(event(name,name,ModifierKeys::leftButtonModifier));master->mouseUp(event(name,name,0));
        require(contextMenus==1&&selected==0,"Plain Master click opened its context menu or selected a normal track");
        const Point<float> slot{20,20};
        auto slotClick=[&](int modifier){master->mouseDown(event(slot,slot,modifier|ModifierKeys::leftButtonModifier));master->mouseUp(event(slot,slot,modifier));};
        slotClick(0);require(openedTrack.empty()&&openedEffect=="EQ","Master slot opened another track's FX");
        slotClick(ModifierKeys::shiftModifier);require(!fxchain::enabled(fxchain::settings(session,{}),"EQ"),"Master slot Shift bypass failed");
        session.undo();require(fxchain::enabled(fxchain::settings(session,{}),"EQ"),"Master bypass Undo failed");
        slotClick(ModifierKeys::altModifier);require(list(get(fxchain::settings(session,{}),"inserted")).size()==1,"Master slot Alt removal failed");
        session.undo();require(list(get(fxchain::settings(session,{}),"inserted")).size()==2,"Master removal Undo failed");
        auto payload=object();put(payload,"type","catlive-fx-copy");put(payload,"project",text(p.id));put(payload,"source",text(song.tracks[0].id));put(payload,"effect","EQ");
        DragAndDropTarget::SourceDetails details(payload,track,{20,20});
        auto *drop=dynamic_cast<DragAndDropTarget*>(master);require(drop&&!drop->isInterestedInDragSource(details),"Master accepts dragged FX");
        const auto original=JSON::toString(session.snapshot());drop->itemDropped(details);
        require(JSON::toString(session.snapshot())==original,"Master applied a rejected effect drop");
        master->mouseDown(event(slot,slot,ModifierKeys::leftButtonModifier));
        master->mouseDrag(event({80,12},slot,ModifierKeys::leftButtonModifier,true));
        require(!mixer.isDragAndDropActive()&&selected==0,"Master starts FX or track dragging");
        master->mouseUp(event({80,12},slot,0,true));
        master->mouseDown(event(slot,slot,ModifierKeys::rightButtonModifier));
        require(contextMenus==1,"Master FX slot context leaked into the strip's Master menu");
        PopupMenu::dismissAllActiveMenus();master->mouseUp(event(slot,slot,0));
        require(failure.isEmpty(),"Master operation reported an error");
        mixer.refresh();
        FileOutputStream output(directory.getChildFile("mixer-fixed-master.png"));output.setPosition(0);output.truncate();
        require(output.openedOk()&&PNGImageFormat().writeImageToStream(mixer.createComponentSnapshot(mixer.getLocalBounds()),output),"Cannot save Master fixture screenshot");
    });
    test("Mixer wheel propagates once through controls and FX with either fixed Master side",[&] {
        jaras::Project project;project.id=uuid();project.name="Mixer wheel";
        jaras::Song song;song.id=uuid();song.name="Song";song.duration=30;
        for(int i=0;i<14;++i){jaras::Track track;track.id=uuid();track.name="Track "+std::to_string(i);track.role.id="other";song.tracks.push_back(track);}
        project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        ID openedTrack;String openedEffect,failure;
        MixerPanel mixer(session,[&](ID id,String effect){openedTrack=id;openedEffect=effect;},[](ID,ModifierKeys){},
            [&](String error){failure=error;},[](ID,bool){},[](ID){return false;},[](ID,Point<int>){});
        mixer.setBounds(24,24,640,320);mixer.setVisible(true);
        auto *scroll=dynamic_cast<ScrollBar*>(uiFeatureTests::find(mixer,"mixerHorizontalScroll"));
        auto *track=uiFeatureTests::find(mixer,"mixerStrip:"+text(song.tracks.front().id));
        auto *master=uiFeatureTests::find(mixer,"mixerMaster");
        require(scroll&&track&&master,"Mixer wheel strips or scrollbar are missing");
        auto *fader=dynamic_cast<Slider*>(uiFeatureTests::find(*track,"mixerFader"));
        auto *pan=dynamic_cast<Slider*>(uiFeatureTests::find(*track,"mixerPan"));
        auto *mute=uiFeatureTests::find(*track,"mixerMute");
        require(scroll&&track&&master&&fader&&pan&&mute,"Mixer wheel controls are missing");
        const auto wheel=[&](Component &target,Point<float> point,float x,float y,int modifiers=0) {
            MouseWheelDetails delta{};delta.deltaX=x;delta.deltaY=y;delta.isSmooth=true;
            // Session 0 has no visible HWND for WindowFromPoint. Start at the
            // actual control and exercise its normal parent/Viewport bubbling.
            // Full OS dispatch is covered by the interactive native UI check.
            const auto now=Time::getCurrentTime();
            MouseEvent event(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(modifiers),
                1,0,0,0,0,&target,&target,now,point,now,1,false);
            target.mouseWheelMove(event,delta);
        };
        const auto reset=[&] {scroll->setCurrentRangeStart(1,sendNotificationSync);scroll->setCurrentRangeStart(0,sendNotificationSync);};
        const auto original=JSON::toString(session.snapshot());
        for(bool right:{false,true}) {
            mixer.setMasterRight(right);
            const auto fixed=master->getBounds();
            for(auto *target:std::vector<Component*>{track,fader,pan,mute}) {
                reset();const auto point=target==track?Point<float>{40,(float)track->getHeight()-12}:target->getLocalBounds().toFloat().getCentre();
                wheel(*target,point,0,-.1f);
                if(mixer.scrollX()!=32||master->getBounds()!=fixed) {
                    const auto *under=Desktop::getInstance().getMainMouseSource().getComponentUnderMouse();
                    throw std::runtime_error(utf8("One control wheel event moved tracks twice or moved fixed Master: right="+String((int)right)+
                        " control="+target->getComponentID()+" scrollX="+String(mixer.scrollX())+" expectedMaster="+fixed.toString()+
                        " actualMaster="+master->getBounds().toString()+" scale="+String(Desktop::getInstance().getGlobalScaleFactor())+
                        " underMouse="+(under?under->getComponentID():String("null"))));
                }
                require(std::abs(scroll->getCurrentRangeStart()-mixer.scrollX())<.01,"Mixer scrollbar waited for a timer after wheel movement");
            }
            reset();wheel(*track,{20,20},-.1f,0);
            require(mixer.scrollX()==32,"Horizontal gesture was swallowed by an empty FX slot");
            reset();wheel(*track,{40,(float)track->getHeight()-12},.0001f,-.1f);
            require(mixer.scrollX()==32,"Tiny horizontal noise swallowed the dominant vertical wheel movement");
            reset();
            for(int i=0;i<50;++i)wheel(*track,{40,(float)track->getHeight()-12},-.001f,0);
            require(std::abs(mixer.scrollX()-16)<=1,"Small touchpad deltas were lost instead of accumulated");
            reset();wheel(*master,{40,(float)master->getHeight()-12},0,-.1f);
            require(mixer.scrollX()==0&&master->getBounds()==fixed,"Wheel on fixed Master body changed the scrolling track area");
        }
        require(JSON::toString(session.snapshot())==original&&fader->getValue()==1&&pan->getValue()==0,
                "Wheel changed fader, pan or project state");
        auto effects=object();put(effects,"inserted",Array<var>{"EQ","Compressor","Limiter","Delay","Reverb"});
        session.configureEffects(song.tracks.front().id,effects);session.configureEffects({},effects);mixer.refresh();
        const auto slotClick=[&](Component &strip) {
            const Point<float> point{20,20};
            const auto event=[&](int modifiers) {return MouseEvent(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(modifiers),1,0,0,0,0,&strip,&strip,Time::getCurrentTime(),point,Time::getCurrentTime(),1,false);};
            strip.mouseDown(event(ModifierKeys::leftButtonModifier));strip.mouseUp(event(0));
        };
        for(bool right:{false,true}) {
            mixer.setMasterRight(right);reset();
            wheel(*track,{20,20},-.1f,0);
            require(mixer.scrollX()==32,"Horizontal gesture was swallowed by overflowing FX slots");
            reset();wheel(*track,{20,20},.0001f,-.1f,ModifierKeys::shiftModifier);
            require(mixer.scrollX()==32,"Shift-wheel was redirected into the vertical FX list");
            reset();
            for(auto *strip:{track,master}) {
                wheel(*strip,{20,20},0,-.1f);slotClick(*strip);
                require(openedEffect=="Compressor"&&openedTrack==(strip==master?ID{}:song.tracks.front().id)&&mixer.scrollX()==0,
                        "Vertical FX wheel skipped a slot, selected the wrong bus or scrolled tracks");
                wheel(*strip,{20,20},0,.1f);slotClick(*strip);
                require(openedEffect=="EQ","Reverse FX wheel failed to restore the first slot");
                wheel(*strip,{20,20},.0001f,-.1f);slotClick(*strip);
                require(openedEffect=="Compressor"&&mixer.scrollX()==0,
                        "Diagonal noise diverted a predominantly vertical FX scroll into track scrolling");
                wheel(*strip,{20,20},0,.1f);
                wheel(*strip,{(float)strip->getWidth()-2,20},0,-.1f);slotClick(*strip);
                require(openedEffect=="Compressor"&&mixer.scrollX()==0,
                        "Wheel on the FX scrollbar moved tracks instead of the FX list");
                wheel(*strip,{(float)strip->getWidth()-2,20},0,.1f);slotClick(*strip);
                require(openedEffect=="EQ","FX scrollbar reverse wheel failed to restore the first slot");
            }
        }
        require(failure.isEmpty(),"Mixer wheel operation failed");
    });
    test("Master context shares transport actions and persists its side in both mixer presentations",[&] {MasterMixerTests::run(directory);});
}
}
namespace catlive {
inline void MasterMixerTests::run(const File &directory) {
    const auto require=masterMixerTests::require;
    jaras::Project project;project.id=uuid();project.name="Master placement";
    jaras::Song song;song.id=uuid();song.name="Song";song.duration=30;
    for(int i=0;i<14;++i){jaras::Track track;track.id=uuid();track.name="Track "+std::to_string(i);track.role.id="other";song.tracks.push_back(track);}
    project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
    const auto preferences=directory.getNonexistentChildFile("master-placement",".json");
    {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);session.dirty=false;
        const auto original=JSON::toString(session.snapshot());const auto revision=session.revision;
        const bool undo=session.canUndo(),redo=session.canRedo();
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,preferences);
        workspace.setSize(1366,900);workspace.footerMixerVisible=true;workspace.resized();
        const auto menuItems=[&](bool bar) {
            auto menu=workspace.masterMenu(bar);std::map<int,String> items;
            PopupMenu::MenuItemIterator iterator(menu);
            while(iterator.next()) {
                const auto &item=iterator.getItem();if(item.itemID<=0)continue;
                require(!item.isTicked,"Master side action must be a dynamic label, not a checked option");
                items[item.itemID]=item.text;
            }
            return items;
        };
        const auto transportMenu=menuItems(false);auto barMenu=menuItems(true);
        require(transportMenu==std::map<int,String>{{1,"Patch"},{2,"FX"},{3,"Env"},{4,"Editar pista"}},
                "Transport Master context changed its actions or exposes the bar placement option");
        require(barMenu.size()==5 && barMenu[5]==String::fromUTF8("Mostrar Master à direita"),
                "Left Master does not offer the right-placement action");
        for(const auto &entry:transportMenu)require(barMenu[entry.first]==entry.second,"Bar Master does not share the transport context actions");
        const auto checkSide=[&](MixerPanel &panel,bool right) {
            auto *master=uiFeatureTests::find(panel,"mixerMaster");
            auto *viewport=dynamic_cast<Viewport*>(uiFeatureTests::find(panel,"mixerTracksViewport"));
            auto *scroll=dynamic_cast<ScrollBar*>(uiFeatureTests::find(panel,"mixerHorizontalScroll"));
            auto *track=uiFeatureTests::find(panel,"mixerStrip:"+text(song.tracks[0].id));
            require(master&&viewport&&scroll&&track,"Master placement fixture is missing a mixer component");
            require(std::abs(master->getWidth()-track->getWidth()*1.25)<1 && master->getParentComponent()==&panel,
                    "Master lost its fixed host or its 25 percent extra width");
            require(right?(master->getRight()==panel.getWidth()&&viewport->getX()==0&&viewport->getRight()<master->getX()):
                          (master->getX()==0&&master->getRight()<viewport->getX()),"Master is on the wrong fixed side");
            require(scroll->getX()>=viewport->getX()&&scroll->getRight()<=viewport->getRight(),"Scrollbar extends under the fixed Master");
            const auto fixed=master->getBounds();scroll->setCurrentRangeStart(100,sendNotificationSync);
            require(master->getBounds()==fixed,"Track scrolling moved Master after a menu action");
        };
        for(bool right:{false,true}) {
            auto &panel=*workspace.footerMixer;panel.setMasterRight(right);
            int previousFader=0;
            for(int height:{232,240,255,256,300,480,724}) {
                panel.setSize(640,height);
                for(auto *strip:{panel.master.get(),panel.strips[0]}) {
                    const auto geometry=strip->layout();
                    require(strip->getLocalBounds().contains(geometry.name),"Compact mixer clipped the track name");
                    for(auto *control:std::vector<Component*>{&strip->fx,&strip->mute,&strip->solo,&strip->phase,
                            &strip->record,&strip->mono,&strip->pan,&strip->fader,strip->peak.get()}) {
                        if(!control->isVisible())continue;
                        require(strip->getLocalBounds().contains(control->getBounds()) &&
                                !geometry.name.intersects(control->getBounds()),"Compact track name overlaps or clips a mixer control");
                    }
                    require(strip->fader.getHeight()>=115,"Compact mixer sacrificed the fader to keep FX slots");
                    if(height<=255)require(geometry.slots.isEmpty()&&strip->visibleSlots()==0&&strip->slotAt({20,20})<0,
                        "Compact mixer still paints or hit-tests hidden FX slots");
                    else require(!geometry.slots.isEmpty()&&strip->slotAt({20,geometry.slots.getY()})==0,
                        "Expanded mixer failed to restore FX slots");
                }
                const int currentFader=panel.strips[0]->fader.getHeight();
                if(height>255)require(currentFader==previousFader,"Expanded mixer stretched controls instead of revealing slots");
                previousFader=currentFader;
            }
        }
        workspace.resized();workspace.footerMixer->setMasterRight(false);
        checkSide(*workspace.footerMixer,false);
        workspace.handleMasterMenu(5,false);checkSide(*workspace.footerMixer,false);
        workspace.handleMasterMenu(5,true);checkSide(*workspace.footerMixer,true);
        require((bool)Appearance(preferences).value("catlive.barMixer.masterRight",false) &&
                menuItems(true).at(5)==String::fromUTF8("Mostrar Master à esquerda"),"Right placement was not saved or the action label did not switch");
        workspace.showDetachedMixer();
        auto *floating=dynamic_cast<MixerPanel*>(workspace.floatingWindows.at("Mixer")->getContentComponent());
        require(floating,"Detached mixer is missing");checkSide(*floating,true);
        workspace.handleMasterMenu(5,true);checkSide(*workspace.footerMixer,false);checkSide(*floating,false);
        require(!(bool)Appearance(preferences).value("catlive.barMixer.masterRight",true),"Left placement did not persist");
        workspace.handleMasterMenu(5,true);checkSide(*workspace.footerMixer,true);checkSide(*floating,true);
        require(menuItems(false)==transportMenu && !session.dirty && session.canUndo()==undo && session.canRedo()==redo &&
                session.revision==revision && JSON::toString(session.snapshot())==original,
                "Master presentation changed the transport menu, project, history or audio state");
    }
    Session restored;restored.inspection=true;restored.audio.prepareOffline(48000);
    restored.restoreSnapshot(ProjectCodec::encode(project));restored.audio.setOffline(true);
    Auth auth;Lighting lighting(restored);Workspace workspace(restored,auth,lighting,false,preferences);
    workspace.setSize(1366,900);workspace.footerMixerVisible=true;workspace.resized();
    auto *master=uiFeatureTests::find(*workspace.footerMixer,"mixerMaster");
    require(master&&master->getRight()==workspace.footerMixer->getWidth(),"A new workspace did not restore Master on the saved side");
}
}
