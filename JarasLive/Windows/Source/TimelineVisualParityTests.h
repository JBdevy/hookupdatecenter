#pragma once
#include "FloatingControlTests.h"
#include "ItemLayout.h"
#include "TimelineGrid.h"
#include "TimelineNeedle.h"

namespace catlive::timelineVisualParityTests {
using floatingControlTests::require;

inline MouseEvent mouse(Component &canvas, Point<float> at, Point<float> anchor, bool down, bool dragged = false) {
    return MouseEvent(Desktop::getInstance().getMainMouseSource(), at,
        ModifierKeys((dragged ? ModifierKeys::shiftModifier : 0) | (down ? ModifierKeys::leftButtonModifier : 0)),
        1, 0, 0, 0, 0, &canvas, &canvas, Time::getCurrentTime(), anchor, Time::getCurrentTime(), 1, dragged);
}
inline int differences(const Image &a, const Image &b, juce::Rectangle<int> area) {
    require(a.isValid() && b.isValid() && a.getBounds() == b.getBounds(), "Timeline snapshots have different dimensions");
    int changed = 0;
    for (int y = area.getY(); y < area.getBottom(); ++y)
        for (int x = area.getX(); x < area.getRight(); ++x)
            changed += a.getPixelAt(x,y) != b.getPixelAt(x,y);
    return changed;
}
inline int maximumChannelDifference(const Image &a, const Image &b) {
    require(a.isValid() && b.isValid() && a.getBounds() == b.getBounds(), "Timeline snapshots have different dimensions");
    int maximum = 0;
    for (int y = 0; y < a.getHeight(); ++y)
        for (int x = 0; x < a.getWidth(); ++x) {
            const auto before = a.getPixelAt(x,y), after = b.getPixelAt(x,y);
            maximum = std::max({maximum, std::abs(before.getRed()-after.getRed()),
                std::abs(before.getGreen()-after.getGreen()), std::abs(before.getBlue()-after.getBlue()),
                std::abs(before.getAlpha()-after.getAlpha())});
        }
    return maximum;
}
inline void save(const File &directory, const char *name, const Image &image) {
    FileOutputStream output(directory.getChildFile(name));
    require(output.openedOk(), "Cannot create timeline visual regression screenshot");
    output.setPosition(0); output.truncate();
    require(PNGImageFormat().writeImageToStream(image,output), "Cannot write timeline visual regression screenshot");
}
inline var itemState(Workspace &workspace, const ID &id) {
    for (const auto &item : list(get(get(workspace.diagnostics(),"timeline"),"visibleItems")))
        if (str(item,"id") == text(id)) return item;
    throw std::runtime_error("Timeline visual regression item is not visible");
}
inline juce::Rectangle<float> localRect(Workspace &workspace, const var &rectangle) {
    const auto state=get(workspace.diagnostics(),"timeline");
    return {(float)(num(rectangle,"x")-num(state,"x")), (float)(num(rectangle,"y")-num(state,"y")),
            (float)num(rectangle,"width"), (float)num(rectangle,"height")};
}
inline void zoomInForInspection(Workspace &workspace) {
    auto *slider = dynamic_cast<Slider *>(uiFeatureTests::find(workspace, "timeline-zoom-slider"));
    require(slider && bool(slider->onValueChange), "Timeline zoom slider is missing");
    // Keep the fixture's items at seconds 3–20 within the viewport.
    slider->setValue(30., dontSendNotification);
    slider->onValueChange();
}

template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Wave LFO editor redraws the amplitude envelope when Sustain changes", [&] {
        auto project = floatingControlTests::fixture();
        const auto track = project.songs.front().tracks.front().id;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        require(session.insertLibraryEffect(track, "native:Wave LFO", {}) == "Wave LFO", "Cannot insert the track envelope");
        EffectsPanel panel(session, track, [](String error) { throw std::runtime_error(utf8(error)); }, false, "Wave LFO");
        panel.setSize(720, 480);
        fxui::Knob* sustain = nullptr;
        for (auto* child : panel.getChildren())
            if (auto* knob = dynamic_cast<fxui::Knob*>(child); knob && knob->slider.getMaximum() == 100) sustain = knob;
        require(sustain != nullptr, "Missing Sustain control");
        auto changedGraph = [&](double value) {
            sustain->slider.setValue(value, sendNotificationSync);
            const auto band = panel.getLocalBounds().withY(sustain->getY() - 70).withHeight(66).reduced(25, 0);
            return panel.createComponentSnapshot(band);
        };
        const auto high = changedGraph(85), low = changedGraph(15);
        int changed = 0;
        for (int y = 0; y < high.getHeight(); ++y)
            for (int x = 0; x < high.getWidth(); ++x)
                if (std::abs(high.getPixelAt(x,y).getGreen() - low.getPixelAt(x,y).getGreen()) > 25) ++changed;
        require(changed > 90, "The displayed ADSR curve did not follow the knob");
        require(std::abs(WaveLFOParameters::read(fxchain::settings(session,track)).sustain - .15) < .0001,
                "The graph and the saved audio parameter differ");
    });
    test("Wave LFO Library drop distinguishes an audio item from its track", [&] {
        auto project = floatingControlTests::fixture();
        auto& track = project.songs.front().tracks.front();
        jaras::AudioClip first; first.id = uuid(); first.name = "First"; first.startTime = 3; first.duration = 3;
        first.audioFile = jaras::AudioFile{"Stems/source.wav", {}};
        auto next = first; next.id = uuid(); next.name = "Second"; next.startTime = 10;
        track.clips = {first, next};
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session, auth, lighting, false, directory.getNonexistentChildFile("wave-drop", ".json"));
        workspace.setSize(1366, 768); zoomInForInspection(workspace);
        auto* canvas = uiFeatureTests::find(workspace, "timelineCanvas");
        auto* target = dynamic_cast<DragAndDropTarget*>(canvas);
        require(target != nullptr, "Timeline drop target is missing");
        auto rect = [&](const ID& id) {
            const auto bounds = get(itemState(workspace, id), "bounds");
            const juce::Rectangle<int> inWorkspace(roundToInt(num(bounds, "x")), roundToInt(num(bounds, "y")),
                roundToInt(num(bounds, "width")), roundToInt(num(bounds, "height")));
            return canvas->getLocalArea(&workspace, inWorkspace).toFloat();
        };
        auto drop = [&](Point<int> point) {
            auto payload = object(); put(payload, "type", "catlive-library-effect");
            put(payload, "project", text(project.id)); put(payload, "identity", "native:Wave LFO");
            DragAndDropTarget::SourceDetails drag(payload, &workspace, point);
            require(target->isInterestedInDragSource(drag), "Timeline refused the Library effect");
            target->itemDragEnter(drag); target->itemDragMove(drag); target->itemDropped(drag);
        };
        const auto itemPoint = rect(first.id).getCentre().roundToInt();
        drop(itemPoint);
        const auto wave = [](const auto& json) {
            return json && WaveLFOParameters::read(JSON::parse(text(*json))).enabled;
        };
        const auto& a = session.song()->tracks.front();
        require(wave(a.clips[0].fxJSON), "The audio item must accept the Wave LFO insert through the shared core");
        require(!wave(a.fxJSON) && !wave(a.clips[1].fxJSON), "Item drop leaked to another destination");
        const auto left = rect(first.id), right = rect(next.id);
        drop({roundToInt((left.getRight() + right.getX()) / 2), roundToInt(left.getCentreY())});
        const auto restored = ProjectCodec::decode(ProjectCodec::encode(session.project()));
        const auto& saved = restored.songs.front().tracks.front();
        require(wave(saved.fxJSON) && wave(saved.clips[0].fxJSON) && !wave(saved.clips[1].fxJSON),
                "Reopened document lost the distinction between the track and its item");
    });
    test("Playback needle paints and clears its left-hand trail", [&] {
        const auto render = [](float x, float width) {
            Image image(Image::ARGB, 128, 60, true, SoftwareImageType{});
            Graphics graphics(image);
            timelineNeedle::draw(graphics, x, 0.f, 12.f, 60.f, Colours::lime, width);
            return image;
        };
        const auto playing = render(64.5f, timelineNeedle::maxTrailWidth);
        const auto paused = render(64.5f, 0.f);
        const auto alpha = [&](int x) { return playing.getPixelAt(x, 35).getAlpha(); };
        require(alpha(24) == 0 && alpha(32) > 0 && alpha(32) < alpha(46) &&
                alpha(46) < alpha(58) && alpha(70) == 0,
                "Playback trail must strengthen towards the needle and end at its leading edge");
        require(playing.getPixelAt(45, 5).getAlpha() == 0 && paused.getPixelAt(45, 35).getAlpha() == 0,
                "Trail leaked into the ruler or remained visible on pause");
        const auto moved = render(104.25f, timelineNeedle::maxTrailWidth);
        const auto oldArea = timelineNeedle::paintBounds(64.5f, timelineNeedle::maxTrailWidth, playing.getBounds());
        const auto newArea = timelineNeedle::paintBounds(104.25f, timelineNeedle::maxTrailWidth, playing.getBounds());
        for (int y = 0; y < playing.getHeight(); ++y)
            for (int x = 0; x < playing.getWidth(); ++x) {
                if (playing.getPixelAt(x, y).getAlpha() != 0)
                    require(oldArea.contains(x, y), "Old needle pixels escaped the stop/seek repaint");
                if (moved.getPixelAt(x, y).getAlpha() != 0)
                    require(newArea.contains(x, y), "New needle pixels escaped the seek repaint");
            }
        require(timelineNeedle::paintBounds(144.f, timelineNeedle::maxTrailWidth, playing.getBounds()).contains(120, 35),
                "A needle just offscreen must still paint the visible end of its trail");
    });
    test("Musical timeline grid resumes the active tempo at the end of an owned section", [&] {
        auto project = floatingControlTests::fixture();
        auto& song = project.songs.front();
        song.parts = {{uuid(), "Local tempo", 4, 8.25}};
        jaras::TimelineMarker global{uuid(), "Global", 0, 0};
        global.tempoBPM = 90;
        jaras::TimelineMarker local{uuid(), "Local", 4, 0};
        local.tempoBPM = 60; local.tempoBeats = 3; local.regionOwnerID = song.parts.front().id;
        song.markers = std::vector<jaras::TimelineMarker>{global, local};
        const auto ticks = timelineGrid::ticks(song, 0, 20, 100, true);
        const auto hasBar = [&](double position) {
            return std::any_of(ticks.begin(), ticks.end(), [position](const auto& tick) {
                return tick.primary && tick.drawsInGrid && std::abs(tick.time - position) < 1e-6;
            });
        };
        require(hasBar(4) && hasBar(7) && hasBar(8.25) && hasBar(8.25 + 8. / 3.) && !hasBar(10),
                "Grid should restart and restore the global tempo at the region end");
    });
    test("Timeline cursor lane separates continuous grid lines from ruler-only ticks", [&] {
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));
        Auth auth; Lighting lighting(session);
        Workspace workspace(session, auth, lighting, false, directory.getNonexistentChildFile("cursor-lane", ".json"));
        workspace.setSize(1366, 768);
        auto* zoom = dynamic_cast<Slider*>(uiFeatureTests::find(workspace, "timeline-zoom-slider"));
        require(zoom && bool(zoom->onValueChange), "Timeline zoom control missing");
        zoom->setValue(32, dontSendNotification); zoom->onValueChange();
        auto* canvas = uiFeatureTests::find(workspace, "timelineCanvas");
        require(canvas && canvas->getParentComponent(), "Timeline canvas missing");
        auto& timeline = *canvas->getParentComponent();
        const auto state = get(workspace.diagnostics(), "timeline");
        const auto offset = num(state, "horizontal");
        const int top = int(num(state, "rulerTop")), bottom = int(num(state, "headerHeight"));
        require(bottom - top == 32, "Ruler numbers and cursor must each occupy a 16-point lane");
        const auto x = [offset](double time) { return roundToInt(time * 32 - offset); };
        const auto pixels = timeline.createComponentSnapshot(timeline.getLocalBounds());
        save(directory, "timeline-cursor-lane.png", pixels);
        const auto light = [&](double time, int y) { return pixels.getPixelAt(x(time), y).getRed(); };
        const auto background = [&](double time, int y) { return pixels.getPixelAt(x(time) - 3, y).getRed(); };
        require(light(4, top + 5) > background(4, top + 5) + 10, "Numbered lines must reach the number lane");
        require(light(2, top + 5) == background(2, top + 5) &&
                light(2, top + 20) > background(2, top + 20) + 10,
                "Unnumbered lines must start in the cursor lane");
        for (const auto y : {top + 15, bottom - 1}) {
            const auto contrast = [&](int row) { return light(4, row) - background(4, row); };
            require(3 * contrast(y) >= 2 * std::min(contrast(y - 1), contrast(y + 1)),
                    "Numbered columns must run across the ruler lane boundaries without a visible break");
        }
        for (const int y : {bottom - 16, bottom - 12, bottom - 5}) {
            const int tickContrast = light(1, y) - background(1, y);
            const int gridContrast = light(2, y) - background(2, y);
            require(tickContrast > 0 && std::abs(tickContrast - gridContrast) <= 1,
                    "Ruler-only marks must match the grid columns throughout the cursor lane");
        }
        require(light(1, top + 5) == background(1, top + 5) &&
                light(1, bottom + 5) == background(1, bottom + 5),
                "Ruler-only marks must stay in the cursor lane");

        // At the overview in the Mac reference, measures 33 to 65 span about
        // 191 points, with a continuous column for every two measures.
        zoom->setValue(2.984375, dontSendNotification); zoom->onValueChange();
        const auto overview = get(workspace.diagnostics(), "timeline");
        const double overviewScale = num(overview, "zoom"), overviewOffset = num(overview, "horizontal");
        const int firstTrackBoundary = bottom + int(num(overview, "trackHeight"));
        const auto overviewPixels = timeline.createComponentSnapshot(timeline.getLocalBounds());
        save(directory, "timeline-ruler-overview.png", overviewPixels);
        for (int measure = 35; measure < 65; measure += 2) {
            const int column = int(std::floor((measure - 1) * 2 * overviewScale - overviewOffset));
            for (const int row : {bottom - 16, bottom - 10, bottom - 2, bottom + 3, firstTrackBoundary - 1}) {
                const int contrast = overviewPixels.getPixelAt(column, row).getRed() -
                                     overviewPixels.getPixelAt(column - 3, row).getRed();
                require(contrast >= 25, "Every overview column must be visible from the top of the cursor lane through the grid");
            }
        }
    });
    test("Desktop minimum zoom uses the calibrated Mac scale on every viewport", [&] {
        for (const double width : {320., 800., 1440., 3840., 7680.}) {
            const double scale = timelineGrid::minimumZoom(width);
            require(std::abs(scale - .3651216238088901) < 1.e-12,
                    "Minimum zoom must match the saved Mac calibration");
            jaras::Song song; song.bpm=120;
            const auto ticks = timelineGrid::ticks(song,0,width/scale,scale);
            require(ticks.size() < size_t(width), "Distant grid must retain bounded tick density");
        }
    });
    test("Item headers keep their original start below the continuous-follow zoom threshold", [&] {
        jaras::Track track; track.id=uuid(); track.name="Track";
        jaras::AudioClip clip; clip.id=uuid(); clip.name="Item"; clip.duration=100;
        const juce::Rectangle<float> bounds(-200,100,1000,70);
        const ItemHeader fixed(bounds,700,track,clip,{},false,10), pinned(bounds,700,track,clip);
        require(fixed.visible.getX()==-200 && pinned.visible.getX()==0,"Header origin must follow the selected zoom policy");
        require(fixed.gainRect.getRight()<0 && pinned.gainRect.getX()>=0,"Offscreen item controls must not retain a pinned hit target");
        require(!ItemHeader::pinsAtScale(23.47) && ItemHeader::pinsAtScale(23.48),"Windows and Apple must use the same reference zoom");
        const juce::Rectangle<float> onscreen(30,100,300,70);
        const ItemHeader overview(onscreen,700,track,clip,{},false,1.0);
        const ItemHeader selected(onscreen,700,track,clip,{},false,1.0,true);
        const ItemHeader narrow({30,100,32,70},700,track,clip,{},false,25);
        const ItemHeader volume(onscreen,700,track,clip,{},false,ItemHeader::volumeMinimumScale);
        const ItemHeader all(onscreen,700,track,clip,{},false,ItemHeader::fxAndPanMinimumScale);
        require(overview.gainRect.isEmpty() && !volume.gainRect.isEmpty() && volume.fxRect.isEmpty() && volume.panRect.isEmpty(),
                "Volume must appear at the first zoom threshold");
        require(overview.nameRect().getWidth() >= 10 && overview.muteRect.isEmpty() &&
                !selected.muteRect.isEmpty() && selected.gainRect.isEmpty() &&
                selected.hit(selected.muteRect.getCentre(),clip) == ItemHeader::mute,
                "Zoomed-out items keep their name and reveal M only on selection");
        require(narrow.nameRect().getWidth() >= 10 && narrow.muteRect.isEmpty(),
                "A short item must keep its name even when the timeline is zoomed in");
        require(!all.gainRect.isEmpty() && !all.fxRect.isEmpty() && !all.panRect.isEmpty(),
                "FX and Pan must appear at the second zoom threshold");
    });
    test("Timeline marker and item drags snap to the existing edit cursor", [&] {
        for (const bool tempo : {false,true}) {
            auto project=floatingControlTests::fixture();auto &song=project.songs[0];
            song.duration=60;song.parts={jaras::Part{uuid(),"Song",20,60}};
            jaras::AudioClip clip;clip.id="cursor-snap-item";clip.name="Item";clip.startTime=3;clip.duration=3;
            song.tracks[0].clips={clip};
            jaras::TimelineMarker marker{uuid(),"Marker",8.3,0xffffff};
            if(tempo){marker.tempoBPM=120;marker.tempoBeats=4;marker.tempoUnit=4;}
            song.markers=std::vector<jaras::TimelineMarker>{marker};
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);
            Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("cursor-drag-snap",".json"));
            workspace.setSize(1366,768);zoomInForInspection(workspace);
            auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");require(canvas,"Missing timeline canvas");
            session.command(jaras::CommandKind::editSeek,{},15.37);
            const auto state=get(workspace.diagnostics(),"timeline");
            const double zoom=num(state,"zoom"),offset=num(state,"horizontal");
            auto event=[&](Point<float> point,Point<float> start,bool down,bool dragged) {
                return MouseEvent(Desktop::getInstance().getMainMouseSource(),point,
                    ModifierKeys(down?ModifierKeys::leftButtonModifier:0),1,0,0,0,0,canvas,canvas,
                    Time::getCurrentTime(),start,Time::getCurrentTime(),1,dragged);
            };
            canvas->createComponentSnapshot(canvas->getLocalBounds());
            Point<float> head{(float)(marker.position*zoom-offset+2),(float)(num(state,"rulerTop")+(tempo ? 8 : -12))};
            auto target=head+Point<float>((float)((15.41-marker.position)*zoom),0);
            canvas->mouseDown(event(head,head,true,false));canvas->mouseDrag(event(target,head,true,true));canvas->mouseUp(event(target,head,false,true));
            auto found=std::find_if(session.song()->markers->begin(),session.song()->markers->end(),[&](const auto &value){return value.id==marker.id;});
            require(found!=session.song()->markers->end() && std::abs(found->position-15.37)<1e-6,"Marker did not snap to edit cursor");
            const auto bounds=localRect(workspace,get(itemState(workspace,clip.id),"bounds"));
            const auto start=bounds.getCentre();target=start+Point<float>((float)((15.41-clip.startTime)*zoom),0);
            canvas->mouseDown(event(start,start,true,false));
            require(std::abs(session.transport().editPosition-15.37)<1e-6,"Picking up an item moved its cursor magnet");
            canvas->mouseDrag(event(target,start,true,true));canvas->mouseUp(event(target,start,false,true));
            require(std::abs(session.song()->tracks[0].clips[0].startTime-15.37)<1e-6,"Item did not snap to edit cursor");
        }
    });
    test("Timeline item edge guides follow drag and resize across the cached grid", [&] {
        auto project=floatingControlTests::fixture();
        jaras::AudioClip clip; clip.id="guide-visual-item"; clip.name="Moving item";
        clip.startTime=3; clip.duration=8;
        project.songs[0].tracks[0].clips={clip};
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("timeline-item-guides",".json"));
        workspace.setSize(1366,768); zoomInForInspection(workspace);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
        require(canvas && canvas->getParentComponent(),"Item guide fixture canvas is missing");
        // Do not force a repaint here: that would hide stale columns in the
        // real buffered canvas when only the dragged item's row is dirty.
        auto &timelineComponent=*canvas->getParentComponent();
        auto capture=[&] { return timelineComponent.createComponentSnapshot(canvas->getBounds()); };
        const auto timeline=get(workspace.diagnostics(),"timeline");
        const double zoom=num(timeline,"zoom"),offset=num(timeline,"horizontal");
        const int y=canvas->getHeight()-24; // Well below the item's row.
        auto xAt=[&](double time) {return roundToInt(time*zoom-offset);};
        auto yellowAt=[&](const Image &image,int x) {
            for(int dx=-1;dx<=1;++dx) {
                const auto pixel=image.getPixelAt(x+dx,y);
                if(pixel.getRed()>240 && pixel.getGreen()>240 && pixel.getBlue()<20)return true;
            }
            return false;
        };
        for (const bool resize : {false,true}) {
            const auto current=session.song()->tracks[0].clips[0];
            const auto bounds=localRect(workspace,get(itemState(workspace,clip.id),"bounds"));
            const Point<float> anchor{resize ? bounds.getRight()-1 : bounds.getCentreX(),bounds.getCentreY()};
            capture();
            canvas->mouseDown(mouse(*canvas,anchor,anchor,true));
            auto image=capture();
            require(yellowAt(image,xAt(current.startTime)) && yellowAt(image,xAt(current.startTime+current.duration)),
                    "Item edge guides are missing before dragging");
            double lastStart=current.startTime,lastEnd=current.startTime+current.duration;
            for(const double delta : {2.,4.,1.}) {
                const auto point=anchor+Point<float>((float)(delta*zoom),0);
                canvas->mouseDrag(mouse(*canvas,point,anchor,true,true));
                image=capture();
                const double from=current.startTime+(resize ? 0 : delta),to=current.startTime+current.duration+delta;
                require(yellowAt(image,xAt(from)) && yellowAt(image,xAt(to)),
                        "Item guides did not follow the preview across the full grid while held");
                if(std::abs(from-lastStart)>1e-6)require(!yellowAt(image,xAt(lastStart)),"Old start guide remained in the cached grid");
                require(!yellowAt(image,xAt(lastEnd)),"Old end guide remained in the cached grid");
                require(session.song()->tracks[0].clips[0].startTime==current.startTime && session.song()->tracks[0].clips[0].duration==current.duration,
                        "Guide movement committed the item before mouse release");
                lastStart=from;lastEnd=to;
            }
            save(directory,resize?"item-resize-guides.png":"item-drag-guides.png",image);
            const auto point=anchor+Point<float>((float)zoom,0);
            canvas->mouseUp(mouse(*canvas,point,anchor,false,true));
            image=capture();
            require(!yellowAt(image,xAt(lastStart)) && !yellowAt(image,xAt(lastEnd)),"Item guides remained after release");
        }
    });
    test("Timeline time selection and active loop have equivalent ruler-down pixels including cursor Heads", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("timeline-range-visual",".json"));
        workspace.setSize(1366,768); zoomInForInspection(workspace);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
        require(canvas && canvas->getParentComponent(), "Timeline canvas or Heads parent is missing");
        auto &timeline=*canvas->getParentComponent();
        auto capture=[&] {
            // The canvas has an image cache. Invalidate it exactly as the real range gesture does,
            // and include its Heads sibling so an extra loop fill in Heads cannot escape this test.
            canvas->repaint(); timeline.repaint();
            return timeline.createComponentSnapshot(timeline.getLocalBounds());
        };
        const auto state=get(workspace.diagnostics(),"timeline");
        const double zoom=num(state,"zoom"), offset=num(state,"horizontal");
        const int left=100, right=std::min(320,canvas->getWidth()-40);
        require(right-left>100 && zoom>0, "Timeline range fixture is too narrow");
        const double from=(left+offset)/zoom, to=(right+offset)/zoom;
        const auto baseline=capture(); save(directory,"timeline-range-baseline.png",baseline);
        session.selectTimeRange(from,to);
        const auto selection=capture();
        session.command(jaras::CommandKind::toggleLoop);
        require(session.transport().loop.enabled && session.transport().loop.start && session.transport().loop.end &&
                std::abs(*session.transport().loop.start-from)<1e-8 && std::abs(*session.transport().loop.end-to)<1e-8,
                "Loop did not adopt the selected time bounds");
        const auto loop=capture();
        save(directory,"timeline-time-selection.png",selection); save(directory,"timeline-loop.png",loop);
        // Repainting a fractional grid edge can quantize its antialias
        // coverage by 3/255, including when enabling Repeat. Keep the same
        // per-channel bound used below when disabling it; an extra overlay,
        // moved boundary or cursor remains far outside this tolerance.
        require(maximumChannelDifference(selection,loop)<=3,
                "Loop adds different pixels, opacity, or cursor Heads compared with the same time selection");
        const int top=(int)num(state,"headerHeight")-16;
        // A 1px outline centered on the ruler boundary has half a pixel of
        // antialias coverage in top-1 (47 for this 48px ruler origin), as on Mac.
        // Nothing farther above may change; in particular Heads must not add
        // a fill over the region/marker/tempo rows.
        require(differences(baseline,selection,{0,0,selection.getWidth(),top-1})==0,
                "Time range overlay leaked into the region, marker, or tempo rows above the ruler");
        require(differences(baseline,selection,{left+20,top+16,right-left-40,selection.getHeight()-top-16})>100,
                "Time range did not visibly shade the timeline below the ruler");
        const int x=left+30, y=top+40;
        const auto expected=baseline.getPixelAt(x,y).overlaidWith(Colours::white.withAlpha(.12f));
        const auto actual=selection.getPixelAt(x,y);
        require(std::abs(actual.getRed()-expected.getRed())<=1 && std::abs(actual.getGreen()-expected.getGreen())<=1 &&
                std::abs(actual.getBlue()-expected.getBlue())<=1,
                "Time range fill is not a single white overlay at twelve percent opacity");
        for (int edge : {left,right}) {
            bool yellow=false;
            for(int dx=-2;dx<=2;++dx) {
                const auto pixel=selection.getPixelAt(edge+dx,y);
                yellow=yellow || (pixel.getRed()>100 && pixel.getGreen()>100 && pixel.getBlue()*2<pixel.getRed());
            }
            require(yellow,"Time range boundary is missing its yellow outline");
        }
        session.command(jaras::CommandKind::toggleLoop);
        require(!session.selectedTimeRange(),"Disabling Repeat retained the manual range");
        const auto disabled=capture(); save(directory,"timeline-repeat-disabled.png",disabled);
        // Repainting a cached fractional grid edge can quantize its coverage
        // by up to 3/255. A retained 12% overlay or yellow boundary is much
        // larger; check every pixel without requiring bit-identical coverage.
        require(maximumChannelDifference(baseline,disabled)<=3,
                "Disabling Repeat left a stale overlay in the cached canvas or cursor Heads");
    });

    test("Timeline fade drag paints immediately and release preserves the exact preview", [&] {
        auto project=floatingControlTests::fixture();
        jaras::AudioClip clip; clip.id="fade-visual-item"; clip.name="Fade preview";
        clip.startTime=2; clip.duration=18; clip.fadeIn=1; clip.fadeOut=1;
        clip.audioFile=jaras::AudioFile{"fade-preview.wav",{}};
        project.songs[0].tracks[0].clips={clip};
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("timeline-fade-visual",".json"));
        workspace.setSize(1366,768); zoomInForInspection(workspace);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
        require(canvas && canvas->getParentComponent(),"Timeline fade fixture canvas is missing");
        auto &timeline=*canvas->getParentComponent();
        auto capture=[&] { canvas->repaint(); return timeline.createComponentSnapshot(timeline.getLocalBounds()); };
        for (const bool left : {true,false}) {
            const auto state=itemState(workspace,clip.id);
            const auto handle=localRect(workspace,get(state,left?"fadeIn":"fadeOut"));
            require(!handle.isEmpty(),"Fade handle is unavailable in the visual fixture");
            const auto at=handle.getCentre();
            const auto zoom=num(get(workspace.diagnostics(),"timeline"),"zoom");
            const auto destination=at+Point<float>((float)((left?1:-1)*3*zoom),0);
            const auto original=left?session.song()->tracks[0].clips[0].fadeIn:session.song()->tracks[0].clips[0].fadeOut;
            canvas->mouseDown(mouse(*canvas,at,at,true));
            const auto before=capture();
            canvas->mouseDrag(mouse(*canvas,destination,at,true,true));
            const auto preview=capture();
            const auto during=left?session.song()->tracks[0].clips[0].fadeIn:session.song()->tracks[0].clips[0].fadeOut;
            require(during==original,"Fade gesture committed the project before mouse release");
            const auto body=localRect(workspace,get(state,"bounds")).withTrimmedTop(18).reduced(2).getLargestIntegerWithin();
            require(differences(before,preview,body)>30,
                    "Fade preview stayed at its original geometry while the mouse was dragging");
            canvas->mouseUp(mouse(*canvas,destination,at,false,true));
            const auto committed=left?session.song()->tracks[0].clips[0].fadeIn:session.song()->tracks[0].clips[0].fadeOut;
            require(committed && std::abs(*committed-original.value_or(0)-3)<1e-5,
                    "Fade release did not commit the displayed duration");
            const auto after=capture();
            save(directory,left?"timeline-fade-in-preview.png":"timeline-fade-out-preview.png",preview);
            save(directory,left?"timeline-fade-in-committed.png":"timeline-fade-out-committed.png",after);
            require(differences(preview,after,body)==0,
                    "Releasing the fade changed the already displayed preview or flashed its old state");
        }
    });
}
}
