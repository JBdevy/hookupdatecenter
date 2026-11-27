#pragma once
#include "Session.h"
#include "Localization.h"
namespace catlive {
class TimelineLockPanel final : public Component, private Timer {
    Label title;
    std::array<ToggleButton, 6> options;
    std::function<int()> read;
    std::function<void(int)> commit;
    static constexpr int masks[] = {jaras::TimelineLocks::all, jaras::TimelineLocks::regions,
        jaras::TimelineLocks::itemPosition, jaras::TimelineLocks::itemVolume, jaras::TimelineLocks::itemPan,
        jaras::TimelineLocks::itemMute};
    void timerCallback() override {
        const int mask = read();
        for (size_t i=0;i<options.size();++i) options[i].setToggleState((mask & masks[i]) == masks[i], dontSendNotification);
    }
public:
    TimelineLockPanel(std::function<int()> current, std::function<void(int)> changed)
      : read(std::move(current)), commit(std::move(changed)) {
        title.setText(localization::translate(String::fromUTF8("Bloqueios da grade")), dontSendNotification);
        addAndMakeVisible(title);
        const char *labels[] = {"Bloquear tudo", "Regiões e marcadores", "Posição dos itens", "Volume dos itens", "Pan dos itens", "Mute dos itens"};
        for (size_t i=0;i<options.size();++i) {
            auto &button=options[i];
            button.setButtonText(localization::translate(String::fromUTF8(labels[i])));
            button.onClick=[this,i] {
                const int mask=read(), bit=masks[i];
                commit(options[i].getToggleState() ? mask | bit : mask & ~bit);
                timerCallback();
            };
            addAndMakeVisible(button);
        }
        setSize(320, 258); timerCallback(); startTimer(150);
    }
    void paint(Graphics &g) override { g.setColour(Colours::grey.withAlpha(.35f));g.drawHorizontalLine((float)options[0].getBottom() + 6, 14.f, (float)getWidth() - 14); }
    void resized() override {
        auto r=getLocalBounds().reduced(14);title.setBounds(r.removeFromTop(28));
        for(size_t i=0;i<options.size();++i) { if(i==1)r.removeFromTop(12);options[i].setBounds(r.removeFromTop(31)); }
    }
};
class ProjectSavePanel final : public Component {
    Label title, error;
    TextEditor name;
    TextButton save, portable, reduce;
    std::function<void(String)> rename;
    std::function<void()> shareAction, reduceAction;
    void saveName() {
        try { rename(name.getText()); dismiss(); }
        catch (const std::exception &e) { error.setText(localization::translate(String::fromUTF8(e.what())), dontSendNotification); setSize(500,212); resized(); }
    }
    void dismiss() { if(auto *box=findParentComponentOfClass<CallOutBox>()) box->dismiss(); }
public:
    ProjectSavePanel(String current, std::function<void(String)> commit, std::function<void()> shareProject, std::function<void()> reduceProject)
      : rename(std::move(commit)), shareAction(std::move(shareProject)), reduceAction(std::move(reduceProject)) {
        title.setText(localization::translate("Project name"),dontSendNotification);
        name.setText(current,false); name.onReturnKey=[this]{saveName();};
        save.setButtonText(localization::translate("Save")); save.onClick=[this]{saveName();};
        portable.setButtonText("Share");
        portable.onClick=[this]{auto action=shareAction; dismiss(); MessageManager::callAsync(std::move(action));};
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
