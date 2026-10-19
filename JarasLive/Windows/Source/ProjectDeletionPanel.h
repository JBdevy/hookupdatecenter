#pragma once
#include "ProjectDeletion.h"
#include "ModalSheet.h"
namespace catlive {
// Matches ProjectDeletionConfirmation on macOS; the plan owns the safety delay.
class ProjectDeletionPanel final : public Component, private Timer {
  public:
    ProjectDeletionPanel(std::shared_ptr<ProjectDeletion> value, std::function<void()> action)
        : plan(std::move(value)), confirm(std::move(action)) {
        getProperties().set("selfContainedSheet", true);
        addAndMakeVisible(cancel); addAndMakeVisible(remove);
        cancel.setButtonText(localization::translate("Cancel"));
        cancel.onClick = [this] { if (!working) ModalSheet::dismiss(*this); };
        remove.onClick = [this] {
            if (working || plan->remaining() > 0) return;
            const SafePointer<ProjectDeletionPanel> safe(this);
            working = true; cancel.setEnabled(false); remove.setEnabled(false);
            ModalSheet::blockDismiss(*this, true);
            try {
                confirm();
                if (safe) { ModalSheet::blockDismiss(*safe, false); ModalSheet::dismiss(*safe); }
            } catch (const std::exception &e) {
                if (!safe) return;
                working = false; failure = String::fromUTF8(e.what());
                ModalSheet::blockDismiss(*this, false); cancel.setEnabled(true);
                ModalSheet::resizeContent(*this, 340); timerCallback(); repaint();
            }
        };
        setSize(460, 298); timerCallback(); startTimerHz(10);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colour(0xffff454a));
        g.drawRoundedRectangle(28, 31, 10, 12, 1, 1.5f);
        g.drawLine(26, 30, 40, 30, 1.5f);
        g.drawRoundedRectangle(31, 26, 4, 4, 1, 1.5f);
        g.drawLine(31, 33, 31, 40, 1); g.drawLine(35, 33, 35, 40, 1);
        g.setFont(theme::font(16, true));
        g.drawText(localization::translate("Delete project"), 49, 24, getWidth()-73, 24, Justification::centredLeft);
        g.setColour(Colours::white); g.setFont(theme::font(13, true));
        g.drawFittedText(plan->document.getFileNameWithoutExtension(), 24, 60, getWidth()-48, 24, Justification::topLeft, 1);
        g.setFont(theme::font(13));
        g.drawFittedText(localization::translate("The CatLive project and its own media, waveform caches and backups will be permanently deleted. The containing folder, unrelated files and media shared with other projects will be kept. This cannot be undone."),
                         24, 94, getWidth()-48, 66, Justification::topLeft, 5, 1.f);
        g.setColour(theme::display); g.fillRoundedRectangle(24, 172, (float)getWidth()-48, 44, 5);
        g.setColour(Colours::white); g.setFont(theme::font(10));
        g.drawFittedText(plan->document.getFullPathName(), 34, 180, getWidth()-68, 28, Justification::centredLeft, 2, 1.f);
        if (failure.isNotEmpty()) {
            g.setColour(Colour(0xffff454a)); g.setFont(theme::font(11));
            g.drawFittedText(failure, 24, 224, getWidth()-48, 34, Justification::topLeft, 2, 1.f);
        }
    }
    void resized() override {
        cancel.setBounds(24, getHeight()-56, 78, 24);
        remove.setBounds(getWidth()-144, getHeight()-64, 120, 40);
    }
  private:
    class ActionButton final : public TextButton {
      public:
        explicit ActionButton(bool danger) : destructive(danger) {}
        void paintButton(Graphics &g, bool over, bool down) override {
            const auto bounds=getLocalBounds().toFloat().reduced(.5f);
            auto fill=destructive ? Colour(0xff893535) : Colour(0xff505050);
            if (over || down) fill=fill.brighter(down ? .05f : .12f);
            g.setColour(fill.withMultipliedAlpha(isEnabled() ? 1.f : .45f));
            g.fillRoundedRectangle(bounds, 6);
            if (destructive) { g.setColour(Colour(0xffed454a).withAlpha(isEnabled()?1.f:.45f)); g.drawRoundedRectangle(bounds,6,1); }
            g.setColour(Colours::white.withAlpha(isEnabled()?1.f:.5f));
            g.setFont(theme::font(13,destructive));
            g.drawFittedText(getButtonText(),getLocalBounds().reduced(6,0),Justification::centred,1);
        }
      private: bool destructive;
    };
    std::shared_ptr<ProjectDeletion> plan;
    std::function<void()> confirm;
    ActionButton cancel{false}, remove{true};
    bool working=false;
    String failure;
    void timerCallback() override {
        const int seconds=plan->remaining();
        remove.setButtonText(seconds>0 ? (localization::english ? "Delete in " : "Apagar em ")+String(seconds)+"s" : localization::translate("Delete project"));
        remove.setEnabled(seconds==0 && !working);
    }
};
} // namespace catlive
