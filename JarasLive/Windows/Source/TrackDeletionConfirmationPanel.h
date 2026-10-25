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
        bool destructive = false;
        void paintButton(Graphics &g, bool over, bool down) override {
            auto fill = destructive ? Colour(0xff693c3b) : Colour(0xff444444);
            if (over) fill = fill.brighter(.08f);
            if (down) fill = fill.darker(.15f);
            g.setColour(fill); g.fillRoundedRectangle(getLocalBounds().toFloat(), getHeight() / 2.f);
            g.setColour(destructive ? Colour(0xffff3b30) : Colour(0xffdddddd));
            g.setFont(theme::mediumFont(16));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
    } cancel, remove;
    std::function<void()> accept;
public:
    explicit TrackDeletionConfirmationPanel(std::function<void()> action) : accept(std::move(action)) {
        getProperties().set("selfContainedSheet", true);
        getProperties().set("sheetCornerRadius", 32.0);
        setComponentID("trackDeletionConfirmation"); setWantsKeyboardFocus(true);
        remove.destructive = true;
        cancel.setButtonText(localization::translate("Cancel")); cancel.setComponentID("cancelTrackDeletion");
        remove.setButtonText(localization::translate("Delete")); remove.setComponentID("confirmTrackDeletion");
        addAndMakeVisible(cancel); addAndMakeVisible(remove);
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        remove.onClick = [this] { auto action = accept; ModalSheet::dismiss(*this); MessageManager::callAsync(std::move(action)); };
    }
    void paint(Graphics &g) override {
        const auto frame = getLocalBounds().toFloat().reduced(.5f);
        g.setGradientFill(ColourGradient(Colour(0xff343434), 0, 0, Colour(0xff303030), 0, (float)getHeight(), false));
        g.fillRoundedRectangle(frame,32); g.setColour(Colour(0xff565656)); g.drawRoundedRectangle(frame,32,1);
        g.setColour(Colour(0xffdddddd)); g.setFont(theme::semiboldFont(17));
        g.drawFittedText(localization::translate("Delete selected tracks and their items?"),28,24,getWidth()-56,48,Justification::centredLeft,2,1.f);
    }
    void resized() override {
        const int gap=10,margin=20,width=(getWidth()-2*margin-gap)/2;
        cancel.setBounds(margin,getHeight()-58,width,36);
        remove.setBounds(margin+width+gap,getHeight()-58,getWidth()-margin*2-width-gap,36);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey || key == KeyPress::returnKey) { cancel.onClick(); return true; }
        return false;
    }
};
}
