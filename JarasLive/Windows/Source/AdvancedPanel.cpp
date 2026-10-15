#include "AdvancedPanel.h"
#include "MediaCleanupPanel.h"
#include "ModalSheet.h"
namespace catlive {
namespace {
const char *colourKeys[]{"jaras.setlist.allRegionsTextColor", "jaras.setlist.playlistTextColor",
                         "jaras.setlist.unifiedTextColor"};
constexpr uint32 colourDefaults[]{0xffffff, 0x00ff9a, 0xffeb3b};
class ColourEditor final : public Component {
  public:
    ColourEditor(Colour initial, std::function<void(Colour)> commit)
        : selected(initial), save(std::move(commit)),
          selector(ColourSelector::showColourAtTop | ColourSelector::showSliders |
                   ColourSelector::showColourspace) {
        addAndMakeVisible(selector);
        selector.setCurrentColour(selected, dontSendNotification);
        selector.setColour(ColourSelector::backgroundColourId, theme::panel);
        addAndMakeVisible(apply);
        apply.onClick = [this] {
            save(selector.getCurrentColour().withAlpha(1.f));
            if (auto *callout = findParentComponentOfClass<CallOutBox>())
                callout->dismiss();
        };
        setSize(300, 340);
    }
    void resized() override {
        selector.setBounds(getLocalBounds().withTrimmedBottom(44));
        apply.setBounds(getWidth() - 94, getHeight() - 36, 82, 26);
    }

