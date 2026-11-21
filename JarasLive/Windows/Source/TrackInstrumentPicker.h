#pragma once
#include "Localization.h"
#include "TrackInstrumentArtwork.h"
#include "ModalSheet.h"
namespace catlive {
class TrackInstrumentPicker final : public Component {
    class Choice final : public Button {
    public:
        const std::string icon;
        bool selected = false;
        Choice(std::string id, String title) : Button(std::move(title)), icon(std::move(id)) {
            setComponentID("trackIcon:" + catlive::text(icon));
        }
        void paintButton(Graphics &g,bool over,bool down) override {
            const auto r=getLocalBounds().toFloat().reduced(1);
            g.setColour(selected?theme::green.withAlpha(.25f):Colours::white.withAlpha(over||down?.12f:.06f));
            g.fillRoundedRectangle(r,5);
            if(selected){g.setColour(theme::green);g.drawRoundedRectangle(r,5,1.5f);}
            const auto artwork=juce::Rectangle<float>(6,6,getWidth()-12.f,38);
            {
                Graphics::ScopedSaveState imageState(g);
                g.setOpacity(1.0f);
                g.setImageResamplingQuality(Graphics::highResamplingQuality);
                trackIcons::draw(g, icon, artwork);
            }
            g.setColour(Colours::white);g.setFont(theme::font(10));
            g.drawFittedText(getName(),4,47,getWidth()-8,17,Justification::centred,1,.7f);
        }
    };
    String trackName;
    std::optional<std::string> value;
    std::function<void(std::optional<std::string>)> save;
    Viewport viewport;
    Component grid;
    OwnedArray<Choice> choices;
    OwnedArray<QuietButton> categories;
    size_t category = 0, rasterCount = 0;
    QuietButton cancel{localization::translate("Cancelar")}, apply{localization::translate("Salvar")},
        clear{localization::translate(String::fromUTF8("Sem ícone"))};

    void refreshSelection() {
        for (auto *choice : choices) {
            choice->selected = value == choice->icon;
            choice->repaint();
        }
        clear.setToggleState(!value, dontSendNotification);
    }
    void selectCategory(size_t index) {
        category = index;
        for (int i = 0; i < categories.size(); ++i)
            categories[i]->setToggleState(size_t(i) == category, dontSendNotification);
        choices.clear();
        const auto &group = trackIcons::categories()[category];
        auto add = [&](std::string id, String title) {
            auto *choice = choices.add(new Choice(std::move(id), std::move(title)));
            grid.addAndMakeVisible(choice);
            choice->onClick = [this, choice] { value = choice->icon; refreshSelection(); };
        };
        for (const auto &entry : group.artwork) add(utf8(entry.id), entry.title);
        rasterCount = size_t(choices.size());
        for (const auto &key : group.legacy)
            if (const auto *icon = trackIcons::find(utf8(key))) add(icon->id, String::fromUTF8(icon->title));
        refreshSelection();
        resized();
        viewport.setViewPosition(0, 0);
    }

public:
    TrackInstrumentPicker(String name,std::optional<std::string> initial,std::function<void(std::optional<std::string>)> action)
        :trackName(std::move(name)),value(std::move(initial)),save(std::move(action)) {
        setComponentID("trackInstrumentPicker");setWantsKeyboardFocus(true);
        getProperties().set("selfContainedSheet",true);
        addAndMakeVisible(viewport);viewport.setViewedComponent(&grid,false);viewport.setScrollBarsShown(true,false);viewport.setScrollBarThickness(8);
        size_t initialCategory = 0;
        const auto &groups = trackIcons::categories();
        for (size_t i = 0; i < groups.size(); ++i) {
            const auto &group = groups[i];
            auto *button = categories.add(new QuietButton(group.name));
            button->setComponentID("trackIconCategory:" + group.name);
            button->onClick = [this, i] { selectCategory(i); };
            addAndMakeVisible(button);
            if (value && (group.legacy.contains(text(*value)) ||
                std::any_of(group.artwork.begin(), group.artwork.end(), [&](const auto &artwork) { return artwork.id == text(*value); })))
                initialCategory = i;
        }
        for (auto *button : {&cancel, &clear, &apply}) {
            addAndMakeVisible(button);
            button->setColour(TextButton::buttonColourId,theme::accent);
        }
        clear.setComponentID("trackIcon:none");
        clear.onClick = [this] { value.reset(); refreshSelection(); };
        selectCategory(initialCategory);
        cancel.setComponentID("trackIconCancel");apply.setComponentID("trackIconSave");
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        apply.onClick=[this]{auto action=save;auto selected=value;ModalSheet::dismiss(*this);action(selected);};
    }
    ~TrackInstrumentPicker() override {viewport.setViewedComponent(nullptr,false);}
    void paint(Graphics &g) override {
        g.setColour(theme::panel);g.fillRoundedRectangle(getLocalBounds().toFloat(),16);
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(18));g.drawText(String::fromUTF8("Ícone da pista"),22,18,getWidth()-44,26,Justification::centredLeft);
        g.setColour(theme::secondary);g.setFont(theme::font(11));g.drawText(trackName,22,52,getWidth()-44,20,Justification::centredLeft);
    }
    void resized() override {
        const int navigationWidth = 106, contentTop = 78;
        for (int i = 0; i < categories.size(); ++i)
            categories[i]->setBounds(22, contentTop + i * 27, navigationWidth, 25);
        viewport.setBounds(22 + navigationWidth + 10, contentTop, getWidth() - 54 - navigationWidth, std::max(50, getHeight() - 146));
        constexpr int columns = 5, gap = 6, rowHeight = 69;
        const int width = std::max(1, (viewport.getWidth() - 8 - (columns - 1) * gap) / columns);
        const int pngRows = (int(rasterCount) + columns - 1) / columns;
        const int legacyTop = pngRows * rowHeight + (rasterCount && rasterCount < size_t(choices.size()) ? 10 : 0);
        grid.setSize(std::max(1, viewport.getWidth() - 8), legacyTop + ((choices.size() - int(rasterCount) + columns - 1) / columns) * rowHeight);
        for (int i = 0; i < choices.size(); ++i) {
            const bool legacy = size_t(i) >= rasterCount;
            const int index = legacy ? i - int(rasterCount) : i;
            choices[i]->setBounds((index % columns) * (width + gap), (legacy ? legacyTop : 0) + (index / columns) * rowHeight, width, 63);
        }
        cancel.setBounds(22,getHeight()-50,84,30);
        clear.setBounds(114,getHeight()-50,84,30);
        apply.setBounds(getWidth()-106,getHeight()-50,84,30);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::returnKey){apply.onClick();return true;}
        if(key==KeyPress::escapeKey){cancel.onClick();return true;}return false;
    }
};
}
