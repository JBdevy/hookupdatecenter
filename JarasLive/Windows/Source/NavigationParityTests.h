#pragma once
#include "FloatingControlTests.h"
#include "EffectInsertPanel.h"
#include "TimelinePlaybackFollow.h"

namespace catlive::navigationParityTests {
using floatingControlTests::require;
using floatingControlTests::pump;

template <typename Test> void registerTests(const File &directory, Test &test) {
    test("UTF8 interface literals preserve accents and punctuation before translation", [] {
        const ScopedValueSetter<bool> language(localization::english, false);
        const auto pt = JSON::parse(String::fromUTF8(BinaryData::Portuguese_json, BinaryData::Portuguese_jsonSize));
        const auto en = JSON::parse(String::fromUTF8(BinaryData::English_json, BinaryData::English_jsonSize));
        for (bool english : {false, true}) {
            localization::english = english;
            require(localization::translate("Salvando…") == String::fromUTF8(english ? "Saving…" : "Salvando…"),
                    "Saving label contains broken ellipsis or failed to translate");
            require(localization::translate("Ação inédita: São João — 🎹") == String::fromUTF8("Ação inédita: São João — 🎹"),
                    "Uncatalogued UTF8 text was corrupted");
            for (const auto &catalog : {pt, en}) {
                require(catalog.getDynamicObject() != nullptr, "Missing translation catalog");
                for (const auto &entry : catalog.getDynamicObject()->getProperties()) {
                    for (const auto &value : {entry.name.toString(), entry.value.toString()})
                        require(localization::translate(value.toRawUTF8()) == localization::translate(value),
                                "Narrow UTF8 catalog text differs from decoded Unicode");
                }
            }
        }
    });
    test("REC can run with no armed tracks and missing media or effects remain nonblocking", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        session.audio.missingFiles.add("missing.wav"); session.audio.unsupported.add("Missing effect media");
        session.toggleRecording();
        require(session.audio.isRecording() && session.transport().playing,"REC was blocked by empty arming or missing assets");
        AudioBuffer<float> output(2,480);
        const auto start=session.audio.state().position;
        for(int i=0;i<4;++i) session.audio.render(output.getArrayOfWritePointers(),2,480);
        require(session.audio.state().position>start,"REC without armed tracks did not advance transport");
        session.toggleRecording(); pump();
        require(!session.audio.isRecording(),"Empty recording did not stop");
        require(session.audio.missingFiles.size()==1 && session.audio.unsupported.size()==1,"Recording discarded missing asset diagnostics");
    });
    test("Interface translations switch both ways without translating user-defined Parts names", [] {
        const bool original=localization::english;
        struct Restore { bool value; ~Restore(){localization::english=value;} } restore{original};
        for(bool english:{true,false,true}) {
            localization::english=english;
            require(localization::translate("Cancel")== (english?"Cancel":"Cancelar"),"Cancel uses the wrong language");
            require(localization::translate("Playing / Selected")== (english?"Playing / Selected":"Tocando / Selecionada"),"Parts heading uses the wrong language");
            require(localization::translate("Undock mixer")== (english?"Undock mixer":"Desindexar"),"Undock label differs from Mac");
            require(localization::translate("My marker 42")=="My marker 42","User label was translated");
        }
    });

