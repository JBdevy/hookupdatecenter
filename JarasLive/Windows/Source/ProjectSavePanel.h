#pragma once
#include "Session.h"
#include "Localization.h"
namespace catlive {
class TimelineLockPanel final : public Component, private Timer {
    Label title;
    std::array<ToggleButton, 4> options;
    std::function<int()> read;
    std::function<void(int)> commit;
    static constexpr int masks[4] = {7, 1, 2, 4};
    void timerCallback() override {
        const int mask = read();
        for (int i=0;i<4;++i) options[(size_t)i].setToggleState((mask & masks[i]) == masks[i], dontSendNotification);
    }
public:
    TimelineLockPanel(std::function<int()> current, std::function<void(int)> changed)
      : read(std::move(current)), commit(std::move(changed)) {
        title.setText(localization::translate(String::fromUTF8("Bloqueios da grade")), dontSendNotification);
        addAndMakeVisible(title);
        const char *labels[] = {"Bloquear tudo", "Regiões e marcadores", "Itens", "Volume e pan dos itens"};
        for (int i=0;i<4;++i) {
            auto &button=options[(size_t)i];
            button.setButtonText(localization::translate(String::fromUTF8(labels[i])));
            button.onClick=[this,i] {
                const int mask=read(), bit=masks[i];
                commit(options[(size_t)i].getToggleState() ? mask | bit : mask & ~bit);
                timerCallback();
            };
            addAndMakeVisible(button);
        }
        setSize(320,196);timerCallback();startTimer(150);
    }
    void paint(Graphics &g) override { g.setColour(Colours::grey.withAlpha(.35f));g.drawHorizontalLine(85,14.f,(float)getWidth()-14); }
    void resized() override {
        auto r=getLocalBounds().reduced(14);title.setBounds(r.removeFromTop(28));
        for(int i=0;i<4;++i) { if(i==1)r.removeFromTop(12);options[(size_t)i].setBounds(r.removeFromTop(31)); }
    }
};
class ProjectSavePanel final : public Component {
    Label title, error;
    TextEditor name;
    TextButton save, portable, reduce;
    std::function<void(String)> rename;
    std::function<void()> exportAction, reduceAction;
    void saveName() {
        try { rename(name.getText()); dismiss(); }
        catch (const std::exception &e) { error.setText(localization::translate(String::fromUTF8(e.what())), dontSendNotification); setSize(500,212); resized(); }
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
        setSize(500,172);
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