  private:
    Colour selected;
    std::function<void(Colour)> save;
    ColourSelector selector;
    TextButton apply{"Save"};
};
} // namespace
AdvancedPanel::AdvancedPanel(Appearance &settings, Session &value, std::function<void(String)> fail)
    : appearance(settings), session(value), error(std::move(fail)) {
    setName("Advanced");
    const StringArray names{String::fromUTF8("Tempo do projeto"),
                            "Timeline",
                            "Gravar",
                            String::fromUTF8("Re-renderizar"),
                            String::fromUTF8("Vídeo"),
                            "Setlist"};
    for (int i = 0; i < names.size(); ++i) {
        auto *tab = tabs.add(new TextButton(names[i]));
        addAndMakeVisible(tab);
        tab->setName(names[i]);
        tab->setComponentID("advancedTab" + String(i));
        tab->getProperties().set("flat", true);
        tab->getProperties().set("plain", true);
        tab->getProperties().set("fontSize", 13);
        tab->setColour(TextButton::buttonOnColourId, theme::green.withAlpha(.15f));
        tab->setColour(TextButton::textColourOnId, Colours::white);
        const char *icons[]{"clock", "grid", "record", "waveform", "video", "setlist"};
        tab->getProperties().set("leadingIcon", icons[i]);
        tab->onClick = [this, i] { select(i); };
    }
    addAndMakeVisible(viewport);
    viewport.setViewedComponent(&page, false);
    viewport.setScrollBarsShown(true, false);
    viewport.setScrollBarThickness(8);
    for (auto *button : {&close, &apply}) {
        addAndMakeVisible(button);
        button->getProperties().set("flat", true);
    }
    apply.setColour(TextButton::buttonColourId, Colour(0xff60b746));
    close.setColour(TextButton::buttonColourId, Colour(0xff505050));
    close.onClick = [this] { ModalSheet::dismiss(*this); };
    apply.onClick = [this] { applyTiming(); };
    select(0);
}
void AdvancedPanel::save(const String &key, var value) {
    auto result = appearance.set(key, std::move(value));
    if (result.failed())
        error(result.getErrorMessage());
}
Label &AdvancedPanel::label(const String &name, int x, int y, int width, int height, bool bold) {
    auto *field = new Label();
    fields.add(field);
    page.addAndMakeVisible(field);
    field->setText(name, dontSendNotification);
    field->setFont(theme::font(bold ? 16.f : 13.f, bold));
    field->setBounds(x, y, width, height);
    return *field;
}
ComboBox &AdvancedPanel::choice(const String &name, const StringArray &items, int current, int x,
                                int y, int width, std::function<void(int)> changed) {
    auto *field = new ComboBox();
    fields.add(field);
    page.addAndMakeVisible(field);
    field->setName(name);
    field->addItemList(items, 1);
    field->setSelectedId(current, dontSendNotification);
    field->setBounds(x, y, width, 24);
    field->onChange = [field, changed] { changed(field->getSelectedId()); };
    return *field;
}
ToggleButton &AdvancedPanel::toggle(const String &name, const String &key, bool fallback, int y) {
    auto *field = new ToggleButton(name);
    fields.add(field);
    page.addAndMakeVisible(field);
    field->setBounds(18, y, 550, 26);
    field->setToggleState((bool)appearance.value(key, fallback), dontSendNotification);
    field->onClick = [this, field, key] { save(key, field->getToggleState()); };
    return *field;
}
void AdvancedPanel::colourRow(const String &name, const String &key, uint32 initial, int y,
                              bool reset) {
    label(name, 18, y, reset ? 370 : 490);
    auto *swatch = new TextButton();
    fields.add(swatch);
    page.addAndMakeVisible(swatch);
    swatch->setName(name);
    swatch->setBounds(reset ? 440 : 560, y + 2, 44, 22);
    swatch->setColour(TextButton::buttonColourId, appearance.colour(key, initial));
    auto safe = SafePointer<AdvancedPanel>(this);
    auto button = SafePointer<TextButton>(swatch);
    swatch->onClick = [safe, button, key, initial] {
        if (!safe || !button)
            return;
        auto editor = std::make_unique<ColourEditor>(
            safe->appearance.colour(key, initial), [safe, button, key](Colour colour) {
                if (!safe || !button)
                    return;
                safe->save(key, (int)(colour.getARGB() & 0xffffffu));
                button->setColour(TextButton::buttonColourId, colour);
            });
        CallOutBox::launchAsynchronously(std::move(editor), button->getScreenBounds(), nullptr);
    };
    if (reset) {
        auto *resetButton = new TextButton("Restaurar");
        fields.add(resetButton);
        page.addAndMakeVisible(resetButton);
        resetButton->setBounds(496, y + 1, 88, 24);
        resetButton->onClick = [safe, button, key, initial] {
            if (!safe || !button)
                return;
            safe->save(key, (int)initial);
            button->setColour(TextButton::buttonColourId, Colour(0xff000000u | initial));
        };
    }
}
void AdvancedPanel::select(int index) {
    selected = index;
    fields.clear();
    bpm = beats = unit = nullptr;
    timebase = nullptr;
    automation = nullptr;
    for (int i = 0; i < tabs.size(); ++i)
        tabs[i]->setToggleState(i == index, dontSendNotification);
    label(tabs[index]->getButtonText(), 18, 16, 560, 28, true);
    contentHeight = 300;
    if (index == 0) {
        label("BPM:", 18, 58, 42);
        label("Compasso", 136, 58, 78);
        label("/", 246, 58, 14);
        auto edit = [this](String name, String initial, int x, int width) {
            auto *e = new TextEditor();
            fields.add(e);
            page.addAndMakeVisible(e);
            e->setName(name);
            e->setText(initial);
            e->setFont(theme::font(13));
            e->setJustification(Justification::centred);
            e->setBounds(x, 59, width, 24);
            e->onReturnKey = [this] { applyTiming(); };
            return e;
        };
        const auto *song = session.song();
        bpm = edit("BPM", String(song ? song->bpm : 120), 62, 60);
        beats = edit("Compasso", String(song ? song->beatsPerBar : 4), 214, 34);
        unit = edit("Unidade", String(song ? song->beatUnit : 4), 260, 34);
        const auto settings = song ? song->timeSettings.value_or(jaras::ProjectTimeSettings{})
                                   : jaras::ProjectTimeSettings{};
        label("Projeto timebase", 18, 104, 230);
        timebase = &choice("Projeto timebase", {"Grid Livre", "Grid Relativo"},
                           settings.timebase == jaras::ProjectTimebase::relative ? 2 : 1, 306, 105,
                           160, [](int) {});
        automation =
            new ToggleButton(String::fromUTF8("Timebase afeta a duração dos itens de automação"));
        fields.add(automation);
        page.addAndMakeVisible(automation);
        automation->setBounds(18, 146, 570, 30);
        automation->setToggleState(settings.affectsAutomationLength, dontSendNotification);
    } else if (index == 1) {
        label("Gridline", 18, 58, 300);
        choice("Gridline", {"Ativado", "Desativado"}, appearance.gridlines() ? 1 : 2, 436, 59, 148,
               [this](int id) { save("jaras.timeline.gridlines", id == 1); });
        const StringArray names{String::fromUTF8("Fundo da timeline"),
                                String::fromUTF8("Cor do grid primário"),
                                String::fromUTF8("Cor do grid secundário"),
                                String::fromUTF8("Cor do cursor de reprodução"),
                                String::fromUTF8("Cor do cursor de edição"),
                                "Cor do cursor Sub Play"};
        const char *keys[]{"background", "primaryGrid", "secondaryGrid",
                           "playCursor", "editCursor",  "subPlayCursor"};
        const uint32 defaults[]{0x1e1e1e, 0x535250, 0x333235, 0x7548dd, 0xb9e229, 0xff6f00};
        for (int i = 0; i < 6; ++i)
            colourRow(names[i], String("jaras.timeline.") + keys[i], defaults[i], 102 + i * 40,
                      true);
        label({}, 18, 344, 566, 1).setColour(Label::backgroundColourId, theme::line);
        label(String::fromUTF8("Limpeza de arquivos deletados da timeline"), 18, 360, 470);
        auto *cleanup = new TextButton("Excluir");
        fields.add(cleanup);
        page.addAndMakeVisible(cleanup);
        cleanup->setBounds(504, 360, 80, 26);
        cleanup->getProperties().set("flat", true);
        cleanup->onClick = [this] {
            Component *host = this;
            if (auto *sheet = findParentComponentOfClass<ModalSheet>())
                if (sheet->getParentComponent())
                    host = sheet->getParentComponent();
            ModalSheet::open(*host, String::fromUTF8("Limpar arquivos removidos da timeline"),
                             std::make_unique<MediaCleanupPanel>(session), 480, 300);
        };
        contentHeight = 410;
    } else if (index == 2 || index == 3) {
        const String prefix = String("jaras.media.") + (index == 2 ? "record." : "rerender.");
        label("Formato", 18, 58, 88);
        choice("Formato", {"WAV", "AIFF"},
               appearance.value(prefix + "format", "WAV").toString() == "AIFF" ? 2 : 1, 114, 59,
               110, [this, prefix](int id) { save(prefix + "format", id == 2 ? "AIFF" : "WAV"); });
        const int bits = (int)appearance.value(prefix + "bits", 24);
        choice("Profundidade", {"PCM de 16 bits", "PCM de 24 bits", "PCM de 32 bits"},
               bits == 16   ? 1
               : bits == 32 ? 3
                            : 2,
               248, 59, 180, [this, prefix](int id) {
                   save(prefix + "bits", id == 1 ? 16 : id == 3 ? 32 : 24);
               });
    } else if (index == 4) {
        toggle("Stretch", "jaras.video.stretch", false, 56);
        label(String::fromUTF8("Resolução"), 18, 96, 104);
        const int resolution = (int)appearance.value("jaras.video.resolution", 1080);
        choice(String::fromUTF8("Resolução"),
               {String::fromUTF8("640 × 360"), String::fromUTF8("854 × 480"),
                String::fromUTF8("1280 × 720"), String::fromUTF8("1920 × 1080")},
               resolution == 360   ? 1
               : resolution == 480 ? 2
               : resolution == 720 ? 3
                                   : 4,
               126, 97, 160, [this](int id) {
                   const int sizes[]{360, 480, 720, 1080};
                   save("jaras.video.resolution", sizes[id - 1]);
               });
        toggle("Preto e branco", "jaras.video.grayscale", false, 136);
        toggle(String::fromUTF8("Sem áudio"), "jaras.video.noAudio", true, 172);
    } else {
        label("Modo ID do Setlist", 174, 58, 130);
        choice("Setlist ID mode", {"ID da playlist", String::fromUTF8("ID da região")},
               appearance.regionIDs() ? 2 : 1, 308, 59, 126,
               [this](int id) { save("jaras.setlist.idMode", id == 2 ? "region" : "playlist"); });
        label("Fonte do Setlist", 180, 100, 120);
        choice("Setlist font",
               {String::fromUTF8("Padrão"), "Negrito", String::fromUTF8("Negrito itálico")},
               appearance.fontStyle() + 1, 300, 101, 134,
               [this](int id) { save("jaras.setlist.fontStyle", id - 1); });
        const StringArray names{String::fromUTF8("Letras das músicas em All Regions"),
                                String::fromUTF8("Letras das músicas nas playlists"),
                                String::fromUTF8("Letras das músicas dentro das gavetas")};
        for (int i = 0; i < 3; ++i)
            colourRow(names[i], colourKeys[i], colourDefaults[i], 142 + i * 40);
    }
    apply.setVisible(selected == 0);
    localization::panel(*this);
    viewport.setViewPosition(0, 0);
    resized();
    repaint();
}
void AdvancedPanel::applyTiming() {
    if (selected != 0 || !bpm)
        return;
    const double value = bpm->getText().replaceCharacter(',', '.').getDoubleValue();
    const int numerator = beats->getText().getIntValue(),
              denominator = unit->getText().getIntValue();
    if (!std::isfinite(value) || value < 60 || value > 300) {
        error("Informe um BPM entre 60 e 300.");
        bpm->grabKeyboardFocus();
        return;
    }
    if (numerator < 1 || numerator > 32 || denominator < 1 || denominator > 64 ||
        (denominator & (denominator - 1))) {
        error(String::fromUTF8("Compasso inválido."));
        return;
    }
    auto settings = session.song()
                        ? session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{})
                        : jaras::ProjectTimeSettings{};
    settings.timebase = timebase->getSelectedId() == 2 ? jaras::ProjectTimebase::relative
                                                       : jaras::ProjectTimebase::free;
    settings.affectsAutomationLength = automation->getToggleState();
    try {
        session.configureTiming(value, numerator, denominator, settings);
        ModalSheet::dismiss(*this);
    } catch (const std::exception &e) {
        error(String::fromUTF8(e.what()));
    }
}
void AdvancedPanel::paint(Graphics &g) {
    g.setColour(theme::background);
    g.fillRoundedRectangle(getLocalBounds().toFloat(), 16);
    g.setColour(theme::panel);
    g.fillRect(0, 0, 136, getHeight() - 52);
    g.setColour(theme::line);
    g.drawVerticalLine(136, 0, (float)getHeight() - 52);
    g.drawHorizontalLine(getHeight() - 52, 0, (float)getWidth());
}
void AdvancedPanel::resized() {
    for (int i = 0; i < tabs.size(); ++i)
        tabs[i]->setBounds(10, 10 + i * 42, 116, 36);
    viewport.setBounds(137, 0, getWidth() - 137, getHeight() - 52);
    page.setSize(std::max(610, viewport.getWidth() - 8), contentHeight);
    close.setBounds(getWidth() - (selected == 0 ? 166 : 92), getHeight() - 38, 78, 24);
    apply.setBounds(getWidth() - 82, getHeight() - 38, 66, 24);
}
} // namespace catlive
