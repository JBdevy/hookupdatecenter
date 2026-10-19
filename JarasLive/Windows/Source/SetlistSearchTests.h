#pragma once
#include "FloatingControlTests.h"

namespace catlive::setlistSearchTests {
inline void require(bool value,const char *message) { if (!value) throw std::runtime_error(message); }
inline jaras::Project fixture() {
    auto project=floatingControlTests::fixture();auto &song=project.songs[0];song.duration=80;
    song.parts={{"late","Final",60,80},{"early",utf8(String::fromUTF8("Canção (versão acústica)")),0,20},
                {"family","Medley",20,40},{"child-a",utf8(String::fromUTF8("Graça")),20,30},
                {"child-b",utf8(String::fromUTF8("Refrão")),30,40},{"outside",utf8(String::fromUTF8("Canção final")),40,60}};
    song.parts[3].parentRegionID="family";song.parts[4].parentRegionID="family";
    jaras::RegionSetlist state;
    state.playlists={{"last","Only last",song.id,{"late"}},{"family-list","Family",song.id,{"family"}}};
    state.selectedId="last";
    jaras::SetlistBlock block;block.id="block";block.songId=song.id;block.playlistId="last";
    block.beforeRegionId="late";block.name=utf8(String::fromUTF8("Canção bloco"));block.color=0x54ff93;
    state.blocks=std::vector<jaras::SetlistBlock>{block};project.regionSetlist=state;
    return project;
}
inline std::vector<String> strings(const var &values) {
    std::vector<String> result;for (const auto &value:list(values)) result.push_back(value.toString());return result;
}
inline void click(SetlistRows &rows,int row) {
    const Point<float> at{20.f,(float)rows.rowTop(row)+15};
    rows.getModel()->listBoxItemClicked(row,MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
        ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,&rows,&rows,Time::getCurrentTime(),at,
        Time::getCurrentTime(),1,false));
}
template <typename Test> void registerTests(const File &directory,Test &test) {
    test("Setlist search uses persisted IDs and finds every song, including accented children outside the playlist",[&] {
        auto project=fixture();
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        const auto preferences=directory.getNonexistentChildFile("setlist-search-ids",".json");
        require(preferences.replaceWithText(R"({"jaras.setlist.idMode":"region"})"),"Cannot create Setlist search preferences");
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,preferences);workspace.setSize(1366,768);
        auto *toggle=dynamic_cast<TextButton *>(uiFeatureTests::find(workspace,"setlistSearchToggle"));
        auto *field=dynamic_cast<TextEditor *>(uiFeatureTests::find(workspace,"setlistSearchField"));
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));
        require(toggle && field && rows,"Setlist search controls missing");
        require(rows->getRowHeight(0)==28 && rows->getRowHeight(1)==38 && rows->rowTop(1)==28,
                "Compact block rows must not reserve the height of a song");
        auto state=[&]{return get(workspace.diagnostics(),"setlist");};
        auto ids=[&]{return strings(get(state(),"rowIDs"));};
        auto query=[&](const String &text){field->setText(text,false);field->onTextChange();};
        require(ids()==std::vector<String>{"block","late"} &&
                (int)list(get(state(),"rowRegionNumbers"))[1]==1,"Normal playlist did not retain the region's creation ID");
        toggle->onClick();
        require(flag(state(),"searching") && field->isVisible() &&
                ids()==std::vector<String>{"early","family","child-a","child-b","outside","late"},
                "Opening empty search stayed in the playlist, omitted children, kept blocks or sorted by creation order");
        query("cancao");
        require(ids()==std::vector<String>{"early","outside"},"Search did not ignore accents or included matching playlist blocks");
        query(String::fromUTF8(u8"CANC\u0327A\u0303O"));
        require(ids()==std::vector<String>{"early","outside"},"Decomposed accents did not match the composed song names");
        query(" 02 ");require(ids()==std::vector<String>{"early"},"Zero-padded numeric query used chronological position instead of persisted ID");
        query("0000000000000000000002");require(ids()==std::vector<String>{"early"},"Leading zeroes changed the region ID");
        query("999999999999999999999999");require(ids().empty(),"Overflowing numeric search matched an unrelated ID");
        field->onReturnKey();require(flag(state(),"searching") && session.project().regionSetlist->selectedId=="last",
                "Enter on an empty result changed the selected playlist or closed search");
        query("cancao");field->onReturnKey();
        require(!flag(state(),"searching") && !field->isVisible() && field->getText().isEmpty() &&
                !session.project().regionSetlist->selectedId && session.transport().regionId=="early" &&
                session.transport().editPosition==0 && ids()==std::vector<String>{"early","family","outside","late"},
                "Enter did not select the first chronological result, switch to All Regions and restore its normal list");
        require(strings(get(state(),"rowRegionNumbers"))==std::vector<String>{"2","3","6","1"},
                "All Regions renumbered stored IDs by their timeline order");
        toggle->onClick();query("graca");click(*rows,0);
        require(!session.project().regionSetlist->selectedId && session.transport().editPosition==20 &&
                strings(get(state(),"visibleSelectedEntries"))==std::vector<String>{"child-a"} &&
                ids()==std::vector<String>{"early","family","child-a","child-b","outside","late"},
                "Choosing a hidden child did not expand its parent and reveal the selected song");
        const Point<float> repeatAt{20,15};
        const MouseEvent repeat(Desktop::getInstance().getMainMouseSource(),repeatAt,
            ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,rows,rows,Time::getCurrentTime(),repeatAt,
            Time::getCurrentTime(),2,false);
        rows->getModel()->listBoxItemClicked(0,repeat);rows->getModel()->listBoxItemDoubleClicked(0,repeat);
        require(session.transport().editPosition==20 &&
                strings(get(state(),"visibleSelectedEntries"))==std::vector<String>{"child-a"},
                "Second click selected the normal-list row that replaced the search result");
        auto familyState=*session.project().regionSetlist;familyState.selectedId="family-list";
        session.configureSetlist(familyState);
        toggle->onClick();query("05");click(*rows,0);
        require(session.project().regionSetlist->selectedId=="family-list" && session.transport().editPosition==30 &&
                strings(get(state(),"visibleSelectedEntries"))==std::vector<String>{"child-b"} && !flag(state(),"searching"),
                "Searching a child already in the playlist unnecessarily switched to All Regions or failed to close search");
    });
    test("Setlist playlist numbering searches names and queues a global result without seeking the playing song",[&] {
        auto project=fixture();project.songs[0].parts[0].name="Final 02";
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("setlist-search-playback",".json"));
        workspace.setSize(1366,768);
        auto *toggle=dynamic_cast<TextButton *>(uiFeatureTests::find(workspace,"setlistSearchToggle"));
        auto *field=dynamic_cast<TextEditor *>(uiFeatureTests::find(workspace,"setlistSearchField"));
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));
        require(toggle && field && rows,"Setlist search controls missing");
        auto state=[&]{return get(workspace.diagnostics(),"setlist");};
        auto query=[&](const String &text){field->setText(text,false);field->onTextChange();};
        toggle->onClick();query("02");
        require(strings(get(state(),"rowIDs"))==std::vector<String>{"late"},
                "Playlist numbering mode searched region IDs instead of only names");
        field->onEscapeKey();
        require(!flag(state(),"searching") && strings(get(state(),"rowIDs"))==std::vector<String>{"block","late"} &&
                session.project().regionSetlist->selectedId=="last","Escape did not restore the original playlist and blocks");
        session.command(jaras::CommandKind::selectRegion,"early");session.command(jaras::CommandKind::play);
        uiFeatureTests::render(session,48000);
        const auto audioBefore=session.audio.state();const auto editBefore=session.transport().editPosition;
        toggle->onClick();query("graca");click(*rows,0);
        const auto audioAfter=session.audio.state();
        require(audioAfter.playing && std::abs(audioAfter.position-audioBefore.position)<.0001 &&
                session.transport().playing && session.transport().regionId=="early" &&
                session.transport().queuedRegionId=="child-a" && session.transport().editPosition==editBefore,
                "Choosing a search result sought/stopped the playing song instead of arming its queue");
        require(!session.project().regionSetlist->selectedId && !flag(state(),"searching") &&
                strings(get(state(),"visibleSelectedEntries"))==std::vector<String>{"child-a"},
                "Queued child outside the playlist was not revealed in All Regions");
        session.command(jaras::CommandKind::stopAll);
    });
}
}
