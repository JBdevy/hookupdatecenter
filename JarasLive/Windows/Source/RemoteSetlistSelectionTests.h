#pragma once
#include "FloatingControlTests.h"
#include "RemotePresentation.h"

namespace catlive::remoteSetlistSelectionTests {
inline void require(bool value,const char *message) { if (!value) throw std::runtime_error(message); }
inline jaras::Project fixture() {
    auto project=floatingControlTests::fixture();auto &song=project.songs[0];
    song.duration=300;song.parts.clear();
    for(int i=0;i<26;++i) song.parts.push_back({uuid(),"Song "+std::to_string(i+1),i*10.,(i+1)*10.});
    const auto parent=uuid();
    song.parts.push_back({parent,"Unified",260,280});
    song.parts.push_back({uuid(),"Child A",260,270});song.parts.back().parentRegionID=parent;
    song.parts.push_back({uuid(),"Child B",270,280});song.parts.back().parentRegionID=parent;
    song.parts.push_back({uuid(),"Last",280,300});
    jaras::RegionSetlist state;
    state.playlists={{uuid(),"Only last",song.id,{song.parts.back().id}},
                     {uuid(),"Unified playlist",song.id,{parent}}};
    project.regionSetlist=state;return project;
}
inline var request(const Session &session,const ID &target) {
    auto value=object();put(value,"id",remote::wireID(uuid()));
    put(value,"project",remote::wireID(session.project().id));
    put(value,"song",remote::wireID(session.song()->id));
    put(value,"action","selectRegion");put(value,"target",remote::wireID(target));
    put(value,"value",0);return value;
}
inline std::vector<String> strings(const var &value) {
    std::vector<String> result;for(const auto &item:list(value))result.push_back(item.toString());return result;
}
inline int rowFor(const Workspace &workspace,const ID &id) {
    const auto rows=strings(get(get(workspace.diagnostics(),"setlist"),"rowIDs"));
    const auto found=std::find(rows.begin(),rows.end(),text(id));
    return found==rows.end()?-1:(int)std::distance(rows.begin(),found);
}
inline void selectedAndRevealed(Workspace &workspace,SetlistRows &rows,const ID &id,const ID &visible={}) {
    const auto state=get(workspace.diagnostics(),"setlist");
    const auto visibleID=visible.empty()?id:visible;
    require(strings(get(state,"selectedEntries"))==std::vector<String>{text(id)} &&
            strings(get(state,"visibleSelectedEntries"))==std::vector<String>{text(visibleID)},
            "Remote did not select exactly the requested Setlist row");
    const auto row=rowFor(workspace,visibleID);require(row>=0,"Selected Remote song is absent from the list");
    const auto top=rows.rowTop(row),scroll=rows.getViewport()->getViewPositionY();
    require(top>=scroll && top+rows.getRowHeight(row)<=scroll+rows.getViewport()->getViewHeight(),
            "Remote selection did not scroll its row fully into view");
}
inline void click(SetlistRows &rows,int row) {
    rows.selectRow(row);
    const Point<float> at{20.f,(float)(rows.rowTop(row)+15)};
    rows.getModel()->listBoxItemClicked(row,MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
        ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,&rows,&rows,Time::getCurrentTime(),at,
        Time::getCurrentTime(),1,false));
}
template <typename Test> void registerTests(const File &directory,Test &test) {
    test("Setlist drag preview contains only draggable selected rows at display resolution",[&] {
        struct Model final : ListBoxModel {
            int getNumRows() override {return 9;}
            void paintListBoxItem(int row,Graphics &g,int,int,bool) override {
                g.fillAll(row==0?Colours::red:row==2?Colours::blue:Colours::green);
            }
            var getDragSourceDescription(const SparseSet<int> &selection) override {
                return selection.contains(1)?var{}:var("song");
            }
        } model;
        SetlistRows rows;rows.setModel(&model);rows.setSize(300,100);rows.updateContent();
        rows.selectRow(0,false,true);
        auto single=rows.createDragPreview(2).getImage();
        const auto *firstRow=rows.getViewport()->getViewedComponent()->getChildComponent(0);
        require(single.getHeight()==76 && single.getWidth()==firstRow->getWidth()*2 && single.getPixelAt(20,20)==Colours::red,
                ("Single-song preview: "+String(single.getWidth())+"x"+String(single.getHeight())+" row="+String(firstRow->getWidth())+" color="+single.getPixelAt(20,20).toString()).toRawUTF8());
        rows.selectRow(1,false,false);rows.selectRow(2,false,false);
        auto multiple=rows.createDragPreview(2).getImage();
        require(multiple.getHeight()==152 && multiple.getPixelAt(20,20)==Colours::red && multiple.getPixelAt(20,100)==Colours::blue,
                "Drag preview included an excluded row or gaps between selected songs");
        rows.getViewport()->setViewPosition(0,200);
        auto scrolled=rows.createDragPreview(2).getImage();
        require(scrolled.getHeight()==152 && scrolled.getPixelAt(20,20)==Colours::red && scrolled.getPixelAt(20,100)==Colours::blue,
                "Scrolling clipped selected rows in the drag preview");
        rows.selectRangeOfRows(0,8);
        require(rows.createDragPreview(2).getImage().getHeight()==(5*38+24)*2,
                "Large selections must use a compact preview and remaining-count footer");
        rows.setModel(nullptr);
    });
    test("Setlist group drag retains selected songs until release and a plain click collapses on mouse-up",[&] {
        struct Model final : ListBoxModel {
            SetlistRows &rows;int clicks=0;
            explicit Model(SetlistRows &value):rows(value) {}
            int getNumRows() override {return 4;}
            void paintListBoxItem(int,Graphics &,int,int,bool) override {}
            void listBoxItemClicked(int row,const MouseEvent &) override {++clicks;rows.selectRow(row,false,true);}
        };
        SetlistRows rows;Model model(rows);rows.setModel(&model);rows.setSize(300,200);rows.updateContent();
        rows.selectRangeOfRows(0,1);
        auto *row=rows.getViewport()->getViewedComponent()->getChildComponent(0);
        require(row,"First Setlist row missing");
        const Point<float> start{20,15};
        const auto event=[&](Point<float> at,bool moved) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
                ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,row,row,Time::getCurrentTime(),start,
                Time::getCurrentTime(),1,moved);
        };
        row->mouseDown(event(start,false));
        require(rows.getSelectedRows().size()==2 && model.clicks==0,"Mouse-down collapsed selection before drag");
        row->mouseDrag(event({20,90},true));row->mouseUp(event({20,90},true));
        require(rows.getSelectedRows().size()==2 && model.clicks==0,"Group drag activated a single song");
        row->mouseDown(event(start,false));row->mouseUp(event(start,false));
        require(rows.getSelectedRows().size()==1 && rows.getSelectedRows().contains(0) && model.clicks==1,
                ("Plain click must select its song only on release: selected="+std::to_string(rows.getSelectedRows().size())+" clicks="+std::to_string(model.clicks)+" bounds="+row->getBounds().toString().toStdString()).c_str());
        rows.setModel(nullptr);
    });
    test("Actual Setlist preserves multiple songs through mouse-down, refresh, drag payload and release",[&] {
        auto project=fixture();const auto &parts=project.songs[0].parts;
        auto &state=*project.regionSetlist;
        state.playlists[0].regionIds={parts[0].id,parts[1].id,parts[2].id,parts[3].id};
        state.selectedId=state.playlists[0].id;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        const auto settings=directory.getNonexistentChildFile("setlist-group-press",".json");
        Workspace workspace(session,auth,lighting,false,settings);workspace.setSize(1366,768);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));
        require(rows,"Setlist rows missing");
        rows->selectRow(0,false,true);rows->selectRow(2,false,false);
        auto *row=rows->getViewport()->getViewedComponent()->getChildComponent(0);
        const Point<float> start{20,15};
        const auto event=[&](bool moved) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),start,
                ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,row,row,Time::getCurrentTime(),start,
                Time::getCurrentTime(),1,moved);
        };
        const auto revision=session.setlistFocusRevision;
        row->mouseDown(event(false));
        require(rows->getSelectedRows().size()==2 && session.setlistFocusRevision==revision,
                "Actual Setlist activated one song on mouse-down before group drag");
        // Normal project notifications must not discard the pending group drag.
        session.configureSetlist(*session.project().regionSetlist);
        const auto payload=rows->getModel()->getDragSourceDescription(rows->getSelectedRows());
        require(strings(get(payload,"ids"))==std::vector<String>{text(parts[0].id),text(parts[2].id)},
                "Refresh lost a selected song or changed the drag payload order");
        row->mouseUp(event(true));
        require(rows->getSelectedRows().size()==2 && session.setlistFocusRevision==revision,
                "Drag release collapsed selection or activated a song");
        row->mouseDown(event(false));
        require(rows->getSelectedRows().size()==2,"Second press collapsed group selection");
        row->mouseUp(event(false));
        require(rows->getSelectedRows().size()==1 && rows->getSelectedRows().contains(0) && session.focusedRegion==parts[0].id,
                "Plain release failed to select and focus only the clicked song");
    });
    test("Remote region commands select and reveal the same Setlist row as local clicks, including repeated selections and unified children",[&] {
        const auto project=fixture();const auto &parts=project.songs[0].parts;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        const auto settings=directory.getNonexistentChildFile("remote-setlist-selection",".json");
        Workspace workspace(session,auth,lighting,false,settings);workspace.setSize(1366,768);
        Appearance preferences(settings);StageState stage(preferences);remote::Presentation presentation(session,stage);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));
        require(rows,"Setlist rows missing");
        // This is the same decode/apply path called by Host::perform after authentication.
        auto select=[&](const ID &id){require(presentation.apply(remote::Command::decode(request(session,id))),"Remote rejected a current region command");};
        const auto focusBefore=session.setlistFocusRevision;
        select(parts.back().id);
        require(session.focusedRegion==parts.back().id && session.setlistFocusRevision>focusBefore &&
                session.transport().editPosition==280 && !session.transport().playing,
                "Stopped Remote selection did not focus the requested song and its edit cursor");
        selectedAndRevealed(workspace,*rows,parts.back().id);
        rows->selectRow(0);rows->getViewport()->setViewPosition(0,0);
        const auto sameBefore=session.setlistFocusRevision;select(parts.back().id);
        require(session.setlistFocusRevision>sameBefore,"Selecting the same song remotely did not request another reveal");
        selectedAndRevealed(workspace,*rows,parts.back().id);
        click(*rows,rowFor(workspace,parts[12].id));
        const auto localPosition=session.transport().position,localEdit=session.transport().editPosition;
        selectedAndRevealed(workspace,*rows,parts[12].id);
        select(parts[0].id);select(parts[12].id);
        require(session.transport().position==localPosition && session.transport().editPosition==localEdit,
                "Remote stopped selection differs from a local Setlist click");
        selectedAndRevealed(workspace,*rows,parts[12].id);
        auto playlist=*session.project().regionSetlist;playlist.selectedId=playlist.playlists[0].id;
        session.configureSetlist(playlist);select(parts[27].id);
        require(!session.project().regionSetlist->selectedId && session.transport().editPosition==260,
                "Remote child outside the playlist did not reveal All Regions at the child's start");
        selectedAndRevealed(workspace,*rows,parts[27].id,parts[26].id);
        auto *drawer=dynamic_cast<Button *>(uiFeatureTests::find(workspace,"setlist-drawer-"+text(parts[26].id)));
        require(drawer && drawer->onClick,"Unified region drawer missing");drawer->onClick();select(parts[27].id);
        selectedAndRevealed(workspace,*rows,parts[27].id);
        playlist=*session.project().regionSetlist;playlist.selectedId=playlist.playlists[1].id;
        session.configureSetlist(playlist);select(parts[28].id);
        require(session.project().regionSetlist->selectedId==playlist.selectedId,
                "Remote child already represented by its parent discarded the selected playlist");
        selectedAndRevealed(workspace,*rows,parts[28].id);
        auto *toggle=dynamic_cast<TextButton *>(uiFeatureTests::find(workspace,"setlistSearchToggle"));
        auto *search=dynamic_cast<TextEditor *>(uiFeatureTests::find(workspace,"setlistSearchField"));
        require(toggle && search,"Setlist search controls missing");toggle->onClick();
        search->setText("no matching song",false);search->onTextChange();select(parts[27].id);
        require(!flag(get(workspace.diagnostics(),"setlist"),"searching"),"A search filter hid the remotely selected song");
        selectedAndRevealed(workspace,*rows,parts[27].id);
        const auto validFocus=session.setlistFocusRevision;const auto validPosition=session.transport().editPosition;
        require(!presentation.apply(remote::Command::decode(request(session,uuid()))),"Unknown Remote region was accepted");
        auto stale=request(session,parts[0].id);put(stale,"project",remote::wireID(uuid()));
        require(!presentation.apply(remote::Command::decode(stale)) && session.setlistFocusRevision==validFocus &&
                session.transport().editPosition==validPosition,"Invalid/stale Remote request changed the selection or cursor");
        selectedAndRevealed(workspace,*rows,parts[27].id);
    });
    test("Remote region selection queues like a local click without seeking playback and still reveals the selected row",[&] {
        const auto project=fixture();const auto &parts=project.songs[0].parts;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        const auto settings=directory.getNonexistentChildFile("remote-setlist-playback",".json");
        Workspace workspace(session,auth,lighting,false,settings);workspace.setSize(1366,768);
        Appearance preferences(settings);StageState stage(preferences);remote::Presentation presentation(session,stage);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));require(rows,"Setlist rows missing");
        auto select=[&](const ID &id){require(presentation.apply(remote::Command::decode(request(session,id))),"Remote rejected selection during playback");};
        session.command(jaras::CommandKind::selectRegion,parts[0].id);session.command(jaras::CommandKind::play);
        uiFeatureTests::render(session,48000);session.command(jaras::CommandKind::editSeek,{},0);
        const auto before=session.audio.state();const auto editBefore=session.transport().editPosition;
        auto playbackUnchanged=[&] {
            require(session.audio.state().playing && session.transport().playing &&
                    std::abs(session.audio.state().position-before.position)<.0001 &&
                    std::abs(session.transport().position-before.position)<.0001 &&
                    session.transport().editPosition==editBefore && session.transport().regionId==parts[0].id,
                    "Remote Setlist selection stopped or sought the running audio/edit cursor");
        };
        click(*rows,rowFor(workspace,parts.back().id));
        const auto localQueue=session.transport().queuedRegionId;
        require(localQueue==parts.back().id,"Local click did not queue the destination");
        select(parts.back().id);require(!session.transport().queuedRegionId,"Remote reclick did not cancel the existing queue");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts.back().id);
        select(parts.back().id);require(session.transport().queuedRegionId==localQueue,"Remote queue differs from local selection");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts.back().id);
        select(parts[0].id);
        require(session.transport().queuedRegionId==localQueue,"Selecting the active song discarded the armed next song");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts[0].id);
        auto playlist=*session.project().regionSetlist;playlist.selectedId=playlist.playlists[0].id;
        session.configureSetlist(playlist);select(parts[28].id);
        require(session.transport().queuedRegionId==parts[28].id && !session.project().regionSetlist->selectedId,
                "Remote child selection outside the playlist did not arm/reveal that song");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts[28].id,parts[26].id);
        session.command(jaras::CommandKind::stopAll);
    });
}
} // namespace catlive::remoteSetlistSelectionTests
