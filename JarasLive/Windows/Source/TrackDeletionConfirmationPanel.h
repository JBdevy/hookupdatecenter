#pragma once
#include "ModalSheet.h"
#include "ConfirmationStyle.h"
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
            g.setFont(theme::mediumFont(confirmationStyle::buttonSize));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
    } cancel, remove;
    std::function<void()> accept;
public:
    explicit TrackDeletionConfirmationPanel(std::function<void()> action) : accept(std::move(action)) {
        getProperties().set("selfContainedSheet", true);
        getProperties().set("sheetCornerRadius", (double)confirmationStyle::radius);
        setComponentID("trackDeletionConfirmation"); setWantsKeyboardFocus(true);
        remove.destructive = true;
        cancel.setButtonText(localization::translate("Cancel")); cancel.setComponentID("cancelTrackDeletion");
        remove.setButtonText(localization::translate("Delete")); remove.setComponentID("confirmTrackDeletion");
        addAndMakeVisible(cancel); addAndMakeVisible(remove);
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        remove.onClick = [this] { auto action = accept; ModalSheet::dismiss(*this); MessageManager::callAsync(std::move(action)); };
    }
    void paint(Graphics &g) override {
        confirmationStyle::surface(g,getLocalBounds().toFloat());
        g.setColour(Colour(0xffdddddd));g.setFont(theme::semiboldFont(confirmationStyle::titleSize));
        g.drawFittedText(localization::translate("Delete selected tracks and their items?"),20,20,getWidth()-40,46,Justification::centredLeft,2,1.f);
    }
    void resized() override {
        const int width=(getWidth()-2*confirmationStyle::margin-confirmationStyle::gap)/2;
        cancel.setBounds(confirmationStyle::margin,getHeight()-52,width,confirmationStyle::buttonHeight);
        remove.setBounds(cancel.getRight()+confirmationStyle::gap,cancel.getY(),width,confirmationStyle::buttonHeight);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey || key == KeyPress::returnKey) { cancel.onClick(); return true; }
        return false;
    }
};
}
