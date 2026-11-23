#pragma once
#include "CloseProjectSheet.h"
#include "TimelineRegionLabels.h"
#include "DesktopToolbarSymbols.h"
#include "FooterAudioStatusButton.h"
#include "Workspace.h"
#include "PatchPanel.h"
#include "ModalSheet.h"
#include "MIDIItemExport.h"
#include "FloatingControlTests.h"
#include "ProjectDeletionPanel.h"
#include "ProjectOpenConfirmationPanel.h"
#include "SetlistRows.h"
#include "ExportPanel.h"
#include "WaveformRasterIdentity.h"
namespace catlive {
struct WorkspaceLayoutTests {
    static void ctrlClearMixerButtons(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();auto &tracks=project.songs.front().tracks;
        while(tracks.size()<200){auto track=tracks.front();track.id=uuid();tracks.push_back(track);}
        tracks[2].parentTrackID=tracks[1].id;
        tracks[3].role.id="generatedClick";tracks[3].name="Click";
        const ID first=tracks[0].id,second=tracks[1].id;
        std::set<ID> all;for(const auto &track:tracks)all.insert(track.id);
        project.masterMute=true;project.masterSolo=true;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("ctrl-clear-mixer",".json"));
        w.setSize(1366,900);w.projectOpened(false);w.footerMixerVisible=true;w.resized();w.footerMixer->refresh();
        w.selectMixerTrack(first,{},true,false);
        w.selectMixerTrack(second,ModifierKeys(ModifierKeys::ctrlModifier),true,false);
        const auto selected=w.selectedTracks;
        auto *retainedRow=uiFeatureTests::find(w,"trackRow:"+text(first));
        require(retainedRow,"Track Mixer row is missing");
        auto active=[&](const ID &id,bool mute) {
            const auto &current=session.song()->tracks;
            const auto at=std::find_if(current.begin(),current.end(),[&](const auto &track){return track.id==id;});
            require(at!=current.end(),"Expected mixer track is missing");
            return mute?at->mute:at->solo;
        };
        auto check=[&](Component &row,bool horizontal) {
            for(auto kind:{jaras::CommandKind::mute,jaras::CommandKind::solo}) {
                const bool mute=kind==jaras::CommandKind::mute;
                auto *button=dynamic_cast<QuietButton *>(uiFeatureTests::find(row,
                    horizontal ? (mute?"mixerMute":"mixerSolo") : (mute?"trackMute":"trackSolo")));
                require(button && button->isVisible(),"Mixer M/S button is missing");
                session.mixerCommand(kind,second,all);
                session.mixerCommand(kind,first,{first}); // Ctrl-click an inactive button, with other tracks active.
                require(!active(first,mute),"Clicked track must start inactive");
                const auto revision=session.revision;
                const auto point=button->getLocalBounds().toFloat().getCentre();const auto now=Time::getCurrentTime();
                MouseEvent down(Desktop::getInstance().getMainMouseSource(),point,
                    ModifierKeys(ModifierKeys::ctrlModifier|ModifierKeys::leftButtonModifier),1,0,0,0,0,button,button,now,point,now,1,false);
                button->mouseDown(down);
                // Releasing Ctrl before the mouse must not trigger the normal toggle on mouse-up.
                MouseEvent up(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(),1,0,0,0,0,button,button,now,point,now,1,false);
                button->mouseUp(up);
                for(const auto &track:session.song()->tracks)
                    require(!(mute?track.mute:track.solo),"Ctrl-click left M/S active on an unselected, grouped or offscreen track");
                require(session.revision==revision+1,"Ctrl-click toggled twice or published multiple mixer updates");
                require(session.project().masterMute && session.project().masterSolo,"Ctrl-click changed the Master");
                require(w.selectedTracks==selected && uiFeatureTests::find(w,"trackRow:"+text(first))==retainedRow,
                        "Ctrl-click changed selection or rebuilt retained controls");
                require(button->modifiedClick && !button->modifiedClick(ModifierKeys()),"An ordinary click was consumed by Ctrl-click handling");
                button->onClick();
                require(active(first,mute) && active(second,mute) &&
                        !(mute?session.song()->tracks.back().mute:session.song()->tracks.back().solo),
                        "Ordinary M/S no longer follows the selected tracks");
                button->onClick();
            }
        };
        check(*retainedRow,false);
        auto *strip=uiFeatureTests::find(*w.footerMixer,"mixerStrip:"+text(first));
        require(strip,"Docked Hoz-Mixer strip is missing");check(*strip,true);
        auto *trackI = dynamic_cast<Button *>(uiFeatureTests::find(*retainedRow, "trackInputMonitor"));
        auto *hozI = dynamic_cast<Button *>(uiFeatureTests::find(*strip, "mixerInputMonitor"));
        require(trackI && hozI && !session.recordingArmed(first), "Unarmed monitor fixture missing");
        trackI->onClick();
        require(trackI->getToggleState() && hozI->getToggleState() && !session.recordingArmed(first),
                "Both monitor buttons must light immediately with REC off");
        hozI->onClick();
        require(!trackI->getToggleState() && !hozI->getToggleState(), "Both monitor buttons must turn off together");
        w.showDetachedMixer();
        auto *floating=dynamic_cast<MixerPanel *>(w.floatingWindows.at("Mixer")->getContentComponent());
        require(floating,"Detached Hoz-Mixer is missing");
        strip=uiFeatureTests::find(*floating,"mixerStrip:"+text(first));
        require(strip,"Detached Hoz-Mixer strip is missing");check(*strip,true);
        auto *master=uiFeatureTests::find(*floating,"mixerMaster");
        require(master,"Detached Master is missing");
        for(const auto *id:{"mixerMute","mixerSolo"}) {
            auto *button=dynamic_cast<QuietButton *>(uiFeatureTests::find(*master,id));
            require(button && !button->modifiedClick(ModifierKeys(ModifierKeys::ctrlModifier)),"Master Ctrl-click must retain the ordinary Master action");
        }
    }
    static void duplicateTrackFollow(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();auto &tracks=project.songs.front().tracks;
        while(tracks.size()<900){auto track=tracks.front();track.id=uuid();tracks.push_back(track);}
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("duplicate-follow",".json"));
        w.setSize(1366,900);w.projectOpened(false);w.footerMixerVisible=true;w.resized();w.footerMixer->refresh();
        const ID retainedID=tracks.front().id;
        auto *retainedRow=uiFeatureTests::find(w,"trackRow:"+text(retainedID));
        auto *retainedStrip=uiFeatureTests::find(*w.footerMixer,"mixerStrip:"+text(retainedID));
        require(retainedRow && retainedStrip,"Initial mixer controls are missing");
        auto *hozViewport=dynamic_cast<Viewport*>(uiFeatureTests::find(*w.footerMixer,"mixerTracksViewport"));
        require(hozViewport,"Hoz Mixer viewport missing");
        w.selectMixerTrack(tracks[898].id,{},true,false);
        auto *farStrip=uiFeatureTests::find(*w.footerMixer,"mixerStrip:"+text(tracks[898].id));
        require(farStrip && hozViewport->getViewArea().contains(farStrip->getBounds()),"Track Mixer click did not reveal the Hoz strip");
        w.selectMixerTrack(retainedID,{},true,true);
        require(w.tracksViewport.getViewArea().contains(retainedRow->getBounds()),"Hoz click did not reveal the Track Mixer row");
        const auto visibleOrigin=w.tracksViewport.getViewPosition();
        w.selectMixerTrack(retainedID,{},true,true);
        require(w.tracksViewport.getViewPosition()==visibleOrigin,"Reselecting a visible row moved the Track Mixer");
        w.selectMixerTrack(tracks[898].id,{},true,false);
        w.selectMixerTrack(tracks[899].id,ModifierKeys(ModifierKeys::ctrlModifier),true,false);
        w.copyGridItems(false);
        for(int repeat=0;repeat<3;++repeat) {
            std::set<ID> before;for(const auto &track:session.song()->tracks)before.insert(track.id);
            w.pasteGridItems();
            const auto *song=session.song();require(song && song->tracks.size()==size_t(902+repeat*2),"Repeated paste lost its original multi-track clipboard");
            const auto created=std::find_if(song->tracks.rbegin(),song->tracks.rend(),[&](const auto &track){return !before.count(track.id);});
            require(created!=song->tracks.rend(),"Paste did not create a new identity");const ID last=created->id;
            require(song->tracks.back().id==last,"Repeated Paste inserted before the previous copies instead of progressing downwards");
            require(w.selectedTracks==std::set<ID>{last} && w.selectedTrack==last && w.trackSelectionAnchor==last,
                    "The last created track must be the sole selection and the next range anchor");
            auto *row=uiFeatureTests::find(w,"trackRow:"+text(last));
            require(row && w.tracksViewport.getViewArea().contains(row->getBounds()),"Track Mixer did not reveal the complete new row immediately");
            auto *viewport=dynamic_cast<Viewport*>(uiFeatureTests::find(*w.footerMixer,"mixerTracksViewport"));
            auto *strip=uiFeatureTests::find(*w.footerMixer,"mixerStrip:"+text(last));
            require(viewport && strip && viewport->getViewArea().contains(strip->getBounds()),"Hoz-Mixer waited for a timer to reveal the new strip");
            require(uiFeatureTests::find(w,"trackRow:"+text(retainedID))==retainedRow &&
                    uiFeatureTests::find(*w.footerMixer,"mixerStrip:"+text(retainedID))==retainedStrip,
                    "Pasting rebuilt existing mixer controls");
        }
    }
    static void exportMixerSelection(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("export-mixer-selection",".json"));
        w.setSize(1366,900); w.projectOpened(false);
        const auto &song=*session.song();
        const ID first=song.tracks[0].id, second=song.tracks[1].id, third=song.tracks[2].id;
        const ModifierKeys toggle(ModifierKeys::ctrlModifier);
        w.selectMixerTrack(first,{},true,false);
        w.selectMixerTrack(second,toggle,true,false);
        w.chooseExport();
        require(Component::getCurrentlyModalComponent()==nullptr,"Export still blocks mixer interaction");
        auto &window=*w.floatingWindows.at("Exportar");
        auto *panel=dynamic_cast<ExportPanel *>(window.getContentComponent());
        require(panel,"Export window missing");
        auto *source=dynamic_cast<ComboBox *>(uiFeatureTests::find(*panel,"exportSource"));
        require(source,"Export source control missing");
        source->setSelectedId(2,sendNotificationSync);
        auto checked=[&](const ID &id) {
            auto *button=dynamic_cast<ToggleButton *>(uiFeatureTests::find(*panel,"exportTrack:"+text(id)));
            require(button && button->isShowing(),"Export track checkbox missing");
            return button->getToggleState();
        };
        require(checked(first)&&checked(second)&&!checked(third),"Opening export lost part of mixer selection");
        w.selectMixerTrack(first,toggle,true,false);
        require(!checked(first)&&checked(second),"Track Mixer deselection did not reach export");
        w.selectMixerTrack(third,toggle,true,true);
        require(checked(second)&&checked(third),"Hoz Mixer selection did not reach export");
        w.selectMixerTrack(second,toggle,true,true);
        w.selectMixerTrack(third,toggle,true,true);
        require(!checked(first)&&!checked(second)&&!checked(third),"Empty mixer selection did not clear export");
        require((int)get(panel->diagnostics(),"jobs")==0,"Empty track selection exports unselected tracks");
        auto *manual=dynamic_cast<ToggleButton *>(uiFeatureTests::find(*panel,"exportTrack:"+text(first)));
        manual->setToggleState(true,dontSendNotification); manual->onClick();
        w.updateState();
        require(checked(first),"Unchanged workspace refresh erased manual export selection");
        w.selectMixerTrack(second,{},true,false);
        require(!checked(first)&&checked(second),"Changed mixer selection did not replace manual selection");
        window.closeButtonPressed();
        w.selectMixerTrack(third,toggle,true,true);
        w.chooseExport();
        panel=dynamic_cast<ExportPanel *>(w.floatingWindows.at("Exportar")->getContentComponent());
        require(panel && checked(second)&&checked(third),"Reopening export restored stale mixer selection");
    }
    static void splitSelection(const File &directory) {
        using floatingControlTests::require;
        for (int selectedCount : {0, 1, 2}) {
            Session session; session.inspection=true; session.audio.prepareOffline(48000);
            auto project=floatingControlTests::fixture();
            auto &song=project.songs.front(); song.tracks.clear(); song.parts.clear(); song.markers.reset(); song.duration=20;
            std::set<ID> originals;
            for(int i=0;i<2;++i) {
                jaras::Track track; track.id=uuid(); track.name="Track";
                jaras::AudioClip item; item.id=uuid(); item.name="Item"; item.startTime=0; item.duration=10;
                originals.insert(item.id); track.clips={item}; song.tracks.push_back(track);
            }
            project.savedCursor=jaras::SavedProjectCursor{song.id,5};
            session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
            Auth auth; Lighting lighting(session);
            Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("split-selection",".json"));
            w.projectOpened(false); session.command(jaras::CommandKind::editSeek,{},5);
            w.selectedClips.clear(); w.selectedClip.clear();
            for(int i=0;i<selectedCount;++i)w.selectedClips.insert(session.song()->tracks[(size_t)i].clips[0].id);
            if(!w.selectedClips.empty())w.selectedClip=*w.selectedClips.begin();
            w.performAction("splitItems",1,-1);
            require(w.selectedClips.size()==(size_t)(selectedCount==0?2:selectedCount),"Split did not select all new right halves");
            require(w.selectedClips.count(w.selectedClip)!=0,"Split anchor did not follow the right selection");
            for(const auto &track:session.song()->tracks)for(const auto &item:track.clips)if(w.selectedClips.count(item.id))
                require(item.startTime==5 && item.duration==5 && !originals.count(item.id),"Split retained a left half in the selection");
            const auto selected=w.selectedClips;
            w.performAction("splitItems",1,-1);
            require(w.selectedClips==selected,"S at an existing edge changed selection");
        }
    }
    static void fullscreenTransport(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("fullscreen-layout",".json"));
        Component tabs; tabs.addAndMakeVisible(w);
        DocumentWindow host("Fullscreen layout",theme::background,0);
        host.setUsingNativeTitleBar(false); host.setTitleBarHeight(0);
        host.setContentNonOwned(&tabs,false); host.setBounds(40,40,1440,850); host.setVisible(true); w.projectOpened(false);
        const auto hwnd=static_cast<HWND>(host.getPeer()->getNativeHandle());
        auto nativeRects=[&] {
            std::map<HWND,RECT> result;
            for(auto child=GetWindow(hwnd,GW_CHILD);child;child=GetWindow(child,GW_HWNDNEXT)) {
                wchar_t name[64]{}; GetClassNameW(child,name,64);
                if(std::wstring(name)!=L"CatLiveTransportButton") continue;
                RECT rect{}; GetWindowRect(child,&rect); result.emplace(child,rect);
            }
            return result;
        };
        std::vector<Component*> transport{&w.masterVolume,&w.songDisplay,
            &w.transportTime,w.tempoControl.get(),w.tuner.get()};
        for(auto id:{"masterMono","masterMute",
            "previousProjectTab","nextProjectTab",
            "play","pause","loop","record","metronome","save","setlist"}) transport.push_back(w.controls[id]);
        for(int width:{800,1000,1440,1920}) for(int tabInset:{0,24}) {
            host.setSize(width,850); w.workspaceFullscreen=false;
            w.setBounds(0,tabInset,tabs.getWidth(),tabs.getHeight()-tabInset); w.resized();
            require(w.controls["masterMono"]->isVisible() && w.controls["masterMute"]->isVisible() &&
                    w.controls["masterPatch"]->isVisible() && w.controls["masterFX"]->isVisible() &&
                    w.controls["masterSolo"]->isVisible() && w.masterPan.isVisible(),
                    "Main must show channel mode, Patch, FX, Pan, Mute and Solo");
            require(w.masterVolume.getRight() <= w.transportDisplayBounds.getX(),
                    "The Main must stay at the left of the top transport");
            if (width >= 1440) {
                const auto *remote = w.controls.at("remote"), *audio = w.controls.at("audioStatus");
                require(remote->getRight() <= audio->getX() && audio->getX() - remote->getRight() <= 4 &&
                        audio->getWidth() == FooterAudioStatusButton::widthForStatus(w.toolbarAudioFormat),
                        "Remote and the audio format must sit together at the right edge");
            }
            const auto normalPanel=w.transportBounds, normalGrid=w.workspaceBounds;
            for (auto id : {"proPlay", "proPause", "proRepeat", "proRecord", "metronome"})
                require(w.transportDisplayBounds.contains(w.controls[id]->getBounds()), "Playback must stay inside the transport display");
            require(w.controls["proPlay"]->isVisible() && w.controls["proPlay"]->getButtonText().isEmpty() &&
                    w.controls.count("proMode") == 0 && w.controls.count("subplay") == 0, "Desktop must open directly in Pro");
            const auto modeBounds = w.controls["metronomeMode"]->getBounds();
            const auto metronomeBounds = w.controls["metronome"]->getBounds();
            require(modeBounds.getRight() + 6 == metronomeBounds.getX() &&
                    metronomeBounds.getRight() + 6 == w.tempoDisplayBounds.getX() &&
                    modeBounds.getWidth() == w.controls["save"]->getWidth() &&
                    metronomeBounds.getWidth() == modeBounds.getWidth() &&
                    modeBounds.getY() == w.tempoDisplayBounds.getY() &&
                    metronomeBounds.getY() == modeBounds.getY() &&
                    modeBounds.getHeight() == w.tempoDisplayBounds.getHeight() &&
                    metronomeBounds.getHeight() == modeBounds.getHeight(),
                    "Mode and metronome must be standard buttons to the left of the BPM panel");
            require(w.tuner->getX() > w.tempoDisplayBounds.getRight() && w.songDisplay.getY() < w.tempoControl->getY(),
                    "Tuner must sit to the right of BPM beneath the centered song title");
            require(w.tuner->getY() == w.tempoDisplayBounds.getY() &&
                    w.tuner->getHeight() == w.tempoDisplayBounds.getHeight(), "BPM and Tuner must share their top and height");
            const int playbackBottom = w.controls["proPlay"]->getBottom();
            for (auto id : {"proFadeout", "proPause", "proRepeat", "proRecord", "save", "setlist"})
                require(w.controls[id]->getBottom() == playbackBottom, "Transport buttons must align at the bottom");
            require(w.timelineSnap.isVisible() && w.timelineTimebase.isVisible() &&
                    w.controls["editMode"]->isVisible() && w.controls["track-envelopes"]->isVisible(),
                    "Desktop must show the Pro editing and timeline switch controls");
            require(w.footerSongBounds.contains(w.transportInfo.getBounds()) &&
                    w.transportInfo.getJustificationType() == Justification::centred,
                    "Notices should stay centered in the footer");
            if (width == 1920)
                require(playbackBottom == w.tuner->getBottom(), "Playback must align with BPM and Tuner");
            require(w.controls.count("export") == 0 &&
                    w.controls["save"]->getRight() < w.controls["setlist"]->getX() &&
                    w.controls["save"]->getY() == w.controls["setlist"]->getY(), "Save must sit to the left of Setlist");
            std::vector<juce::Rectangle<int>> normal;
            for(auto *c:transport) normal.push_back(c->getBounds());
            const auto beforeNative=nativeRects(); require(beforeNative.size()==8,"Native controls missing");
            const auto beforeMaster=w.createComponentSnapshot({4,normalPanel.getY()+4,222,80});
            for(int repeat=0;repeat<3;++repeat) {
                w.workspaceFullscreen=true; w.resized();
                require(w.transportBounds.getY()==normalPanel.getY()-32 && w.workspaceBounds.getY()==normalGrid.getY()-32,
                        "Fullscreen retained caption space above the grid/transport");
                require(!w.windowCaption().isVisible(),"Fullscreen still shows workspace caption");
                for(size_t i=0;i<transport.size();++i) {
                    require(transport[i]->getBounds()==normal[i].translated(0,-32),"Transport component did not follow hidden caption");
                    require(w.transportBounds.contains(transport[i]->getBounds()),"Transport overlaps toolbar/grid in fullscreen");
                }
                const auto afterNative=nativeRects();
                const int pixelShift=roundToInt(32*host.getPeer()->getPlatformScaleFactor());
                for(const auto &[child,rect]:beforeNative) {
                    auto expected=rect; OffsetRect(&expected,0,-pixelShift);
                    const auto found=afterNative.find(child);
                    require(found!=afterNative.end() && EqualRect(&expected,&found->second),"Native hit area lagged behind fullscreen layout");
                }
                const auto afterMaster=w.createComponentSnapshot({4,w.transportBounds.getY()+4,222,80});
                for(int y=0;y<beforeMaster.getHeight();++y) for(int x=0;x<beforeMaster.getWidth();++x)
                    require(beforeMaster.getPixelAt(x,y)==afterMaster.getPixelAt(x,y),"Master drawing moved relative to its controls");
                w.workspaceFullscreen=false; w.resized();
                for(size_t i=0;i<transport.size();++i)
                    require(transport[i]->getBounds()==normal[i],"Repeated fullscreen toggles accumulate transport offset");
            }
        }
        host.clearContentComponent();
    }
    static void keyboardContextSettings(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        Auth auth; Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("keyboard-context",".json"));
        w.proTransport=false;
        w.setSize(1366,768);
        auto *key=dynamic_cast<QuietButton*>(w.controls.at("railKeyboard"));
        require(key!=nullptr,"Keyboard must handle context clicks");
        const auto visible=w.keyboardVisible;
        const auto now=Time::getCurrentTime();
        const Point<float> point(4.f,4.f);
        MouseEvent down(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys::rightButtonModifier,
                        1,0,0,0,0,key,key,now,point,now,1,false);
        key->mouseDown(down); key->mouseUp(down);
        auto *sheet=uiFeatureTests::find(w,"modalSheet");
        require(sheet && w.keyboardVisible==visible,"Keyboard right click opens settings without toggling the keyboard");
        require(uiFeatureTests::find(*sheet,"jaras.keyboard.whiteColor") && uiFeatureTests::find(*sheet,"jaras.keyboard.blackColor"),
                "Both key highlight colours must be editable");
        auto *style=dynamic_cast<ComboBox*>(uiFeatureTests::find(*sheet,"jaras.keyboard.style"));
        auto *channel=dynamic_cast<ComboBox*>(uiFeatureTests::find(*sheet,"jaras.keyboard.channel"));
        require(style && channel && channel->getNumItems()==17,"Keyboard style and Omni plus sixteen MIDI channels must be available");
        style->setSelectedId(2,sendNotificationSync); channel->setSelectedId(5,sendNotificationSync);
        require(w.appearance.value("jaras.keyboard.style").toString()=="black" && int(w.appearance.value("jaras.keyboard.channel"))==4,
                "Keyboard settings must write the preferences used by Advanced and the live keyboard");
        sheet->exitModalState(0);
    }

    static void transportHitBounds(const File &directory) {
        using floatingControlTests::require;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("transport-bounds",".json"));
        DocumentWindow host("Transport",theme::background,0);host.setContentNonOwned(&w,false);host.setBounds(50,50,1400,800);host.setVisible(true);w.projectOpened(false);
        w.syncNativeTransport();
        const auto parent=static_cast<HWND>(host.getPeer()->getNativeHandle());
        std::vector<std::pair<HWND,RECT>> original;
        std::vector<HWND> simplePlayback;
        const auto peer=host.getPeer();
        const auto peerFrame=peer->getBounds();
        const auto componentFrame=peer->getComponent().getLocalBounds();
        const auto scale=AffineTransform::scale(
            (float)peer->getPlatformScaleFactor()*peerFrame.getWidth()/std::max(1,componentFrame.getWidth()),
            (float)peer->getPlatformScaleFactor()*peerFrame.getHeight()/std::max(1,componentFrame.getHeight()));
        for(auto child=GetWindow(parent,GW_CHILD);child;child=GetWindow(child,GW_HWNDNEXT)) {
            wchar_t name[64]{};GetClassNameW(child,name,64);
            if(std::wstring(name)!=L"CatLiveTransportButton")continue;
            RECT rect{};GetWindowRect(child,&rect);MapWindowPoints(HWND_DESKTOP,parent,reinterpret_cast<POINT*>(&rect),2);
            original.emplace_back(child,rect);
            for (auto id : {"play","fadeout","pause","loop","record"}) {
                const auto area=peer->getComponent().getLocalArea(&w,w.controls.at(id)->getBounds()).toFloat()
                    .transformedBy(scale).getSmallestIntegerContainer();
                const RECT expected{area.getX(),area.getY(),area.getRight(),area.getBottom()};
                if (EqualRect(&rect,&expected)) simplePlayback.push_back(child);
            }
            SetWindowPos(child,nullptr,rect.left+43,rect.top+9,rect.right-rect.left+7,rect.bottom-rect.top,SWP_NOACTIVATE|SWP_NOZORDER);
        }
        require(original.size()==8,"Native transport buttons are missing");
        w.syncNativeTransport();
        for(const auto &[child,expected]:original) {
            RECT rect{};GetWindowRect(child,&rect);MapWindowPoints(HWND_DESKTOP,parent,reinterpret_cast<POINT*>(&rect),2);
            require(EqualRect(&rect,&expected)!=FALSE,"Input bounds stayed displaced despite unchanged transport state");
        }
        w.proTransport=true;
        w.resized();
        require(simplePlayback.size()==5,"Missing native Simple Mode playback inputs");
        for (auto child : simplePlayback)
            require((GetWindowLongPtrW(child,GWL_STYLE)&WS_VISIBLE)==0,"A native Simple Mode playback button covers Pro Mode");
        w.proTransport=false;
        w.resized();
        for(auto child : simplePlayback)
            require((GetWindowLongPtrW(child,GWL_STYLE)&WS_VISIBLE)!=0,"Simple Mode did not restore native buttons");
        host.clearContentComponent();
    }
    static void performanceDockPositions(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth; Lighting lighting(session); Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("performance-docks",".json"));
        w.setSize(1600,1050); w.projectOpened(false);
        w.libraryVisible=true; w.focusVisible=true; w.setlistVisible=true; w.footerMixerVisible=true; w.vinhetasVisible=true;
        w.resized();
        const auto bounds = [&](const Component &c) { return w.getLocalArea(&c,c.getLocalBounds()); };
        auto mixer=bounds(*w.footerMixer), pads=bounds(*w.vinhetasPanel);
        const auto *library = w.findChildWithID("workspace-library-panel");
        require(library && library->isVisible(),"Library must be visible");
        require(mixer.getX()>=w.focusMixer->getRight() && w.focusMixer->getX()>=library->getRight(),"Hoz Mixer covers an inspector");
        require(pads.getY()==w.focusMixer->getBottom() && pads.getX()==library->getX(),"Pads must sit below both inspectors");
        require(mixer.getRight()==pads.getRight() && pads.getRight()<w.getWidth(),"Docked panels overlap Setlist");
        w.controls["midiPreview"]->onClick();
        require(w.midiPreviewVisible && !w.vinhetasVisible,"Opening MIDI Preview closes Pads");
        w.controls["railKeyboard"]->onClick();
        require(w.keyboardVisible && w.midiPreviewVisible,"Keyboard and MIDI Preview can stay open together");
        w.controls["railVinhetas"]->onClick();
        require(w.vinhetasVisible && !w.keyboardVisible && !w.midiPreviewVisible,"Opening Pads closes Keyboard and MIDI Preview");
        w.controls["railKeyboard"]->onClick();
        require(w.keyboardVisible && !w.vinhetasVisible,"Opening Keyboard closes Pads");
        w.controls["midiPreview"]->onClick();
        const auto initialHeight = w.midiPreviewPanel->getHeight();
        w.midiPreviewDivider.started(); w.midiPreviewDivider.moved(-30);
        require(w.midiPreviewPanel->getHeight() == initialHeight + 30, "Preview divider moves its panel by the drag distance");
        const auto preview=bounds(*w.midiPreviewPanel);
        auto *horizontal = dynamic_cast<ScrollBar*>(uiFeatureTests::find(*w.midiPreviewPanel,"midiPreviewHorizontalScroll"));
        auto *vertical = dynamic_cast<ScrollBar*>(uiFeatureTests::find(*w.midiPreviewPanel,"midiPreviewVerticalScroll"));
        require(horizontal && vertical && horizontal->getWidth() > horizontal->getHeight() &&
                vertical->getHeight() > vertical->getWidth() &&
                vertical->getCurrentRange().getLength() < 128,"MIDI Preview must expose both scroll bars");
        vertical->setCurrentRangeStart(0,sendNotificationSync);
        require(vertical->getCurrentRangeStart() == 0,"MIDI Preview pitch scrolling must move to the requested octave");
        const auto divider = bounds(w.midiPreviewDivider), currentMixer = bounds(*w.footerMixer);
        require(preview.getX() == w.focusMixer->getRight() && preview.getRight() == currentMixer.getRight() &&
                w.focusMixer->getBottom() == preview.getBottom() && library->getBottom() == preview.getBottom(),
                "MIDI Preview must stay to the right of Library and Track - I until its bottom edge");
        require(divider.getX() == preview.getX() && divider.getWidth() == preview.getWidth() &&
                divider.getBottom() == preview.getY() && bounds(*w.keyboard).getY() == preview.getBottom(),
                "The handle must span the preview column, with Keyboard below it");
        w.setSize(1366,768);
        const auto fixedPads=bounds(*w.vinhetasPanel);
        w.keyboardVisible=true; w.resized();
        w.mixerHeightDivider.started();
        w.mixerHeightDivider.moved(-2000);
        require(w.workspaceBounds.getHeight()>=128 &&
                w.footerMixer->getHeight()==w.mixerHeightLimit &&
                w.footerMixer->getHeight()<=w.dockViewport.getHeight() &&
                bounds(*w.vinhetasPanel).getHeight()==fixedPads.getHeight(),
                "Hoz Mixer must stop at the available height below the timeline with Pads and Keyboard open");
        w.setSize(1600,1050);
        const auto clock = session.transport().editPosition;
        const auto now = Time::getCurrentTime();
        auto* piano = uiFeatureTests::find(*w.midiPreviewPanel,"midiPreviewLiveCanvas");
        require(piano && piano->isVisible(),"Live preview canvas is missing");
        const juce::Point<float> canvas{float(piano->getWidth() * .75), float(std::min(12,piano->getHeight()/2))};
        const MouseEvent click(Desktop::getInstance().getMainMouseSource(),canvas,
            ModifierKeys(ModifierKeys::leftButtonModifier),1.f,0.f,0.f,0.f,0.f,
            piano,piano,now,canvas,now,1,false);
        piano->mouseDown(click);
        require(session.transport().editPosition > clock,"Clicking MIDI Preview must move the shared timeline cursor");
        const auto pitch = vertical->getCurrentRangeStart();
        MouseWheelDetails wheel{}; wheel.deltaY = -.3f;
        auto* zoom = dynamic_cast<Slider*>(uiFeatureTests::find(*w.midiPreviewPanel,"piano-time-zoom-slider"));
        require(zoom != nullptr,"MIDI Preview time zoom is missing");
        const auto originalZoom = zoom->getValue();
        const auto scrollEvent = [&](ModifierKeys modifiers) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),canvas,modifiers,0.f,0.f,0.f,0.f,0.f,
                              piano,piano,now,canvas,now,0,false);
        };
        piano->mouseWheelMove(scrollEvent(ModifierKeys{}),wheel);
        require(zoom->getValue() < originalZoom && vertical->getCurrentRangeStart() == pitch,
                "Unmodified vertical scrolling must zoom MIDI Preview");
        const auto currentZoom = zoom->getValue();
        piano->mouseWheelMove(scrollEvent(ModifierKeys(ModifierKeys::altModifier)),wheel);
        require(vertical->getCurrentRangeStart() > pitch && zoom->getValue() == currentZoom,
                "Alt scrolling must move only the MIDI Preview pitch rows");
        for (const int width : {1060, 1600}) {
            w.setSize(width, 1050);
            require(w.controls.count("proMode") == 0 && w.transportProgressBounds().getHeight() == 4,
                    "Desktop must open with the Pro transport and its four-point progress bar");
            const auto compactZoom = w.controls.at("trackHeightFit")->getBounds();
            require(compactZoom.getX() - w.tuner->getRight() == 6 &&
                    w.controls.at("proTool")->getX() - w.zoom.getRight() == 6 &&
                    compactZoom.getY() >= w.tuner->getY(),
                    "Tuner, Zoom and the cursor picker must use equal spacing");
        }
        require(w.songDisplay.isVisible() && w.songDisplay.getBottom() <= w.tempoDisplayBounds.getY() &&
                w.tempoDisplayBounds.getHeight()==35 &&
                w.tempoDisplayBounds.getHeight()==w.tuner->getHeight() &&
                !w.tempoDisplayBounds.intersects(w.proPlaybackBounds),
                "Pro and Simple Mode must use the same BPM and Tuner height");
        require(w.timelineSnap.isVisible() && w.timelineTimebase.isVisible() && w.controls.at("zoomFit")->isVisible() &&
                w.controls.at("editMode")->isVisible() && w.controls.at("track-envelopes")->isVisible() &&
                w.controls.at("proTool")->isVisible() && w.controls.count("proStop")==0 && w.controls.count("proSubplay")==0,
                "Pro Mode must keep the timeline tools and a single Play/Stop control");
        const auto &metronomeMode = *w.controls.at("metronomeMode");
        const auto &metronome = *w.controls.at("metronome");
        require(w.controls.at("track-envelopes")->getX() - w.controls.at("editMode")->getRight() == 6 &&
                w.timelineSnap.getX() - w.controls.at("track-envelopes")->getRight() == 6 &&
                w.timelineTimebase.getX() - w.timelineSnap.getRight() == 6 &&
                metronomeMode.getX() - w.timelineTimebase.getRight() == 6 &&
                metronome.getX() - metronomeMode.getRight() == 6 &&
                w.tempoDisplayBounds.getX() - metronome.getRight() == 6 &&
                metronome.getBottom() == w.tuner->getBottom() &&
                metronomeMode.getHeight() == w.tuner->getHeight() &&
                w.timelineTimebase.getBottom() == w.tuner->getBottom() &&
                w.timelineTimebase.getHeight() == w.tuner->getHeight(),
                "Edit, Envelopes, Snap and Timebase must match the transport button heights and spacing");
        for (const auto *id : {"masterMono", "masterPatch", "masterFX", "masterMute", "masterSolo"})
            require(w.controls.at(id)->isVisible(), "The Main strip must keep all its controls in Pro Mode");
        w.controls.at("proClock")->onClick();
        auto &clockWindow = *w.floatingWindows.at("Clock Position");
        require(clockWindow.isVisible() && clockWindow.isResizable() && w.clockPositionLabel, "Clock Position must be resizable");
        const auto fontHeight = w.clockPositionLabel->getFont().getHeight();
        clockWindow.setSize(clockWindow.getWidth() + 150, clockWindow.getHeight() + 50);
        require(w.clockPositionLabel->getFont().getHeight() > fontHeight, "The clock digits must grow with the window");
        for (const auto *id : {"projectStart","previousTimelinePoint","nextTimelinePoint","projectEnd",
                               "proPlay","proPause","proFadeout","proRecord","proRepeat"}) {
            const auto &button = *w.controls.at(id);
            require(button.isVisible() && button.getButtonText().isEmpty() && w.proPlaybackBounds.contains(button.getBounds()),
                    "Pro playback controls must use icons and remain inside a single group");
            require(button.getHeight()==w.controls.at("save")->getHeight() && button.getWidth() >= 32,
                    "Pro controls must match the Save height and have a wider hit area");
        }
        w.controls.at("proNotes")->onClick();
        auto *proDock = uiFeatureTests::find(w,"pro-library-dock");
        auto *setlistPanel = uiFeatureTests::find(w,"setlistPanel");
        require(proDock && setlistPanel && proDock->isVisible() && proDock->getX() == setlistPanel->getRight(),
                "Pro Notes must dock next to the right of Setlist");
        w.controls.at("proSamplers")->onClick();
        require(w.proDock == Workspace::ProDock::samplers && proDock->isVisible(),
                "Pro Samplers must switch the dock to sample categories");
        w.controls.at("proSamplers")->onClick();
        require(!proDock->isVisible() && w.songDisplay.isVisible() && w.controls.at("proPlay")->isVisible(),
                "Closing the Samplers dock must keep the Pro transport visible");
    }
    static void transportRegionDisplay(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));
        session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("transport-region",".json"));
        w.setSize(1366,768); w.projectOpened(false);
        const auto &part = session.song()->parts.front();
        const auto name = timelineRegionLabels::displayName(part);
        const auto dash = String::fromUTF8("—");
        session.command(jaras::CommandKind::editSeek, {}, part.startTime);
        w.updateState();
        require(get(w.diagnostics(), "currentSongDisplay").toString()==name,"Selected region name missing");
        session.focusSetlistRegion(std::nullopt);
        w.updateState();
        require(get(w.diagnostics(), "currentSongDisplay").toString()==dash,
                "Unselected region under the cursor must leave a dash");
        session.command(jaras::CommandKind::play);
        w.updateState();
        require(get(w.diagnostics(), "currentSongDisplay").toString()==name,"Playing region name missing");
    }
    static void toolbarTimerAndLabels(const File &directory) {
        using floatingControlTests::require;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("toolbar-labels",".json"));
        DocumentWindow host("Workspace",theme::background,0);
        host.setTitleBarHeight(0);host.setResizable(true,false);
        host.setContentNonOwned(&w,true);host.setBounds(50,50,1600,800);host.setVisible(true);w.projectOpened(false);
        for (const auto* symbol : {"line.3.horizontal","books.vertical","sidebar.left","slider.horizontal.3",
            "slider.vertical.3","square.grid.3x3","list.bullet.indent","text.bubble","stopwatch","pianokeys",
            "square.grid.3x2.fill","midiPreview","info.circle","stageLights","projection","teleprompter1",
            "teleprompter2","eye","preview","trackMixer","hozMixer","video","dot.radiowaves.left.and.right","gearshape","addTrack","unlock","lock",
            "magnet","itemTimebase","timelineLanes","arrow.up.and.down.text.horizontal","editCursor","automationLanes",
            "folder.fill","library.instruments","library.plugins","library.samplers","library.presets","note.text","doc.text",
            "rectangle","flag","square.grid.2x2","star.fill","fitTracks","fitTime","trackHeightAxis","timelineZoomAxis",
            "record","loop","play","stopall","pause","fadeout"}) {
            Image off(Image::ARGB, 24, 24, true, SoftwareImageType{}), on(Image::ARGB, 24, 24, true, SoftwareImageType{});
            {
            Graphics gOff(off), gOn(on);
            require(drawControlIcon(gOff,symbol,false,off.getBounds().toFloat(),1.f) &&
                    drawControlIcon(gOn,symbol,true,on.getBounds().toFloat(),1.f),"Missing control artwork");
            }
            int visible = 0, different = 0;
            for (int y = 0; y < 24; ++y) for (int x = 0; x < 24; ++x) {
                const auto left = off.getPixelAt(x,y), right = on.getPixelAt(x,y);
                visible += left.getAlpha() > 64 && right.getAlpha() > 64;
                different += left != right;
            }
            if (visible <= 10 || different <= 10) throw std::runtime_error(std::string("Missing visible PNG states for ") + symbol);
        }
        require(w.timelineBands.getProperties()["icon"].toString() == "timelineLanes"
                && (float)w.timelineBands.getProperties()["iconSize"] == 18.f,
                "Regions and tempo menu must use the shared 18-point icon");
        require(w.timelineBands.findColour(TextButton::buttonColourId) == theme::secondary.withAlpha(.12f)
                && w.timelineBands.findColour(TextButton::buttonOnColourId) == theme::secondary.withAlpha(.12f),
                "Regions and tempo menu must keep the same matte gray background in both states");
        const auto* pause = w.controls.at("pause");
        require(pause->findColour(TextButton::buttonColourId) == Colour(0xff454545)
                && pause->findColour(TextButton::buttonOnColourId) == theme::yellow,
                "Pause must reserve the yellow background for the paused transport");
        const auto minimum = host.getConstrainer()->getMinimumWidth();
        require(minimum > 900 && minimum < 1600,"Native window minimum must follow the toolbar width");
        for (const int width : {minimum, minimum + 12, 1600}) {
            host.setBoundsConstrained(host.getBounds().withWidth(width));
            require(w.controls["railClock"]->isVisible()&&w.controls["railClock"]->getX()>w.controls["railNotice"]->getRight()
                    &&w.controls["railClock"]->getRight()<w.controls["railKeyboard"]->getX(),"Timer is not between Messages and Keyboard");
            require(!w.stageTimer->isVisible(),"Stopped timer should not display a count in the toolbar");
            const auto row = w.controls["menu"]->getY();
            for (auto id : {"advanced", "grandma2", "resolume", "tp1", "tp2", "preview", "video", "remote", "audioStatus", "settings"}) {
                const auto *control = w.controls[id];
                require(control->isVisible() && control->getY() == row && w.getLocalBounds().contains(control->getBounds()),
                        "Toolbar control moved off the first row");
            }
            const int gap = w.controls["tp1"]->getX() - w.controls["resolume"]->getRight();
            require(gap >= 0, "TP1 and Resolume must meet at the minimum width");
            require(w.controls["tp2"]->getProperties()["icon"].toString()=="teleprompter2", "TP2 lost its own symbol");
            if (w.stageTimer->getY() == row)
                require(w.stageTimer->getRight() <= w.controls["tp1"]->getX() &&
                        w.stageTimer->getX() >= w.controls["resolume"]->getRight(), "Timer overlaps toolbar labels");
            else
                require(w.transportBounds.contains(w.stageTimer->getBounds()),"Timer needs space in the existing panel at the minimum width");
            int navRight = w.proPlaybackBounds.getX();
            for (auto id : {"projectStart", "previousTimelinePoint", "nextTimelinePoint", "projectEnd"}) {
                const auto *control = w.controls[id];
                require(control->isVisible() && control->getButtonText().isEmpty() &&
                        w.proPlaybackBounds.contains(control->getBounds()) &&
                        control->getX() >= navRight && control->getY() == w.controls["proPlay"]->getY(),
                        "Project navigation must show symbols at the left of the display");
                navRight = control->getRight();
            }
            require(w.proTimeBounds.getX() == w.proPlaybackBounds.getX() &&
                    w.proTimeBounds.getBottom() <= w.proPlaybackBounds.getY() &&
                    w.proTimeBounds.getRight() <= w.songDisplay.getX(), "Position display must sit above the transport without overlap");
            require(navRight <= w.controls["proPlay"]->getX() &&
                    w.controls["proPause"]->getRight() <= w.controls["proFadeout"]->getX() &&
                    w.controls["proFadeout"]->getRight() <= w.controls["proRecord"]->getX() &&
                    w.controls["proFadeout"]->getY() == w.controls["proPause"]->getY(),
                    "Play follows navigation and Fadeout sits between Pause and Record");
            require(w.controls["remote"]->getRight() < w.controls["audioStatus"]->getX(), "Live tools overlap audio status");
            require(uiFeatureTests::find(w,"timerHours")==nullptr,"Toolbar retained editable timer inputs");
            w.stage.target=65;w.stage.start();w.updateState();
            require(w.stageTimer->isVisible()&&w.stageTimer->getText()=="00:01:05","Active countdown did not appear immediately");
            w.stage.started-=2;w.updateState();
            require(w.stageTimer->getText()=="00:01:03","Toolbar count did not advance");
            w.stage.reset();w.updateState();
            require(!w.stageTimer->isVisible(),"Timer count remained visible after stopping");
        }
        require(w.controls["menu"]->getTooltip().isEmpty(), "File must not show a tooltip");
        for (auto id : {"mixer", "railMixer", "matrixPatch", "railParts", "railNotice",
                        "railKeyboard", "railVinhetas", "railClock",
                        "advanced", "grandma2", "resolume", "tp1", "tp2", "preview", "remote"}) {
            auto *button = w.controls[id];
            require(button->getTooltip().isNotEmpty(), "Icon is missing its tooltip");
            const auto tip = button->getTooltip();
            const juce::Rectangle<int> area(0,0,800,600);
            const auto bounds = w.look.getTooltipBounds(tip, {795,595}, area);
            require(area.contains(bounds) && bounds.getWidth() - 16 >= GlyphArrangement::getStringWidth(theme::font(12), tip),
                    "Tooltip must fit the full name at the screen edge");
            require(button->getButtonText().isNotEmpty() && (bool)button->getProperties()["toolbarLabel"],
                    "Toolbar labels should retain their flat presentation");
        }
        for (auto id : {"menu","library","focus","midiPreview","tp1","video","remote","settings"})
            require(w.controls[id]->getProperties()["icon"].toString().isNotEmpty(), "Toolbar symbol missing");
        require(w.controls["advanced"]->getProperties()["icon"].toString()=="info.circle",
                "Advanced must use the circled information icon");
        require(w.controls["menu"]->getButtonText() == "File" && w.controls["railKeyboard"]->getButtonText() == "Keyboard" &&
                w.controls["railClock"]->getButtonText() == "Timer" && w.controls["focus"]->getButtonText() == "Track - I",
                "Fixed toolbar labels must be verbatim");
        require(w.addTrack.getWidth() == w.timelineBands.getWidth() && w.addTrack.getHeight() == w.timelineBands.getHeight() &&
                w.addTrack.getRight() < w.timelineBands.getX(), "Timeline lanes must match Add and sit immediately to its right");
        require(w.controls["editMode"]->getProperties()["icon"].toString() == "editCursor" &&
                w.controls["track-envelopes"]->getProperties()["icon"].toString() == "automationLanes" &&
                w.controls["editMode"]->getRight() < w.controls["track-envelopes"]->getX(),
                "The edit cursor and global envelopes controls must be beside one another");
        auto testMemory = [&](Slider &slider, const char *control, double previous, double manual) {
            auto *button = w.controls[control];
            slider.setValue(previous, sendNotificationSync);
            previous = slider.getValue();
            button->onClick();
            require(button->getToggleState() && std::abs(slider.getValue() - slider.getMinimum()) < .000001,
                    "The first memory press must select minimum");
            button->onClick();
            require(!button->getToggleState() && std::abs(slider.getValue() - previous) < .000001,
                    "The second memory press must restore the previous setting");
            button->onClick();
            slider.setValue(manual, sendNotificationSync);
            manual = slider.getValue();
            require(!button->getToggleState(), "A manual adjustment must leave minimum mode");
            button->onClick();
            button->onClick();
            require(std::abs(slider.getValue() - manual) < .000001, "Memory must restore the new manual setting");
        };
        testMemory(w.trackHeightSlider, "trackHeightFit", 96, 124);
        testMemory(w.zoom, "zoomFit", 10, 23);
        auto *envelopes = w.controls["track-envelopes"];
        envelopes->onClick();
        require(envelopes->getToggleState() && automation::allTrackLanesVisible(*w.session.song()),
                "Global automation must open every compatible track");
        envelopes->onClick();
        require(!envelopes->getToggleState() && !automation::allTrackLanesVisible(*w.session.song()),
                "Global automation must close track envelopes");
        w.controls["projectEnd"]->onClick();
        require(w.session.transport().editPosition == w.session.song()->duration, "End must move the edit cursor to the end");
        w.controls["projectStart"]->onClick();
        require(w.session.transport().editPosition == 0, "Start must move the edit cursor to the beginning");
        require(w.controls["settings"]->getButtonText().isEmpty() &&
                w.controls["settings"]->getProperties()["icon"].toString() == "gearshape" &&
                float(w.controls["settings"]->getProperties()["iconSize"]) == 15.f,
                "Settings must use the shared 15-point gear");
        const auto signal = [&](const char *id) { return int(w.controls[id]->getProperties()["toolbarSignal"]); };
        require(signal("mixer") == 1 && signal("focus") == 0 && signal("library") == 0,
                "The toolbar must indicate which panels are open");
        w.controls["focus"]->onClick();
        w.controls["library"]->onClick();
        require(signal("focus") == 1 && signal("library") == 1, "Open Focus and Library must turn green");
        w.controls["focus"]->onClick();
        w.controls["library"]->onClick();
        require(signal("focus") == 0 && signal("library") == 0, "A closed panel must clear its active colour");
        host.clearContentComponent();
    }
    static void settingsThemeParity(const File &directory) {
        using floatingControlTests::require;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("theme-parity",".json"));
        w.setSize(1530,860);w.projectOpened(false);
        SettingsPanel settings(session,auth,lighting,w.appearance,w.actions,0,
            [](String message){throw std::runtime_error(utf8(message));},[]{});
        settings.setSize(760,520);
        auto *language = uiFeatureTests::find(settings,"language");
        auto *themeChoice = uiFeatureTests::find(settings,"interfaceTheme");
        auto *startup = uiFeatureTests::find(settings,"startupSound");
        auto *show = uiFeatureTests::find(settings,"showMode");
        require(language&&themeChoice&&startup&&show&&language->getY()<themeChoice->getY()&&themeChoice->getY()<startup->getY()&&startup->getY()<show->getY(),
                "General settings must follow the Mac order");
        auto *dark=dynamic_cast<Button*>(uiFeatureTests::find(settings,"interfaceTheme0"));
        auto *light=dynamic_cast<Button*>(uiFeatureTests::find(settings,"interfaceTheme1"));
        require(dark&&light&&dark->getName()=="Dark"&&light->getName()=="Light Dark"&&light->getToggleState(),
                "General must use one segmented theme control");
        auto *canvas=uiFeatureTests::find(w,"timelineCanvas");
        require(canvas,"Timeline canvas missing");
        const auto sample=juce::Rectangle<int>(canvas->getWidth()/2,canvas->getHeight()-60,48,42);
        const auto before=canvas->createComponentSnapshot(sample);
        dark->onClick();
        floatingControlTests::pump();
        const auto after=canvas->createComponentSnapshot(sample);
        require(dark->getToggleState()&&!light->getToggleState()&&theme::background==theme::darkBackground&&
                before.getPixelAt(10,10)!=after.getPixelAt(10,10),"Dark must repaint a previously captured grid immediately");
        light->onClick();
        floatingControlTests::pump();
        const auto restored=canvas->createComponentSnapshot(sample);
        require(light->getToggleState()&&!dark->getToggleState()&&theme::background==theme::lightDarkBackground&&
                before.getPixelAt(10,10)==restored.getPixelAt(10,10),"Light Dark must repaint the grid without another interaction");
    }
    static void tabbedPatchWindow(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        auto project=floatingControlTests::fixture();session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getChildFile("patch-window-ui.json"));
        Component tabs;tabs.setSize(1200,800);tabs.addAndMakeVisible(workspace);workspace.setBounds(tabs.getLocalBounds());
        DocumentWindow root("Tabbed workspace",theme::background,0);root.setContentNonOwned(&tabs,true);root.setVisible(true);
        Workspace::showPanel("Patch",std::make_unique<PatchPanel>(session,project.songs.front().tracks.front().id,[](String){}),360,500);
        floatingControlTests::pump();
        DocumentWindow *patchWindow=nullptr;
        for(int i=0;i<Desktop::getInstance().getNumComponents();++i)
            if(auto *window=dynamic_cast<DocumentWindow*>(Desktop::getInstance().getComponent(i)))
                if(dynamic_cast<PatchPanel*>(window->getContentComponent()))patchWindow=window;
        require(patchWindow!=nullptr,"Patch was not opened from the tab host");
        require(!patchWindow->isCurrentlyModal() && Component::getCurrentlyModalComponent()==nullptr,"Patch blocked the workspace");
        require(patchWindow->getTitleBarHeight()==0 && !patchWindow->isUsingNativeTitleBar(),"Patch retained a title bar");
        require(patchWindow->getCloseButton()==nullptr && patchWindow->getMinimiseButton()==nullptr && patchWindow->getMaximiseButton()==nullptr,"Patch retained window chrome buttons");
        TextButton *close=nullptr;
        for(auto *child:patchWindow->getContentComponent()->getChildren())
            if(auto *button=dynamic_cast<TextButton*>(child))close=button;
        require(close!=nullptr,"Patch lost its bottom Close button");close->onClick();
        require(!patchWindow->isVisible(),"Bottom Close did not close the modeless Patch");
        floatingControlTests::pump();
    }
    static void toolWindowOrdering(const File &directory) {
        using floatingControlTests::require;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("tool-order",".json"));
        DocumentWindow host("Workspace",theme::background,0);
        host.setContentNonOwned(&w,false);host.setBounds(50,50,1100,750);host.setVisible(true);w.projectOpened(false);
        w.openAdvanced();
        auto *tool=w.floatingWindows.at(String::fromUTF8("Avançado")).get();
        const auto main=static_cast<HWND>(host.getPeer()->getNativeHandle());
        const auto handle=static_cast<HWND>(tool->getPeer()->getNativeHandle());
        for(int i=0;i<3;++i) {
            host.toFront(true);w.updateState();floatingControlTests::pump();
            require(GetWindow(handle,GW_OWNER)==main,"Advanced lost its workspace owner");
            DWORD foregroundProcess = 0;
            if (const auto foreground = GetForegroundWindow()) GetWindowThreadProcessId(foreground, &foregroundProcess);
            if (foregroundProcess == GetCurrentProcessId()) {
                require(tool->isVisible() && !tool->isMinimised(), "Advanced disappeared after focusing workspace");
                bool above = false;
                for (auto window = GetTopWindow(nullptr); window; window = GetWindow(window, GW_HWNDNEXT)) {
                    if (window == handle) { above = true; break; }
                    if (window == main) break;
                }
                require(above, "Advanced fell behind workspace");
            }
            require(!(GetWindowLongPtrW(handle,GWL_EXSTYLE)&WS_EX_TOPMOST),"Tool became globally topmost");
            require(Component::getCurrentlyModalComponent()==nullptr,"Tool blocked workspace controls");
            require(!tool->isResizable()&&tool->getMaximiseButton()==nullptr,"Advanced is still user resizable");
            const auto *limits=tool->getConstrainer();
            require(limits&&limits->getMinimumWidth()==limits->getMaximumWidth()&&limits->getMinimumHeight()==limits->getMaximumHeight(),"Advanced does not keep its designed size");
        }
        tool->closeButtonPressed();require(!tool->isVisible(),"Explicit Close failed");
        host.clearContentComponent();
    }
    static void projectReplacement(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(Session::makeEmptyProject("Original"))); session.audio.setOffline(true);
        const auto file=directory.getNonexistentChildFile("replace-current", "").getChildFile("Original.jl");
        session.save(file);
        Auth auth; Lighting lighting(session); Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("replacement-ui",".json"));
        w.setSize(1200,800); w.projectOpened(false);
        session.edit([](jaras::Project &p){p.name="Preserved edit";},false);
        bool applied=false, cancelled=false;
        auto find=[] { return dynamic_cast<CloseProjectSheet *>(Component::getCurrentlyModalComponent()); };
        w.confirmProjectReplacement("Next",[&]{applied=true;},[&]{cancelled=true;});
        auto *panel=find();require(panel!=nullptr,"Replacement used a system alert instead of the rounded panel");
        panel->keyPressed(KeyPress(KeyPress::escapeKey));floatingControlTests::pump();
        require(cancelled&&!applied&&session.dirty&&session.project().name=="Preserved edit","Cancel modified the outgoing project");
        w.confirmProjectReplacement("Next",[&]{applied=true;});panel=find();require(panel!=nullptr,"Second confirmation missing");
        panel->keyPressed(KeyPress(KeyPress::returnKey));
        const auto deadline=Time::getMillisecondCounterHiRes()+15000;
        while(!applied&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        require(applied&&!session.dirty,"Replacement ran before saving or never continued");
        Session reopened;reopened.inspection=true;reopened.audio.prepareOffline(48000);reopened.audio.setOffline(true);reopened.load(file);
        require(reopened.project().name=="Preserved edit","Replacement discarded unsaved edits");
        floatingControlTests::pump();
        session.edit([](jaras::Project &p){p.name="Remote preserved edit";},false);applied=false;
        w.confirmProjectReplacement("Remote next",[&]{applied=true;},{},true);
        panel = find();
        require(panel && !applied && session.dirty, "Incoming Remote selection must allow the desktop to save its pending edits");
        panel->keyPressed(KeyPress(KeyPress::returnKey));
        const auto remoteDeadline=Time::getMillisecondCounterHiRes()+15000;
        while(!applied&&Time::getMillisecondCounterHiRes()<remoteDeadline)floatingControlTests::pump();
        require(applied&&!session.dirty,"Remote replacement did not save before continuing");
        reopened.load(file);require(reopened.project().name=="Remote preserved edit","Remote replacement lost edits");
    }
    static void liveRecordingWaveform(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();
        auto &track=project.songs.front().tracks.front();track.clips.clear();track.heightScale=.1;track.color=0x555555;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Session::RecordingItem item;item.track=track.id;item.clip.id=uuid();item.clip.name="Live";item.clip.startTime=0;item.clip.duration=100;item.clip.recordingLane=0;
        item.preview=std::make_shared<RecordingPreview>(48000,2);item.preview->frames=48000;
        session.recordingItems.push_back(item);++session.revision;
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getChildFile("recording-preview.json"));
        w.setSize(1600,900);w.projectOpened(false);w.partsLeftVisible=false;w.partsRightVisible=false;w.setlistVisible=false;
        w.pixelsPerSecond=240;w.rebuild();
        auto silent=w.createComponentSnapshot(w.getLocalBounds());
        AudioBuffer<float> samples(2,48000);for(int c=0;c<2;++c)for(int i=0;i<48000;++i)samples.setSample(c,i,(c?-.6f:.8f));
        item.preview->append(samples.getArrayOfReadPointers(),48000);item.preview->drain();
        // Invalidate the cached canvas without rebuilding or stopping capture.
        std::function<void(Component &)> invalidate=[&](Component &c){c.repaint();for(auto *child:c.getChildren())invalidate(*child);};
        invalidate(w);
        auto recorded=w.createComponentSnapshot(w.getLocalBounds());
        int changed=0;for(int y=0;y<silent.getHeight();++y)for(int x=0;x<silent.getWidth();++x)
            if(silent.getPixelAt(x,y)!=recorded.getPixelAt(x,y))++changed;
        require(changed>50,"Compact live item has no visible waveform before Stop");
    }
    static void dividerMargins(const File &directory) {
        using floatingControlTests::require;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("divider-margins",".json"));
        w.setSize(1600,900);w.projectOpened(false);w.partsLeftVisible=false;w.partsRightVisible=false;
        w.mixerWidth=350;w.setlistWidth=300;
        for(bool mixer:{false,true})for(bool setlist:{false,true})for(bool leading:{false,true}) {
            w.mixerVisible=mixer;w.setlistVisible=setlist;
            w.setlistPlacement=leading?Workspace::SetlistPlacement::left:Workspace::SetlistPlacement::right;w.resized();
            const auto state=get(w.diagnostics(),"timeline");
            require(num(state,"x")==w.tracksViewport.getRight()+(mixer?6:0),"Mixer divider lost its narrow resize area");
            require(w.mixerDivider.getWidth()==(mixer?6:0)&&w.setlistDivider.getWidth()==(setlist&&leading?6:0),"Hidden divider retained a margin or visible resize area collapsed");
            require(w.tracksViewport.getWidth()==(mixer?350:0),"Divider margin reduced mixer controls");
            if(setlist&&!leading)require(num(state,"x")+num(state,"width")+timelineGrid::verticalScrollbarWidth==w.setlistDivider.getX(),"Timeline scrollbar must meet the trailing Setlist");
            if(setlist&&leading)require(w.setlistDivider.getRight()==w.tracksViewport.getX(),"Leading setlist gap was not reserved");
        }
    }
    static void trackIconWidth(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();
        auto &tracks=project.songs.front().tracks;
        tracks[1].parentTrackID=tracks[0].id;
        const auto target=tracks[0].id;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getChildFile("track-icon-width-layout.json"));
        w.setSize(1600,900);w.projectOpened(false);w.mixerVisible=true;
        w.partsLeftVisible=false;w.partsRightVisible=false;w.setlistVisible=false;
        std::function<Component *(Component &,const String &)> find=[&](Component &parent,const String &id)->Component * {
            if(parent.getComponentID()==id)return &parent;
            for(auto *child:parent.getChildren())if(auto *result=find(*child,id))return result;
            return nullptr;
        };
        const auto frames=[&] {
            std::vector<juce::Rectangle<int>> result;
            for(const auto &track:session.song()->tracks) {
                auto *row=find(w,"trackRow:"+text(track.id));require(row!=nullptr,"Missing track row");
                for(auto *child:row->getChildren())if(child->isVisible())result.push_back(child->getBounds());
            }
            return result;
        };
        for(int width:{281,350,480}) {
            w.mixerWidth=width;w.rebuild();
            const auto before=frames();const int viewport=w.tracksViewport.getWidth();
            const auto toolbar=w.addTrack.getBounds();
            session.setTrackInstrumentIcon({target},std::string("drums"));w.rebuild();
            require(w.tracksViewport.getWidth()==viewport && w.mixerWidth==width,
                    "Painting a track icon must keep the saved mixer width");
            require(w.addTrack.getBounds()==toolbar, "Painting a track icon moved the toolbar");
            w.mixerVisible=false;w.resized();
            require(w.tracksViewport.getWidth()==0&&!w.tracksViewport.isVisible(),"Hidden mixer retained its width");
            w.mixerVisible=true;w.resized();
            require(w.tracksViewport.getWidth()==viewport, "Restoring the mixer changed its width");
            session.setTrackInstrumentIcon({target},std::nullopt);w.rebuild();
            require(w.tracksViewport.getWidth()==viewport&&frames()==before,"Removing the last icon changed the saved body width");
        }
    }
    static void mixerNamesAndMinimumWidth(const File &directory) {
        using floatingControlTests::require;
        auto project = floatingControlTests::fixture();
        auto &track = project.songs.front().tracks.front();
        track.color = 0x234567;
        const auto id = track.id;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session, auth, lighting, false, directory.getNonexistentChildFile("mixer-names", ".json"));
        workspace.setSize(1366,900); workspace.projectOpened(false);
        workspace.footerMixerVisible = workspace.mixerVisible = true;
        workspace.mixerWidth = 1;
        workspace.resized(); workspace.footerMixer->refresh();
        require(workspace.tracksViewport.getWidth() == 278, "Track Mixer did not stop at the saved minimum");
        auto *row = uiFeatureTests::find(workspace, "trackRow:" + text(id));
        require(row, "Track Mixer row is missing");
        auto *patch = uiFeatureTests::find(*row, "trackPatch");
        require(patch && patch->isVisible(), "Patch must remain visible at the minimum width");
        auto *fader = uiFeatureTests::find(*row, "trackVolume");
        const int narrow = fader ? fader->getWidth() : 0;
        workspace.mixerWidth = 360; workspace.resized();
        require(narrow > 0 && narrow == fader->getWidth(), "The fader must keep its length across mixer widths");

        auto rename = [&](Component *channel, const String &replacement) {
            require(channel, "Mixer channel is missing");
            auto *input = dynamic_cast<InlineMixerTrackName *>(uiFeatureTests::find(*channel, "mixerTrackNameEditor"));
            require(input && !input->isVisible(), "The rename field should start hidden");
            auto point = input->getBounds().toFloat().getCentre();
            if (channel == row) point.x = float(input->getX() + 6);
            const auto now = Time::getCurrentTime();
            const MouseEvent event(Desktop::getInstance().getMainMouseSource(), point,
                ModifierKeys(ModifierKeys::leftButtonModifier), 1, 0, 0, 0, 0,
                channel, channel, now, point, now, 2, false);
            channel->mouseDoubleClick(event);
            require(input->isVisible(), "Double-clicking a track name must open its inline editor");
            input->setText(replacement, false);
            input->finishIfOutside(input);
            require(input->isVisible(), "The rename field must stay open on an inside click");
            input->finishIfOutside(channel);
            require(!input->isVisible(), "The rename field must close on an outside click in the same track");
            floatingControlTests::pump();
            require(text(session.song()->tracks.front().name) == replacement &&
                    session.song()->tracks.front().color == 0x234567, "Rename changed the wrong field or the track color");
        };
        rename(row, "Track Mixer name");
        rename(uiFeatureTests::find(*workspace.footerMixer, "mixerStrip:" + text(id)), "Hoz Mixer name");

        const ID second = project.songs.front().tracks[1].id;
        workspace.setlistVisible = false; workspace.resized();
        workspace.selectMixerTrack(id, {});
        require(workspace.keyPressed(KeyPress(KeyPress::downKey)) && workspace.selectedTrack == second,
                "Down should select the next mixer track with Setlist closed");
        require(workspace.keyPressed(KeyPress(KeyPress::upKey)) && workspace.selectedTrack == id,
                "Up should select the previous mixer track with Setlist closed");
        workspace.setlistVisible = true; workspace.resized();
        auto *firstInput = dynamic_cast<InlineMixerTrackName *>(uiFeatureTests::find(*row, "mixerTrackNameEditor"));
        auto *nextRow = uiFeatureTests::find(workspace, "trackRow:" + text(second));
        require(firstInput && nextRow, "Mixer name navigation fixture is missing");
        auto *nextInput = dynamic_cast<InlineMixerTrackName *>(uiFeatureTests::find(*nextRow, "mixerTrackNameEditor"));
        require(nextInput, "The next track has no inline name editor");
        require(workspace.stepMixerTrack(1, true) && nextInput->isVisible(),
                "Setlist visibility must not block inline track name navigation");
        nextInput->setText("Saved on Up", false);
        require(nextInput->keyPressed(KeyPress(KeyPress::upKey)) &&
                workspace.selectedTrack == id && firstInput->isVisible() && !nextInput->isVisible(),
                "Up did not move focus to the preceding track name");
        floatingControlTests::pump();
        require(text(session.song()->tracks[1].name) == "Saved on Up",
                "Moving between names must confirm the previous edit");
    }
    static void deleteRecentWhilePlaying(const File &directory) {
        using floatingControlTests::require;
        struct RestoreRecents { StringArray saved=RecentProjects::read(); ~RestoreRecents(){RecentProjects::write(saved);} } recents;
        const auto folder=directory.getNonexistentChildFile("live-recent-deletion","");
        const auto currentFile=folder.getChildFile("current/Current.jl"), otherFile=folder.getChildFile("other/Other.jl");
        otherFile.getParentDirectory().createDirectory();
        ProjectCodec::write(otherFile,ProjectCodec::encode(floatingControlTests::fixture()));
        auto session=std::make_unique<Session>();session->inspection=true;session->audio.prepareOffline(48000);
        session->restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session->audio.setOffline(true);
        session->save(currentFile);
        Auth auth;Lighting lighting(*session);Workspace w(*session,auth,lighting,false,folder.getChildFile("layout.json"));
        w.setSize(1366,900);w.projectOpened(false);
        session->edit([](auto &project){project.name="Unsaved active show";},false);
        session->command(jaras::CommandKind::play);
        AudioBuffer<float> pcm(2,128);session->audio.render(pcm.getArrayOfWritePointers(),2,128);
        const auto projectID=session->project().id;
        w.deleteRecentProject(otherFile);
        ProjectDeletionPanel *panel=nullptr;
        std::function<void(Component &)> find=[&](Component &component){
            if(auto *candidate=dynamic_cast<ProjectDeletionPanel*>(&component))panel=candidate;
            for(auto *child:component.getChildren())find(*child);
        };
        find(w);require(panel!=nullptr,"Playback prevented the recent-project deletion confirmation");
        TextButton *remove=nullptr;
        for(auto *child:panel->getChildren())if(auto *button=dynamic_cast<TextButton*>(child))
            if(button->getButtonText()!=localization::translate("Cancel"))remove=button;
        require(remove && !remove->isEnabled(),"Deletion confirmation skipped its countdown");
        const auto deadline=Time::getMillisecondCounterHiRes()+4500;
        while(!remove->isEnabled()&&Time::getMillisecondCounterHiRes()<deadline) {
            floatingControlTests::pump();session->audio.render(pcm.getArrayOfWritePointers(),2,128);
        }
        require(remove->isEnabled()&&session->transport().playing&&otherFile.existsAsFile(),
                "Opening or waiting for deletion stopped playback or deleted without confirmation");
        const auto clock=session->audio.state();
        remove->onClick();floatingControlTests::pump();
        require(!otherFile.existsAsFile()&&currentFile.existsAsFile(),"Deletion removed the wrong project");
        require(session->project().id==projectID&&session->document==currentFile&&w.projectReady,
                "Deleting another recent project cleared the active session");
        require(session->transport().playing&&session->audio.state().playing&&session->audio.state().position==clock.position,
                "Deleting another recent project stopped or reset the audio clock");
        require(ProjectCodec::decode(ProjectCodec::read(currentFile)).name=="Unsaved active show",
                "Deleting another project lost the active project's unsaved shared-media protection");
        session->command(jaras::CommandKind::stopAll);
    }
    static void unifyItems(const File &directory) {
        using floatingControlTests::require;
        for(bool midi:{false,true}) {
            const auto folder=directory.getNonexistentChildFile("unify-selection","");folder.createDirectory();
            mediaImportTests::source(folder,"source.wav",48000);
            auto project=floatingControlTests::fixture();project.songs.front().parts.clear();
            std::set<ID> selected;ID clicked,unselected;
            for(int ti=0;ti<2;++ti) for(int ci=0;ci<3;++ci) {
                jaras::AudioClip clip;clip.id=uuid();clip.name="Item";clip.startTime=ci*2;clip.duration=1;
                if(midi){clip.midi.emplace();clip.midi->sourceBPM=120;clip.midi->notes.push_back({uuid(),0,1,60+ci,100,1});}
                else clip.audioFile=jaras::AudioFile{"source.wav",{}};
                project.songs.front().tracks[(size_t)ti].clips.push_back(clip);
                if(ci<2){selected.insert(clip.id);clicked=clip.id;}else unselected=clip.id;
            }
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.mediaDirectory=folder;session.document=folder.getChildFile("Show.jl");
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,folder.getChildFile("layout.json"));
            w.setSize(1366,900);w.projectOpened(false);
            const auto before=JSON::toString(session.snapshot());w.selectedClips=selected;w.selectedClip=clicked;
            const auto choose=[&](const ID &id,int action){
                // Invoke the exact callback passed to the popup, including the
                // selection snapshot captured when that menu opens.
                const auto handler=w.clipMenuAction(id);
                handler(action);floatingControlTests::pump();mediaImportTests::wait(session,60000);floatingControlTests::pump();
                mediaImportTests::require(session.message.isEmpty(),"Item menu action failed: "+session.message);
            };
            if(!midi){
                for(int mode:{1,2,3,4,0}){
                    if(mode==0)choose(clicked,21);
                    const auto previous=JSON::toString(session.snapshot());
                    choose(clicked,20+mode);
                    for(const auto &track:session.song()->tracks)for(const auto &clip:track.clips)
                        require(clip.channelMode.value_or(0)==(selected.count(clip.id)?mode:0),"Channel conversion skipped selection or changed an unselected item");
                    session.undo();require(JSON::toString(session.snapshot())==previous,"Channel conversion Undo changed other item data");
                    if(mode==0)session.undo();
                }
                w.performAction("normalizeItems",1,0);
                auto *level=dynamic_cast<TextEditor*>(uiFeatureTests::find(w,"normalizationTarget"));
                auto *apply=dynamic_cast<Button*>(uiFeatureTests::find(w,"normalizationApply"));
                require(level&&apply,"Normalize Action did not open the selected-item panel");
                level->setText("-6");apply->onClick();
                const auto deadline=Time::getMillisecondCounterHiRes()+10000;
                while(!session.song()->tracks[1].clips[1].normalizationGain&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
                for(const auto &track:session.song()->tracks)for(const auto &clip:track.clips)
                    require(clip.normalizationGain.has_value()==(selected.count(clip.id)>0),"Normalize Action did not process exactly the full selection");
                ModalSheet::dismiss(w);floatingControlTests::pump();session.undo();
                require(JSON::toString(session.snapshot())==before,"Normalize Action was not one Undo");
                w.performAction("reRenderItems",1,0);mediaImportTests::wait(session,60000);floatingControlTests::pump();
                require(session.message.isEmpty()&&w.selectedClips.size()==selected.size(),"Re-render Action skipped selected audio items");
                session.undo();require(JSON::toString(session.snapshot())==before,"Re-render Action was not one Undo");
                w.selectedClips=selected;w.selectedClip=clicked;
            }
            w.performAction("unifyAudioItems",1,0);mediaImportTests::wait(session,60000);floatingControlTests::pump();
            require(w.selectedClips.size()==2,"Unify did not select one resulting item per track");
            for(int ti=0;ti<2;++ti){const auto &track=session.song()->tracks[(size_t)ti];require(track.clips.size()==2,"Unify processed only the right-clicked item or removed unrelated items");
                const auto &clip=track.clips.front();require(clip.startTime==0&&clip.duration==3&&w.selectedClips.count(clip.id),"Unified range or result selection is wrong");
                require(selected.count(track.clips.back().id)==0&&track.clips.back().startTime==4,"Unselected item changed");
                if(midi)require(clip.midi&&clip.midi->notes.size()==2,"Unify lost MIDI notes");
                else require(clip.audioFile&&!clip.waveform.empty()&&folder.getChildFile(text(clip.audioFile->path)).existsAsFile(),"Unify produced no audio or peaks");
            }
            session.undo();require(JSON::toString(session.snapshot())==before,"Single Undo did not restore selected originals");
            session.redo();require(session.song()->tracks.front().clips.size()==2,"Redo did not restore unified item");
            // Right-click outside the selection must affect that item alone.
            session.undo();w.selectedClips=selected;w.selectedClip=clicked;choose(unselected,14);
            require(session.song()->tracks.front().clips.size()==3&&session.song()->tracks[1].clips.size()==3,"Unify outside selection modified selected items");
        }
    }
    static void exportItems(const File &directory) {
        using floatingControlTests::require;
        const auto folder=directory.getNonexistentChildFile("export-selection","");folder.createDirectory();
        mediaImportTests::source(folder,"source.wav",48000);
        auto project=floatingControlTests::fixture();auto &song=project.songs.front();song.parts.clear();song.duration=60;
        for(auto &track:song.tracks)track.clips.clear();
        std::set<ID> selected,audio;ID clicked,unselected;
        for(int i=0;i<2;++i) {
            auto &track=song.tracks[size_t(i)];
            jaras::AudioClip clip;clip.id=uuid();clip.name="Same.wav";clip.startTime=10+i*20;clip.duration=.25+i*.25;
            clip.audioFile=jaras::AudioFile{"source.wav",{}};track.clips.push_back(clip);
            audio.insert(clip.id);selected.insert(clip.id);clicked=clip.id;
            clip.id=uuid();clip.startTime+=2;track.clips.push_back(clip);unselected=clip.id;
        }
        auto midi=song.tracks.front().clips.front();midi.id=uuid();midi.midi.emplace();
        midi.audioFile.reset();song.tracks.front().audioFile=jaras::AudioFile{"source.wav",{}};
        song.tracks.front().clips.push_back(midi);selected.insert(midi.id);
        auto video=song.tracks.front().clips.front();video.id=uuid();song.tracks[2].role.id="video";
        song.tracks[2].name=jaras::fixedTrackName(song.tracks[2].role);
        song.tracks[2].clips.push_back(video);selected.insert(video.id);
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.mediaDirectory=folder;
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,folder.getChildFile("layout.json"));
        w.setSize(1366,900);w.projectOpened(false);
        const auto before=JSON::toString(session.snapshot());
        auto choose=[&](const ID &item,bool pre) {
            w.clipMenuAction(item)(12);floatingControlTests::pump();
            auto *button=dynamic_cast<Button*>(uiFeatureTests::find(w,pre?"itemExportPreProcessing":"itemExportPostProcessing"));
            require(button!=nullptr,"Item export skipped the processing choice");button->onClick();floatingControlTests::pump();
            ExportPanel *panel=nullptr;
            std::function<void(Component &)> find=[&](Component &view){if(auto *p=dynamic_cast<ExportPanel*>(&view))panel=p;for(auto *child:view.getChildren())find(*child);};
            find(w);require(panel!=nullptr,"Item export panel did not open");return panel->diagnostics();
        };
        for(bool pre:{true,false}) {
            w.selectedClips=selected;w.selectedClip=clicked;
            const auto state=choose(clicked,pre);const auto jobs=list(get(state,"plannedFiles"));
            require(jobs.size()==2,"Context export skipped selected audio or included MIDI/video/unselected items");
            require(!flag(state,"boundsEnabled",true)&&num(state,"source")==4,"Item export permits changing global bounds or source");
            require(str(jobs[0],"name")=="Same.wav"&&str(jobs[1],"name")=="Same - 001.wav","Batch filenames lost the original name and padded suffix");
            for(const auto &job:jobs)require(audio.count(utf8(str(job,"clip")))!=0,"Export changed the captured selection");
            require(num(jobs[0],"start")==10&&num(jobs[0],"end")==10.25&&num(jobs[1],"start")==30&&num(jobs[1],"end")==30.5,"Item export used project/region bounds");
            ModalSheet::dismiss(w);floatingControlTests::pump();
        }
        const auto state=choose(unselected,true);
        require(num(state,"jobs")==1&&str(list(get(state,"plannedFiles"))[0],"clip")==text(unselected),"Export outside the selection included selected items");
        ModalSheet::dismiss(w);floatingControlTests::pump();
        require(JSON::toString(session.snapshot())==before,"Opening or cancelling export changed the project");
    }
    static void generatedItems(const File &directory) {
        using floatingControlTests::require;
        for (bool playing : {false,true}) {
            auto project=floatingControlTests::fixture();
            auto &tracks=project.songs.front().tracks;
            tracks[1].role.id="teleprompt";tracks[1].name=jaras::fixedTrackName(tracks[1].role);
            tracks[2].role.id="chords";tracks[2].name=jaras::fixedTrackName(tracks[2].role);
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);
            Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("generated-items",".json"));w.setSize(1366,900);w.projectOpened(false);
            session.command(jaras::CommandKind::editSeek,{},3);
            if(playing)session.command(jaras::CommandKind::play);
            for(size_t index=0;index<3;++index) {
                // Windows MIDI creation is a structural edit and requires Stop;
                // text creation also supports an already-running transport.
                if (playing && index==0) continue;
                const auto id=tracks[index].id;
                if(index==0)w.addMIDIItem(id,5);else w.addTextItem(id,5);
                const auto findTrack=[&]() -> const jaras::Track& { return *std::find_if(session.song()->tracks.begin(),session.song()->tracks.end(),[&](const auto &t){return t.id==id;}); };
                require(!findTrack().clips.empty(),"Generated item was not inserted");
                const auto &clip=findTrack().clips.back();
                const auto end=clip.startTime+clip.duration;
                if(index==0) require(clip.midi&&!w.floatingWindows.count("Piano Roll - "+text(clip.id)),
                    "Creating a MIDI item must leave the Piano Roll closed");
                require(session.transport().editPosition==end,"Generated item did not advance edit cursor to its actual end");
                require(session.transport().playing==playing&&session.transport().position==(playing?3:end),"Generated item disrupted playback");
                if(index>0) {
                    w.floatingWindows.at("Editor de texto")->closeButtonPressed();
                    w.addTextItem(id,session.transport().editPosition);
                    require(findTrack().clips.back().startTime==end,"Consecutive text items do not start at the previous end");
                    w.floatingWindows.at("Editor de texto")->closeButtonPressed();
                }
            }
            session.command(jaras::CommandKind::stopAll);
        }
    }
    static void sharedWaveformRaster(const File &directory) {
        using floatingControlTests::require;
        WaveformCache::Data data;data.version="fixture";
        jaras::AudioClip clip;clip.id=uuid();clip.name="Original";clip.duration=20;
        const auto identity=[&](const jaras::AudioClip &value) {
            return WaveformRasterIdentity::make(data,value,ClipTempo(value),5,1.5f,98,58,0,98,Colours::black);
        };
        const auto key=identity(clip);require(key.has_value(),"Valid waveform has no identity");
        auto copy=clip;copy.id=uuid();copy.name="Renamed copy";copy.startTime=50;
        require(identity(copy)==key,"Identical audio in a copied or moved item cannot share its waveform");
        const std::vector<std::function<void(jaras::AudioClip &)>> edits={
            [](auto &c){c.gain=.5;},[](auto &c){c.normalizationGain=2;},[](auto &c){c.phaseInverted=true;},
            [](auto &c){c.pan=.5;},[](auto &c){c.channelMode=1;},[](auto &c){c.sourceOffset=.5;},
            [](auto &c){c.playbackRate=1.159;},[](auto &c){c.duration=19;},
            [](auto &c){c.loopLength=2;},[](auto &c){c.loopStart=.25;},
            [](auto &c){c.fadeIn=1;},[](auto &c){c.fadeOut=1;},
            [](auto &c){c.fadeInCurve=.5;},[](auto &c){c.fadeOutCurve=.5;},
            [](auto &c){c.fadeInSCurve=2;},[](auto &c){c.fadeOutSCurve=2;}};
        for(const auto &edit:edits){auto changed=clip;edit(changed);require(!(identity(changed)==key),"An edited copy reused incompatible waveform pixels");}
        auto timing=ClipTempo(clip);timing.spans.front().rate=2;
        require(!(WaveformRasterIdentity::make(data,clip,timing,5,1.5f,98,58,0,98,Colours::black)==key),"Tempo mapping was omitted from raster identity");
        require(!(WaveformRasterIdentity::make(data,clip,ClipTempo(clip),5,1.5f,98,58,0,98,Colours::red)==key),"Waveform colour was omitted");
        require(!(WaveformRasterIdentity::make(data,clip,ClipTempo(clip),5,2,98,58,0,98,Colours::black)==key),"DPI was omitted");
        data.version="changed";require(!(identity(clip)==key),"Changed source peaks retained their old pixels");

        const auto folder=directory.getNonexistentChildFile("shared-waveforms","");
        require(folder.createDirectory().wasOk(),"Cannot create waveform fixture");
        const auto source=folder.getChildFile("tone.wav");
        WavAudioFormat format;auto stream=source.createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.release(),48000,2,24,{},0));
        require(bool(writer),"Cannot create waveform fixture audio");
        AudioBuffer<float> pcm(2,96000);
        for(int ch=0;ch<2;++ch)for(int i=0;i<pcm.getNumSamples();++i)
            pcm.setSample(ch,i,float(.7*std::sin(i*.037*(ch+1))*(.2+.8*i/pcm.getNumSamples())));
        require(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Cannot write waveform fixture audio");writer.reset();
        auto project=floatingControlTests::fixture();auto &song=project.songs.front();song.duration=30;song.tracks.clear();
        clip.duration=20;clip.loopLength=2;clip.audioFile=jaras::AudioFile{"tone.wav",{}};
        for(int i=0;i<200;++i){jaras::Track track;track.id=uuid();track.name="Copy "+std::to_string(i);track.role.id="other";clip.id=uuid();track.clips={clip};song.tracks.push_back(track);}
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);session.mediaDirectory=folder;session.core.loadProject(project);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,folder.getChildFile("preferences.json"));
        w.setSize(1366,900);w.projectOpened(false);w.zoom.setValue(20,sendNotificationSync);
        auto *canvas=uiFeatureTests::find(w,"timelineCanvas");require(canvas,"No waveform canvas");
        Image image(Image::RGB,canvas->getWidth(),canvas->getHeight(),true);
        auto paint=[&]{Graphics g(image);canvas->paint(g);return get(w.diagnostics(),"timeline");};
        auto state=paint();const auto deadline=Time::getMillisecondCounterHiRes()+10000;
        while((int64)get(state,"waveformRasterBuilds")==0 && Time::getMillisecondCounterHiRes()<deadline) {
            floatingControlTests::pump();Thread::sleep(20);state=paint();
        }
        // The worker can finish while the previous frame is already drawing
        // its last row. Measure reuse after a complete frame with ready peaks.
        state=paint();
        require((int64)get(state,"waveformRasterBuilds")==1,"Identical visible copies built separate waveform bitmaps");
        require((int64)get(state,"waveformRasterHits")>=1,"Visible duplicate rows did not reuse the same waveform");
        w.mixerDivider.scrollTo(64*150);state=paint();
        require((int64)get(state,"waveformRasterBuilds")==1,"Scrolling to distant copies rebuilt the same waveform");
        auto *timeline=canvas->getParentComponent();
        for(int frame=0;frame<5;++frame) {
            w.zoom.setValue(30+frame,sendNotificationSync);
            const auto before=(int64)get(get(w.diagnostics(),"timeline"),"waveformRasterBuilds");
            const auto point=canvas->getLocalBounds().toFloat().getCentre();const auto now=Time::getCurrentTime();
            MouseEvent event(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(),1,0,0,0,0,timeline,timeline,now,point,now,1,false);
            MouseWheelDetails wheel{};wheel.deltaY=1e-9f;timeline->mouseWheelMove(event,wheel);state=paint();
            require((int64)get(state,"waveformRasterBuilds")==before,"Zoom must retain the direct exact-scale drawing path");
            require((int64)get(state,"waveformRasterBytes")<=16*1024*1024,"Waveform raster cache exceeded its memory bound");
        }
    }
    static void overviewProfile(const File &directory) {
        using floatingControlTests::require;
        const File source(SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_PROJECT",{}));
        auto project=ProjectCodec::decode(ProjectCodec::read(source));
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        session.mediaDirectory=source.getParentDirectory();session.core.loadProject(project);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("overview-ui",".json"));
        w.setSize(1366,900);w.projectOpened(false);
        auto *canvas=uiFeatureTests::find(w,"timelineCanvas");
        require(canvas!=nullptr,"No grid canvas for overview profile");
        if(SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_GRID_MOVEMENT",{})=="1") {
            auto *timeline=canvas->getParentComponent();ScrollBar *horizontal=nullptr;
            for(auto *child:timeline->getChildren())if(auto *bar=dynamic_cast<ScrollBar *>(child);bar&&!bar->isVertical())horizontal=bar;
            require(horizontal,"No horizontal grid scrollbar for movement profile");
            w.pixelsPerSecond=5;w.rebuild();
            Image image(Image::RGB,canvas->getWidth(),canvas->getHeight(),true);
            // Warm the actual saved project's peak mapping before measuring gestures.
            for(int frame=0;frame<60;++frame){Graphics g(image);canvas->paint(g);floatingControlTests::pump();Thread::sleep(20);}
            Array<var> measurements;
            for(const String mode:{"scroll","zoom","vertical"}) {
                w.zoom.setValue(5,sendNotificationSync);
                for(int frame=0;frame<90;++frame) {
                    const auto point=canvas->getLocalBounds().toFloat().getCentre();const auto now=Time::getCurrentTime();
                    MouseEvent event(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(),1,0,0,0,0,timeline,timeline,now,point,now,1,false);
                    timeline->mouseDown(event); // Finish the preceding synthetic gesture.
                    const auto started=Time::getMillisecondCounterHiRes();
                    if(mode=="scroll")horizontal->setCurrentRangeStart(frame*7.5,sendNotificationSync);
                    if(mode=="vertical")w.mixerDivider.scrollTo(frame*12);
                    if(mode=="zoom") {
                        w.zoom.setValue(5*std::exp(std::sin(frame*.08)*.8),sendNotificationSync);
                        // Enter the real wheel-rendering path without changing the chosen scale.
                        MouseWheelDetails wheel{};wheel.deltaY=1e-9f;timeline->mouseWheelMove(event,wheel);
                    }
                    const auto inputMs=Time::getMillisecondCounterHiRes()-started;
                    {Graphics g(image);canvas->paint(g);}
                    const auto state=get(w.diagnostics(),"timeline");
                    auto row=object();put(row,"mode",mode);put(row,"frame",frame);put(row,"inputMs",inputMs);
                    put(row,"drawMs",get(state,"paintMilliseconds"));put(row,"stages",get(state,"paintStagesMilliseconds"));
                    put(row,"rasterBuilds",get(state,"waveformRasterBuilds"));put(row,"rasterHits",get(state,"waveformRasterHits"));
                    put(row,"zoom",get(state,"zoom"));measurements.add(row);
                }
            }
            auto report=object();put(report,"tracks",(int)session.song()->tracks.size());
            put(report,"width",canvas->getWidth());put(report,"height",canvas->getHeight());put(report,"samples",measurements);
            directory.getChildFile("grid-movement-profile.json").replaceWithText(JSON::toString(report,true));
            return;
        }
        Array<var> timings;
        for(double scale:{.01,.04,.16,.663591698059409,2.5,10.}) {
            w.pixelsPerSecond=scale;w.rebuild();
            Image image(Image::RGB,canvas->getWidth(),canvas->getHeight(),true);
            for(int frame=0;frame<70;++frame) {
                Graphics g(image);canvas->paint(g);
                if(frame>=65) {
                    const auto state=get(w.diagnostics(),"timeline");
                    auto row=object();put(row,"zoom",scale);put(row,"ms",get(state,"paintMilliseconds"));
                    put(row,"stages",get(state,"paintStagesMilliseconds"));put(row,"waveforms",get(state,"waveforms"));timings.add(row);
                } else {floatingControlTests::pump();Thread::sleep(30);}
            }
        }
        directory.getChildFile("overview-profile.json").replaceWithText(JSON::toString(timings,true));
    }
    static void setlistResponsiveness(const File &directory) {
        using floatingControlTests::require;
        const auto source=SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_PROJECT",{});
        auto project=floatingControlTests::fixture();
        if(source.isNotEmpty())project=ProjectCodec::decode(ProjectCodec::read(File(source)));
        else {
            auto &song=project.songs.front();song.duration=3600;song.parts.clear();song.markers.emplace();
            for(int i=0;i<120;++i) {
                song.parts.push_back({uuid(),"Song "+std::to_string(i),i*30.,(i+1)*30.});
                jaras::TimelineMarker marker;marker.id=uuid();marker.name="Tempo";marker.position=i*30.;marker.tempoBPM=120;
                song.markers->push_back(marker);
            }
            auto &tracks=song.tracks;
            while(tracks.size()<12){auto track=tracks.front();track.id=uuid();tracks.push_back(track);}
            const auto largeSettings=utf8("{\"inserted\":[],\"savedState\":\""+String::repeatedString("x",1024*1024)+"\"}");
            for(auto &track:tracks) {
                track.fxJSON=largeSettings;
                for(int i=0;i<120;++i){jaras::AudioClip clip;clip.id=uuid();clip.name="Audio";clip.startTime=i*30.;clip.duration=30.;clip.waveform=std::vector<double>(128,.25);track.clips.push_back(clip);}
            }
            project.masterFXJSON=largeSettings;
        }
        // Use the actual document model without opening devices or constructing
        // third-party processors. The user's file and audio remain untouched.
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        session.core.loadProject(project);
        const auto *song=session.song();require(song && !song->tracks.empty(),"Profile needs a track");
        std::vector<ID> roots;for(const auto &part:song->parts)if(!part.parentRegionID)roots.push_back(part.id);
        require(roots.size()>1,"Profile needs two regions");
        auto state=session.project().regionSetlist.value_or(jaras::RegionSetlist{});
        const ID a=uuid(),b=uuid();state.playlists.push_back({a,"Profile A",song->id,roots});state.playlists.push_back({b,"Profile B",song->id,roots});
        state.selectedId=a;state.autoAdvance=false;state.automaticSubplay=false;state.stopAtRegionEnd=false;
        session.configureSetlist(state);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("setlist-ui-preferences",".json"));
        w.setSize(1366,900);w.projectOpened(false);w.pixelsPerSecond=4;w.rebuild();
        session.command(jaras::CommandKind::selectRegion,roots.front());session.command(jaras::CommandKind::play);
        w.createComponentSnapshot(w.getLocalBounds());
        int rebuilds=0;const auto changed=session.changed;
        session.changed=[&]{++rebuilds;if(changed)changed();};
        Array<var> timings;
        auto measure=[&](const String &name,const std::function<void()> &operation) {
            const auto begin=Time::getMillisecondCounterHiRes();operation();const auto done=Time::getMillisecondCounterHiRes();
            require(w.itemLayoutRevision==session.revision,"Setlist-only gesture invalidated the entire item layout");
            const auto image=w.createComponentSnapshot(w.getLocalBounds());require(image.isValid(),"Setlist gesture did not paint");
            auto row=object();put(row,"operation",name);put(row,"handlerMilliseconds",done-begin);
            put(row,"paintMilliseconds",Time::getMillisecondCounterHiRes()-done);timings.add(row);
        };
        for(int i=0;i<3;++i) {
            measure("queue",[&]{session.command(jaras::CommandKind::queueRegion,roots[1]);});
            measure("stopOn",[&]{auto next=*session.project().regionSetlist;next.stopAtRegionEnd=true;session.configureSetlist(next);});
            measure("stopOff",[&]{auto next=*session.project().regionSetlist;next.stopAtRegionEnd=false;session.configureSetlist(next);});
            measure("playlist",[&]{auto next=*session.project().regionSetlist;next.selectedId=i%2?a:b;session.configureSetlist(next);});
        }
        require(rebuilds==0,"Queue or playlist policy rebuilt unrelated track and mixer controls");
        auto report=object();put(report,"timings",timings);put(report,"workspaceRebuilds",rebuilds);put(report,"realProject",source.isNotEmpty());
        directory.getChildFile("setlist-ui-profile.json").replaceWithText(JSON::toString(report,true));
        session.command(jaras::CommandKind::stopAll);
    }
    static void tempoResponsiveness(const File &directory) {
        using floatingControlTests::require;
        const auto source=SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_PROJECT",{});
        auto project=floatingControlTests::fixture();
        if(source.isNotEmpty())project=ProjectCodec::decode(ProjectCodec::read(File(source)));
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        session.core.loadProject(project);
        if(source.isNotEmpty() && SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_AUDIO",{})=="1")
            session.audio.prepareSong(*session.song(),File(source).getParentDirectory(),{},&session.project());
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("tempo-ui-preferences",".json"));
        w.setSize(1366,900);w.projectOpened(false);w.pixelsPerSecond=4;w.rebuild();
        require(session.song()&&!session.song()->parts.empty(),"Tempo profile needs a region");
        const auto region=session.song()->parts.front().id;
        session.command(jaras::CommandKind::selectRegion,region);
        const auto initial=session.tempoBPM();
        w.createComponentSnapshot(w.getLocalBounds());
        Array<var> measurements;
        const int edits=source.isEmpty()?44:4;
        for(int step=0;step<edits;++step) {
            const auto start=Time::getMillisecondCounterHiRes();session.setTempo(initial+(step%2?0:1));
            const auto changed=Time::getMillisecondCounterHiRes();
            const auto image=w.createComponentSnapshot(w.getLocalBounds());require(image.isValid(),"Tempo update did not paint");
            auto row=object();put(row,"handler",changed-start);put(row,"paint",Time::getMillisecondCounterHiRes()-changed);measurements.add(row);
        }
        require(std::abs(session.tempoBPM()-initial)<.00001,"Tempo did not return to its original value");
        session.undo();require(std::abs(session.tempoBPM()-initial-1)<.00001,"Tempo undo did not restore preceding edit");
        session.redo();require(std::abs(session.tempoBPM()-initial)<.00001,"Tempo redo did not restore original BPM");
        if(source.isEmpty()) {
            for(int step=0;step<40;++step) {
                require(session.canUndo(),"Tempo history lost a retained edit");session.undo();
                require(std::abs(session.tempoBPM()-initial-(step%2?0:1))<.00001,"Tempo history order changed at capacity");
            }
            require(!session.canUndo(),"Tempo history exceeded the forty-edit limit");
            for(int step=0;step<40;++step)session.redo();
            require(std::abs(session.tempoBPM()-initial)<.00001&&!session.canRedo(),"Tempo redo did not restore full history");
        }
        directory.getChildFile("tempo-ui-profile.json").replaceWithText(JSON::toString(measurements,true));
    }
    static void pitchResponsiveness(const File &directory) {
        using floatingControlTests::require;
        const auto source=SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_PROJECT",{});
        auto project=floatingControlTests::fixture();
        if(source.isNotEmpty())project=ProjectCodec::decode(ProjectCodec::read(File(source)));
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        session.core.loadProject(project);
        if(source.isNotEmpty())session.audio.prepareSong(*session.song(),File(source).getParentDirectory(),{},&session.project());
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("pitch-ui-preferences",".json"));
        w.setSize(1366,900);w.projectOpened(false);w.pixelsPerSecond=4;w.rebuild();
        const auto original=session.song()->parts.front();
        session.command(jaras::CommandKind::selectRegion,original.id);
        int fullRebuilds=0;const auto changed=session.changed;
        session.changed=[&]{++fullRebuilds;if(changed)changed();};
        Array<var> measurements;
        for(bool playing:{false,true}) {
            if(playing)session.command(jaras::CommandKind::play);
            for(int semitones:{1,2,0,3,0}) {
                const auto start=Time::getMillisecondCounterHiRes();
                session.setRegionPitch(original.id,semitones,regionPitch::defaults(*session.song(),false),regionPitch::defaults(*session.song(),true));
                const auto changedAt=Time::getMillisecondCounterHiRes();
                w.createComponentSnapshot(w.getLocalBounds());
                auto row=object();put(row,"playing",playing);put(row,"semitones",semitones);
                put(row,"handler",changedAt-start);put(row,"paint",Time::getMillisecondCounterHiRes()-changedAt);measurements.add(row);
                require(session.transport().playing==playing,"Tuner changed transport state");
            }
            if(playing)session.command(jaras::CommandKind::stopAll);
        }
        require(fullRebuilds==0,"Pitch edit rebuilt unrelated track controls");
        while(session.canUndo())session.undo();
        const auto &restored=session.song()->parts.front();
        require(restored.pitchSemitones==original.pitchSemitones && restored.pitchTrackIDs==original.pitchTrackIDs && restored.pitchGroupIDs==original.pitchGroupIDs,
                "Tuner Undo did not restore inherited/default targets exactly");
        while(session.canRedo())session.redo();
        require(session.song()->parts.front().pitchSemitones==0,"Tuner Redo lost last adjustment");
        directory.getChildFile("pitch-ui-profile.json").replaceWithText(JSON::toString(measurements,true));
    }
    static void immediateTrackScroll(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();auto &tracks=project.songs.front().tracks;
        while(tracks.size()<30){auto track=tracks.front();track.id=uuid();tracks.push_back(track);}
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("track-scroll",".json"));
        w.setSize(1366,900);w.projectOpened(false);
        auto row=uiFeatureTests::find(w,"trackRow:"+text(tracks[0].id));require(row,"Mixer row missing");
        const auto rowBounds=row->getBounds();const auto contentBounds=w.tracksContent.getLocalBounds();
        auto check=[&] {
            require(w.verticalOffset==w.tracksViewport.getViewPositionY(),"Track viewport and workspace scroll diverged");
            require(num(get(w.diagnostics(),"timeline"),"vertical")==w.verticalOffset,"Grid scroll waited for the workspace status timer");
            require(row->getBounds()==rowBounds && w.tracksContent.getLocalBounds()==contentBounds,"Scrolling rebuilt row geometry");
        };
        w.tracksViewport.setViewPosition(0,60);check();
        const auto at=w.tracksViewport.getBounds().getCentre().toFloat();
        const auto event=[&](int flags=0){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(flags),
            1,0,0,0,0,&w,&w,Time::getCurrentTime(),at,Time::getCurrentTime(),1,false);};
        MouseWheelDetails wheel{};wheel.deltaY=-.1f;
        w.mouseWheelMove(event(),wheel);
        require(w.verticalOffset==60,"Discrete wheel jumped before its first smooth frame");
        // One 16 ms message pump can end before a 60 Hz timer's first frame;
        // a busy runner can instead finish the entire 110 ms animation.
        const auto firstFrame=Time::getMillisecondCounterHiRes()+500;
        while(w.verticalOffset==60 && Time::getMillisecondCounterHiRes()<firstFrame)floatingControlTests::pump();
        check();
        require(w.verticalOffset>60 && w.verticalOffset<=90,"Discrete wheel did not animate a single 30-pixel step");
        const auto deadline=Time::getMillisecondCounterHiRes()+300;
        while(Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        check();require(w.verticalOffset==90,"Wheel was applied twice or did not reach its target");
        wheel.isSmooth=true;wheel.deltaY=-.001f;
        for(int i=0;i<10;++i)w.mouseWheelMove(event(),wheel);
        check();require(w.verticalOffset==93,"Precise wheel lost fractional movement");
        wheel.isSmooth=false;wheel.deltaY=-.1f;w.mouseWheelMove(event(),wheel);
        w.mixerDivider.scrollTo(150);check();
        const auto afterThumb=Time::getMillisecondCounterHiRes()+150;
        while(Time::getMillisecondCounterHiRes()<afterThumb)floatingControlTests::pump();
        check();require(w.verticalOffset==150,"An old wheel animation overrode a scrollbar drag");
        auto *grid=uiFeatureTests::find(w,"timelineCanvas");require(grid,"Timeline canvas missing");
        const auto gridPoint=grid->getLocalBounds().toFloat().getCentre();
        const auto now=Time::getCurrentTime();
        const auto altWheel=MouseEvent(Desktop::getInstance().getMainMouseSource(),gridPoint,ModifierKeys(ModifierKeys::altModifier),
            1,0,0,0,0,grid,grid,now,gridPoint,now,1,false);
        const auto zoom=w.pixelsPerSecond;
        wheel.isSmooth=true;grid->mouseWheelMove(altWheel,wheel);
        check();require(w.verticalOffset==180&&w.pixelsPerSecond==zoom,"Alt + touchpad must scroll the grid vertically");
        const int height=w.trackHeight;wheel.deltaY=.2f;
        w.mouseWheelMove(event(ModifierKeys::ctrlModifier),wheel);
        require(w.trackHeight>height,"Ctrl wheel no longer adjusts track height");
        require(w.verticalOffset==w.tracksViewport.getViewPositionY(),"Changing track height desynchronized scroll");
        w.selectedTracks.clear(); w.selectedTrack.clear();
        w.mixerDivider.scrollTo(w.rowTop(8) + w.rowHeight(8) / 2);
        const double clippedFraction = double(w.verticalOffset-w.rowTop(8))/w.rowHeight(8);
        wheel.deltaY=.5f; w.mouseWheelMove(event(ModifierKeys::ctrlModifier),wheel);
        require(std::abs(w.verticalOffset-w.rowTop(8)-clippedFraction*w.rowHeight(8))<=1,
                "Unselected height zoom moved the first visible row");
        w.selectedTrack=tracks[11].id;w.selectedTracks={w.selectedTrack};
        const int selectedY=w.rowTop(11)-w.verticalOffset;
        for(float delta:{.3f,-.6f,.3f}) {
            wheel.deltaY=delta;w.mouseWheelMove(event(ModifierKeys::ctrlModifier),wheel);
            require(w.rowTop(11)-w.verticalOffset==selectedY,"Height zoom did not anchor the selected track");
            require(w.verticalOffset==w.tracksViewport.getViewPositionY(),"Height zoom separated grid and mixer");
        }

    }
    static void trackTail(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();auto &tracks=project.songs.front().tracks;
        while(tracks.size()<30){auto track=tracks.front();track.id=uuid();track.name="Track "+std::to_string(tracks.size());tracks.push_back(track);}
        jaras::AudioClip clip;clip.id=uuid();clip.name="Retained grid selection";clip.duration=3;
        tracks.front().clips.push_back(clip);
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("track-tail",".json"));w.setSize(1366,900);w.projectOpened(false);
        require(w.tracksContent.getHeight()-w.rowTop((int)tracks.size())==w.trackHeight*2,"Empty track tail differs from Mac's two rows");
        w.selectMixerTrack(tracks[0].id,ModifierKeys{});
        w.selectMixerTrack(tracks[1].id,ModifierKeys(ModifierKeys::ctrlModifier));
        const auto event=[&](Component &target,Point<float> at,int flags=ModifierKeys::leftButtonModifier){
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(flags),1,0,0,0,0,
                              &target,&target,Time::getCurrentTime(),at,Time::getCurrentTime(),1,false);
        };
        const auto selected=w.selectedTracks;
        const Point<float> blank{20.0f,(float)w.rowTop((int)tracks.size())+10.0f};
        w.mouseDown(event(w.tracksContent,blank,ModifierKeys::rightButtonModifier));
        require(w.selectedTracks==selected,"Context click cleared track selection");
        w.mouseDown(event(w.tracksContent,{20,10}));
        require(w.selectedTracks==selected,"Blank-tail handler consumed a track row click");
        w.mouseDown(event(w.addTrack,{5,5}));
        require(w.selectedTracks==selected,"A mixer control cleared the selected tracks");
        w.selectedClip=clip.id;w.selectedClips={w.selectedClip};
        w.mouseDown(event(w.tracksContent,blank));
        require(w.selectedTracks.empty()&&w.selectedTrack.empty()&&w.trackSelectionAnchor.empty(),
                "Clicking empty mixer space did not clear tracks and the Shift-selection anchor");
        require(w.selectionAreas.activeScope()=="tracks"&&w.selectedClip==clip.id,
                "Empty mixer click changed another panel's selection or lost Delete ownership");
        const auto count=session.song()->tracks.size();
        w.keyPressed(KeyPress(KeyPress::deleteKey));
        require(session.song()->tracks.size()==count,"Delete after deselection removed a stale track");
        require(session.song()->tracks.front().clips.size()==1,"Delete after a blank mixer click leaked into the grid selection");
        const int offset=w.tracksContent.getHeight()-w.tracksViewport.getViewHeight();
        w.verticalOffset=offset;w.tracksViewport.setViewPosition(0,offset);
        w.tracksViewport.selection.mouseDoubleClick(event(w.addTrack,{5,5}));
        w.tracksViewport.selection.mouseDoubleClick(event(w.tracksContent,blank,ModifierKeys::rightButtonModifier));
        w.tracksViewport.selection.mouseDoubleClick(event(w.tracksContent,blank,ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier));
        require(session.song()->tracks.size()==count,"Control or modified double-click created a track");
        w.tracksViewport.selection.mouseDoubleClick(event(w.tracksContent,blank));w.rebuild();
        require(session.song()->tracks.size()==31,"Double-click track command did not append a track");
        require(w.verticalOffset==offset&&w.tracksViewport.getViewPositionY()==offset,"Appending a track jumped to the top");
    }
    static void setlistBlockDeletion(const File &directory) {
        using floatingControlTests::require;
        auto project = floatingControlTests::fixture();
        auto &song = project.songs.front();
        jaras::AudioClip clip; clip.id = uuid(); clip.name = "Retained item"; clip.duration = 5;
        song.tracks.front().clips = {clip};
        song.markers = std::vector<jaras::TimelineMarker>{{uuid(), "Verse", 2, 0x54ff93}};
        jaras::RegionSetlist state; const ID playlist = uuid(), other = uuid(), block = uuid(), otherBlock = uuid();
        state.selectedId = playlist;
        state.playlists = {{playlist, "Show", song.id, {song.parts[0].id, song.parts[1].id}},
                           {other, "Other", song.id, {song.parts[1].id}}};
        state.blocks = std::vector<jaras::SetlistBlock>{{block, song.id, playlist, "Opening", 0x54ff93, song.parts[0].id},
                                                       {otherBlock, song.id, other, "Other", 0x54ff93, song.parts[1].id}};
        project.regionSetlist = state;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session, auth, lighting, false, directory.getNonexistentChildFile("setlist-block-delete", ".json"));
        w.setSize(1366, 900); w.projectOpened(false);
        auto *panel = uiFeatureTests::find(w, "setlistPanel"); require(panel, "Setlist panel is missing");
        auto *rows = dynamic_cast<SetlistRows *>(uiFeatureTests::find(w, "setlistRows"));
        require(rows && rows->getModel() && rows->getModel()->getNumRows() == 3, "Playlist fixture must contain a block and two songs");
        rows->selectRow(0);
        const auto payload = rows->getModel()->getDragSourceDescription(rows->getSelectedRows());
        require(list(get(payload, "ids")).size() == 1 && list(get(payload, "ids"))[0].toString() == text(block),
                "Block row is excluded from its drag payload");
        require(rows->createDragPreview().getImage().getHeight() == 34, "Block drag must use the same compact title strip as songs");
        auto *target = dynamic_cast<DragAndDropTarget *>(panel); require(target, "Setlist drop target is missing");
        const auto priorDrag = JSON::toString(session.snapshot());
        const auto end = panel->getLocalPoint(rows, Point<int>(20, rows->rowTop(3) + 6));
        DragAndDropTarget::SourceDetails drop(payload, rows, end);
        require(target->isInterestedInDragSource(drop), "Setlist rejects dragging its own block");
        target->itemDropped(drop);
        require(!session.project().regionSetlist->blocks->front().beforeRegionId &&
                session.project().regionSetlist->playlists.front().regionIds == state.playlists.front().regionIds,
                "Dropping a block at the end moved its songs or failed to move the block");
        session.undo(); w.rebuild();
        require(JSON::toString(session.snapshot()) == priorDrag, "Undo did not restore block drag order");
        w.selectMixerTrack(song.tracks[0].id, ModifierKeys{});
        w.selectedClip = clip.id; w.selectedClips = {clip.id};
        rows->selectRow(0); w.selectionAreas.activate(*panel);
        const auto before = JSON::toString(session.snapshot());
        const auto songsBefore = JSON::toString(get(session.snapshot(), "songs"));
        const auto request = [&] {
            w.keyPressed(KeyPress(KeyPress::deleteKey)); floatingControlTests::pump();
            auto *alert = dynamic_cast<ModalSheet *>(Component::getCurrentlyModalComponent());
            require(alert && uiFeatureTests::find(*alert, "confirmationPanel") &&
                    alert->getName() == localization::translate("Delete selected blocks?"),
                    "Delete did not target the selected block or showed the region deletion warning");
            return alert;
        };
        const auto respond = [&](Component *sheet, bool accepted) {
            auto *button = dynamic_cast<Button *>(uiFeatureTests::find(*sheet, accepted ? "confirmationAccept" : "confirmationCancel"));
            require(button && button->onClick, "Confirmation choice is missing");
            button->onClick(); for (int i=0;i<4;++i) floatingControlTests::pump();
        };
        respond(request(), false);
        require(JSON::toString(session.snapshot()) == before && rows->getSelectedRows().contains(0), "Cancel removed the block or cleared its selection");
        respond(request(), true);
        require(session.project().regionSetlist->blocks->size() == 1 &&
                session.project().regionSetlist->blocks->front().id == otherBlock, "Delete did not remove only the selected block");
        require(JSON::toString(get(session.snapshot(), "songs")) == songsBefore &&
                session.project().regionSetlist->playlists.front().regionIds == state.playlists.front().regionIds,
                "Deleting a block removed songs, audio, markers or a stale track/grid selection");
        w.keyPressed(KeyPress(KeyPress::spaceKey));
        require(session.transport().playing, "A deleted block left Play blocked");
        session.command(jaras::CommandKind::stopAll);
        session.undo(); w.rebuild();
        require(JSON::toString(session.snapshot()) == before, "One Undo did not restore the complete block metadata");
        rows->selectRow(0); w.selectionAreas.activate(*panel);
        auto *pending = request();
        auto changed = *session.project().regionSetlist; changed.selectedId = other;
        session.configureSetlist(changed); respond(pending, true);
        require(session.project().regionSetlist->blocks->size() == 2, "A stale confirmation deleted a block after switching playlists");
    }
    static void setlistBlockMIDI(const File &directory) {
        using floatingControlTests::require;
        auto project = floatingControlTests::fixture();
        const auto song = project.songs.front();
        const ID a = song.parts[0].id, b = song.parts[1].id, playlist = uuid(), other = uuid();
        const ID first = uuid(), second = uuid(), consecutive = uuid(), tail = uuid();
        jaras::RegionSetlist state; state.selectedId = playlist;
        state.playlists = {{playlist,"First playlist",song.id,{a,b}}, {other,"Second playlist",song.id,{b,a}}};
        // Persisted metadata order and names intentionally disagree with the visible block order.
        state.blocks = std::vector<jaras::SetlistBlock>{{second,song.id,playlist,"Bloco 01",0x54ff93,b},
            {first,song.id,playlist,"Renamed 99",0x54ff93,a},
            {consecutive,song.id,playlist,"Empty consecutive block",0x54ff93,a},
            {tail,song.id,playlist,"Tail",0x54ff93,std::nullopt},
            {uuid(),song.id,other,"Different project-style name",0x54ff93,b}};
        project.regionSetlist = state;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("setlist-block-midi-workspace",".json"));
        w.setSize(1366,900); w.projectOpened(false);
        auto midi = object(); put(midi,"status",0xb0);put(midi,"number",48);put(midi,"channel",4);
        require(w.actions.assign("setlistBlock:1","midi",midi),"Could not map the first block");
        auto trigger = [&] {
            ActionBindingsTestAccess::receive(w.actions,MidiMessage::controllerEvent(4,48,0));
            ActionBindingsTestAccess::receive(w.actions,MidiMessage::controllerEvent(4,48,127));
        };
        session.command(jaras::CommandKind::selectRegion,b);
        const auto songData = JSON::toString(get(session.snapshot(),"songs"));
        trigger();
        require(session.transport().regionId == a && !session.transport().playing && session.transport().editPosition == 0,
                "Block MIDI used its name/metadata index instead of the visible ordinal, or started playback");
        require(w.selectionAreas.activeScope() == "setlist", "Block MIDI did not select the same area as a song click");
        w.performAction("setlistBlock:3",1,0);
        require(session.transport().regionId == b && !session.transport().playing,"Third block did not select its first song");
        w.performAction("setlistBlock:1",1,0);
        require(session.transport().regionId == a,"Consecutive empty block prevented selecting the first song below");
        w.performAction("setlistBlock:4",1,0); w.performAction("setlistBlock:1000",1,0);
        require(session.transport().regionId == a && !session.transport().playing,"Trailing or missing block changed the selection");
        session.command(jaras::CommandKind::play);
        w.performAction("setlistBlock:3",1,0);
        require(session.transport().playing && session.transport().regionId == a && session.transport().queuedRegionId == b,
                "During playback block MIDI did not use the normal song queue");
        session.command(jaras::CommandKind::stopAll);
        auto changed = *session.project().regionSetlist; changed.selectedId = other;
        session.configureSetlist(changed); w.rebuild(); trigger();
        require(session.transport().regionId == b && !session.transport().playing,"Global mapping kept a block UUID from the previous playlist");
        changed = *session.project().regionSetlist; changed.selectedId = playlist;
        require(playlistOccurrences::moveEntries(changed,song.id,playlist,{first,consecutive},std::nullopt),"Could not reorder block test fixture");
        session.configureSetlist(changed); w.rebuild(); trigger();
        require(session.transport().regionId == b && !session.transport().playing,"MIDI ordinal did not follow reordered blocks");
        require(JSON::toString(get(session.snapshot(),"songs")) == songData,"Learning or triggering a block modified project media");
        auto otherProject = floatingControlTests::fixture();
        const auto otherSong = otherProject.songs.front(); const ID otherPlaylist = uuid();
        jaras::RegionSetlist fresh; fresh.selectedId = otherPlaylist;
        fresh.playlists = {{otherPlaylist,"Another project",otherSong.id,{otherSong.parts[0].id,otherSong.parts[1].id}}};
        fresh.blocks = std::vector<jaras::SetlistBlock>{{uuid(),otherSong.id,otherPlaylist,"Fresh block",0x54ff93,otherSong.parts[1].id}};
        otherProject.regionSetlist = fresh;
        session.restoreSnapshot(ProjectCodec::encode(otherProject)); w.projectOpened(false); trigger();
        require(session.transport().regionId == otherSong.parts[1].id && !session.transport().playing,
                "Global block mapping did not resolve the current project's first block");
    }
    static void textEditor(const File &directory) {
        using floatingControlTests::require;
        for (const auto *role : {"teleprompt", "chords"}) {
            auto project=floatingControlTests::fixture();
            auto &track=project.songs.front().tracks.front();
            track.role.id=role;track.name=jaras::fixedTrackName(track.role);
            jaras::AudioClip clip;clip.id=uuid();clip.name="Text";clip.duration=10;clip.text="Original";
            track.clips={clip};
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);
            Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("text-window",".json"));
            struct Host : DocumentWindow {
                Host():DocumentWindow("CatLive",theme::background,allButtons){}
                void closeButtonPressed() override {}
            } host;
            host.setContentNonOwned(&w,false);host.setBounds(40,40,1100,750);host.setVisible(true);w.projectOpened(false);
            w.showTeleprompter(1);w.updateState();floatingControlTests::pump();
            auto *projection=w.floatingWindows.at("Teleprompter 1").get();
            const auto handle=static_cast<HWND>(projection->getPeer()->getNativeHandle());
            const auto owner=GetWindowLongPtrW(handle,GWLP_HWNDPARENT);
            w.editTextItem(clip.id);w.updateState();floatingControlTests::pump();
            auto *editor=w.floatingWindows.at("Editor de texto").get();
            require(editor->isVisible()&&projection->isVisible()&&Component::getCurrentlyModalComponent()==nullptr,
                    "Text editor hid the projection or became a workspace-blocking modal");
            require(owner == 0 && GetWindowLongPtrW(handle, GWLP_HWNDPARENT) == 0,
                    "Teleprompter must keep its independent window while an editor is open");
            TextEditor *input=nullptr;Button *apply=nullptr,*cancel=nullptr;
            for(auto *child:editor->getContentComponent()->getChildren()) {
                if(auto *text=dynamic_cast<TextEditor*>(child))input=text;
                if(auto *button=dynamic_cast<Button*>(child)) {
                    if(button->getButtonText()=="Aplicar")apply=button;
                    if(button->getButtonText()=="Cancelar")cancel=button;
                }
            }
            require(input&&apply&&cancel,"Text editing controls missing");
            input->setText("Updated\nAm G");floatingControlTests::pump();
            require(*session.song()->tracks.front().clips.front().text=="Original","Typing changed the item before Apply");
            w.editTextItem(clip.id);require(w.floatingWindows.at("Editor de texto").get()==editor&&input->getText()=="Updated\nAm G","Reopening replaced the unfinished draft");
            input->setHighlightedRegion({0,7});
            const auto now=Time::getCurrentTime();
            input->mouseDown(MouseEvent(Desktop::getInstance().getMainMouseSource(),{20,20},
                ModifierKeys(ModifierKeys::rightButtonModifier),1,0,0,0,0,input,input,now,{20,20},now,1,false));
            floatingControlTests::pump();
            auto *palette=Component::getCurrentlyModalComponent();
            require(palette!=nullptr,"Selected text did not open the colour palette");
            Button *colour=nullptr;
            std::function<void(Component*)> findColour=[&](Component *node){
                if(auto *button=dynamic_cast<Button*>(node);button && button->getTooltip().startsWith("#"))colour=button;
                for(auto *child:node->getChildren())findColour(child);
            };
            findColour(palette);require(colour!=nullptr,"Colour choices missing");
            colour->onClick();floatingControlTests::pump();
            require(Component::getCurrentlyModalComponent()==nullptr && editor->isVisible() && projection->isVisible(),
                    "Choosing text colour closed the editor or projection");
            require(input->getText()=="Updated\nAm G" && *session.song()->tracks.front().clips.front().text=="Original",
                    "Choosing colour prematurely applied or changed the draft text");
            apply->onClick();floatingControlTests::pump();
            require(!editor->isVisible()&&projection->isVisible()&&ItemTextColors::plain(text(*session.song()->tracks.front().clips.front().text))=="Updated\nAm G","Apply failed to commit and close only the text editor");
            session.undo();require(*session.song()->tracks.front().clips.front().text=="Original","Text edit could not be undone");
            w.editTextItem(clip.id);editor=w.floatingWindows.at("Editor de texto").get();
            editor->closeButtonPressed();require(projection->isVisible(),"Cancel closed the projection");
            host.clearContentComponent();
        }
    }
    static void run(const File &directory) {
        using floatingControlTests::require;
        const auto preferences=directory.getNonexistentChildFile("global-workspace-layout",".json");
        auto project=floatingControlTests::fixture();
        Session first; first.inspection=true; first.audio.prepareOffline(48000);
        first.restoreSnapshot(ProjectCodec::encode(project)); first.audio.setOffline(true);
        Auth auth; Lighting lighting(first);
        Workspace a(first,auth,lighting,false,preferences);a.setSize(1366,900);a.projectOpened(false);
        const auto before=JSON::toString(first.snapshot());
        a.mixerVisible=false;a.mixerWidth=410;a.setlistWidth=370;a.partsLeftWidth=290;
        a.mixerHeightSetting=410;a.partsRightVisible=true;
        a.setSetlistPlacement(Workspace::SetlistPlacement::detached);
        a.detachLeftParts();a.showDetachedMixer();
        const juce::Rectangle<int> frame(30,40,680,430);
        a.floatingWindows.at("Mixer")->setBounds(frame);
        a.floatingWindows.at("Parts")->setBounds(frame.withX(80));
        a.setlistWindow->setBounds(frame.withX(130));
        a.saveWorkspaceLayout();a.deactivateProjectTab();
        require(!a.floatingWindows.at("Mixer")->isVisible()&&!a.floatingWindows.at("Parts")->isVisible()&&!a.setlistWindow->isVisible(),"Background project left its floating panels visible");
        Session second;second.inspection=true;second.audio.prepareOffline(48000);
        project.id=uuid();second.restoreSnapshot(ProjectCodec::encode(project));second.audio.setOffline(true);
        Lighting otherLighting(second);Workspace b(second,auth,otherLighting,false,preferences);
        b.setSize(1366,900);b.projectOpened(false);
        require(!b.mixerVisible&&b.mixerWidth==410&&b.partsLeftWidth==290&&b.mixerHeightSetting==410,"Panel dimensions and visibility did not transfer to another project");
        require(b.mixerDetached&&b.partsLeftDetached&&b.setlistPlacement==Workspace::SetlistPlacement::detached,"Docking belongs to the project instead of global preferences");
        require(b.floatingWindows.at("Mixer")->getBounds()==frame&&b.floatingWindows.at("Parts")->getBounds()==frame.withX(80)&&b.setlistWindow->getBounds()==frame.withX(130),"Detached window frames were not restored");
        b.openVideo();require(b.floatingWindows.at("Video")->isVisible(),"Video did not open");
        b.openVideo();require(!b.floatingWindows.at("Video")->isVisible(),"Video toolbar failed to toggle closed");
        b.focusVisible=true;b.resized();
        const auto focus=b.focusMixer->getBounds();
        require(b.focusMixer->isVisible()&&focus.getY()==b.workspaceBounds.getY()&&focus.getWidth()==MixerPanel::focusWidth(),
                "Focus must keep its channel widths below the transport");
        b.focusVisible=false;b.resized();
        b.mixerVisible=true;b.mixerWidth=480;b.floatingWindows.at("Mixer")->setBounds(frame.withWidth(760));
        b.saveWorkspaceLayout();b.deactivateProjectTab();a.activateProjectTab();
        require(a.mixerVisible&&a.mixerWidth==480&&a.floatingWindows.at("Mixer")->getWidth()==760,"Returning to an existing tab restored its stale project layout");
        require(JSON::toString(first.snapshot())==before,"Global panel preferences modified the project");
    }
};
namespace workspaceLayoutTests {
template<class Test> void registerTests(const File &directory,Test &test) {
    test("Ctrl-click M and S clears all 200 tracks in Track Mixer and docked or detached Hoz-Mixer",[&]{WorkspaceLayoutTests::ctrlClearMixerButtons(directory);});
    test("Duplicated waveform rasters share pixels through scrolling and exact zoom without sharing edits",[&]{WorkspaceLayoutTests::sharedWaveformRaster(directory);});
    test("Export selection follows Track Mixer and Hoz Mixer while the window stays open",[&]{WorkspaceLayoutTests::exportMixerSelection(directory);});
    if(SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_PROJECT",{}).isNotEmpty())
        test("Overview zoom profile on an isolated real project",[&]{WorkspaceLayoutTests::overviewProfile(directory);});
    test("Project replacement saves edits before continuing and Cancel preserves them",[&]{WorkspaceLayoutTests::projectReplacement(directory);});
    test("Recording live waveform is visible in compact tracks before Stop",[&]{WorkspaceLayoutTests::liveRecordingWaveform(directory);});
    test("MIDI item export preserves trimmed notes and channels while muted",[&]{
        using floatingControlTests::require;
        jaras::AudioClip clip;clip.id=uuid();clip.name="Keys";clip.startTime=10;clip.duration=1.5;clip.sourceOffset=1;clip.playbackRate=2;clip.muted=true;clip.gain=0;
        clip.midi.emplace();clip.midi->sourceBPM=120;
        jaras::MIDINote a;a.id=uuid();a.start=0;a.length=4;a.pitch=60;a.velocity=80;a.channel=3;
        auto b=a;b.id=uuid();b.start=4;b.pitch=64;b.channel=16;b.velocity=100;clip.midi->notes={a,b};
        auto file=directory.getNonexistentChildFile("export-item",".mid");exportMIDIItem(clip,file);
        FileInputStream input(file);MidiFile parsed;require(parsed.readFrom(input),"Unreadable MIDI file");parsed.convertTimestampTicksToSeconds();
        std::vector<MidiMessage> notes;for(int t=0;t<parsed.getNumTracks();++t)for(int i=0;i<parsed.getTrack(t)->getNumEvents();++i){auto m=parsed.getTrack(t)->getEventPointer(i)->message;if(m.isNoteOn()||m.isNoteOff())notes.push_back(m);}
        require(notes.size()==4,"MIDI notes were lost");require(notes[0].getChannel()==3&&notes[2].getChannel()==16,"MIDI channels changed");
        require(std::abs(notes.front().getTimeStamp())<.001&&std::abs(notes.back().getTimeStamp()-1.5)<.001,"MIDI trim or rate changed");
        file.deleteFile();
    });
    test("Split selects right halves for single multiple and empty selections",[&]{WorkspaceLayoutTests::splitSelection(directory);});
    test("Workspace divider margins match Mac without shrinking track controls",[&]{WorkspaceLayoutTests::dividerMargins(directory);});
    test("Track icons stay inside the mixer without widening the track column",[&]{WorkspaceLayoutTests::trackIconWidth(directory);});
    test("Track Mixer minimum keeps Patch and both mixers rename in place",[&]{WorkspaceLayoutTests::mixerNamesAndMinimumWidth(directory);});
    test("Deleting another recent project during playback preserves the current dirty project and audio clock",[&]{WorkspaceLayoutTests::deleteRecentWhilePlaying(directory);});
    test("Item context and Actions process full audio selections with channel conversion, Re-render, Normalize, Unify and Undo",[&]{WorkspaceLayoutTests::unifyItems(directory);});
    test("Item context export includes selected audio across tracks, ignores non-audio and locks bounds",[&]{WorkspaceLayoutTests::exportItems(directory);});
    test("Generated MIDI and text items advance edit cursor without seeking playback",[&]{WorkspaceLayoutTests::generatedItems(directory);});
    test("Setlist transport gestures retain grid geometry and avoid workspace rebuilds",[&]{WorkspaceLayoutTests::setlistResponsiveness(directory);});
    test("Tuner gestures retain the project and audio graph while playing and stopped",[&]{WorkspaceLayoutTests::pitchResponsiveness(directory);});
    test("Tempo gestures update grid and preserve Undo and Redo",[&]{WorkspaceLayoutTests::tempoResponsiveness(directory);});
    test("Track Mixer wheel thumb and grid scroll stay synchronized without rebuilding rows",[&]{WorkspaceLayoutTests::immediateTrackScroll(directory);});
    test("Repeated multi-track paste selects the last copy and immediately reveals it in both 900-track mixers while retaining controls",[&]{WorkspaceLayoutTests::duplicateTrackFollow(directory);});
    test("Keyboard right click opens the keyboard settings sheet",[&]{WorkspaceLayoutTests::keyboardContextSettings(directory);});
    test("Native transport repairs externally displaced input bounds",[&]{WorkspaceLayoutTests::transportHitBounds(directory);});
    test("Fullscreen transport keeps controls, Master drawing and native hit areas aligned",[&]{WorkspaceLayoutTests::fullscreenTransport(directory);});
    test("Performance dock geometry with Hoz Mixer Pads and MIDI Preview",[&]{WorkspaceLayoutTests::performanceDockPositions(directory);});
    test("Toolbar symbols and timer fit with accessible labels",[&]{WorkspaceLayoutTests::toolbarTimerAndLabels(directory);});
    test("Stopped transport shows a dash without a selected region",[&]{WorkspaceLayoutTests::transportRegionDisplay(directory);});
    test("Settings order and immediate theme repaint",[&]{WorkspaceLayoutTests::settingsThemeParity(directory);});
    test("Advanced remains above workspace without blocking controls",[&]{WorkspaceLayoutTests::toolWindowOrdering(directory);});
    test("Empty track tail matches Mac and appending preserves vertical scroll",[&]{WorkspaceLayoutTests::trackTail(directory);});
    test("Setlist block Delete and drag follow last area, keep songs and media, support cancel and Undo, and reject stale confirmations",[&]{WorkspaceLayoutTests::setlistBlockDeletion(directory);});
    test("Setlist block MIDI follows the current playlist ordinal and normal song selection or queue",[&]{WorkspaceLayoutTests::setlistBlockMIDI(directory);});
    test("Lyrics and chord editors retain visible projections, drafts and undo",[&]{WorkspaceLayoutTests::textEditor(directory);});
    test("Panel layout survives new workspaces and tab switches without changing projects; Focus and Video toggle stay independent",[&]{WorkspaceLayoutTests::run(directory);});
}
}
}
