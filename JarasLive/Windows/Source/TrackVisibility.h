#pragma once
#include "Appearance.h"
#include "TrackTree.h"

namespace catlive {
// Presentation preferences belong to this computer/project, never to the audio
// graph or .jl file. A hidden parent does not overwrite a child's own choice.
class TrackVisibility {
  public:
    enum class Panel { trackMixer, barMixer };
    static String panelName(Panel panel) { return panel==Panel::trackMixer?"trackMixer":"barMixer"; }
    static bool supportsBarMixer(const jaras::Track &track) {
        return jaras::fixedTrackName(track.role).empty()||track.role.id=="generatedClick";
    }
    bool load(const Appearance &appearance,const ID &project) {
        std::array<std::set<ID>,2> next;
        for(auto panel:{Panel::trackMixer,Panel::barMixer})
            for(const auto &value:list(appearance.value(key(project,panel))))
                if(value.isString()&&value.toString().isNotEmpty())next[index(panel)].insert(utf8(value.toString()));
        const bool changed=projectID!=project||hidden!=next;
        projectID=project;hidden=std::move(next);return changed;
    }
    bool ownVisible(Panel panel,const ID &id) const { return hidden[index(panel)].count(id)==0; }
    bool visible(const jaras::Song &song,Panel panel,const ID &id) const {
        if(hidden[index(panel)].empty())return true;
        const auto at=trackTree::index(song,id);
        return at<song.tracks.size()?visible(song,panel,song.tracks[at]):ownVisible(panel,id);
    }
    bool visible(const jaras::Song &song,Panel panel,const jaras::Track &track) const {
        if(hidden[index(panel)].empty())return true;
        const auto &id=track.id;
        if(!ownVisible(panel,id))return false;
        auto parent=track.parentTrackID;
        for(size_t guard=0;guard<song.tracks.size();++guard) {
            if(!parent)return true;
            if(!ownVisible(panel,*parent))return false;
            const auto at=trackTree::index(song,*parent);
            if(at>=song.tracks.size())break;
            parent=song.tracks[at].parentTrackID;
        }
        return true;
    }
    Result set(Appearance &appearance,const ID &project,Panel panel,const ID &id,bool visible) {
        if(projectID!=project)load(appearance,project);
        auto next=hidden[index(panel)];
        if(visible)next.erase(id);else if(!id.empty())next.insert(id);
        Array<var> values;for(const auto &entry:next)values.add(text(entry));
        auto result=appearance.set(key(project,panel),values);
        if(result.wasOk())hidden[index(panel)]=std::move(next);
        return result;
    }
    bool hasHidden() const { return !hidden[0].empty()||!hidden[1].empty(); }
  private:
    ID projectID;
    std::array<std::set<ID>,2> hidden;
    static size_t index(Panel panel) { return panel==Panel::trackMixer?0:1; }
    static String key(const ID &project,Panel panel) { return "trackVisibility."+text(project)+"."+panelName(panel); }
};
} // namespace catlive
