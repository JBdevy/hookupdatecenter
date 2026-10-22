#pragma once
#include "TimelineVisualParityTests.h"

namespace catlive::itemLocalGeometryTests {
using floatingControlTests::require;
inline jaras::AudioClip clip(const ID &id, double start, double duration) {
    jaras::AudioClip value; value.id=id; value.name=id; value.startTime=start; value.duration=duration; return value;
}
inline jaras::Track track() {
    jaras::Track value; value.id="local-lanes"; value.name="Local overlap geometry"; value.role.id="other";
    value.clips={clip("isolated",1,2),clip("adjacent",3,2),clip("pair-a",6,4),clip("pair-b",7,4),
                 clip("triple-a",12,4),clip("triple-b",13,4),clip("triple-c",14,4)};
    return value;
}
inline MouseEvent mouse(Component &canvas, Point<float> at, Point<float> anchor, int flags, bool dragged=false) {
    return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(flags),1,0,0,0,0,
                      &canvas,&canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);
}
inline bool approximatelyEqual(double a, double b) { return std::abs(a-b)<1e-4; }
inline const jaras::AudioClip &currentClip(Session &session, const ID &id) {
    for(const auto &track:session.song()->tracks) for(const auto &item:track.clips) if(item.id==id)return item;
    throw std::runtime_error("Local geometry fixture lost an item");
}

