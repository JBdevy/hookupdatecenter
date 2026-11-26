#pragma once
#include "Session.h"
#include "PlaylistOccurrences.h"
#include "Localization.h"
#include "SetlistSearch.h"
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
        list.setClickingTogglesRowSelection(true);
        list.setComponentID("playlistSongs");
        list.setColour(ListBox::backgroundColourId, theme::panel);
        addAndMakeVisible(name);
        name.setFont(theme::font(13));
        name.setTextToShowWhenEmpty(localization::translate("Nome da playlist"), theme::secondary);
        name.setText(text(playlist.name));
        name.setComponentID("playlistName");
        setComponentID("playlistEditor");
        addAndMakeVisible(search);
        search.setFont(theme::font(13));
        search.setTextToShowWhenEmpty(localization::translate("Search songs"),theme::secondary);
        search.setComponentID("playlistSearch");
        search.onTextChange=[this]{filterRows();};
        addAndMakeVisible(searchIcon);
        searchIcon.getProperties().set("icon","search");
        searchIcon.getProperties().set("plain",true);
        searchIcon.onClick=[this]{search.grabKeyboardFocus();};
        for (auto *b : {&all, &clear, &saveButton, &closeButton}) {
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
        }
        saveButton.setComponentID("playlistSave");
        saveButton.getProperties().set("plain", false);
        saveButton.setColour(TextButton::buttonColourId, Colour(0xff3d7d56));
        saveButton.setButtonText(editing ? localization::translate("Salvar") : localization::translate("Criar"));
        closeButton.getProperties().set("icon", "close");
        all.onClick = [this] {
            for(auto index:visibleRows)choose(regions[index].id);
            syncSelection();
        };
        clear.onClick = [this] { chosen.clear();syncSelection(); };
        closeButton.onClick = this->close;
        saveButton.onClick = [this] {
            const auto title = name.getText().trim();
            if (title.isEmpty()) {
                name.grabKeyboardFocus();
                return;
            }
            auto result = playlist;
            result.name = utf8(title);
            if(!adding) result.regionIds.erase(std::remove_if(result.regionIds.begin(), result.regionIds.end(),
                                                  [&](const ID &id) { return !isChosen(result.resolvedRegionId(id)); }),
                                   result.regionIds.end());
            for (const auto &id : chosen)
                if (std::none_of(result.regionIds.begin(), result.regionIds.end(), [&](const auto &entry){return result.resolvedRegionId(entry)==id;}))
                    result.regionIds.push_back(id);
            playlistOccurrences::prune(result);
            commit(std::move(result));
        };
        name.onTextChange = [this] { update(); };
        name.onReturnKey = [this] { saveButton.triggerClick(); };
        for(const auto &region:regions)
            if(std::any_of(playlist.regionIds.begin(),playlist.regionIds.end(),[&](const auto &entry){return playlist.resolvedRegionId(entry)==region.id;}))choose(region.id);
        filterRows();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(13));
        g.drawText(adding ? localization::translate(String::fromUTF8("Adicionar regiões")) : editing ? localization::translate("Editar playlist") : localization::translate("Nova playlist"), 12, 8, getWidth() - 52, 28,
                   Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(10));
        g.drawText(String((int)chosen.size()), 12, getHeight() - 42, 80, 30,
                   Justification::centredLeft);
    }
    void resized() override {
        closeButton.setBounds(getWidth() - 38, 8, 28, 28);
        name.setBounds(12, 46, getWidth() - 24, 26);
        all.setBounds(12, 84, 64, 28);
        clear.setBounds(80, 84, 64, 28);
        searchIcon.setBounds(12,120,24,26);
        search.setBounds(40,120,getWidth()-52,26);
        list.setBounds(8, 154, getWidth() - 16, std::max(1, getHeight() - 210));
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
    TextEditor name,search;
    TextButton searchIcon;
    std::vector<size_t> visibleRows;
    std::vector<ID> chosen;
    bool isChosen(const ID &id) const { return std::find(chosen.begin(),chosen.end(),id)!=chosen.end(); }
    void choose(const ID &id) { if(!isChosen(id))chosen.push_back(id); }
    bool filtering=false;
    TextButton all{localization::translate("Todas")}, clear{localization::translate("Limpar")}, saveButton{localization::translate("Criar")}, closeButton;
    int getNumRows() override { return (int)visibleRows.size(); }
    void selectedRowsChanged(int) override {
        if(filtering)return;
        for(size_t row=0;row<visibleRows.size();++row) {
            const auto &id=regions[visibleRows[row]].id;
            if(list.isRowSelected((int)row))choose(id);else chosen.erase(std::remove(chosen.begin(),chosen.end(),id),chosen.end());
        }
        update();
    }
    void syncSelection() {
        SparseSet<int> rows;
        for(int row=0;row<(int)visibleRows.size();++row)
            if(isChosen(regions[visibleRows[(size_t)row]].id))rows.addRange({row,row+1});
        list.setSelectedRows(rows,dontSendNotification);
        update();
    }
    void filterRows() {
        const ScopedValueSetter<bool> guard(filtering,true);
        visibleRows.clear();
        const auto query=search.getText().trim();
        for(size_t index=0;index<regions.size();++index)
            if(setlistSearch::nameContains(text(regions[index].name),query))visibleRows.push_back(index);
        list.updateContent();syncSelection();
    }
    void update() {
        saveButton.setEnabled(name.getText().trim().isNotEmpty() && !chosen.empty());
        repaint();
    }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) override {
        if (row < 0 || row >= (int)visibleRows.size())
            return;
        const auto &p = regions[visibleRows[(size_t)row]];
        g.setColour(selected ? Colour(0xff214e70) : theme::background);
        g.fillRect(0, 1, width, height - 2);
        g.setColour(Colours::white);
        g.setFont(theme::font(12));
        auto title = text(p.name);
        if (p.uppercaseName.value_or(true))
            title = unicodeCase(title);
        const auto order=std::find(chosen.begin(),chosen.end(),p.id);
        const int nameLeft=order==chosen.end()?8:34;
        if(order!=chosen.end()) {
            g.setColour(theme::green);
            g.drawText(String((int)std::distance(chosen.begin(),order)+1),8,0,22,height,Justification::centredLeft);
            g.setColour(Colours::white);
        }
        g.drawFittedText(title, nameLeft, 0, width-nameLeft-58, height, Justification::centredLeft, 1);
        const int seconds = (int)(p.endTime - p.startTime);
        g.setFont(theme::semiboldFont(9));
        g.drawText((seconds >= 60 ? String(seconds / 60) + "m " : "") + String(seconds % 60) + "s",
                   width - 55, 0, 48, height, Justification::centredRight);
    }
};
class RegionEditor final : public Component {
  public:
    std::function<void(unsigned)> previewColour;
    std::function<void()> finishPreview;
    ~RegionEditor() override {
        if(!confirmed && previewColour)previewColour(originalColour);
        if(finishPreview)finishPreview();
    }
    RegionEditor(String value, unsigned colour, bool uppercase,
                 std::function<void(String, unsigned, bool)> save, std::function<void()> close,
                 bool allowUppercase = true, bool allowName = true)
        : commit(std::move(save)), cancel(std::move(close)), showsUppercase(allowUppercase), showsName(allowName), originalColour(colour) {
        getProperties().set("selfContainedSheet", true);
        setWantsKeyboardFocus(showsName);
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
        upper.setButtonText(localization::translate("Caixa alta"));
        upper.setToggleState(uppercase, dontSendNotification);
        for (auto *b : {&saveButton, &cancelButton}) {
            addAndMakeVisible(b);
            b->getProperties().set("flat", true);
        }
        saveButton.setColour(TextButton::buttonColourId, Colour(0xff63b641));
        cancelButton.setColour(TextButton::buttonColourId, Colour(0xff505050));
        saveButton.setComponentID("nameColourSave"); cancelButton.setComponentID("nameColourCancel");
        upper.setComponentID("nameColourUppercase");
        name.onTextChange = [this] { saveButton.setEnabled(!showsName || name.getText().trim().isNotEmpty()); };
        saveButton.setEnabled(!showsName || value.trim().isNotEmpty());
        cancelButton.onClick = cancel;
        saveButton.onClick = [this] {
            auto value = name.getText().trim();
            if (!showsName || value.isNotEmpty()) {
                confirmed=true;commit(value, colourValue(), upper.getToggleState());
            }
        };
        name.onReturnKey = [this] { saveButton.triggerClick(); };
    }
    void visibilityChanged() override { if (isShowing() && showsName) name.grabKeyboardFocus(); }
    // ModalSheet becomes modal after adding its content, which takes focus
    // away from the editor's visibilityChanged callback. Forward that final
    // modal focus to the name so shortcut-created markers accept typing.
    void focusGained(FocusChangeType) override {
        if (showsName) { name.grabKeyboardFocus(); name.selectAll(); }
    }
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
    unsigned originalColour;
    bool confirmed=false;
    TextEditor name;
    ParameterSlider rgb[3];
    ToggleButton upper;
    OwnedArray<TextButton> swatches;
    TextButton saveButton{localization::translate("Salvar")}, cancelButton{localization::translate("Cancelar")};
    unsigned colourValue() const {
        return ((unsigned)rgb[0].getValue() << 16) | ((unsigned)rgb[1].getValue() << 8) |
               (unsigned)rgb[2].getValue();
    }
    void setColourValue(unsigned c) {
        for (int i = 0; i < 3; ++i)
            rgb[i].setValue((c >> (16 - i * 8)) & 255, dontSendNotification);
        for(auto *swatch:swatches) swatch->getProperties().set("selectedColour", (swatch->findColour(TextButton::buttonColourId).getARGB() & 0xffffff)==c);
        if(previewColour)previewColour(c);
        repaint();
    }
};
} // namespace catlive
