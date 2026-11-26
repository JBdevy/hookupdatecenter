#pragma once
#include "TransportFadeoutPanel.h"
#include "TransportFadeoutOverlay.h"
#include "EditorSelectionAreas.h"
#include "TrackDeletionConfirmationPanel.h"

namespace catlive {
namespace uiFeatureTests {
inline Component *find(Component &parent, const String &id) {
    if (parent.getComponentID() == id) return &parent;
    for (auto *child : parent.getChildren()) if (auto *found = find(*child, id)) return found;
    return nullptr;
}
inline jaras::Project project(const jaras::Project &base) {
    auto result = base;
    auto &song = result.songs.front();
    song.tracks.clear();
    for (const auto *role : {"other", "group", "generatedClick", "video", "timecode", "chords", "teleprompt", "teleprompt2"}) {
        jaras::Track track;
        track.id = uuid(); track.role.id = role;
        const auto fixedName = jaras::fixedTrackName(track.role);
        track.name = fixedName.empty() ? role : fixedName;
        song.tracks.push_back(std::move(track));
    }
    return result;
}
inline void render(Session &session, int frames) {
    AudioBuffer<float> buffer(2, 1024);
    while (frames > 0) {
        const int count = std::min(frames, buffer.getNumSamples());
        session.audio.render(buffer.getArrayOfWritePointers(), 2, count);
        frames -= count;
    }
}
} // namespace uiFeatureTests

// Components are instantiated without addToDesktop: no test window is opened.
template <typename Register>
void addUIFeatureTests(const File &directory, Register &&test) {
    const auto require = [](bool okay, const char *message) {
        if (!okay) throw std::runtime_error(message);
    };
    test("Track deletion confirms only selected tracks containing items across project songs", [&, require] {
        jaras::Project project; project.songs.emplace_back();
        jaras::Track empty; empty.id=uuid();
        jaras::Track occupied; occupied.id=uuid(); occupied.clips.emplace_back();
        project.songs[0].tracks={empty,occupied};
        require(!tracksContainItems(project,{empty.id}),"An empty selected track must delete immediately");
        require(tracksContainItems(project,{occupied.id}),"A selected track with an item needs confirmation");
        require(tracksContainItems(project,{empty.id,occupied.id}),"Mixed selections must protect their items");
        project.songs.emplace_back(); auto linked=empty; linked.clips.emplace_back(); project.songs[1].tracks={linked};
        require(tracksContainItems(project,{empty.id}),"Shared track IDs must protect items in other songs");
    });
    test("Fadeout preferences keep project-specific tracks and safe defaults", [&, require] {
        const auto file = directory.getChildFile("fadeout-ui-preferences.json");
        require(file.replaceWithText("{}"), "Could not prepare UI preferences");
        Appearance settings(file);
        jaras::Project base; base.id = uuid(); base.songs.emplace_back();
        const auto project = uiFeatureTests::project(base);
        const auto &tracks = project.songs.front().tracks;
        const auto initial = TransportFadeoutPanel::read(settings, project);
        const std::set<ID> expected{tracks[0].id, tracks[1].id, tracks[2].id};
        require(!initial.enabled && initial.duration == 3 && initial.tracks == expected,
                "Fadeout defaults or eligible audio/group/click tracks differ");
        auto projects = object();
        Array<var> selected;
        selected.add(text(tracks[0].id)); selected.add(text(tracks[3].id)); selected.add("deleted-track");
        put(projects, Identifier(text(project.id)), selected);
        auto other = project; other.id = uuid();
        put(projects, Identifier(text(other.id)), Array<var>{});
        require(settings.set("jaras.transportFadeout.projects", projects).wasOk(), "Could not persist project selections");
        require(settings.set("jaras.transportFadeout.enabled", true).wasOk(), "Could not enable Fadeout");
        require(settings.set("jaras.transportFadeout.duration", 9.).wasOk(), "Could not persist duration");
        Appearance reloaded(file);
        const auto restored = TransportFadeoutPanel::read(reloaded, project);
        require(restored.enabled && restored.duration == 5 && restored.tracks == std::set<ID>{tracks[0].id},
                "Preferences failed to reload or retained excluded/deleted tracks");
        require(TransportFadeoutPanel::read(reloaded, other).tracks.empty(), "Explicit empty project selection became all tracks");
        other.id = uuid();
        require(TransportFadeoutPanel::read(reloaded, other).tracks == expected, "Another project's selection leaked into a new project");
        require(settings.set("jaras.transportFadeout.duration", 0.).wasOk() &&
                TransportFadeoutPanel::read(settings, project).duration == 1, "Duration lower limit differs");
        require(settings.set("jaras.transportFadeout.duration", 2.6).wasOk() &&
                TransportFadeoutPanel::read(settings, project).duration == 3, "Duration is not a whole second");
    });
    test("Fadeout panel commits controls immediately and locks them while fading", [&, require] {
        const auto file = directory.getChildFile("fadeout-ui-panel.json");
        require(file.replaceWithText("{}"), "Could not prepare panel preferences");
        Appearance settings(file);
        Session session; session.inspection = true;
        session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(uiFeatureTests::project(session.project())));
        session.audio.setOffline(true);
        ActionBindings bindings(settings, session.audio.devices);
        require(bindings.assign("transportFadeout", "keyboard", "F8"), "Could not set optional Fadeout shortcut");
        TransportFadeoutPanel panel(session, settings, bindings); panel.setSize(440, 452);
        auto *enabled = dynamic_cast<ToggleButton *>(uiFeatureTests::find(panel, "transportFadeoutEnabled"));
        auto *duration = dynamic_cast<ComboBox *>(uiFeatureTests::find(panel, "transportFadeoutDuration"));
        auto *shortcut = dynamic_cast<TextButton *>(uiFeatureTests::find(panel, "transportFadeoutShortcut"));
        // Engine::loadProject orders special tracks first. Resolve fixture roles
        // after loading instead of treating the source array index as identity.
        const auto trackID = [&](const char *role) {
            for (const auto &track : session.song()->tracks) if (track.role.id == role) return track.id;
            throw std::runtime_error("Missing Fadeout fixture track role");
        };
        const auto audioID = trackID("other"), groupID = trackID("group"), videoID = trackID("video");
        auto *selected = dynamic_cast<ToggleButton *>(uiFeatureTests::find(panel, "transportFadeoutTrack-" + text(audioID)));
        auto *group = dynamic_cast<ToggleButton *>(uiFeatureTests::find(panel, "transportFadeoutTrack-" + text(groupID)));
        require(enabled && duration && shortcut && selected && group, "Missing Fadeout controls");
        require(!uiFeatureTests::find(panel, "transportFadeoutTrack-" + text(videoID)), "Video track appeared in Fadeout list");
        require(KeyPress::createFromDescription(shortcut->getButtonText()) == KeyPress(KeyPress::F8Key), "Modal shortcut label differs from Actions");
        auto *midiTab = dynamic_cast<TextButton *>(uiFeatureTests::find(panel,"transportFadeoutMIDI"));
        auto *keyboardTab = dynamic_cast<TextButton *>(uiFeatureTests::find(panel,"transportFadeoutKeyboard"));
        auto *remove = dynamic_cast<TextButton *>(uiFeatureTests::find(panel,"transportFadeoutRemoveShortcut"));
        require(midiTab && keyboardTab && remove,"Direct MIDI and keyboard tabs exist");
        midiTab->onClick();shortcut->onClick();
        require(bindings.learning=="transportFadeout" && bindings.learningKind=="midi","MIDI learning starts inside Fadeout modal");
        require(panel.keyPressed(KeyPress(KeyPress::escapeKey)) && bindings.learning.isEmpty(),"Escape cancels MIDI learning without closing modal");
        auto midi=object();put(midi,"status",0x90);put(midi,"number",67);put(midi,"channel",2);
        require(bindings.assign("transportFadeout","midi",midi),"MIDI assignment accepted");bindings.sendSynchronousChangeMessage();
        require(shortcut->getButtonText().contains("67"),"MIDI label displayed in same modal");
        keyboardTab->onClick();require(KeyPress::createFromDescription(shortcut->getButtonText())==KeyPress(KeyPress::F8Key),"Keyboard mapping survives MIDI mapping");
        shortcut->onClick();midiTab->onClick();require(bindings.learning.isEmpty(),"Changing tab cancels old learning");
        remove->onClick();require(bindings.inputLabel("transportFadeout","midi").isEmpty() && bindings.inputLabel("transportFadeout","keyboard").isNotEmpty(),"Clear affects only selected input type");
        keyboardTab->onClick();
        enabled->setToggleState(true, dontSendNotification); enabled->onClick();
        duration->setSelectedId(5, dontSendNotification); duration->onChange();
        group->setToggleState(false, dontSendNotification); group->onClick();
        const auto saved = TransportFadeoutPanel::read(Appearance(file), session.project());
        require(saved.enabled && saved.duration == 5 && saved.tracks.count(audioID) && !saved.tracks.count(groupID),
                "Panel changes were not persisted immediately");
        for (const auto *id : {"transportFadeoutEnabled", "transportFadeoutDuration", "transportFadeoutTracks",
                              "transportFadeoutShortcut", "transportFadeoutRemoveShortcut", "transportFadeoutMIDI"}) {
            auto *component = uiFeatureTests::find(panel, id);
            require(component && panel.getLocalBounds().contains(component->getBounds()), "Fadeout control clipped at installed modal size");
        }
        session.command(jaras::CommandKind::play);
        session.toggleTransportFadeout(true, {audioID}, 1);
        require(session.transportFadeoutActive(), "Could not begin offline Fadeout");
        TransportFadeoutPanel activePanel(session, settings, bindings); activePanel.setSize(440, 452);
        for (const auto *id : {"transportFadeoutEnabled", "transportFadeoutDuration", "transportFadeoutShortcut",
                              "transportFadeoutRemoveShortcut", "transportFadeoutMIDI"})
            require(!uiFeatureTests::find(activePanel, id)->isEnabled(), "Configuration remained editable during Fadeout");
        require(!uiFeatureTests::find(activePanel, "transportFadeoutTrack-" + text(audioID))->isEnabled(),
                "Track selection remained editable during Fadeout");
        session.cancelTransportFadeout();
    });
    test("Fadeout overlay counts down, separates warnings and preserves input", [&, require] {
        Session session; session.inspection = true;
        auto project = session.project();
        jaras::Track track; track.id = uuid(); track.name = "Fadeout UI audio"; track.role.id = "other";
        project.songs.front().tracks.push_back(track);
        session.audio.prepareOffline(48000); session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        int cancellations = 0;
        TransportFadeoutOverlay overlay(session, [&] { ++cancellations; session.cancelTransportFadeout(); });
        overlay.setSize(1366, 768);
        bool interceptSelf = true, interceptChildren = false;
        overlay.getInterceptsMouseClicks(interceptSelf, interceptChildren);
        auto *cancel = dynamic_cast<TextButton *>(uiFeatureTests::find(overlay, "transportFadeoutCancel"));
        require(!interceptSelf && interceptChildren && !overlay.getWantsKeyboardFocus() && cancel &&
                !cancel->getWantsKeyboardFocus() && !cancel->getMouseClickGrabsKeyboardFocus(), "Overlay steals transport focus or pointer input");
        session.command(jaras::CommandKind::play); session.toggleTransportFadeout(true, {track.id}, 1); overlay.update();
        require(overlay.isActive() && overlay.isVisible() && cancel->isVisible(), "Countdown was not shown");
        auto pixel = [&] {
            // Use a software image and finish Graphics before reading pixels;
            // a native Direct2D image may still have a pending drawing context.
            Image image(Image::ARGB, overlay.getWidth(), overlay.getHeight(), true, SoftwareImageType());
            { Graphics graphics(image); overlay.paint(graphics); }
            const auto card = overlay.countdownArea();
            return image.getPixelAt(card.getX() + 210, card.getY() + 45);
        };
        require(pixel() == theme::green, "Countdown bar did not start full");
        uiFeatureTests::render(session, 24000); overlay.update();
        require(pixel() != theme::green, "Countdown bar filled instead of shrinking");
        overlay.showWarning("Subplay indisponivel enquanto o Fadeout esta acontecendo.");
        for (int scale = 60; scale <= 120; scale += 10) {
            overlay.setSize(1366 * 100 / scale, 768 * 100 / scale);
            require(!overlay.countdownArea().intersects(overlay.warningArea()) &&
                    overlay.getLocalBounds().contains(overlay.countdownArea()) &&
                    overlay.getLocalBounds().contains(overlay.warningArea()) &&
                    overlay.countdownArea().contains(cancel->getBounds()), "Warning, countdown or Cancel overlaps/clips at supported scale");
            require(!overlay.hitTest(overlay.getWidth() / 2, overlay.getHeight() / 2), "Overlay blocks unrelated controls");
        }
        cancel->onClick();
        require(cancellations == 1 && !session.transportFadeoutActive() && session.transport().playing && !cancel->isVisible(),
                "Cancel stopped transport or left Fadeout active");
        overlay.showWarning({});
        require(!overlay.isVisible(), "Inactive overlay remains visible after warning clears");
    });
    test("Ctrl+A resolves the last editor area without leaking to hidden or destroyed areas", [&, require] {
        const KeyPress select('A', ModifierKeys::ctrlModifier, 0);
        require(isSelectAllShortcut(select) && isSelectAllShortcut(KeyPress('a', ModifierKeys::ctrlModifier, 0)) &&
                isSelectAllShortcut(KeyPress(1, ModifierKeys::ctrlModifier, 0)), "Ctrl+A/C0 normalisation differs");
        require(!isSelectAllShortcut(KeyPress('A')) &&
                !isSelectAllShortcut(KeyPress('A', ModifierKeys::ctrlModifier | ModifierKeys::shiftModifier, 0)) &&
                !isSelectAllShortcut(KeyPress('A', ModifierKeys::ctrlModifier | ModifierKeys::altModifier, 0)), "Modified shortcut consumed as Ctrl+A");
        Component host, grid, tracks, setlist, piano, toolbar, gridItem, trackFader, setlistRow, note;
        for (auto *child : {&grid, &tracks, &setlist, &piano, &toolbar}) host.addAndMakeVisible(child);
        grid.addAndMakeVisible(gridItem); tracks.addAndMakeVisible(trackFader);
        setlist.addAndMakeVisible(setlistRow); piano.addAndMakeVisible(note);
        int selections = 0;
        EditorSelectionAreas areas;
        areas.add(grid, "grid", [&] { ++selections; return true; });
        areas.add(tracks, "tracks", [&] { ++selections; return true; });
        areas.add(setlist, "setlist", [&] { ++selections; return true; });
        areas.add(piano, "piano", [&] { ++selections; return true; });
        areas.activate(gridItem); require(areas.activeScope() == "grid", "Grid descendant chose another area");
        areas.activate(trackFader); require(areas.activeScope() == "tracks", "Mixer descendant chose another area");
        areas.activate(setlistRow); require(areas.activeScope() == "setlist", "Setlist descendant chose another area");
        areas.activate(toolbar); require(areas.activeScope() == "setlist", "Toolbar discarded the active editor area");
        areas.activate(note); require(areas.activeScope() == "piano", "Piano descendant chose another area");
        // JUCE isShowing requires a native peer; this deliberately has none.
        require(!areas.selectAll(select) && selections == 0, "Non-showing editor processed selection");
        auto detached = std::make_unique<Component>();
        areas.add(*detached, "detached mixer", [&] { ++selections; return true; });
        areas.activate(*detached); detached.reset();
        require(areas.activeScope().isEmpty() && !areas.selectAll(select) && selections == 0,
                "Destroyed detached mixer retained a callback target");
        areas.activate(gridItem); require(areas.activeScope() == "grid", "Selection router failed after detached window destruction");
    });
}
} // namespace catlive
