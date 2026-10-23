#pragma once
#include "FloatingShortcuts.h"
#include "UIFeatureTests.h"
#include "PlaylistEditor.h"
namespace catlive::floatingControlTests {
inline void require(bool okay, const char *message) { if (!okay) throw std::runtime_error(message); }
inline void pump() {
    for (int i=0;i<8;++i) { MSG m; while(PeekMessage(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessage(&m);} Thread::sleep(2); }
}
inline jaras::Project fixture() {
    jaras::Project p; p.id=uuid();p.name="Floating control regression";
    jaras::Song s;s.id=uuid();s.name="Song";s.duration=30;
    for(int i=0;i<3;++i){jaras::Track t;t.id=uuid();t.name="Track "+std::to_string(i);t.role.id="other";s.tracks.push_back(t);}
    s.parts={{uuid(),"First",0,15},{uuid(),"Second",15,30}};
    p.songs={s};p.savedCursor=jaras::SavedProjectCursor{s.id,0};return p;
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Marker shortcut modal focuses the name before the first typed character", [&] {
        Component host; host.setWantsKeyboardFocus(true); host.setSize(900,650);
        host.addToDesktop(ComponentPeer::windowIsTemporary);host.setVisible(true);host.grabKeyboardFocus();pump();
        auto panel=std::make_unique<RegionEditor>("Marker",0xff0000,false,[](String,unsigned,bool){},[]{},false);
        ModalSheet::open(host,"Marker",std::move(panel),380,330);pump();
        auto *editor=dynamic_cast<TextEditor *>(uiFeatureTests::find(host,"nameColourName"));
        require(editor && editor->hasKeyboardFocus(false),"Marker name did not receive modal focus");
        require(host.getPeer()->handleKeyPress(KeyPress('x',ModifierKeys(),L'x')),"First marker character was not handled");
        require(editor->getText()=="x","Typing did not replace the selected marker name");
        ModalSheet::dismiss(*editor);pump();
        require(!Component::getCurrentlyModalComponent(),"Marker modal did not dismiss");
    });
    test("Tap tempo matches Mac rounding, accidental taps, idle reset and limits", [] {
        for(auto measured:{123.2,123.8}){TapTempo tap;require(!tap.tap(0),"First tap must not change tempo");require(tap.tap(60/measured)==std::round(measured),"Mac rounding differs");}
        TapTempo tap;tap.tap(0);require(tap.tap(.5)==120 && tap.tap(1)==120,"Average differs");
        require(!tap.tap(1.01) && tap.tap(1.5)==120,"Accidental tap changed the clock");
        require(!tap.tap(6) && tap.tap(7)==60,"Idle reset differs");
        tap={};tap.tap(0);require(tap.tap(.15)==300,"Fast taps must clamp");
        tap={};tap.tap(0);require(tap.tap(2)==60,"Slow taps must clamp");
    });
    test("Delete preserves track selection after cancel or a declined edit and retries with one Undo", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        auto p=fixture();auto &tracks=p.songs[0].tracks;
        tracks[1].parentTrackID=tracks[0].id;tracks[1].patch=jaras::OutputPatch{-2,2};
        jaras::AudioClip clip;clip.id=uuid();clip.name="Item";clip.duration=3;tracks[1].clips={clip};
        tracks[1].fxJSON=utf8(JSON::toString(fxschema::defaults()));
        session.restoreSnapshot(ProjectCodec::encode(p));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("delete-selected",".json"));w.setSize(1366,768);
        const auto before=JSON::toString(session.snapshot());
        const auto id0=tracks[0].id,id1=tracks[1].id,remaining=tracks[2].id;
        auto select=[&](const ID &id,int flags){auto *row=uiFeatureTests::find(w,"trackRow:"+text(id));require(row,"Track row missing");Point<float> at{15,10};row->mouseDown(MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(flags|ModifierKeys::leftButtonModifier),1,0,0,0,0,row,row,Time::getCurrentTime(),at,Time::getCurrentTime(),1,false));};
        select(id0,0);select(id1,ModifierKeys::ctrlModifier);
        require(list(get(w.diagnostics(),"selectedTracks")).size()==2,"Fixture did not select two tracks");
        auto request=[&] {
            require(w.keyPressed(KeyPress(KeyPress::deleteKey)),"Delete was not handled after the previous confirmation");pump();
            auto *modal=Component::getCurrentlyModalComponent();require(modal,"Delete skipped confirmation");
            require(session.song()->tracks.size()==3,"Tracks removed before confirmation");
            return modal;
        };
        auto click=[&](Component *modal,const String &label) {
            Button *button=nullptr;
            for(auto *child:modal->getChildren())if(auto *candidate=dynamic_cast<Button *>(child);candidate && candidate->getButtonText()==label)button=candidate;
            require(button,"Confirmation action button missing");button->triggerClick();pump();
            require(!Component::getCurrentlyModalComponent(),"Confirmation did not close after clicking its button");
        };
        click(request(),"Cancelar");
        require(list(get(w.diagnostics(),"selectedTracks")).size()==2 && session.song()->tracks.size()==3,"Cancel removed tracks or their selection");
        auto *pending=request();session.busy=true;click(pending,"Continuar");session.busy=false;
        require(list(get(w.diagnostics(),"selectedTracks")).size()==2 && session.song()->tracks.size()==3,"Declined edit lost the selection needed to retry Delete");
        click(request(),"Continuar");
        require(session.song()->tracks.size()==1 && session.song()->tracks[0].id==remaining,"Delete left a selected track or removed the unselected track");
        session.undo();require(JSON::toString(session.snapshot())==before,"One Undo did not restore group, items and FX exactly");
        session.redo();require(session.song()->tracks.size()==1,"One Redo did not remove the selection");
    });
    test("Closing the Setlist playlist selector returns Space to transport without stealing text or modal input", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("playlist-focus",".json"));
        w.setSize(1366,768);w.addToDesktop(ComponentPeer::windowIsTemporary);w.setVisible(true);w.grabKeyboardFocus();pump();
        auto *selector=dynamic_cast<ComboBox *>(uiFeatureTests::find(w,"setlistPlaylistSelector"));
        require(selector,"Setlist playlist selector missing");
        require(!selector->getWantsKeyboardFocus()&&!selector->getMouseClickGrabsKeyboardFocus(),
                "Playlist mouse click still takes transport keyboard focus");
        const Point<float> at{10,10};
        selector->mouseDown(MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
            ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,selector,selector,
            Time::getCurrentTime(),at,Time::getCurrentTime(),1,false));pump();
        auto *callout=dynamic_cast<CallOutBox *>(Component::getCurrentlyModalComponent());
        require(callout,"Playlist mouse click did not open the picker");
        require(!w.keyPressed(KeyPress(KeyPress::spaceKey))&&!session.transport().playing,
                "Space escaped the open playlist modal");
        callout->dismiss();pump();
        require(!Component::getCurrentlyModalComponent(),"Playlist picker failed to close");
        require(!selector->keyPressed(KeyPress(KeyPress::spaceKey)),"Closed playlist selector still consumes Space");
        auto *peer=w.getPeer();require(peer,"Workspace native peer missing");
        require(peer->handleKeyPress(KeyPress(KeyPress::spaceKey))&&session.transport().playing,
                "Space after dismissing playlist did not start playback");
        require(!Component::getCurrentlyModalComponent(),"Space reopened the playlist picker");
        peer->handleKeyPress(KeyPress(KeyPress::spaceKey));
        require(session.transport().playing,"Held Space toggled playback repeatedly");
        peer->handleKeyUpOrDown(false);peer->handleKeyPress(KeyPress(KeyPress::spaceKey));
        require(!session.transport().playing,"Space after release did not stop playback");peer->handleKeyUpOrDown(false);
        // Even focus assigned by an accessibility client must bubble Space.
        selector->setWantsKeyboardFocus(true);selector->grabKeyboardFocus();pump();
        peer->handleKeyPress(KeyPress(KeyPress::spaceKey));
        require(session.transport().playing&&!Component::getCurrentlyModalComponent(),
                "Focused playlist selector reopened instead of routing Space");
        peer->handleKeyUpOrDown(false);peer->handleKeyPress(KeyPress(KeyPress::spaceKey));peer->handleKeyUpOrDown(false);
        require(!session.transport().playing,"Focused selector failed to route Stop");
        TextEditor editor;w.addAndMakeVisible(editor);editor.setBounds(300,100,200,25);editor.grabKeyboardFocus();pump();
        peer->handleKeyPress(KeyPress(KeyPress::spaceKey,ModifierKeys(),L' '));
        require(editor.getText()==" "&&!session.transport().playing&&!Component::getCurrentlyModalComponent(),
                "Typing Space in a text field triggered playback or playlist picker");
    });
    test("FX window routes transport and undo while preserving text, local keys and held Space", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("floating-keys",".json"));w.setSize(1366,768);
        const auto id=session.song()->tracks[0].id;
        w.openFX(id);pump();
        DocumentWindow *window=nullptr;
        auto &desktop=Desktop::getInstance();
        for(int i=0;i<desktop.getNumComponents();++i)if(auto *candidate=dynamic_cast<DocumentWindow *>(desktop.getComponent(i)))
            if(candidate->getContentComponent() && candidate->getContentComponent()->getComponentID()=="effectsPanel")window=candidate;
        require(window && window->getPeer(),"FX window has no native peer");
        auto *button=uiFeatureTests::find(*window,"saveFXPreset");require(button,"FX button missing");
        button->setEnabled(true);button->grabKeyboardFocus();pump();
        auto *peer=window->getPeer();
        require(peer->handleKeyPress(KeyPress(KeyPress::spaceKey)),"FX did not route Space");
        require(session.transport().playing && !Component::getCurrentlyModalComponent(),"Space triggered FX button instead of Play");
        peer->handleKeyPress(KeyPress(KeyPress::spaceKey));require(session.transport().playing,"Held Space toggled playback");
        peer->handleKeyUpOrDown(false);peer->handleKeyPress(KeyPress(KeyPress::spaceKey));
        require(!session.transport().playing,"Space release did not rearm Stop");peer->handleKeyUpOrDown(false);
        session.renameTrack(id,"Renamed");
        peer->handleKeyPress(KeyPress('Z',ModifierKeys::ctrlModifier,0));peer->handleKeyUpOrDown(false);
        require(session.song()->tracks[0].name!="Renamed","FX did not route Ctrl+Z");
        peer->handleKeyPress(KeyPress('Z',ModifierKeys::ctrlModifier|ModifierKeys::shiftModifier,0));peer->handleKeyUpOrDown(false);
        require(session.song()->tracks[0].name=="Renamed","FX did not route Ctrl+Shift+Z");
        TextEditor editor;window->getContentComponent()->addAndMakeVisible(editor);editor.setBounds(300,100,200,25);editor.grabKeyboardFocus();pump();
        peer->handleKeyPress(KeyPress(KeyPress::spaceKey,ModifierKeys(),L' '));
        require(editor.getText()==" " && !session.transport().playing,"Typing a space triggered transport");
        require(!FloatingShortcuts::allows(KeyPress(KeyPress::deleteKey)),"FX Delete leaked into timeline");
        window->setVisible(false);
    });
    test("Advanced and Settings stay nonmodal, reuse their windows and release shortcut learning", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(fixture()));session.audio.setOffline(true);
        const auto preferences=directory.getNonexistentChildFile("floating-preferences",".json");
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,preferences);w.setSize(1366,768);
        const auto track=session.song()->tracks[0].id;
        auto windows=[&](const String &tab) {
            std::vector<DocumentWindow *> result;
            auto &desktop=Desktop::getInstance();
            for(int i=0;i<desktop.getNumComponents();++i)
                if(auto *window=dynamic_cast<DocumentWindow *>(desktop.getComponent(i)))
                    if(window->isVisible()&&uiFeatureTests::find(*window,tab))result.push_back(window);
            return result;
        };
        auto single=[&](const String &tab) {
            const auto found=windows(tab);require(found.size()==1,"Preference window missing or duplicated");
            require(found[0]->getPeer()&&!found[0]->isCurrentlyModal()&&
                    !Component::getCurrentlyModalComponent()&&!w.isCurrentlyBlockedByAnotherModalComponent(),
                    "Preference window entered modal state or blocked the workspace");
            return found[0];
        };
        std::function<Component *(Component &,const std::function<bool(Component &)> &)> matching;
        matching=[&](Component &root,const std::function<bool(Component &)> &predicate)->Component * {
            if(predicate(root))return &root;
            for(auto *child:root.getChildren())if(auto *found=matching(*child,predicate))return found;
            return nullptr;
        };
        auto button=[&](Component &root,const String &title) {
            auto *found=dynamic_cast<Button *>(matching(root,[&](Component &component) {
                if(auto *value=dynamic_cast<TextButton *>(&component))return value->getButtonText()==title;
                return false;
            }));
            require(found&&bool(found->onClick),"Preference action button missing");return found;
        };
        auto tempo=[&](Component &root) {
            auto *found=dynamic_cast<TextEditor *>(matching(root,[](Component &component) {
                return dynamic_cast<TextEditor *>(&component)&&component.getName()=="BPM";
            }));
            require(found,"Advanced BPM editor missing");return found;
        };
        auto editTrack=[&](double value) {
            auto *row=uiFeatureTests::find(w,"trackRow:"+text(track));require(row,"Preference test track row missing");
            auto *fader=dynamic_cast<Slider *>(uiFeatureTests::find(*row,"trackVolume"));
            require(fader&&fader->isEnabled()&&!fader->isCurrentlyBlockedByAnotherModalComponent(),
                    "Floating preferences blocked the track fader");
            fader->setValue(value,sendNotificationSync);
            require(std::abs(session.song()->tracks[0].volume-value)<.001,
                    "Track volume did not change with preferences open");
        };
        auto clickTab=[&](DocumentWindow &window,int index) {
            auto *tab=dynamic_cast<Button *>(uiFeatureTests::find(window,"settingsTab"+String(index)));
            require(tab&&bool(tab->onClick),"Settings tab missing");tab->onClick();pump();
        };
        auto selected=[&](DocumentWindow &window,int index) {
            auto *tab=dynamic_cast<Button *>(uiFeatureTests::find(window,"settingsTab"+String(index)));
            return tab&&tab->getToggleState();
        };
        w.openAdvanced();pump();
        Component::SafePointer<DocumentWindow> advanced(single("advancedTab0"));
        const auto before=session.song()->bpm;tempo(*advanced)->setText("137",false);
        w.openAdvanced();pump();
        require(single("advancedTab0")==advanced.getComponent()&&tempo(*advanced)->getText()=="137",
                "Reopening Advanced replaced the window or discarded its draft");
        editTrack(.37);
        button(*advanced,"Cancelar")->onClick();
        require(!advanced||!advanced->isVisible(),"Advanced Cancel did not close its floating window");
        pump();require(session.song()->bpm==before,"Advanced Cancel applied the draft tempo");
        w.openAdvanced();pump();advanced=single("advancedTab0");
        tempo(*advanced)->setText("137",false);button(*advanced,"Aplicar")->onClick();
        require((!advanced||!advanced->isVisible())&&session.song()->bpm==137,
                "Advanced Apply did not commit and close");pump();

        w.openSettings();pump();
        Component::SafePointer<DocumentWindow> settings(single("settingsTab0"));
        require(selected(*settings,0),"Settings did not open General");
        clickTab(*settings,2);w.openSettings();pump();
        require(single("settingsTab0")==settings.getComponent()&&selected(*settings,2),
                "Reopening Settings duplicated the window or changed its page");
        w.openAudioSettings();pump();
        require(single("settingsTab0")==settings.getComponent()&&selected(*settings,1),
                "Audio settings shortcut did not reuse Settings on its Audio page");
        w.openAdvanced();pump();advanced=single("advancedTab0");single("settingsTab0");
        editTrack(.61);advanced->closeButtonPressed();pump();
        clickTab(*settings,3);
        auto learningButton=[&] {
            return dynamic_cast<Button *>(matching(*settings,[](Component &component) {
                if(auto *value=dynamic_cast<Button *>(&component))return value->getTooltip()=="Fadeout keyboard";
                return false;
            }));
        };
        auto *learn=learningButton();require(learn&&bool(learn->onClick),"Settings shortcut learning control missing");
        learn->onClick();pump();learn=learningButton();
        require(learn&&learn->getName()==String::fromUTF8("Aguardando controle…"),
                "Settings shortcut learning did not start");
        settings->closeButtonPressed();
        require(!settings||!settings->isVisible(),"Settings close did not hide the floating window");
        // Test before deferred window destruction: hiding must immediately stop
        // learning so the next workspace key cannot become an accidental binding.
        w.keyPressed(KeyPress(KeyPress::F9Key));w.keyStateChanged(false);
        Appearance saved(preferences);
        require(str(get(saved.value("catlive.actions",object()),"transportFadeout"),"keyboard").isEmpty(),
                "Closing Settings left shortcut learning active");
        pump();w.openSettings();pump();settings=single("settingsTab0");
        require(selected(*settings,0),"Closed Settings retained stale page/learning state");
        settings->closeButtonPressed();pump();
        require(!Component::getCurrentlyModalComponent()&&windows("settingsTab0").empty()&&windows("advancedTab0").empty(),
                "Closing preferences left a modal mask or visible window");
    });
    test("Live tuner changes audible pitch without moving transport and restores with Undo", [&] {
        const auto folder=directory.getNonexistentChildFile("live-tuner","");folder.createDirectory();
        WavAudioFormat format;auto stream=folder.getChildFile("tone.wav").createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(),48000,2,24,{},0));require(bool(writer),"Cannot create tuner fixture");stream.release();
        AudioBuffer<float> tone(2,48000*4);
        for(int i=0;i<tone.getNumSamples();++i)for(int ch=0;ch<2;++ch)tone.setSample(ch,i,.2f*std::sin(float(i)*2*MathConstants<float>::pi*440/48000));
        require(writer->writeFromAudioSampleBuffer(tone,0,tone.getNumSamples()),"Cannot write tuner fixture");writer.reset();
        auto p=fixture();p.songs[0].tracks.resize(1);auto &t=p.songs[0].tracks[0];
        jaras::AudioClip clip;clip.id=uuid();clip.duration=4;clip.audioFile=jaras::AudioFile{"tone.wav",{}};t.clips={clip};
        Session session;session.inspection=true;session.mediaDirectory=folder;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(p));session.audio.setOffline(true);
        session.command(jaras::CommandKind::play);
        AudioBuffer<float> block(2,480);session.audio.render(block.getArrayOfWritePointers(),2,480);
        const auto cursor=session.audio.state().position;
        session.setMeter(7,8);
        require(session.song()->beatsPerBar==7 && session.song()->beatUnit==8 && session.audio.state().playing && session.audio.state().position==cursor,
                "Live meter edit failed or moved transport");
        session.setRegionPitch(p.songs[0].parts[0].id,12,{t.id},{});
        require(session.audio.state().playing && session.audio.state().position==cursor,"Tuner stopped or moved audio");
        int crossings=0;float previous=0;
        for(int n=0;n<30;++n){session.audio.render(block.getArrayOfWritePointers(),2,480);for(int i=0;i<480;++i){const auto value=block.getSample(0,i);if(n>=10 && previous<=0 && value>0)++crossings;previous=value;}}
        require(std::abs(crossings-176)<5,"Live audio did not transpose from 440 to 880 Hz");
        session.command(jaras::CommandKind::stopAll);session.undo();
        require(session.song()->parts[0].pitchSemitones.value_or(0)==0,"Tuner Undo did not restore pitch");
        session.undo();require(session.song()->beatsPerBar==4 && session.song()->beatUnit==4,"Meter Undo did not restore 4/4");
    });
}
}
