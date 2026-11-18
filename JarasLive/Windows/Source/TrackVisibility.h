#pragma once
#include "Appearance.h"
#include "TrackTree.h"
#include "Localization.h"

namespace catlive {
// Presentation preferences belong to this computer/project, never to the audio
// graph or .jl file. A hidden parent does not overwrite a child's own choice.
class TrackVisibility {
  public:
    static constexpr size_t fixedTrackLimit = 6;
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
        std::vector<ID> pins;
        for (const auto &value : list(appearance.value(pinKey(project)))) {
            if (value.isString() && value.toString().isNotEmpty()) {
                const auto id = utf8(value.toString());
                if (std::find(pins.begin(), pins.end(), id) == pins.end()) pins.push_back(id);
            }
            if (pins.size() == fixedTrackLimit) break;
        }
        const bool changed = projectID != project || hidden != next || fixed != pins;
        projectID = project; hidden = std::move(next); fixed = std::move(pins);
        return changed;
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
    const std::vector<ID>& fixedTracks() const { return fixed; }
    Result toggleFixedTrack(Appearance &appearance, const jaras::Project &project, const ID &id) {
        if (projectID != project.id) load(appearance, project.id);
        auto next = fixed;
        auto exists = [&](const ID &track) {
            return std::any_of(project.songs.begin(), project.songs.end(), [&](const auto &song) {
                return trackTree::index(song, track) < song.tracks.size();
            });
        };
        if (!exists(id)) return Result::ok();
        next.erase(std::remove_if(next.begin(), next.end(), [&](const auto &track) { return !exists(track); }), next.end());
        if (const auto at = std::find(next.begin(), next.end(), id); at != next.end()) next.erase(at);
        else {
            if (next.size() >= fixedTrackLimit) return Result::fail(localization::translate("You can pin up to six tracks."));
            next.push_back(id);
        }
        Array<var> values;
        for (const auto& track : next) values.add(text(track));
        auto result = appearance.set(pinKey(project.id), values);
        if (result.wasOk()) fixed = std::move(next);
        return result;
    }
    bool hasHidden() const { return !hidden[0].empty()||!hidden[1].empty(); }
  private:
    ID projectID;
    std::vector<ID> fixed;
    static String pinKey(const ID &project) { return "trackVisibility."+text(project)+".fixedTracks"; }
    std::array<std::set<ID>,2> hidden;
    static size_t index(Panel panel) { return panel==Panel::trackMixer?0:1; }
    static String key(const ID &project,Panel panel) { return "trackVisibility."+text(project)+"."+panelName(panel); }
};
} // namespace catlive
