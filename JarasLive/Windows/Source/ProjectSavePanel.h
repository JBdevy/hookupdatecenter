#pragma once
#include "Session.h"
#include "Localization.h"
namespace catlive {
class ProjectSavePanel final : public Component {
    Label title, error;
    TextEditor name;
    TextButton save, portable, reduce, partial;
    std::function<void(String)> rename;
    std::function<void()> exportAction, reduceAction, partialAction;
    void saveName() {
        try { rename(name.getText()); dismiss(); }
        catch (const std::exception &e) { error.setText(localization::translate(String::fromUTF8(e.what())), dontSendNotification); setSize(500,250); resized(); }
    }
    void dismiss() { if(auto *box=findParentComponentOfClass<CallOutBox>()) box->dismiss(); }
public:
    ProjectSavePanel(String current, std::function<void(String)> commit, std::function<void()> exportProject, std::function<void()> reduceProject, std::function<void()> exportPartial)
      : rename(std::move(commit)), exportAction(std::move(exportProject)), reduceAction(std::move(reduceProject)), partialAction(std::move(exportPartial)) {
        title.setText(localization::translate("Project name"),dontSendNotification);
        name.setText(current,false); name.onReturnKey=[this]{saveName();};
        save.setButtonText(localization::translate("Save")); save.onClick=[this]{saveName();};
        portable.setButtonText(localization::translate(String::fromUTF8("Exportar para CatLive iPadOS")));
        portable.onClick=[this]{auto action=exportAction; dismiss(); MessageManager::callAsync(std::move(action));};
        reduce.setButtonText(localization::translate(String::fromUTF8("Reduzir projeto")));
        reduce.onClick=[this]{auto action=reduceAction;dismiss();MessageManager::callAsync(std::move(action));};
        partial.setButtonText("Export Partial");
        partial.onClick=[this]{auto action=partialAction;dismiss();MessageManager::callAsync(std::move(action));};
        error.setColour(Label::textColourId, Colours::indianred);
        for(Component *c : std::initializer_list<Component*>{&title,&name,&save,&portable,&reduce,&partial,&error})addAndMakeVisible(c);
        setSize(500,210);
    }
    void paint(Graphics &g) override { g.setColour(Colours::grey.withAlpha(.35f)); g.drawHorizontalLine(portable.getY()-8,14.f,(float)getWidth()-14); }
    void resized() override {
        auto r=getLocalBounds().reduced(14);
        title.setBounds(r.removeFromTop(25)); name.setBounds(r.removeFromTop(30)); r.removeFromTop(9);
        save.setBounds(r.removeFromTop(30).removeFromLeft(80));
        error.setBounds(r.removeFromTop(error.getText().isEmpty()?0:40)); r.removeFromTop(16);
        partial.setBounds(r.removeFromTop(30)); r.removeFromTop(8);
        auto bottom=r.removeFromTop(30);reduce.setBounds(bottom.removeFromRight(140));bottom.removeFromRight(10);portable.setBounds(bottom);
    }
};
}
