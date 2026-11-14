#include "Songs/Song.hpp"
#include "Project/Models.hpp"
#include "TimelineSelection.h"
#include <cassert>
#include <functional>
#include <iostream>
#include <memory>
using jaras::ID;
using String=std::string;
template<class T> using SafePointer=T*;
String text(const String& value){return value;}
String utf8(const String& value){return value;}
namespace trackTree { size_t index(const jaras::Song& song,const ID& id){return std::find_if(song.tracks.begin(),song.tracks.end(),[&](const auto& t){return t.id==id;})-song.tracks.begin();} }
namespace theme {
struct Colour { unsigned value; unsigned getARGB()const{return value;} };
Colour track(const jaras::Track& t){return {t.color.value_or(0x414141)};}
}
struct Component { virtual ~Component()=default; };
struct RegionEditor {
    bool allowUppercase,allowName;
    std::function<void(String,unsigned,bool)> commit;
    RegionEditor(String,unsigned,bool,std::function<void(String,unsigned,bool)> save,std::function<void()>,bool upper,bool name)
        :allowUppercase(upper),allowName(name),commit(std::move(save)){}
};
struct Workspace;
struct ModalSheet:Component {
    String title; bool dismissed=false;
    String getName()const{return title;}
    void exitModalState(int){dismissed=true;}
    static inline std::unique_ptr<RegionEditor> editor;
    static inline String lastTitle;
    static void open(Workspace&,String,std::unique_ptr<RegionEditor>,int,int);
};
struct Session {
    jaras::Project model; int edits=0;
    const jaras::Project& project()const{return model;}
    const jaras::Song* song()const{return model.songs.empty()?nullptr:&model.songs.front();}
    template<class F>void edit(F f,bool){f(model);++edits;}
};
struct Workspace {
    Session session;
    ModalSheet sheet;
    std::vector<Component*> getChildren(){return {&sheet};}
    template<class F>void perform(F f){f();}
    void editTrack(ID,std::set<ID> targets={});
};
void ModalSheet::open(Workspace& w,String title,std::unique_ptr<RegionEditor> content,int,int){
    lastTitle=title;w.sheet.title=title;w.sheet.dismissed=false;editor=std::move(content);
}
// INSERT_EDIT_TRACK
int main(){
    Workspace w; w.session.model.id="project";
    jaras::Song song; song.id="song";
    for(auto id:{"a","b","c"}){jaras::Track t;t.id=id;t.name=id;t.role.id="keys";t.color=0x111111;song.tracks.push_back(t);}
    w.session.model.songs={song};
    w.editTrack("a",{"a","b"});
    assert(ModalSheet::lastTitle=="Editar pistas" && !ModalSheet::editor->allowName && !ModalSheet::editor->allowUppercase);
    ModalSheet::editor->commit("Ignored",0x55aa88,false);
    const auto& tracks=w.session.model.songs.front().tracks;
    assert(tracks[0].color==0x55aa88 && tracks[1].color==0x55aa88 && tracks[2].color==0x111111);
    assert(tracks[0].name=="a" && tracks[1].name=="b" && w.session.edits==1 && w.sheet.dismissed);
    w.editTrack("a");assert(ModalSheet::editor->allowName);
    ModalSheet::editor->commit("Renamed",0xaabbcc,false);
    assert(tracks[0].name=="Renamed" && tracks[1].name=="b");
    w.editTrack("a",{"a","b","missing"});
    w.session.model.id="another";
    const int edits=w.session.edits;
    ModalSheet::editor->commit("Stale",0xffffff,false);
    assert(w.session.edits==edits && tracks[0].color==0xaabbcc);
    std::vector<ID> ordered{"a","b","c","d","e"};
    assert(catlive::timelineSelection::interval(ordered,ID("b"),ID("e"))==std::set<ID>({"b","c","d","e"}));
    assert(catlive::timelineSelection::interval(ordered,ID("d"),ID("a"))==std::set<ID>({"a","b","c","d"}));
    assert(catlive::timelineSelection::interval(ordered,ID("missing"),ID("c"))==std::set<ID>({"c"}));
    std::cout<<"WINDOWS_MULTI_TRACK_COLOUR_SINGLE_EDIT_NO_RENAME_STALE_PROJECT_AND_SELECTION_INTERVAL_OK\n";
}
