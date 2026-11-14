#include <juce_gui_basics/juce_gui_basics.h>
#include <map>
#include <optional>
#include <stdexcept>
using namespace juce;
using ID=std::string;
namespace jaras {
struct TimecodeSettings { std::string mode="ltc"; };
struct Track { ID id; struct Role { std::string id="other"; } role; std::optional<TimecodeSettings> timecode; };
struct Song { std::vector<Track> tracks; };
inline std::string fixedTrackName(const Track::Role &role){return role.id=="other"?"":role.id;}
inline bool isTeleprompterRole(const Track::Role &role){return role.id=="teleprompter";}
}
struct Session {
    jaras::Song value;
    jaras::Song *song(){return &value;}
    bool programChangePasteReady=false;
    int scannerQueries=0;
    bool scanningProgramChange(const ID &){++scannerQueries;return false;}
    uint64 scannedProgramChangePacket(const ID &){return 0;}
    void *selectedProgramMarker(){return nullptr;}
};
namespace trackIcons { inline bool visible(const jaras::Song *){return false;} }
namespace theme { const auto green=Colours::green; }
namespace localization { inline String translate(const String &s){return s;} }
namespace meterDisplay {
// INSERT_VIEWPORT_VISIBILITY
}
// INSERT_SPECIAL_CONTROLS

class MixerPanel final : public Component {
public:
    struct Strip final: Component {
        ID id;
        int refreshes=0;
        static inline int constructions=0;
        Strip(MixerPanel &,ID value):id(std::move(value)){++constructions;}
        void refresh(){++refreshes;}
        void ensureControlLayout(){}
    };
    struct MixerViewport:Viewport {
        std::function<void()> moved;
        void visibleAreaChanged(const juce::Rectangle<int>&)override{if(moved)moved();}
    } viewport;
    Component content;
    Session &session;
    std::unique_ptr<Strip> master;
    OwnedArray<Strip> strips;
    std::vector<ID> ids;
    bool masterRight=false,showsIcons=false;
    std::function<bool(ID)> isTrackVisible;
    ScrollBar horizontal{false};
    static constexpr int stripWidth=100,stripStride=103;
    explicit MixerPanel(Session &s):session(s),master(std::make_unique<Strip>(*this,ID{})) {
        addAndMakeVisible(*master);addAndMakeVisible(viewport);addAndMakeVisible(horizontal);
        viewport.setViewedComponent(&content,false);viewport.setScrollBarsShown(false,false,false,false);
        viewport.moved=[this]{refreshVisible();syncScroll();};
    }
    ~MixerPanel(){viewport.moved={};viewport.setViewedComponent(nullptr,false);}
// INSERT_MIXER_METHODS
};
static void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
int main(){
    ScopedJuceInitialiser_GUI init;
    Session session;for(int i=0;i<900;++i){jaras::Track track;track.id=std::to_string(i);session.value.tracks.push_back(track);}
    MixerPanel panel(session);panel.setSize(1200,280);panel.refresh();
    auto *first=panel.strips[0],*last=panel.strips[899];const int created=MixerPanel::Strip::constructions;
    for(int repeat=0;repeat<5;++repeat){
        jaras::Track track;track.id="copy"+std::to_string(repeat);session.value.tracks.push_back(track);
        panel.refresh();panel.revealTrack(track.id);
        require(MixerPanel::Strip::constructions==created+repeat+1,"An insertion reconstructed existing strips");
        require(panel.strips[0]==first && panel.strips[899]==last,"Existing controls changed identity");
        require(panel.viewport.getViewArea().contains(panel.strips.getLast()->getBounds()),"Newest strip is outside the viewport");
    }
    for(auto *strip:panel.strips)strip->refreshes=0;
    panel.refreshVisible();int touched=0;for(auto *strip:panel.strips)touched+=strip->refreshes>0;
    require(touched>0 && touched<15,"Meter refresh visited offscreen strips");
    panel.revealTrack("0");require(panel.viewport.getViewPositionX()==0,"An earlier copy cannot be revealed");
    session.value.tracks.erase(session.value.tracks.begin()+400);panel.refresh();
    require(panel.strips[0]==first && panel.strips[898]==last,"Deletion recreated the surviving controls");
    std::reverse(session.value.tracks.begin(),session.value.tracks.end());panel.refresh();
    require(panel.strips.getLast()==first,"Reordering recreated a control");
    panel.setSize(190,280);panel.revealTrack("0");
    require(panel.viewport.getViewArea().intersects(first->getBounds()),"Narrow mixers cannot reveal the destination");
    std::puts("WINDOWS_MIXER_900_TRACKS_RETAINS_CONTROLS_BOUNDS_REFRESH_AND_FOLLOWS_COPY_OK");

    std::vector<std::unique_ptr<SpecialTrackControls>> controls;
    for(const auto &track:session.value.tracks) {
        controls.push_back(std::make_unique<SpecialTrackControls>(session,track.id,[](ID,String){}));
        require(!controls.back()->isTimerRunning(),"An ordinary track started a scanner timer");
    }
    session.value.tracks.front().role.id="programChange";controls.front()->refresh();
    require(controls.front()->isTimerRunning(),"The Program Change scanner lost its updates");
    controls.front()->timerCallback();require(session.scannerQueries==0,"An offscreen scanner did work");
    session.value.tracks.front().role.id="other";controls.front()->refresh();
    require(!controls.front()->isTimerRunning(),"A role change left a scanner timer running");
    std::puts("WINDOWS_900_ORDINARY_TRACKS_HAVE_NO_SPECIAL_CONTROL_TIMERS_OK");
}
