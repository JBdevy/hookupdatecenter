#pragma once
#include "ModalSheet.h"
namespace catlive {
inline bool tracksContainItems(const jaras::Project &project, const std::set<ID> &ids) {
    for (const auto &song : project.songs)
        for (const auto &track : song.tracks)
            if (ids.count(track.id) && !track.clips.empty()) return true;
    return false;
}
class TrackDeletionConfirmationPanel final : public Component {
    class Choice final : public QuietButton {
    public:
        bool primary = false;
        void paintButton(Graphics &g, bool over, bool down) override {
            auto fill = primary ? Colour(0xff60b53d) : Colour(0xff48474b);
            if (over) fill = fill.brighter(.08f);
            if (down) fill = fill.darker(.15f);
            g.setColour(fill); g.fillRoundedRectangle(getLocalBounds().toFloat(), getHeight() / 2.f);
            g.setColour(primary ? Colours::white : Colour(0xffff6666));
            g.setFont(theme::mediumFont(14));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
    } cancel, remove;
    std::function<void()> accept;
public:
    explicit TrackDeletionConfirmationPanel(std::function<void()> action) : accept(std::move(action)) {
        getProperties().set("selfContainedSheet", true);
        getProperties().set("sheetCornerRadius", 25.0);
        setComponentID("trackDeletionConfirmation"); setWantsKeyboardFocus(true);
        cancel.primary = true;
        cancel.setButtonText(localization::translate("Cancel")); cancel.setComponentID("cancelTrackDeletion");
        remove.setButtonText(localization::translate("Delete")); remove.setComponentID("confirmTrackDeletion");
        addAndMakeVisible(cancel); addAndMakeVisible(remove);
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        remove.onClick = [this] { auto action = accept; ModalSheet::dismiss(*this); MessageManager::callAsync(std::move(action)); };
    }
    void paint(Graphics &g) override {
        const auto frame = getLocalBounds().toFloat().reduced(.5f);
        g.setGradientFill(ColourGradient(Colour(0xf5303030), 0, 0, Colour(0xf039363e), (float)getWidth(), (float)getHeight(), false));
        g.fillRoundedRectangle(frame,25); g.setColour(Colour(0xff565656)); g.drawRoundedRectangle(frame,25,1);
        g.setColour(Colour(0xffdddddd)); g.setFont(theme::semiboldFont(16));
        g.drawFittedText(localization::translate("Delete selected tracks and their items?"),24,20,getWidth()-48,70,Justification::centredLeft,3,1.f);
    }
    void resized() override {
        cancel.setBounds(16,getHeight()-82,getWidth()-32,30);
        remove.setBounds(16,getHeight()-44,getWidth()-32,30);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey || key == KeyPress::returnKey) { cancel.onClick(); return true; }
        return false;
    }
};
}
