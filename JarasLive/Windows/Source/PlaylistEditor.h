#pragma once
#include "Session.h"
#include "PlaylistOccurrences.h"
#include "Localization.h"
namespace catlive {
class PlaylistEditor final : public Component, private ListBoxModel {
  public:
    PlaylistEditor(const jaras::Song &song, const jaras::RegionPlaylist *existing,
                   std::function<void(jaras::RegionPlaylist)> save, std::function<void()> cancel, bool appendOnly = false)
        : commit(std::move(save)), close(std::move(cancel)), list("Playlist regions", this), adding(appendOnly) {
        playlist = existing ? *existing : jaras::RegionPlaylist{uuid(), {}, song.id, {}};
        editing = existing != nullptr;
        for (const auto &p : song.parts)
            if (!p.parentRegionID && (!adding || std::none_of(playlist.regionIds.begin(),playlist.regionIds.end(),[&](const auto &entry){return playlist.resolvedRegionId(entry)==p.id;})))
                regions.push_back(p);
        std::stable_sort(regions.begin(), regions.end(),
                         [](const auto &a, const auto &b) { return a.startTime < b.startTime; });
        addAndMakeVisible(list);
        list.setRowHeight(34);
        list.setMultipleSelectionEnabled(true);
        list.setColour(ListBox::backgroundColourId, theme::panel);
        addAndMakeVisible(name);
        name.setFont(theme::font(13));
        name.setTextToShowWhenEmpty("Nome da playlist", theme::secondary);
        name.setText(text(playlist.name));
        name.setComponentID("playlistName");
        setComponentID("playlistEditor");
        for (auto *b : {&all, &clear, &saveButton, &closeButton}) {
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
        }
        saveButton.getProperties().set("plain", false);
        saveButton.setColour(TextButton::buttonColourId, Colour(0xff3d7d56));
        saveButton.setButtonText(editing ? "Salvar" : "Criar");
        closeButton.getProperties().set("icon", "close");
        all.onClick = [this] {
            SparseSet<int> rows;
            rows.addRange({0, (int)regions.size()});
            list.setSelectedRows(rows);
        };
        clear.onClick = [this] { list.deselectAllRows(); };
        closeButton.onClick = this->close;
        saveButton.onClick = [this] {
            const auto title = name.getText().trim();
            if (title.isEmpty()) {
                name.grabKeyboardFocus();
                return;
            }
            auto result = playlist;
            result.name = utf8(title);
            std::set<ID> chosen;
            for (int i = 0; i < (int)regions.size(); ++i)
                if (list.isRowSelected(i))
                    chosen.insert(regions[(size_t)i].id);
            if(!adding) result.regionIds.erase(std::remove_if(result.regionIds.begin(), result.regionIds.end(),
                                                  [&](const ID &id) { return !chosen.count(result.resolvedRegionId(id)); }),
                                   result.regionIds.end());
            for (const auto &region : regions)
                if (chosen.count(region.id) &&
                    std::none_of(result.regionIds.begin(), result.regionIds.end(), [&](const auto &entry){return result.resolvedRegionId(entry)==region.id;}))
                    result.regionIds.push_back(region.id);
            playlistOccurrences::prune(result);
            commit(std::move(result));
        };
        name.onTextChange = [this] { update(); };
        name.onReturnKey = [this] { saveButton.triggerClick(); };
        list.updateContent();
        SparseSet<int> selection;
        for (int i = 0; i < (int)regions.size(); ++i)
            if (std::any_of(playlist.regionIds.begin(), playlist.regionIds.end(),
                          [&](const auto &entry){return playlist.resolvedRegionId(entry)==regions[(size_t)i].id;}))
                selection.addRange({i, i + 1});
        list.setSelectedRows(selection);
        update();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(13));
        g.drawText(adding ? "Adicionar regiões" : editing ? "Editar playlist" : "Nova playlist", 12, 8, getWidth() - 52, 28,
                   Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(10));
        g.drawText(String::fromUTF8("Ctrl: múltiplos · Shift: intervalo"), 12, 122, getWidth() - 24,
                   20, Justification::centredLeft);
        g.drawText(String(list.getNumSelectedRows()), 12, getHeight() - 42, 80, 30,
                   Justification::centredLeft);
    }
    void resized() override {
        closeButton.setBounds(getWidth() - 38, 8, 28, 28);
        name.setBounds(12, 46, getWidth() - 24, 26);
        all.setBounds(12, 84, 64, 28);
        clear.setBounds(80, 84, 64, 28);
        list.setBounds(8, 148, getWidth() - 16, std::max(1, getHeight() - 204));
        saveButton.setBounds(getWidth() - 78, getHeight() - 48, 66, 38);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey) {
            close();
            return true;
        }
        return false;
    }

  private:
    std::function<void(jaras::RegionPlaylist)> commit;
    std::function<void()> close;
    jaras::RegionPlaylist playlist;
    std::vector<jaras::Part> regions;
    bool editing = false, adding = false;
    ListBox list;
    TextEditor name;
    TextButton all{"Todas"}, clear{"Limpar"}, saveButton{"Criar"}, closeButton;
    int getNumRows() override { return (int)regions.size(); }
    void selectedRowsChanged(int) override { update(); }
    void update() {
        saveButton.setEnabled(name.getText().trim().isNotEmpty() && list.getNumSelectedRows() > 0);
        repaint();
    }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) override {
        if (row < 0 || row >= (int)regions.size())
            return;
        const auto &p = regions[(size_t)row];
        g.setColour(selected ? Colour(0xff214e70) : theme::background);
        g.fillRect(0, 1, width, height - 2);
        g.setColour(Colours::white);
        g.setFont(theme::font(12));
        auto title = text(p.name);
        if (p.uppercaseName.value_or(true))
            title = unicodeCase(title);
        g.drawFittedText(title, 8, 0, width - 66, height, Justification::centredLeft, 1);
        const int seconds = (int)(p.endTime - p.startTime);
        g.setFont(theme::semiboldFont(9));
        g.drawText((seconds >= 60 ? String(seconds / 60) + "m " : "") + String(seconds % 60) + "s",
                   width - 55, 0, 48, height, Justification::centredRight);
    }
};
class RegionEditor final : public Component {
  public:
    RegionEditor(String value, unsigned colour, bool uppercase,
                 std::function<void(String, unsigned, bool)> save, std::function<void()> close,
                 bool allowUppercase = true, bool allowName = true)
        : commit(std::move(save)), cancel(std::move(close)), showsUppercase(allowUppercase), showsName(allowName) {
        getProperties().set("selfContainedSheet", true);
        name.setComponentID("nameColourName");
        addAndMakeVisible(name); name.setVisible(showsName);
        name.setFont(theme::font(13));
        name.setText(value);
        name.selectAll();
        for (int i = 0; i < 3; ++i) {
            addAndMakeVisible(rgb[i]);
            rgb[i].setRange(0, 255, 1);
            rgb[i].setSliderStyle(Slider::LinearHorizontal);
            rgb[i].setTextBoxStyle(Slider::NoTextBox, true, 0, 0);
            rgb[i].setComponentID("nameColourRGB" + String(i));
            rgb[i].setColour(Slider::trackColourId, i == 0   ? Colour(0xffff5757)
                                                    : i == 1 ? Colour(0xff54dc79)
                                                             : Colour(0xff2796ff));
            rgb[i].onValueChange = [this] { setColourValue(colourValue()); };
        }
        setColourValue(colour);
        const uint32 palette[]{0x000000,0x414141,0x828282,0xbdbdbd,0xffffff,0xf44336,0xff6f00,0xffc107,
            0xffeb3b,0xb9e229,0x70d14d,0x00a65a,0x00cfa0,0x00c9c9,0x00a3e0,0x287bff,
            0x4a4ddb,0x7548dd,0xae40d6,0xe13db5,0xff6993,0xb84a56,0x9a613b,0xc7915e};
        for (auto c : palette) {
            auto *b = swatches.add(new TextButton());
            addAndMakeVisible(b);
            b->setColour(TextButton::buttonColourId, Colour(0xff000000u | c));
            b->getProperties().set("flat", true);
            b->setComponentID("nameColourSwatch" + String(swatches.size()-1));
            b->getProperties().set("colourSwatch", true);
            b->onClick = [this, c] { setColourValue(c); };
        }
        setColourValue(colour);
        addAndMakeVisible(upper);
        upper.setVisible(showsUppercase);
        upper.setButtonText("Caixa alta");
        upper.setToggleState(uppercase, dontSendNotification);
        for (auto *b : {&saveButton, &cancelButton}) {
            addAndMakeVisible(b);
            b->getProperties().set("flat", true);
        }
        saveButton.setColour(TextButton::buttonColourId, Colour(0xff63b641));
        cancelButton.setColour(TextButton::buttonColourId, Colour(0xff505050));
        saveButton.setComponentID("nameColourSave"); cancelButton.setComponentID("nameColourCancel");
        upper.setComponentID("nameColourUppercase");
        name.onTextChange = [this] { saveButton.setEnabled(name.getText().trim().isNotEmpty()); };
        saveButton.setEnabled(value.trim().isNotEmpty());
        cancelButton.onClick = cancel;
        saveButton.onClick = [this] {
            auto value = name.getText().trim();
            if (value.isNotEmpty())
                commit(value, colourValue(), upper.getToggleState());
        };
        name.onReturnKey = [this] { saveButton.triggerClick(); };
    }
    void visibilityChanged() override { if (isShowing() && showsName) name.grabKeyboardFocus(); }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white); g.setFont(theme::font(13,true));
        g.drawText(getName(),18,18,getWidth()-36,18,Justification::centredLeft);
        g.setColour(Colour(0xff000000u | colourValue()));
        g.fillRoundedRectangle(18,showsName ? 86 : 42,getWidth()-36.f,28,5);
        g.setFont(theme::font(13)); g.setColour(Colours::white);
        for(int i=0;i<3;++i) { g.drawText(String::charToString("RGB"[i]),18,(showsName ? 128 : 84)+i*30,14,20,Justification::centredLeft);
            g.drawText(String((int)rgb[i].getValue()),getWidth()-48,(showsName ? 128 : 84)+i*30,30,20,Justification::centredRight); }
    }
    bool keyPressed(const KeyPress &key) override { if(key==KeyPress::returnKey){saveButton.triggerClick();return true;} return false; }
    void resized() override {
        name.setBounds(18,50,getWidth()-36,22);
        for(int i=0;i<3;++i) rgb[i].setBounds(38,(showsName ? 128 : 84)+i*30,getWidth()-90,20);
        const float cell=(getWidth()-36-42)/8.f;
        for(int i=0;i<swatches.size();++i) swatches[i]->setBounds(roundToInt(18+(i%8)*(cell+6)),roundToInt((showsName ? 220 : 176)+(i/8)*(cell+6)),roundToInt(cell),roundToInt(cell));
        upper.setBounds(18,330,getWidth()-36,20);
        cancelButton.setBounds(18,getHeight()-42,78,24); saveButton.setBounds(getWidth()-80,getHeight()-42,62,24);
    }

  private:
    std::function<void(String, unsigned, bool)> commit;
    std::function<void()> cancel;
    bool showsUppercase;
    bool showsName;
    TextEditor name;
    ParameterSlider rgb[3];
    ToggleButton upper;
    OwnedArray<TextButton> swatches;
    TextButton saveButton{"Salvar"}, cancelButton{"Cancelar"};
    unsigned colourValue() const {
        return ((unsigned)rgb[0].getValue() << 16) | ((unsigned)rgb[1].getValue() << 8) |
               (unsigned)rgb[2].getValue();
    }
    void setColourValue(unsigned c) {
        for (int i = 0; i < 3; ++i)
            rgb[i].setValue((c >> (16 - i * 8)) & 255, dontSendNotification);
        for(auto *swatch:swatches) swatch->getProperties().set("selectedColour", (swatch->findColour(TextButton::buttonColourId).getARGB() & 0xffffff)==c);
        repaint();
    }
};
} // namespace catlive
