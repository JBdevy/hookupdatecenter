#pragma once
#include "Session.h"
#include "Localization.h"
namespace catlive {
class ProjectSavePanel final : public Component {
    Label title, error;
    TextEditor name;
    TextButton save, portable;
    std::function<void(String)> rename;
    std::function<void()> exportAction;
    void saveName() {
        try { rename(name.getText()); dismiss(); }
        catch (const std::exception &e) { error.setText(localization::translate(String::fromUTF8(e.what())), dontSendNotification); setSize(350,210); resized(); }
    }
    void dismiss() { if(auto *box=findParentComponentOfClass<CallOutBox>()) box->dismiss(); }
public:
    ProjectSavePanel(String current, std::function<void(String)> commit, std::function<void()> exportProject)
      : rename(std::move(commit)), exportAction(std::move(exportProject)) {
        title.setText(localization::translate("Project name"),dontSendNotification);
        name.setText(current,false); name.onReturnKey=[this]{saveName();};
        save.setButtonText("Save"); save.onClick=[this]{saveName();};
        portable.setButtonText(localization::translate(String::fromUTF8("Exportar para CatLive iPadOS")));
        portable.onClick=[this]{auto action=exportAction; dismiss(); MessageManager::callAsync(std::move(action));};
        error.setColour(Label::textColourId, Colours::indianred);
        for(Component *c : std::initializer_list<Component*>{&title,&name,&save,&portable,&error})addAndMakeVisible(c);
        setSize(350,170);
    }
    void paint(Graphics &g) override { g.setColour(Colours::grey.withAlpha(.35f)); g.drawHorizontalLine(portable.getY()-8,14.f,(float)getWidth()-14); }
    void resized() override {
        auto r=getLocalBounds().reduced(14);
        title.setBounds(r.removeFromTop(25)); name.setBounds(r.removeFromTop(30)); r.removeFromTop(9);
        save.setBounds(r.removeFromTop(30).removeFromLeft(80));
        error.setBounds(r.removeFromTop(error.getText().isEmpty()?0:40)); r.removeFromTop(16);
        portable.setBounds(r.removeFromTop(30));
    }
};
}
