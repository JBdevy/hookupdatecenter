#pragma once
#include "Session.h"
#include "Localization.h"
namespace catlive {
class ProjectSavePanel final : public Component {
    Label title, error;
    TextEditor name;
    TextButton save, portable, reduce;
    std::function<void(String)> rename;
    std::function<void()> exportAction, reduceAction;
    void saveName() {
        try { rename(name.getText()); dismiss(); }
        catch (const std::exception &e) { error.setText(localization::translate(String::fromUTF8(e.what())), dontSendNotification); setSize(500,210); resized(); }
    }
    void dismiss() { if(auto *box=findParentComponentOfClass<CallOutBox>()) box->dismiss(); }
public:
    ProjectSavePanel(String current, std::function<void(String)> commit, std::function<void()> exportProject, std::function<void()> reduceProject)
      : rename(std::move(commit)), exportAction(std::move(exportProject)), reduceAction(std::move(reduceProject)) {
        title.setText(localization::translate("Project name"),dontSendNotification);
        name.setText(current,false); name.onReturnKey=[this]{saveName();};
        save.setButtonText(localization::translate("Save")); save.onClick=[this]{saveName();};
        portable.setButtonText(localization::translate(String::fromUTF8("Exportar para CatLive iPadOS")));
        portable.onClick=[this]{auto action=exportAction; dismiss(); MessageManager::callAsync(std::move(action));};
        reduce.setButtonText(localization::translate(String::fromUTF8("Reduzir projeto")));
        reduce.onClick=[this]{auto action=reduceAction;dismiss();MessageManager::callAsync(std::move(action));};
        error.setColour(Label::textColourId, Colours::indianred);
        for(Component *c : std::initializer_list<Component*>{&title,&name,&save,&portable,&reduce,&error})addAndMakeVisible(c);
        setSize(500,170);
    }
    void paint(Graphics &g) override { g.setColour(Colours::grey.withAlpha(.35f)); g.drawHorizontalLine(portable.getY()-8,14.f,(float)getWidth()-14); }
    void resized() override {
        auto r=getLocalBounds().reduced(14);
        title.setBounds(r.removeFromTop(25)); name.setBounds(r.removeFromTop(30)); r.removeFromTop(9);
        save.setBounds(r.removeFromTop(30).removeFromLeft(80));
        error.setBounds(r.removeFromTop(error.getText().isEmpty()?0:40)); r.removeFromTop(16);
        auto bottom=r.removeFromTop(30);reduce.setBounds(bottom.removeFromRight(140));bottom.removeFromRight(10);portable.setBounds(bottom);
    }
};
}