    test("Escape cancels section, loop and song queue on separate presses without seeking audio", [&] {
        auto project = floatingControlTests::fixture();
        auto &song = project.songs.front();
        jaras::TimelineMarker next{uuid(), "Next", 4, 0x51ef93}; next.section = true;
        jaras::TimelineMarker queued{uuid(), "Queued", 8, 0x51ef93}; queued.section = true;
        song.markers = std::vector<jaras::TimelineMarker>{queued, next};
        project.regionSetlist.emplace(); project.regionSetlist->autoAdvance = true;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session, auth, lighting, false, directory.getNonexistentChildFile("escape-priority", ".json"));
        workspace.setSize(1366, 768);
        session.command(jaras::CommandKind::editSeek, {}, 2);
        session.selectTimeRange(2, 6);
        session.command(jaras::CommandKind::toggleLoop);
        session.command(jaras::CommandKind::play);
        require(session.transport().queuedRegionId == song.parts.back().id &&
                session.project().regionSetlist->autoAdvance, "Auto did not prepare the fixture song queue");
        session.command(jaras::CommandKind::queueSection, queued.id);
        const auto playback = session.transport().position;
        const auto press = [&] { require(workspace.keyPressed(KeyPress(KeyPress::escapeKey)), "Escape was not handled"); };
        const auto release = [&] { workspace.keyStateChanged(false); };
        press();
        require(!session.transport().queuedSectionMarkerId && session.transport().editPosition == 4 &&
                session.transport().loop.enabled && session.transport().queuedRegionId == song.parts.back().id &&
                session.project().regionSetlist->autoAdvance,
                "First Escape failed to cancel only the section and preview the nearest right section");
        press();
        require(session.transport().loop.enabled, "Held Escape cancelled another priority");
        release(); press();
        require(!session.transport().loop.enabled && session.transport().queuedRegionId &&
                session.project().regionSetlist->autoAdvance, "Second press changed queue or Auto while cancelling loop");
        require(!session.selectedTimeRange(), "Cancelling Repeat retained its selected area unlike Mac");
        release(); press();
        require(!session.transport().queuedRegionId && !session.project().regionSetlist->autoAdvance &&
                !session.selectedTimeRange(), "Third press did not exclusively cancel queue and Auto");
        require(session.transport().playing && session.transport().position == playback,
                "Cancellation moved or stopped playback");
        session.selectTimeRange(2,6);
        press(); require(session.selectedTimeRange().has_value(), "Held Escape also removed the time selection");
        release(); press(); require(!session.selectedTimeRange(), "Next press failed to clear the remaining time selection");
        release();
        session.command(jaras::CommandKind::stopAll);
        session.selectTimeRange(2, 6);
        auto automatic = *session.project().regionSetlist; automatic.autoAdvance = true;
        session.core.configureRegionSetlist(automatic);
        require(!session.transport().queuedRegionId && !session.transport().queue.songId,
                "Auto-only cancellation fixture unexpectedly contains a song queue");
        press();
        require(!session.project().regionSetlist->autoAdvance && session.selectedTimeRange(),
                "Cancelling Auto without a queued song also cleared the time selection");
        release();
        session.command(jaras::CommandKind::editSeek, {}, 20);
        session.command(jaras::CommandKind::play);
        session.command(jaras::CommandKind::queueSection, song.parts.back().id);
        const auto tailPlayback = session.transport().position;
        press();
        require(!session.transport().queuedSectionMarkerId && session.transport().editPosition == 30 &&
                session.transport().playing && session.transport().position == tailPlayback,
                "Cancelling with no next section did not move only the editing needle to the song end");
        release(); session.command(jaras::CommandKind::stopAll);
    });

    test("Play and Subplay keep available audio audible when another media file is missing", [&] {
        const auto folder = directory.getNonexistentChildFile("missing-media-playback", "");
        require(folder.createDirectory().wasOk(), "Cannot create playback fixture directory");
        WavAudioFormat format;
        auto stream = folder.getChildFile("available.wav").createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
        require(bool(writer), "Cannot create available WAV fixture");
        stream.release();
        AudioBuffer<float> tone(2, 48000 * 4);
        for (int sample = 0; sample < tone.getNumSamples(); ++sample)
            for (int channel = 0; channel < 2; ++channel)
                tone.setSample(channel, sample, .2f * std::sin(float(sample) * 2 * MathConstants<float>::pi * 440 / 48000));
        require(writer->writeFromAudioSampleBuffer(tone, 0, tone.getNumSamples()), "Cannot write available WAV fixture");
        writer.reset();

        auto project = floatingControlTests::fixture();
        project.songs[0].tracks.resize(2);
        for (int index = 0; index < 2; ++index) {
            jaras::AudioClip clip;
            clip.id = uuid(); clip.duration = 4;
            clip.audioFile = jaras::AudioFile{index == 0 ? "available.wav" : "missing.wav", {}};
            project.songs[0].tracks[index].clips = {clip};
        }
        Session session;
        session.inspection = true;
        session.mediaDirectory = folder;
        session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));
        session.audio.setOffline(true);
        require(session.audio.missingFiles.size() == 1 && session.audio.unsupported.isEmpty(),
                "Fixture must contain exactly one missing media file and usable processing");
        session.command(jaras::CommandKind::play);
        require(session.transport().playing, "Missing media blocked Play");
        AudioBuffer<float> output(2, 512);
        auto requireAudible = [&] {
            float magnitude = 0;
            for (int block = 0; block < 4; ++block) {
                session.audio.render(output.getArrayOfWritePointers(), 2, output.getNumSamples());
                magnitude = std::max(magnitude, output.getMagnitude(0, output.getNumSamples()));
            }
            require(magnitude > .01f, "Missing media silenced the available audio track");
        };
        requireAudible();
        session.command(jaras::CommandKind::subSeek, {}, .5);
        session.command(jaras::CommandKind::subPlay);
        require(session.transport().playing && session.transport().subPlay.playing,
                "Missing media blocked Subplay or stopped main playback");
        requireAudible();
        session.command(jaras::CommandKind::subStop);
        require(session.transport().playing && !session.transport().subPlay.playing,
                "Stopping Subplay stopped the available main track");
        requireAudible();
        session.command(jaras::CommandKind::stopAll);
        require(!session.transport().playing && !session.transport().subPlay.playing,
                "Missing-media playback did not stop normally");
        require(session.audio.missingFiles.size() == 1, "Playing hid the missing-media diagnostic");
    });

    test("Timeline zoom follows the active needle and remains centered within both document edges", [] {
        jaras::TransportState state;
        state.editPosition = 24; state.position = 60; state.subPlay.position = 90;
        auto centered = [&](double expected) {
            const auto position = timelineZoomPosition(state);
            require(position == expected, "Zoom selected the wrong transport needle");
            for (const auto scale : {25., 50., 100.}) {
                const auto offset = timelineCenteredZoomOffset(position, scale, 20000, 800);
                require(std::abs(position * scale - offset - 400) < .000001,
                        "Zoom did not keep its active needle at the viewport center");
            }
        };
        centered(24);
        state.playing = true; centered(60);
        state.subPlay.playing = true; centered(90);
        state.playing = false; centered(90);
        state.subPlay.playing = false; centered(24);
        require(timelineCenteredZoomOffset(1, 100, 20000, 800) == 0,
                "Zoom near the beginning scrolled before the document");
        require(timelineCenteredZoomOffset(199, 100, 20000, 800) == 19200,
                "Zoom near the end scrolled beyond the document");
        require(timelineCenteredZoomOffset(2, 100, 400, 800) == 0,
                "Zoom created a scroll offset for content narrower than its viewport");
    });

    test("Zoom from a far-out view moves scale and cursor focus together instead of panning at the old scale", [] {
        constexpr double position=800,viewport=1000,initialScale=1,origin=0,finalScale=1.3;
        const double anchor=position*initialScale-origin;
        double previousScale=initialScale,previousOffset=origin;
        for(int step=0;step<=100;++step) {
            const double progress=step/100.,eased=1-std::pow(1-progress,3.);
            const double scale=std::exp(std::log(initialScale)+(std::log(finalScale)-std::log(initialScale))*eased);
            const double focus=anchor+(viewport/2-anchor)*eased;
            const double offset=timelineAnchoredZoomOffset(position,scale,2000*scale,viewport,focus);
            require(std::abs(position*scale-offset-focus)<.000001,"Cursor focus detached from the zoom transform");
            if(step==0)require(offset==origin,"First wheel frame panned before increasing the zoom");
            require(scale>=previousScale && offset>=previousOffset,"Zoom reversed toward the project beginning");
            previousScale=scale;previousOffset=offset;
        }
        require(std::abs(position*finalScale-previousOffset-viewport/2)<.000001,"Zoom did not finish centered on its cursor");
    });

    test("Master FX chooser keeps audio effects but hides instruments and CatStem, including external instruments", [&] {
        auto &catalog = VST3Catalog::shared();
        struct RestoreCatalog {
            VST3Catalog &catalog; Array<var> plugins;
            ~RestoreCatalog() { catalog.plugins = plugins; ++catalog.revision; }
        } restore{catalog, catalog.plugins};
        auto instrument = object(), effect = object();
        put(instrument, "name", "Instrument first"); put(instrument, "classID", "instrument-fixture");
        put(instrument, "category", "Instrument|Sampler"); put(instrument, "vendor", "Instrument company");
        put(effect, "name", "Audio effect"); put(effect, "classID", "effect-fixture");
        put(effect, "category", "Fx|Dynamics"); put(effect, "vendor", "Effect company");
        catalog.plugins = {instrument, effect}; ++catalog.revision;
        int inserted = 0, dismissed = 0;
        EffectInsertPanel panel(directory, [&](String kind, String data) {
            require(kind == "External" && str(JSON::parse(data), "classID") == "effect-fixture",
                    "Master catalog offered an external instrument before the audio effect");
            ++inserted; return true;
        }, [&] { ++dismissed; }, false, false);
        DocumentWindow owner("Master insertion regression", theme::panel, DocumentWindow::closeButton);
        owner.setContentNonOwned(&panel, true); owner.setContentComponentSize(460, 214); owner.setVisible(true);
        auto *kind = dynamic_cast<ComboBox *>(uiFeatureTests::find(panel, "effectKind"));
        require(kind, "Master effect selector is missing");
        const auto containsKind = [&](int id) {
            for (int index = 0; index < kind->getNumItems(); ++index)
                if (kind->getItemId(index) == id) return true;
            return false;
        };
        require(!containsKind(7) && !containsKind(9),
                "Master chooser exposes instruments or CatStem");
        require(containsKind(1) && containsKind(6) && containsKind(8),
                "Master filtering removed audio effects");
        kind->setSelectedId(8, sendNotificationSync); pump();
        Component *browser = nullptr;
        for (int index = 0; index < Desktop::getInstance().getNumComponents(); ++index) {
            auto *candidate = Desktop::getInstance().getComponent(index);
            if (candidate->getComponentID() == "externalPluginBrowserWindow" && candidate->isVisible()) browser = candidate;
        }
        require(browser, "Master external catalog did not open");
        auto *list = dynamic_cast<ListBox *>(uiFeatureTests::find(*browser, "externalPluginList"));
        require(list && list->getModel()->getNumRows() == 1, "Master catalog lost its allowed audio effect");
        const Point<float> at{20, 20};
        list->getModel()->listBoxItemClicked(0, MouseEvent(Desktop::getInstance().getMainMouseSource(), at,
            ModifierKeys(ModifierKeys::leftButtonModifier), 1, 0, 0, 0, 0, list, list,
            Time::getCurrentTime(), at, Time::getCurrentTime(), 1, false));
        require(inserted == 1 && dismissed == 1 && !browser->isVisible(),
                "Master audio effect did not insert directly from its catalog");
    });
}
} // namespace catlive::navigationParityTests
