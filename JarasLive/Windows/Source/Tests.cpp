#include "Workspace.h"
#include "StartupSplash.h"
#include "TrackTree.h"
#include "ClipAudio.h"
#include "ResolumeComposition.h"
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
#include "WaveformCache.h"
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
    auto test = [&](const String &name, const std::function<void()> &work) {
        try {
            work();
            passed.add(name);
        } catch (const std::exception &e) {
            failed += name + ": " + String::fromUTF8(e.what()) + "\n";
        }
    };
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
    test("Interface scale defaults to 90 percent and persists separately from projects", [&] {
        auto file = directory.getNonexistentChildFile("interface-scale", ".json");
        Appearance preferences(file);
        expect(std::abs(preferences.interfaceScale() - .9f) < 1e-6, "Compact default");
        expect(preferences.set("jaras.interface.scale", 1.25).wasOk(), "Scale saved");
        expect(std::abs(Appearance(file).interfaceScale() - 1.25f) < 1e-6, "Scale restored");
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
        expect(data != nullptr && data->channels.size() == 2, "Source produces two cached channels without embedded waveform");
        expect(data->range(0, .2, .3).second < .11f && data->range(0, 1.2, 1.3).second > .69f, "Real source amplitude retained");
        expect(data->range(1, .2, .3).second > .29f && data->range(1, 1.2, 1.3).second < .06f, "Stereo channels remain independent");
        expect(data->range(0, 3, 4).second == 0, "No fabricated waveform beyond the source");
        jaras::AudioClip clip; clip.sourceOffset = .5; clip.playbackRate = 2;
        expect(std::abs(WaveformCache::sourcePosition(clip, .3) - 1.1) < 1e-8, "Offset and playback rate map source time");
        clip.loopStart = .25; clip.loopLength = .5;
        expect(std::abs(WaveformCache::sourcePosition(clip, .3) - .6) < 1e-8, "Loop maps wrapped source time");
        expect(cache.request(file) == data, "Repeated paint reuses analysis");
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
        Image output(Image::ARGB, 390, 430, true, SoftwareImageType());
        Graphics graphics(output);
        // A transparent native peer may enter paint() with a transparent current brush.
        graphics.setOpacity(0.f);
        splash.paint(graphics);
        int visiblePixels = 0;
        for (int y = 8; y < 338; ++y)
            for (int x = 30; x < 360; ++x)
                if (output.getPixelAt(x, y).getAlpha() > 100)
                    ++visiblePixels;
        expect(visiblePixels > 10000, "Closing panel contains visible logo artwork");
        FileOutputStream stream(directory.getChildFile("closing-logo.png"));
        stream.setPosition(0);
        stream.truncate();
        PNGImageFormat().writeImageToStream(output, stream);
    });
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
        expect(std::abs(regular.getHeightInPoints() - 13.f * .9684564f) < .01f, "Font cap height is calibrated to the Mac reference before display DPI");
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
        expect(JSON::toString(migrated) == JSON::toString(fixture),
               "Migration changed data or lost UUID references");
        const auto model = ProjectCodec::decode(legacy);
        expect(model.id == p.id && model.songs[0].tracks[0].id == p.songs[0].tracks[0].id,
               "Legacy model IDs were not migrated");
        const auto round = ProjectCodec::encode(model, legacy);
        expect(str(get(round, "extension"), "track") == text(p.songs[0].tracks[0].id),
               "Unknown extension reference was lost");
        const auto target = directory.getChildFile("legacy-uuid/Show.jl");
        ProjectCodec::write(target, legacy);
        expect(JSON::toString(ProjectCodec::read(target)) == JSON::toString(fixture),
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
            formats.registerBasicFormats();
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
        trackTree::duplicate(song, folder.id);
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
        formats.registerBasicFormats();
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
        formats.registerBasicFormats();
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
        plan.decks[1] = {1, "One", {{1, "Start"}}};
        plan.decks[2] = {2, "Two", {{1, "Start"}}};
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
    test("Timeline trimming preserves Mac source loops, MIDI notes and track constraints", [&] {
        auto p = projectFixture();
        auto &song = p.songs[0];
        auto &clip = song.tracks[0].clips[0];
        const auto id = clip.id;
        clip.startTime = 20;
        clip.duration = 10;
        clip.playbackRate = 2;
        clip.sourceOffset = 30;
        clipEditing::resize(p, id, 23, 28);
        expect(clip.sourceOffset == 36 && clip.loopStart == 30 && clip.loopLength == 20 &&
                   clip.duration == 5,
               "Audio trim changed the source loop");
        clipEditing::resize(p, id, 17, 31);
        expect(clip.sourceOffset == 44 && clip.loopLength == 20 && clip.duration == 14,
               "Audio extension failed to wrap the original source");
        auto portable = ProjectCodec::decode(ProjectCodec::encode(p, {}));
        expect(portable.songs[0].tracks[0].clips[0].loopLength == 20,
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
        expect(clip.sourceOffset == 0 && clip.midi->notes[0].start == 9,
               "MIDI left extension did not preserve the note's audible position");
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
            expect(audio.getUnderruns() == before, "First block after seek was not ready");
            for (int c = 0; c < 2; ++c) for (int n = 0; n < 512; ++n)
                expect(std::abs(output.getSample(c, n) - expected) < .001f, "Large project lost or doubled PCM");
        };
        verify(.25, false, .1f);
        verify(1495.25, true, .2f);
        verify(1497.99, false, .1f);
        expect(audio.residentStreams() <= 4, "Cache grew with total project files");
        const auto deadline = Time::getMillisecondCounter() + 5000;
        while (audio.residentStreams() > 0 && (int32)(Time::getMillisecondCounter() - deadline) < 0) Thread::sleep(20);
        expect(audio.residentStreams() == 0, "Unused readers were not retired");
        audio.setOffline(true);
        verify(1498.1, true, .2f);
        expect(audio.residentStreams() <= 2, "Export reopened unrelated timeline files");
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
