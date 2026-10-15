#pragma once
#include "Common.h"
namespace catlive {
// Matches SidebarView: Projects opens a sheet; Live Session returns to the
// editor. The scrim intercepts timeline input while navigation is visible.
class NavigationPanel final : public Component {
  public:
    NavigationPanel(std::function<void()> projectsAction, std::function<void()> closeAction)
        : close(std::move(closeAction)) {
        setComponentID("navigation");
        setVisible(false);
        for (auto *button : {&projects, &live}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
            button->getProperties().set("plain", true);
            button->getProperties().set("flat", true);
            button->getProperties().set("fontSize", 11.f);
            button->getProperties().set("mediumWeight", true);
            button->getProperties().set("cornerRadius", 6.f);
            button->setColour(TextButton::textColourOffId, theme::secondary);
        }
        projects.setComponentID("navigationProjects");
        projects.getProperties().set("leadingIcon", "folder");
        projects.onClick = [this, projectsAction] { close(); projectsAction(); };
        live.setComponentID("navigationLive");
        live.getProperties().set("leadingIcon", "waveform");
        live.setToggleState(true, dontSendNotification);
        live.setColour(TextButton::buttonOnColourId, theme::accent.withAlpha(.12f));
        live.setColour(TextButton::textColourOnId, theme::accent);
        live.onClick = [this] { close(); };
    }
    void paint(Graphics &g) override {
        g.fillAll(Colours::black.withAlpha(.16f));
        DropShadow(Colours::black.withAlpha(.3f), 10, {4, 0})
            .drawForRectangle(g, {0, 0, 210, getHeight()});
        g.setColour(theme::background);
        g.fillRect(0, 0, 210, getHeight());
    }
    void resized() override {
        projects.setBounds(12, 12, 186, 38);
        live.setBounds(12, 58, 186, 38);
    }
    void mouseDown(const MouseEvent &event) override {
        if (event.x >= 210) close();
    }
  private:
    std::function<void()> close;
    TextButton projects{"Projetos"}, live{"Live Session"};
};
}
