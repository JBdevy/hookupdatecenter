#pragma once
#include "FloatingControlTests.h"
#include "ItemLayout.h"

namespace catlive::timelineVisualParityTests {
using floatingControlTests::require;

inline MouseEvent mouse(Component &canvas, Point<float> at, Point<float> anchor, bool down, bool dragged = false) {
    return MouseEvent(Desktop::getInstance().getMainMouseSource(), at,
        ModifierKeys(ModifierKeys::shiftModifier | (down ? ModifierKeys::leftButtonModifier : 0)),
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
inline void fit(Workspace &workspace) {
    auto *button=dynamic_cast<Button *>(uiFeatureTests::find(workspace,"zoomFit"));
    require(button && bool(button->onClick), "Timeline fit control is missing");
    button->onClick();
}

template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Timeline time selection and active loop have equivalent ruler-down pixels including cursor Heads", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("timeline-range-visual",".json"));
        workspace.setSize(1366,768); fit(workspace);
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
        project.songs[0].tracks[0].clips={clip};
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("timeline-fade-visual",".json"));
        workspace.setSize(1366,768); fit(workspace);
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
