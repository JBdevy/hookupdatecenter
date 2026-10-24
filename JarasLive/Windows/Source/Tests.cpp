#include "ProjectionSelection.h"
#include "MediaSource.h"
#include "MarkerRegionConversion.h"
#include "Workspace.h"
#include "StartupSplash.h"
#include "TrackTree.h"
#include "ClipAudio.h"
#include "ResolumeComposition.h"
#include "LightingRegionTests.h"
#include "ClipEditing.h"
#include "Normalization.h"
#include "MIDIEditing.h"
#include "MediaCleanup.h"
#include "RemoteCipher.h"
#include "RemoteTransport.h"
#include "RemoteHost.h"
#include "RemotePresentation.h"
#include "LicenseProof.h"
#include "TimelineGrid.h"
#include "TimelineBulkEditing.h"
#include "WaveformRenderer.h"
#include "RegionEditing.h"
#include "ClickTempo.h"
#include "MP3Writer.h"
#include "TeleprompterHTTP.h"
#include "TempoEditing.h"
#include "MeterDisplay.h"
#include "StageTimerSettings.h"
#include "MixerPanel.h"
#include "DesktopLayout.h"
#include "ProjectOpenConfirmationPanel.h"
#include "BPMInputPanel.h"
#include "SettingsPanel.h"
#include "EffectsPanel.h"
#include "CatDynamicsTests.h"
#include "NativeFXPreviewTests.h"
#if CATLIVE_NATIVE_FRONTEND
#include "FrontendBridgeTests.h"
#include "NativeFrontendWaveformsTests.h"
#endif
#include "EQAnalysisTests.h"
#include "FXChain.h"
#include "ItemRender.h"
#include "SetlistShareText.h"
#include "ProjectDeletionPanel.h"
#include "ShowMode.h"
#include "PortablePackage.h"
#include "TimelinePlaybackFollow.h"
#include "RecordingProject.h"
#include "TrackEditing.h"
#include "TrackDuplicationTests.h"
#include "RecordingCaptureTests.h"
#include "VinhetasTests.h"
#include "ProjectReductionTests.h"
#include "TransportFadeoutTests.h"
#include "ActionBindingsTests.h"
#include "UIFeatureTests.h"
#include "PartsPanelTests.h"
#include "StemGraphTests.h"
#include "MediaImportTests.h"
#include "GridMediaClipboardTests.h"
#include "FloatingControlTests.h"
#include "ProjectOpenTests.h"
#include "NavigationParityTests.h"
#include "ProjectBrowserLoadingTests.h"
#include "BPMDetectionTests.h"
#include "SectionMarkerTests.h"
#include "ReaperImportParityTests.h"
#include "MIDITakePlaybackTests.h"
#include "RegionLaneTests.h"
#include "MasterMixerTests.h"
#include "WorkspaceLayoutTests.h"
#include "WorkspaceSetlistPresentationTests.h"
#include "SetlistSearchTests.h"
#include "RemoteSetlistSelectionTests.h"
#include "TrackVisibilityTests.h"
#include "LiveItemResizeTests.h"
#include "LiveSessionEditTests.h"
#include "StreamingReaderTests.h"
#include "AudioGainRenderTests.h"
#include "ClipAudioReadTests.h"
#include "LongTimelineAudioTests.h"
#include "TimelineMarqueeTests.h"
#include "TimelineVisualParityTests.h"
#include "ItemLocalGeometryTests.h"
#include "HozMixerFocusTests.h"
#include "CompactTextBaselineTests.h"
#include "InstrumentRenderTests.h"
namespace catlive {
namespace {
void expect(bool condition, const String &message) {
    if (!condition)
        throw std::runtime_error(utf8(message));
}
jaras::Project projectFixture() {
    jaras::Project p;
    p.id = uuid();
    p.name = "São João Show";
    p.createdAt = p.updatedAt = "2026-10-14T12:00:00.000Z";
    jaras::Song s;
    s.id = uuid();
    s.name = "Show";
    s.duration = 40;
    s.bpm = 120;
    s.parts = {{uuid(), "Música Teste", 10, 20}, {uuid(), "Outra Música", 30, 40}};
    s.markers = std::vector<jaras::TimelineMarker>{{uuid(), "Refrão", 12, 0xffdc52}};
    jaras::Track track;
    track.id = uuid();
    track.name = "Piano";
    track.role.id = "keys";
    track.volume = .73;
    track.pan = -.2;
    track.phaseInverted = true;
    track.heightScale = 1.25;
    track.outputs = std::vector<jaras::OutputPatch>{{0, 2}, {3, 2}};
    jaras::AudioClip clip;
    clip.id = uuid();
    clip.name = "Piano take";
    clip.startTime = 10;
    clip.duration = 8;
    clip.sourceOffset = 1;
    clip.audioFile = jaras::AudioFile{"Stems/Piano.wav", {}};
    clip.waveform = {.1, .4, .2};
    clip.gain = .7;
    clip.fadeIn = .25;
    clip.fadeOut = .5;
    track.clips.push_back(clip);
    s.tracks.push_back(track);
    p.savedCursor = jaras::SavedProjectCursor{s.id, 12.5};
    p.masterOutputs = std::vector<jaras::OutputPatch>{{3, 2}, {1, 1}};
    p.songs.push_back(s);
    p.setlists.push_back({uuid(), "Show", {s.id}});
    return p;
}
} // namespace
int runTests(const File &directory) {
    directory.createDirectory();
    StringArray passed, skipped;
    String failed;
    const auto filter=SystemStats::getEnvironmentVariable("CATLIVE_TEST_FILTER",{});
    auto test = [&](const String &name, const std::function<void()> &work) {
        if(filter.isNotEmpty()&&!name.containsIgnoreCase(filter)){skipped.add(name);return;}
        directory.getChildFile("progress.log").appendText("RUN " + name + "\n");
        try {
            work();
            directory.getChildFile("progress.log").appendText("PASS " + name + "\n");
            passed.add(name);
        } catch (const std::exception &e) {
            directory.getChildFile("progress.log").appendText("FAIL " + name + ": " + String::fromUTF8(e.what()) + "\n");
            failed += name + ": " + String::fromUTF8(e.what()) + "\n";
        }
    };
    test("Automatic access checks preserve activation on token expiry and enforce quarantine",[&]{
        for(const String code:{String(),String("invalidSession"),String("unavailable"),String("quarantined")}) {
            const auto folder=directory.getNonexistentChildFile("access-policy-"+code,"");folder.createDirectory();
            std::atomic<int> calls{0};std::atomic<bool> correctRoute{true};
            Auth auth(folder,[&](const String &route,const var &body,const String &)->var {
                ++calls;if(route!="access-status" || str(body,"refreshToken")!="test-refresh")correctRoute=false;
                if(code.isNotEmpty())throw Auth::ServiceFailure(code,"Test "+code);
                return object();
            });
            auto saved=object(),session=object();put(session,"refreshToken","test-refresh");put(saved,"session",session);auth.loginData=saved;
            const auto cache=folder.getChildFile("session.dat");expect(cache.replaceWithText("preserved-encrypted-cache"),"Cannot write fixture");
            auth.checkOnlineAccess();
            for(int i=0;i<200 && auth.busy;++i)floatingControlTests::pump();
            expect(!auth.busy && calls==1 && correctRoute,"Automatic check rotated tokens or failed to finish");
            if(code=="quarantined") {
                expect(!cache.existsAsFile() && !auth.loginData.isObject() && folder.getChildFile("quarantine.dat").existsAsFile(),"Quarantine did not revoke and persist the block");
                Auth restarted(folder);restarted.restore();expect(!restarted.allowed() && restarted.message.isNotEmpty(),"Quarantine disappeared on restart");
            } else expect(cache.loadFileAsString()=="preserved-encrypted-cache" && auth.loginData.isObject(),"Expired tokens or network errors erased device activation");
        }
    });
    test("Login window is compact and clamped inside Windows work area",[]{
        DocumentWindow window("Login",Colours::black,0);window.setBounds(0,0,1600,1000);fitLoginWindow(window);
        expect(window.getWidth()<=600 && window.getHeight()<=640,"Login inherited editor dimensions");
        const auto *display=Desktop::getInstance().getDisplays().getDisplayForRect(window.getBounds());
        expect(display && display->userArea.contains(window.getBounds()),"Login overlaps taskbar or screen edge");
    });
    test("Project transitions and interface scale preserve the shared native window",[]{
        DocumentWindow window("Window placement", Colours::black, 0);
        window.setResizable(true, false);
        fitProjectBrowserWindow(window);
        showEditorWindow(window);
        const auto editor = window.getBounds();
        window.setBounds(editor.withPosition(editor.getX() + 17, editor.getY() + 23));
        const auto moved = window.getBounds();
        showEditorWindow(window); // New tab has no remembered editor bounds.
        expect(window.getBounds() == moved, "New tab reset the shared window");
        showEditorWindow(window, editor); // Replacement project has stale remembered bounds.
        expect(window.getBounds() == moved, "Opening another project reset the window");
        const auto hwnd = static_cast<HWND>(window.getPeer()->getNativeHandle());
        const auto originalScale = Desktop::getInstance().getGlobalScaleFactor();
        struct RestoreScale {
            DocumentWindow &window; float scale;
            ~RestoreScale() { setInterfaceScalePreservingWindow(&window, scale); }
        } restore{window, originalScale};
        auto checkScale = [&] {
            RECT before{}; expect(GetWindowRect(hwnd, &before), "Missing native frame");
            for (const float scale : {.75f, 1.f, 1.25f, 1.f}) {
                setInterfaceScalePreservingWindow(&window, scale);
                RECT after{}; expect(GetWindowRect(hwnd, &after) && EqualRect(&before, &after),
                                    "Scaling moved or resized the native window");
            }
        };
        checkScale();
        window.setFullScreen(true);
        checkScale();
        expect(window.isFullScreen(), "Scaling unmaximized the editor");
        showEditorWindow(window);
        expect(window.isFullScreen(), "New project unmaximized the editor");
        window.setFullScreen(false);
        fitProjectBrowserWindow(window);
        checkScale();
        showEditorWindow(window);
        expect(window.getWidth() > 600, "Browser failed to expand for first project");
    });
    test("Sidebar rail scroll and width gestures stay on their initial axis",[]{
        DragDivider rail;rail.setBounds(0,0,6,400);
        int offset=0,width=300,starts=0,ends=0;
        rail.scrollMetrics=[&]{return DragDivider::ScrollMetrics{offset,400,1600};};
        rail.scrollTo=[&](int y){offset=jlimit(0,1200,y);};
        rail.started=[&]{++starts;};rail.ended=[&]{++ends;};rail.moved=[&](int delta){width=300+delta;};
        const Point<float> origin{3,100};
        auto event=[&](Point<float> at){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,&rail,&rail,Time::getCurrentTime(),origin,Time::getCurrentTime(),1,false);};
        rail.mouseDown(event(origin));rail.mouseDrag(event({3,150}));rail.mouseUp(event({3,150}));
        expect(offset>0 && width==300 && starts==0 && ends==0,"Scroll gesture resized the sidebar");
        const int savedOffset=offset;
        rail.mouseDown(event(origin));rail.mouseDrag(event({33,101}));rail.mouseDrag(event({43,180}));rail.mouseUp(event({43,180}));
        expect(width==340 && offset==savedOffset && starts==1 && ends==1,"Resize gesture switched axes or failed to persist once");
    });
    test("Mixer slot Shift bypass and Alt remove affect one effect and support undo",[&]{
        auto project=projectFixture();Session session;session.inspection=true;session.restoreSnapshot(ProjectCodec::encode(project));
        const auto id=session.song()->tracks[0].id;
        auto settings=object();Array<var> chain;chain.add("EQ");chain.add("Compressor");put(settings,"inserted",chain);put(settings,"eqEnabled",true);put(settings,"compressorEnabled",true);
        session.configureEffects(id,settings);
        int opens=0;String error;
        MixerPanel mixer(session,[&](ID,String){++opens;},[](ID,ModifierKeys){},[&](String value){error=value;},[](ID,bool){},[](ID){return false;},[](ID,Point<int>){});
        mixer.setSize(600,350);
        auto *strip=uiFeatureTests::find(mixer,"mixerStrip:"+text(id));expect(strip,"Mixer strip missing");
        auto click=[&](int modifiers){Point<float> at{20,20};auto event=MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(modifiers|ModifierKeys::leftButtonModifier),1,0,0,0,0,strip,strip,Time::getCurrentTime(),at,Time::getCurrentTime(),1,false);strip->mouseDown(event);strip->mouseUp(event);};
        click(ModifierKeys::shiftModifier);
        expect(!fxchain::enabled(fxchain::settings(session,id),"EQ") && fxchain::enabled(fxchain::settings(session,id),"Compressor"),"Shift bypass affected the wrong effects");
        session.undo();expect(fxchain::enabled(fxchain::settings(session,id),"EQ"),"Bypass undo failed");
        click(ModifierKeys::altModifier);
        expect(list(get(fxchain::settings(session,id),"inserted")).size()==1,"Alt failed to remove only one FX");
        session.undo();expect(list(get(fxchain::settings(session,id),"inserted")).size()==2 && fxchain::enabled(fxchain::settings(session,id),"EQ"),"Removal undo failed");
        expect(opens==0 && error.isEmpty(),"Modified click opened FX manager or failed");
    });
    test("Peak readouts retain maxima through silence, ignore invalid values and reset explicitly",[]{
        meterDisplay::PeakHold peak;
        peak.record(.01f);expect(peak.amplitude()==0,"Noise below -24 dB displayed a peak");
        peak.record(.5f);peak.record(.1f);peak.record(0);peak.record(std::numeric_limits<float>::infinity());
        expect(peak.amplitude()==.5f,"Silence, decay or invalid input changed held peak");
        peak.record(1.25f);expect(peak.amplitude()==1.25f,"Overload peak was clamped");
        peak.clear();expect(peak.amplitude()==0,"Reset failed");peak.record(.25f);expect(peak.amplitude()==.25f,"Peak did not resume after reset");
    });
    const auto editorFixture=SystemStats::getEnvironmentVariable("CATLIVE_TEST_VST3_EDITOR",{});
    if(editorFixture.isNotEmpty())test("Native VST3 editor stays inside FX manager across resizing and disposal",[&]{
        auto descriptions=native::vst3::scan(std::filesystem::u8path(utf8(editorFixture)));
        expect(!descriptions.empty(),"Editor fixture is empty");
        auto processor=std::make_shared<native::vst3::Processor>(descriptions.front(),native::vst3::State{},48000);
        DocumentWindow manager("FX embedded regression",Colours::black,DocumentWindow::closeButton);
        manager.setUsingNativeTitleBar(true);
        auto embedded=std::make_unique<ExternalEffectEditor>(processor,[](const KeyPress&){return false;},[](bool){});
        manager.setContentNonOwned(embedded.get(),false);manager.centreWithSize(740,560);manager.setVisible(true);
        floatingControlTests::pump();
        auto *host=dynamic_cast<HWNDComponent*>(embedded->getChildComponent(0));
        expect(host&&host->getHWND(),"Native view was not attached to manager");
        const auto hwnd=static_cast<HWND>(host->getHWND());
        expect(GetAncestor(hwnd,GA_ROOT)==manager.getPeer()->getNativeHandle(),"Plugin opened in a separate window");
        expect(GetWindow(hwnd,GW_CHILD)!=nullptr,"Plugin canvas missing");
        manager.setContentComponentSize(120,80);floatingControlTests::pump();
        RECT client{};GetClientRect(hwnd,&client);
        expect(client.right>0&&client.bottom>0&&client.right<200,"Host did not follow manager bounds");
        manager.clearContentComponent();embedded.reset();expect(!IsWindow(hwnd),"Native editor survived disposal");
        AudioBuffer<float> buffer(2,64);buffer.clear();native::vst3::Transport transport;
        expect(processor->process(buffer.getWritePointer(0),buffer.getWritePointer(1),64,transport),"Closing editor interrupted processor");
    });
    trackDuplicationTests::run(test);
    trackDuplicationTests::runSession<Session>(test);
    recordingCaptureTests::registerTests(directory, test);
    vinhetasTests::run(directory,test);
    projectReductionTests::run(directory,test,projectFixture);
    test("Armed input meters work before REC with monitoring off and no master leakage", [&] {
        jaras::Song song; song.id = uuid(); song.duration = 60; song.bpm = 120;
        jaras::Track track; track.id = uuid(); track.role.id = "other"; track.name = "Input 3/4";
        track.inputPatch = jaras::OutputPatch{3, 2}; track.inputMonitoring = false;
        track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
        song.tracks.push_back(track);
        AudioEngine audio; audio.prepareOffline(48000); audio.prepareSong(song, directory);
        audio.armTrack(track.id, true);
        AudioBuffer<float> input(4, 512), output(2, 512); input.clear();
        FloatVectorOperations::fill(input.getWritePointer(2), .2f, 512);
        FloatVectorOperations::fill(input.getWritePointer(3), -.4f, 512);
        audio.render(output.getArrayOfWritePointers(), 2, 512, input.getArrayOfReadPointers(), 4);
        const auto levels = audio.meterLevels(track.id);
        expect(levels[0] > .19f && levels[1] > .39f, "Stopped armed track did not meter its selected stereo input");
        expect(output.getMagnitude(0, 512) == 0 && audio.peak() == 0, "Input metering routed monitor-off audio to master");
        expect(!audio.state().playing && !audio.isRecording(), "Metering started playback or recording");
    });
    transportFadeoutTests::registerTests(directory, test);
    addActionBindingsTests(directory, test);
    addUIFeatureTests(directory, test);
    addPartsPanelTests(directory, test);
    stemGraphTests::registerTests(directory, test, skipped);
    mediaImportTests::registerTests(directory, test);
    liveItemResizeTests::registerTests(directory, test);
    liveSessionEditTests::registerTests(directory, test);
    streamingReaderTests::registerTests(directory, test);
    audioGainRenderTests::registerTests(directory, test);
    clipAudioReadTests::registerTests(directory, test);
    longTimelineAudioTests::registerTests(directory, test);
    timelineMarqueeTests::registerTests(test);
    timelineVisualParityTests::registerTests(directory, test);
    itemLocalGeometryTests::registerTests(directory, test);
    hozMixerFocusTests::registerTests(directory, test);
    instrumentRenderTests::registerTests(test);
    gridMediaClipboardTests::registerTests(test);
    floatingControlTests::registerTests(directory,test);
    projectOpenTests::registerTests(directory,test);
    navigationParityTests::registerTests(directory,test);
    projectBrowserLoadingTests::registerTests(directory,test);
    bpmDetectionTests::registerTests(directory,test);
    lightingRegionTests::registerTests(directory,test);
    sectionMarkerTests::registerTests(directory,test);
    reaperImportParityTests::registerTests(directory,test);
    midiTakePlaybackTests::registerTests(test);
    regionLaneTests::registerTests(directory,test);
    setlistSearchTests::registerTests(directory,test);
    remoteSetlistSelectionTests::registerTests(directory,test);
    addTrackVisibilityTests(directory,test);
    addWorkspaceSetlistPresentationTests(directory,test);
    masterMixerTests::registerTests(directory,test);
    workspaceLayoutTests::registerTests(directory,test);
    test("Transport Fadeout waits for silence, cancels and blocks Subplay without changing saved faders", [&] {
        Session session; session.inspection = true;
        auto p = projectFixture();
        auto &track = p.songs[0].tracks[0]; track.clips.clear();
        const auto id = track.id; const double volume = track.volume;
        auto partner = track; partner.id = uuid(); partner.stereoLinkPartner = id;
        track.stereoLinkPartner = partner.id;
        track.stereoLinkLeft = true;
        track.inputPatch = jaras::OutputPatch{1, 1};
        partner.inputPatch = jaras::OutputPatch{2, 1};
        partner.pan = -track.pan;
        const auto stereoLink = [](const ID &other, bool left) {
            auto link = object(); put(link, "partner", text(other)); put(link, "left", left);
            put(link, "original", object()); return utf8(JSON::toString(link, true));
        };
        track.stereoLinkJSON = stereoLink(partner.id, true);
        partner.stereoLinkJSON = stereoLink(id, false);
        p.songs[0].tracks.push_back(partner);
        session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(p));
        session.audio.setOffline(true);
        String warning;
        session.transportFadeoutWarning = [&](String value) { warning = value; };
        session.toggleTransportFadeout(true, {id}, 1);
        expect(!session.transportFadeoutActive() && warning.isNotEmpty(), "Stopped transport accepted Fadeout");
        session.command(jaras::CommandKind::play);
        session.toggleTransportFadeout(false, {id}, 1);
        expect(!session.transportFadeoutActive(), "Disabled Fadeout started");
        session.toggleTransportFadeout(true, {id}, 1);
        expect(session.transportFadeoutActive() && session.transport().playing, "Fadeout did not start");
        const auto saved = JSON::toString(session.snapshot());
        const bool dirty = session.dirty, undo = session.canUndo();
        warning.clear(); session.command(jaras::CommandKind::subPlay);
        expect(!session.transport().subPlay.playing && warning.isNotEmpty() && session.transportFadeoutActive(), "Subplay escaped exclusion");
        session.command(jaras::CommandKind::volume, id, .1);
        session.command(jaras::CommandKind::volume, partner.id, .1);
        expect(session.song()->tracks[0].volume == volume, "Transient fade changed saved fader");
        AudioBuffer<float> buffer(2, 1024);
        auto render = [&](int frames) { while (frames > 0) {
            const int count = std::min(frames, buffer.getNumSamples());
            session.audio.render(buffer.getArrayOfWritePointers(), 2, count); frames -= count;
        }};
        render(24000); session.updateTransportFadeout();
        expect(session.transport().playing && session.transportFadeoutActive() && session.trackDisplayVolume(id, volume) < volume, "Transport stopped before silence");
        session.toggleTransportFadeout(true, {id}, 1);
        expect(session.transport().playing && !session.transportFadeoutActive() && session.trackDisplayVolume(id, volume) == volume, "Repeated Fadeout did not cancel and restore");
        expect(JSON::toString(session.snapshot()) == saved && session.dirty == dirty && session.canUndo() == undo, "Fadeout changed document or history");
        session.command(jaras::CommandKind::subPlay);
        warning.clear(); session.toggleTransportFadeout(true, {id}, 1);
        expect(!session.transportFadeoutActive() && warning.isNotEmpty() && session.transport().subPlay.playing, "Fadeout escaped Subplay exclusion");
        session.command(jaras::CommandKind::subStop);
        session.toggleTransportFadeout(true, {id}, 1);
        render(47999); session.updateTransportFadeout();
        expect(session.transport().playing, "Fadeout stopped one sample early");
        render(1);
        expect(session.audio.trackFadeoutComplete() && session.audio.trackFadeoutGain(id) == 0, "Fadeout completion was not silent");
        session.busy = true;
        session.updateTransportFadeout();
        expect(session.transportFadeoutActive() && session.transport().playing, "Busy transport discarded completed Fadeout before Stop");
        session.busy = false;
        session.updateTransportFadeout();
        expect(!session.transport().playing && !session.transportFadeoutActive() && session.trackDisplayVolume(id, volume) == volume, "Completed Fadeout did not stop and restore");
        session.canPlay = [] { return false; };
        session.command(jaras::CommandKind::play);
        expect(session.audio.trackFadeoutGain(id) == 0 && !session.transport().playing, "Rejected Play released held FX tails");
        session.canPlay = [] { return true; };
        session.command(jaras::CommandKind::subPlay);
        expect(!session.transport().subPlay.playing && session.audio.trackFadeoutComplete(), "Stopped Subplay changed transport or released FX tails");
        session.command(jaras::CommandKind::play);
        expect(session.transport().playing && !session.audio.trackFadeoutActive(), "Next Play after Fadeout remained silent");
        session.command(jaras::CommandKind::subPlay);
        expect(session.transport().subPlay.playing && !session.audio.trackFadeoutActive(), "Subplay after restarting remained silent");
        session.command(jaras::CommandKind::subStop);
        session.toggleTransportFadeout(true, {id}, 2);
        session.command(jaras::CommandKind::stop);
        expect(!session.transportFadeoutActive() && !session.transport().playing && session.trackDisplayVolume(id, volume) == volume, "Ordinary Stop retained fading fader");
        session.command(jaras::CommandKind::play);
        session.toggleTransportFadeout(true, {id}, 2);
        render(480);
        const auto beforeRebuild = session.audio.state();
        const auto fadingGain = session.audio.trackFadeoutGain(id);
        session.restoreSnapshot(session.snapshot());
        expect(session.preparingLiveAudio(), "Same-project restore did not prepare its live graph asynchronously");
        const auto rebuildDeadline = Time::getMillisecondCounterHiRes() + 15000;
        while (session.preparingLiveAudio() && Time::getMillisecondCounterHiRes() < rebuildDeadline)
            liveSessionEditTests::dispatch();
        expect(!session.preparingLiveAudio(), "Same-project restore did not finish preparing its live graph");
        liveItemResizeTests::assertClocks(beforeRebuild, session.audio.state());
        expect(session.transportFadeoutActive() && session.trackFaderLocked(id) && session.transport().playing &&
                   session.audio.trackFadeoutGain(id) == fadingGain,
               "Same-project restore reset the running Fadeout or released its selected fader");
        session.newProject();
        expect(!session.transportFadeoutActive() && !session.trackFaderLocked(id) &&
                   !session.audio.trackFadeoutActive() && !session.transport().playing,
               "Opening a new project retained the previous project's Fadeout controls");
    });
    test("Movement lock persists, prevents geometry edits and preserves tempo metadata and undo", [&] {
        Session session;
        auto p=projectFixture(); for (auto &track:p.songs[0].tracks) for (auto &clip:track.clips) clip.audioFile.reset();
        p.timelineMovementLocked=true;
        session.restoreSnapshot(ProjectCodec::encode(p));
        expect(session.project().timelineMovementLocked == true, "Movement lock was not decoded");
        for (int change=0; change<6; ++change) {
            const auto before=JSON::toString(session.snapshot()); bool rejected=false;
            try { session.edit([&](auto &candidate) {
                auto &song=candidate.songs[0]; auto &clip=song.tracks[0].clips[0];
                if(change==0) clip.startTime+=1;
                if(change==1) clip.duration+=1;
                if(change==2) clip.sourceOffset+=1;
                if(change==3) song.parts[0].startTime+=1;
                if(change==4) song.parts[0].endTime+=1;
                if(change==5) song.markers->front().position+=1;
            }); } catch (...) { rejected=true; }
            expect(rejected && JSON::toString(session.snapshot())==before && !session.canUndo(), "Locked edit committed or changed history");
        }
        session.edit([](auto &candidate) {candidate.songs[0].parts[0].name="Renamed";candidate.songs[0].parts[0].color=0xff0000;});
        session.undo(); expect(session.project().songs[0].parts[0].name==p.songs[0].parts[0].name,"Metadata undo failed with lock");
        session.setTempo(130); expect(std::abs(session.tempoBPM()-130)<.001,"Lock prevented tempo edit"); session.undo();
        session.edit([](auto &candidate) {candidate.timelineMovementLocked=false;},false);
        session.edit([](auto &candidate) {candidate.songs[0].tracks[0].clips[0].startTime+=1;});
        expect(session.song()->tracks[0].clips[0].startTime==p.songs[0].tracks[0].clips[0].startTime+1,"Unlocked movement rejected");
    });
    test("REC Multitrack creates and arms sequential mono inputs only after saving", [&] {
        for (int channels : {1, 32, 128}) {
            const auto project = makeRecordingProject("Recording test", channels);
            const auto decoded = ProjectCodec::decode(ProjectCodec::encode(project));
            expect(decoded.songs.size() == 1 && decoded.songs[0].tracks.size() == (size_t)channels, "REC track count mismatch");
            std::set<ID> ids;
            for (int index = 0; index < channels; ++index) {
                const auto &track = decoded.songs[0].tracks[(size_t)index];
                expect(ids.insert(track.id).second, "REC tracks share IDs");
                expect(track.inputPatch && track.inputPatch->firstChannel == index+1 && track.inputPatch->channelCount == 1, "REC input mismatch");
                expect(track.recordingChannels == 1 && track.inputMonitoring == true && !track.recordingFormat, "REC defaults mismatch");
                expect(track.outputs && track.outputs->size() == 1 && track.outputs->front().firstChannel == 0, "REC is not routed to Master");
            }
        }
        for (int channels : {0, 129}) {
            bool rejected=false; try { (void)makeRecordingProject("Recording test", channels); } catch (...) { rejected=true; }
            expect(rejected, "Invalid REC count accepted");
        }
        Session session;
        const auto target=directory.getChildFile("rec-template-" + text(uuid()) + "/Recording.jl");
        session.createRecordingProject("REC 32", 32, target);
        expect(target.existsAsFile() && !session.dirty, "REC project not saved");
        for (const auto &track : session.song()->tracks) expect(session.recordingArmed(track.id), "REC track not armed");
        const auto before=session.project().id;
        bool rejected=false; try { session.createRecordingProject("Other", 4, target); } catch (...) { rejected=true; }
        expect(rejected && session.project().id == before && session.song()->tracks.size()==32, "Failed creation replaced open project");
    });
    test("Fade shapes preserve legacy envelope, MIDI velocity, document data and fine handles", [&] {
        expect(std::abs(jaras::FadeCurve{}.value(.25)-.15625)<1e-12,"Legacy smooth envelope changed");
        for(double curvature:{-1.,0.,1.})for(double shape:{-1.,0.,1.}){
            jaras::FadeCurve curve(curvature,shape);double previous=0;
            for(int n=0;n<=1000;++n){const auto v=curve.value(n/1000.);expect(v>=previous-1e-12 && v>=0 && v<=1,"Fade became nonmonotonic");previous=v;}
            expect(curve.value(0)==0 && curve.value(1)==1,"Fade endpoints changed");
        }
        auto p=projectFixture();auto &track=p.songs[0].tracks[0];auto &clip=track.clips[0];
        clip.startTime=0;clip.duration=8;clip.sourceOffset=0;clip.playbackRate=1;clip.gain=1;clip.loopLength.reset();clip.loopStart.reset();clip.fadeIn=2;clip.fadeOut=2;
        clip.fadeInCurve=.7;clip.fadeInSCurve=-.4;clip.fadeOutCurve=-.8;clip.fadeOutSCurve=.25;
        const auto decoded=ProjectCodec::decode(ProjectCodec::encode(p,{})).songs[0].tracks[0].clips[0];
        expect(decoded.fadeInCurve==.7 && decoded.fadeInSCurve==-.4 && decoded.fadeOutCurve==-.8 && decoded.fadeOutSCurve==.25,"Fade parameters lost in project codec");
        ItemHeader header({0,0,800,100},800,track,clip);
        for(auto control:{ItemHeader::fadeInCurve,ItemHeader::fadeInSCurve,ItemHeader::fadeOutCurve,ItemHeader::fadeOutSCurve}){
            const auto rect=header.shapeRect(clip,ItemHeader::shapeIn(control),ItemHeader::shapeS(control));expect(!rect.isEmpty() && header.hit(rect.getCentre(),clip)==control,"Fine fade handle cannot be grabbed");}
        clip.fadeInCurve.reset();clip.fadeInSCurve.reset();clip.fadeOutCurve.reset();clip.fadeOutSCurve.reset();clip.audioFile.reset();clip.midi.emplace();clip.midi->sourceBPM=120;
        for(int n=0;n<16;++n)clip.midi->notes.push_back({uuid(),n*.5,.2,60,100,1});
        const auto notes=playbackNotes(track);expect(notes.size()==15,"Silent first MIDI note must not be emitted");
        expect(notes[0].velocity==4 && notes[3].velocity==50 && notes[7].velocity==100,"MIDI fade velocity differs from Mac");
        expect(clip.midi->notes[0].velocity==100,"Fade destroyed source MIDI velocities");
    });
    test("Automatic Subplay seconds and bars survive Windows project serialization", [&] {
        auto p=projectFixture();p.regionSetlist=jaras::RegionSetlist{};p.regionSetlist->automaticSubplay=true;
        for(int count=1;count<=5;++count) {
            p.regionSetlist->automaticSubplayBars=count;p.regionSetlist->automaticSubplaySeconds=3;
            p.regionSetlist->automaticSubplayNext=true;p.songs[0].parts[0].subplayInitBars=count;p.songs[0].parts[1].subplayInitSeconds=count;
            const auto restored=ProjectCodec::decode(ProjectCodec::encode(p,{}));
            expect(restored.regionSetlist->automaticSubplayBars==count && restored.regionSetlist->automaticSubplaySeconds==3,
                "Windows codec lost Subplay units or count");
            expect(restored.regionSetlist->automaticSubplayNext.value_or(false) && restored.songs[0].parts[0].subplayInitBars==count && restored.songs[0].parts[1].subplayInitSeconds==count,"Windows codec lost Next or Config Init");
            p.regionSetlist->automaticSubplayBars.reset();p.regionSetlist->automaticSubplaySeconds=count;
            const auto seconds=ProjectCodec::decode(ProjectCodec::encode(p,{}));
            expect(!seconds.regionSetlist->automaticSubplayBars && seconds.regionSetlist->automaticSubplaySeconds==count,
                "Seconds mode unexpectedly became musical bars");
        }
    });
    test("Playlist copies retain row identity through save, selection, Remote and deletion without changing the grid", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        auto p=projectFixture();const auto first=p.songs[0].parts[0].id,second=p.songs[0].parts[1].id;
        jaras::RegionPlaylist playlist{uuid(),"Show",p.songs[0].id,{first,second}};
        p.regionSetlist.emplace();p.regionSetlist->playlists={playlist};p.regionSetlist->selectedId=playlist.id;
        session.restoreSnapshot(ProjectCodec::encode(p));session.audio.setOffline(true);
        const auto grid=JSON::toString(get(ProjectCodec::encode(session.project()),"songs"));
        const auto copy=session.duplicatePlaylistRegion(playlist.id,first);
        expect(!copy.empty(),"Copy was not created");
        expect(session.project().regionSetlist->playlists[0].regionIds==std::vector<ID>{first,copy,second},"Copy was not adjacent");
        expect(JSON::toString(get(ProjectCodec::encode(session.project()),"songs"))==grid,"Copy changed grid media or regions");
        const auto reopened=ProjectCodec::decode(ProjectCodec::encode(session.project()));
        expect(reopened.regionSetlist->playlists[0].resolvedRegionId(copy)==first,"Windows codec lost occurrence source");
        session.command(jaras::CommandKind::selectRegion,copy);
        expect(!session.transport().playing && session.transport().playlistEntryId==copy && session.transport().regionId==first,
               "Stopped copy did not select its source and occurrence");
        session.command(jaras::CommandKind::play);
        bool rejected=false;try{session.command(jaras::CommandKind::queueRegion,copy);}catch(const std::exception&){rejected=true;}
        expect(rejected,"Copy of the currently playing song was not rejected");
        session.command(jaras::CommandKind::stopAll);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("playlist-occurrences",".json"));workspace.setSize(1366,768);
        const auto rows=[&]{return setlistSearchTests::strings(get(get(workspace.diagnostics(),"setlist"),"rowIDs"));};
        expect(rows()==std::vector<String>{text(first),text(copy),text(second)},"Copied row disappeared from Windows list");
        session.command(jaras::CommandKind::selectRegion,second);session.command(jaras::CommandKind::play);
        session.command(jaras::CommandKind::queueRegion,copy);
        expect(session.transport().queuedRegionId==first && session.transport().queuedPlaylistEntryId==copy,"Queue conflated source and row");
        expect(setlistSearchTests::strings(get(get(workspace.diagnostics(),"setlist"),"visibleSelectedEntries"))==std::vector<String>{text(copy)},"Selecting copy selected its original too");
        Appearance remotePreferences(directory.getNonexistentChildFile("playlist-remote",".json"));StageState remoteStage(remotePreferences);
        remote::Presentation presentation(session,remoteStage);
        const auto remoteState=presentation.snapshot(0);
        const auto remoteRows=list(get(remoteState,"regions"));
        expect(remoteRows.size()==3 && str(remoteRows[1],"id")==remote::wireID(copy) && str(remoteRows[1],"sourceRegionId")==remote::wireID(first),"Remote lost occurrence identity");
        expect(str(remoteState,"queuedPlaylistEntryId")==remote::wireID(copy),"Remote queue highlighted wrong occurrence");
        session.command(jaras::CommandKind::stopAll);
        auto state=*session.project().regionSetlist;
        playlistOccurrences::remove(state,playlist.id,{copy});session.configureSetlist(state);
        expect(rows()==std::vector<String>{text(first),text(second)} && session.song()->parts.size()==2,"Removing copy removed original or grid");
    });
    test("Windows Live marks ten seconds of audio, persists marks and clears through desktop and Remote gates", [&] {
        auto p=projectFixture();auto &song=p.songs[0];song.parts[0].startTime=0;song.parts[0].endTime=25;
        song.parts[1].startTime=25;song.parts[1].endTime=40;
        p.regionSetlist.emplace();p.regionSetlist->liveEnabled=true;
        jaras::Engine engine;engine.loadProject(p);engine.execute({jaras::CommandKind::selectRegion,song.parts[0].id});engine.execute({jaras::CommandKind::play});
        engine.advance(9);expect(!engine.project().regionSetlist->playedLiveRegionIDs || engine.project().regionSetlist->playedLiveRegionIDs->empty(),"Live marked before ten seconds");
        engine.advance(1);
        const auto restored=ProjectCodec::decode(ProjectCodec::encode(engine.project()));
        expect(restored.regionSetlist->playedLiveRegionIDs==std::optional<std::vector<ID>>{{song.parts[0].id}},"Windows Live history not persisted");
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(restored));session.audio.setOffline(true);
        Appearance preferences(directory.getNonexistentChildFile("live-occurrences",".json"));
        StageState stage(preferences);remote::Presentation remote(session,stage);
        remote::Command command;command.id=uuid();command.project=p.id;command.song=song.id;command.action="toggleSetlistLive";
        expect(remote.apply(command),"Remote Live toggle failed");
        expect(!session.project().regionSetlist->liveEnabled.value_or(false) && session.project().regionSetlist->playedLiveRegionIDs->empty(),"Remote Live off retained played marks");
    });
    test("Edit cursor selects setlist songs without changing playback or queue", [&] {
        Session session; auto p=projectFixture(); auto &song=p.songs[0];
        const auto first=song.parts[0].id, second=song.parts[1].id;
        auto child=song.parts[0]; child.id=uuid(); child.startTime=12; child.endTime=18; child.parentRegionID=first; song.parts.push_back(child);
        jaras::RegionSetlist state; jaras::RegionPlaylist playlist;playlist.id=uuid();playlist.name="First only";playlist.songId=song.id;playlist.regionIds={first};state.playlists={playlist};state.selectedId=playlist.id;p.regionSetlist=state;
        session.core.loadProject(p);
        session.command(jaras::CommandKind::editSeek,{},13);
        expect(session.focusedRegion==child.id,"Unified internal song not focused");
        expect(session.project().regionSetlist->selectedId==playlist.id,"Matching playlist changed");
        session.command(jaras::CommandKind::play);
        session.command(jaras::CommandKind::queueRegion,second);
        const auto before=session.transport();
        session.command(jaras::CommandKind::editSeek,{},32);
        expect(session.focusedRegion==second,"Edit cursor did not select second song");
        expect(!session.project().regionSetlist->selectedId,"Out-of-playlist song not revealed in all regions");
        expect(session.transport().playing && session.transport().regionId==before.regionId && session.transport().queuedRegionId==before.queuedRegionId,"Selection changed playback/queue");
        session.command(jaras::CommandKind::editSeek,{},25);
        expect(!session.focusedRegion,"Empty grid retained selection");
        session.command(jaras::CommandKind::stopAll);
        expect(Session::subCursorOpacity(.1)==1 && Session::subCursorOpacity(.6)==.3f && Session::subCursorOpacity(1)==1,"SubPlay blink differs from Mac 0.9s cycle");
    });
    test("Project rename preserves identity and redirects Save without moving media", [&] {
        Session s; s.newProject("Before");
        auto folder=directory.getChildFile("rename-project");folder.createDirectory();
        const auto old=folder.getChildFile("Before.jl"), next=folder.getChildFile("After.jl");
        s.save(old); const auto id=s.project().id; const auto sync=s.project().projectSyncID;
        s.renameProject("After");
        expect(!old.existsAsFile() && next.existsAsFile() && s.document==next,"Rename did not move the document");
        expect(s.project().id==id && s.project().projectSyncID==sync && s.mediaDirectory==folder,"Rename changed identity or media root");
        s.save(s.document);
        expect(ProjectCodec::decode(ProjectCodec::read(next)).name=="After","Future Save missed the renamed document");
        old.replaceWithText("preserve"); bool rejected=false;
        try{s.renameProject("Before");}catch(...){rejected=true;}
        expect(rejected && old.loadFileAsString()=="preserve" && s.document==next,"Rename overwrote another file");
    });
    test("Missing selected audio output rejects every Play attempt", [&] {
        Session s;s.newProject("Missing output");s.audio.deviceSessionRequested=true;
        for(int attempt=0;attempt<2;++attempt) {
            bool rejected=false;try{s.command(jaras::CommandKind::play);}catch(const std::exception &e){rejected=String(e.what()).contains("disconnected");}
            expect(rejected && !s.transport().playing,"Missing output allowed Play or omitted the warning");
        }
    });
    test("Waveform pixels follow fade curves without altering cached peaks", [&] {
        auto data=std::make_shared<WaveformCache::Data>();data->duration=1;data->sampleRate=48000;data->frames=48000;data->sourceChannels=data->storedChannels=1;
        data->levels.push_back({256,0,188});data->owned.setSize(188*4,true);
        auto *bytes=(uint8*)data->owned.getData();
        const auto high=(uint16)WaveformCache::encode(.4f),low=(uint16)WaveformCache::encode(-.4f);
        for(int i=0;i<188;++i){bytes[i*4]=(uint8)high;bytes[i*4+1]=(uint8)(high>>8);bytes[i*4+2]=(uint8)low;bytes[i*4+3]=(uint8)(low>>8);}
        WaveformCache cache;jaras::AudioClip clip;clip.duration=1;clip.fadeIn=.5;clip.fadeOut=.5;clip.fadeInSCurve=clip.fadeOutSCurve=0;
        const auto render=[&]{Image image(Image::ARGB,200,100,true);Graphics g(image);WaveformRenderer::draw(g,cache,data,clip,{0,0,200,100},{0,0,200,100},200,Colours::white);return image;};
        const auto extent=[](const Image &image,int x){int count=0;for(int y=18;y<98;++y)if(image.getPixelAt(x,y).getAlpha()>100)++count;return count;};
        auto linear=render();const auto full=extent(linear,100),left=extent(linear,50),right=extent(linear,150);
        expect(full>=30 && full<=33 && left>=14 && left<=18 && right>=14 && right<=18,"Waveform does not shrink at fade-in/out");
        clip.fadeInCurve=1;clip.fadeInSCurve=1;clip.fadeOutCurve=-1;clip.fadeOutSCurve=-1;auto curved=render();
        expect(extent(curved,50)<10 && extent(curved,150)>25,"Fine curves not reflected in waveform pixels");
        expect(std::abs(data->range(0,0,1).second-.4f)<.001f,"Fade modified source peaks");
        PNGImageFormat png;auto out=directory.getChildFile("waveform-fades.png").createOutputStream();png.writeImageToStream(curved,*out);
        clip.fadeIn.reset();clip.fadeOut.reset();clip.gain=2.5;
        const auto fullScale=extent(render(),100);
        clip.gain=1.25; const auto minus6=extent(render(),100);
        expect(fullScale>=76 && fullScale<=80 && minus6>=37 && minus6<=41,"Absolute PCM waveform calibration differs from 0 dBFS / -6 dBFS");
        clip.fadeIn.reset();clip.fadeOut.reset();clip.gain=.5;clip.normalizationGain=1;
        const auto half=extent(render(),100);clip.normalizationGain=2;const auto normalized=extent(render(),100);
        expect(normalized>half*1.8&&normalized<half*2.2,"Normalization gain does not rescale cached waveform pixels");
        clip.gain=.25;clip.normalizationGain=4;expect(std::abs(extent(render(),100)-normalized)<=1,"Item and normalization gains do not multiply");
        const auto positive=(uint16)WaveformCache::encode(.1f);
        for(int i=0;i<188;++i){bytes[i*4+2]=(uint8)positive;bytes[i*4+3]=(uint8)(positive>>8);}
        const auto above=render();clip.phaseInverted=true;const auto below=render();
        const auto mass=[](const Image &image,bool upper){int count=0;for(int y=upper?18:58;y<(upper?58:98);++y)count+=image.getPixelAt(100,y).getAlpha();return count;};
        expect(mass(above,true)>mass(above,false)*5&&mass(below,false)>mass(below,true)*5,"Phase inversion does not reflect asymmetric waveform vertically");
        expect(std::abs(extent(above,100)-extent(below,100))<=1,"Phase inversion collapsed the waveform envelope");
        expect(std::abs(data->range(0,0,1).second-.4f)<.001f,"Gain or polarity rewrote source peaks");
    });
    test("Waveform physical columns retain transients and scroll without repartitioning", [&] {
        auto data=std::make_shared<WaveformCache::Data>();
        data->duration=200;data->sampleRate=48000;data->frames=9600000;data->sourceChannels=data->storedChannels=1;
        const size_t count=(size_t)((data->frames+255)/256);
        data->levels.push_back({256,0,count});data->owned.setSize(count*4,true);
        auto *bytes=(uint8*)data->owned.getData();
        for(size_t bin=0;bin<count;++bin) {
            const uint16 high=(uint16)WaveformCache::encode(bin%997==0?.8f:.04f);
            const uint16 low=(uint16)WaveformCache::encode(bin%997==0?-.6f:-.04f);
            bytes[bin*4]=(uint8)high;bytes[bin*4+1]=(uint8)(high>>8);
            bytes[bin*4+2]=(uint8)low;bytes[bin*4+3]=(uint8)(low>>8);
        }
        WaveformCache cache;jaras::AudioClip clip;clip.duration=200;
        for(float density:{1.f,1.25f,1.5f,2.f}) {
            const auto draw=[&](float scroll) {
                // This checks source-column invariance, so use deterministic software
                // coverage. Direct2D can tessellate the cropped contours differently.
                Image image(Image::ARGB,roundToInt(512*density),roundToInt(96*density),true,SoftwareImageType());
                Graphics g(image);g.addTransform(AffineTransform::scale(density));
                WaveformRenderer::draw(g,cache,data,clip,{-scroll,0,2000,96},{0,0,512,96},10,Colours::white);
                return image;
            };
            const auto original=draw(0),panned=draw(16);const int shift=roundToInt(16*density);
            int tall=0;
            for(int x=4;x<original.getWidth()-shift-4;++x) {
                int height=0;
                for(int y=roundToInt(20*density);y<roundToInt(93*density);++y) {
                    const auto a=original.getPixelAt(x+shift,y).getAlpha(),b=panned.getPixelAt(x,y).getAlpha();
                    if (std::abs((int)a-(int)b)>2) {
                        for (const auto &entry : std::initializer_list<std::pair<String,Image>>{
                                {"waveform-original",original},{"waveform-panned",panned}}) {
                            FileOutputStream file(directory.getChildFile(entry.first+".png"));
                            PNGImageFormat().writeImageToStream(entry.second,file);
                        }
                        expect(false,"Scrolling changed source peak columns: density="+String(density)+
                                     ", x="+String(x)+", y="+String(y)+", alpha="+String(a)+"/"+String(b));
                    }
                    height+=b>100;
                }
                if(height>40*density)++tall;
            }
            expect(tall>0,"A short transient disappeared in the physical-pixel overview");
        }
    });
    test("Marquee follow pause survives mouse release and cursor edits until playback changes", [&] {
        TimelinePlaybackFollowPolicy policy;jaras::TransportState state;
        state.playing=true;state.songId=uuid();state.regionId=uuid();
        policy.pause(state);expect(policy.isPaused(state),"Marquee did not pause following");
        state.position=42;expect(policy.isPaused(state),"Playback ticks or mouse release resumed following");
        state.editPosition=80;expect(policy.isPaused(state),"Editing the cursor resumed following");
        policy.reset();expect(policy.isPaused(state),"Viewport reset cleared the manual pause");
        state.regionId=uuid();expect(!policy.isPaused(state),"Changing the playing song did not resume following");
        policy.pause(state);state.playing=false;expect(!policy.isPaused(state),"Stop did not expire the manual pause");
        state.playing=true;policy.pause(state);state.subPlay.playing=true;expect(!policy.isPaused(state),"SubPlay handoff did not resume following");
    });
    test("Continuous scroll matches Mac and none does not change the viewport", [&] {
        TimelinePlaybackFollowPolicy policy;
        expect(!policy.destination(39,10,10000,0,800,"main",1),"Scroll before viewport midpoint");
        expect(policy.destination(41,10,10000,0,800,"main",1)==10,"Follow midpoint");
        expect(policy.destination(210,10,10000,10,800,"main",1)==1700,"Continuous playback");
        expect(policy.destination(180,10,10000,1700,800,"sub",1)==1400,"SubPlay handoff");
        expect(policy.destination(60,10,10000,1400,800,"main",1)==200,"Return to main");
        expect(!policy.destination({},10,10000,200,800,"main",1)&&!policy.previousPosition,"Stop resets following");
        double origin=0;
        for(int frame=1;frame<=60;++frame) {
            const auto next=policy.destination(200+frame/60.,2,10000,origin,800,"main",0);
            expect(next && *next>origin,"Distant zoom waited for a whole pixel before following");
            expect(std::abs(*next-frame/30.)<1e-9,"Fractional scroll drifted from the audio position");
            origin=*next;
        }
        Appearance prefs(directory.getNonexistentChildFile("scroll-none",".json"));
        expect(!prefs.continuousScroll(),"Continuous scroll must default to none");
        prefs.set("jaras.timeline.continuousScroll",true);expect(prefs.continuousScroll(),"true did not enable continuous scroll");
    });
    test("Master default and temporary SubPlay cursor match Mac", [&] {
        Session session;session.newProject();expect(session.project().masterColor==0x414141,"New Master colour differs");
        expect(!session.subCursorVisible(),"SubPlay cursor initially visible");session.command(jaras::CommandKind::subSeek,{},2);
        expect(session.subCursorVisible(),"SubPlay positioning does not reveal needle");
        session.subCursorPreviewUntil=Time::getMillisecondCounterHiRes()-1;expect(!session.subCursorVisible(),"SubPlay needle persists after preview");
        session.command(jaras::CommandKind::play);session.command(jaras::CommandKind::subPlay);expect(session.subCursorVisible(),"SubPlay playing needle hidden");session.command(jaras::CommandKind::stopAll);
        expect(!session.subCursorVisible(),"Stopped SubPlay needle retained");
    });
    test("Show Mode preserves power-plan lid actions, handles denial and supports desktops", [&] {
        Appearance preferences(directory.getChildFile("show-mode-test.json"));
        ShowMode::State state{"plan-A",true,false,2,3};
        int changes=0;
        ShowMode::Backend backend{[&]{return state;},[&](const auto &,DWORD ac,DWORD dc){
            const auto originals=preferences.value("originals");
            expect(get(originals,Identifier(state.scheme)).isObject(),"Original lid actions must be saved before applying power changes");
            ++changes;state.ac=ac;state.dc=dc;
        }};
        auto active=ShowMode::transition(preferences,backend,true);
        expect(active.enabled && state.ac==0 && state.dc==0 && changes==1,"Show Mode must use do-nothing for both AC and battery");
        ShowMode::transition(preferences,backend,true);
        auto originals=get(preferences.value("originals"),Identifier("plan-A"));
        expect((int)get(originals,"ac")==2 && (int)get(originals,"dc")==3,"Repeated activation must not replace original lid actions with zero");
        active=ShowMode::transition(preferences,backend,false);
        expect(!active.enabled && state.ac==2 && state.dc==3 && !get(preferences.value("originals"),Identifier("plan-A")).isObject(),"Disable must restore the saved AC/DC actions and clear only that plan backup");
        backend.apply=[](const auto &,DWORD,DWORD){throw std::runtime_error("Authorization denied");};
        bool denied=false;try{ShowMode::transition(preferences,backend,true);}catch(...){denied=true;}
        expect(denied && !(bool)preferences.value("enabled") && state.ac==2 && state.dc==3,"Denied authorization must not claim activation or change the previous settings");
        expect(get(preferences.value("originals"),Identifier("plan-A")).isObject(),"Keep the saved settings if authorization fails so a later retry can restore them");
        backend.apply=[&](const auto &,DWORD,DWORD){++changes;};
        bool mismatch=false;try{ShowMode::transition(preferences,backend,true);}catch(...){mismatch=true;}
        expect(mismatch && !(bool)preferences.value("enabled"),"Do not report success when the system did not confirm the requested setting");
        state.scheme="desktop";state.hasLid=false;
        const int before=changes;
        active=ShowMode::transition(preferences,backend,true);
        expect(active.enabled && changes==before,"Desktop Show Mode must keep an app-level wake request without changing a nonexistent lid setting");
        active=ShowMode::transition(preferences,backend,false);
        expect(!active.enabled && changes==before,"Desktop Show Mode must be switchable off without powercfg");
        const auto blocker=directory.getChildFile("show-mode-blocked-parent");
        expect(blocker.replaceWithText("not a directory"),"Cannot create failed-preference fixture");
        Appearance unavailable(blocker.getChildFile("show-mode.json"));
        state={"plan-B",true,false,1,2};
        bool unsaved=false;try{ShowMode::transition(unavailable,backend,true);}catch(...){unsaved=true;}
        expect(unsaved && changes==before && state.ac==1 && state.dc==2,"Never change lid behavior if the original values could not be saved first");
    });
    test("Project deletion protects sibling media and rechecks inventory after confirmation", [&] {
        auto root=directory.getNonexistentChildFile("DeleteProject",{});root.getChildFile("Stems").createDirectory();
        auto p=projectFixture();p.songs[0].tracks[0].clips[0].audioFile=jaras::AudioFile{"Stems/Shared.wav",{}};
        auto own=p.songs[0].tracks[0].clips[0];own.id=uuid();own.startTime=20;own.audioFile=jaras::AudioFile{"Stems/Own.wav",{}};p.songs[0].tracks[0].clips.push_back(own);
        auto shared=root.getChildFile("Stems/Shared.wav"),exclusive=root.getChildFile("Stems/Own.wav"),unrelated=root.getChildFile("notes.txt");
        shared.replaceWithText("shared");exclusive.replaceWithText("own");unrelated.replaceWithText("preserve");const auto document=root.getChildFile("Show.jl");ProjectCodec::write(document,ProjectCodec::encode(p,{}));
        auto make = [&](const char *path) { auto f=root.getChildFile(path);f.getParentDirectory().createDirectory();expect(f.replaceWithText("owned media"),"Deletion fixture");return f; };
        auto cache=make("Stems/WF/Own.wav.waveform"), sharedCache=make("Stems/WF/Shared.wav.waveform");
        auto recovery=make("backups/Media/Archive/recovery.wav"), foreign=make("backups/Media/Foreign/keep.wav");
        auto backup=p;backup.songs[0].tracks[0].clips.resize(1);backup.songs[0].tracks[0].clips[0].audioFile->path="backups/Media/Archive/recovery.wav";
        const auto backupFile=root.getChildFile("backups/Recovery.bkjl");ProjectCodec::write(backupFile,ProjectCodec::encode(backup,{}));
        ProjectDeletion plan(document);
        bool invoked=false;
        ProjectDeletionPanel confirmation(std::make_shared<ProjectDeletion>(plan),[&]{invoked=true;});
        TextButton *deleteButton=nullptr;
        for(auto *child:confirmation.getChildren())if(auto *button=dynamic_cast<TextButton*>(child);button && button->getButtonText().contains("3s"))deleteButton=button;
        expect(deleteButton && !deleteButton->isEnabled() && !invoked,"Project confirmation must show its disabled three-second countdown");
        auto saveConfirmation=[&](const char *name){auto out=directory.getChildFile(name).createOutputStream();expect(out && PNGImageFormat().writeImageToStream(confirmation.createComponentSnapshot(confirmation.getLocalBounds(),true,2),*out),"Cannot capture project confirmation");};
        saveConfirmation("project-deletion-countdown.png");
        bool rejected=false;try{plan.remove();}catch(...){rejected=true;}expect(rejected && document.existsAsFile(),"Deletion skipped the three-second confirmation");
        auto sibling=p;sibling.id=uuid();sibling.songs[0].tracks[0].clips.resize(1);auto siblingData=ProjectCodec::seal(JSON::toString(ProjectCodec::encode(sibling,{}),true));expect(root.getChildFile("Other.jl").replaceWithData(siblingData.getData(),siblingData.getSize()),"Cannot construct legacy sibling fixture");
        Thread::sleep(3100);
        Timer::callPendingTimersSynchronously();
        expect(deleteButton && deleteButton->isEnabled() && deleteButton->getButtonText()==localization::translate("Delete project") && !invoked,"Confirmation must become available after three seconds without deleting anything automatically");
        saveConfirmation("project-deletion-ready.png");
        plan.remove();expect(!document.exists() && !exclusive.exists() && shared.existsAsFile() && unrelated.existsAsFile() && root.isDirectory(),"Deletion removed shared or unrelated files, or retained exclusive media");
        expect(!cache.exists() && sharedCache.existsAsFile() && !backupFile.exists() && !recovery.exists() && !recovery.getParentDirectory().exists() && foreign.existsAsFile(),"Deletion must remove owned waveform/recovery media and empty subfolders while preserving unrelated recovery files");
    });
    test("Batch FX bypass and deletion undo every selected chain with exact plugin state", [&] {
        auto p = projectFixture();
        auto other = p.songs[0].tracks[0]; other.id = uuid(); other.clips.clear(); p.songs[0].tracks.push_back(other);
        const auto fx = fxschema::complete(JSON::parse(R"({"inserted":["EQ","Native:repeat","External:kontakt"],"eqEnabled":true,"bands":[{"frequency":1000,"gain":7,"q":0.12345678901234567}],"instances":[{"id":"repeat","kind":"Compressor","settings":{"inserted":["Compressor"],"compressorEnabled":false,"threshold":-39}}],"externalPlugins":[{"id":"kontakt","classID":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","name":"Kontakt","path":"C:/test.vst3","bypassed":false,"componentState":"bGlicmFyeS1lZGl0ZWQ=","controllerState":"dWktc3RhdGU="}]})"));
        const auto encoded = utf8(JSON::toString(fx, true, 17));
        for (auto &track : p.songs[0].tracks) track.fxJSON = encoded;
        p.masterFXJSON = encoded;
        Session session; session.inspection = true; session.restoreSnapshot(ProjectCodec::encode(p));
        const auto captured = ProjectCodec::decode(session.snapshot());
        const auto capturedFX = JSON::parse(text(*captured.songs[0].tracks[0].fxJSON));
        expect(num(list(get(capturedFX, "bands"))[0], "q") == num(list(get(fx, "bands"))[0], "q"),
               "Capturing live plugin state rounded an existing native parameter");
        const std::vector<ID> ids{p.songs[0].tracks[0].id, other.id};
        fxchain::change(session, ids, false);
        for (const auto &id : ids) expect(fxchain::allBypassed(fxchain::settings(session, id)), "Selected chain still enabled");
        expect(session.project().masterFXJSON == p.masterFXJSON, "Track action changed master");
        session.undo();
        for (const auto &t : session.song()->tracks) {
            if (t.fxJSON != encoded) {
                directory.getChildFile("fx-undo-before.json").replaceWithText(text(encoded));
                directory.getChildFile("fx-undo-after.json").replaceWithText(t.fxJSON ? text(*t.fxJSON) : "null");
            }
            expect(t.fxJSON == encoded, "Undo lost mixed bypass, settings or plugin state");
        }
        session.redo();
        fxchain::change(session, ids, false);
        for (const auto &id : ids) for (auto key : list(get(fx, "inserted"))) expect(fxchain::enabled(fxchain::settings(session, id), key.toString()), "Unbypass left a stage disabled");
        const auto before = session.snapshot();
        fxchain::change(session, ids, true);
        for (const auto &t : session.song()->tracks) expect(!t.fxJSON, "Deleted chain retained plugin state");
        session.undo();
        const auto restored = ProjectCodec::decode(before);
        for (size_t i = 0; i < ids.size(); ++i) expect(session.song()->tracks[i].fxJSON == restored.songs[0].tracks[i].fxJSON, "One undo did not restore both complete chains");
        session.redo();
        for (const auto &t : session.song()->tracks) expect(!t.fxJSON, "Redo did not delete chain");
    });
    test("Undoing item controls preserves the current song, region and editing cursor", [&] {
        auto p=projectFixture();Session session;session.inspection=true;session.restoreSnapshot(ProjectCodec::encode(p));
        const auto songID=p.songs[0].id,regionID=p.songs[0].parts[0].id;
        session.command(jaras::CommandKind::selectRegion,regionID);
        session.command(jaras::CommandKind::editSeek,{},14);
        session.edit([](jaras::Project &p){p.songs[0].tracks[0].clips[0].gain=.25;},false);
        session.undo();
        expect(session.transport().songId==songID && session.transport().regionId==regionID && session.transport().editPosition==14,"Undo reset the current editing context");
        expect(session.song()->tracks[0].clips[0].gain==.7,"Undo did not restore gain");
        session.redo();
        expect(session.transport().regionId==regionID && session.transport().editPosition==14 && session.song()->tracks[0].clips[0].gain==.25,"Redo lost context or gain");
    });
    test("Secondary audio clock runs independently outside all items and regions", [&] {
        auto p=projectFixture(); auto &song=p.songs[0]; song.tracks.clear();
        AudioEngine engine; engine.prepareOffline(48000); engine.prepareSong(song,directory,{},&p);
        AudioEngine::State state; state.subPlaying=true; state.subPosition=song.duration+10;
        engine.transport(state); AudioBuffer<float> output(2,480);
        engine.render(output.getArrayOfWritePointers(),2,480);
        expect(engine.state().subPlaying && std::abs(engine.state().subPosition-(song.duration+10.01))<.00001,
               "secondary clock stopped or reset beyond the arrangement");
        expect(!engine.state().playing && output.getMagnitude(0,480)==0,"empty secondary playback must be silent without starting main");
        state=engine.state(); state.subPlaying=false; engine.transport(state);
        engine.render(output.getArrayOfWritePointers(),2,480);
        expect(!engine.state().subPlaying,"secondary Stop did not reach audio thread");
    });
    test("Touching duplicated items tolerate arithmetic rounding but real overlaps split lanes", [&] {
        jaras::Track track; track.role.id="other";
        jaras::AudioClip original; original.id="a"; original.startTime=10; original.duration=.1;
        auto copy=original; copy.id="b"; copy.startTime=std::nextafter(10.1,0.);
        track.clips={original,copy}; expect(ItemLanes(track).count==1,"touching items use one lane");
        track.clips[1].startTime=10.099; expect(ItemLanes(track).count==2,"real overlaps keep separate lanes");
    });
    test("Overlapping audio items use separate Mac lanes and preserve recording take order", [&] {
        jaras::Track track; track.role.id="other";
        auto add=[&](ID id,double start,double length,std::optional<int> recording={}) {
            jaras::AudioClip clip;clip.id=id;clip.startTime=start;clip.duration=length;clip.recordingLane=recording;track.clips.push_back(clip);
        };
        add("a",10,10);add("b",15,10);add("c",20,5);add("take",9,7,0);add("later",30,5);
        ItemLanes lanes(track);
        expect(lanes.count==3 && lanes.lane("take")==2 && lanes.lane("later")==0,"Recorded take must be below both overlapping originals");
        for(const auto &a:track.clips) for(const auto &b:track.clips)
            if(a.id!=b.id && a.startTime<b.startTime+b.duration && b.startTime<a.startTime+a.duration)
                expect(lanes.lane(a.id)!=lanes.lane(b.id),"Two overlapping items cover each other");
        expect(lanes.lane("a")==lanes.lane("c"),"Touching items should share a lane");
        std::reverse(track.clips.begin(),track.clips.end());
        expect(ItemLanes(track).lanes==lanes.lanes,"Serialization order changes layout");
        track.role.id="video";track.clips.resize(0);add("a",0,10);add("b",20,10);
        expect(clipEditing::constrainedStart(track,track.clips[1],5)==10,"Single-lane drag must stop at nearest free boundary");
        expect(clipEditing::constrainedEdges(track,track.clips[1],5,35).first==10,"Single-lane resize crosses its neighbor");
    });
    test("Extended item triangles preserve source offset, playback rate and bounded zoom work", [&] {
        jaras::AudioClip clip;clip.duration=12;clip.loopLength=4;clip.loopStart=2;clip.sourceOffset=3;clip.playbackRate=2;
        const auto seams=itemLoopSeams(clip,{0,0,1200,60},1200,100);
        expect(seams.size()==6 && std::abs(seams[0]-150)<.001 && std::abs(seams[1]-350)<.001,"Loop seam phase/rate differ from source audio");
        const auto outline=itemOutline(clip,{0,0,1200,60},1200,100);
        expect(!outline.contains(150,59) && outline.contains(140,59) && outline.contains(150,50),"Loop boundary must cut a triangle out of the bottom edge");
        clip.duration=1e9;clip.loopLength=.001;
        expect(itemLoopSeams(clip,{0,0,5e6f,60},800,.005).size()<82,"Minimum zoom iterates invisible repetitions");
    });
    test("Item header controls remain disjoint and fades stay below the header", [&] {
        jaras::Track track; track.role.id="other";
        jaras::AudioClip clip;clip.id="clip";clip.duration=10;clip.fadeIn=2;clip.fadeOut=3;
        ItemHeader header({-80,100,400,60},600,track,clip);
        expect(header.gainRect.getX()==2.6f && !header.gainLabel.isEmpty(),"Clipped item header loses its controls");
        const std::vector<std::pair<ItemHeader::Control,juce::Rectangle<float>>> controls{
            {ItemHeader::mute,header.muteRect},{ItemHeader::fx,header.fxRect},{ItemHeader::phase,header.phaseRect},
            {ItemHeader::pan,header.panRect},{ItemHeader::gain,header.gainRect}};
        for(const auto &a:controls) {
            expect(header.hit(a.second.getCentre(),clip)==a.first,"Header hit selects wrong control");
            for(const auto &b:controls) if(a.first!=b.first) expect(!a.second.intersects(b.second),"Header controls overlap");
        }
        for(bool left:{true,false}) {const auto r=header.fadeRect(clip,left);expect(r.getY()==118 && header.hit(r.getCentre(),clip)==(left?ItemHeader::fadeIn:ItemHeader::fadeOut),"Fade handle not in waveform body");}
        expect(ItemHeader({0,0,20,60},600,track,clip).gainRect.isEmpty(),"Narrow item paints overflowing controls");
    });
    test("Footer keyboard preserves the Mac 88-note range across window sizes", [&] {
        MidiKeyboardState state;
        Appearance appearance(directory.getChildFile("keyboard-appearance.json"));
        FooterKeyboard keyboard(state, appearance);
        for (int width : {600, 1200, 1920}) {
            keyboard.setSize(width, 108);
            expect(std::abs(keyboard.keyRect(21).getX() - 6) < .001f, "First note starts at padding");
            expect(std::abs(keyboard.keyRect(108).getRight() - (width - 6)) < .001f, "C7 remains visible without scrolling");
            const auto white = keyboard.keyRect(21), black = keyboard.keyRect(22);
            expect(std::abs(white.getWidth() * 52 - (width - 12)) < .001f, "All 52 white keys fit");
            expect(std::abs(black.getWidth() / white.getWidth() - .6f) < .001f, "Black key width matches Mac");
            expect(std::abs(black.getHeight() / white.getHeight() - .63f) < .001f, "Black key height matches Mac");
            expect(std::abs(black.getCentreX() - white.getRight()) < .001f, "Black key straddles white keys");
        }
    });
    test("Gain faders match the Mac decibel scale and preserve actual gain", [&] {
        GainFader fader;
        expect(std::abs(fader.valueToProportionOfLength(1) - 5. / 6.) < 1e-8, "0 dB at 83.33 percent");
        expect(std::abs(fader.proportionOfLengthToValue(.5) - std::pow(10., -24. / 20.)) < 1e-8, "Midpoint is -24 dB");
        expect(fader.proportionOfLengthToValue(0) == 0, "Bottom is silence");
        expect(std::abs(fader.getMaximum() - std::pow(10., 12. / 20.)) < 1e-8, "Top is +12 dB");
        for (double db : {-60., -48., -24., -6., 0., 6., 12.}) {
            const auto gain = std::pow(10., db / 20.);
            if (db > -60) expect(std::abs(fader.proportionOfLengthToValue(fader.valueToProportionOfLength(gain)) - gain) < 1e-8, "Gain round trip");
            fader.setValue(gain, dontSendNotification);
            expect(std::abs(fader.getValue() - gain) < 1e-8, "Actual gain is not remapped in the audio model");
        }
    });
    test("Right clicks never trigger the normal button action", [&] {
        QuietButton button;
        button.setBounds(0, 0, 40, 24);
        int activated = 0, mapped = 0;
        button.onClick = [&] { ++activated; };
        const auto mouse = [&](int modifiers) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(), {5,5}, ModifierKeys(modifiers),
                              1, 0, 0, 0, 0, &button, &button, Time::getCurrentTime(),
                              {5,5}, Time::getCurrentTime(), 1, false);
        };
        auto right = mouse(ModifierKeys::rightButtonModifier);
        auto released = mouse(0);
        button.mouseDown(right); button.mouseUp(released);
        expect(activated == 0, "Tuner step ignores right click, including release without modifiers");
        button.context = [&](Point<int>) { ++mapped; };
        button.mouseDown(right); button.mouseUp(released);
        expect(activated == 0 && mapped == 1, "BPM mapping opens once and never changes tempo");

    });
    test("Parameter wheels forward scrolling without changing gain or pan", [&] {
        struct Parent : Component { int calls=0; void mouseWheelMove(const MouseEvent &, const MouseWheelDetails &) override { ++calls; } } parent;
        GainFader gain; ParameterSlider pan;
        parent.addAndMakeVisible(gain); parent.addAndMakeVisible(pan);
        gain.setValue(.8); pan.setRange(-1,1); pan.setValue(-.2);
        for (Slider *slider : std::initializer_list<Slider *>{&gain,&pan}) {
            const auto before=slider->getValue();
            MouseEvent event(Desktop::getInstance().getMainMouseSource(), {5,5}, ModifierKeys(), 1, 0, 0, 0, 0, slider, slider, Time::getCurrentTime(), {5,5}, Time::getCurrentTime(), 0, false);
            MouseWheelDetails wheel{}; wheel.deltaY=.1f;
            slider->mouseWheelMove(event,wheel); wheel.deltaY=-.1f; slider->mouseWheelMove(event,wheel);
            expect(slider->getValue()==before,"Wheel must not change parameter");
            slider->setSize(200,24); slider->setSliderStyle(Slider::LinearHorizontal);slider->setTextBoxStyle(Slider::NoTextBox,false,0,0);
            slider->setDoubleClickReturnValue(true,0);
            MouseEvent right(Desktop::getInstance().getMainMouseSource(), {180,12}, ModifierKeys(ModifierKeys::rightButtonModifier), 1, 0, 0, 0, 0, slider, slider, Time::getCurrentTime(), {180,12}, Time::getCurrentTime(), 2, false);
            slider->mouseDown(right);slider->mouseDrag(right);slider->mouseDoubleClick(right);slider->mouseUp(right);
            expect(slider->getValue()==before,"Right click, drag and double click must not change parameter");
        }
        expect(parent.calls==4,"Wheel reaches parent exactly once");
    });
    test("Meter bars use a short smooth fall without hold and keep instant attack", [&] {
        for(int block:{64,128,480,1024}) {
            float level=1;const double elapsed=double(block)/48000;const int count=(int)(.1/elapsed);
            for(int i=0;i<count;++i)level=meterDisplay::envelope(level,0,elapsed);
            expect(std::abs(20*std::log10(level)+120*count*elapsed)<.001,"Fall must follow elapsed audio time, not callback count");
            for(int i=0;i<(int)(.5/elapsed);++i)level=meterDisplay::envelope(level,0,elapsed);
            expect(level==0,"Silence clears short tail within 600 ms");
        }
        expect(meterDisplay::envelope(0,.8f,.01)==.8f,"Immediate attack");
        expect(meterDisplay::envelope(.001f,0,.1)==0,"Silence threshold");
        meterDisplay::PeakHold peak;peak.record(1);peak.record(.01f);
        expect(peak.amplitude()==1,"Numeric maximum remains independent of moving bars");
    });
    test("Removing EQ resets its parameters without changing other effects", [&] {
        auto value=object();fxui::defaults(value);put(value,"threshold",-47.);put(value,"delayTime",1.7);
        auto bands=list(get(value,"bands"));put(bands.getReference(1),"gain",11.);put(value,"bands",bands);
        fxui::reset("EQ",value);
        expect(num(list(get(value,"bands"))[1],"gain")==0 && num(value,"threshold")==-47 && num(value,"delayTime")==1.7,"Independent reset");
    });
    test("FX presets persist defaults and isolate each processor", [&] {
        fxpresets::Store store(directory.getNonexistentChildFile("fx-presets", ".json"));
        auto source=object();fxui::defaults(source);put(source,"threshold",-37.);put(source,"ratio",9.);
        auto preset=fxpresets::capture("Compressor",source,"Voz");
        auto library=store.read();fxpresets::Store::save(library,preset);
        fxpresets::Store::setDefault(library,"native:Compressor",str(preset,"id"));store.write(library);
        auto target=object();fxui::defaults(target);put(target,"delayTime",1.3);put(target,"compressorEnabled",false);
        store.applyDefault("Compressor",target);
        expect(num(target,"threshold")==-37 && num(target,"ratio")==9,"Preset restored after disk reload");
        expect(num(target,"delayTime")==1.3 && !flag(target,"compressorEnabled"),"Other effect and bypass preserved");
        expect(fxpresets::matches("Compressor",target,preset),"Selected preset recognized");
        put(target,"threshold",-11.);expect(!fxpresets::matches("Compressor",target,preset),"Edited preset recognized as custom");
        library=store.read();fxpresets::Store::setDefault(library,"native:Compressor",{});store.write(library);
        fxui::reset("Compressor",target);store.applyDefault("Compressor",target);
        expect(num(target,"threshold")==-20,"Factory default restored for new inserts");
        bool rejected=false;try{fxpresets::apply("Delay",target,preset);}catch(...){rejected=true;}
        expect(rejected,"Cross-plugin load rejected");
        rejected=false;try{fxpresets::Store::save(library,preset);}catch(...){rejected=true;}
        expect(rejected,"Duplicate names rejected");
    });
    test("Live tempo edits preserve following songs and undo", [&] {
        const auto media = directory.getNonexistentChildFile("live-tempo", "");
        media.getChildFile("Stems").createDirectory();
        WavAudioFormat wav; auto stream = media.getChildFile("Stems/Piano.wav").createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),48000,2,24,{},0));
        expect(writer != nullptr,"Tempo fixture writer");stream.release();
        AudioBuffer<float> pcm(2,480000);pcm.clear();
        for(int i=0;i<pcm.getNumSamples();++i)for(int c=0;c<2;++c)pcm.setSample(c,i,.1f*std::sin(float(i)*.01f));
        expect(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Tempo fixture audio");writer.reset();
        Session session;session.inspection=true;session.mediaDirectory=media;
        auto fixture=projectFixture();fixture.songs[0].timeSettings=jaras::ProjectTimeSettings{};
        fixture.songs[0].timeSettings->timebase=jaras::ProjectTimebase::relative;
        session.restoreSnapshot(ProjectCodec::encode(fixture));
        session.command(jaras::CommandKind::selectRegion,session.song()->parts[0].id);
        session.command(jaras::CommandKind::play);session.setTempo(135);
        expect(session.transport().playing && session.tempoBPM()==135,"BPM changes while playing");
        expect(tempoEditing::needsRender(*session.song(), &session.song()->parts[0]),"Changed tempo is highlighted before rendering");
        expect(tempoEditing::bpm(*session.song(),30)==120,"Following song preserved");
        session.command(jaras::CommandKind::stopAll);session.undo();
        expect(tempoEditing::bpm(*session.song(),10)==120,"Undo restores tempo");
        expect(!tempoEditing::needsRender(*session.song(), &session.song()->parts[0]),"Restored reference tempo clears highlighting");
    });
    test("Repeated tempo edits preserve overlapping next song without adding markers", [&] {
        auto p=projectFixture();auto &song=p.songs[0];song.timeSettings=jaras::ProjectTimeSettings{};
        song.parts={{"a","Outgoing",0,16},{"b","Next",10,30},{"group","Unified",0,30}};
        song.parts[0].parentRegionID="group";song.parts[1].parentRegionID="group";
        auto a=tempoEditing::boundary(song,0),b=tempoEditing::boundary(song,10);
        a.tempoBPM=120;a.tempoReferenceBPM=120;a.regionOwnerID="a";
        b.tempoBPM=144;b.tempoReferenceBPM=144;b.regionOwnerID="b";
        song.markers=std::vector<jaras::TimelineMarker>{a,b};
        for(int i=0;i<100;++i) {
            auto before=song;
            for(const auto &marker:tempoEditing::regionChange(song,song.parts[0],i%2?-1:1)) {
                auto found=std::find_if(song.markers->begin(),song.markers->end(),[&](const auto &m){return m.id==marker.id;});
                if(found==song.markers->end())song.markers->push_back(marker);else *found=marker;
            }
            jaras::TempoEditMap map(before,song);map.apply(song);
            expect(song.markers->size()==2,"An overlapping tail created extra tempo markers");
            expect(*song.markers->at(1).tempoBPM==144,"Outgoing BPM changed the next song");
        }
        expect(std::abs(song.parts[0].endTime-16)<.000001,"Repeated tempo edit did not restore the tail");
    });
    test("Tempo highlighting follows effective source rate, not its historical baseline", [&] {
        auto p=projectFixture();auto &song=p.songs[0];song.markers.reset();
        auto &clip=song.tracks[0].clips[0];clip.playbackRate=1;clip.tempoBasePlaybackRate=.8;
        expect(!tempoEditing::needsRender(song),"Unity rate was highlighted because the saved baseline differs");
        clip.playbackRate=1.25;clip.tempoBasePlaybackRate=1.25;
        expect(tempoEditing::needsRender(song),"Changed rate was hidden because it matched the saved baseline");
    });
    test("Selected tracks share one neutral grid highlight and preserve grid colours", [&] {
        const Colour base(0xff161616), selected(0xff1d1d1d), primary(0xff535250);
        const auto secondary=Colour(0xff333235).withAlpha(.85f);
        Image pixels(Image::RGB,96,64,true);
        {
            Graphics graphics(pixels);
            graphics.fillAll(base);
            int y=16;
            for (const auto trackColour : {Colour(0xffffff00),Colour(0xff828282),Colour(0xff00ff00)}) {
                graphics.setColour(trackColour);graphics.fillRect(0,y,96,16);
                graphics.setColour(theme::panel);graphics.fillRect(0,y,96,16);
                y+=16;
            }
            for(y=0;y<64;y+=16) {
                graphics.setColour(primary);graphics.fillRect(16,y,1,16);
                graphics.setColour(secondary);graphics.fillRect(48,y,1,16);
            }
        } // End the native Direct2D drawing batch before reading its pixels.
        {
            FileOutputStream output(directory.getChildFile("timeline-selected-grid.png"));
            PNGImageFormat().writeImageToStream(pixels,output);
        }
        const auto luma=[](Colour c){return .2126f*c.getRed()+.7152f*c.getGreen()+.0722f*c.getBlue();};
        // Direct2D alpha blending and Colour::overlaidWith round 8-bit channels
        // differently. Permit that single level, but keep opaque pixels exact.
        const auto sameBlend=[](Colour a,Colour b){
            return a.getAlpha()==b.getAlpha() && std::abs((int)a.getRed()-(int)b.getRed())<=1 &&
                std::abs((int)a.getGreen()-(int)b.getGreen())<=1 && std::abs((int)a.getBlue()-(int)b.getBlue())<=1;
        };
        for(int y=24;y<64;y+=16) {
            expect(pixels.getPixelAt(47,y)==selected&&pixels.getPixelAt(49,y)==selected,"Yellow gray and green tracks must share the opaque neutral highlight");
            expect(std::abs(luma(pixels.getPixelAt(48,y))-luma(selected))>=10.f,"Secondary line must remain visible and exactly one pixel wide");
            expect(sameBlend(pixels.getPixelAt(48,y),selected.overlaidWith(secondary)),"Secondary colour and alpha must remain unchanged");
            expect(pixels.getPixelAt(16,y)==primary,"Primary grid colour must remain unchanged");
        }
        expect(sameBlend(pixels.getPixelAt(48,8),base.overlaidWith(secondary)),"Unselected secondary grid colour must remain unchanged");
    });
    test("Timeline grid follows tempo markers, meter and visible subdivisions", [&] {
        jaras::Song song; song.duration = 60; song.bpm = 120;
        jaras::TimelineMarker marker; marker.id = "tempo"; marker.position = 5.25;
        marker.tempoBPM = 60; marker.tempoBeats = 3; marker.tempoUnit = 4;
        song.markers = std::vector<jaras::TimelineMarker>{marker};
        const auto ticks = timelineGrid::ticks(song, 0, 12, 100);
        const auto has = [&](double time, bool primary) {
            return std::any_of(ticks.begin(), ticks.end(), [&](const auto &t) { return std::abs(t.time - time) < 1e-8 && t.primary == primary; });
        };
        expect(has(0, true) && has(2, true) && has(.5, false), "120 BPM grid has half-second beats and two-second bars");
        expect(has(5.25, true) && has(8.25, true) && has(6.25, false), "60 BPM 3/4 marker restarts bar and beat phase");
        expect(!has(6, true), "Old bar phase ends at tempo marker");
        const auto cropped = timelineGrid::ticks(song, 6, 10, 100);
        for (const auto &tick : cropped) {
            expect(tick.time >= 6 && tick.time <= 10, "Grid clipped to viewport");
            expect(has(tick.time, tick.primary), "Scrolling keeps grid phase");
        }
        expect(timelineGrid::label(5.25) == "00:00:05.250", "Fractional ruler label");
        expect(timelineGrid::ticks(song, 0, 10, 0).empty(), "Invalid zoom rejected");
    });
    test("Cursor and item snapping match Mac tempo divisions and timeline anchors", [&] {
        auto song=projectFixture().songs.front();song.bpm=120;song.beatsPerBar=4;song.beatUnit=4;song.duration=40;
        song.parts={jaras::Part{uuid(),"Region",3.13,7.17}};
        song.tracks.clear();jaras::Track edgeTrack;jaras::AudioClip edgeClip;edgeClip.startTime=4.19;edgeClip.duration=1.68;edgeTrack.clips.push_back(edgeClip);song.tracks.push_back(edgeTrack);
        jaras::TimelineMarker marker{uuid(),"Marker",9.23,0xffffff};
        jaras::TimelineMarker tempo{uuid(),"Tempo",10.25,0xffffff};tempo.tempoBPM=60;tempo.tempoBeats=3;tempo.tempoUnit=4;
        song.markers=std::vector<jaras::TimelineMarker>{marker,tempo};
        jaras::TransportState transport;transport.editPosition=15.37;transport.position=16.39;
        auto checkPosition=[&](double actual,double wanted,const char *message){expect(std::abs(actual-wanted)<1e-7,message);};
        auto gridOnly=song;gridOnly.tracks.clear();
        for(double scale:{1.,20.,100.,1000.}) {
            checkPosition(timelineGrid::snapCursor(2.21,gridOnly,scale,false),2.,"Cursor uses configured subdivisions at every zoom");
            checkPosition(timelineGrid::snapCursor(2.21,song,scale,true),2.21,"Shift bypasses cursor grid");
            checkPosition(timelineGrid::snapCursor(10.91,gridOnly,scale,false),11.25,"Cursor restarts snap phase at tempo change");
            for(double target:{3.13,7.17,9.23}) {
                if(scale==1)continue;
                checkPosition(timelineGrid::snapSelection(target+.001,song,scale,transport,false),target,"Items snap to region start/end and marker");
                checkPosition(timelineGrid::snapSelection(target+.001,song,scale,transport,true),target+.001,"Shift bypasses item anchors");
            }
        }
        for(double target:{4.19,5.87}) {
            checkPosition(timelineGrid::snapCursor(target+.001,song,20,false),target,"Cursor snaps to item start and end");
            checkPosition(timelineGrid::snapCursor(target+.001,song,20,true),target+.001,"Shift bypasses item edge magnets");
        }
        checkPosition(timelineGrid::snapSelection(15.371,song,100,transport,false),15.37,"Item snaps to edit cursor");
        checkPosition(timelineGrid::snapCursor(15.371,song,100,false),15.25,"Edit cursor must not snap back to its old position");
    });
    test("Timebase shortcut confirms both modes, preserves item timing and supports Undo", [&] {
        for(bool initiallyRelative:{false,true})for(bool accept:{false,true}) {
            auto project=projectFixture();auto settings=jaras::ProjectTimeSettings{};
            settings.timebase=initiallyRelative?jaras::ProjectTimebase::relative:jaras::ProjectTimebase::free;
            settings.divisions=2;settings.affectsAutomationLength=false;
            project.songs[0].timeSettings=settings;
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("timebase-shortcut",".json"));workspace.setSize(1366,768);
            auto *button=dynamic_cast<TextButton *>(uiFeatureTests::find(workspace,"timelineTimebase"));
            auto *lock=uiFeatureTests::find(workspace,"timelineMovementLock");
            expect(button && lock && button->onClick,"Timebase shortcut missing");
            expect(button->getRight()<lock->getX(),"Timebase shortcut is not left of the lock");
            expect(button->getToggleState()==initiallyRelative,"Timebase button did not reflect the project");
            expect(button->findColour(TextButton::textColourOnId)==theme::green && button->findColour(TextButton::textColourOffId)==theme::yellow,"Timebase colours do not match the requested states");
            button->onClick();
            expect(session.song()->timeSettings->timebase==settings.timebase,"Opening confirmation already changed Timebase");
            auto *action=dynamic_cast<Button *>(uiFeatureTests::find(workspace,accept?"timebaseApply":"timebaseCancel"));
            expect(action && action->onClick,"Timebase confirmation action missing");action->onClick();floatingControlTests::pump();
            const auto expected=accept?!initiallyRelative:initiallyRelative;
            expect((session.song()->timeSettings->timebase==jaras::ProjectTimebase::relative)==expected,"Timebase confirmation did not apply or cancel correctly");
            expect(button->getToggleState()==expected,"Timebase button did not refresh after confirmation");
            const auto &before=project.songs[0].tracks[0].clips[0],&after=session.song()->tracks[0].clips[0];
            expect(session.song()->bpm==project.songs[0].bpm && before.id==after.id && before.startTime==after.startTime && before.duration==after.duration && before.playbackRate==after.playbackRate && before.sourceOffset==after.sourceOffset,"Changing Timebase modified BPM or items before a tempo edit");
            expect(session.song()->timeSettings->divisions==2 && !session.song()->timeSettings->affectsAutomationLength,"Shortcut overwrote unrelated timing settings");
            if(accept){session.undo();expect(button->getToggleState()==initiallyRelative,"Undo did not restore Timebase indicator");}
        }
    });
    test("Stopping at a queued song reveals its region in the grid", [&] {
        auto project=projectFixture();project.regionSetlist=jaras::RegionSetlist{};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        const auto first=project.songs[0].parts[0],next=project.songs[0].parts[1];
        session.command(jaras::CommandKind::selectRegion,first.id);
        session.command(jaras::CommandKind::play);
        session.command(jaras::CommandKind::queueRegion,next.id);
        int reveals=0;
        session.selectionChanged=[&]{++reveals;expect(!session.transport().playing,"Grid reveal ran before Stop committed");};
        session.command(jaras::CommandKind::stop);
        expect(session.transport().regionId==next.id,"Stop did not select the queued region");
        expect(std::abs(session.transport().editPosition-next.startTime)<1e-7,"Stop did not move the edit cursor to the queued region");
        expect(reveals==1,"Stop did not request the same grid reveal as direct selection");
    });
    test("Grid and ruler clicks snap, while ruler drags pan without moving the cursor", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.parts.clear();song.markers.reset();song.tracks.clear();song.bpm=120;song.beatsPerBar=4;song.beatUnit=4;
        project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("cursor-snap",".json"));workspace.setSize(1366,768);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");expect(canvas!=nullptr,"Canvas exists");
        auto event=[&](Point<float> at,Point<float> anchor,int mods,bool dragged){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(mods),1,0,0,0,0,canvas,canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);};
        for(float y:{60.f,110.f}) for(bool free:{false,true}) {
            Point<float> at{46,y};int mods=ModifierKeys::leftButtonModifier|(free?ModifierKeys::shiftModifier:0);
            canvas->mouseDown(event(at,at,mods,false));canvas->mouseUp(event(at,at,free?ModifierKeys::shiftModifier:0,false));
            expect(std::abs(session.transport().editPosition-(free?2.3:2.5))<1e-6,"Ruler and empty grid both seek; Shift is free");
        }
        const double cursor=session.transport().editPosition;
        const double offset=num(get(workspace.diagnostics(),"timeline"),"horizontal");
        Point<float> at{300,60},end{100,60};canvas->mouseDown(event(at,at,ModifierKeys::leftButtonModifier,false));
        canvas->mouseDrag(event(end,at,ModifierKeys::leftButtonModifier,true));
        expect(session.transport().editPosition==cursor,"Ruler pan moved the editing cursor");
        expect(num(get(workspace.diagnostics(),"timeline"),"horizontal")>offset,"Ruler drag did not scroll horizontally");
        canvas->mouseDrag(event({80,60},at,ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier,true));
        canvas->mouseUp(event({80,60},at,0,true));
        expect(session.transport().editPosition==cursor,"Releasing ruler pan moved the editing cursor");
    });
    test("Stereo meter channels use identical colour coverage at fractional scale", [&] {
        for(float scale:{.6f,.9f,1.f,1.1f,1.2f}) {
            Image image(Image::ARGB,60,160,true);Graphics g(image);g.fillAll(Colour(0xff595959));g.addTransform(AffineTransform::scale(scale));
            meterDisplay::bar(g,{2,4,5,120},.8f);meterDisplay::bar(g,{18,4,5,120},.8f);
            const int left=roundToInt(2*scale),right=roundToInt(18*scale),width=std::max(1,roundToInt(5*scale));
            for(int y=roundToInt(20*scale);y<roundToInt(110*scale);++y)for(int x=0;x<width;++x)
                expect(image.getPixelAt(left+x,y)==image.getPixelAt(right+x,y),"Equal stereo levels must have identical pixels and hue");
        }
    });
    test("Special track rows expose role-specific controls without audio FX and recording", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.tracks.clear();
        for(const auto &role:{"generatedClick","timecode","video","teleprompt","teleprompt2","chords"}) {
            jaras::Track track;track.id=uuid();track.role.id=role;track.name=jaras::fixedTrackName(track.role);song.tracks.push_back(track);
        }
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("special-controls",".json"));workspace.setSize(1366,768);
        for(const auto &track:session.song()->tracks) {
            auto *row=uiFeatureTests::find(workspace,"trackRow:"+text(track.id));expect(row!=nullptr,"Special row exists");
            auto *controls=uiFeatureTests::find(*row,"specialTrackControls");expect(controls&&controls->isVisible(),"Special controls shown");
            for(auto *control:controls->getChildren())if(control->isVisible())expect(controls->getLocalBounds().contains(control->getBounds()),"Special control remains inside its row");
            auto *record=uiFeatureTests::find(*row,"trackRecord");expect(record&&!record->isVisible(),"Special tracks cannot record");
            for(auto *child:row->getChildren())if(auto *button=dynamic_cast<TextButton*>(child)) {
                if(button->getButtonText()=="M"||button->getButtonText()=="S")expect(button->isVisible()==(track.role.id=="generatedClick"||track.role.id=="timecode"),"Mute/Solo only on audio-generating special tracks");
                if(button->getButtonText()==String::fromUTF8("Ø"))expect(!button->isVisible(),"Special tracks have no phase inversion button");
            }
            auto *pan=uiFeatureTests::find(*row,"trackPan");expect(pan&&!pan->isVisible(),"Standard pan hidden on special tracks");
            if(track.role.id=="generatedClick")expect(uiFeatureTests::find(*controls,"insertClick")->isVisible(),"Click exposes Insert");
            expect(uiFeatureTests::find(*controls,"insertMedia")->isVisible()==(track.role.id=="video"),"Only legacy video tracks expose Add media");
            if(track.role.id=="chords"||jaras::isTeleprompterRole(track.role))expect(uiFeatureTests::find(*controls,"insertText")->isVisible(),"Text track exposes Add text");
        }
    });
    test("Video audio decoding preserves source timing and silent video metadata", [&] {
        const auto fixtures=File(__FILE__).getParentDirectory().getSiblingFile("Tests").getChildFile("Fixtures");
        const auto video=fixtures.getChildFile("tone-video.mp4"),silent=fixtures.getChildFile("silent.mp4");
        auto info=inspectMediaSource(video);expect(info.audio&&info.video&&std::abs(info.duration-2)<.05,"Video with audio streams and duration");
        info=inspectMediaSource(silent);expect(info.video&&!info.audio,"Silent video is valid projection media");
        double firstTime=0,laterTime=0;
        auto firstFrame=decodeVideoFrame(video,.1,&firstTime),laterFrame=decodeVideoFrame(video,1.5,&laterTime);
        expect(firstFrame.isValid()&&laterFrame.isValid()&&firstFrame.getWidth()==64&&firstFrame.getHeight()==64,"Stopped video decodes an exact still frame");
        expect(std::abs(firstTime-.1)<.1&&std::abs(laterTime-1.5)<.1,
               "Stopped video selected incorrect timestamps: "+String(firstTime)+" / "+String(laterTime));
        expect(laterTime>firstTime+1,"Moving the edit cursor seeks to the later frame");
        AudioFormatManager formats;registerAudioFormats(formats);std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(video));
        expect(reader&&reader->numChannels==2&&reader->sampleRate>0,"Read embedded stereo audio");
        AudioBuffer<float> first(2,2048),afterSeek(2,2048),middle(2,2048);
        expect(reader->read(&first,0,2048,4096,true,true),"Decode initial segment");
        expect(first.getMagnitude(0,2048)>.1f,"Embedded audio is audible");
        expect(reader->read(&middle,0,2048,(int64)reader->sampleRate,true,true),"Seek forward by timestamp");
        expect(reader->read(&afterSeek,0,2048,4096,true,true),"Seek backwards by timestamp");
        float difference=0;for(int c=0;c<2;++c)for(int i=256;i<2048;++i)difference=std::max(difference,std::abs(first.getSample(c,i)-afterSeek.getSample(c,i)));
        expect(difference<.002f,"Seeking preserves sample alignment instead of returning the earlier keyframe");
    });
    test("Projection selects the first active media item in grid order on ordinary tracks", [&] {
        jaras::Song song;jaras::Track first,second;first.id=uuid();second.id=uuid();first.role.id=second.role.id="other";
        jaras::AudioClip a;a.id=uuid();a.startTime=2;a.duration=5;a.audioFile=jaras::AudioFile{"Videos/first.mp4",{}};
        auto b=a;b.id=uuid();b.audioFile=jaras::AudioFile{"Videos/second.mp4",{}};first.clips={a};second.clips={b};song.tracks={first,second};
        expect(firstProjectionItem(song,3,"video")->id==a.id,"Topmost active media wins");
        song.tracks[0].mute=true;expect(firstProjectionItem(song,3,"video")->id==b.id,"Muted track is skipped");
        song.tracks[0].mute=false;song.tracks[0].clips[0].muted=true;expect(firstProjectionItem(song,3,"video")->id==b.id,"Muted item is skipped");
        expect(!firstProjectionItem(song,7,"video"),"End is exclusive");
        expect(!firstProjectionItem(song,3,"teleprompt"),"Teleprompter stays scoped to its own track");
    });
    test("Media drop imports a batch into separate tracks or one sequence with gap and one undo", [&] {
        const auto folder=directory.getChildFile("media-drop");folder.createDirectory();
        Image image(Image::RGB,8,8,true);image.clear(image.getBounds(),Colours::red);
        Array<File> files;
        for(int i=0;i<2;++i){auto file=folder.getChildFile("image"+String(i)+".png");auto stream=file.createOutputStream();PNGImageFormat format;expect(stream&&format.writeImageToStream(image,*stream),"Write image fixture");stream.reset();files.add(file);}
        auto wait=[&](Session &session){const double deadline=Time::getMillisecondCounterHiRes()+15000;while(session.busy&&Time::getMillisecondCounterHiRes()<deadline){MSG message;while(PeekMessage(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessage(&message);}Thread::sleep(2);}expect(!session.busy,"Import worker finishes");};
        for(bool same:{false,true}) {
            auto project=projectFixture();auto &song=project.songs.front();song.parts.clear();song.markers.reset();song.tracks.resize(1);song.tracks.front().role.id="other";song.tracks.front().clips.clear();
            Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);session.mediaDirectory=folder.getChildFile(same?"same":"separate");session.mediaDirectory.createDirectory();
            auto before=JSON::toString(ProjectCodec::encode(session.project()));const auto id=session.song()->tracks.front().id;
            session.importMedia(files,3,id,same ? MediaDropLayout::sameTrack : MediaDropLayout::separateTracks,2);wait(session);
            expect(session.song()->tracks.size()==(same?1u:2u),utf8(session.message).c_str());
            const auto &first=session.song()->tracks.front();expect(first.id==id&&first.role.id=="other","Dropped item preserves destination track type");
            expect(first.clips.front().startTime==3&&first.clips.front().duration==10,"Drop time and image duration match Mac");
            if(same)expect(first.clips.size()==2&&first.clips[1].startTime==15,"Sequential layout preserves two-second gap");
            else expect(session.song()->tracks[1].clips.front().startTime==3,"Separate tracks share drop time");
            session.undo();expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"Single undo restores entire batch");
            session.redo();expect(session.song()->tracks.front().clips.size()==(same?2u:1u),"Redo restores batch and media references");
        }
    });
    test("Generated Click overview follows tempo origins and bounds pixel density", [&] {
        auto song=projectFixture().songs.front();song.bpm=120;song.beatsPerBar=4;song.beatUnit=4;song.parts.clear();
        jaras::TimelineMarker tempo{uuid(),"Tempo",5.25,0};tempo.tempoBPM=60;tempo.tempoUnit=4;song.markers=std::vector<jaras::TimelineMarker>{tempo};
        jaras::AudioClip clip;clip.startTime=.1;clip.duration=10;
        auto beats=timelineGrid::clickBeats(song,clip,0,12,100);
        expect(!beats.empty()&&beats.front()==.5,"Trimmed Click starts on musical beat, not item edge");
        expect(std::find(beats.begin(),beats.end(),5.25)!=beats.end()&&std::find(beats.begin(),beats.end(),6.25)!=beats.end(),"Tempo change resets pulse phase");
        clip.duration=100000;song.duration=100000;
        expect(timelineGrid::clickBeats(song,clip,0,100000,.01).size()<=1002,"Zoomed-out Click rendering stays bounded by pixels");
    });
    test("Individual track height previews only one row and commits one undo step", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.parts.clear();song.markers.reset();
        for(auto &track:song.tracks){track.clips.clear();track.heightScale=1;track.automationJSON.reset();}
        jaras::AudioClip heightClip;heightClip.id=uuid();heightClip.name="Height";heightClip.startTime=2;heightClip.duration=4;
        song.tracks.front().clips.push_back(heightClip);song.tracks.front().color=0xdd3030;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("height-drag",".json"));workspace.setSize(1366,768);workspace.setVisible(true);
        auto *handle=uiFeatureTests::find(workspace,"trackHeightHandle");expect(handle!=nullptr,"Height input exists");
        const auto before=JSON::toString(ProjectCodec::encode(session.project()));
        auto event=[&](Point<float> at,Point<float> anchor,int mods,bool dragged){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(mods),1,0,0,0,0,handle,handle,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);};
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
        expect(!handle->hitTest(50,0)&&!handle->hitTest(50,2),"Row tops do not resize tracks");
        expect(handle->hitTest(50,58)&&handle->hitTest(50,63),"Footer hits belong to the row above");
        expect(!handle->hitTest(50,64)&&!handle->hitTest(50,65),"Moving below a footer must not resize the next track");
        const auto alignedGrid=handle->getLocalPoint(canvas,Point<int>{100,110});
        expect(!handle->hitTest(alignedGrid.x,alignedGrid.y),"An aligned point in the grid cannot resize a track");
        const auto gridTarget=workspace.getComponentAt(workspace.getLocalPoint(canvas,Point<int>{100,110}));
        expect(gridTarget&&gridTarget!=handle,"Native grid hit testing must not return the mixer resize overlay");
        for(const auto point:{Point<float>{50,1},Point<float>{50,65},alignedGrid.toFloat()}) {
            handle->mouseDown(event(point,point,ModifierKeys::leftButtonModifier,false));
            handle->mouseDrag(event(point+Point<float>{0,20},point,ModifierKeys::leftButtonModifier,true));
            handle->mouseUp(event(point+Point<float>{0,20},point,0,true));
        }
        expect(JSON::toString(ProjectCodec::encode(session.project()))==before,
               "Top, next-row and aligned-grid gestures cannot change any track");
        auto firstImage=canvas->createComponentSnapshot(canvas->getLocalBounds());
        expect(firstImage.getPixelAt(75,140).getRed()<100,"Baseline sample is below first item");
        Point<float> anchor{50,62},end{50,94};
        handle->mouseDown(event(anchor,anchor,ModifierKeys::leftButtonModifier,false));handle->mouseDrag(event(end,anchor,ModifierKeys::leftButtonModifier,true));
        expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"Preview leaves stored project unchanged");
        auto previewImage=canvas->createComponentSnapshot(canvas->getLocalBounds());
        // Drag previews are coalesced at 60 Hz; let the native timer publish a frame.
        const auto previewDeadline=Time::getMillisecondCounterHiRes()+500;
        while(previewImage.getPixelAt(75,140).getRed()<=100 && Time::getMillisecondCounterHiRes()<previewDeadline) {
            floatingControlTests::pump();
            previewImage=canvas->createComponentSnapshot(canvas->getLocalBounds());
        }
        expect(previewImage.getPixelAt(75,140).getRed()>100,"Grid item grows with its mixer row before mouse release");
        expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"Published preview leaves stored project unchanged");
        handle->mouseUp(event(end,anchor,0,true));
        expect(session.song()->tracks.front().heightScale.value_or(1)>1.4,"Only dragged row grows");
        for(size_t i=1;i<session.song()->tracks.size();++i)expect(session.song()->tracks[i].heightScale.value_or(1)==1,"Other rows keep their heights");
        session.undo();expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"One undo restores row height");
        handle->mouseDown(event(anchor,anchor,ModifierKeys::leftButtonModifier,false));handle->mouseDrag(event(end,anchor,ModifierKeys::leftButtonModifier,true));handle->keyPressed(KeyPress(KeyPress::escapeKey));handle->mouseUp(event(end,anchor,0,true));
        for(int frame=0;frame<4;++frame)floatingControlTests::pump();
        expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"Escape cancels resize without a project mutation");
        expect(canvas->createComponentSnapshot(canvas->getLocalBounds()).getPixelAt(75,140).getRed()<100,"Cancelled preview cannot return on a later timer frame");
    });
    test("Track drop destination matches group indicator and preserves routes and descendants", [&] {
        jaras::Song song;auto make=[](const char *id,std::optional<ID> parent={}){jaras::Track t;t.id=id;t.name=id;t.role.id="other";t.parentTrackID=parent;t.patch=jaras::OutputPatch{parent?-2:0,2};return t;};
        song.tracks={make("A"),make("G"),make("C","G"),make("D","G"),make("Z")};
        auto into=trackDrop::resolve(song,"A","D",true,false);expect(into&&into->joins&&into->parent==ID("G")&&into->before=="Z","Last child bottom remains inside group");
        trackDrop::apply(song,*into);expect(song.tracks[3].id=="A"&&song.tracks[3].patch->firstChannel==-2,"Commit matches yellow indicator and routes to group");
        auto out=trackDrop::resolve(song,"A","C",true,true);expect(out&&!out->joins&&!out->parent&&out->indicator=="D","Gutter points past entire remaining group");
        trackDrop::apply(song,*out);expect(!song.tracks[3].parentTrackID&&song.tracks[3].patch->firstChannel==0,"Leaving group restores master output");
        expect(!trackDrop::resolve(song,"G","C",true,false),"Folder cannot enter its own child");
        song.tracks.front().role.id="generatedClick";expect(!trackDrop::resolve(song,song.tracks.front().id,"Z",true,false),"Special tracks cannot be reordered");
    });
    test("Folder drag matches Mac engine for nesting and keeps complete subtrees", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.tracks.clear();
        std::vector<ID> ids;for(int i=0;i<8;++i)ids.push_back(uuid());
        const int parents[]{-1,0,0,2,0,-1,5,-1};
        for(int i=0;i<8;++i){jaras::Track track;track.id=ids[i];track.name=std::to_string(i);track.role.id="other";
            if(parents[i]>=0)track.parentTrackID=ids[parents[i]];
            track.patch=jaras::OutputPatch{parents[i]>=0?-2:0,2};track.secondaryPatch=jaras::OutputPatch{6,2};
            song.tracks.push_back(track);}
        int checked=0;
        for(int source:{0,2,5})for(int target=0;target<8;++target)for(bool after:{false,true}) {
            auto destination=trackDrop::resolve(song,ids[source],ids[target],after,false);
            if(!destination || destination->adoption)continue;
            auto actual=project;trackDrop::apply(actual.songs.front(),*destination);
            jaras::Engine engine;engine.loadProject(project);engine.execute({jaras::CommandKind::select,song.id});
            const bool member=song.tracks[target].parentTrackID && !trackTree::descendant(song,source,ids[target]);
            ID before=member?ids[target]:(after?(target+1<8?ids[target+1]:ID{}):ids[target]);
            engine.reorderTrack(ids[source],before);
            expect(JSON::toString(get(list(get(ProjectCodec::encode(actual),"songs"))[0],"tracks"))==JSON::toString(get(list(get(ProjectCodec::encode(engine.project()),"songs"))[0],"tracks")),
                "Mac/Windows folder mismatch: "+String(source)+" -> "+String(target)+(after?" after":" before"));
            ++checked;
        }
        expect(checked>12,"Folder nesting cases were not exercised");
        auto adopted=song;auto destination=trackDrop::resolve(adopted,ids[5],ids[2],false,false);
        expect(destination && destination->adoption && destination->indicator==ids[2] && !destination->after,"Dropping above a member must adopt following siblings and retain the hovered insertion line");
        trackDrop::apply(adopted,*destination);
        const int order[]{0,1,5,2,3,4,6,7};
        for(int i=0;i<8;++i)expect(adopted.tracks[i].id==ids[order[i]],"Adopted group moved past unrelated following tracks");
        expect(adopted.tracks[3].parentTrackID==ids[5] && adopted.tracks[4].parentTrackID==ids[2] &&
               adopted.tracks[5].parentTrackID==ids[5] && adopted.tracks[6].parentTrackID==ids[5],"Adoption lost nested or existing children");
        auto removed=song;trackEditing::removeFromGroup(removed,ids[2]);
        const int removedOrder[]{0,1,4,2,3,5,6,7};
        for(int i=0;i<8;++i)expect(removed.tracks[i].id==ids[removedOrder[i]],"Removing nested group split its subtree");
        expect(!removed.tracks[3].parentTrackID && removed.tracks[4].parentTrackID==ids[2],"Nested group was dissolved instead of promoted");
        trackEditing::ungroup(removed,ids[2]);expect(!removed.tracks[4].parentTrackID,"Root folder did not dissolve");
        expect(removed.tracks[4].secondaryPatch->firstChannel==6,"Group action changed an auxiliary output");
    });
    test("Folder button confirms, preserves nested children and supports undo", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.tracks.clear();
        std::vector<ID> ids;for(int i=0;i<4;++i)ids.push_back(uuid());
        for(int i=0;i<4;++i){jaras::Track t;t.id=ids[i];t.name="Folder "+std::to_string(i);t.role.id="other";
            if(i>0)t.parentTrackID=ids[i==2?1:0];t.patch=jaras::OutputPatch{i>0?-2:0,2};song.tracks.push_back(t);}
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("folder-action",".json"));workspace.setSize(1366,768);
        auto press=[&](int track,int result){
            auto *row=uiFeatureTests::find(workspace,"trackRow:"+text(ids[track]));expect(row!=nullptr,"Folder row missing");
            auto *button=dynamic_cast<Button*>(uiFeatureTests::find(*row,"trackGroupAction"));expect(button!=nullptr,"Folder action missing");
            const auto before=JSON::toString(ProjectCodec::encode(session.project()));button->onClick();floatingControlTests::pump();
            expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"Folder changed before confirmation");
            auto *modal=Component::getCurrentlyModalComponent();expect(modal!=nullptr,"Folder action must ask before changing hierarchy");
            modal->exitModalState(result);for(int i=0;i<4;++i)floatingControlTests::pump();
        };
        const auto baseline=JSON::toString(ProjectCodec::encode(session.project()));
        press(0,0);expect(JSON::toString(ProjectCodec::encode(session.project()))==baseline,"Cancel changed the group");
        press(1,1);
        expect(!session.song()->tracks[2].parentTrackID && session.song()->tracks[2].id==ids[1] &&
               session.song()->tracks[3].parentTrackID==ids[1],"Nested folder click did not promote the complete group");
        session.undo();expect(JSON::toString(ProjectCodec::encode(session.project()))==baseline,"Undo lost group state");
        press(0,1);
        expect(!session.song()->tracks[1].parentTrackID && session.song()->tracks[2].parentTrackID==ids[1] &&
               !session.song()->tracks[3].parentTrackID,"Root folder click must dissolve only its immediate membership");
        session.undo();expect(JSON::toString(ProjectCodec::encode(session.project()))==baseline,"Undo did not restore dissolved group");
    });
    test("Grid right drag selects intersecting items without seeking or opening menus", [&] {
        Session session; session.inspection=true;
        auto project=projectFixture(); auto &song=project.songs.front(); song.tracks.clear();
        for(int row=0;row<2;++row) {
            jaras::Track track;track.id=uuid();track.role.id="other";track.name="Selection";
            jaras::AudioClip clip;clip.id=uuid();clip.startTime=2;clip.duration=4;
            track.clips.push_back(clip);song.tracks.push_back(track);
        }
        session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        auto preferences=directory.getNonexistentChildFile("grid-input", ".json");
        Appearance appearance(preferences);
        appearance.set("jaras.timeline.zoom", 10.);
        Auth auth; Lighting lighting(session); Workspace workspace(session,auth,lighting,false,preferences);
        workspace.setSize(1366,768);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");expect(canvas!=nullptr,"Grid canvas available");
        auto event=[&](Point<float> point,Point<float> anchor,int modifiers,bool dragged) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(modifiers),1,0,0,0,0,
                canvas,canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);
        };
        const auto selectedCount=[&] {return list(get(workspace.diagnostics(),"selectedItems")).size();};
        const double edit=session.transport().editPosition;
        const int modals=Component::getNumCurrentlyModalComponents();
        // Start in the track area, below the edit cursor head's hit target.
        Point<float> anchor{0,72},end{(float)canvas->getWidth()-1,(float)canvas->getHeight()-1};
        canvas->mouseDown(event(anchor,anchor,ModifierKeys::rightButtonModifier,false));
        expect(Component::getNumCurrentlyModalComponents()==modals,"Right down defers menu");
        canvas->mouseDrag(event(end,anchor,ModifierKeys::rightButtonModifier,true));
        expect(selectedCount()==2,"Both rows selected during drag, before release");
        canvas->mouseUp(event(end,anchor,0,true));
        expect(selectedCount()==2 && session.transport().editPosition==edit,"Selection persists without changing edit cursor");
        expect(Component::getNumCurrentlyModalComponents()==modals,"Drag release does not open item menu");
        // A high-rate mouse can release before the next display tick. The final
        // pointer position must be applied even when intermediate events coalesce.
        canvas->mouseDown(event(anchor,anchor,ModifierKeys::rightButtonModifier,false));
        canvas->mouseDrag(event({5,76},anchor,ModifierKeys::rightButtonModifier,true));
        for(int n=0;n<100;++n)canvas->mouseDrag(event(end,anchor,ModifierKeys::rightButtonModifier,true));
        canvas->mouseUp(event(end,anchor,0,true));
        expect(selectedCount()==2,"Final rectangle was lost before the coalesced selection frame");
        // An empty rectangle retains the previous selection only with Shift/Ctrl.
        for(int additive:std::initializer_list<int>{ModifierKeys::shiftModifier,ModifierKeys::ctrlModifier,0}) {
            anchor={0,(float)canvas->getHeight()-8};end={5,(float)canvas->getHeight()-1};
            canvas->mouseDown(event(anchor,anchor,ModifierKeys::rightButtonModifier|additive,false));
            canvas->mouseDrag(event(end,anchor,ModifierKeys::rightButtonModifier|additive,true));
            canvas->mouseUp(event(end,anchor,additive,true));
            expect(selectedCount()==(additive?2:0),"Additive modifiers preserve; plain drag replaces");
        }
    });
    test("Region edges show a compact cursor and green grip inside the fill like Mac", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.parts.resize(1);song.markers.reset();
        project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        const auto original=session.song()->tracks.front().clips.front();
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("region-edge-input",".json"));workspace.setSize(1366,768);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");expect(canvas!=nullptr,"Canvas exists");
        auto event=[&](Point<float> at,Point<float> anchor,int mods,bool dragged){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(mods),1,0,0,0,0,canvas,canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);};
        const auto geometry=get(workspace.diagnostics(),"timeline");const double zoom=num(geometry,"zoom"),scroll=num(geometry,"horizontal");
        const int free=ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier;
        for(int edge:{1,-1}) {
            const auto region=session.song()->parts.front();
            const float x=(float)((edge>0?region.endTime:region.startTime)*zoom-scroll)+(edge>0?-2.f:2.f);
            Point<float> anchor{x,8},end{x+(float)(edge*2*zoom),8};
            canvas->mouseMove(event(anchor,anchor,0,false));
            expect(canvas->getMouseCursor()!=MouseCursor(MouseCursor::NormalCursor) &&
                   canvas->getMouseCursor()!=MouseCursor(MouseCursor::LeftRightResizeCursor),"Region edge did not use its compact resize cursor");
            const auto hover=canvas->createComponentSnapshot(canvas->getLocalBounds());
            const int gripX=roundToInt((edge>0?region.endTime:region.startTime)*zoom-scroll+(edge>0?-10:10));
            const auto grip=hover.getPixelAt(gripX,8);
            expect(grip.getGreen()>240 && grip.getRed()<110 && grip.getBlue()>120,"Green edge grip is missing");
            canvas->mouseDown(event(anchor,anchor,free,false));canvas->mouseDrag(event(end,anchor,free,true));
            expect(session.song()->parts.front().startTime==region.startTime && session.song()->parts.front().endTime==region.endTime,"Preview committed early");
            canvas->mouseUp(event(end,anchor,ModifierKeys::shiftModifier,true));
            const auto resized=session.song()->parts.front();
            expect(std::abs(resized.startTime-(region.startTime+(edge<0?-2:0)))<.001 && std::abs(resized.endTime-(region.endTime+(edge>0?2:0)))<.001,"Inside-edge drag did not resize the region");
            const auto clip=session.song()->tracks.front().clips.front();
            expect(clip.startTime==original.startTime && clip.duration==original.duration && clip.sourceOffset==original.sourceOffset,"Region resize moved or trimmed its audio");
        }
        Point<float> ruler{200,(float)num(geometry,"headerHeight")-8};canvas->mouseMove(event(ruler,ruler,0,false));
        expect(canvas->getMouseCursor()==MouseCursor(MouseCursor::PointingHandCursor),"Number ruler did not show hand cursor");
    });
    test("Dragging paints the actual item at the pointer and commits only on release", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.parts.clear();song.markers.reset();project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        auto &track=song.tracks.front();track.role.id="other";track.color=0xdd3030;track.heightScale=1;track.mute=false;track.clips.clear();
        jaras::AudioClip clip;clip.id=uuid();clip.name="Live item";clip.startTime=2;clip.duration=4;track.clips.push_back(clip);
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("drag-visual",".json"));workspace.setSize(1366,768);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");expect(canvas!=nullptr,"Canvas exists");
        auto event=[&](Point<float> at,Point<float> anchor,int mods,bool dragged){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(mods),1,0,0,0,0,canvas,canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);};
        const int left=ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier;
        Point<float> anchor{70,90},end{270,90};
        canvas->mouseDown(event(anchor,anchor,left,false));
        const auto before=JSON::toString(ProjectCodec::encode(session.project()));
        auto guide=canvas->createComponentSnapshot(canvas->getLocalBounds());
        auto yellowAt=[&](const Image &image,int x){for(int dx=-1;dx<=1;++dx){auto c=image.getPixelAt(x+dx,160);if(c.getRed()>180 && c.getGreen()>180 && c.getBlue()<80)return true;}return false;};
        expect(yellowAt(guide,40)&&yellowAt(guide,120),"Yellow guides appear on press at both item boundaries");
        canvas->mouseDrag(event(end,anchor,left,true));
        auto image=canvas->createComponentSnapshot(canvas->getLocalBounds());
        expect(yellowAt(image,240)&&yellowAt(image,320),"Yellow guides follow moved item boundaries");
        const auto source=image.getPixelAt(70,90),target=image.getPixelAt(270,90);
        expect(target.getRed()>100 && target.getRed()>target.getGreen()*1.5,"Moved item renders its real red surface, not a translucent green rectangle");
        expect(source.getRed()<100,"Original item disappears while moving");
        expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"Drag drawing does not mutate the saved project");
        canvas->mouseUp(event(end,anchor,ModifierKeys::shiftModifier,true));
        expect(std::abs(session.song()->tracks.front().clips.front().startTime-12)<.001,"Release commits pointer position");
        session.undo();expect(JSON::toString(ProjectCodec::encode(session.project()))==before,"One undo restores the item");
    });
    test("Ruler range drives looping and resizes without moving items or cursors", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        auto fixture=projectFixture();fixture.songs.front().tracks.clear();
        session.restoreSnapshot(ProjectCodec::encode(fixture));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("range-input",".json"));workspace.setSize(1366,768);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");expect(canvas!=nullptr,"Canvas available");
        const auto before=JSON::toString(session.snapshot());
        auto event=[&](Point<float> at,Point<float> anchor,int mods,bool dragged){return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(mods),1,0,0,0,0,canvas,canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);};
        const int right=ModifierKeys::rightButtonModifier|ModifierKeys::shiftModifier;
        Point<float> anchor{200,60},end{100,60};
        canvas->mouseDown(event(anchor,anchor,right,false));
        expect(!session.selectedTimeRange(),"Press alone creates no selection");
        canvas->mouseDrag(event(end,anchor,right,true));
        const auto range=session.selectedTimeRange();expect(range && range->first<range->second,"Reverse drag normalizes persistent range");
        canvas->mouseUp(event(end,anchor,ModifierKeys::shiftModifier,true));
        expect(session.selectedTimeRange()==range,"Range remains after release");
        expect(JSON::toString(session.snapshot())==before,"Range is transient and does not change the project or cursors");
        session.command(jaras::CommandKind::toggleLoop);
        expect(session.transport().loop.enabled && session.transport().loop.start==range->first && session.transport().loop.end==range->second,"Loop uses selection rather than whole song");
        anchor={200,60};end={250,60};
        const int left=ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier;
        canvas->mouseDown(event(anchor,anchor,left,false));canvas->mouseDrag(event(end,anchor,left,true));canvas->mouseUp(event(end,anchor,ModifierKeys::shiftModifier,true));
        expect(session.selectedTimeRange()->second>range->second && session.transport().loop.end==session.selectedTimeRange()->second,"Dragging edge updates active loop immediately");
        session.command(jaras::CommandKind::escape);expect(!session.transport().loop.enabled && !session.selectedTimeRange(),"Escape cancels loop and removes its selection exactly as on Mac");
        session.selectTimeRange(3,7);session.command(jaras::CommandKind::toggleLoop);
        session.selectTimeRange(4,8);
        expect(session.transport().loop.start==4 && session.transport().loop.end==8 && session.selectedTimeRange()==std::make_pair(4.,8.),"Editing the range updates the active loop and its visual bounds together");
        session.command(jaras::CommandKind::toggleLoop);
        expect(!session.transport().loop.enabled && !session.selectedTimeRange(),"Disabling Repeat leaves no stale selected area");
        session.selectTimeRange(3,7);session.command(jaras::CommandKind::escape);expect(!session.selectedTimeRange(),"Escape still clears an independent manual range");
        session.selectTimeRange(2,5);session.command(jaras::CommandKind::editSeek,{},2);session.command(jaras::CommandKind::toggleLoop);session.command(jaras::CommandKind::play);
        session.core.advance(3.25);expect(session.transport().position>=2 && session.transport().position<5,"Playback wraps inside selected interval");
    });
    test("Timeline bulk deletions isolate categories and undo restores unified regions", [&] {
        auto original=projectFixture();auto &song=original.songs.front();
        jaras::TimelineMarker tempo{uuid(),"Tempo",4,0x999999};tempo.tempoBPM=125;
        song.markers->push_back(tempo);
        const auto root=song.parts.front().id;
        jaras::Part child{uuid(),"Unified child",11,19};child.parentRegionID=root;song.parts.push_back(child);
        jaras::TimelineMarker unified{uuid(),"Unified child",11,0xffcc00};unified.unifiedRegionID=root;unified.sourceRegionID=child.id;song.markers->push_back(unified);
        for(auto kind:{timelineBulk::Kind::tempo,timelineBulk::Kind::regions,timelineBulk::Kind::markers}) {
            Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(original));session.audio.setOffline(true);
            const auto before=JSON::toString(session.snapshot());const auto clips=session.song()->tracks.front().clips.size();
            session.edit([&](auto &project){timelineBulk::erase(project,song.id,kind);},true,kind==timelineBulk::Kind::tempo);
            const auto *current=session.song();
            expect(current->tracks.front().clips.size()==clips,"Bulk region deletion preserves media items");
            if(kind==timelineBulk::Kind::regions)expect(current->parts.empty(),"Deletes wrappers and members together");
            for(const auto &m:current->markers.value_or(std::vector<jaras::TimelineMarker>{}))expect(!timelineBulk::matches(m,kind),"Requested category removed");
            if(kind!=timelineBulk::Kind::regions)expect(std::any_of(current->markers->begin(),current->markers->end(),[&](const auto &m){return m.id==unified.id;}),"Unified region marker protected");
            session.undo();expect(JSON::toString(session.snapshot())==before,"One undo restores entire operation exactly");
            session.redo();expect(session.canUndo(),"Redo remains undoable");
        }
    });
    test("Marker conversion follows VS Hook bounds and restores exactly with undo", [&] {
        auto original=projectFixture();auto &song=original.songs.front();song.duration=40;
        song.parts={jaras::Part{uuid(),"Existing",25,30}};
        song.markers=std::vector<jaras::TimelineMarker>{{uuid(),"First",0,0x123456},{uuid(),"Second",10,0x654321},{uuid(),"No audio",5,1},{uuid(),"*1",8,1},{uuid(),"Inside",26,1},{uuid(),"No audio 2",20,1}};
        song.tracks.front().clips.clear();
        for(auto times: {std::pair<double,double>{0,20},{0,30},{10,25},{8,3}}) {
            jaras::AudioClip clip;clip.id=uuid();clip.name="Take";clip.startTime=times.first;clip.duration=times.second;
            clip.audioFile=jaras::AudioFile{"Stems/take.wav",{}};song.tracks.front().clips.push_back(clip);
        }
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(original));session.audio.setOffline(true);
        const auto before=JSON::toString(session.snapshot());const auto result=markerRegions::plan(*session.song());
        expect(result.plans.size()==2 && result.plans[0].end==10 && result.plans[1].end==25,"Audio-start and next marker/region boundaries match VS Hook");
        expect(result.skipped.size()==4 && result.message().contains("Alinhe o marcador"),"Skipped markers explain corrective action");
        expect(markerRegions::plan(*session.song(),song.markers->at(2).id).plans.empty(),"Invalid individual conversion preserves marker");
        session.edit([&](auto &project){markerRegions::apply(project,song.id,result);});
        const auto after=JSON::toString(session.snapshot());
        expect(session.song()->parts.size()==3 && session.song()->markers->size()==4,"Only eligible markers replaced");
        expect(session.song()->parts[1].color==0x123456 && session.song()->parts[2].color==0x654321,"Colours preserved");
        expect(session.song()->tracks.front().clips.size()==4,"Media preserved");
        session.undo();expect(JSON::toString(session.snapshot())==before,"Single undo restores markers and regions");
        session.redo();expect(JSON::toString(session.snapshot())==after,"Redo restores region identities");
    });
    test("FX removal selects the last remaining effect and handles an empty chain", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        auto settings=fxschema::defaults(true);put(settings,"inserted",Array<var>{"EQ","Compressor","Delay"});
        session.configureEffects(ID{},settings);
        EffectsPanel panel(session,{},[&](String error){expect(false,error);});panel.setSize(920,600);
        auto *remove=dynamic_cast<TextButton*>(panel.findChildWithID("removeEffect"));ListBox *chain=nullptr;
        for(auto *child:panel.getChildren())if(auto *list=dynamic_cast<ListBox*>(child))chain=list;
        expect(remove&&chain,"FX manager controls missing");panel.selectEffect("EQ");remove->onClick();
        expect(chain->getSelectedRow()==1,"Removing first FX did not select last remaining FX");
        panel.selectEffect("Compressor");remove->onClick();expect(chain->getSelectedRow()==0,"One remaining FX was not selected");
        remove->onClick();expect(chain->getSelectedRow()==-1,"Empty chain retained stale selection");
    });
    test("BPM sheet starts with current value and validates edits", [&] {
        double committed=0;String error;
        BPMInputPanel panel("153",[&](double value){committed=value;},[&](String value){error=value;});panel.setSize(390,188);
        auto *input=dynamic_cast<TextEditor*>(panel.findChildWithID("bpmValue"));
        expect(input&&input->getText()=="153","BPM value missing");
        input->setText("1");input->onReturnKey();expect(error.isNotEmpty()&&committed==0,"Invalid tempo was accepted");
        input->setText("153,5");input->onReturnKey();floatingControlTests::pump();
        expect(committed==153.5,"Decimal BPM was not applied");
        auto stream=directory.getChildFile("bpm-input-panel.png").createOutputStream();
        expect(stream&&PNGImageFormat().writeImageToStream(panel.createComponentSnapshot(panel.getLocalBounds()),*stream),"BPM screenshot failed");
    });
    test("Audio settings hide all controls while the transport runs", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Appearance appearance(directory.getNonexistentChildFile("audio-settings",".json"));
        ActionBindings bindings(appearance,session.audio.devices);
        auto count=[](Component &root){int count=0;std::function<void(Component&)> walk=[&](Component &c){
            if(dynamic_cast<ComboBox*>(&c))++count;for(auto *child:c.getChildren())walk(*child);};walk(root);return count;};
        session.command(jaras::CommandKind::play);
        SettingsPanel playing(session,auth,lighting,appearance,bindings,1,[](String){},[]{});playing.setSize(780,580);
        expect(count(playing)==0,"Audio controls remained visible during playback");
        session.command(jaras::CommandKind::stop);
        SettingsPanel stopped(session,auth,lighting,appearance,bindings,1,[](String){},[]{});stopped.setSize(780,580);
        expect(count(stopped)>0,"Audio controls did not return when stopped");
    });
    test("Colour-only editor supports presets, preview, cancel and save", [&] {
        unsigned saved=0,preview=0;bool finished=false;
        {RegionEditor panel("",0x112233,false,[&](String,unsigned colour,bool){saved=colour;},[]{},false,false);
         panel.previewColour=[&](unsigned colour){preview=colour;};panel.finishPreview=[&]{finished=true;};panel.setSize(336,340);
         auto *swatch=dynamic_cast<Button*>(panel.findChildWithID("nameColourSwatch5"));expect(swatch,"Preset missing");swatch->onClick();
         expect(preview==0xf44336,"Preset not previewed");}
        expect(saved==0&&preview==0x112233&&finished,"Dismissal failed to restore original colour");
        RegionEditor panel("",0x112233,false,[&](String,unsigned colour,bool){saved=colour;},[]{},false,false);
        auto *save=dynamic_cast<Button*>(panel.findChildWithID("nameColourSave"));expect(save&&save->isEnabled(),"Colour-only save disabled");save->onClick();
        expect(saved==0x112233,"Colour-only editor did not save");
    });
    test("Project replacement confirmation has rounded app-owned buttons", [&] {
        ProjectOpenConfirmationPanel panel("Untitled",[]{});panel.setSize(460,232);
        expect(panel.findChildWithID("cancelOpenProject")&&panel.findChildWithID("confirmOpenProject"),"Missing confirmation choices");
        auto stream=directory.getChildFile("project-open-confirmation.png").createOutputStream();
        expect(stream&&PNGImageFormat().writeImageToStream(panel.createComponentSnapshot(panel.getLocalBounds()),*stream),"Could not capture confirmation");
    });
    test("Interface scale defaults to 100 percent and persists separately from projects", [&] {
        auto file = directory.getNonexistentChildFile("interface-scale", ".json");
        Appearance preferences(file);
        expect(std::abs(preferences.interfaceScale() - 1.f) < 1e-6, "First-install default");
        expect(preferences.set("jaras.interface.scale", 1.1).wasOk(), "Scale saved");
        expect(std::abs(Appearance(file).interfaceScale() - 1.f) < 1e-6, "Scale restored");
        for (int percent = 75; percent <= 125; percent += 25) {
            expect(preferences.set("jaras.interface.scale", percent / 100.0).wasOk(), "Save scale option");
            expect(std::abs(Appearance(file).interfaceScale() - percent / 100.f) < 1e-6, "Restore scale option");
        }
        for (double legacy : {.6, .7}) {
            expect(preferences.set("jaras.interface.scale", legacy).wasOk(), "Legacy small scale saved");
            expect(std::abs(Appearance(file).interfaceScale() - .75f) < 1e-6, "Legacy scale upgrades to 75 percent");
        }
        expect(preferences.set("jaras.interface.scale", 1.5).wasOk(), "Legacy scale saved");
        expect(std::abs(Appearance(file).interfaceScale() - 1.25f) < 1e-6, "Legacy scale is limited to 125 percent");
    });
    test("Waveforms analyse real stereo media asynchronously and map offsets, rates and loops", [&] {
        const auto file = directory.getNonexistentChildFile("waveform-source", ".wav");
        AudioBuffer<float> samples(2, 96000);
        for (int i = 0; i < samples.getNumSamples(); ++i) {
            const float wave = std::sin((float)(i * 2 * MathConstants<double>::pi * 440 / 48000));
            samples.setSample(0, i, wave * (i < 48000 ? .1f : .7f));
            samples.setSample(1, i, wave * (i < 48000 ? .3f : .05f));
        }
        WavAudioFormat wav;
        auto stream = file.createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
        expect(writer != nullptr, "Waveform fixture writer"); stream.release();
        expect(writer->writeFromAudioSampleBuffer(samples, 0, samples.getNumSamples()), "Waveform fixture write");
        writer.reset();
        WaveformCache cache;
        std::shared_ptr<const WaveformCache::Data> data = cache.request(file);
        const auto deadline = Time::getMillisecondCounterHiRes() + 5000;
        while (!data && Time::getMillisecondCounterHiRes() < deadline) { Thread::sleep(10); data = cache.request(file); }
        expect(data != nullptr && data->sourceChannels == 2 && data->storedChannels == 3, "Source produces two cached channels without embedded waveform");
        expect(data->range(0, .2, .3).second < .11f && data->range(0, 1.2, 1.3).second > .69f, "Real source amplitude retained");
        expect(data->range(1, .2, .3).second > .29f && data->range(1, 1.2, 1.3).second < .06f, "Stereo channels remain independent");
        expect(data->range(0, 3, 4).second == 0, "No fabricated waveform beyond the source");
        jaras::AudioClip clip; clip.sourceOffset = .5; clip.playbackRate = 2;
        expect(std::abs(WaveformCache::sourcePosition(clip, .3) - 1.1) < 1e-8, "Offset and playback rate map source time");
        clip.loopStart = .25; clip.loopLength = .5;
        expect(std::abs(WaveformCache::sourcePosition(clip, .3) - .6) < 1e-8, "Loop maps wrapped source time");
        expect(cache.request(file) == data, "Repeated paint reuses analysis");
    });
    test("Waveform hierarchy preserves signed peaks, mono cancellation and Mac cache format", [&] {
        const auto file = directory.getNonexistentChildFile("waveform-detail", ".wav");
        AudioBuffer<float> samples(2, 131071);
        for (int i = 0; i < samples.getNumSamples(); ++i) {
            const float sample = .2f + .1f * std::sin((float)(i * .013));
            samples.setSample(0, i, sample); samples.setSample(1, i, -sample);
        }
        samples.setSample(0, 65535, .95f); samples.setSample(1, 65535, -.95f);
        WavAudioFormat wav;
        auto stream = file.createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
        expect(writer != nullptr, "PCM writer"); stream.release();
        expect(writer->writeFromAudioSampleBuffer(samples, 0, samples.getNumSamples()), "PCM fixture"); writer.reset();
        std::unique_ptr<AudioFormatReader> reader(wav.createReaderFor(file.createInputStream().release(), true));
        expect(reader != nullptr, "PCM reader");
        auto data = WaveformCache::analyse(*reader);
        expect(data != nullptr, "Peak hierarchy");
        expect(data->range(0, 0, data->duration).first > .099f, "Positive DC is not expanded to zero");
        expect(data->range(1, 0, data->duration).second < -.099f, "Negative DC is not expanded to zero");
        expect(std::abs(data->range(2, 0, data->duration).second) < .0001f, "Mono averages PCM before extrema; opposing channels cancel");
        expect(data->range(0, 0, data->duration).second > .949f, "Single transient survives widest view");
        for (int64 step : {256, 512, 1024, 2048, 16384, 65536}) {
            for (int64 frame = 0; frame < data->frames; frame += step) {
                const int end = (int)std::min(data->frames, frame + step);
                const auto exact = FloatVectorOperations::findMinAndMax(samples.getReadPointer(0, (int)frame), end - (int)frame);
                const auto peak = data->rangeFrames(0, frame, end);
                expect(std::abs(peak.first - exact.getStart()) < .0001f && std::abs(peak.second - exact.getEnd()) < .0001f, "Aligned LOD equals original PCM extrema");
            }
        }
        for (float amplitude : {-24.f, -2.f, -1.f, -.123f, 0.f, .321f, 1.f, 2.f, 24.f})
            expect(std::abs(WaveformCache::decode(WaveformCache::encode(amplitude)) - amplitude) < std::max(.0001f, std::abs(amplitude) * .0005f), "Mac signed logarithmic peak encoding");
        const auto cacheFile = directory.getNonexistentChildFile("peaks", ".waveform");
        const auto stamp = file.getLastModificationTime().toMilliseconds();
        expect(WaveformCache::writeCache(*data, cacheFile, file.getSize(), stamp), "Write JARASPK4 cache");
        auto restored = WaveformCache::readCache(cacheFile, file.getSize(), stamp);
        expect(restored && restored->mappedBytes() > 0 && restored->owned.getSize() == 0, "Cache memory mapped without copying all peaks");
        expect(restored->range(0, 0, data->duration) == data->range(0, 0, data->duration), "Persistent peaks identical");
        expect(!WaveformCache::readCache(cacheFile, file.getSize() + 1, stamp), "Reject stale source size");
        expect(!WaveformCache::readCache(cacheFile, file.getSize(), stamp + 1000), "Reject stale source date");
        restored.reset();
        expect(cacheFile.replaceWithText("JARASPK4"), "Truncate fixture");
        expect(!WaveformCache::readCache(cacheFile, file.getSize(), stamp), "Reject truncated cache");
        WaveformCache cache;
        auto ready = cache.request(file);
        const auto deadline = Time::getMillisecondCounterHiRes() + 5000;
        while (!ready && Time::getMillisecondCounterHiRes() < deadline) { Thread::sleep(10); ready = cache.request(file); }
        expect(ready != nullptr, "Async source ready");
        auto detail = cache.detail(ready, 65535);
        while (!detail && Time::getMillisecondCounterHiRes() < deadline) { Thread::sleep(10); detail = cache.detail(ready, 65535); }
        expect(detail && std::abs(detail->sample(0, 65535) - .95f) < .0001f, "Detailed PCM retains transient at page boundary");
        expect(std::abs(detail->sample(2, 65535)) < .0001f, "Detailed mono matches coarse mono");
        expect(WaveformCache::step(48000, 10) == 2048 && WaveformCache::step(48000, 500) == 48, "LOD matches Mac half-point rule");
        Image image(Image::ARGB, 1024, 80, true); Graphics graphics(image);
        jaras::AudioClip clip; clip.duration = data->duration; clip.playbackRate = 1;
        const auto started = Time::getMillisecondCounterHiRes();
        for (int n = 0; n < 20; ++n)
            WaveformRenderer::draw(graphics, cache, ready, clip, {0, 0, 1024, 80}, {0, 0, 1024, 80}, 1024 / clip.duration, Colours::white);
        expect(Time::getMillisecondCounterHiRes() - started < 2000, "Viewport envelope rendering remains bounded");
    });
    test("Unify and disunify match Mac region, marker, playlist and audio ownership rules", [&] {
        auto project = projectFixture(); auto &song = project.songs.front();
        song.parts[1].startTime = 19; song.parts[1].endTime = 30;
        const auto first=song.parts[0].id,second=song.parts[1].id;
        jaras::Part adjacent{uuid(),"Touching only",30,40}; song.parts.push_back(adjacent);
        song.tracks[0].clips[0].regionOwnerID=first;
        project.regionSetlist.emplace();
        jaras::RegionPlaylist playlist{uuid(),"Show",song.id,{second,first,adjacent.id}};
        project.regionSetlist->playlists.push_back(playlist);
        jaras::SetlistBlock block{uuid(),song.id,playlist.id,"Block",0,first};
        project.regionSetlist->blocks=std::vector<jaras::SetlistBlock>{block};
        const auto media=song.tracks[0].clips[0].audioFile->path;
        expect(regionEditing::overlapping(song,first).size()==2,"Touching edges never join overlapping roots");
        const auto group=regionEditing::unify(project,song.id,first,"Unified");
        expect(song.parts.size()==4&&regionEditing::hasChildren(song,group),"Wrapper retains both complete songs");
        expect(project.regionSetlist->playlists[0].regionIds==std::vector<ID>{group,adjacent.id},"Playlist keeps first occurrence and surviving order");
        expect(project.regionSetlist->blocks->front().beforeRegionId==group,"Block follows unified root");
        expect(song.tracks[0].clips[0].regionOwnerID==first,"Original audio ownership remains with its song");
        for(auto &marker:*song.markers)if(marker.sourceRegionID==first){marker.position=9;marker.name="Edited song";marker.color=0x112233;}
        regionEditing::disunify(project,song.id,group);
        expect(song.parts.size()==3&&!regionEditing::hasChildren(song,group),"Unwrap removes only wrapper");
        const auto restored=std::find_if(song.parts.begin(),song.parts.end(),[&](const auto &p){return p.id==first;});
        expect(restored!=song.parts.end()&&restored->startTime==9&&restored->name=="Edited song"&&restored->color==0x112233,"Edited unified markers restore name, colour and start");
        expect(project.regionSetlist->playlists[0].regionIds==std::vector<ID>{first,second,adjacent.id},"Unwrapped playlist expands chronologically");
        expect(song.tracks[0].clips[0].audioFile->path==media&&song.tracks[0].clips[0].startTime==10,"Region operations never move or replace audio");
        jaras::validate(project);
    });
    test("Disunifying an opened project survives save, reopen, undo and redo without stale parent IDs", [&] {
        auto project = projectFixture(); auto &song = project.songs.front();
        song.tracks.clear(); song.parts[1].startTime = 19; song.parts[1].endTime = 30;
        const auto songID = song.id, childID = song.parts[0].id;
        const auto groupID = regionEditing::unify(project, songID, childID, "Imported family");
        auto original = ProjectCodec::encode(project);
        auto originalSong = list(get(original, "songs"))[0];
        for (auto part : list(get(originalSong, "parts")))
            if (str(part, "id") == text(childID)) put(part, "futureImportMetadata", "retain-child-extension");
        const auto file = directory.getChildFile("codec-disunify-" + text(uuid())).getChildFile("Show.jl");
        ProjectCodec::write(file, original);
        Session session; session.inspection = true; session.audio.setOffline(true); session.load(file);
        session.edit([&](jaras::Project &value) { regionEditing::disunify(value, songID, groupID); });
        const auto assertUnwrapped = [&](const var &raw) {
            const auto decoded = ProjectCodec::decode(raw); // Rejects dangling parent IDs.
            expect(decoded.songs.front().parts.size() == 2 &&
                       std::all_of(decoded.songs.front().parts.begin(), decoded.songs.front().parts.end(),
                                   [](const auto &part) { return !part.parentRegionID; }),
                   "A removed parent came back from the opened document metadata");
            bool extensionKept = false;
            for (const auto &part : list(get(list(get(raw, "songs"))[0], "parts")))
                if (str(part, "id") == text(childID))
                    extensionKept = str(part, "futureImportMetadata") == "retain-child-extension" &&
                                    get(part, "parentRegionID").isVoid();
            expect(extensionKept, "Disunification removed unknown child data or retained its old parent field");
        };
        assertUnwrapped(session.snapshot());
        session.undo();
        expect(session.song()->parts.size() == 3 && regionEditing::hasChildren(*session.song(), groupID),
               "Undo did not restore the opened family");
        session.redo(); assertUnwrapped(session.snapshot());
        session.save(file); assertUnwrapped(ProjectCodec::read(file));
        session.load(file); assertUnwrapped(session.snapshot());
    });
    test("Cleared marker and region options stay cleared through original JSON, history and encrypted save", [&] {
        auto project = projectFixture(); auto &song = project.songs.front(); song.tracks.clear();
        auto &part = song.parts.front(); part.color = 0x123456; part.uppercaseName = true;
        part.pitchSemitones = 3; part.totalLoop = true;
        part.pitchTrackIDs = std::vector<ID>{}; part.pitchGroupIDs = std::vector<ID>{};
        auto &section = song.markers->front(); section.section = true; section.loopSection = true;
        jaras::TimelineMarker tempo{uuid(), "Tempo", 11, 0x999999};
        tempo.tempoBPM = 130; tempo.tempoBeats = 3; tempo.tempoUnit = 4;
        tempo.tempoReferenceBPM = 120; tempo.tempoTimebase = "free";
        song.markers->push_back(tempo);
        const auto sectionTemplate = song.markers->front();
        auto original = ProjectCodec::encode(project);
        auto originalSong = list(get(original, "songs"))[0];
        for (auto marker : list(get(originalSong, "markers"))) put(marker, "futureImportMetadata", "retain-marker-extension");
        auto originalPart = list(get(originalSong, "parts"))[0];
        put(originalPart, "futureImportMetadata", "retain-part-extension");
        Session session; session.inspection = true; session.audio.setOffline(true); session.restoreSnapshot(original);
        session.edit([](jaras::Project &value) {
            auto &song = value.songs.front(); auto &part = song.parts.front();
            part.color.reset(); part.uppercaseName.reset(); part.pitchSemitones.reset(); part.totalLoop.reset();
            part.pitchTrackIDs.reset(); part.pitchGroupIDs.reset();
            for (auto &marker : *song.markers) {
                marker.section.reset(); marker.loopSection.reset(); marker.tempoBPM.reset();
                marker.tempoBeats.reset(); marker.tempoUnit.reset(); marker.tempoReferenceBPM.reset(); marker.tempoTimebase.reset();
            }
        });
        const auto assertCleared = [&](const var &raw) {
            const auto decoded = ProjectCodec::decode(raw);
            expect(decoded.songs.front().markers->size() == 2, "Clearing marker types removed their positions");
            const auto encodedSong = list(get(raw, "songs"))[0];
            for (const auto &marker : list(get(encodedSong, "markers"))) {
                for (const auto *key : {"section", "loopSection", "tempoBPM", "tempoBeats", "tempoUnit", "tempoReferenceBPM", "tempoTimebase"})
                    expect(get(marker, key).isVoid(), String("Removed marker field returned: ") + key);
                expect(str(marker, "futureImportMetadata") == "retain-marker-extension", "Unknown marker data was lost");
            }
            const auto region = list(get(encodedSong, "parts"))[0];
            for (const auto *key : {"color", "uppercaseName", "pitchSemitones", "totalLoop", "pitchTrackIDs", "pitchGroupIDs"})
                expect(get(region, key).isVoid(), String("Removed region field returned: ") + key);
            expect(str(region, "futureImportMetadata") == "retain-part-extension", "Unknown region data was lost");
        };
        assertCleared(session.snapshot());
        session.undo();
        expect(session.song()->parts.front().color == 0x123456 && session.song()->markers->front().section == true &&
                   session.song()->markers->back().tempoBPM == 130, "Undo lost the original optional fields");
        session.redo(); assertCleared(session.snapshot());
        const auto file = directory.getChildFile("codec-marker-options-" + text(uuid())).getChildFile("Show.jl");
        session.save(file); assertCleared(ProjectCodec::read(file));
        auto cleared = ProjectCodec::decode(session.snapshot());
        cleared.songs.front().markers.reset();
        const auto withoutMarkers = ProjectCodec::encode(cleared, original);
        expect(!ProjectCodec::decode(withoutMarkers).songs.front().markers &&
                   get(list(get(withoutMarkers, "songs"))[0], "markers").isVoid(),
               "An absent marker collection reappeared from the original document");
        // Explicit false/zero values are distinct from an absent option.
        cleared.songs.front().markers = std::vector<jaras::TimelineMarker>{sectionTemplate};
        cleared.songs.front().markers->front().section = false;
        cleared.songs.front().markers->front().loopSection = false;
        cleared.songs.front().parts.front().color = 0;
        cleared.songs.front().parts.front().uppercaseName = false;
        const auto explicitDefaults = ProjectCodec::decode(ProjectCodec::encode(cleared, original));
        expect(explicitDefaults.songs.front().markers->front().section == false &&
                   explicitDefaults.songs.front().markers->front().loopSection == false &&
                   explicitDefaults.songs.front().parts.front().color == 0 &&
                   explicitDefaults.songs.front().parts.front().uppercaseName == false,
               "Explicit false or zero was mistaken for an absent option");
    });
    test("Region deletion preserves other songs, while timeline wrapper deletion restores children", [&] {
        auto project=projectFixture();auto &song=project.songs.front();song.regionOwnershipInitialized=true;
        auto &first=song.parts[0];auto &second=song.parts[1];second.startTime=18;
        const auto firstID=first.id,secondID=second.id,songID=song.id;
        auto owned=song.tracks[0].clips[0];owned.regionOwnerID=firstID;
        auto other=owned;other.id=uuid();other.startTime=19;other.regionOwnerID=secondID;
        song.tracks[0].clips={owned,other};
        jaras::TimelineMarker manual{uuid(),"Other song",19,0xffffff};manual.regionOwnerID=secondID;
        jaras::TimelineMarker tempo{uuid(),"Old unassigned tempo",12,0x999999};tempo.tempoBPM=123;
        song.markers=std::vector<jaras::TimelineMarker>{manual,tempo};
        regionEditing::erase(project,songID,{firstID},true);
        expect(song.parts.size()==1&&song.parts[0].id==secondID,"Only selected top-level song removed");
        expect(song.tracks[0].clips.size()==1&&song.tracks[0].clips[0].id==other.id,"Overlapping audio belonging to another song is preserved");
        expect(song.markers->size()==1&&song.markers->front().id==manual.id,"Owned marker preserved; legacy unassigned tempo inside removed song cleared");
        project=projectFixture();auto &restore=project.songs.front();restore.parts[1].startTime=19;
        const auto group=regionEditing::unify(project,restore.id,restore.parts[0].id,"Group");
        const auto count=restore.tracks[0].clips.size();
        regionEditing::erase(project,restore.id,{group},false);
        expect(restore.parts.size()==2&&restore.tracks[0].clips.size()==count,"Timeline wrapper deletion restores songs and retains audio items");
        jaras::validate(project);
    });
    test("Detected tempo markers use two bars and remove near-integer noise", [&] {
        std::vector<clickTempo::Section> input;
        for(int i=0;i<100;++i)input.push_back({i*.1,i<50?140.164:145.12});
        const auto result=clickTempo::markerSections(input,4,4,10);
        expect(result.size()==2 && result[0].bpm==140 && result[1].bpm==145 && result[1].position==5,"Stable tempo was not rounded or coalesced");
        input.clear();for(int i=0;i<100;++i)input.push_back({i*.1,120.+i});
        for(auto signature:std::vector<std::pair<int,int>>{{4,4},{3,4},{7,8}}){
            const auto spans=clickTempo::markerSections(input,signature.first,signature.second,10);
            for(size_t i=1;i<spans.size();++i)expect(spans[i].position-spans[i-1].position+1e-9>=2.*signature.first*4/signature.second*60/spans[i-1].bpm,"Markers were closer than two bars");
        }
        const auto shortChange=clickTempo::markerSections({{0,140},{.5,160},{1,140}},4,4,20);
        expect(shortChange.size()==1 && shortChange[0].bpm==140,"Short fluctuation left a stale tempo");
    });
    test("Click BPM detection preserves Mac clock phase, meter, rests and tempo changes", [&] {
        for(double rate:{44100.,48000.})for(double bpm:{147.999,130.001,119.9995,155.998})for(int count:{8,64,600}){
            std::vector<double> pulses;for(int i=0;i<count;++i)pulses.push_back(std::round((.123+i*60/bpm)*rate)/rate);
            const auto spans=clickTempo::sections(pulses);
            expect(spans.size()==1&&spans[0].bpm==std::round(bpm)&&spans[0].position==pulses[0],"Near-integer source clocks match Mac");
        }
        std::vector<double> pulses;double time=.123;
        for(int i=0;i<32;++i){pulses.push_back(time);time+=.5;}
        for(int i=0;i<9;++i){pulses.push_back(time);time+=1;}
        auto spans=clickTempo::sections(pulses);
        expect(spans.size()==2&&spans[0].bpm==120&&spans[1].bpm==60,"Sustained slow ending survives");
        pulses.clear();for(int i=0;i<80;++i)pulses.push_back(.123+i*.5);pulses.push_back(pulses.back()+2);
        spans=clickTempo::sections(pulses);expect(spans.size()==1&&spans[0].bpm==120,"Whole-beat rest does not create false tempo");
        for(int signature:{3,4,7}){
            std::vector<clickTempo::Transient> accents;
            for(int i=0;i<signature*5;++i)accents.push_back({i*.5,i%signature==0?.4:.8,{}});
            expect(clickTempo::meter(accents)==signature,"Quieter accented beat detects shortest repeated meter");
        }
        auto song=projectFixture().songs.front();song.tracks[0].name="Click";song.tracks[0].role.id="click";
        auto &clip=song.tracks[0].clips[0];clip.startTime=10;clip.duration=20;clip.sourceOffset=0;
        jaras::Part region{uuid(),"Click song",10,30};song.parts={region};
        const auto detected=clickTempo::markers(song,region,[](const auto &){std::vector<clickTempo::Transient> result;for(int i=0;i<30;++i)result.push_back({.125+i*.5,1,{}});return result;});
        expect(detected.size()==2&&detected[0].position==10&&detected[1].position==10.125,"Intro guard preserves first audible sample anchor");
        clickTempo::insert(song,region,detected);
        expect(song.tracks[0].clips[0].startTime==10&&song.tracks[0].clips[0].playbackRate==1,"Detection does not move or retime the click");
        auto original=song;original.bpm=87;original.beatsPerBar=7;original.markers=std::vector<jaras::TimelineMarker>{{uuid(),"Manual",15,0xff0000}};
        clickTempo::insert(original,region,detected);
        const auto initial=std::find_if(original.markers->begin(),original.markers->end(),[](const auto &m){return m.tempoBPM&&m.position==0;});
        expect(initial!=original.markers->end() && initial->tempoBPM==120 && initial->tempoReferenceBPM==120 && initial->tempoBeats==4 && initial->tempoUnit==4,"Empty lead-in differs from current Mac initial tempo");
        expect(std::any_of(original.markers->begin(),original.markers->end(),[](const auto &m){return m.name=="Manual";}),"Tempo detection removed manual marker");
        const auto count=original.markers->size();clickTempo::insert(original,region,detected);
        expect(original.markers->size()==count,"Repeated BPM application duplicates markers");
        expect(original.tracks[0].clips[0].startTime==song.tracks[0].clips[0].startTime && original.tracks[0].clips[0].playbackRate==1,"Applying BPM changed source items");
        auto atBoundary=detected.front();atBoundary.position=region.endTime;atBoundary.regionOwnerID.reset();original.markers->push_back(atBoundary);
        auto updated=atBoundary;updated.tempoBPM=130;clickTempo::insert(original,region,{updated});
        const auto boundary=std::find_if(original.markers->begin(),original.markers->end(),[&](const auto &m){return m.id==atBoundary.id;});
        expect(boundary!=original.markers->end() && !boundary->regionOwnerID && boundary->tempoBPM==130,"Updating existing onset lost intentional marker ownership");
    });
    test("MP3 click detection keeps a stable clock across compressed frame boundaries", [&] {
        const auto file=directory.getChildFile("click-123.mp3");file.deleteFile();
        const int rate=44100,frames=rate*48;const double period=60./123;
        MP3Writer writer(file,rate,2,192);AudioBuffer<float> pcm(2,4096);
        for(int first=0;first<frames;first+=pcm.getNumSamples()) {
            pcm.clear();const int count=std::min(pcm.getNumSamples(),frames-first);
            for(int n=0;n<count;++n){const double t=(first+n)/(double)rate-.2;
                if(t<0)continue;const double local=std::fmod(t,period);
                if(local<.018){const float value=(float)(.7*std::sin(2*MathConstants<double>::pi*1800*local)*std::exp(-local*220));pcm.setSample(0,n,value);pcm.setSample(1,n,value);}
            }
            writer.write(pcm,count);
        }
        writer.finish();const auto pulses=clickTempo::transients(file);
        std::vector<double> positions;for(const auto &p:pulses)positions.push_back(p.position);
        const auto sections=clickTempo::sections(positions);
        expect(pulses.size()>90&&sections.size()==1&&sections[0].bpm==123,"MP3 frame seeks created false tempo changes");
        for(size_t i=1;i<pulses.size();++i)expect(std::abs(pulses[i].position-pulses[0].position-i*period)<.002,"Decoded click clock drifts between MP3 frames");
    });
    test("TP web serves independent snapshots, shared preview page and bounded media ranges", [&] {
        TeleprompterHTTP first,second;first.start(0,"127.0.0.1");second.start(0,"127.0.0.1");
        auto one=object(),two=object();put(one,"text",String::fromUTF8("TP1 · Canção"));put(two,"text","TP2");
        put(one,"mediaID","current");const auto media=directory.getChildFile("tp-range.mp4");media.replaceWithText("0123456789",false,false,nullptr);
        first.publish(one,media);second.publish(two);
        auto request=[&](TeleprompterHTTP &server,String text){
            StreamingSocket socket;expect(socket.connect("127.0.0.1",server.port(),2000),"TP connection failed");
            expect(socket.write(text.toRawUTF8(),(int)text.getNumBytesAsUTF8())==(int)text.getNumBytesAsUTF8(),"TP request failed");
            String response;const auto until=Time::getMillisecondCounterHiRes()+3000;
            while(Time::getMillisecondCounterHiRes()<until){if(socket.waitUntilReady(true,100)<=0)continue;char bytes[8192];const int n=socket.read(bytes,sizeof(bytes),false);if(n<=0)break;response+=String::fromUTF8(bytes,n);}
            return response;
        };
        auto a=request(first,"GET /state HTTP/1.1\r\nHost: localhost\r\n\r\n"),b=request(second,"GET /state HTTP/1.1\r\nHost: localhost\r\n\r\n");
        expect(a.contains(String::fromUTF8("Canção"))&&b.contains("TP2")&&!b.contains("TP1"),"TP profiles leaked into each other");
        expect(request(first,"GET / HTTP/1.1\r\n\r\n").contains("CatLive Teleprompter"),"Shared browser preview missing");
        expect(request(first,"HEAD /state HTTP/1.1\r\n\r\n").endsWith("\r\n\r\n"),"HEAD returned a body");
        const auto range=request(first,"GET /media/current HTTP/1.1\r\nRange: bytes=2-5\r\n\r\n");
        expect(range.contains("206 Partial Content")&&range.contains("Content-Range: bytes 2-5/10")&&range.endsWith("2345"),"Video range is incorrect");
        expect(request(first,"GET /media/current HTTP/1.1\r\nRange: bytes=-3\r\n\r\n").endsWith("789"),"Video suffix range is incorrect");
        expect(request(first,"GET /media/current HTTP/1.1\r\nRange: bytes=99-\r\n\r\n").contains("416"),"Invalid range was accepted");
        expect(request(first,"GET /media/../anything HTTP/1.1\r\n\r\n").contains("404"),"Non-current media was exposed");
        expect(request(first,"POST /state HTTP/1.1\r\n\r\n").contains("405"),"TP accepted a write request");
        first.stop();expect(!first.enabled()&&second.enabled(),"TP1 shutdown stopped TP2");
    });
    test("Resource metrics use process CPU normalized by cores and sample once per second", [&] {
        expect(std::abs(ResourceUsage::cpuPercent(1, 2, 8) - 6.25) < 1e-8, "CPU is normalized by active processors");
        expect(ResourceUsage::cpuPercent(99, 1, 1) == 100, "CPU is bounded");
        ResourceUsage usage;
        expect(usage.sample() && usage.samples == 1, "Initial sample");
        expect(!usage.cpu && usage.ram && *usage.ram > 0 && *usage.ram < 100, "Initial CPU awaits an interval; RAM belongs to the process");
        expect(!usage.sample() && usage.samples == 1, "Paint/timer frequency cannot resample within a second");
    });
    test("Song display tempo belongs to its own region", [&] {
        auto song = projectFixture().songs.front();
        jaras::TimelineMarker tempo; tempo.id = uuid(); tempo.position = 10; tempo.tempoBPM = 123;
        song.markers->push_back(tempo);
        expect(regionCaption(song, &song.parts.front()).endsWith("123 bpm"), "Region tempo shown");
        expect(!regionCaption(song, &song.parts.back()).contains("bpm"), "Previous song tempo does not leak into next display");
    });
    test("Closing panel renders the embedded original logo", [&] {
        auto logo = ImageCache::getFromMemory(BinaryData::CatLiveSplash_png,
                                              BinaryData::CatLiveSplash_pngSize);
        expect(logo.isValid() && logo.getWidth() == 1254 && logo.getHeight() == 1254,
               "Original logo decodes from executable");
        StartupSplash splash(true);
        splash.setVisible(false);
        Image output(Image::ARGB, splash.getWidth(), splash.getHeight(), true, SoftwareImageType());
        Graphics graphics(output);
        // A transparent native peer may enter paint() with a transparent current brush.
        graphics.setOpacity(0.f);
        splash.paint(graphics);
        int visiblePixels = 0;
        for (int y = 36; y < 200; ++y)
            for (int x = 36; x < 221; ++x)
                if (output.getPixelAt(x, y).getAlpha() > 100 && output.getPixelAt(x, y) != theme::panel)
                    ++visiblePixels;
        expect(visiblePixels > 3000, "Closing panel contains visible logo artwork distinct from its background");
        FileOutputStream stream(directory.getChildFile("closing-logo.png"));
        stream.setPosition(0);
        stream.truncate();
        PNGImageFormat().writeImageToStream(output, stream);
    });
    compactTextBaselineTests::registerTests(test, skipped);
    test("Embedded font faces and persisted setlist appearance", [&] {
        auto file = directory.getNonexistentChildFile("appearance", ".json");
        Appearance settings(file);
        expect(settings.fontStyle() == 0 && !settings.regionIDs(), "Appearance defaults");
        expect(settings.setlistColour(false, false) == Colours::white,
               "All Regions default colour");
        expect(settings.set("jaras.setlist.fontStyle", 2).wasOk(), "Persist italic choice");
        expect(settings.set("jaras.setlist.idMode", "region").wasOk(), "Persist ID mode");
        expect(settings.set("jaras.setlist.playlistTextColor", 0x123456).wasOk(),
               "Persist playlist colour");
        Appearance restored(file);
        expect(restored.fontStyle() == 2 && restored.regionIDs(), "Reload preferences");
        expect(restored.setlistColour(true, false) == Colour(0xff123456), "Reload playlist colour");
        expect(restored.setlistColour(false, true) == Colour(0xffffeb3b),
               "Independent drawer colour");
        auto regular = theme::font(13), bold = theme::font(13, true),
             italic = restored.setlistFont();
        expect(regular.getTypefaceName() == "Inter", "Embedded Inter family loaded");
        expect(bold.getTypefaceStyle().containsIgnoreCase("Bold"), "Real embedded bold face");
        expect(italic.getTypefaceStyle().containsIgnoreCase("Italic"), "Real embedded italic face");
        expect(std::abs(regular.getHeightInPoints() - 13.f * .9f) < .01f, "Compact Windows text remains independent of display DPI");
    });
    test("Timecode LTC physical route, Master bypass, spans and main-only playback", [&] {
        auto project = projectFixture();
        auto& song = project.songs[0]; song.duration = 10;
        song.parts = {{uuid(), "Clock", 1, 2}};
        jaras::Track track; track.id = uuid(); track.name = "Timecode"; track.role.id = "timecode";
        track.timecode = jaras::TimecodeSettings{}; track.timecode->mode = "ltc"; track.timecode->offset = 3600;
        track.outputs = std::vector<jaras::OutputPatch>{{3, 2}};
        song.tracks = {track}; jaras::synchronizeTimecode(project);
        auto& item = song.tracks[0].clips[0]; item.startTime = .5; item.duration = 2;
        project.masterMute = true; project.masterVolume = 0;
        for (double rate : {44100., 48000.}) {
            AudioEngine engine; engine.prepareOffline(rate); engine.prepareSong(song, directory, {}, &project);
            AudioEngine::State state; state.playing = true;
            state.scope[0].minimum = 100; // A child's stem ownership cannot mask generated LTC.
            AudioBuffer<float> pcm(4, 512);
            auto render = [&](double position) {
                state.position = position; engine.transport(state);
                engine.render(pcm.getArrayOfWritePointers(), 4, 512);
                return pcm.getMagnitude(2, 0, 512);
            };
            expect(render(.3) == 0, "LTC starts at its item, not at its positive offset");
            expect(render(.75) > .2f, "Extended LTC item emits before original region");
            expect(pcm.getMagnitude(0,0,512) == 0 && pcm.getMagnitude(1,0,512) == 0, "LTC uses the selected physical pair");
            for (int n=0;n<512;++n) expect(pcm.getSample(2,n) == pcm.getSample(3,n), "Stereo LTC matches on both channels");
            expect(render(2.25) > .2f, "LTC continues through extended right edge");
            expect(render(2.6) == 0, "LTC ends at item boundary");
            state.subPlaying = true; state.subPosition = .75;
            expect(render(.75) <= .251f, "Sub Play does not double timecode");
            state.playing = false;
            expect(render(.75) == 0, "Sub Play alone never emits timecode");
            state.playing = true; song.tracks[0].mute = true; engine.setMixer(project,song);
            expect(render(.75) == 0 && engine.trackPeak(track.id) == 0, "Mute stops LTC and resets its meter");
            song.tracks[0].mute = false; engine.setMixer(project,song);
            expect(render(.75) > .2f, "Unmute restores LTC");
        }
        song.tracks[0].timecode->mode = "mtc";
        AudioEngine midiOnly; midiOnly.prepareOffline(48000); midiOnly.prepareSong(song,directory,{},&project);
        AudioEngine::State state; state.playing = true; state.position = .75; midiOnly.transport(state);
        AudioBuffer<float> pcm(4,512); midiOnly.render(pcm.getArrayOfWritePointers(),4,512);
        expect(pcm.getMagnitude(0,512) == 0, "MTC generates no audio");
    });
    test("Encrypted project round trip and authenticated tamper rejection", [&] {
        auto p = projectFixture();
        auto root = ProjectCodec::encode(p);
        auto extra = object();
        put(extra, "preserved", "future-value");
        put(root, "futureFeature", extra);
        auto lighting = object();
        auto destinations = object();
        put(destinations, "region:existing", 0);
        put(destinations, "region:removed", 7);
        put(lighting, "assignments", destinations);
        put(lighting, "committed", true);
        auto startTimes = object();
        put(startTimes, "existing", 0.0);
        put(startTimes, "later", 123.125);
        put(lighting, "starts", startTimes);
        auto ma = object();
        put(ma, "sequence", 4);
        put(ma, "page", 2);
        put(ma, "executor", 7);
        put(ma, "timecode", 9);
        put(ma, "slot", 2);
        put(lighting, "grandMA2", ma);
        auto future = object();
        put(future, "label", String::fromUTF8("São João 🎵"));
        Array<var> values;
        values.add(var());
        values.add(false);
        values.add(0);
        values.add(-1);
        values.add(1.25);
        values.add(var((int64)9007199254740993LL));
        put(future, "values", values);
        put(lighting, "future", future);
        put(root, "windowsLighting", lighting);
        auto sealed = ProjectCodec::seal(JSON::toString(root, true));
        auto decoded = JSON::parse(ProjectCodec::unseal(sealed));
        auto restored = ProjectCodec::decode(decoded);
        expect(restored.name == p.name, "Project name changed");
        auto round = ProjectCodec::encode(restored, decoded);
        expect(str(get(round, "futureFeature"), "preserved") == "future-value",
               "Unknown fields lost");
        auto file = directory.getChildFile("Roundtrip/Show.jl");
        ProjectCodec::write(file, round);
        expect(ProjectCodec::decode(ProjectCodec::read(file)).songs[0].parts.size() == 2,
               "Parts lost");
        auto *bytes = (uint8 *)sealed.getData();
        bytes[sealed.getSize() - 1] ^= 1;
        bool rejected = false;
        try {
            ProjectCodec::unseal(sealed);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Tampered ciphertext accepted");
        auto nonceA = ProjectCodec::seal("{}"), nonceB = ProjectCodec::seal("{}");
        expect(nonceA != nonceB, "Nonce was reused");
        directory.getChildFile("fixture.json").replaceWithText(JSON::toString(root));
        auto known = ProjectCodec::seal(JSON::toString(root, true));
        directory.getChildFile("fixture.jl").replaceWithData(known.getData(), known.getSize());
    });
    test("Legacy Windows IDs migrate atomically to Swift UUID spelling", [&] {
        const auto p = projectFixture();
        auto fixture = ProjectCodec::encode(p);
        auto extension = object();
        put(extension, "track", text(p.songs[0].tracks[0].id));
        auto keyed = object();
        put(keyed, Identifier(text(p.songs[0].tracks[0].id)), "preserved");
        put(extension, "keyed", keyed);
        put(fixture, "extension", extension);
        auto serialized = JSON::toString(fixture);
        const std::function<void(const var &)> verifyIDs = [&](const var &v) {
            if (auto *node = v.getDynamicObject()) {
                const auto id = str(v, "id");
                if (id.isNotEmpty()) {
                    expect(id.length() == 36 && Uuid(id).toDashedString().equalsIgnoreCase(id),
                           "Generated ID is not a Swift UUID");
                    serialized = serialized.replace(id, id.removeCharacters("-"));
                }
                for (const auto &property : node->getProperties())
                    verifyIDs(property.value);
            } else if (auto *array = v.getArray())
                for (const auto &value : *array)
                    verifyIDs(value);
        };
        verifyIDs(fixture);
        const auto legacy = JSON::parse(serialized);
        const auto migrated = ProjectCodec::canonicalIDs(legacy);
        auto expected = fixture.clone();
        put(expected, "extension", get(legacy, "extension"));
        expect(JSON::toString(migrated) == JSON::toString(expected),
               "Migration changed data or lost UUID references");
        const auto model = ProjectCodec::decode(legacy);
        expect(model.id == p.id && model.songs[0].tracks[0].id == p.songs[0].tracks[0].id,
               "Legacy model IDs were not migrated");
        const auto round = ProjectCodec::encode(model, legacy);
        expect(str(get(round, "extension"), "track") == text(p.songs[0].tracks[0].id).removeCharacters("-"),
               "Unknown extension reference was lost");
        const auto target = directory.getChildFile("legacy-uuid/Show.jl");
        ProjectCodec::write(target, legacy);
        expect(JSON::toString(ProjectCodec::read(target)) == JSON::toString(expected),
               "Saved legacy project is not portable");
        auto timed = p;
        jaras::Track timecode; timecode.id = uuid(); timecode.name = "Timecode"; timecode.role.id = "timecode";
        timed.songs[0].tracks.push_back(timecode);
        jaras::synchronizeTimecode(timed);
        auto &item = timed.songs[0].tracks.back().clips[0];
        item.timecodeStartOffset = .25;
        const auto canonicalItem = item.id;
        auto oldJSON = JSON::toString(ProjectCodec::encode(timed));
        const auto oldRegion = text(timed.songs[0].parts[0].id).removeCharacters("-");
        oldJSON = oldJSON.replace(text(canonicalItem), oldRegion + "-timecode");
        oldJSON = oldJSON.replace(text(timed.songs[0].parts[0].id), oldRegion);
        auto migratedTiming = ProjectCodec::decode(JSON::parse(oldJSON));
        jaras::synchronizeTimecode(migratedTiming);
        const auto &restoredItem = migratedTiming.songs[0].tracks.back().clips[0];
        expect(restoredItem.id == canonicalItem && restoredItem.timecodeStartOffset == .25,
               "Legacy generated Timecode lost identity or timing edits");
    });
    test("Portable media paths reject traversal, absolute paths and drive paths", [&] {
        for (auto path : {"../secret.wav", "C:/secret.wav", "/secret.wav", "Stems/../../secret.wav",
                          "\\\\server\\share.wav"}) {
            bool rejected = false;
            try {
                ProjectCodec::resolveMedia(directory, path);
            } catch (...) {
                rejected = true;
            }
            expect(rejected, path);
        }
        expect(ProjectCodec::resolveMedia(directory, "Stems/test.wav").isAChildOf(directory),
               "Relative media rejected");
    });
    test("Windows credential protection and standard signed license proofs", [&] {
        MemoryBlock secret("test-token", 10);
        auto encrypted = Auth::protect(secret);
        expect(encrypted != secret, "Token not encrypted");
        expect(Auth::unprotect(encrypted) == secret, "DPAPI round trip failed");
        expect(!Auth::verifyEntitlement(object(), text(uuid()), text(uuid())),
               "Unsigned entitlement accepted");
        const auto fixture = JSON::parse(R"fixture({"account":"11111111-2222-4333-8444-555555555555","installation":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","publicKey":"11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=","entitlement":{"status":"active","planId":"vitalicio","expiresAt":"2099-01-01T00:00:00.000Z","offlineValidUntil":"2026-10-22T12:00:00.000Z","serverTime":"2026-10-15T12:00:00.000Z","maxDevices":3,"features":["desktop"],"proof":{"payload":"eyJ2ZXJzaW9uIjoxLCJhY2NvdW50SWQiOiIxMTExMTExMS0yMjIyLTQzMzMtODQ0NC01NTU1NTU1NTU1NTUiLCJpbnN0YWxsYXRpb25JZCI6IkFBQUFBQUFBLUJCQkItNENDQy04RERELUVFRUVFRUVFRUVFRSIsInN0YXR1cyI6ImFjdGl2ZSIsInBsYW5JZCI6InZpdGFsaWNpbyIsImV4cGlyZXNBdCI6IjIwOTktMDEtMDFUMDA6MDA6MDAuMDAwWiIsIm9mZmxpbmVWYWxpZFVudGlsIjoiMjAyNi0xMC0yMlQxMjowMDowMC4wMDBaIiwic2VydmVyVGltZSI6IjIwMjYtMTAtMTVUMTI6MDA6MDAuMDAwWiIsIm1heERldmljZXMiOjMsImZlYXR1cmVzIjpbImRlc2t0b3AiXX0=","signature":"P68XquZmnG2pRMmwj0qOrxDSfFm+9gcbe602Y8AhZuk9/68yHmkjsirnQqgDmKdHuC1GV3j5pB8QwJncClU9Ag=="}}})fixture");
        const auto entitlement = get(fixture, "entitlement");
        const auto account = str(fixture, "account"), installation = str(fixture, "installation"),
                   key = str(fixture, "publicKey");
        expect(license::verify(entitlement, account, installation, key),
               "Independent Node Ed25519 signature with standard Base64 rejected");
        expect(!Auth::verifyEntitlement(entitlement, account, installation),
               "Test key replaced the production license key");
        auto altered = entitlement.clone();
        put(altered, "maxDevices", 99);
        expect(!license::verify(altered, account, installation, key), "Changed license accepted");
        altered = entitlement.clone();
        auto proof = get(altered, "proof");
        auto signature = str(proof, "signature");
        put(proof, "signature", (signature.startsWithChar('A') ? "B" : "A") + signature.substring(1));
        expect(!license::verify(altered, account, installation, key), "Changed signature accepted");
        expect(!license::verify(entitlement, text(uuid()), installation, key), "Other account accepted");
        expect(!license::verify(entitlement, account, text(uuid()), key), "Other installation accepted");
        MemoryBlock legacy("fake", 4), decoded;
        expect(!license::decodeBase64(legacy.toBase64Encoding(), decoded, 64), "JUCE private encoding accepted");
        expect(Auth::canonicalInstallationID(installation.removeCharacters("-")) == installation,
               "Legacy installation UUID was not migrated without changing identity");
        expect(Auth::canonicalInstallationID(installation.toLowerCase()) == installation,
               "Existing installation identity was changed");
    });
    test("Windows device names follow the discovery UTF-8 byte limit", [&] {
        expect(Auth::validatedDeviceName("  PC do palco  ") == "PC do palco", "Trim chosen name");
        expect(Auth::validatedDeviceName(String::fromUTF8("João · Palco")) == String::fromUTF8("João · Palco"), "Accented device names");
        expect(Auth::validatedDeviceName(String::repeatedString("a", 63)).isNotEmpty(), "63 bytes allowed");
        expect(Auth::validatedDeviceName(String::repeatedString("a", 64)).isEmpty(), "64 bytes rejected");
        expect(Auth::validatedDeviceName(String::repeatedString(String::fromUTF8("é"), 32)).isEmpty(), "Limit bytes, not characters");
        for (auto value : {"", "   ", "---", "PC\nPalco", "PC\tPalco"}) expect(Auth::validatedDeviceName(value).isEmpty(), "Invalid display name rejected");
    });
    test("Selected tracks share REC, mixer buttons and relative fader/pan changes", [&] {
        auto project = projectFixture(); auto &song = project.songs[0];
        auto first = song.tracks[0]; first.clips.clear(); first.audioFile.reset(); first.id=uuid(); first.volume=.5;first.pan=-.2;first.mute=false;first.solo=false;
        auto second=first;second.id=uuid();second.volume=.25;second.pan=.1;second.mute=true;
        auto third=first;third.id=uuid();
        song.tracks={first,second,third};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        const std::set<ID> selection{first.id,second.id};
        session.cycleRecordArm(first.id,selection);
        expect(session.recordArm(first.id)==1&&session.recordArm(second.id)==1&&session.recordArm(third.id)==0,"Arm every selected track");
        session.cycleRecordArm(first.id,selection);
        expect(session.recordArm(first.id)==2&&session.recordArm(second.id)==2,"Same next REC mode");
        session.mixerCommand(jaras::CommandKind::mute,first.id,selection);
        expect(session.song()->tracks[0].mute&&session.song()->tracks[1].mute&&!session.song()->tracks[2].mute,"Mute mixed selection consistently");
        session.mixerCommand(jaras::CommandKind::solo,first.id,selection);
        expect(session.song()->tracks[0].solo&&session.song()->tracks[1].solo&&!session.song()->tracks[2].solo,"Solo selection");
        session.mixerCommand(jaras::CommandKind::volume,first.id,selection,1.);
        expect(std::abs(session.song()->tracks[0].volume-1.)<1e-8&&std::abs(session.song()->tracks[1].volume-.5)<1e-8&&session.song()->tracks[2].volume==.5,"Keep relative levels");
        session.mixerCommand(jaras::CommandKind::pan,first.id,selection,.2);
        expect(std::abs(session.song()->tracks[0].pan-.2)<1e-8&&std::abs(session.song()->tracks[1].pan-.5)<1e-8,"Keep pan offsets");
        session.beginMixerGesture(jaras::CommandKind::pan,first.id);
        session.mixerCommand(jaras::CommandKind::pan,first.id,selection,1.);
        session.mixerCommand(jaras::CommandKind::pan,first.id,selection,.2);
        session.endMixerGesture();
        expect(std::abs(session.song()->tracks[1].pan-.5)<1e-8,"Pan returns to its original offset after clipping");
        session.setRecordingSelection(first.id,selection);
        expect(session.recordingArmed(first.id)&&session.recordingArmed(second.id)&&!session.recordingArmed(third.id),"Automatic REC follows the whole selection");
        session.setRecordingSelection(third.id);
        expect(!session.recordingArmed(first.id)&&!session.recordingArmed(second.id),"Automatic REC disarms deselected tracks");
        session.mixerCommand(jaras::CommandKind::mute,third.id,selection);
        expect(session.song()->tracks[0].mute&&session.song()->tracks[1].mute&&session.song()->tracks[2].mute,"Unselected control acts independently");
    });
    test("Save and Save As require one project per folder", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        const auto root=directory.getNonexistentChildFile("project-folder-policy",{},false);
        const auto first=root.getChildFile("One.jl"), second=root.getChildFile("Two.jl");
        session.save(first); const auto before=first.loadFileAsString();
        bool rejected=false;try{session.save(second);}catch(const std::exception &e){rejected=String::fromUTF8(e.what()).contains("pasta separada");}
        expect(rejected&&!second.existsAsFile()&&first.loadFileAsString()==before&&session.document==first,"Reject second document before writing or changing active path");
        session.save(first);expect(first.existsAsFile(),"Ordinary Save still works");
        const auto separate=root.getChildFile("Separate/Two.jl");session.save(separate);expect(separate.existsAsFile(),"Save As in a separate folder works");
    });
    test("Native DSP delay timing, compressor gain and live piano rendering", [&] {
        NativeFX fx;
        auto settings = object();
        Array<var> order;
        order.add("Delay");
        put(settings, "inserted", order);
        put(settings, "delayEnabled", true);
        put(settings, "delayTime", .01);
        put(settings, "delayMix", 100);
        put(settings, "feedback", 0);
        fx.prepare(settings, 48000);
        AudioBuffer<float> buffer(2, 1024);
        buffer.clear();
        buffer.setSample(0, 0, 1);
        buffer.setSample(1, 0, 1);
        fx.process(buffer, 1024);
        expect(std::abs(buffer.getSample(0, 480) - 1) < .0001f && buffer.getSample(0, 0) == 0,
               "Delay is not aligned to samples");
        settings = object();
        order.clear();
        order.add("Compressor");
        put(settings, "inserted", order);
        put(settings, "compressorEnabled", true);
        put(settings, "threshold", -20);
        put(settings, "ratio", 4);
        put(settings, "attack", .001);
        put(settings, "release", .1);
        fx.prepare(settings, 48000);
        for (int i = 0; i < 30; ++i) {
            for (int ch = 0; ch < 2; ++ch)
                FloatVectorOperations::fill(buffer.getWritePointer(ch), .5f, 1024);
            fx.process(buffer, 1024);
        }
        expect(buffer.getMagnitude(0, 1024) > .05f && buffer.getMagnitude(0, 1024) < .25f,
               "Compressor did not reduce gain");
        Instrument piano;
        MidiBuffer notes;
        notes.addEvent(MidiMessage::noteOn(1, 69, .8f), 0);
        buffer.clear();
        piano.render(buffer, notes, 1024);
        expect(buffer.getMagnitude(0, 1024) > .01f, "Live piano produced no audio");
        piano.stop();
        notes.clear();
        buffer.clear();
        piano.render(buffer, notes, 1024);
        expect(buffer.getMagnitude(0, 1024) == 0, "Piano panic left stuck notes");
    });
    test("Project tab sessions share one audio host but preserve independent edits undo and transport", [&] {
        Session first;
        Session second(first.audio.deviceHost);
        first.inspection = second.inspection = true;
        expect(&first.audio.devices == &second.audio.devices, "Tabs opened independent hardware drivers");
        expect(first.project().id != second.project().id, "Tabs shared a project identity");
        first.edit([](jaras::Project &p) { p.name = "First edited"; }, false);
        second.edit([](jaras::Project &p) { p.name = "Second edited"; }, false);
        first.undo();
        expect(first.project().name != "First edited" && second.project().name == "Second edited", "Undo crossed a tab boundary");
        first.redo();
        first.command(jaras::CommandKind::play);
        second.command(jaras::CommandKind::editSeek, {}, 24);
        expect(first.transport().playing && !second.transport().playing, "Selecting another tab stopped background playback");
        second.command(jaras::CommandKind::play);
        expect(first.transport().playing && second.transport().playing, "Tabs cannot play independently");
        first.command(jaras::CommandKind::stopAll);
        expect(second.transport().playing, "Stop leaked into another project");
        second.command(jaras::CommandKind::stopAll);
        expect(first.project().name == "First edited" && second.dirty, "Tab navigation discarded edits");
    });
    test("Live MIDI REC gates new notes but preserves sustain and note releases after switching tracks", [&] {
        MidiBuffer input, previous, current;
        input.addEvent(MidiMessage::controllerEvent(2, 64, 127), 0);
        input.addEvent(MidiMessage::noteOn(2, 60, (uint8)100), 10);
        appendLiveTrackMIDI(previous, input, 128, true);
        expect(previous.getNumEvents() == 2, "Armed track lost live notes or sustain");
        input.clear(); previous.clear();
        input.addEvent(MidiMessage::noteOff(2, 60), 5);
        input.addEvent(MidiMessage::noteOn(2, 62, (uint8)100), 10);
        input.addEvent(MidiMessage::controllerEvent(2, 64, 0), 20);
        input.addEvent(MidiMessage::noteOn(2, 64, (uint8)0), 25);
        input.addEvent(MidiMessage::allNotesOff(2), 30);
        appendLiveTrackMIDI(previous, input, 128, false);
        appendLiveTrackMIDI(current, input, 128, true);
        expect(current.getNumEvents() == 5, "New armed track did not receive the performance");
        expect(previous.getNumEvents() == 4, "Disarmed track lost note/pedal releases");
        bool pedalReleased = false;
        for (const auto event : previous) {
            expect(!event.getMessage().isNoteOn(), "Disarmed track received a new note");
            if (event.getMessage().isControllerOfType(64))
                pedalReleased = event.getMessage().getControllerValue() == 0 && event.samplePosition == 20;
        }
        expect(pedalReleased, "Pedal release did not reach the previous track at its original sample");
    });
    test("MIDI clips preserve source offset, loops, rate, gain and frozen state", [&] {
        jaras::Track track;
        jaras::AudioClip clip;
        clip.id = uuid();
        clip.name = "MIDI";
        clip.duration = 1;
        clip.sourceOffset = .25;
        clip.loopStart = 0;
        clip.loopLength = .5;
        clip.gain = .5;
        clip.pitchSemitones = 12;
        jaras::MIDIItem midi;
        midi.sourceBPM = 120;
        midi.notes.push_back({uuid(), 0, .5, 60, 100, 2});
        clip.midi = midi;
        track.clips = {clip};
        auto notes = playbackNotes(track);
        expect(notes.size() == 2, "MIDI loop repetitions or trimmed notes are incorrect");
        expect(std::abs(notes[0].start - .25) < 1e-9 && std::abs(notes[1].end - 1) < 1e-9 &&
                   notes[0].pitch == 72 && notes[0].velocity == 50 && notes[0].channel == 2,
               "MIDI source-time or note properties changed");
        track.clips[0].playbackRate = 2;
        notes = playbackNotes(track);
        expect(notes.size() == 4 && std::abs(notes[0].start - .125) < 1e-9,
               "MIDI playback rate was ignored");
        track.clips[0].muted = true;
        expect(playbackNotes(track).empty(), "Muted MIDI clip still produced notes");
        track.clips[0].muted = false;
        track.clips[0].frozenMIDI = true;
        expect(playbackNotes(track).empty(), "Frozen MIDI was doubled with its audio render");
    });
    const auto soundFontPath = SystemStats::getEnvironmentVariable("CATLIVE_TEST_SF2", {});
    if (soundFontPath.isNotEmpty())
        test("Real SF2 timeline playback, note chase, Sub Play, routing and portable bank", [&] {
            const File source(soundFontPath);
            expect(instrumentAssets::validBank(source), "SF2 test fixture is missing or invalid");
            const auto folder = directory.getChildFile("MidiProject");
            folder.getChildFile("Instruments").createDirectory();
            expect(source.copyFileTo(folder.getChildFile("Instruments/fixture.sf2")),
                   "Could not stage the SF2 fixture");
            auto fx = object(), parameters = object();
            put(fx, "inserted", Array<var>{"Instruments"});
            put(fx, "instrumentID", "fixture");
            put(parameters, "release", .01);
            put(fx, "instrumentParameters", parameters);
            jaras::Song song;
            song.id = uuid();
            song.name = "MIDI";
            song.duration = 2;
            jaras::Track track;
            track.id = uuid();
            track.name = "Instrument";
            track.fxJSON = utf8(JSON::toString(fx, true));
            track.outputs = std::vector<jaras::OutputPatch>{{3, 2}};
            jaras::AudioClip clip;
            clip.id = uuid();
            clip.name = "MIDI";
            clip.startTime = .25;
            clip.duration = .75;
            jaras::MIDIItem notes;
            notes.sourceBPM = 120;
            notes.notes.push_back({uuid(), 0, 1, 60, 110, 1});
            clip.midi = notes;
            track.clips = {clip};
            song.tracks = {track};
            AudioEngine engine;
            engine.prepareSong(song, folder);
            expect(engine.missingFiles.isEmpty() && engine.unsupported.isEmpty(),
                   "Native instrument was not loaded");
            AudioBuffer<float> output(4, 480);
            AudioEngine::State state;
            state.playing = true;
            state.position = .1;
            engine.transport(state);
            engine.render(output.getArrayOfWritePointers(), 4, 480);
            expect(output.getMagnitude(0, 480) == 0, "MIDI sounded before its item");
            state.position = .35;
            engine.transport(state);
            engine.render(output.getArrayOfWritePointers(), 4, 480);
            const auto first = output.getMagnitude(2, 0, 480);
            expect(first > .0001f && output.getMagnitude(0, 0, 480) == 0,
                   "Seek did not chase the held note or ignored output patch");
            state.subPlaying = true;
            state.subPosition = .35;
            engine.transport(state);
            engine.render(output.getArrayOfWritePointers(), 4, 480);
            expect(std::abs(output.getMagnitude(2, 0, 480) - 2 * first) <
                       std::max(.0001f, first * .05f),
                   "Main and Sub Play did not use independent instrument voices");
            state.playing = state.subPlaying = false;
            engine.transport(state);
            engine.render(output.getArrayOfWritePointers(), 4, 480);
            expect(output.getMagnitude(0, 480) == 0, "Stopping MIDI left stuck notes");
            Session saved;
            saved.mediaDirectory = folder;
            saved.edit([&](jaras::Project &p) {
                p.songs[0].tracks = song.tracks;
                p.songs[0].duration = 2;
            });
            const auto target = directory.getChildFile("MidiPortable/Show.jl");
            saved.save(target);
            auto copied = target.getParentDirectory().getChildFile("Instruments/fixture.sf2");
            expect(copied.existsAsFile(), "Save As omitted the instrument bank");
            FileInputStream a(source), b(copied);
            expect(SHA256(a) == SHA256(b), "Portable instrument bank was changed");
            Session reopened;
            reopened.load(target);
            expect(reopened.audio.missingFiles.isEmpty() &&
                       reopened.song()->tracks[0].clips[0].midi.has_value(),
                   "Portable MIDI project did not reopen");
        });
    else
        skipped.add("Real SF2 audio: set CATLIVE_TEST_SF2 to an installed bank.");
    test("Polyphonic pitch transposes stereo without changing rendered length", [&] {
        constexpr int block = 480, rate = 48000;
        for (int semitones : {-12, 12}) {
            NativeFX fx;
            auto settings = object();
            put(settings, "inserted", Array<var>{"Pitch"});
            put(settings, "pitchEnabled", true);
            put(settings, "pitchSemitones", semitones);
            fx.prepare(settings, rate);
            expect(fx.unsupported.isEmpty(), "Pitch was left unsupported");
            AudioBuffer<float> buffer(2, block);
            int crossings[2]{0, 0};
            float previous[2]{0, 0};
            double energy[2]{0, 0};
            for (int frame = 0; frame < 200; ++frame) {
                for (int c = 0; c < 2; ++c)
                    for (int n = 0; n < block; ++n)
                        buffer.setSample(c, n,
                                         (float)(.2 * std::sin(MathConstants<double>::twoPi *
                                                               (c == 0 ? 440 : 660) *
                                                               (frame * block + n) / rate)));
                fx.process(buffer, block);
                if (frame >= 100)
                    for (int c = 0; c < 2; ++c)
                        for (int n = 0; n < block; ++n) {
                            const auto value = buffer.getSample(c, n);
                            expect(std::isfinite(value), "Pitch produced invalid samples");
                            if (previous[c] <= 0 && value > 0)
                                ++crossings[c];
                            previous[c] = value;
                            energy[c] += value * value;
                        }
            }
            for (int c = 0; c < 2; ++c) {
                const auto expected = (c == 0 ? 440 : 660) * (semitones == 12 ? 2. : .5);
                expect(std::abs(crossings[c] - expected) < 5,
                       "Pitch frequency or stereo separation is incorrect");
                expect(energy[c] > 100, "Pitch lost the sustained signal");
            }
        }
    });
    test("grandMA2 map stability, tombstones and partial export destinations", [&] {
        std::vector<LightingRegion> regions{
            {"new", "s", "New"}, {"old1", "s", "Old 1"}, {"old2", "s", "Old 2"}};
        auto saved = object();
        put(saved, "region:old1", 0);
        put(saved, "region:old2", 1);
        put(saved, "region:removed", 4);
        auto assigned = Lighting::buildAssignments(regions, saved);
        expect((int)get(assigned, "region:new") == 5, "New song reused reserved destination");
        expect((int)get(assigned, "region:old1") == 0, "Old destination changed");
        expect((int)get(assigned, "region:removed") == 4, "Tombstone lost");
        expect(Lighting::cleanName(String::fromUTF8("CHOPP, ALEGRIA E DIVERSÃO")) ==
                   "CHOPP ALEGRIA E DIVERSAO",
               "Accent conversion differs from Hook Center: " +
                   Lighting::cleanName(String::fromUTF8("CHOPP, ALEGRIA E DIVERSÃO")));
        expect(Lighting::cleanName(String::fromUTF8("ISABELA – ZUFA")) == "ISABELA - ZUFA",
               "Punctuation conversion failed");
        expect(Lighting::safeStem("CON") == "_CON", "Reserved filename not escaped");
    });
    test("grandMA2 native XML parity with Hook Center cues, switch-off and installer", [&] {
        Session session;
        session.restoreSnapshot(ProjectCodec::encode(projectFixture()));
        auto resolume = object();
        put(resolume, "webPort", 8099);
        put(session.original, "resolume", resolume);
        Lighting light(session);
        light.settings = {4, 2, 7, 9, 2};
        light.refresh();
        auto exports = light.buildExports(false);
        expect(exports.size() == 2, "Wrong export count");
        auto &first = exports[0];
        auto &second = exports[1];
        expect(first.macro.contains("Assign Sequence 4 Cue 2 /Trig=Timecode /TrigTime=0H0M12.00S"),
               "Cue trigger not absolute");
        expect(first.macro.contains("/StatusCall=On") && first.macro.contains("/PreRoll=0") &&
                   first.macro.contains("Keep Playbacks"),
               "Playback restore settings lost");
        expect(first.timecode.contains("time=\"900\" command=\"Off\""),
               "Other song must switch off old executor");
        expect(!first.timecode.contains("time=\"600\" command=\"Off\""),
               "Executor must hold at region end");
        expect(first.timecode.contains("lenght=\"1200\""), "Timecode must cover full timeline");
        expect(second.settings.sequence == 5 && second.settings.executor == 8 &&
                   second.settings.timecode == 10,
               "Stable numbering differs");
        expect(XmlDocument::parse(first.macro) != nullptr &&
                   XmlDocument::parse(first.timecode) != nullptr,
               "Invalid XML");
        light.selected = {second.region.id};
        expect(light.buildExports()[0].settings.sequence == 5, "Partial export renumbered music");
        auto name = light.exportGrandMA2(directory.getChildFile("grandMA2"));
        expect((int)num(get(session.original, "resolume"), "webPort") == 8099,
               "grandMA2 export reset the Mac Resolume REST port");
        expect(directory.getChildFile("grandMA2/macros/" + name).existsAsFile(),
               "Installer missing");
        light.settings.sequence = 9999;
        bool overflow = false;
        try {
            light.buildExports(false);
        } catch (...) {
            overflow = true;
        }
        expect(overflow, "Destination overflow accepted");
        light.settings.sequence = 1;
        light.selected.clear();
        light.refresh();
        expect(light.buildExports().empty(), "Clearing export selection selected everything again");
    });
    test("LR swap persists and exchanges actual playback and rendered stereo samples", [&] {
        const auto folder=directory.getNonexistentChildFile("swap-lr-audio","");folder.createDirectory();
        {
            auto file=folder.getChildFile("signal.wav");auto stream=file.createOutputStream();WavAudioFormat wav;
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.release(),48000,2,24,{},0));
            expect(writer!=nullptr,"Cannot create LR fixture");AudioBuffer<float> pcm(2,48000);
            for(int n=0;n<48000;++n){pcm.setSample(0,n,.1f);pcm.setSample(1,n,.2f);}
            expect(writer->writeFromAudioSampleBuffer(pcm,0,48000),"Cannot write LR fixture");
        }
        // Measure the rendered PCM, not only the fader's label conversion.
        for (const auto gains : {std::array<double,3>{0,0,0}, {-3,0,0}, {-6,0,0},
                                 {-12,0,0}, {6,0,0}, {0,-3,0}, {-3,-3,0}, {0,0,-3}}) {
            auto p=projectFixture(); auto &song=p.songs[0]; song.duration=1;
            song.parts.clear(); song.markers.reset(); p.masterAutomationJSON.reset();
            p.masterVolume=std::pow(10.0,gains[2]/20.0);
            p.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
            jaras::Track group; group.id=uuid(); group.name="Calibration group";
            group.volume=std::pow(10.0,gains[1]/20.0); group.patch=jaras::OutputPatch{0,2};
            jaras::Track child; child.id=uuid(); child.name="Calibration input";
            child.parentTrackID=group.id; child.patch=jaras::OutputPatch{-2,2};
            child.volume=std::pow(10.0,gains[0]/20.0);
            jaras::AudioClip clip; clip.id=uuid(); clip.duration=1;
            clip.audioFile=jaras::AudioFile{"signal.wav",{}}; child.clips={clip}; song.tracks={group,child};
            AudioEngine calibrated; calibrated.prepareOffline(48000);
            calibrated.prepareSong(song,folder,{},&p); calibrated.setOffline(true); calibrated.setMixer(p,song);
            AudioEngine::State state; state.playing=true; state.position=.1; calibrated.transport(state);
            AudioBuffer<float> out(2,512);
            for(int i=0;i<32;++i) calibrated.render(out.getArrayOfWritePointers(),2,512);
            const auto measured=20.0*std::log10(std::abs(out.getSample(0,100))/.1);
            expect(std::abs(measured-(gains[0]+gains[1]+gains[2]))<.01,
                   "Track/group/master faders must apply the displayed dB to rendered audio");
        }
        {
            auto p=projectFixture();auto &song=p.songs[0];song.duration=1;song.parts.clear();song.markers.reset();p.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
            auto &track=song.tracks[0];track.volume=1;track.pan=0;track.phaseInverted=false;track.fxJSON.reset();track.automationJSON.reset();track.patch=jaras::OutputPatch{1,2};track.outputs.reset();
            jaras::AudioClip clip;clip.id=uuid();clip.duration=1;clip.audioFile=jaras::AudioFile{"signal.wav",{}};clip.channelMode=4;track.clips={clip};
            jaras::validate(p);auto decoded=ProjectCodec::decode(ProjectCodec::encode(p));expect(decoded.songs[0].tracks[0].clips[0].channelMode==4,"Swap LR did not survive project roundtrip");
            auto engine=std::make_unique<AudioEngine>();engine->prepareOffline(48000);engine->prepareSong(song,folder,{},&p);engine->setOffline(true);engine->setMixer(p,song);
            AudioBuffer<float> output(2,512);AudioEngine::State state;state.playing=true;state.position=.25;engine->transport(state);engine->render(output.getArrayOfWritePointers(),2,512);
            expect(std::abs(output.getSample(0,100)-.2)<.0001&&std::abs(output.getSample(1,100)-.1)<.0001,"Swap LR did not exchange actual playback samples");
            std::atomic<bool> cancel{false};auto rendered=itemRender::render(p,song,folder,{clip.id},false,0,cancel,{});
            AudioFormatManager formats;registerAudioFormats(formats);std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(rendered[0].generated));expect(reader!=nullptr,"Cannot read swapped output");AudioBuffer<float> printed(2,512);reader->read(&printed,0,512,12000,true,true);
            expect(std::abs(printed.getSample(0,100)-.2)<.0001&&std::abs(printed.getSample(1,100)-.1)<.0001,"Re-render/export did not bake LR swap");
        }
    });
    test("WASAPI-independent stereo render, mixer, Sub Play, seek and sample loop", [&] {
        auto folder = directory.getChildFile("Audio");
        folder.createDirectory();
        auto file = folder.getChildFile("signal.wav");
        file.deleteFile();
        {
            WavAudioFormat wav;
            auto stream = std::make_unique<FileOutputStream>(file);
            expect(stream->openedOk(), "Fixture output failed");
            std::unique_ptr<AudioFormatWriter> writer(
                wav.createWriterFor(stream.release(), 48000, 2, 24, {}, 0));
            expect(writer != nullptr, "WAV writer unavailable");
            AudioBuffer<float> buffer(2, 48000);
            for (int n = 0; n < 48000; ++n) {
                buffer.setSample(0, n, .1f);
                buffer.setSample(1, n, .2f);
            }
            expect(writer->writeFromAudioSampleBuffer(buffer, 0, 48000), "WAV fixture failed");
        }

        {
            auto p=projectFixture();auto &song=p.songs[0];song.duration=1;song.parts.clear();song.markers.reset();p.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
            auto &track=song.tracks[0];track.volume=1;track.pan=0;track.phaseInverted=false;track.fxJSON.reset();track.automationJSON.reset();
            jaras::AudioClip clip;clip.id=uuid();clip.name="Fade test";clip.duration=1;clip.audioFile=jaras::AudioFile{"signal.wav",{}};clip.fadeIn=1;clip.fadeInCurve=1;clip.fadeInSCurve=0;track.clips={clip};
            AudioEngine shaped;shaped.prepareOffline(48000);shaped.prepareSong(song,folder,{},&p);shaped.setOffline(true);shaped.setMixer(p,song);
            AudioBuffer<float> output(2,512);AudioEngine::State state;state.playing=true;state.position=.25;shaped.transport(state);shaped.render(output.getArrayOfWritePointers(),2,512);
            const auto t=.25+100./48000;expect(std::abs(output.getSample(0,100)-.1*t/(16-15*t))<.0001,"Rendered samples ignore curvature handle");
            std::atomic<bool> cancel{false};auto rendered=itemRender::render(p,song,folder,{clip.id},false,0,cancel,{});
            expect(rendered.size()==1 && !rendered[0].clip.fadeIn && !rendered[0].clip.fadeInCurve,"Re-render keeps baked fade active twice");
            song.tracks[0].clips={rendered[0].clip};shaped.prepareSong(song,folder,{},&p);shaped.setOffline(true);shaped.setMixer(p,song);shaped.transport(state);shaped.render(output.getArrayOfWritePointers(),2,512);
            expect(std::abs(output.getSample(0,100)-.1*t/(16-15*t))<.0001,"Re-render changed the audible fade");
        }
        {
            auto p=projectFixture();auto &song=p.songs[0];song.duration=1;song.parts.clear();song.markers.reset();p.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
            auto &t=song.tracks[0];t.volume=1;t.pan=0;t.phaseInverted=false;t.fxJSON.reset();t.automationJSON.reset();
            jaras::AudioClip c;c.id=uuid();c.duration=1;c.audioFile=jaras::AudioFile{"signal.wav",{}};t.clips={c};
            auto settings=object();put(settings,"mode","read");auto envelope=automation::envelope("volume",AutomationCurve::normalized(.5));put(settings,"envelopes",Array<var>{envelope});p.masterAutomationJSON=utf8(JSON::toString(settings,true));
            AudioEngine engine;engine.prepareOffline(48000);engine.prepareSong(song,folder,{},&p);engine.setOffline(true);engine.setMixer(p,song);
            AudioBuffer<float> out(2,512);AudioEngine::State state;state.playing=true;state.position=.1;engine.transport(state);engine.render(out.getArrayOfWritePointers(),2,512);
            expect(std::abs(out.getSample(0,100)-.05)<.0001 && std::abs(out.getSample(1,100)-.1)<.0001,"Master volume envelope must affect rendered output");
        }
        AudioEngine engine;
        jaras::Song song;
        song.id = uuid();
        song.name = "Audio test";
        song.duration = 1;
        jaras::Track track;
        track.id = uuid();
        track.name = "Signal";
        jaras::AudioClip clip;
        clip.id = uuid();
        clip.name = "Signal";
        clip.duration = 1;
        clip.audioFile = jaras::AudioFile{"signal.wav", {}};
        track.clips.push_back(clip);
        song.tracks.push_back(track);
        engine.prepareSong(song, folder);
        AudioEngine::State stopped;
        stopped.position = .1;
        engine.transport(stopped);
        expect((int)engine.streamDiagnostics()["primedSources"] == 0,
               "Stopped project edits must not request or wait for audio readers");
        Thread::sleep(150);
        jaras::Project p;
        p.masterVolume = 1;
        engine.setMixer(p, song);
        AudioBuffer<float> output(2, 480);
        auto render = [&] { engine.render(output.getArrayOfWritePointers(), 2, 480); };
        AudioEngine::State state;
        state.playing = true;
        state.position = .1;
        engine.transport(state);
        expect((int)engine.streamDiagnostics()["primedSources"] > 0,
               "Starting playback must still prime the active head");
        render();
        for (int retry = 0; retry < 20 && output.getMagnitude(0, 480) < .01f; ++retry) {
            Thread::sleep(20);
            engine.transport(state);
            render();
        }
        expect(std::abs(output.getSample(0, 100) - .1f) < .002f, "Left channel incorrect");
        expect(std::abs(output.getSample(1, 100) - .2f) < .002f, "Stereo channels collapsed");
        // Adding a generated track must retain unchanged readers and their audio.
        auto clickTrack = track;
        clickTrack.id = uuid(); clickTrack.role.id = "generatedClick";
        clickTrack.name = "Click"; clickTrack.clips.clear();
        song.tracks.push_back(clickTrack);
        engine.prepareSong(song, folder);
        expect((int)engine.preparationDiagnostics["reusedSources"] == 1,
               "Adding Click reopened unchanged source metadata");
        engine.setMixer(p, song); engine.transport(state); render();
        expect(std::abs(output.getSample(0, 100) - .1f) < .002f &&
                   std::abs(output.getSample(1, 100) - .2f) < .002f,
               "Adding Click changed existing audio");
        song.tracks.pop_back();
        expect(file.setLastModificationTime(file.getLastModificationTime() + RelativeTime::seconds(2)),
               "Could not update media revision");
        engine.prepareSong(song, folder);
        expect((int)engine.preparationDiagnostics["reusedSources"] == 0,
               "Changed media reused a stale decoder");
        engine.setMixer(p, song); engine.transport(state); render();

        // Thousands of edits without a device callback used to fill the queue
        // in visual inspection. The last mixer and transport values must survive.
        for (int edit = 0; edit < 1500; ++edit) {
            p.masterMute = edit % 2 == 0;
            p.masterVolume = edit % 2 == 0 ? .25 : .5;
            song.tracks[0].volume = .5;
            state.position = .1;
            engine.setMixer(p, song);
            engine.transport(state);
        }
        render();
        expect(std::abs(output.getSample(0, 100) - .025f) < .002f &&
                   std::abs(output.getSample(1, 100) - .05f) < .002f,
               "Command backlog lost the final mute or mixer update");
        expect(std::abs(engine.state().position - .11) < .0001,
               "Command backlog lost the final seek");
        state.playing = false;
        engine.transport(state);
        render();
        expect(output.getMagnitude(0, 480) == 0 && !engine.state().playing,
               "Stop after a command backlog was lost");
        state.playing = true;
        song.tracks[0].volume = 1;
        p.masterVolume = .5;
        engine.setMixer(p, song);
        engine.transport(state);
        render();
        expect(std::abs(output.getSample(0, 100) - .05f) < .002f, "Master fader incorrect");
        state.subPlaying = true;
        state.subPosition = .1;
        engine.transport(state);
        render();
        expect(std::abs(output.getSample(0, 100) - .1f) < .002f, "Sub Play did not mix both heads");
        song.tracks[0].mute = true;
        engine.setMixer(p, song);
        render();
        expect(output.getMagnitude(0, 480) == 0, "Mute failed");
        song.tracks[0].mute = false;
        engine.setMixer(p, song);
        state.subPlaying = false;
        state.position = .195;
        state.loop = true;
        state.loopStart = .1;
        state.loopEnd = .2;
        engine.transport(state);
        render();
        expect(std::abs(engine.state().position - .105) < .0001,
               "Loop boundary is not sample aligned");
        state.playing = false;
        state.subPlaying = false;
        engine.transport(state);
        render();
        expect(output.getMagnitude(0, 480) == 0, "Stopped transport emitted audio");
        p.masterVolume = .5;
        p.masterOutputs = std::vector<jaras::OutputPatch>{{3, 2}};
        engine.prepareSong(song, folder, {}, &p);
        engine.setOffline(true);
        engine.setMixer(p, song);
        AudioBuffer<float> multi(4, 480);
        state.playing = true;
        state.position = .1;
        state.loop = false;
        engine.transport(state);
        engine.render(multi.getArrayOfWritePointers(), 4, 480);
        expect(multi.getMagnitude(0, 0, 480) == 0 && multi.getMagnitude(1, 0, 480) == 0,
               "Master ignored selected hardware outputs");
        expect(std::abs(multi.getSample(2, 100) - .05f) < .002f &&
                   std::abs(multi.getSample(3, 100) - .1f) < .002f,
               "Master output channel numbering differs from Mac");
        song.tracks[0].outputs = std::vector<jaras::OutputPatch>{{1, 2}};
        p.masterMute = true;
        engine.prepareSong(song, folder, {}, &p);
        engine.setOffline(true);
        engine.setMixer(p, song);
        engine.transport(state);
        engine.render(multi.getArrayOfWritePointers(), 4, 480);
        expect(std::abs(multi.getSample(0, 100) - .1f) < .002f &&
                   std::abs(multi.getSample(1, 100) - .2f) < .002f,
               "Direct output was shifted or changed by master controls");
        p.masterSolo = true;
        engine.setMixer(p, song);
        engine.transport(state);
        engine.render(multi.getArrayOfWritePointers(), 4, 480);
        expect(multi.getMagnitude(0, 480) == 0,
               "Master Solo did not silence direct hardware output");
        p.masterSolo = false;
        p.masterMute = false;
        p.masterVolume = 1;
        p.masterOutputs = std::vector<jaras::OutputPatch>{{1, 2}};
        auto &sourceTrack = song.tracks[0];
        sourceTrack.outputs = std::vector<jaras::OutputPatch>{{-1, 2}};
        jaras::Track destination;
        destination.id = uuid();
        destination.name = "Receive bus";
        destination.volume = .5;
        destination.routing = jaras::TrackRouting{{sourceTrack.id}, {}};
        sourceTrack.routing = jaras::TrackRouting{{}, {destination.id}};
        const auto sourceId = sourceTrack.id;
        song.tracks.insert(song.tracks.begin(), destination);
        engine.prepareSong(song, folder, {}, &p);
        engine.setOffline(true);
        engine.setMixer(p, song);
        engine.transport(state);
        render();
        expect(std::abs(output.getSample(0, 100) - .05f) < .002f,
               "Send/receive routing was missing, doubled, or ordered incorrectly");
        expect(engine.trackPeak(sourceId) > .1f, "Track meter did not publish the rendered peak");
        song.tracks[1].phaseInverted = true;
        engine.setMixer(p, song);
        engine.transport(state);
        render();
        expect(std::abs(output.getSample(0, 100) + .05f) < .002f,
               "Track polarity inversion was ignored");
        engine.prepareSong(song, folder, {}, &p);
        engine.setOffline(true);
        engine.setMixer(p, song);
        engine.transport(state);
        render();
        expect(std::abs(output.getSample(0, 100) + .05f) < .002f,
               "Restoring an inverted track applied polarity twice");
        song.tracks[0].routing->transmitters.push_back(sourceId);
        bool feedback = false;
        try {
            engine.prepareSong(song, folder, {}, &p);
        } catch (...) {
            feedback = true;
        }
        expect(feedback, "Audio routing accepted a feedback cycle");
    });
    test("Export plan tokens, collision naming and secondary outputs match desktop documents", [&] {
        auto p = projectFixture();
        const auto &song = p.songs[0];
        ExportEncoding encoding;
        auto jobs =
            audioExport::plan(p, song, 0, 3, "%project - %region", {}, {}, {}, {}, encoding);
        expect(jobs.size() == 2 && jobs[0].start == 10 && jobs[0].end == 20,
               "Export region bounds were lost");
        auto secondary = audioExport::plan(p, song, 0, 3, "Same", {}, {}, {}, {}, encoding);
        expect(secondary[1].name == "Same (2).wav", "Duplicate export names collided");
        audioExport::appendSecondary(secondary, secondary);
        std::set<String> names;
        for (const auto &job : secondary)
            expect(names.insert(job.name.toLowerCase()).second,
                   "Secondary output overwrites primary");
        auto safe = audioExport::plan(p, song, 0, 0, "../CON", {}, {}, {}, {}, encoding);
        expect(!safe[0].name.containsChar('/') && !safe[0].name.containsChar('\\'),
               "Export template escaped its folder");
    });
    test("Unified playback renders only eligible stems for grid entry, continuous play and Ignore Next", [&] {
        const auto media = directory.getChildFile("playback-scope-fixture");
        media.createDirectory();
        {
            WavAudioFormat wav;
            auto stream = std::make_unique<FileOutputStream>(media.getChildFile("scope.wav"));
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
            expect(writer != nullptr, "Scope fixture writer failed"); stream.release();
            AudioBuffer<float> tone(2, 48000 * 4);
            for (int c = 0; c < 2; ++c) FloatVectorOperations::fill(tone.getWritePointer(c), .1f, tone.getNumSamples());
            writer->writeFromAudioSampleBuffer(tone, 0, tone.getNumSamples());
        }
        jaras::Project project; project.id = uuid(); project.name = "Scope PCM";
        jaras::Song song; song.id = uuid(); song.name = "Timeline"; song.duration = 6; song.bpm = 120;
        const auto group = uuid(), a = uuid(), b = uuid(), c = uuid();
        song.parts = {{group, "Group", 0, 6}, {a, "A", 0, 4}, {b, "B", 2, 5}, {c, "C", 5, 6}};
        for (size_t i = 1; i < song.parts.size(); ++i) song.parts[i].parentRegionID = group;
        song.regionOwnershipInitialized = true; song.regionOwnershipVersion = 2;
        jaras::Track track; track.id = uuid(); track.name = "Stems"; track.role.id = "other";
        jaras::AudioClip first; first.id = uuid(); first.name = "A"; first.duration = 4;
        first.audioFile = jaras::AudioFile{"scope.wav", {}}; first.gain = .5; first.regionOwnerID = a;
        auto second = first; second.id = uuid(); second.name = "B"; second.startTime = 2 - .0000004;
        second.duration = 3; second.gain = 1; second.regionOwnerID = b;
        track.clips = {first, second}; song.tracks = {track}; project.songs = {song};
        jaras::Engine core; core.loadProject(project);
        AudioEngine audio; audio.prepareOffline(48000); audio.prepareSong(*core.currentSong(), media, {}, &core.project()); audio.setOffline(true);
        AudioBuffer<float> output(2, 512);
        auto render = [&](float expected, const String& message) {
            const auto& t = core.transport(); AudioEngine::State state;
            state.position = t.position; state.playing = t.playing;
            state.subPosition = t.subPlay.position; state.subPlaying = t.subPlay.playing;
            state.scope[0] = jaras::playbackScope(*core.currentSong(), t);
            state.scope[1] = jaras::playbackScope(*core.currentSong(), t, true);
            state.end = t.ignoreNextEnd.value_or(std::numeric_limits<double>::infinity());
            audio.transport(state);
            for (int i = 0; i < 8; ++i) audio.render(output.getArrayOfWritePointers(), 2, 512);
            const float sample = output.getSample(0, 256);
            expect(std::abs(sample - expected) < .002f, message + " PCM=" + String(sample));
        };
        core.execute({jaras::CommandKind::editSeek, "", 2.5}); core.execute({jaras::CommandKind::play});
        render(.1f, "Grid entry leaked previous tail or silenced rounded incoming audio");
        core.execute({jaras::CommandKind::pause}); render(0, "Pause remained audible");
        core.execute({jaras::CommandKind::play}); render(.1f, "Resume lost entry");
        core.execute({jaras::CommandKind::stopAll}); core.execute({jaras::CommandKind::selectRegion, a}); core.execute({jaras::CommandKind::play}); core.advance(2.5);
        render(.15f, "Continuous A-to-B discarded tail");
        core.execute({jaras::CommandKind::ignoreNext}); render(.05f, "Ignore Next did not exclude B");
        core.execute({jaras::CommandKind::ignoreNext}); render(.15f, "Toggle off did not restore B");
        core.execute({jaras::CommandKind::seek, "", 2.5}); render(.1f, "Manual live seek retained A");
        core.execute({jaras::CommandKind::subSeek, "", .5}); core.execute({jaras::CommandKind::subPlay});
        render(.15f, "Secondary entry leaked into main scope");
        core.execute({jaras::CommandKind::stop}); render(.05f, "Promotion did not retain secondary scope");
        core.execute({jaras::CommandKind::stopAll}); core.execute({jaras::CommandKind::selectRegion, a}); core.execute({jaras::CommandKind::play}); core.advance(3.99);
        core.execute({jaras::CommandKind::ignoreNext}); render(0, "Ignore Next rendered past last owned audio");
    });
    test("WAV AIFF and native MP3 export preserve rate, bounds, channels and signal", [&] {
        const auto media = directory.getChildFile("export-fixture-" + text(uuid()));
        media.createDirectory();
        const auto signal = media.getChildFile("tone.wav");
        {
            WavAudioFormat wav;
            auto stream = std::make_unique<FileOutputStream>(signal);
            std::unique_ptr<AudioFormatWriter> writer(
                wav.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
            expect(writer != nullptr, "Export fixture writer failed");
            stream.release();
            AudioBuffer<float> tone(2, 48000);
            for (int n = 0; n < 48000; ++n) {
                tone.setSample(0, n,
                               .25f * std::sin(MathConstants<double>::twoPi * 440 * n / 48000));
                tone.setSample(1, n,
                               .125f * std::sin(MathConstants<double>::twoPi * 440 * n / 48000));
            }
            writer->writeFromAudioSampleBuffer(tone, 0, 48000);
        }
        auto p = projectFixture();
        auto &song = p.songs[0];
        song.duration = 1;
        song.parts.clear();
        song.markers.reset();
        song.tracks.resize(1);
        auto &track = song.tracks[0];
        track.clips.clear();
        track.audioFile.reset();
        track.volume = 1;
        track.pan = 0;
        track.mute = track.solo = false;
        track.patch = jaras::OutputPatch{3, 2};
        jaras::AudioClip clip;
        clip.id = uuid();
        clip.name = "Tone";
        clip.duration = 1;
        clip.audioFile = jaras::AudioFile{"tone.wav", {}};
        track.clips = {clip};
        for (const auto &format : StringArray{"WAV", "AIFF", "MP3"}) {
            ExportRequest request;
            request.directory = media.getChildFile(uuid());
            auto &encoding = request.encodings[0];
            encoding.format = format;
            encoding.rate = format == "AIFF" ? 48000 : 44100;
            encoding.channels = format == "AIFF" ? 1 : 2;
            ExportJob job;
            job.name = "render." + format.toLowerCase();
            job.start = .1;
            job.end = .6;
            job.track = track.id;
            request.jobs = {job};
            std::atomic<bool> cancel{false};
            audioExport::render(p, song, media, request, cancel, {});
            AudioFormatManager formats;
            registerAudioFormats(formats);
            std::unique_ptr<AudioFormatReader> reader(
                formats.createReaderFor(request.directory.getChildFile(job.name)));
            expect(reader && reader->sampleRate == encoding.rate &&
                       reader->numChannels == (unsigned)encoding.channels,
                   "Export rate or channel count differs from request: " + format);
            const double duration = (double)reader->lengthInSamples / reader->sampleRate;
            expect(std::abs(duration - .5) < (format == "MP3" ? .1 : .0001),
                   "Export did not honor selected bounds: " + format);
            AudioBuffer<float> decoded((int)reader->numChannels, (int)reader->lengthInSamples);
            reader->read(&decoded, 0, decoded.getNumSamples(), 0, true, true);
            expect(decoded.getMagnitude(0, decoded.getNumSamples()) > .15f,
                   "Track export was silenced by its hardware patch: " + format);
            bool rejected = false;
            try {
                audioExport::render(p, song, media, request, cancel, {});
            } catch (...) {
                rejected = true;
            }
            expect(rejected, "Export silently replaced an existing file");
        }
        {
            auto nonAudio = clip;
            nonAudio.id = uuid();
            nonAudio.audioFile.reset();
            track.clips.push_back(nonAudio);
            ExportEncoding encoding;
            const auto stems = audioExport::plan(p, song, 3, 0, "%stem", {},
                                                 {clip.id, nonAudio.id}, {}, {}, encoding);
            expect(stems.size() == 1 && stems[0].clip == clip.id,
                   "Stem export included an item without an audio source");
            track.clips.pop_back();
        }
        song.duration = .25;
        track.patch = jaras::OutputPatch{0, 2};
        {
            ExportEncoding encoding;
            const auto jobs = audioExport::plan(p, song, 0, 0, "%project", {}, {}, {}, {}, encoding);
            expect(jobs.size() == 1 && std::abs(jobs[0].end - 1.0) < 1e-9,
                   "Complete export stopped at the nominal song duration");
            ExportRequest request;
            request.directory = media.getChildFile("past-song-end-" + text(uuid()));
            request.jobs = jobs;
            std::atomic<bool> cancel{false};
            audioExport::render(p, song, media, request, cancel, {});
            AudioFormatManager formats;
            registerAudioFormats(formats);
            std::unique_ptr<AudioFormatReader> reader(
                formats.createReaderFor(request.directory.getChildFile(jobs[0].name)));
            expect(reader && reader->lengthInSamples == 48000,
                   "Complete export did not render the full audio item");
            AudioBuffer<float> tail(2, 1024);
            expect(reader->read(&tail, 0, 1024, 36000, true, true) &&
                       tail.getMagnitude(0, 1024) > .1f,
                   "Audio after the nominal song duration was silenced");
        }
    });
    test("Track folders preserve descendants, routing and undo across moves and removal", [&] {
        auto p = projectFixture();
        auto &song = p.songs[0];
        song.tracks.clear();
        jaras::Track folder;
        folder.id = uuid();
        folder.name = "Group";
        jaras::Track nested;
        nested.id = uuid();
        nested.name = "Nested";
        nested.parentTrackID = folder.id;
        nested.patch = jaras::OutputPatch{-2, 2};
        jaras::Track child;
        child.id = uuid();
        child.name = "Child";
        child.parentTrackID = nested.id;
        child.patch = jaras::OutputPatch{-2, 2};
        jaras::Track outside;
        outside.id = uuid();
        outside.name = "Outside";
        outside.routing = jaras::TrackRouting{{folder.id}, {}};
        song.tracks = {folder, nested, child, outside};
        jaras::validate(p);
        trackTree::move(song, folder.id, child.id);
        expect(song.tracks[0].id == folder.id, "Folder moved into its own descendant");
        trackTree::move(song, outside.id, folder.id);
        jaras::validate(p);
        expect(song.tracks[0].id == outside.id && song.tracks[3].id == child.id,
               "Folder ordering lost descendants");
        const auto copy = trackEditing::duplicateDocument(ProjectCodec::encode(p), song.id, {folder.id});
        song = ProjectCodec::decode(copy.document).songs[0];
        jaras::validate(p);
        expect(song.tracks.size() == 7 && song.tracks[5].parentTrackID == song.tracks[4].id &&
                   song.tracks[6].parentTrackID == song.tracks[5].id,
               "Folder copy did not remap nested parents");
        Session session;
        session.restoreSnapshot(ProjectCodec::encode(p));
        session.removeTrack(folder.id);
        jaras::validate(session.project());
        const auto *now = session.song();
        const auto n = trackTree::index(*now, nested.id);
        expect(n < now->tracks.size() && !now->tracks[n].parentTrackID &&
                   now->tracks[n].outputPatches()[0].firstChannel == 0,
               "Deleting folder did not promote and reroute children");
        expect(!now->tracks[0].routing->receives[0], "Deleting folder left a dangling receive");
        session.undo();
        expect(session.song()->tracks.size() == 7, "Deleting folder was not undoable");
        jaras::validate(session.project());
    });
    test("Live FX replacement preserves transport and applies the prepared chain", [&] {
        Session session;
        session.mediaDirectory = directory.getChildFile("Audio");
        session.edit([&](jaras::Project &p) {
            auto &song = p.songs[0];
            song.duration = 3;
            jaras::Track t;
            t.id = uuid();
            t.name = "Signal";
            jaras::AudioClip c;
            c.id = uuid();
            c.name = "Signal";
            c.duration = 1;
            c.audioFile = jaras::AudioFile{"signal.wav", {}};
            t.clips = {c};
            song.tracks = {t};
        });
        session.command(jaras::CommandKind::play);
        AudioBuffer<float> buffer(2, 480);
        session.audio.setOffline(true);
        session.audio.render(buffer.getArrayOfWritePointers(), 2, 480);
        const auto before = session.audio.state().position;
        auto settings = object();
        put(settings, "inserted", Array<var>{"Compressor"});
        put(settings, "compressorEnabled", true);
        put(settings, "ratio", 1);
        put(settings, "threshold", 0);
        put(settings, "makeup", 6);
        session.configureEffects(session.song()->tracks[0].id, settings);
        expect(session.transport().playing && session.audio.state().playing,
               "Editing FX stopped transport");
        expect(std::abs(session.audio.state().position - before) < .00001,
               "Editing FX moved the audio cursor");
        session.audio.render(buffer.getArrayOfWritePointers(), 2, 480);
        expect(std::abs(buffer.getSample(0, 100) - .1f * Decibels::decibelsToGain(6.f)) < .002f,
               "Live FX did not change the signal");
        expect(session.audio.state().position > before, "Live FX stalled the audio cursor");
        expect(session.dirty && session.canUndo(),
               "Live FX did not create an undoable project edit");
        const auto cursor = session.audio.state().position;
        session.undo();
        expect(session.audio.state().playing && session.audio.state().position == cursor, "Undoing live FX stopped or moved playback");
        session.audio.render(buffer.getArrayOfWritePointers(), 2, 480);
        expect(std::abs(buffer.getSample(0, 100) - .1f) < .002f, "Live FX undo did not restore dry audio");
        session.redo();
        session.audio.render(buffer.getArrayOfWritePointers(), 2, 480);
        expect(std::abs(buffer.getSample(0, 100) - .1f * Decibels::decibelsToGain(6.f)) < .002f, "Live FX redo did not restore processing");
    });
    test("CatStem editor preserves independent source controls and saved settings", [&] {
        auto settings=fxschema::defaults();put(settings,"stemMix",stemMix::defaults());put(settings,"stemSeparatorEnabled",true);
        var saved;int commits=0;
        CatStemEditor editor("Stereo source",[&]{return settings;},[&](var value,bool commit){
            if(commit){saved=JSON::parse(JSON::toString(value));++commits;}
        },[]{native::stem::Status value;value.state="running";value.ready=true;return value;});
        editor.setSize(560,470);
        auto *gain=dynamic_cast<Slider*>(editor.findChildWithID("catStemGain0"));
        auto *mute=dynamic_cast<Button*>(editor.findChildWithID("catStemMute1"));
        auto *solo=dynamic_cast<Button*>(editor.findChildWithID("catStemSolo2"));
        auto *enabled=dynamic_cast<Button*>(editor.findChildWithID("catStemEnabled"));
        expect(gain&&mute&&solo&&enabled,"Missing CatStem source controls");
        gain->setValue(-6,sendNotificationSync);mute->setToggleState(true,sendNotification);solo->setToggleState(true,sendNotification);
        auto sources=list(get(get(saved,"stemMix"),"sources"));
        expect(commits>=3&&sources.size()==5,"CatStem changes were not committed");
        expect(std::abs(num(sources[0],"gain")-Decibels::decibelsToGain(-6.))<1.e-6,"CatStem gain calibration changed on save");
        expect(flag(sources[1],"mute")&&!flag(sources[0],"mute")&&flag(sources[2],"solo"),"CatStem controls changed another source");
        auto snapshot=editor.createComponentSnapshot(editor.getLocalBounds());
        auto stream=directory.getChildFile("catstem-editor.png").createOutputStream();
        expect(stream&&PNGImageFormat().writeImageToStream(snapshot,*stream),"Cannot capture CatStem editor");
        enabled->setToggleState(false,sendNotification);
        expect(!flag(saved,"stemSeparatorEnabled")&&!gain->isEnabled(),"CatStem bypass was not saved/displayed");
        expect(list(get(get(saved,"stemMix"),"sources")).size()==5,"Bypass discarded the source mix");
    });
    dynamicsTests::run(test, expect, directory);
    nativePreviewTests::run(test, expect, directory);
#if CATLIVE_NATIVE_FRONTEND
    frontendBridgeTests::run(test,expect,directory);
    frontendWaveformTests::run(test,expect,directory);
#endif
    eqAnalysisTests::run(test, expect, directory);
    test("Native limiter respects its output ceiling and links stereo peaks without automatic makeup", [&] {
        for(double rate:{44100.,48000.}) {
            auto settings=fxschema::defaults();put(settings,"inserted",Array<var>{"Limiter"});put(settings,"limiterEnabled",true);
            auto parameters=object();put(parameters,"ceiling",-6);put(parameters,"inputGain",12);put(parameters,"release",.1);put(settings,"limiter",parameters);
            NativeFX limiter;limiter.prepare(settings,rate);
            AudioBuffer<float> signal(2,4096);const float ceiling=Decibels::decibelsToGain(-6.f);
            for(int block=0;block<8;++block) {
                for(int n=0;n<4096;++n){const float sample=(n%31==0?2.f:.2f)*(n%2?1.f:-1.f);signal.setSample(0,n,sample);signal.setSample(1,n,sample*.25f);}
                limiter.process(signal,4096);
                for(int n=0;n<4096;++n){
                    expect(std::abs(signal.getSample(0,n))<=ceiling+1.e-6f,"Limiter exceeded its chosen output ceiling");
                    expect(std::abs(signal.getSample(1,n)-signal.getSample(0,n)*.25f)<1.e-6f,"Limiter changed stereo balance");
                }
            }
        }
    });
    test("Every native FX survives live insertion edits bypass and removal with variable buffers", [&] {
        for (int rate : {44100,48000}) {
            const auto folder=directory.getChildFile("native-fx-continuity-"+String(rate)); folder.createDirectory();
            const auto file=folder.getChildFile("tone.wav");
            auto sample=[&](int channel,int64 frame) { return (float)((channel==0?.03:.015)*std::sin(
                frame*MathConstants<double>::twoPi*(channel==0?1000:700)/rate+.2)); };
            {
                auto stream=file.createOutputStream(); expect(stream!=nullptr,"Cannot create native FX fixture");
                stream->setPosition(0);stream->truncate();WavAudioFormat wav;
                std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),rate,2,24,{},0));
                expect(writer!=nullptr,"Cannot create native FX WAV writer");stream.release();
                AudioBuffer<float> tone(2,rate*30);
                for(int c=0;c<2;++c)for(int n=0;n<tone.getNumSamples();++n)tone.setSample(c,n,sample(c,n));
                expect(writer->writeFromAudioSampleBuffer(tone,0,tone.getNumSamples()),"Cannot write native FX tone");
            }
            for(const String kind : {"EQ","Compressor","Limiter","Delay","Reverb","Pitch"}) {
                Session session;session.inspection=true;session.audio.prepareOffline(rate);session.mediaDirectory=folder;
                auto project=projectFixture();auto &song=project.songs[0];song.duration=30;song.parts.clear();song.markers.reset();
                project.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
                song.timeSettings.emplace();song.timeSettings->timebase=jaras::ProjectTimebase::free;
                jaras::Track group;group.id=uuid();group.name="Group";
                jaras::Track track;track.id=uuid();track.name="Signal";track.parentTrackID=group.id;
                track.outputs={{-2,2}};
                jaras::AudioClip clip;clip.id=uuid();clip.name="Signal";clip.duration=30;clip.audioFile=jaras::AudioFile{"tone.wav",{}};
                track.clips={clip};song.tracks={group,track};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
                session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);session.command(jaras::CommandKind::play);
                AudioBuffer<float> output(2,2048);
                for(int n=0;n<24;++n)session.audio.render(output.getArrayOfWritePointers(),2,512);
                auto settings=fxschema::defaults(true);
                const String enabled=kind=="EQ"?"eqEnabled":kind=="Compressor"?"compressorEnabled":kind=="Limiter"?"limiterEnabled":
                    kind=="Delay"?"delayEnabled":kind=="Reverb"?"reverbEnabled":"pitchEnabled";
                for(int stage=0;stage<9;++stage) {
                    if(stage==1){put(settings,"inserted",Array<var>{kind});put(settings,Identifier(enabled),true);}
                    if(stage==2||stage==5)put(settings,Identifier(enabled),false);
                    if(stage==3||stage==6)put(settings,Identifier(enabled),true);
                    if(stage==4) {
                        if(kind=="EQ") { auto band=object();put(band,"frequency",1000);put(band,"gain",-6);put(settings,"bands",Array<var>{band}); }
                        if(kind=="Compressor"){put(settings,"threshold",0);put(settings,"ratio",1);put(settings,"makeup",-6);}
                        if(kind=="Limiter"){auto parameters=object();put(parameters,"ceiling",-24);put(parameters,"inputGain",12);put(settings,"limiter",parameters);}
                        if(kind=="Delay"){put(settings,"delayTime",.06);put(settings,"delayMix",30);put(settings,"feedback",30);}
                        if(kind=="Reverb"){put(settings,"reverbRoom",2);put(settings,"reverbDecay",.4);put(settings,"reverbMix",30);}
                        if(kind=="Pitch")put(settings,"pitchSemitones",3);
                    }
                    if(stage==7)settings=fxschema::defaults(true);
                    if(stage==8){
                        settings=fxschema::defaults(true);put(settings,Identifier(enabled),true);
                        auto nested=settings.clone();put(nested,"inserted",Array<var>{kind});
                        auto instance=object();put(instance,"id","repeat");put(instance,"kind",kind);put(instance,"settings",nested);
                        put(settings,"instances",Array<var>{instance});put(settings,"inserted",Array<var>{kind,"Native:repeat"});
                    }
                    const auto position=session.audio.state().position;
                    session.configureEffects(track.id,settings);
                    expect(session.audio.state().playing&&session.audio.state().position==position,"Native FX edit stopped or moved transport");
                    int rendered=0;const bool dry=stage==0||stage==2||stage==5||stage==7;
                    const int priming=kind=="Pitch"&&(stage==4||stage==6)?(int)(rate*.15):0;
                    const String context=kind+" stage "+String(stage)+" rate "+String(rate);
                    for(int block=0;block<36;++block) {
                        const int sizes[]{64,128,256,512,1024,2048},count=sizes[block%6];
                        const auto firstFrame=(int64)std::llround(session.audio.state().position*rate);
                        session.audio.render(output.getArrayOfWritePointers(),2,count);
                        for(int c=0;c<2;++c){double energy=0;float error=0;
                            for(int n=0;n<count;++n){const auto value=output.getSample(c,n);
                                expect(std::isfinite(value)&&std::abs(value)<.15f,context+": invalid PCM or overshoot");
                                energy+=value*value;error=std::max(error,std::abs(value-sample(c,firstFrame+n)));
                            }
                            if(rendered>priming)expect(energy/count>.00000025,context+": audio dropout, block "+String(block)+" channel "+String(c));
                            if(dry&&rendered>rate*.25)expect(error<.0001f,context+": bypass/removal changed scheduled PCM");
                        }
                        rendered+=count;
                    }
                }
            }
        }
    });
    test("Failed batch FX restores live audio and preserves the existing redo transaction", [&] {
        // Reject malformed settings before a model worker is started.
        Session session;
        session.inspection=true;session.mediaDirectory=directory.getChildFile("Audio");
        auto project=projectFixture();
        auto &song=project.songs[0];song.duration=3;song.tracks.clear();song.parts.clear();song.markers.reset();project.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
        jaras::Track first;first.id="00000000-0000-0000-0000-000000000001";first.name="First destination";
        jaras::AudioClip clip;clip.id=uuid();clip.name="Signal";clip.duration=1;clip.audioFile=jaras::AudioFile{"signal.wav",{}};first.clips={clip};
        jaras::Track second;second.id="00000000-0000-0000-0000-000000000002";second.name="Failing destination";
        song.tracks={first,second};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        auto compressor=fxschema::defaults();put(compressor,"inserted",Array<var>{"Compressor"});
        put(compressor,"compressorEnabled",true);put(compressor,"ratio",1);put(compressor,"threshold",0);put(compressor,"makeup",3);
        session.configureEffects(first.id,compressor);session.undo();
        expect(!session.canUndo()&&session.canRedo(),"Fixture did not create a single redoable FX edit");
        session.dirty=false;session.command(jaras::CommandKind::play);
        AudioBuffer<float> output(2,480);session.audio.render(output.getArrayOfWritePointers(),2,480);
        const double cursor=session.audio.state().position;
        auto malformed=fxschema::defaults(),mix=object();
        put(malformed,"inserted",Array<var>{"CatStemSeparation 5"});put(malformed,"stemSeparatorEnabled",true);
        put(mix,"sources",Array<var>{object()});put(malformed,"stemMix",mix);
        put(compressor,"makeup",6);
        // The first ordered destination installs successfully; NativeFX rejects
        // the second chain's malformed source count before any model is spawned.
        bool failed=false;
        try {session.configureEffects({{first.id,compressor},{second.id,malformed}});}
        catch(const std::exception &error){failed=String::fromUTF8(error.what()).contains("cinco stems");}
        expect(failed,"Second FX destination did not exercise the preparation failure");
        expect(!session.canUndo()&&session.canRedo()&&!session.dirty,"Failed batch changed history or saved-project dirty state");
        expect(!session.song()->tracks[0].fxJSON&&!session.song()->tracks[1].fxJSON,"Failed batch changed project FX settings");
        expect(session.audio.state().playing&&session.audio.state().position==cursor,"Failed batch interrupted or moved playback");
        session.audio.render(output.getArrayOfWritePointers(),2,480);
        expect(std::abs(output.getSample(0,100)-.1f)<.002f,"Failed batch left the first destination's prepared gain audible");
        session.redo();session.audio.render(output.getArrayOfWritePointers(),2,480);
        expect(std::abs(output.getSample(0,100)-.1f*Decibels::decibelsToGain(3.f))<.002f,"Failure discarded or replaced the prior redo transaction");
    });
    test("Mixer slot copies preserve independent native and external states with single-step undo", [&] {
        Session session;
        auto sourceSettings=object(); fxui::defaults(sourceSettings);
        put(sourceSettings,"inserted",Array<var>{"Compressor"}); put(sourceSettings,"compressorEnabled",false);
        put(sourceSettings,"threshold",-39.); put(sourceSettings,"ratio",9.); put(sourceSettings,"makeup",7.);
        auto targetSettings=object(); fxui::defaults(targetSettings);
        put(targetSettings,"inserted",Array<var>{"Delay"}); put(targetSettings,"delayEnabled",true); put(targetSettings,"delayTime",1.7);
        auto plugin=object(); put(plugin,"id",text(uuid())); put(plugin,"classID",String::repeatedString("A",32));
        put(plugin,"name","Kontakt"); put(plugin,"path","C:/CatLiveTests/Missing/Kontakt.vst3"); put(plugin,"category","Instrument");
        put(plugin,"componentState","bGlicmFyeS1lZGl0ZWQ="); put(plugin,"controllerState","dWktc3RhdGU="); put(plugin,"bypassed",true);
        const auto externalKey="External:"+str(plugin,"id");
        put(sourceSettings,"externalPlugins",Array<var>{plugin}); put(sourceSettings,"inserted",Array<var>{var("Compressor"),var(externalKey)});
        session.edit([&](jaras::Project &p) {
            jaras::Track source; source.id=uuid(); source.name="Source"; source.fxJSON=utf8(JSON::toString(sourceSettings,true));
            jaras::Track destination; destination.id=uuid(); destination.name="Destination"; destination.fxJSON=utf8(JSON::toString(targetSettings,true));
            p.songs[0].tracks={source,destination};
        });
        const auto source=session.song()->tracks[0].id,destination=session.song()->tracks[1].id;
        const auto copied=session.copyEffect(source,"Compressor",destination,"Delay");
        expect(copied.startsWith("Native:"),"Copied native FX did not receive an independent identity");
        auto value=fxchain::settings(session,destination);
        expect(list(get(value,"inserted"))==Array<var>{copied,"Delay"},"Slot copy did not insert before destination");
        const auto nested=get(list(get(value,"instances"))[0],"settings");
        expect(num(nested,"threshold")==-39&&num(nested,"ratio")==9&&num(nested,"makeup")==7&&!flag(nested,"compressorEnabled"),"Native parameters or bypass changed during copy");
        expect(JSON::toString(fxchain::settings(session,source),true)==JSON::toString(sourceSettings,true),"Copy mutated source FX");
        session.undo(); expect(JSON::toString(fxchain::settings(session,destination),true)==JSON::toString(targetSettings,true),"Single undo did not restore destination chain");
        session.redo(); expect(list(get(fxchain::settings(session,destination),"inserted"))[0].toString()==copied,"Redo changed copied processor identity");
        const auto another=session.copyEffect(destination,copied,destination);
        expect(another!=copied&&list(get(fxchain::settings(session,destination),"inserted")).size()==3,"Same-track slot copy moved or shared the source instance");
        session.undo(); expect(list(get(fxchain::settings(session,destination),"inserted")).size()==2,"Same-track copy undo removed unrelated slots");
        const auto newExternal=session.copyEffect(source,externalKey,destination,copied);
        value=fxchain::settings(session,destination); auto duplicated=list(get(value,"externalPlugins"))[0];
        expect(newExternal!=externalKey&&str(duplicated,"id")!=str(plugin,"id"),"VST3 copy reused source instance identity");
        expect(str(duplicated,"componentState")==str(plugin,"componentState")&&str(duplicated,"controllerState")==str(plugin,"controllerState")&&flag(duplicated,"bypassed"),"VST3 copy lost opaque library/controller state or bypass");
        expect(list(get(value,"inserted"))[0].toString()==newExternal,"VST3 copy did not occupy destination slot");
        session.undo(); expect(list(get(fxchain::settings(session,destination),"externalPlugins")).isEmpty(),"VST3 copy undo retained the duplicate");
        session.redo(); expect(str(list(get(fxchain::settings(session,destination),"externalPlugins"))[0],"componentState")==str(plugin,"componentState"),"VST3 redo lost library state");
        const auto before=JSON::toString(fxchain::settings(session,destination),true);
        expect(session.copyEffect(source,"missing",destination).isEmpty()&&JSON::toString(fxchain::settings(session,destination),true)==before,"Stale drag changed the destination");
        // Feed the real Windows copy/save output into Swift's production
        // ProjectDocumentCodec, including sparse legacy master and item chains.
        auto portable = session.project();
        auto master = object(); put(master,"inserted",Array<var>{externalKey});
        put(master,"externalPlugins",Array<var>{plugin.clone()});
        portable.masterFXJSON=utf8(JSON::toString(master,true));
        auto itemFX=object(); put(itemFX,"inserted",Array<var>{"Delay"});
        put(itemFX,"delayEnabled",true); put(itemFX,"delayTime",1.25); put(itemFX,"feedback",48.);
        jaras::AudioClip item; item.id=uuid(); item.name="Windows item FX"; item.duration=1;
        item.audioFile=jaras::AudioFile{"signal.wav",{}}; item.fxJSON=utf8(JSON::toString(itemFX,true));
        portable.songs[0].tracks[0].clips.push_back(item);
        const auto interchange = ProjectCodec::encode(portable);
        expect(str(master,"threshold").isEmpty()&&str(itemFX,"ratio").isEmpty(),"Serialization modified the live sparse FX objects");
        expect(directory.getChildFile("fx-portability.json").replaceWithText(JSON::toString(interchange,true,17)),"Could not write the Windows-to-Mac FX fixture");
    });
    test("Item FX insert remove undo and redo preserve live readers and sample position", [&] {
        Session session;
        session.mediaDirectory = directory.getChildFile("Audio");
        session.edit([&](jaras::Project &p) {
            auto &song=p.songs[0];song.duration=10;
            jaras::Track track;track.id=uuid();track.name="Item FX";
            jaras::AudioClip clip;clip.id=uuid();clip.name="Signal";clip.duration=1;
            clip.audioFile=jaras::AudioFile{"signal.wav",{}};track.clips={clip};song.tracks={track};
        });
        const auto id=session.song()->tracks[0].clips[0].id;
        session.audio.setOffline(true);session.command(jaras::CommandKind::play);
        AudioBuffer<float> output(2,128);
        session.audio.render(output.getArrayOfWritePointers(),2,128);
        const auto readers=session.audio.residentStreams();
        auto settings=object();put(settings,"inserted",Array<var>{"Compressor"});
        put(settings,"compressorEnabled",true);put(settings,"ratio",1);put(settings,"threshold",0);put(settings,"makeup",6);
        for(int i=0;i<12;++i) {
            const double before=session.audio.state().position;
            session.configureEffects(id,settings);
            expect(session.audio.state().playing&&session.audio.state().position==before,"Item FX moved or stopped playback");
            session.audio.render(output.getArrayOfWritePointers(),2,128);
            expect(std::abs(output.getSample(0,64)-.1f*Decibels::decibelsToGain(6.f))<.002f,"Item FX was not applied");
            session.configureEffects(id,var());
            session.audio.render(output.getArrayOfWritePointers(),2,128);
            expect(std::abs(output.getSample(0,64)-.1f)<.002f,"Removing item FX did not restore audio");
            session.undo();session.audio.render(output.getArrayOfWritePointers(),2,128);
            expect(std::abs(output.getSample(0,64)-.1f*Decibels::decibelsToGain(6.f))<.002f,"Undo did not restore item FX state");
            session.redo();session.audio.render(output.getArrayOfWritePointers(),2,128);
            expect(std::abs(output.getSample(0,64)-.1f)<.002f,"Redo did not remove item FX");
            expect(session.audio.residentStreams()==readers,"Item FX rebuilt the audio readers");
        }
    });
    test("Native and external FX can be replaced while the device callback renders", [&] {
        Session session;session.mediaDirectory=directory.getChildFile("Audio");
        session.edit([&](jaras::Project &p){
            auto &song=p.songs[0];song.duration=10;
            jaras::Track track;track.id=uuid();track.name="Live FX";
            jaras::AudioClip clip;clip.id=uuid();clip.name="Signal";clip.duration=1;clip.audioFile=jaras::AudioFile{"signal.wav",{}};
            track.clips={clip};song.tracks={track};
        });
        const auto track=session.song()->tracks[0].id,clip=session.song()->tracks[0].clips[0].id;
        session.audio.setOffline(true);session.command(jaras::CommandKind::play);
        AudioEngine::State state;state.playing=true;state.position=.1;state.loop=true;state.loopStart=.05;state.loopEnd=.9;session.audio.transport(state);
        std::vector<var> chains;
        for(const String &kind:StringArray{"EQ","Compressor","Limiter","Delay","Reverb","Pitch"}){
            auto fx=object();fxui::defaults(fx);put(fx,"inserted",Array<var>{kind});fxui::enable(kind,fx,true);put(fx,"pitchSemitones",2);chains.push_back(fx);
        }
        const auto pluginPath=SystemStats::getEnvironmentVariable("CATLIVE_TEST_VST3",{});
        if(pluginPath.isNotEmpty()){
            const auto plugins=native::vst3::scan(std::filesystem::u8path(utf8(pluginPath)));
            expect(!plugins.empty(),"Test VST3 has no processor");
            auto plugin=object(),fx=object();put(plugin,"id",text(uuid()));put(plugin,"classID",text(plugins[0].classID));
            put(plugin,"name",text(plugins[0].name));put(plugin,"path",pluginPath);put(plugin,"category",text(plugins[0].category));put(plugin,"bypassed",false);
            put(fx,"externalPlugins",Array<var>{plugin});put(fx,"inserted",Array<var>{"External:"+str(plugin,"id")});chains.push_back(fx);
        }
        struct Running {std::atomic<bool> stop{false},finite{true};std::atomic<int> blocks{0};std::thread thread;
            ~Running(){stop=true;if(thread.joinable())thread.join();}} running;
        running.thread=std::thread([&]{AudioBuffer<float> output(2,128);while(!running.stop.load()){
            {const ScopedLock lock(session.audio.devices.getAudioCallbackLock());session.audio.render(output.getArrayOfWritePointers(),2,128);}
            for(int ch=0;ch<2;++ch)for(int n=0;n<128;++n)if(!std::isfinite(output.getSample(ch,n)))running.finite=false;
            ++running.blocks;Thread::sleep(1);
        }});
        for(const auto &target:std::vector<ID>{track,clip})for(const auto &fx:chains){
            session.configureEffects(target,fx);Thread::sleep(8);
            const auto keys=list(get(fx,"inserted"));
            if(keys[0].toString().startsWith("External:")){
                auto captured=fx.clone();session.audio.captureExternalEffects(target,captured);
                expect(str(list(get(captured,"externalPlugins"))[0],"componentState").isNotEmpty(),"External FX did not capture its live state");
                const auto file=directory.getChildFile("live-vst-save/"+text(target)+"/project.jl");
                session.save(file);
                const auto saved=ProjectCodec::decode(ProjectCodec::read(file));
                const auto &savedTrack=saved.songs[0].tracks[0];
                const auto encoded=target==track?savedTrack.fxJSON:savedTrack.clips[0].fxJSON;
                expect(encoded.has_value(),"Saved project lost its external FX chain");
                expect(str(list(get(JSON::parse(text(*encoded)),"externalPlugins"))[0],"componentState").isNotEmpty(),
                    "Saving did not preserve the plugin's live state");
            }
            session.configureEffects(target,var());session.undo();Thread::sleep(4);session.redo();
        }
        expect(running.blocks.load()>10&&running.finite.load()&&session.audio.state().playing,"Live FX stalled crashed or emitted nonfinite samples");
    });
    test("Physical channel gaps preserve inputs nested groups and direct hardware outputs", [&] {
        AudioEngine engine;engine.prepareOffline(48000);engine.instrumentAllowed=true;
        jaras::Project project;project.masterMute=true;
        jaras::Song song;song.id=uuid();song.duration=10;
        jaras::Track group;group.id=uuid();group.name="Group";group.volume=.5;
        group.outputs=std::vector<jaras::OutputPatch>{{5,2}};
        jaras::Track nested;nested.id=uuid();nested.name="Nested";nested.parentTrackID=group.id;
        nested.outputs=std::vector<jaras::OutputPatch>{{-2,2}};
        jaras::Track stereo;stereo.id=uuid();stereo.name="Input 3-4";stereo.parentTrackID=nested.id;
        stereo.inputPatch=jaras::OutputPatch{3,2};stereo.inputMonitoring=true;
        stereo.outputs=std::vector<jaras::OutputPatch>{{-2,2}};
        jaras::Track mono;mono.id=uuid();mono.name="Input 7";mono.inputPatch=jaras::OutputPatch{7,1};
        mono.inputMonitoring=true;mono.outputs=std::vector<jaras::OutputPatch>{{9,1}};
        song.tracks={group,nested,stereo,mono};
        engine.prepareSong(song,directory,{},&project);engine.setMixer(project,song);
        engine.armTrack(stereo.id,true);engine.armTrack(mono.id,true);
        BigInteger inputs,outputs;for(int channel:{2,3,6})inputs.setBit(channel);
        for(int channel:{4,5,8})outputs.setBit(channel);
        engine.configureDeviceChannels(inputs,outputs);
        AudioBuffer<float> in(3,128),out(3,128);
        for(int ch=0;ch<3;++ch)FloatVectorOperations::fill(in.getWritePointer(ch),.1f*(ch+1),128);
        auto render=[&]{static_cast<AudioIODeviceCallback&>(engine).audioDeviceIOCallbackWithContext(in.getArrayOfReadPointers(),3,out.getArrayOfWritePointers(),3,128,{});};
        render();
        expect(std::abs(out.getSample(0,64)-.05f)<.0001f&&std::abs(out.getSample(1,64)-.1f)<.0001f,"Stereo group channels were shifted mixed or duplicated");
        expect(std::abs(out.getSample(2,64)-.3f)<.0001f,"Mono input or direct output used the wrong physical channel");
        song.tracks[0].mute=true;engine.setMixer(project,song);render();
        expect(out.getMagnitude(0,0,128)==0&&out.getMagnitude(1,0,128)==0,"Group mute did not silence its children");
        expect(std::abs(out.getSample(2,64)-.3f)<.0001f,"Group mute leaked to an independent direct output");
        engine.armTrack(mono.id,false);render();
        expect(out.getMagnitude(2,0,128)==0,"Disarmed track still monitored its input");
    });
    test("Generated Click and metronome follow tempo, spans, mute and output patch", [&] {
        jaras::Song song;
        song.id = uuid();
        song.name = "Click";
        song.duration = 3;
        song.bpm = 120;
        jaras::TimelineMarker marker;
        marker.id = uuid();
        marker.position = 1;
        marker.tempoBPM = 60;
        marker.tempoBeats = 3;
        marker.tempoUnit = 4;
        song.markers = std::vector<jaras::TimelineMarker>{marker};
        ClickProgram program;
        program.prepare(song);
        program.a = ClickProgram::tone("Digital", true);
        program.b = ClickProgram::tone("Digital", false);
        auto beatEnergy = [&](double start) {
            double energy = 0;
            for (int i = 0; i < 1680; ++i) {
                const auto value = program.sample(start + i / 48000.);
                energy += value * value;
            }
            return energy;
        };
        expect(beatEnergy(.5) > 1 && beatEnergy(.9) == 0, "Metronome did not follow quarter notes");
        expect(beatEnergy(1) > 1 && beatEnergy(1.5) == 0 && beatEnergy(2) > 1,
               "Tempo marker did not reset beat origin or change spacing");
        jaras::Track track;
        track.id = uuid();
        track.name = "Click";
        track.role.id = "generatedClick";
        jaras::AudioClip clip;
        clip.id = uuid();
        clip.name = "Click";
        clip.startTime = .5;
        clip.duration = 1;
        track.clips = {clip};
        song.tracks = {track};
        AudioEngine engine;
        engine.prepareSong(song, directory);
        AudioBuffer<float> output(4, 4800);
        AudioEngine::State state;
        state.playing = true;
        state.position = .1;
        engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 4, 4800);
        expect(output.getMagnitude(0, 4800) == 0, "Generated Click sounded outside its items");
        state.position = .5;
        engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 4, 4800);
        const auto peak = output.getMagnitude(0, 4800);
        expect(peak > .005f, "Bundled generated Click did not render");
        clip.id = uuid();
        song.tracks[0].clips.push_back(clip);
        engine.prepareSong(song, directory);
        engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 4, 4800);
        expect(std::abs(output.getMagnitude(0, 4800) - peak) < .0001f,
               "Overlapping click items doubled the level");
        song.tracks.clear();
        engine.prepareSong(song, directory);
        auto settings = object(), patch = object();
        put(settings, "enabled", true);
        put(settings, "preset", "Digital");
        put(patch, "firstChannel", 3);
        put(patch, "channelCount", 2);
        put(settings, "output", patch);
        engine.configureMetronome(settings);
        state.position = 0;
        engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 4, 4800);
        expect(output.getMagnitude(0, 0, 4800) == 0 && output.getMagnitude(2, 0, 4800) > .1f,
               "Metronome ignored its independent output");
        engine.metronomeEnabled = false;
        engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 4, 4800);
        expect(output.getMagnitude(0, 4800) == 0, "Metronome toggle did not silence output");
    });
    test("Automation sample playback keeps main and Sub Play envelopes independent", [&] {
        auto envelope = automation::envelope("volume", AutomationCurve::normalized(1));
        auto point = [&](double time, double level, String shape) {
            auto p = object();
            put(p, "id", text(uuid()));
            put(p, "time", time);
            put(p, "value", AutomationCurve::normalized(level));
            put(p, "shape", shape);
            return p;
        };
        put(envelope, "points", Array<var>{point(0, 1, "square"), point(.5, .5, "linear")});
        auto settings = object();
        put(settings, "enabled", true);
        put(settings, "mode", "read");
        put(settings, "envelopes", Array<var>{envelope});
        jaras::Song song;
        song.id = uuid();
        song.name = "Automation";
        song.duration = 1;
        jaras::Track track;
        track.id = uuid();
        track.name = "Signal";
        track.volume = 0;
        track.automationJSON = utf8(JSON::toString(settings, true));
        jaras::AudioClip clip;
        clip.id = uuid();
        clip.name = "Signal";
        clip.duration = 1;
        clip.audioFile = jaras::AudioFile{"signal.wav", {}};
        track.clips.push_back(clip);
        song.tracks.push_back(track);
        AudioEngine engine;
        engine.prepareSong(song, directory.getChildFile("Audio"));
        engine.setOffline(true);
        AudioEngine::State state;
        state.playing = true;
        state.position = .1;
        state.subPlaying = true;
        state.subPosition = .6;
        engine.transport(state);
        AudioBuffer<float> output(2, 480);
        engine.render(output.getArrayOfWritePointers(), 2, 480);
        expect(std::abs(output.getSample(0, 100) - .15f) < .002f,
               "Read automation used one cursor for both playback heads, or retained a zero fader");
        auto take = automation::envelope("volume", AutomationCurve::normalized(.5));
        auto takeSettings = object();
        put(takeSettings, "envelopes", Array<var>{take});
        song.tracks[0].clips[0].automationJSON = utf8(JSON::toString(takeSettings, true));
        engine.prepareSong(song, directory.getChildFile("Audio"));
        engine.setOffline(true);
        engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 2, 480);
        expect(std::abs(output.getSample(0, 100) - .075f) < .002f,
               "Take and track automation did not combine");
        put(envelope, "points", Array<var>{point(0, 1, "linear"), point(1, .5, "linear")});
        put(envelope, "valueScale", "linearGain");
        put(settings, "envelopes", Array<var>{envelope});
        AutomationProgram program;
        program.prepare(settings);
        expect(std::abs(program.evaluate(.5, 1, 0).gain - .75) < 1e-8,
               "Imported linear-gain automation interpolated in decibels");
        put(settings, "mode", "trimRead");
        program.prepare(settings);
        expect(std::abs(program.evaluate(.5, .5, 0).gain - .375) < 1e-8,
               "Trim/Read ignored the fader offset");
    });
    test("Mac legacy media, custom Click, saved cursor and lighting survive Save As", [&] {
        auto source = directory.getChildFile("PortableSource");
        auto target = directory.getChildFile("PortableCopy");
        source.getChildFile("Stems").createDirectory();
        auto signal = directory.getChildFile("Audio/signal.wav");
        expect(signal.copyFileTo(source.getChildFile("Stems/signal.wav")),
               "Legacy media fixture copy failed");
        expect(signal.copyFileTo(source.getChildFile("Stems/custom-click.wav")),
               "Click fixture copy failed");
        auto p = projectFixture();
        auto &track = p.songs[0].tracks[0];
        track.audioFile = jaras::AudioFile{"Stems/signal.wav", {}};
        track.clips[0].audioFile.reset();
        jaras::Track click;
        click.id = uuid();
        click.name = "Click";
        click.role.id = "generatedClick";
        click.clickSound = jaras::AudioFile{"Stems/custom-click.wav", {}};
        p.songs[0].tracks.push_back(click);
        auto raw = ProjectCodec::encode(p);
        auto fixture = JSON::parse(directory.getChildFile("fixture.json").loadFileAsString());
        put(raw, "windowsLighting", get(fixture, "windowsLighting").clone());
        ProjectCodec::write(source.getChildFile("Show.jl"), raw);
        Session session;
        session.load(source.getChildFile("Show.jl"));
        expect(std::abs(session.transport().editPosition - 12.5) < .0001,
               "Saved Mac editing cursor was not restored");
        session.save(target.getChildFile("Show.jl"));
        expect(target.getChildFile("Stems/signal.wav").existsAsFile(),
               "Save As dropped legacy track media");
        expect(target.getChildFile("Stems/custom-click.wav").existsAsFile(),
               "Save As dropped custom Click media");
        auto returned = ProjectCodec::read(target.getChildFile("Show.jl"));
        expect(JSON::toString(get(returned, "windowsLighting"), true) ==
                   JSON::toString(get(raw, "windowsLighting"), true),
               "Save As changed reserved lighting destinations");
        Session reopened;
        reopened.load(target.getChildFile("Show.jl"));
        expect(std::abs(reopened.transport().editPosition - 12.5) < .0001,
               "Saved cursor changed after reopening Windows copy");
    });
    test("Custom action conflict, unbinding and restart persistence", [&] {
        auto targetProject = projectFixture();
        auto &targetSong = targetProject.songs[0];
        expect(actionTrack(targetSong, {}, 9999) == nullptr,
               "Invalid numbered action fell back to a different track");
        expect(actionTrack(targetSong, {}, 1)->id == targetSong.tracks[0].id,
               "Numbered track action did not resolve");
        targetSong.tracks[0].role.id = "teleprompt";
        expect(actionTrack(targetSong, targetSong.tracks[0].id, 0) == nullptr,
               "Special track accepted a standard track action");
        expect(midiFaderGain(0) == 0 && std::abs(midiFaderGain(1) - std::pow(10., .6)) < 1e-7 &&
                   std::abs(midiFaderGain(.5) - std::pow(10., -1.2)) < 1e-7,
               "MIDI volume curve differs from Mac");
        const auto file = directory.getChildFile("action-preferences.json");
        file.replaceWithText("{}");
        Appearance settings(file);
        AudioDeviceManager devices;
        ActionBindings bindings(settings, devices);
        String invoked;
        bindings.invoke = [&](const String &id, float, int) { invoked = id; };
        expect(bindings.key(KeyPress(KeyPress::spaceKey)) && invoked == "playStop",
               "Space did not map to Play/Stop");
        invoked.clear();
        for (int repeat = 0; repeat < 30; ++repeat)
            expect(bindings.key(KeyPress(KeyPress::spaceKey), true), "Held Space leaked to another control");
        expect(invoked.isEmpty(), "Held Space toggled Play/Stop repeatedly");
        expect(bindings.key(KeyPress(KeyPress::spaceKey)) && invoked == "playStop",
               "Space did not trigger again after release");
        invoked.clear();
        expect(bindings.key(KeyPress(KeyPress::spaceKey, ModifierKeys::shiftModifier, 0), true) && invoked.isEmpty(),
               "Held Shift+Space toggled Sub Play repeatedly");
        expect(bindings.key(KeyPress('D'), true) && invoked == "nextRegion",
               "Region navigation lost the Mac repeat behavior");
        expect(bindings.key(KeyPress(KeyPress::upKey)) && invoked == "setlistUp",
               "Up arrow did not map to Setlist Up");
        expect(bindings.key(KeyPress('E')) && invoked == "previousTimelinePoint",
               "A named key collided with E");
        expect(bindings.key(KeyPress('M')) && invoked == "muteTrack",
               "Default track mute did not route");
        expect(bindings.key(KeyPress('S')) && invoked == "splitItems",
               "Mac S shortcut did not split items");
        expect(bindings.key(KeyPress('S', ModifierKeys::shiftModifier, 0)) &&
                   invoked == "soloTrack",
               "Mac Shift+S shortcut did not solo");
        expect(bindings.key(KeyPress('R')) && invoked == "repeatPlayback",
               "Mac R shortcut did not repeat");
        expect(bindings.key(KeyPress(KeyPress::spaceKey, ModifierKeys::shiftModifier, 0)) &&
                   invoked == "subPlayStop",
               "Mac Shift+Space shortcut did not target Sub Play");
        expect(!bindings.assign("setlistUp", "keyboard", "F7"),
               "Fixed setlist keyboard navigation was reassigned");
        auto midiInput = object();
        put(midiInput, "status", 0x90);
        put(midiInput, "number", 60);
        put(midiInput, "channel", 1);
        expect(!bindings.assign("normalizeItems", "midi", midiInput),
               "Keyboard-only normalization accepted MIDI");
        expect(!bindings.assign("volumeMaster", "midi", midiInput),
               "Continuous volume accepted a note trigger");
        put(midiInput, "status", 0xb0);
        expect(bindings.assign("volumeMaster", "midi", midiInput),
               "Continuous MIDI CC did not save");
        expect(!bindings.assign("playStop", "keyboard", "M"),
               "Duplicate keyboard mapping was accepted");
        expect(bindings.assign("muteTrack", "keyboard", "F8"), "Custom key could not be saved");
        invoked.clear();
        expect(bindings.key(KeyPress('M')) && invoked.isEmpty(),
               "Reassigned default leaked into legacy handling");
        expect(bindings.key(KeyPress(KeyPress::F8Key)) && invoked == "muteTrack",
               "Custom key did not route");
        expect(!bindings.assign("playStop", "keyboard", "ctrl + Q"),
               "Reserved menu shortcut was reassigned");
        bindings.begin("playStop", "keyboard");
        expect(bindings.captureKey(KeyPress(KeyPress::escapeKey)) && bindings.learning.isEmpty(),
               "Escape did not cancel learning");
        Appearance reloaded(file);
        ActionBindings restored(reloaded, devices);
        restored.invoke = [&](const String &id, float, int) { invoked = id; };
        invoked.clear();
        expect(restored.key(KeyPress(KeyPress::F8Key)) && invoked == "muteTrack",
               "Mapping was lost on restart");
        expect(restored.assign("muteTrack", "keyboard", {}), "Unbinding failed");
        invoked.clear();
        restored.key(KeyPress('M'));
        restored.key(KeyPress(KeyPress::F8Key));
        expect(invoked.isEmpty(), "Removed key still invoked its action");
    });
    test("Project timing edits retime content and undo as a single operation", [&] {
        Session session;
        session.restoreSnapshot(ProjectCodec::encode(projectFixture()));
        const double oldDuration = session.song()->duration, oldBpm = session.song()->bpm;
        jaras::ProjectTimeSettings settings;
        settings.timebase = jaras::ProjectTimebase::relative;
        session.configureTiming(oldBpm * 1.5, 3, 4, settings);
        expect(std::abs(session.song()->duration - oldDuration / 1.5) < 1e-6,
               "Relative timing did not retime arrangement");
        session.undo();
        expect(std::abs(session.song()->duration - oldDuration) < 1e-6 &&
                   session.song()->bpm == oldBpm,
               "Timing undo lost original geometry");
        session.redo();
        expect(session.song()->beatsPerBar == 3 && session.song()->bpm == oldBpm * 1.5,
               "Timing redo did not restore signature");
    });
    test("Timer keypad matches Mac field editing, countdown lock and saved auto start", [&] {
        const auto file = directory.getChildFile("timer-keypad-preferences.json");
        file.replaceWithText("{}");
        Appearance preferences(file);
        StageState state(preferences);
        StageTimerSettings panel(state);
        panel.setSize(380, 348);
        auto press = [&](const String &name) {
            for (auto *child : panel.getChildren())
                if (auto *button = dynamic_cast<Button *>(child);
                    button && (button->getName() == name || button->getButtonText() == name)) {
                    expect(button->isEnabled(), "Timer button unexpectedly disabled: " + name);
                    button->onClick(); return;
                }
            expect(false, "Timer button missing: " + name);
        };
        press("Minutos"); press("1"); press("2");
        expect(state.target == 720, "Keypad did not replace both digits of the selected field");
        press(String::fromUTF8("⌫"));
        expect(state.target == 600, "Backspace did not clear the previous digit");
        press("Limpar"); press("9"); press("9");
        expect(state.target == 3540, "Minutes exceeded 59");
        press("Segundos"); press("3"); press("4");
        press("INIT AUTO");
        Appearance restored(file);
        StageState reopened(restored);
        expect(reopened.target == 3574 && reopened.autoStart, "Keypad changes were not persisted");
        press("Iniciar");
        expect(state.running, "Timer did not start");
        for (auto *child : panel.getChildren())
            if (child->getName() == "1" || child->getName() == "Horas")
                expect(!child->isEnabled(), "Duration remained editable while counting down");
        int contextCount = 0;
        StageTimerControl control(state, [&] { ++contextCount; });
        control.setSize(164, 43);
        for (auto *child : control.getChildren())
            if (auto *button = dynamic_cast<QuietButton *>(child)) {
                const auto before = contextCount;
                button->context({});
                expect(contextCount == before + 1 && state.running,
                       "Timer button context did not configure without stopping the timer");
            }
    });
    test("Stage clock, notices and independent teleprompter profiles", [&] {
        const auto file = directory.getChildFile("stage-preferences.json");
        file.replaceWithText("{}");
        Appearance preferences(file);
        StageState state(preferences);
        state.target = 90;
        state.autoStart = true;
        state.saveTimer();
        jaras::TransportState transport;
        transport.playing = true;
        transport.regionId = uuid();
        state.observe(transport);
        expect(state.running, "Automatic stage clock did not start");
        state.started = StageState::now() - 92.1;
        expect(state.seconds() < 0 && state.timeText().startsWith(String::fromUTF8("−")),
               "Overtime clock lost the negative sign");
        state.reset();
        transport.playing = false;
        state.observe(transport);
        transport.playing = true;
        state.observe(transport);
        expect(state.running, "Automatic stage clock did not restart after stop");
        state.sendNotice("Mensagem");
        expect(state.noticeActive(), "Notice was not sent");
        state.togglePin();
        state.noticeDeadline = StageState::now() - 1;
        expect(state.noticeActive(), "Pinned notice expired");
        state.togglePin();
        expect(state.noticeActive(), "Unpin did not restore remaining time");
        state.noticeDeadline = StageState::now() - 1;
        expect(!state.noticeActive(), "Timed notice did not expire");
        state.clearNotice();
        expect(!state.noticeActive(), "Notice removal failed");
        state.togglePin();
        expect(state.pinned && state.pausedRemaining == 20,
               "Pinning before sending lost the default duration");
        state.sendNotice(String::fromUTF8("atenção"));
        auto noticeStyle = object();
        put(noticeStyle, "emojiEnabled", true);
        put(noticeStyle, "emoji", "!");
        expect(state.noticeText(noticeStyle) == String::fromUTF8("! ATENÇÃO !"),
               "Notice case or configured emoji was ignored");
        state.clearNotice();
        state.set(1, "textScale", 140);
        state.set(2, "textScale", 65);
        state.selectPreset(1, "day");
        state.set(1, "textScale", 110);
        Appearance restored(file);
        StageState reopened(restored);
        expect(reopened.target == 90 && reopened.autoStart,
               "Stage clock preferences did not persist");
        expect(num(reopened.settings(1), "textScale") == 110 &&
                   num(reopened.settings(2), "textScale") == 65,
               "Teleprompter profiles leaked between windows");
        reopened.selectPreset(1, "night");
        expect(num(reopened.settings(1), "textScale") == 140,
               "Night preset was overwritten by day settings");
    });
    test("Multitrack capture preserves input patches, buses, sustained MIDI and length", [&] {
        auto folder = directory.getChildFile("capture-" + text(uuid()));
        folder.createDirectory();
        TrackCapture::Target mono{uuid(), folder.getChildFile("mono.wav"), 3, 1};
        TrackCapture::Target stereo{uuid(), folder.getChildFile("stereo.aiff"), 3, 2};
        TrackCapture::Target synth{uuid(), folder.getChildFile("synth.wav"), 1, 1, true};
        TrackCapture::Target midi{uuid(), {}, 1, 2, false, true};
        TrackCapture capture({mono, stereo, synth, midi}, 48000, 24, 120);
        std::array<int, 128> mapping;
        mapping.fill(-1);
        mapping[2] = 0;
        mapping[3] = 1;
        AudioBuffer<float> input(2, 480), bus(2, 480);
        input.clear();
        bus.clear();
        for (int n = 0; n < 480; ++n) {
            input.setSample(0, n, .25f);
            input.setSample(1, n, -.5f);
            bus.setSample(0, n, .2f);
            bus.setSample(1, n, .6f);
        }
        MidiBuffer notes;
        for (int block = 0; block < 10; ++block) {
            notes.clear();
            if (block == 0) {
                notes.addEvent(MidiMessage::noteOn(2, 60, (uint8)100), 0);
                notes.addEvent(MidiMessage::controllerEvent(2, 64, 127), 120);
                notes.addEvent(MidiMessage::noteOff(2, 60), 240);
                notes.addEvent(MidiMessage::noteOn(1, 70, (uint8)100), 0);
            }
            if (block == 4)
                notes.addEvent(MidiMessage::controllerEvent(2, 64, 0), 0);
            if (block == 5)
                notes.addEvent(MidiMessage::noteOn(2, 64, (uint8)80), 0);
            capture.input(input.getArrayOfReadPointers(), 2, 480, mapping);
            capture.bus(synth.track, bus, 480);
            capture.midi(midi.track, notes, 480, 2);
            capture.advance(480);
        }
        auto takes = capture.finish();
        expect(takes.size() == 4 && capture.overflows() == 0, "Capture count/overflows");
        AudioFormatManager formats;
        registerAudioFormats(formats);
        for (size_t i = 0; i < 3; ++i) {
            auto reader =
                std::unique_ptr<AudioFormatReader>(formats.createReaderFor(takes[i].file));
            expect(reader && reader->lengthInSamples == 4800 &&
                       reader->numChannels == (i == 1 ? 2 : 1),
                   "Recorded sample count/channels");
            AudioBuffer<float> data((int)reader->numChannels, 4800);
            reader->read(&data, 0, 4800, 0, true, true);
            expect(std::abs(data.getSample(0, 2400) - (i == 2 ? .4f : .25f)) < .0001f,
                   "Patched/bus capture value");
            if (i == 1)
                expect(std::abs(data.getSample(1, 2400) + .5f) < .0001f, "Stereo second input");
        }
        expect(takes[3].midi && takes[3].midi->notes.size() == 2,
               "MIDI channel filter and held notes");
        const auto &captured = takes[3].midi->notes;
        expect(captured[0].pitch == 60 && std::abs(captured[0].length - .08) < 1e-9,
               "Sustain release timing");
        expect(captured[1].pitch == 64 && std::abs(captured[1].start - .1) < 1e-9 &&
                   std::abs(captured[1].length - .1) < 1e-9,
               "Held note closes at recording end");
        Session session;
        session.addTrack("Record A");
        session.addTrack("Record B");
        const auto a = session.song()->tracks[0].id, b = session.song()->tracks[1].id;
        session.cycleRecordArm(a);
        expect(session.recordingArmed(a), "Manual arm");
        session.cycleRecordArm(a);
        session.setRecordingSelection(b);
        expect(!session.recordingArmed(a), "Auto arm unselected");
        session.setRecordingSelection(a);
        expect(session.recordingArmed(a), "Auto arm selected");
        session.cycleRecordArm(a);
        expect(!session.recordingArmed(a), "Disarm");
    });
    test("Clip audio preserves pitch through rate, transposition, loops and seek", [&] {
        const auto source = directory.getChildFile("clip-pitch-" + text(uuid()) + ".wav");
        WavAudioFormat wav;
        auto stream = std::make_unique<FileOutputStream>(source);
        auto writer = std::unique_ptr<AudioFormatWriter>(
            wav.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
        expect(writer != nullptr, "Pitch fixture writer");
        stream.release();
        AudioBuffer<float> tone(2, 48000 * 5);
        for (int ch = 0; ch < 2; ++ch)
            for (int n = 0; n < tone.getNumSamples(); ++n)
                tone.setSample(ch, n,
                               (float)(.2 * std::sin(MathConstants<double>::twoPi *
                                                     (ch == 0 ? 440 : 660) * n / 48000.)));
        writer->writeFromAudioSampleBuffer(tone, 0, tone.getNumSamples());
        writer.reset();
        AudioFormatManager formats;
        registerAudioFormats(formats);
        auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(source));
        AudioBuffer<float> scratch(2, 131080), output(2, 480);
        jaras::Song song;
        song.id = uuid();
        song.name = "Pitch";
        song.duration = 2;
        jaras::Track track;
        track.id = uuid();
        track.name = "Tone";
        song.tracks = {track};
        jaras::AudioClip clip;
        clip.id = uuid();
        clip.duration = 2;
        clip.sourceOffset = .25;
        ClipAudio processor(song, track, clip, 48000);
        for (auto [speed, pitch] :
             std::initializer_list<std::pair<double, int>>{{.5, 0}, {2, 0}, {1, 12}, {2, -12}}) {
            clip.playbackRate = speed;
            clip.pitchSemitones = pitch;
            processor.configure(song, track, clip, 48000);
            processor.prepare(48000); // Same-rate device reattachment preserves prepared plans.
            int crossings[2]{};
            float previous[2]{};
            double energy = 0;
            for (int block = 0; block < 150; ++block) {
                expect(processor.render(*reader, scratch, output, 0, block * .01, 480),
                       "Clip render read");
                if (block >= 50)
                    for (int ch = 0; ch < 2; ++ch)
                        for (int n = 0; n < 480; ++n) {
                            float value = output.getSample(ch, n);
                            expect(std::isfinite(value), "Clip sample finite");
                            if (previous[ch] <= 0 && value > 0)
                                ++crossings[ch];
                            previous[ch] = value;
                            energy += value * value;
                        }
            }
            for (int ch = 0; ch < 2; ++ch)
                expect(std::abs(crossings[ch] - (ch == 0 ? 440 : 660) * std::pow(2., pitch / 12.)) <
                           6,
                       "Rate changed pitch or transposition failed: " + String(speed) + " / " +
                           String(pitch) + " / " + String(crossings[ch]));
            expect(energy > 100, "Clip lost audio");
            expect(processor.render(*reader, scratch, output, 1, .9, 480) &&
                       output.getMagnitude(0, 480) > .02f,
                   "Sub Play seek has no initial audio");
            expect(processor.render(*reader, scratch, output, 0, .4, 480) &&
                       output.getMagnitude(0, 480) > .02f,
                   "Main seek has no initial audio");
        }
        clip.playbackRate = 1;
        clip.pitchSemitones.reset();
        song.timeSettings.emplace();
        song.timeSettings->timebase=jaras::ProjectTimebase::relative;
        jaras::TimelineMarker tempo{uuid(),"Tempo",.5,0x999999};
        tempo.tempoBPM=240; tempo.tempoReferenceBPM=120; tempo.tempoTimebase="relative";
        song.markers=std::vector<jaras::TimelineMarker>{tempo};
        ClipAudio varied(song,track,clip,48000);
        expect(ClipAudio::needed(song,track,clip) && std::abs(varied.sourcePosition(1)-1.75)<1e-9,
               "Audio did not consume source at the new tempo");
        int variedCrossings=0;float previousSample=0;
        for(int block=0;block<150;++block){
            expect(varied.render(*reader,scratch,output,0,block*.01,480),"Variable-tempo audio read");
            if(block>=100)for(int n=0;n<480;++n){
                const float sample=output.getSample(0,n);
                if(previousSample<=0 && sample>0)++variedCrossings;
                previousSample=sample;
            }
        }
        expect(std::abs(variedCrossings-220)<5,"Tempo marker changed the pitch of the audio");
        song.markers.reset();
        clip.loopStart = .25;
        clip.loopLength = .1;
        ClipAudio loop(song, track, clip, 48000);
        expect(loop.render(*reader, scratch, output, 0, .295, 480), "Loop read");
        expect(output.getMagnitude(0, 480) > .1f, "Loop boundary lost audio");
        jaras::Track group;
        group.id = uuid();
        group.name = "Group";
        track.parentTrackID = group.id;
        song.tracks = {group, track};
        jaras::Part part{uuid(), "Song", 0, 2};
        part.pitchSemitones = 7;
        part.pitchTrackIDs = std::vector<ID>{};
        part.pitchGroupIDs = std::vector<ID>{group.id};
        song.parts = {part};
        expect(regionPitch::value(song, track, .5) == 7, "Group pitch not inherited");
        song.parts[0].pitchGroupIDs = std::vector<ID>{};
        expect(regionPitch::value(song, track, .5) == 0, "Excluded track still transposed");
        song.parts[0].pitchTrackIDs = std::vector<ID>{track.id};
        expect(regionPitch::value(song, track, .5) == 7, "Explicit track pitch not applied");
        jaras::MIDIItem midi;
        midi.notes.push_back({uuid(), 0, 1, 60, 100, 1});
        clip.midi = midi;
        clip.loopLength.reset();
        track.clips = {clip};
        const auto notes = playbackNotes(track, &song);
        expect(!notes.empty() && notes.front().pitch == 67,
               "Region transposition missing from MIDI");
        clip.midi.reset();
        clip.audioFile = jaras::AudioFile{utf8(source.getFileName()), {}};
        track.clips = {clip};
        song.tracks = {group, track};
        AudioEngine engine;
        engine.prepareSong(song, directory);
        engine.setOffline(true);
        AudioEngine::State state;
        state.playing = true;
        state.position = .5;
        engine.transport(state);
        int crossings = 0;
        float previous = 0;
        for (int block = 0; block < 100; ++block) {
            engine.render(output.getArrayOfWritePointers(), 2, 480);
            for (int sample = 0; sample < 480; ++sample) {
                const float value = output.getSample(0, sample);
                if (previous <= 0 && value > 0)
                    ++crossings;
                previous = value;
            }
        }
        expect(std::abs(crossings - 440 * std::pow(2., 7 / 12.)) < 6,
               "Audio engine ignored the selected region's pitch");
    });
    test("Resolume uses leaf regions and protects media while confirming REST mutations", [&] {
        auto project = projectFixture();
        auto &song = project.songs[0];
        song.parts[0].startTime = 0;
        auto first = song.parts[0];
        first.id = uuid();
        first.name = "Child A";
        first.endTime = 10;
        first.parentRegionID = song.parts[0].id;
        auto second = first;
        second.id = uuid();
        second.name = "Child B";
        second.startTime = 10;
        second.endTime = 20;
        song.parts.push_back(first);
        song.parts.push_back(second);
        auto regions = Lighting::buildResolumeRegions(project);
        expect(regions.size() == 3 && regions[1].id == second.id && regions[1].cues.size() == 2,
               "Resolume did not map leaf regions or smallest marker owner");
        regions[1].cues.push_back({uuid(), "Extra", 15, false});
        auto saved = object();
        put(saved, Identifier("region:" + text(second.id)), "4:0");
        for (size_t i = 1; i < regions[1].cues.size(); ++i)
            put(saved, Identifier("marker:" + text(regions[1].cues[i].id)), "4:2");
        auto assignments = Lighting::buildResolumeAssignments(regions, saved, true);
        expect(
            get(assignments, Identifier("marker:" + text(regions[1].cues[1].id))).toString() ==
                    "4:2" &&
                get(assignments, Identifier("marker:" + text(regions[1].cues[2].id))).toString() ==
                    "4:3",
            "Resolume reused a duplicate column");
        ResolumeComposition::Plan plan;
        plan.name = "Test Show";
        plan.decks[1] = {1, "One", {{1, "Inicio"}}};
        plan.decks[2] = {2, "Two", {{1, "Inicio"}}};
        const auto destination = directory.getChildFile("resolume-" + text(uuid()) + ".avc");
        StringArray names{"Empty", "Empty 2"};
        int selected = 1, posts = 0, saves = 0, destructive = 0;
        String compositionName = "Untitled", columnName = "Column 1";
        bool containsMedia = true;
        auto snapshot = [&] {
            auto value = object();
            put(value, "name", ResolumeComposition::parameter(compositionName));
            Array<var> decks;
            for (int i = 0; i < names.size(); ++i) {
                auto deck = object(), active = object();
                put(deck, "id", i + 1);
                put(deck, "name", ResolumeComposition::parameter(names[i]));
                put(active, "value", selected == i + 1);
                put(deck, "selected", active);
                decks.add(deck);
            }
            put(value, "decks", decks);
            auto column = object();
            put(column, "name", ResolumeComposition::parameter(columnName));
            put(value, "columns", Array<var>{column});
            Array<var> layers;
            if (containsMedia && selected == 2) {
                auto layer = object(), clip = object(), video = object();
                put(video, "file", "valuable.mov");
                put(clip, "video", video);
                put(layer, "clips", Array<var>{clip});
                layers.add(layer);
            }
            put(value, "layers", layers);
            return value;
        };
        ResolumeComposition::Request request = [&](const String &path, const String &method,
                                                   const String &body, const String &) -> var {
            if (path == "/product") {
                auto product = object();
                put(product, "name", "Arena");
                put(product, "major", 7);
                put(product, "minor", 27);
                return product;
            }
            if (path.endsWith("/select"))
                selected = path.fromFirstOccurrenceOf("/decks/", false, false).getIntValue();
            if (method == "DELETE") {
                ++destructive;
                names.remove(names.size() - 1);
            }
            if (path == "/composition/decks/add") {
                ++posts;
                names.add("Empty");
                throw ResolumeComposition::Unconfirmed();
            }
            if (path == "/composition" && method == "PUT") {
                auto data = JSON::parse(body);
                compositionName = str(get(data, "name"), "value");
                names.clear();
                for (const auto &deck : list(get(data, "decks")))
                    names.add(str(get(deck, "name"), "value"));
            }
            if (path == "/composition/columns/1" && method == "PUT")
                columnName = str(get(JSON::parse(body), "name"), "value");
            if (path == "/composition/save") {
                ++saves;
                expect(URL(body).getLocalFile() == destination, "Resolume save URL changed");
                destination.replaceWithText("Test composition");
            }
            return snapshot();
        };
        bool protectedMedia = false;
        try {
            ResolumeComposition(request).create(plan, destination);
        } catch (const std::exception &e) {
            protectedMedia = String::fromUTF8(e.what()).contains(String::fromUTF8("mídia"));
        }
        expect(protectedMedia && posts == 0 && destructive == 0 && saves == 0,
               "Existing media in an inactive deck was modified");
        containsMedia = false;
        names = {"Empty"};
        selected = 1;
        ResolumeComposition(request).create(plan, destination);
        expect(posts == 1 && saves == 1 && names == StringArray{"One", "Two"} && selected == 1 &&
                   destination.getSize() > 0,
               "Ambiguous POST duplicated a deck or failed to save");
        bool existingProtected = false;
        try {
            ResolumeComposition(request).create(plan, destination);
        } catch (...) {
            existingProtected = true;
        }
        expect(existingProtected && posts == 1 && saves == 1,
               "Existing destination was overwritten");
    });
    test("Resolume HTTP client sends real methods and UTF-8 JSON over loopback", [&] {
        struct HTTPFixture final : Thread {
            StreamingSocket listener;
            String error;
            HTTPFixture() : Thread("Resolume HTTP fixture") {
                if (!listener.createListener(0, "127.0.0.1"))
                    throw std::runtime_error("Loopback listener failed");
                startThread();
            }
            ~HTTPFixture() override {
                signalThreadShouldExit();
                listener.close();
                stopThread(5000);
            }
            void run() override {
                try {
                    for (int index = 0; index < 2 && !threadShouldExit(); ++index) {
                        if (listener.waitUntilReady(true, 3000) <= 0)
                            throw std::runtime_error("No HTTP connection");
                        auto client =
                            std::unique_ptr<StreamingSocket>(listener.waitForNextConnection());
                        if (!client)
                            throw std::runtime_error("HTTP accept failed");
                        MemoryOutputStream raw;
                        String request;
                        int length = 0, headerEnd = -1;
                        for (int tries = 0; tries < 100; ++tries) {
                            if (client->waitUntilReady(true, 100) <= 0)
                                continue;
                            char bytes[2048];
                            const int count = client->read(bytes, sizeof(bytes), false);
                            if (count <= 0)
                                break;
                            raw.write(bytes, count);
                            request = raw.toUTF8();
                            headerEnd = request.indexOf("\r\n\r\n");
                            if (headerEnd >= 0) {
                                auto headers =
                                    StringArray::fromLines(request.substring(0, headerEnd));
                                for (auto line : headers)
                                    if (line.startsWithIgnoreCase("Content-Length:"))
                                        length = line.fromFirstOccurrenceOf(":", false, false)
                                                     .getIntValue();
                                auto body = request.substring(headerEnd + 4);
                                if ((int)body.getNumBytesAsUTF8() >= length)
                                    break;
                            }
                        }
                        if (index == 0) {
                            if (!request.startsWith("GET /api/v1/product "))
                                throw std::runtime_error("Wrong GET request");
                        } else {
                            if (!request.startsWith("PUT /api/v1/composition "))
                                throw std::runtime_error("Wrong PUT request");
                            auto body = JSON::parse(request.substring(headerEnd + 4));
                            if (str(body, "name") != String::fromUTF8("São João"))
                                throw std::runtime_error("POST body encoding changed");
                        }
                        const String response = "{\"ok\":true}";
                        const auto message =
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: "
                            "close\r\nContent-Length: " +
                            String(response.getNumBytesAsUTF8()) + "\r\n\r\n" + response;
                        client->write(message.toRawUTF8(), (int)message.getNumBytesAsUTF8());
                    }
                } catch (const std::exception &e) {
                    error = String::fromUTF8(e.what());
                }
            }
        } fixture;
        auto request = ResolumeComposition::network("127.0.0.1", fixture.listener.getBoundPort());
        expect(flag(request("/product", "GET", {}, "application/json"), "ok"),
               "HTTP GET response invalid");
        auto body = object();
        put(body, "name", String::fromUTF8("São João"));
        expect(flag(request("/composition", "PUT", JSON::toString(body, true), "application/json"),
                    "ok"),
               "HTTP PUT response invalid");
        expect(fixture.waitForThreadToExit(4000) && fixture.error.isEmpty(),
               "Loopback REST verification failed: " + fixture.error);
    });
    test("Timeline clipboard preserves complete items, relative positions and undo", [&] {
        auto p = projectFixture();
        auto &first = p.songs[0].tracks[0].clips[0];
        first.fxJSON = utf8(JSON::toString(fxschema::complete(JSON::parse(R"({"inserted":["EQ"],"eqEnabled":true,"bands":[{"frequency":1000,"gain":5}]})")),true,17));
        first.fadeInCurve = .4; first.fadeOutSCurve = -.2; first.pan = -.3;
        first.loopStart = 1; first.loopLength = 4; first.separatedStemTracks = {uuid()};
        auto other = p.songs[0].tracks[0]; other.id = uuid(); other.clips[0].id = uuid();
        other.clips[0].startTime = 20; other.clips[0].midi.emplace(); other.clips[0].audioFile.reset();
        other.clips[0].midi->notes.push_back({uuid(), 0, 1, 60, 100, 1});
        const auto firstID = first.id, secondID = other.clips[0].id;
        p.songs[0].tracks.push_back(other);
        const auto clipboard = GridItemClipboard::copy(p,p.songs[0].id,{firstID,secondID});
        expect(bool(clipboard),"Copy lost the selection");
        const auto entries = clipboard->items(p,100), repeated = clipboard->items(p,200);
        const auto &copy = entries[0].clips[0], &source = p.songs[0].tracks[0].clips[0];
        expect(copy.id!=firstID && copy.id!=repeated[0].clips[0].id && copy.separatedStemTracks.empty(),"Paste reused an item ID or derived-track ownership");
        expect(copy.startTime==100 && entries[1].clips[0].startTime==110 && entries[1].id==other.id,"Multiple-item paste lost track or timing offsets");
        expect(copy.fxJSON==source.fxJSON && copy.audioFile->path==source.audioFile->path && copy.fadeInCurve==source.fadeInCurve && copy.fadeOutSCurve==source.fadeOutSCurve && copy.gain==source.gain && copy.pan==source.pan && copy.loopLength==source.loopLength && copy.waveform==source.waveform,"Paste changed item processing or source data");
        expect(entries[1].clips[0].midi->notes[0].pitch==60 && clipboard->endPosition()==28,"MIDI copy or duplicate endpoint incorrect");
        Session session; session.inspection=true; session.restoreSnapshot(ProjectCodec::encode(p));
        const auto apply=[&](const auto &values){session.edit([&](auto &project){auto edit=session.core;edit.pasteItems(clipboard->song,values,false);project=edit.project();});};
        apply(entries);expect(session.song()->tracks[0].clips.size()==2 && session.song()->tracks[1].clips.size()==2,"Paste did not insert all items");
        session.undo();expect(session.song()->tracks[0].clips.size()==1 && session.song()->tracks[1].clips.size()==1,"One undo must remove the complete paste");
        session.redo();expect(session.song()->tracks[0].clips.back().id==copy.id && session.song()->tracks[0].clips.back().fxJSON==source.fxJSON,"Redo did not restore exact item state");
        const auto duplicate=clipboard->items(p,clipboard->endPosition());
        expect(duplicate[0].clips[0].startTime==28 && duplicate[1].clips[0].startTime==38,"Duplicate must begin immediately after the selected span");
        auto foreign=p;foreign.id=uuid();bool rejected=false;try{clipboard->items(foreign,0);}catch(...){rejected=true;}
        expect(rejected,"Clipboard crossed project media roots");
    });
    test("MIDI timeline extension repeats notes and draws bottom triangular cuts", [&] {
        auto p=projectFixture();auto &track=p.songs[0].tracks[0];auto &clip=track.clips[0];
        clip.startTime=10;clip.duration=2;clip.sourceOffset=0;clip.audioFile.reset();clip.fadeIn.reset();clip.fadeOut.reset();
        clip.midi.emplace();clip.midi->sourceBPM=120;clip.midi->notes={{uuid(),0,1,60,100,1},{uuid(),2,1,67,100,1}};
        const auto original=clip;
        clip=clipEditing::resizedSource(original,10,16);
        const auto right=playbackNotes(track);expect(right.size()==6,"Right extension did not repeat MIDI notes");
        for(size_t i=0;i<right.size();++i) expect(right[i].start==10+i,"Right MIDI repeat timing differs");
        const auto outline=itemOutline(clip,{0,0,600,60},600,100);
        for(float x:{200.f,400.f}) expect(!outline.contains(x,59) && outline.contains(x,50),"Repeated MIDI item has no bottom cut");
        clip=clipEditing::resizedSource(original,6,12);const auto left=playbackNotes(track);
        expect(left.size()==6 && left.front().start==6 && left.back().start==11 && clip.midi->notes[1].start==2,"Left extension changed original MIDI notes");
    });
    test("Timeline trimming preserves Mac source loops, MIDI notes and track constraints", [&] {
        auto p = projectFixture();
        auto &song = p.songs[0];
        auto &clip = song.tracks[0].clips[0];
        const auto id = clip.id;
        clip.startTime = 20;
        clip.duration = 10;
        clip.playbackRate = 2;
        clip.sourceOffset = 30;
        const auto preview = clipEditing::resizedSource(clip, 17, 35);
        expect(clip.startTime==20 && clip.duration==10 && !clip.loopLength, "Resize preview mutated the saved item");
        expect(preview.sourceOffset==24 && !preview.loopLength && preview.duration==18, "Live resize preview differs from committed source loop");
        const auto outline=itemOutline(preview,{0,0,360,60},360,20);
        const auto seams=itemLoopSeams(preview,{0,0,360,60},360,20);
        expect(seams.empty(),"Expanding an ordinary trim must not create repeated-source cuts");
        for(auto seam:seams) expect(!outline.contains(seam,59) && outline.contains(seam,50),"Bottom triangular cut not visible during edge drag");
        const ItemHeader edges({0,0,360,60},360,song.tracks[0],preview);
        expect(edges.resizeSide({9,56})==-1 && edges.resizeSide({351,56})==1 && !edges.resizeSide({180,56}),"Edge grab tolerance differs from Mac");
        clipEditing::resize(p, id, 23, 28);
        expect(clip.sourceOffset == 36 && !clip.loopStart && !clip.loopLength &&
                   clip.duration == 5,
               "Audio trim changed the source loop");
        clipEditing::resize(p, id, 17, 31);
        expect(clip.sourceOffset == 24 && !clip.loopLength && clip.duration == 14,
               "Audio extension failed to wrap the original source");
        auto portable = ProjectCodec::decode(ProjectCodec::encode(p, {}));
        expect(!portable.songs[0].tracks[0].clips[0].loopLength,
               "Trim loop was lost through project serialization");
        clip.audioFile.reset();
        clip.loopLength.reset();
        clip.loopStart.reset();
        clip.midi.emplace();
        clip.midi->sourceBPM = 120;
        clip.midi->notes.push_back({uuid(), 3, 1, 60, 100, 1});
        clip.startTime = 10;
        clip.sourceOffset = 1;
        clipEditing::resize(p, id, 8, 20);
        expect(clip.sourceOffset == 25 && clip.loopLength == 28 && clip.midi->notes[0].start == 3,
               "MIDI left extension must repeat the original source without moving notes");
        jaras::Track destination;
        destination.id = uuid();
        destination.name = "Target";
        const auto target = destination.id;
        song.tracks.push_back(destination);
        clipEditing::move(p, id, 15, target);
        expect(song.tracks[0].clips.empty() && song.tracks[1].clips[0].id == id &&
                   song.tracks[1].clips[0].startTime == 15,
               "Drag did not transfer the item to its target track");
        auto &textTrack = song.tracks[1];
        textTrack.role.id = "teleprompt";
        textTrack.name = jaras::fixedTrackName(textTrack.role);
        textTrack.clips[0].text = "A";
        textTrack.clips[0].audioFile.reset();
        textTrack.clips[0].midi.reset();
        textTrack.clips[0].gain.reset();
        textTrack.clips[0].waveform.clear();
        auto neighbour = textTrack.clips[0];
        neighbour.id = uuid();
        neighbour.startTime = 28;
        neighbour.duration = 5;
        textTrack.clips.push_back(neighbour);
        bool rejected = false;
        try {
            clipEditing::resize(p, id, 15, 30);
        } catch (...) {
            rejected = true;
        }
        expect(rejected && textTrack.clips[0].duration == 12, "Text trim overlapped its neighbour");
        rejected = false;
        try {
            clipEditing::move(p, id, 0, song.tracks[0].id);
        } catch (...) {
            rejected = true;
        }
        expect(rejected && textTrack.clips.size() == 2, "Text item escaped its own track");
        jaras::validate(p);
    });
    test("Remote cipher authenticates directions, counters and fragmented frames", [&] {
        using namespace remote;
        Key hostKey{}, clientKey{};
        for (int i = 0; i < 32; ++i) {
            hostKey[(size_t)i] = (uint8_t)(i + 1);
            clientKey[(size_t)i] = (uint8_t)(100 + i);
        }
        Cipher host(Cipher::host, "CatLive Windows", hostKey),
            client(Cipher::client, "iPad QA", clientKey);
        const auto hostHello = host.hello(), clientHello = client.hello();
        expect(host.accept(clientHello) == "iPad QA" &&
                   client.accept(hostHello) == "CatLive Windows",
               "Remote hello exchange failed");
        const auto hostReady = host.seal({0}), clientReady = client.seal({0});
        expect(client.open(hostReady) == Bytes{0} && host.open(clientReady) == Bytes{0},
               "Encrypted ready failed");
        auto status = object();
        put(status, "requiresPIN", true);
        put(status, "noticesRequiresPIN", false);
        auto access = object();
        put(access, "mode", "observer");
        put(access, "pin", "");
        auto hostPlain = packet(6, status), clientPlain = packet(5, access);
        hostPlain.insert(hostPlain.begin(), 1);
        clientPlain.insert(clientPlain.begin(), 1);
        const auto hostPacket = host.seal(hostPlain), clientPacket = client.seal(clientPlain);
        bool rejected = false;
        try {
            host.open(hostPacket);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Remote accepted reflected ciphertext");
        auto damaged = clientPacket;
        damaged.back() ^= 1;
        rejected = false;
        try {
            host.open(damaged);
        } catch (...) {
            rejected = true;
        }
        expect(rejected && host.open(clientPacket) == clientPlain,
               "Remote failed tag verification or advanced counter on invalid tag");
        expect(client.open(hostPacket) == hostPlain, "Remote application packet failed");
        rejected = false;
        try {
            client.open(hostPacket);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Remote accepted replayed ciphertext");
        Cipher unknown(Cipher::host, "Host");
        auto badHello = clientHello;
        std::fill(badHello.begin() + 5, badHello.begin() + 37, 0);
        rejected = false;
        try {
            unknown.accept(badHello);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Remote accepted a low-order X25519 public key");
        Frames parser;
        auto framed = Frames::encode(hostHello);
        append(framed, Frames::encode(hostReady));
        std::vector<Bytes> received;
        for (auto byte : framed) {
            const auto next = parser.receive(&byte, 1);
            received.insert(received.end(), next.begin(), next.end());
        }
        expect(received == std::vector<Bytes>{hostHello, hostReady},
               "Remote TCP fragmentation lost a frame");
        uint8_t huge[]{0x7f, 0xff, 0xff, 0xff};
        rejected = false;
        try {
            parser.receive(huge, 4);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Remote accepted an oversized frame");
        auto evidence = object();
        auto hex = [&](const char *name, const Bytes &bytes) {
            put(evidence, Identifier(name),
                String::toHexString(bytes.data(), (int)bytes.size(), 0));
        };
        hex("hostHello", hostHello);
        hex("clientHello", clientHello);
        hex("hostReady", hostReady);
        hex("clientReady", clientReady);
        hex("hostPacket", hostPacket);
        hex("clientPacket", clientPacket);
        hex("hostPlain", hostPlain);
        hex("clientPlain", clientPlain);
        expect(
            directory.getChildFile("remote-cipher.json").replaceWithText(JSON::toString(evidence)),
            "Could not save independent Remote evidence");
    });
    test("Remote TCP negotiates encrypted access and rejects replay on loopback", [&] {
        using namespace remote;
        Transport server;
        const auto port = server.start("CatLive QA");
        StreamingSocket socket;
        expect(port > 0 && socket.connect("127.0.0.1", port, 2000), "Remote listener failed");
        Cipher client(Cipher::client, "iPad QA");
        Frames frames;
        std::deque<Bytes> received;
        auto readFrame = [&]() {
            const auto deadline = Time::getMillisecondCounterHiRes() + 4000;
            while (received.empty() && Time::getMillisecondCounterHiRes() < deadline) {
                if (socket.waitUntilReady(true, 20) <= 0)
                    continue;
                uint8_t data[8192];
                const auto size = socket.read(data, sizeof(data), false);
                expect(size > 0, "Remote socket closed before response");
                for (auto &frame : frames.receive(data, (size_t)size))
                    received.push_back(std::move(frame));
            }
            expect(!received.empty(), "Remote socket response timed out");
            auto result = std::move(received.front());
            received.pop_front();
            return result;
        };
        auto writeFrame = [&](const Bytes &data, bool fragmented = false) {
            const auto bytes = Frames::encode(data);
            for (size_t offset = 0; offset < bytes.size();) {
                const int count = fragmented ? 1 : (int)(bytes.size() - offset);
                const int sent = socket.write(bytes.data() + offset, count);
                expect(sent > 0, "Remote socket write failed");
                offset += (size_t)sent;
            }
        };
        expect(client.accept(readFrame()) == "CatLive QA", "Remote TCP hello mismatch");
        writeFrame(client.hello(), true);
        expect(client.open(readFrame()) == Bytes{0}, "Remote TCP host ready failed");
        writeFrame(client.seal({0}));
        auto waitEvent = [&](Transport::Event::Type type) {
            const auto deadline = Time::getMillisecondCounterHiRes() + 4000;
            while (Time::getMillisecondCounterHiRes() < deadline) {
                for (auto &event : server.events())
                    if (event.type == type)
                        return event;
                Thread::sleep(5);
            }
            throw std::runtime_error("Remote event timed out");
        };
        const auto connected = waitEvent(Transport::Event::connected);
        expect(connected.name == "iPad QA" && server.peers().count(connected.client),
               "Remote peer missing");
        auto access = object();
        put(access, "mode", "observer");
        put(access, "pin", "");
        auto plain = packet(5, access);
        plain.insert(plain.begin(), 1);
        const auto encrypted = client.seal(plain);
        writeFrame(encrypted, true);
        const auto request = waitEvent(Transport::Event::packetReceived);
        expect(request.kind == 5 && request.body["mode"].toString() == "observer",
               "Remote access request lost");
        auto status = object();
        put(status, "mode", "observer");
        put(status, "requiresPIN", false);
        const auto statusPacket = packet(6, status);
        expect(server.send(connected.client, statusPacket), "Remote response queue rejected");
        auto expected = statusPacket;
        expected.insert(expected.begin(), 1);
        expect(client.open(readFrame()) == expected, "Remote response payload changed");
        auto ack = packet(3, var(int64(42)));
        ack.insert(ack.begin(), 1);
        writeFrame(client.seal(ack));
        const auto acknowledgment = waitEvent(Transport::Event::packetReceived);
        expect(acknowledgment.kind == 3 && (int64)acknowledgment.body == 42,
               "Remote disconnected on a scalar snapshot acknowledgement");
        writeFrame(encrypted);
        expect(waitEvent(Transport::Event::disconnected).client == connected.client &&
                   server.peers().empty(),
               "Remote replay did not disconnect");
        server.stop();
        expect(!server.running(), "Remote thread failed to stop");
    });
    test("Remote authorization enforces roles, PIN changes and typed commands", [&] {
        using namespace remote;
        Appearance preferences(directory.getChildFile("remote-access.json"));
        Host host(preferences);
        expect(host.savePIN(false, "1234") && !host.savePIN(false, "12"),
               "Remote PIN validation failed");
        int invoked = 0;
        host.perform = [&](const remote::Command &) {
            ++invoked;
            return true;
        };
        host.start(false);
        StreamingSocket socket;
        expect(socket.connect("127.0.0.1", host.port, 2000), "Remote host failed");
        Cipher client(Cipher::client, "Role QA");
        Frames frames;
        std::deque<Bytes> incoming;
        auto write = [&](const Bytes &bytes) {
            const auto frame = Frames::encode(bytes);
            size_t sent = 0;
            while (sent < frame.size()) {
                const int count = socket.write(frame.data() + sent, (int)(frame.size() - sent));
                expect(count > 0, "Remote host write failed");
                sent += count;
            }
        };
        auto read = [&]() {
            const auto until = Time::getMillisecondCounterHiRes() + 4000;
            while (incoming.empty() && Time::getMillisecondCounterHiRes() < until) {
                host.update();
                if (socket.waitUntilReady(true, 10) <= 0)
                    continue;
                uint8_t buffer[8192];
                const int size = socket.read(buffer, sizeof(buffer), false);
                expect(size > 0, "Remote host closed early");
                for (auto &frame : frames.receive(buffer, size))
                    incoming.push_back(std::move(frame));
            }
            expect(!incoming.empty(), "Remote host read timed out");
            auto value = std::move(incoming.front());
            incoming.pop_front();
            return value;
        };
        client.accept(read());
        write(client.hello());
        expect(client.open(read()) == Bytes{0}, "Host ready missing");
        write(client.seal({0}));
        auto receive = [&](int kind) {
            const auto bytes = client.open(read());
            expect(bytes.size() > 5 && bytes[0] == 1 && bytes[4] == kind,
                   "Unexpected Remote packet kind");
            return JSON::parse(
                String::fromUTF8((const char *)bytes.data() + 5, (int)bytes.size() - 5));
        };
        auto send = [&](int kind, const var &value) {
            auto bytes = packet((uint8_t)kind, value);
            bytes.insert(bytes.begin(), 1);
            write(client.seal(bytes));
        };
        auto access = [&](String mode, String pin) {
            auto value = object();
            put(value, "mode", mode);
            put(value, "pin", pin);
            send(5, value);
            return receive(6);
        };
        expect(flag(receive(6), "requiresPIN"), "Director PIN status missing");
        expect(str(access("observer", ""), "mode") == "observer", "Observer should not need PIN");
        auto command = object();
        put(command, "id", text(uuid()));
        put(command, "project", text(uuid()));
        put(command, "action", "play");
        put(command, "value", 0);
        send(1, command);
        const auto waitUntil = Time::getMillisecondCounterHiRes() + 150;
        while (Time::getMillisecondCounterHiRes() < waitUntil) {
            host.update();
            Thread::sleep(5);
        }
        expect(invoked == 0, "Observer changed transport");
        expect(get(access("director", "9999"), "mode").isVoid(),
               "Incorrect PIN gained director access");
        expect(str(access("director", "1234"), "mode") == "director", "Correct PIN rejected");
        send(1, command);
        const auto commandDeadline = Time::getMillisecondCounterHiRes() + 2000;
        while (!invoked && Time::getMillisecondCounterHiRes() < commandDeadline) {
            host.update();
            Thread::sleep(5);
        }
        expect(invoked == 1, "Authorized director command lost");
        expect(host.savePIN(false, "5678") && get(receive(6), "mode").isVoid(),
               "PIN change failed to revoke director");
        expect(str(access("notices", ""), "mode") == "notices", "Notices access rejected");
        put(command, "action", "noticeSend");
        put(command, "text", "TESTE");
        put(command, "value", -1);
        put(command, "noticeReceiptRequested", true);
        send(1, command);
        expect(flag(receive(7), "accepted") && invoked == 2, "Notice receipt failed");
        auto typed = remote::Command::decode(command);
        expect(typed.allowed("notices") && !typed.allowed("observer"),
               "Notice role whitelist failed");
        put(command, "value", "-1");
        bool rejected = false;
        try {
            remote::Command::decode(command);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Remote coerced a string to a command number");
        put(command, "value", -1);
        put(command, "project", "not-a-uuid");
        rejected = false;
        try {
            remote::Command::decode(command);
        } catch (...) {
            rejected = true;
        }
        expect(rejected, "Remote accepted invalid project identity");
        host.stop();
    });
    test("Remote presentation keeps paths private and applies only current project commands", [&] {
        Session session;
        session.inspection = true;
        session.mediaDirectory = directory;
        session.restoreSnapshot(ProjectCodec::encode(projectFixture()));
        Appearance preferences(directory.getChildFile("remote-presentation.json"));
        StageState stage(preferences);
        remote::Presentation presentation(session, stage);
        const auto state = presentation.snapshot(1);
        expect(remote::validID(state["project"]) && get(state, "tracks").isArray() &&
                   get(state, "teleprompters").isArray(),
               "Remote state misses required presentation");
        const auto teleprompters = list(get(state, "teleprompters"));
        const auto blocks = list(get(teleprompters[0], "blocks"));
        expect(!blocks.isEmpty() && remote::validID(get(blocks[0], "id")) &&
                   get(blocks[0], "rows").isArray(),
               "Remote teleprompter blocks must match the Mac protocol");
        for (const auto &block : blocks)
            for (const auto &row : list(get(block, "rows")))
                expect(remote::validID(get(row, "id")),
                       "Remote teleprompter rows need stable region IDs");
        expect(!JSON::toString(state).contains("Stems/") &&
                   !JSON::toString(state).contains(directory.getFullPathName()),
               "Remote exposed a local path");
        auto request = object();
        put(request, "id", text(uuid()));
        put(request, "project", remote::wireID(session.project().id));
        put(request, "song", remote::wireID(session.song()->id));
        put(request, "action", "volume");
        put(request, "value", .42);
        put(request, "target", remote::wireID(session.song()->tracks[0].id));
        expect(presentation.apply(remote::Command::decode(request)) &&
                   std::abs(session.song()->tracks[0].volume - .42) < .00001,
               "Remote track control failed");
        put(request, "project", text(uuid()));
        put(request, "value", .9);
        expect(!presentation.apply(remote::Command::decode(request)) &&
                   std::abs(session.song()->tracks[0].volume - .42) < .00001,
               "Remote stale project changed audio");
        put(request, "project", remote::wireID(session.project().id));
        put(request, "target", var());
        put(request, "action", "timerStart");
        put(request, "value", 10);
        expect(presentation.apply(remote::Command::decode(request)) && stage.running &&
                   stage.target == 10,
               "Remote timer start failed");
        put(request, "action", "timerStop");
        put(request, "value", 0);
        expect(presentation.apply(remote::Command::decode(request)) && !stage.running,
               "Remote timer stop failed");
        directory.getChildFile("remote-state.json")
            .replaceWithText(JSON::toString(presentation.snapshot(1)));
    });
    test("Portable packages exchange encrypted projects and UTF-8 media with Mac, including ZIP64", [&] {
        const auto root=directory.getChildFile("portable-package");
        root.getChildFile("Stems/Primeiro").createDirectory();root.getChildFile("Stems/Segundo").createDirectory();
        auto project=projectFixture();auto &track=project.songs[0].tracks[0];
        track.clips[0].audioFile->path="Stems/Primeiro/Órgão.wav";
        auto second=track.clips[0];second.id=uuid();second.startTime=22;second.audioFile->path="Stems/Segundo/Órgão.wav";track.clips.push_back(second);
        expect(root.getChildFile(String::fromUTF8("Stems/Primeiro/Órgão.wav")).replaceWithText("first media"),"Fixture media");
        expect(root.getChildFile(String::fromUTF8("Stems/Segundo/Órgão.wav")).replaceWithText("second media"),"Fixture media");
        auto raw=ProjectCodec::encode(project);const auto original=JSON::toString(raw);
        auto imports=root.getNonexistentChildFile("Imported",{},false);imports.createDirectory();
        const auto primaryFolder=imports.getChildFile(text(project.name));
        const auto retainedFile=primaryFolder.getChildFile("keep-existing-content.txt");
        for(bool zip64:{false,true}){
            const auto archive=root.getChildFile(zip64?"Windows64.ziplive":"Windows.ziplive");double progress=0;
            portablePackage::exportPackage(raw,root,archive,[&](double p){expect(p>=progress&&p<=1,"Monotonic export progress");progress=p;},zip64);
            expect(progress==1&&JSON::toString(raw)==original,"Export changed source or failed to complete");
            const auto local=portablePackage::importPackage(archive,imports);auto imported=ProjectCodec::decode(ProjectCodec::read(local));
            expect(imported.id==project.id&&imported.name==project.name&&local.getFileName()==text(project.name)+".jl","Project identity or local name changed");
            expect(local.getParentDirectory().getFileName()==text(project.name)+(zip64?"(2)":""),
                   "Portable folder must use the project name and a readable collision suffix, without a UUID");
            expect(imported.songs[0].id==project.songs[0].id&&imported.songs[0].tracks[0].id==track.id&&
                       imported.songs[0].tracks[0].clips[0].id==track.clips[0].id,
                   "A folder collision changed persistent song, track or item identities");
            if(!zip64)expect(retainedFile.replaceWithText("preserve existing folder"),"Folder collision fixture failed");
            else expect(retainedFile.loadFileAsString()=="preserve existing folder"&&
                            primaryFolder.getChildFile(text(project.name)+".jl").existsAsFile(),
                        "Import into a colliding folder overwrote existing project content");
            const auto &clips=imported.songs[0].tracks[0].clips;
            expect(clips[0].audioFile->path!=clips[1].audioFile->path,"Duplicate basenames collided");
            expect(ProjectCodec::resolveMedia(local.getParentDirectory(),clips[0].audioFile->path).loadFileAsString()=="first media"&&ProjectCodec::resolveMedia(local.getParentDirectory(),clips[1].audioFile->path).loadFileAsString()=="second media","Media lost or corrupted");
            expect(local.getSiblingFile("backups").isDirectory()&&local.getSiblingFile("Stems/WF").isDirectory(),"Ordinary editable project folders missing");
            packageZIP::Reader envelope(archive);expect(envelope.entries.size()==4,"Unexpected portable inventory");
            const auto damaged=root.getChildFile(zip64?"Damaged64.ziplive":"Damaged.ziplive");archive.copyFileTo(damaged);
            {FileOutputStream out(damaged);out.setPosition((int64)envelope.entries.at(text(clips[0].audioFile->path)).start);out.writeByte(0);out.flush();}
            bool rejected=false;try{portablePackage::importPackage(damaged,imports);}catch(...){rejected=true;}expect(rejected,"Corrupt media accepted");
        }
        const auto fromMac=directory.getChildFile("Mac.ziplive");
        if(fromMac.existsAsFile()){
            const auto local=portablePackage::importPackage(fromMac,imports);const auto saved=ProjectCodec::read(local);ProjectCodec::write(local,saved);
            portablePackage::exportPackage(ProjectCodec::read(local),local.getParentDirectory(),root.getChildFile("Mac-Windows.ziplive"));
        }
    });
    test("Media cleanup preserves ownership, sibling projects and encrypted recovery backups", [&] {
        const auto root = directory.getNonexistentChildFile("media-cleanup", {}, false);
        expect(root.getChildFile("Stems").createDirectory().wasOk() &&
                   root.getChildFile("backups").createDirectory().wasOk(),
               "Cleanup fixture folders failed");
        auto make = [&](String path) {
            const auto file = root.getChildFile(path);
            file.getParentDirectory().createDirectory();
            expect(file.replaceWithText("fixture " + path), "Cleanup fixture media failed");
        };
        for (auto path : {"Stems/Piano.wav", "Stems/deleted.wav", "Stems/recovery.wav",
                          "Stems/shared.wav", "Stems/unowned.wav", "outside.wav"})
            make(path);
        auto current = projectFixture();
        const auto doc = root.getChildFile("Current.jl");
        const auto currentRaw = ProjectCodec::encode(current, {});
        ProjectCodec::write(doc, currentRaw);
        auto sibling = projectFixture();
        sibling.id = uuid();
        sibling.songs[0].tracks[0].clips[0].audioFile->path = "STEMS/SHARED.WAV";
        const auto siblingFile = root.getChildFile("Sibling.jl");
        // Simulate a document copied into the folder outside CatLive's directory policy.
        const auto siblingBytes =
            ProjectCodec::seal(JSON::toString(ProjectCodec::encode(sibling, {}), true));
        expect(siblingFile.replaceWithData(siblingBytes.getData(), siblingBytes.getSize()),
               "Could not create copied sibling fixture");
        auto backup = current;
        backup.songs[0].tracks[0].clips[0].audioFile->path = "Stems/recovery.wav";
        const auto backupFile = root.getChildFile("backups/Recovery.bkjl");
        ProjectCodec::write(backupFile, ProjectCodec::encode(backup, {}));
        mediaCleanup::Paths known{"Stems/deleted.wav", "Stems/recovery.wav", "Stems/shared.wav",
                                  "Stems/../outside.wav"};
        mediaCleanup::remember(current, doc, known);
        expect(mediaCleanup::removeDeleted(current, currentRaw, doc, {}) == 2,
               "Cleanup removed the wrong media count");
        expect(root.getChildFile("Stems/Piano.wav").existsAsFile() &&
                   root.getChildFile("Stems/shared.wav").existsAsFile() &&
                   root.getChildFile("Stems/unowned.wav").existsAsFile() &&
                   root.getChildFile("outside.wav").existsAsFile(),
               "Cleanup removed live, shared, unowned or outside media");
        expect(!root.getChildFile("Stems/deleted.wav").exists() &&
                   !root.getChildFile("Stems/recovery.wav").exists(),
               "Owned deleted media remained in Stems");
        auto restored = ProjectCodec::decode(ProjectCodec::read(backupFile));
        const auto path = text(restored.songs[0].tracks[0].clips[0].audioFile->path);
        expect(path.startsWith("backups/Media/") &&
                   root.getChildFile(path).loadFileAsString() == "fixture Stems/recovery.wav",
               "Recovery backup lost its media");
        make("Stems/retained.wav");
        mediaCleanup::remember(current, doc, {"Stems/retained.wav"});
        expect(siblingFile.replaceWithText("unreadable"),
               "Could not prepare damaged sibling fixture");
        bool rejected = false;
        try {
            mediaCleanup::removeDeleted(current, currentRaw, doc, {});
        } catch (...) {
            rejected = true;
        }
        expect(rejected && root.getChildFile("Stems/retained.wav").existsAsFile(),
               "Cleanup guessed ownership despite an unreadable sibling");
        expect(!mediaCleanup::mediaPath("Stems/../outside.wav") &&
                   !mediaCleanup::mediaPath("Stems/file.wav:stream") &&
                   !mediaCleanup::mediaPath("Stems\\file.wav"),
               "Unsafe media path accepted");
    });
    test("MIDI editing grid, chord bounds, quantization and source-preserving extension", [&] {
        jaras::MIDIItem midi;
        expect(midiEditing::snap(midi, .34) == .25, "Straight snap differs from Mac");
        midi.mode = "triplet";
        expect(std::abs(midiEditing::snap(midi, .34) - 1. / 3.) < 1e-9, "Triplet snap invalid");
        midi.mode = "swing";
        midi.swing = .5;
        expect(midiEditing::snap(midi, .31) == .375 && midiEditing::snap(midi, -.2, true) == 0,
               "Swing or free snap invalid");
        midi.mode = "straight";
        midi.notes = {{uuid(), .12, .47, 2, 80, 1}, {uuid(), .37, .22, 126, 90, 2}};
        std::set<ID> chosen{midi.notes[0].id, midi.notes[1].id};
        auto moved = midi;
        midiEditing::transform(moved, chosen, -1, 9, 0);
        expect(moved.notes[0].start == 0 && moved.notes[1].start == .25 &&
                   moved.notes[0].pitch == 3 && moved.notes[1].pitch == 127,
               "Chord move lost intervals at bounds");
        auto trimmed = midi;
        midiEditing::transform(trimmed, chosen, 1, 0, -1);
        expect(std::abs(trimmed.notes[1].length - midiEditing::minimum) < 1e-9 &&
                   std::abs(trimmed.notes[0].start + trimmed.notes[0].length - .59) < 1e-9,
               "Left resize lost the note end");
        midiEditing::quantize(midi, {midi.notes[0].id}, .5, true);
        expect(std::abs(midi.notes[0].start - .06) < 1e-9 &&
                   std::abs(midi.notes[0].start + midi.notes[0].length - .545) < 1e-9 &&
                   midi.notes[1].start == .37,
               "Partial quantization affected another channel");
        auto p = projectFixture();
        auto &item = p.songs[0].tracks[0].clips[0];
        item.audioFile.reset();
        item.midi = midi;
        item.sourceOffset = 2;
        item.playbackRate = 2;
        item.duration = 1;
        auto next = midi;
        next.notes.push_back({uuid(), 12, 4, 60, 100, 1});
        midiEditing::replace(p, item.id, next);
        expect(item.duration == 3 && item.sourceOffset == 2,
               "MIDI extension lost source offset or rate");
        const auto portable = ProjectCodec::decode(ProjectCodec::encode(p, {}));
        expect(portable.songs[0].tracks[0].clips[0].midi->notes.size() == 3,
               "MIDI edit lost in the Mac project format");
        item.frozenMIDI = true;
        bool rejected = false;
        try {
            midiEditing::replace(p, item.id, midi);
        } catch (...) {
            rejected = true;
        }
        expect(rejected && item.midi->notes.size() == 3,
               "Frozen audio accepted inaudible MIDI edits");
        item.frozenMIDI.reset();
        jaras::validate(p);
        auto splitProject = projectFixture();
        auto &song = splitProject.songs[0];
        song.tracks[0].clips[0].loopStart = 1;
        song.tracks[0].clips[0].loopLength = 2;
        clipEditing::split(song, song.tracks[0].clips[0].id, 15);
        expect(song.tracks[0].clips.size() == 2 && song.tracks[0].clips[1].sourceOffset == 6 &&
                   song.tracks[0].clips[1].loopLength == 2,
               "Split reset the loop source");
        song.tracks[0].role.id = "timecode";
        clipEditing::split(song, {}, 12);
        expect(song.tracks[0].clips.size() == 2, "Split modified generated timecode");
    });
    test("Piano roll and MIDI playback preserve held notes across tempo changes", [&] {
        auto p = projectFixture();
        auto &song = p.songs[0];
        song.parts.clear(); song.duration = 12; song.bpm = 120;
        song.timeSettings.emplace(); song.timeSettings->timebase = jaras::ProjectTimebase::relative;
        auto &track = song.tracks[0]; auto &clip = track.clips[0];
        clip.audioFile.reset(); clip.startTime = 0; clip.duration = 6; clip.sourceOffset = .5;
        clip.gain = 1; clip.fadeIn.reset(); clip.fadeOut.reset(); clip.midi.emplace();
        clip.midi->sourceBPM = 120;
        clip.midi->notes = {{uuid(),1,12,60,100,1},{uuid(),13,2,64,90,2}};
        auto marker = [&](double time, double bpm, const char *mode) {
            jaras::TimelineMarker m{uuid(),"Tempo",time,0x999999};
            m.tempoBPM=bpm; m.tempoReferenceBPM=120; m.tempoTimebase=mode; return m;
        };
        song.markers = std::vector<jaras::TimelineMarker>{marker(0,120,"relative"),
            marker(2,240,"relative"),marker(4,60,"free")};
        const ClipTempo timing(clip,&song);
        expect(timing.itemTitle(clip)==String::fromUTF8("[1–2] ")+text(clip.name),
               "Item header must display the actual tempo-rate range used by playback");
        auto rendered=clip;rendered.renderedTiming=true;rendered.playbackRate=1;rendered.tempoBasePlaybackRate=2;
        expect(ClipTempo(rendered,&song).itemTitle(rendered)==text(clip.name),
               "Rendered unity-rate item retained a speed label");
        auto altered=clip;altered.playbackRate=1.25;altered.tempoBasePlaybackRate=1;
        expect(ClipTempo(altered).itemTitle(altered)=="[1.25] "+text(clip.name),
               "Item header omitted its changed source rate");
        expect(timing.spans.size()==3 && timing.sourceAt(2)==2.5 && timing.sourceAt(4)==6.5 &&
               timing.sourceAt(6)==8.5, "Tempo change discarded source samples");
        for(double time : {0.,1.,2.,3.,4.,5.,6.})
            expect(std::abs(timing.timeAt(timing.sourceAt(time))-time)<1e-9,
                   "Piano-roll ruler and playback cursor disagree");
        const auto notes = playbackNotes(track,&song);
        expect(notes.size()==2 && notes[0].start==0 && notes[0].end==4 &&
               notes[1].start==4 && notes[1].end==5,
               "Held MIDI note retriggered or ended at the wrong tempo");
        auto next=*clip.midi; next.notes[1].length=8;
        midiEditing::replace(p,clip.id,next);
        expect(clip.duration==8, "Piano-roll extension ignored later free-time section");
        song.parts={{uuid(),"Previous",0,3},{uuid(),"Next",3,10}};
        clip.regionOwnerID=song.parts[0].id;
        song.markers=std::vector<jaras::TimelineMarker>{marker(0,120,"relative"),marker(3,240,"relative")};
        (*song.markers)[0].regionOwnerID=song.parts[0].id;
        (*song.markers)[1].regionOwnerID=song.parts[1].id;
        const ClipTempo owned(clip,&song);
        expect(owned.sourceAt(6)==6.5, "Previous-song MIDI tail inherited the next song tempo");
        clip.regionOwnerID.reset(); song.regionOwnershipInitialized=true;
        const ClipTempo unowned(clip,&song);
        expect(unowned.sourceAt(6)==9.5, "Explicitly unowned MIDI did not use global tempo");
    });
    test("Teleprompter links choose unicast LAN addresses instead of multicast memberships", [&] {
        Array<IPAddress> addresses{IPAddress("224.0.0.1"),IPAddress("127.0.0.1"),
            IPAddress("169.254.171.135"),IPAddress("10.0.0.102"),IPAddress("239.255.255.250")};
        expect(TeleprompterHTTP::localAddress(addresses)=="10.0.0.102", "TP QR code selected multicast or link-local over LAN");
        addresses={IPAddress("224.0.0.1"),IPAddress("169.254.171.135")};
        expect(TeleprompterHTTP::localAddress(addresses)=="169.254.171.135", "Direct Ethernet TP link unavailable");
    });
    test("Mac normalization calibration, source loops, cancellation and true peak", [&] {
        using namespace normalization;
        for (int rate : {44100, 48000}) {
            auto file = directory.getChildFile("normalization-" + String(rate) + ".wav");
            auto writeTone = [&](bool intersample) {
                auto stream = file.createOutputStream();
                expect(stream != nullptr, "Cannot create level fixture");
                stream->setPosition(0);
                stream->truncate();
                WavAudioFormat wav;
                std::unique_ptr<AudioFormatWriter> writer(
                    wav.createWriterFor(stream.get(), rate, 1, 24, {}, 0));
                expect(writer != nullptr, "Cannot create WAV writer");
                stream.release();
                AudioBuffer<float> tone(1, rate * 3);
                for (int i = 0; i < tone.getNumSamples(); ++i)
                    tone.setSample(
                        0, i,
                        .5f * (float)std::sin(intersample
                                                  ? i * MathConstants<double>::halfPi +
                                                        MathConstants<double>::pi / 4
                                                  : i * MathConstants<double>::twoPi * 997 / rate));
                expect(writer->writeFromAudioSampleBuffer(tone, 0, tone.getNumSamples()),
                       "Cannot write level fixture");
            };
            writeTone(false);
            jaras::AudioClip clip;
            clip.id = uuid();
            clip.name = "Tone";
            clip.duration = 3;
            clip.audioFile = jaras::AudioFile{utf8(file.getFileName()), {}};
            const auto sample = measure(clip, directory, peak),
                       average = measure(clip, directory, rms);
            const auto loudness = measure(clip, directory, lufs),
                       maximum = measure(clip, directory, truePeak);
            expect(std::abs(sample + 6.0206) < .01 && std::abs(average + 9.0309) < .01 &&
                       std::abs(loudness + 9.0309) < .15,
                   "Peak/RMS/LUFS calibration differs from Mac");
            expect(maximum >= sample - .01 && maximum < sample + .3,
                   "True peak calibration incorrect");
            clip.loopStart = .5;
            clip.loopLength = .5;
            clip.sourceOffset = 2.25;
            clip.duration = 2;
            clip.playbackRate = 2;
            expect(std::abs(measure(clip, directory, peak) - sample) < .01,
                   "Looped source interval was not measured");
            bool stopped = false;
            try {
                measure(clip, directory, peak, [] { return true; });
            } catch (...) {
                stopped = true;
            }
            expect(stopped, "Cancelled analysis did not stop");
            clip.loopStart.reset();
            clip.loopLength.reset();
            clip.sourceOffset = 0;
            clip.duration = .05;
            clip.playbackRate = 1;
            expect(std::isfinite(measure(clip, directory, lufs)), "Short LUFS integration failed");
            clip.duration = 1;
            writeTone(true);
            expect(measure(clip, directory, truePeak) > measure(clip, directory, peak) + 2.5,
                   "True peak did not detect intersample peaks");
        }
        expect(std::abs(gain(-80, 12) - std::pow(10., 24. / 20)) < 1e-9 && gain(-200, -1) == 1,
               "Normalization gain limit or silence handling changed");
    });
    test("Large timeline streams first and last files, independent heads and loop seeks with a bounded cache", [&] {
        const auto media = directory.getChildFile("large-streams"); media.createDirectory();
        const auto source = media.getChildFile("source.wav");
        {
            WavAudioFormat wav;
            auto stream = std::make_unique<FileOutputStream>(source);
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
            expect(writer != nullptr, "Cannot write streaming fixture"); stream.release();
            AudioBuffer<float> pcm(2, 48000);
            for (int c = 0; c < 2; ++c) FloatVectorOperations::fill(pcm.getWritePointer(c), .1f, 48000);
            expect(writer->writeFromAudioSampleBuffer(pcm, 0, 48000), "Cannot write fixture PCM");
        }
        jaras::Song song; song.id = uuid(); song.duration = 1500; song.bpm = 120;
        jaras::Track track; track.id = uuid(); track.role.id = "other";
        for (int i = 0; i < 300; ++i) {
            const auto name = String(i) + ".wav";
            expect(source.copyFileTo(media.getChildFile(name)), "Cannot copy fixture");
            jaras::AudioClip clip; clip.id = uuid(); clip.startTime = i * 5.; clip.duration = 1;
            clip.audioFile = jaras::AudioFile{utf8(name), {}};
            if (i == 299) { clip.duration = 4; clip.loopStart = 0; clip.loopLength = 1; }
            track.clips.push_back(clip);
        }
        song.tracks = {track};
        AudioEngine audio; audio.prepareOffline(48000); audio.prepareSong(song, media);
        expect(audio.missingFiles.isEmpty() && audio.residentStreams() == 0, "Idle timeline eagerly opened stream buffers");
        AudioBuffer<float> output(2, 512);
        auto verify = [&](double position, bool secondary, float expected) {
            AudioEngine::State state; state.playing = true; state.position = position;
            state.subPlaying = secondary; state.subPosition = .25;
            audio.transport(state);
            const auto before = audio.getUnderruns();
            audio.render(output.getArrayOfWritePointers(), 2, 512);
            expect(audio.getUnderruns() == before, "First block after seek was not ready at " + String(position,6));
            for (int c = 0; c < 2; ++c) for (int n = 0; n < 512; ++n)
                expect(std::abs(output.getSample(c, n) - expected) < .001f, "Large project lost or doubled PCM");
        };
        verify(.25, false, .1f);
        verify(32760. / 48000., false, .1f); // First block crosses a decoder cache boundary.
        auto changed=track.clips[0];changed.gain=.5;audio.setItemControls(changed);verify(.25,false,.05f);
        changed.phaseInverted=true;audio.setItemControls(changed);verify(.25,false,-.05f);
        changed.muted=true;audio.setItemControls(changed);verify(.25,false,0);
        changed.muted=false;changed.phaseInverted=false;changed.gain=1;audio.setItemControls(changed);verify(.25,false,.1f);
        verify(1495.25, true, .2f);
        verify(1497.99, false, .1f);
        expect(audio.residentStreams() <= 4, "Cache grew with total project files");
        const auto idleStart = Time::getMillisecondCounter();
        // A pinned onset may play before the activation worker has published
        // any forward reader. Zero resident streams is not yet an idle state.
        while ((Time::getMillisecondCounter()-idleStart < 2100 || audio.residentStreams() > 0) &&
               Time::getMillisecondCounter()-idleStart < 5000) Thread::sleep(20);
        expect(audio.residentStreams() == 0, "Unused readers were not retired");
        audio.setOffline(true);
        verify(1498.1, true, .2f);
        expect(audio.residentStreams() <= 2, "Export reopened unrelated timeline files");
    });
    test("Interactive transport keeps idle starts warm, cancels pending Play, and primes queued jumps and loops", [&] {
        const auto media=directory.getChildFile("async-transport");media.createDirectory();
        jaras::Song song;song.id=uuid();song.duration=32;song.bpm=120;
        for(int index=0;index<2;++index) {
            const int sampleRate=index?44100:48000;
            const auto name=String(index)+".wav";
            WavAudioFormat wav;auto stream=media.getChildFile(name).createOutputStream();
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),sampleRate,2,24,{},0));
            expect(writer!=nullptr,"Cannot create async transport fixture");stream.release();
            AudioBuffer<float> pcm(2,sampleRate*12);
            for(int c=0;c<2;++c)for(int n=0;n<pcm.getNumSamples();++n)
                pcm.setSample(c,n,float(.1+index*.1+double(n)/sampleRate*.001));
            expect(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Cannot write async fixture");writer.reset();
            jaras::Track track;track.id=uuid();track.role.id="other";
            jaras::AudioClip clip;clip.id=uuid();clip.duration=12;clip.audioFile=jaras::AudioFile{utf8(name),{}};
            track.clips.push_back(clip);clip.id=uuid();clip.startTime=20;clip.duration=10;clip.sourceOffset=2;
            track.clips.push_back(clip);song.tracks.push_back(track);
        }
        AudioEngine audio;audio.prepareOffline(48000);audio.prepareSong(song,media);
        AudioBuffer<float> output(2,256);
        const auto render=[&] {audio.render(output.getArrayOfWritePointers(),2,256);};
        const auto ready=[&] {
            for(int i=0;i<200 && audio.preparingTransport();++i)floatingControlTests::pump();
            expect(!audio.preparingTransport(),"Async transport did not finish preparation");
        };
        const auto check=[&](double value) {
            const auto before=audio.getUnderruns();render();
            expect(audio.getUnderruns()==before,"Prepared transition missed an audio block");
            expect(std::abs(output.getSample(0,64)-value)<.001,"Tracks did not start together at the requested source position");
        };
        AudioEngine::State state;state.playing=true;state.position=5.25;
        const auto begin=Time::getMillisecondCounterHiRes();audio.transportAsync(state);
        expect(Time::getMillisecondCounterHiRes()-begin<250,"Play blocked the message thread for disk preparation");
        ready();check(.3105);
        // Queue/selection edits carry the UI's previous sample, but must never
        // seek the running readers or hold the transport waiting for decoding.
        for(int i=0;i<10;++i)render();
        const auto beforeRouting=audio.state().position;
        audio.updateTransportRouting(state);
        expect(!audio.preparingTransport(),"Arming a queue re-prepared the running sources");
        render();
        expect(audio.state().position>beforeRouting,"Routing update rewound the active source clock");
        state.playing=false;state.position=0;audio.transportAsync(state);render();
        for(int i=0;i<180;++i)floatingControlTests::pump(); // Beyond the old two-second eviction.
        state.playing=true;audio.transportAsync(state);
        expect(!audio.preparingTransport(),"Selected start became cold while idle");check(.3);
        auto destination=state;destination.position=20;
        audio.prewarmTransportDestination(destination);
        for(int i=0;i<20;++i)floatingControlTests::pump();
        // The core observes boundaries between callbacks, not necessarily at
        // their exact first sample. The prepared onset must cover this offset.
        destination.position+=.037;
        audio.transportAsync(destination);
        expect(!audio.preparingTransport(),"Queued onset was decoded again for a small boundary overshoot");
        expect(audio.transportClockPending(),"Seek clock became active before the callback applied it");
        check(.304074);
        expect(!audio.transportClockPending(),"Callback did not acknowledge the prepared seek");
        for(int i=0;i<12;++i) {
            const auto at=audio.state().position;
            floatingControlTests::pump();render();
            expect(std::abs(audio.state().position-(at+256./48000.))<1e-7,
                   "Queued jump replayed its onset after preparation finished");
        }
        state.position=7;audio.transportAsync(state);
        state.position=0;state.playing=false;audio.transportAsync(state);render();
        for(int i=0;i<30;++i)floatingControlTests::pump();
        render();expect(!audio.state().playing && output.getMagnitude(0,256)<.0001,"Cancelled Play restarted after Stop");
        audio.prewarmTransportDestination({});
        state.playing=true;state.position=.99;state.loop=true;state.loopStart=0;state.loopEnd=1;
        audio.transportAsync(state);ready();
        const auto before=audio.getUnderruns();
        for(int i=0;i<6;++i)render();
        expect(audio.getUnderruns()==before && audio.state().position<.1,"Loop transition lost its prepared start");
    });
    test("Cold MP3 Play in the middle starts every stem together and reuses exact seeking history", [&] {
        const auto source=directory.getChildFile("click-123.mp3");
        expect(source.existsAsFile(),"Missing compressed test fixture");
        const auto media=directory.getChildFile("cold-middle-play");media.createDirectory();
        jaras::Song song;song.id=uuid();song.duration=48;song.bpm=123;
        for(int index=0;index<8;++index) {
            const auto name=String(index)+".mp3";
            expect(source.copyFileTo(media.getChildFile(name)),"Cannot copy compressed stem fixture");
            jaras::Track track;track.id=uuid();track.role.id="other";
            jaras::AudioClip clip;clip.id=uuid();clip.duration=48;clip.gain=.05;
            clip.audioFile=jaras::AudioFile{utf8(name),{}};
            track.clips={clip};song.tracks.push_back(track);
        }
        AudioFormatManager formats;registerAudioFormats(formats);
        std::unique_ptr<AudioFormatReader> reference(formats.createReaderFor(source));
        expect(reference!=nullptr,"Cannot decode reference MP3");
        AudioEngine audio;audio.prepareOffline(44100);audio.prepareSong(song,media);
        AudioBuffer<float> output(2,256),expected(2,256);Array<var> measurements;
        for(double at:{33.25,4.375,40.125,33.25}) {
            AudioEngine::State state;state.position=at;audio.transportAsync(state);
            audio.render(output.getArrayOfWritePointers(),2,256);
            state.playing=true;const auto started=Time::getMillisecondCounterHiRes();audio.transportAsync(state);
            while(audio.preparingTransport() && Time::getMillisecondCounterHiRes()-started<5000)
                floatingControlTests::pump();
            expect(!audio.preparingTransport(),"Middle Play never finished preparation");
            const auto elapsed=Time::getMillisecondCounterHiRes()-started;
            auto measurement=object();put(measurement,"position",at);put(measurement,"milliseconds",elapsed);measurements.add(measurement);
            expect(reference->read(&expected,0,256,(int64)std::llround(at*44100),true,true),"Reference MP3 read failed");
            const auto misses=audio.getUnderruns();audio.render(output.getArrayOfWritePointers(),2,256);
            expect(audio.getUnderruns()==misses,"Middle Play began before every stem was ready");
            for(int channel=0;channel<2;++channel)for(int n=0;n<256;++n)
                expect(std::abs(output.getSample(channel,n)-expected.getSample(channel,n)*.4f)<.00002f,
                       "Middle Play changed source position or stem synchronization");
            expect(std::abs(audio.state().position-at-256./44100.)<1e-7,"Middle Play did not advance on its first callback");
        }
        directory.getChildFile("cold-middle-play.json").replaceWithText(JSON::toString(var(measurements)));
    });
    test("Queueing a song and moving its idle secondary cursor never repositions the running head", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        auto project=projectFixture();auto &song=project.songs[0];song.tracks.clear();
        const auto first=song.parts[0].id,second=song.parts[1].id;
        session.restoreSnapshot(ProjectCodec::encode(project));
        session.command(jaras::CommandKind::selectRegion,first);
        session.command(jaras::CommandKind::play);
        AudioBuffer<float> output(2,256);
        session.audio.render(output.getArrayOfWritePointers(),2,256);
        session.projectSyncFrame();
        const auto updates=(int64)session.audio.streamDiagnostics()["transportRepositions"];
        const auto position=session.audio.state().position;
        session.command(jaras::CommandKind::queueRegion,second);
        expect(session.transport().queuedRegionId==second,"Song did not enter the queue");
        expect((int64)session.audio.streamDiagnostics()["transportRepositions"]==updates,
               "Queue selection re-prepared/repositioned the main transport");
        session.audio.render(output.getArrayOfWritePointers(),2,256);
        expect(std::abs(session.audio.state().position-position-256./48000.)<1e-7,
               "Queue selection repeated or skipped main-head samples");
        session.projectSyncFrame();
        session.command(jaras::CommandKind::subSeek,{},23.5);
        expect((int64)session.audio.streamDiagnostics()["transportRepositions"]==updates,
               "Moving an idle Sub Play cursor restarted the main transport");
        expect(std::abs(session.presentationTransport().subPlay.position-23.5)<1e-9,
               "Idle secondary cursor did not follow its selected position");
    });
    test("Session clock waits for the audio seek commit and follows callback loops without replay", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.core.execute({jaras::CommandKind::loopStart,{},0});
        session.core.execute({jaras::CommandKind::loopEnd,{},.1});
        session.core.execute({jaras::CommandKind::toggleLoop});
        session.core.execute({jaras::CommandKind::seek,{},.095});
        session.core.execute({jaras::CommandKind::play});
        AudioEngine::State state;state.position=.095;state.playing=true;
        state.loop=true;state.loopStart=0;state.loopEnd=.1;
        session.audio.transportAsync(state);
        expect(session.audio.transportClockPending(),"Prepared seek needs device acknowledgement");
        session.projectSyncFrame();
        expect(std::abs(session.transport().position-.095)<1e-9,"Core consumed old audio time before seek commit");
        AudioBuffer<float> output(2,256);
        for(int i=0;i<100;++i) {
            session.audio.render(output.getArrayOfWritePointers(),2,256);
            session.projectSyncFrame();
            const double expected=std::fmod(.095+(i+1)*256./48000.,.1);
            expect(std::abs(session.audio.state().position-expected)<1e-7,"Audio repeated a loop onset");
            expect(std::abs(session.transport().position-expected)<1e-7,"Core drifted from the callback loop clock");
            expect(!session.audio.transportClockPending(),"An already executed loop scheduled another seek");
        }
    });
    auto report = object();
    Array<var> names;
    for (auto &name : passed)
        names.add(name);
    put(report, "passed", names);
    Array<var> skippedNames;
    for (const auto &name : skipped)
        skippedNames.add(name);
    put(report, "skipped", skippedNames);
    put(report, "failed", failed);
    put(report, "success", failed.isEmpty());
    directory.getChildFile("results.json").replaceWithText(JSON::toString(report));
    return failed.isEmpty() ? 0 : 1;
}
} // namespace catlive