template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Item local geometry gives isolated clips full height and independent overlap groups two or three lanes", [] {
        const auto source=track(); const ItemLanes lanes(source);
        require(lanes.count==3,"Track height lost its maximum simultaneous lane count");
        const ID ids[]{"isolated","adjacent","pair-a","pair-b","triple-a","triple-b","triple-c"};
        const int counts[]{1,1,2,2,3,3,3}, positions[]{0,0,0,1,0,1,2};
        for(size_t i=0;i<7;++i) {
            const auto placement=lanes.placement(ids[i]); const auto geometry=lanes.geometry(ids[i],180);
            require(placement.count==counts[i] && placement.lane==positions[i],"An unrelated overlap changed the clip's local lane placement");
            require(approximatelyEqual(geometry.height,180./counts[i]) && approximatelyEqual(geometry.top,positions[i]*180./counts[i]),
                    "Local item rectangle does not partition the entire track height");
        }
        auto reversed=source; std::reverse(reversed.clips.begin(),reversed.clips.end()); const ItemLanes reverse(reversed);
        for(const auto &id:ids) require(reverse.placement(id).lane==lanes.placement(id).lane &&
                                      reverse.placement(id).count==lanes.placement(id).count,
                                      "Insertion order changed deterministic local lane placement");
        jaras::Track chain; chain.clips={clip("a",0,3),clip("b",2,3),clip("c",4,3),clip("touch",7-5e-10,2)};
        const ItemLanes connected(chain);
        require(connected.placement("a").count==2 && connected.placement("b").count==2 &&
                connected.placement("c").count==2 && connected.placement("c").lane==0 &&
                connected.placement("touch").count==1,"Overlap chains or nanosecond adjacency tolerance differ from Mac");
        chain.clips={clip("a",0,2),clip("b",2-2e-9,1)};
        require(ItemLanes(chain).placement("b").count==2,"A real overlap beyond tolerance was treated as adjacency");
    });
    test("Recorded takes keep their order and active recording retains the existing global lane geometry", [] {
        auto source=track();
        auto first=clip("take1",22,4);first.recordingLane=1;
        auto second=clip("take2",22,4);second.recordingLane=2;
        source.clips.push_back(second);source.clips.push_back(clip("base",21,4));source.clips.push_back(first);
        const ItemLanes lanes(source);
        require(lanes.placement("base").lane==0 && lanes.placement("take1").lane==1 &&
                lanes.placement("take2").lane==2 && lanes.placement("take2").count==3,
                "Recorded take order changed while building local overlap groups");
        require(approximatelyEqual(lanes.geometry("isolated",180).height,180),"A recorded take elsewhere shrank an isolated item");
        for(const auto &item:source.clips) {
            const auto live=lanes.geometry(item.id,180,true);
            require(approximatelyEqual(live.height,180./lanes.count) && approximatelyEqual(live.top,lanes.lane(item.id)*180./lanes.count),
                    "Active recording stopped using the established global take lanes");
        }
    });
    test("Workspace paints local item heights and marquee selects the lower part of an isolated item", [&] {
        auto project=floatingControlTests::fixture(); project.songs[0].tracks[0]=track();
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("item-local-geometry",".json"));
        workspace.setSize(1366,768);timelineVisualParityTests::fit(workspace);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
        auto *row=uiFeatureTests::find(workspace,"trackRow:local-lanes");
        require(canvas && canvas->getParentComponent() && row,"Local item geometry fixture is unavailable");
        auto &timeline=*canvas->getParentComponent();
        auto capture=[&] { canvas->repaint();return timeline.createComponentSnapshot(timeline.getLocalBounds()); };
        auto bounds=[&](const ID &id) {return timelineVisualParityTests::localRect(workspace,
            get(timelineVisualParityTests::itemState(workspace,id),"bounds"));};
        const auto timelineState=get(workspace.diagnostics(),"timeline");
        const auto mixerBounds=workspace.getLocalArea(row,row->getLocalBounds());
        const double rowTop=mixerBounds.getY()-num(timelineState,"y"),height=mixerBounds.getHeight();
        const ID ids[]{"isolated","adjacent","pair-a","pair-b","triple-a","triple-b","triple-c"};
        const int counts[]{1,1,2,2,3,3,3}, positions[]{0,0,0,1,0,1,2};
        for(size_t i=0;i<7;++i) {
            const auto item=bounds(ids[i]);
            require(approximatelyEqual(item.getY(),rowTop+positions[i]*height/counts[i]+3) && approximatelyEqual(item.getHeight(),height/counts[i]-6),
                    "Workspace diagnostics or hit geometry still use the track's global lane count for every item");
        }
        timelineVisualParityTests::save(directory,"item-local-geometry.png",capture());
        const auto isolated=bounds("isolated");
        const Point<float> anchor{isolated.getX()+4,isolated.getY()+isolated.getHeight()*.75f};
        const Point<float> end{isolated.getRight()-4,isolated.getBottom()-4};
        canvas->mouseDown(mouse(*canvas,anchor,anchor,ModifierKeys::rightButtonModifier));
        canvas->mouseDrag(mouse(*canvas,end,anchor,ModifierKeys::rightButtonModifier,true));
        canvas->mouseUp(mouse(*canvas,end,anchor,0,true));
        const auto selected=list(get(workspace.diagnostics(),"selectedItems"));
        require(selected.size()==1 && selected[0].toString()=="isolated",
                "Right-drag marquee ignored the lower full-height item or captured another overlap cluster");
        timelineVisualParityTests::save(directory,"item-local-marquee-selected.png",capture());

        // Begin a move in the lower full-height area, then cross into the next
        // clip's time interval. Preview must adopt that local overlap geometry
        // and release must preserve it without grabbing a different track.
        const double zoom=num(timelineState,"zoom");
        const Point<float> origin{isolated.getCentreX(),isolated.getBottom()-12};
        const auto destination=origin+Point<float>((float)zoom,0);
        canvas->mouseDown(mouse(*canvas,origin,origin,ModifierKeys::leftButtonModifier));
        canvas->mouseDrag(mouse(*canvas,destination,origin,ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier,true));
        require(approximatelyEqual(currentClip(session,"isolated").startTime,1),"Move preview committed before release");
        const auto movePreview=capture();
        canvas->mouseUp(mouse(*canvas,destination,origin,ModifierKeys::shiftModifier,true));
        require(approximatelyEqual(currentClip(session,"isolated").startTime,2),"Dragging the lower isolated area moved the wrong item or track");
        const auto moved=bounds("isolated");
        require(approximatelyEqual(moved.getY(),rowTop+3) && approximatelyEqual(moved.getHeight(),height/2-6),"Moving into an overlap did not use the new local pair geometry");
        const auto body=moved.withTrimmedTop(22).reduced(4).getLargestIntegerWithin();
        require(timelineVisualParityTests::differences(movePreview,capture(),body)==0,
                "Move release changed the locally sized preview inside the item");

        const Point<float> resizeAt{moved.getRight()-1,moved.getBottom()-10};
        const auto resizeTo=resizeAt+Point<float>((float)(.5*zoom),0);
        canvas->mouseDown(mouse(*canvas,resizeAt,resizeAt,ModifierKeys::leftButtonModifier));
        canvas->mouseDrag(mouse(*canvas,resizeTo,resizeAt,ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier,true));
        const auto resizePreview=capture();
        require(approximatelyEqual(currentClip(session,"isolated").duration,2),"Resize preview committed before release");
        canvas->mouseUp(mouse(*canvas,resizeTo,resizeAt,ModifierKeys::shiftModifier,true));
        require(approximatelyEqual(currentClip(session,"isolated").duration,2.5),"Local resize hit-testing changed the wrong edge or item");
        const auto resizedBody=bounds("isolated").withTrimmedTop(22).reduced(4).getLargestIntegerWithin();
        const auto committed=capture();
        require(timelineVisualParityTests::differences(resizePreview,committed,resizedBody)==0,
                "Resize release changed the locally sized preview inside the item");
        timelineVisualParityTests::save(directory,"item-local-resize-preview.png",resizePreview);
        timelineVisualParityTests::save(directory,"item-local-resize-committed.png",committed);
    });
}
}
