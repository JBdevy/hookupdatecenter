#pragma once
#include "Session.h"
#include "Localization.h"
namespace catlive {
class PlaylistEditor final : public Component, private ListBoxModel {
  public:
    PlaylistEditor(const jaras::Song &song, const jaras::RegionPlaylist *existing,
                   std::function<void(jaras::RegionPlaylist)> save, std::function<void()> cancel)
        : commit(std::move(save)), close(std::move(cancel)), list("Playlist regions", this) {
        playlist = existing ? *existing : jaras::RegionPlaylist{uuid(), {}, song.id, {}};
        editing = existing != nullptr;
        for (const auto &p : song.parts)
            if (!p.parentRegionID)
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
            result.regionIds.erase(std::remove_if(result.regionIds.begin(), result.regionIds.end(),
                                                  [&](const ID &id) { return !chosen.count(id); }),
                                   result.regionIds.end());
            for (const auto &region : regions)
                if (chosen.count(region.id) &&
                    std::find(result.regionIds.begin(), result.regionIds.end(), region.id) ==
                        result.regionIds.end())
                    result.regionIds.push_back(region.id);
            commit(std::move(result));
        };
        name.onTextChange = [this] { update(); };
        name.onReturnKey = [this] { saveButton.triggerClick(); };
        list.updateContent();
        SparseSet<int> selection;
        for (int i = 0; i < (int)regions.size(); ++i)
            if (std::find(playlist.regionIds.begin(), playlist.regionIds.end(),
                          regions[(size_t)i].id) != playlist.regionIds.end())
                selection.addRange({i, i + 1});
        list.setSelectedRows(selection);
        update();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(13));
        g.drawText(editing ? "Editar playlist" : "Nova playlist", 12, 8, getWidth() - 52, 28,
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
    bool editing = false;
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
                 bool allowUppercase = true)
        : commit(std::move(save)), cancel(std::move(close)), showsUppercase(allowUppercase) {
        addAndMakeVisible(name);
        name.setFont(theme::font(13));
        name.setText(value);
        name.selectAll();
        for (int i = 0; i < 3; ++i) {
            addAndMakeVisible(rgb[i]);
            rgb[i].setRange(0, 255, 1);
            rgb[i].setSliderStyle(Slider::LinearHorizontal);
            rgb[i].setTextBoxStyle(Slider::TextBoxRight, false, 36, 22);
            rgb[i].setColour(Slider::trackColourId, i == 0   ? Colour(0xffff5757)
                                                    : i == 1 ? Colour(0xff54dc79)
                                                             : Colour(0xff2796ff));
            rgb[i].onValueChange = [this] { repaint(); };
        }
        setColourValue(colour);
        const uint32 palette[]{0x000000, 0x404040, 0x808080, 0xbfbfbf, 0xffffff, 0xf44336,
                               0xff7800, 0xffc300, 0xffed44, 0xc2df21, 0x70c83e, 0x00a967,
                               0x00c59b, 0x00c1c2, 0x00a3d7, 0x2979ff, 0x5345d5, 0x7e42dd,
                               0xb13cd3, 0xdc36b1, 0xff669c, 0xb24b5c, 0x996037, 0xc39563};
        for (auto c : palette) {
            auto *b = swatches.add(new TextButton());
            addAndMakeVisible(b);
            b->setColour(TextButton::buttonColourId, Colour(0xff000000u | c));
            b->getProperties().set("flat", true);
            b->onClick = [this, c] { setColourValue(c); };
        }
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
        cancelButton.onClick = cancel;
        saveButton.onClick = [this] {
            auto value = name.getText().trim();
            if (value.isNotEmpty())
                commit(value, colourValue(), upper.getToggleState());
        };
        name.onReturnKey = [this] { saveButton.triggerClick(); };
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colour(0xff000000u | colourValue()));
        g.fillRoundedRectangle(16, 46, getWidth() - 32.f, 28, 5);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        for (int i = 0; i < 3; ++i)
            g.drawText(String::charToString("RGB"[i]), 18, 84 + i * 30, 16, 24,
                       Justification::centredLeft);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::returnKey){saveButton.triggerClick();return true;}
        return false;
    }
    void resized() override {
        name.setBounds(16, 8, getWidth() - 32, 26);
        for (int i = 0; i < 3; ++i)
            rgb[i].setBounds(34, 84 + i * 30, getWidth() - 50, 24);
        const int cell = (getWidth() - 32) / 8;
        for (int i = 0; i < swatches.size(); ++i)
            swatches[i]->setBounds(16 + i % 8 * cell, 178 + i / 8 * 34, cell - 5, 28);
        upper.setBounds(14, 286, getWidth() - 28, 26);
        cancelButton.setBounds(16, getHeight() - 38, 80, 25);
        saveButton.setBounds(getWidth() - 80, getHeight() - 38, 64, 25);
    }

  private:
    std::function<void(String, unsigned, bool)> commit;
    std::function<void()> cancel;
    bool showsUppercase;
    TextEditor name;
    Slider rgb[3];
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
        repaint();
    }
};
} // namespace catlive
