#include "Workspace.h"
#include "Projection.h"
#include "PortablePackage.h"
#include "ProjectMigration.h"
#include "ImportNoticePanel.h"
#include "AdvancedPanel.h"
#include "SettingsPanel.h"
#include "StagePanels.h"
#include "PatchPanel.h"
#include "AutomationPanel.h"
#include "EnvelopeLane.h"
#include "MetronomePanel.h"
#include "EffectsPanel.h"
#include "PlaylistEditor.h"
#include "TrackTree.h"
#include "CreateTrackPanel.h"
#include "ExportPanel.h"
#include "ModalSheet.h"
#include "ResolumePanel.h"
#include "TextItemPanel.h"
#include "ClipEditing.h"
#include "ItemTunerPanel.h"
#include "NormalizationPanel.h"
#include "MIDIEditorPanel.h"
#include "RemotePanel.h"
#include "RemotePresentation.h"
#include <BinaryData.h>
#include <fstream>
#include <windows.h>
namespace catlive {
void MacLook::fillTextEditorBackground(Graphics &g, int width, int height, TextEditor &editor) {
    g.setColour(editor.findColour(TextEditor::backgroundColourId));
    g.fillRoundedRectangle(1, 1, width - 2.f, height - 2.f, 5);
}
void MacLook::drawTextEditorOutline(Graphics &g, int width, int height, TextEditor &editor) {
    const bool focused = editor.hasKeyboardFocus(true) && !editor.isReadOnly();
    g.setColour(focused ? Colour(0xff6ea35a) : Colour(0xff3a3a3a));
    g.drawRoundedRectangle(focused ? juce::Rectangle<float>(1.5f, 1.5f, width - 3.f, height - 3.f)
                                   : juce::Rectangle<float>(.5f, .5f, width - 1.f, height - 1.f),
                           5, focused ? 3.f : 1.f);
}
Button *MacLook::createDocumentWindowButton(int type) {
    class TrafficButton final : public Button {
      public:
        TrafficButton(int value)
            : Button(value == DocumentWindow::closeButton      ? "Fechar"
                     : value == DocumentWindow::minimiseButton ? "Minimizar"
                                                               : "Maximizar"),
              kind(value) {}
        void paintButton(Graphics &g, bool hover, bool down) override {
            const Colour color = kind == DocumentWindow::closeButton      ? Colour(0xffff5f57)
                                 : kind == DocumentWindow::minimiseButton ? Colour(0xffffbd2e)
                                                                          : Colour(0xff28c840);
            const auto circle = getLocalBounds().toFloat().withSizeKeepingCentre(13, 13);
            g.setColour(down ? color.darker(.2f) : color);
            g.fillEllipse(circle);
            if (hover) {
                g.setColour(Colours::black.withAlpha(.65f));
                auto r = circle.reduced(4);
                if (kind == DocumentWindow::closeButton) {
                    g.drawLine(r.getX(), r.getY(), r.getRight(), r.getBottom(), 1);
                    g.drawLine(r.getRight(), r.getY(), r.getX(), r.getBottom(), 1);
                } else {
                    g.drawLine(r.getX(), r.getCentreY(), r.getRight(), r.getCentreY(), 1);
                    if (kind == DocumentWindow::maximiseButton)
                        g.drawLine(r.getCentreX(), r.getY(), r.getCentreX(), r.getBottom(), 1);
                }
            }
        }

      private:
        int kind;
    };
    return new TrafficButton(type);
}
void MacLook::drawDocumentWindowTitleBar(DocumentWindow &window, Graphics &g, int width, int height,
                                         int, int, const Image *, bool active) {
    g.fillAll(theme::titlebar);
    g.setColour(active ? Colours::white : theme::secondary);
    g.setFont(theme::semiboldFont(12));
    g.drawText(window.getName(), 14, 0, std::max(1, width - 112), height,
               Justification::centredLeft);
}
MacLook::MacLook() {
    setDefaultSansSerifTypeface(theme::font(13).getTypefacePtr());
    setColour(ResizableWindow::backgroundColourId, theme::background);
    setColour(TextButton::buttonColourId, theme::panel);
    setColour(TextButton::buttonOnColourId, theme::green);
    setColour(TextButton::textColourOffId, Colours::white);
    setColour(TextButton::textColourOnId, Colours::black);
    setColour(Label::textColourId, Colours::white);
    setColour(TextEditor::backgroundColourId, theme::display);
    setColour(TextEditor::textColourId, Colours::white);
    setColour(TextEditor::outlineColourId, theme::line);
    setColour(TextEditor::focusedOutlineColourId, theme::green);
    setColour(ComboBox::backgroundColourId, theme::display);
    setColour(ComboBox::textColourId, Colours::white);
    setColour(ComboBox::outlineColourId, theme::line);
    setColour(PopupMenu::backgroundColourId, theme::panel);
    setColour(PopupMenu::textColourId, Colours::white);
    setColour(PopupMenu::highlightedBackgroundColourId, theme::green.withAlpha(.25f));
    setColour(PopupMenu::highlightedTextColourId, Colours::white);
    setColour(AlertWindow::backgroundColourId, theme::panel);
    setColour(AlertWindow::textColourId, Colours::white);
    setColour(Slider::thumbColourId, Colours::white);
    setColour(Slider::trackColourId, theme::green);
    setColour(Slider::textBoxTextColourId, Colours::white);
    setColour(Slider::textBoxOutlineColourId, Colours::transparentBlack);
    setColour(Slider::textBoxBackgroundColourId, theme::display);
    setColour(TableHeaderComponent::backgroundColourId, theme::panel);
    setColour(TableHeaderComponent::textColourId, theme::secondary);
    setColour(ListBox::backgroundColourId, theme::background);
    setColour(ScrollBar::thumbColourId, Colour(0xff686868));
    setColour(ToggleButton::textColourId, Colours::white);
    setColour(ToggleButton::tickColourId, theme::green);
}
void MacLook::drawButtonBackground(Graphics &g, Button &b, const Colour &colour, bool over,
                                   bool down) {
    const bool plain = (bool)b.getProperties().getWithDefault("plain", false);
    if (plain && !over && !down && !b.getToggleState())
        return;
    auto r = b.getLocalBounds().toFloat().reduced(.6f);
    auto tint = colour;
    if (b.getToggleState())
        tint = b.findColour(TextButton::buttonOnColourId);
    if (!b.isEnabled())
        tint = tint.withMultipliedAlpha(.35f);
    else if (down)
        tint = tint.brighter(.15f);
    else if (over)
        tint = tint.brighter(.08f);
    if ((bool)b.getProperties().getWithDefault("colourWell", false)) {
        g.setColour(Colour(0xff454545));
        g.fillRoundedRectangle(r, r.getHeight() * .5f);
        g.setColour(tint);
        g.fillRoundedRectangle(r.reduced(2.5f), (r.getHeight() - 5) * .5f);
        g.setColour(Colours::white.withAlpha(.25f));
        g.drawRoundedRectangle(r.reduced(2.5f), (r.getHeight() - 5) * .5f, 1);
        return;
    }
    g.setColour(tint);
    g.fillRoundedRectangle(r, 4);
    if (!plain && !(bool)b.getProperties().getWithDefault("flat", false)) {
        g.setColour(b.getToggleState() ? tint.brighter(.25f) : Colours::white.withAlpha(.45f));
        g.drawRoundedRectangle(r, 4, .8f);
    }
}
void MacLook::drawButtonText(Graphics &g, TextButton &b, bool, bool) {
    g.setFont(theme::semiboldFont((float)b.getProperties().getWithDefault("fontSize", 12.0f)));
    g.setColour(
        b.findColour(b.getToggleState() ? TextButton::textColourOnId : TextButton::textColourOffId)
            .withMultipliedAlpha(b.isEnabled() ? 1.0f : .35f));
    const auto icon = b.getProperties().getWithDefault("icon", {}).toString();
    const auto leading = b.getProperties().getWithDefault("leadingIcon", {}).toString();
    if (leading.isNotEmpty()) {
        drawInterfaceIcon(g, leading, {10, (b.getHeight() - 16) * .5f, 16, 16});
        auto label = b.getButtonText();
        const float width = (float)(b.getWidth() - 40);
        if (!label.containsChar(' ') &&
            GlyphArrangement::getStringWidth(g.getCurrentFont(), label) > width) {
            int cut = label.length() - 1;
            while (cut > 1 && GlyphArrangement::getStringWidth(g.getCurrentFont(),
                                                               label.substring(0, cut)) > width)
                --cut;
            const auto hyphen = label.indexOfChar('-');
            if (hyphen >= 0 && hyphen < cut) cut = hyphen + 1;
            label = label.substring(0, cut) + "\n" + label.substring(cut);
        }
        g.drawFittedText(label, 34, 0, b.getWidth() - 40, b.getHeight(), Justification::centredLeft,
                         2, 1.f);
        return;
    }
    if (icon.isNotEmpty() &&
        drawInterfaceIcon(g, icon, b.getLocalBounds().toFloat().withSizeKeepingCentre(17, 17)))
        return;
    g.drawFittedText(b.getButtonText(), b.getLocalBounds().reduced(3, 0), Justification::centred,
                     1);
}
void MacLook::drawToggleButton(Graphics &g, ToggleButton &button, bool over, bool down) {
    const float alpha = button.isEnabled() ? 1.f : .35f;
    const auto box = juce::Rectangle<float>(2, (button.getHeight() - 16.f) * .5f, 16, 16);
    g.setColour((button.getToggleState() ? Colour(0xff64b64a)
                                         : Colour(over || down ? 0xff555555 : 0xff373737))
                    .withAlpha(alpha));
    g.fillRoundedRectangle(box, 4);
    if (button.getToggleState()) {
        Path tick;
        tick.startNewSubPath(box.getX() + 3, box.getY() + 8);
        tick.lineTo(box.getX() + 6.5f, box.getY() + 11.5f);
        tick.lineTo(box.getX() + 13, box.getY() + 4);
        g.setColour(Colours::white.withAlpha(alpha));
        g.strokePath(tick, PathStrokeType(2, PathStrokeType::curved, PathStrokeType::rounded));
    }
    g.setFont(theme::font(13));
    g.setColour(button.findColour(ToggleButton::textColourId).withMultipliedAlpha(alpha));
    g.drawFittedText(button.getButtonText(), 24, 0, std::max(0, button.getWidth() - 26),
                     button.getHeight(), Justification::centredLeft, 2, 1.f);
}
void MacLook::drawComboBox(Graphics &g, int width, int height, bool, int, int, int, int,
                           ComboBox &box) {
    const bool outlined = (bool)box.getProperties().getWithDefault("outlined", false);
    auto bounds = juce::Rectangle<float>(.5f, .5f, width - 1.f, height - 1.f);
    g.setColour(outlined ? theme::display : Colour(0xff505050));
    g.fillRoundedRectangle(bounds, 5);
    if (outlined) {
        g.setColour(theme::line);
        g.drawRoundedRectangle(bounds, 5, 1);
    }
    g.setColour(Colours::white.withAlpha(box.isEnabled() ? 1.f : .35f));
    const float x = width - 13.f, y = height * .5f;
    Path arrows;
    if (!outlined) {
        arrows.startNewSubPath(x - 3, y - 2);
        arrows.lineTo(x, y - 5);
        arrows.lineTo(x + 3, y - 2);
    }
    arrows.startNewSubPath(x - 3, y + 1);
    arrows.lineTo(x, y + 4);
    arrows.lineTo(x + 3, y + 1);
    g.strokePath(arrows, PathStrokeType(1.3f));
}
void MacLook::drawLinearSlider(Graphics &g, int x, int y, int w, int h, float pos, float, float,
                               Slider::SliderStyle style, Slider &slider) {
    if ((bool)slider.getProperties().getWithDefault("stageScale", false)) {
        const float middle = y + h * .5f;
        g.setColour(Colour(0xff505050));
        g.fillRoundedRectangle((float)x, middle - 3, (float)w, 6, 3);
        g.setColour(theme::green);
        g.fillRoundedRectangle((float)x, middle - 3, std::max(0.f, pos - x), 6, 3);
        g.setColour(Colour(0xffdedede));
        g.fillRoundedRectangle(pos - 10, middle - 8, 20, 16, 8);
        return;
    }
    if (slider.getComponentID().endsWith("Volume")) {
        const auto value = slider.getValue();
        const auto db =
            value <= 0 ? String::fromUTF8("−∞") : String(Decibels::gainToDecibels(value), 1);
        g.setColour(Colours::white.withAlpha(.9f));
        g.setFont(theme::semiboldFont(9));
        g.drawText(value >= 1 ? "+" + db : db, 2, 0, 37, slider.getHeight(),
                   Justification::centred);
        const float mid = (float)y + h * .5f;
        g.setColour(Colours::white.withAlpha(.25f));
        g.fillRoundedRectangle((float)x, mid - 3, (float)w, 6, 3);
        g.setColour(Colour(0xffdedede));
        g.fillRoundedRectangle(pos - 5, mid - 9, 10, 18, 2);
        g.setColour(Colour(0xff999999));
        g.drawVerticalLine((int)pos, mid - 6, mid + 6);
        return;
    }
    if (slider.getComponentID().endsWith("Pan")) {
        g.setColour(Colours::white.withAlpha(.3f));
        g.fillRoundedRectangle((float)x, 5, (float)w, 4, 2);
        g.setColour(Colours::white.withAlpha(.9f));
        g.fillEllipse(pos - 4, 3, 8, 8);
        g.setFont(theme::semiboldFont(8));
        const double pan = slider.getValue();
        g.drawText(std::abs(pan) < .005
                       ? String("Center")
                       : String((int)std::round(std::abs(pan) * 100)) + (pan < 0 ? " L" : " R"),
                   0, 12, slider.getWidth(), 12, Justification::centred);
        return;
    }
    g.setColour(Colour(0xff505050));
    if (style == Slider::LinearVertical) {
        if (slider.getComponentID() == "mixerFader") {
            g.setColour(Colours::white.withAlpha(.25f));
            g.fillRoundedRectangle(x + w * .5f - 3, (float)y, 6, (float)h, 3);
            g.setColour(Colour(0xffdedede));
            g.fillRoundedRectangle(x + w * .5f - 11, pos - 6, 22, 12, 2);
            g.setColour(Colour(0xff999999));
            g.drawHorizontalLine((int)pos, x + w * .5f - 8, x + w * .5f + 8);
            return;
        }
        g.fillRoundedRectangle((float)x + w * .5f - 2, (float)y, 4, (float)h, 2);
        g.setColour(theme::green.withAlpha(.7f));
        g.fillRoundedRectangle((float)x + w * .5f - 2, pos, 4, y + h - pos, 2);
        g.setColour(Colours::white);
        g.fillRoundedRectangle((float)x + w * .5f - 7, pos - 3, 14, 6, 2);
    } else {
        g.fillRoundedRectangle((float)x, (float)y + h * .5f - 2, (float)w, 4, 2);
        g.setColour(slider.findColour(Slider::trackColourId));
        g.fillRoundedRectangle((float)x, (float)y + h * .5f - 2, std::max(1.0f, pos - x), 4, 2);
        g.setColour(Colours::white);
        g.fillEllipse(pos - 4, (float)y + h * .5f - 4, 8, 8);
    }
}
Slider::SliderLayout MacLook::getSliderLayout(Slider &slider) {
    auto layout = LookAndFeel_V4::getSliderLayout(slider);
    if (slider.getComponentID().endsWith("Volume"))
        layout.sliderBounds = slider.getLocalBounds().withTrimmedLeft(42).withTrimmedRight(8);
    return layout;
}
void MacLook::drawScrollbar(Graphics &g, ScrollBar &, int x, int y, int w, int h, bool vertical,
                            int start, int size, bool over, bool down) {
    g.setColour(Colour(over || down ? 0xff888888 : 0xff535353));
    if (vertical)
        g.fillRoundedRectangle((float)x + 2, (float)start + 2, (float)w - 4,
                               (float)std::max(4, size - 4), 3);
    else
        g.fillRoundedRectangle((float)start + 2, (float)y + 2, (float)std::max(4, size - 4),
                               (float)h - 4, 3);
}
namespace {
class QuietButton : public TextButton {
  public:
    explicit QuietButton(const String &title = {}) : TextButton(title) {}
    std::function<void(Point<int>)> context;
    void mouseDown(const MouseEvent &e) override {
        right = e.mods.isPopupMenu();
        if (right) {
            if (context)
                context(e.getScreenPosition());
            return;
        }
        TextButton::mouseDown(e);
    }
    void mouseUp(const MouseEvent &e) override {
        if (right) {
            right = false;
            return;
        }
        TextButton::mouseUp(e);
    }

  private:
    bool right = false;
};
class Panel : public Component {
  public:
    OwnedArray<Component> owned;
    Label title, subtitle;
    explicit Panel(String name, String description = {}) {
        addAndMakeVisible(title);
        addAndMakeVisible(subtitle);
        title.setText(name, dontSendNotification);
        title.setFont(theme::font(20, true));
        subtitle.setText(description, dontSendNotification);
        subtitle.setFont(theme::font(11));
        subtitle.setColour(Label::textColourId, theme::secondary);
    }
    void paint(Graphics &g) override { g.fillAll(theme::background); }
    void resized() override {
        title.setBounds(24, 18, getWidth() - 48, 30);
        subtitle.setBounds(24, 50, getWidth() - 48, 28);
    }
    Label &label(String name, int x, int y, int width) {
        auto *l = new Label();
        owned.add(l);
        addAndMakeVisible(l);
        l->setText(name, dontSendNotification);
        l->setFont(theme::font(11));
        l->setBounds(x, y, width, 22);
        return *l;
    }
    TextEditor &editor(String value, int x, int y, int width, int height = 28) {
        auto *e = new TextEditor();
        owned.add(e);
        addAndMakeVisible(e);
        e->setText(value, false);
        e->setFont(theme::font(12));
        e->setBounds(x, y, width, height);
        return *e;
    }
    TextButton &button(String value, int x, int y, int width, std::function<void()> action,
                       Colour colour = theme::panel) {
        auto *b = new QuietButton(value);
        owned.add(b);
        addAndMakeVisible(b);
        b->setBounds(x, y, width, 30);
        b->setColour(TextButton::buttonColourId, colour);
        b->onClick = std::move(action);
        return *b;
    }
};
class MAPanel final : public Panel, private TableListBoxModel {
  public:
    MAPanel(Session &s, Lighting &l, std::function<void(String)> fail)
        : Panel("grandMA2",
                String::fromUTF8("Mapa estável · timecode absoluto · gerador de macros · 30 FPS")),
          session(s), lighting(l), error(std::move(fail)) {
        lighting.refresh();
        const StringArray names{"Sequence inicial", String::fromUTF8("Página"), "Executor inicial",
                                "Timecode inicial", "MTC Slot"};
        const int values[]{l.settings.sequence, l.settings.page, l.settings.executor,
                           l.settings.timecode, l.settings.slot};
        for (int i = 0; i < 5; ++i) {
            label(names[i], 24 + i * 150, 88, 142);
            auto &e = editor(String(values[i]), 24 + i * 150, 112, 136);
            fields.add(&e);
            e.setInputRestrictions(4, "0123456789");
            e.onTextChange = [this] { refreshPreview(); };
        }
        table.setModel(this);
        addAndMakeVisible(table);
        table.setRowHeight(36);
        table.getHeader().addColumn(String::fromUTF8("Exportar / Música"), 1, 280);
        table.getHeader().addColumn(String::fromUTF8("Início MTC"), 2, 100);
        table.getHeader().addColumn("Seq", 3, 65);
        table.getHeader().addColumn("Executor", 4, 85);
        table.getHeader().addColumn("TC", 5, 65);
        table.getHeader().addColumn("Cues", 6, 55);
        table.getHeader().setStretchToFitActive(true);
        button("Selecionar tudo", 24, 156, 125, [this] {
            for (auto &r : lighting.regions)
                lighting.selected.insert(r.id);
            table.repaint();
        });
        button(String::fromUTF8("Limpar seleção"), 157, 156, 125, [this] {
            lighting.selected.clear();
            table.repaint();
        });
        button("Copiar mapa", 290, 156, 110, [this] {
            try {
                apply();
                SystemClipboard::copyTextToClipboard(lighting.exportMapCSV());
                status.setText("Mapa copiado.", dontSendNotification);
            } catch (const std::exception &e) {
                error(String::fromUTF8(e.what()));
            }
        });
        auto devices = MidiOutput::getAvailableDevices();
        midi.addItem(String::fromUTF8("Nenhuma saída MIDI"), 1);
        int id = 2;
        for (auto &d : devices) {
            midi.addItem(d.name, id);
            if (d.identifier == lighting.midiIdentifier)
                midi.setSelectedId(id, dontSendNotification);
            ++id;
        }
        if (midi.getSelectedId() == 0)
            midi.setSelectedId(1, dontSendNotification);
        addAndMakeVisible(midi);
        midi.onChange = [this, devices] {
            try {
                int index = midi.getSelectedId() - 2;
                lighting.setMidiOutput(index >= 0 ? devices[index].identifier : String());
            } catch (const std::exception &e) {
                error(String::fromUTF8(e.what()));
            }
        };
        mtc.setButtonText(String::fromUTF8("Enviar MTC · cursor principal"));
        mtc.setToggleState(lighting.mtcEnabled.load(), dontSendNotification);
        addAndMakeVisible(mtc);
        mtc.onClick = [this] { lighting.enableMTC(mtc.getToggleState()); };
        addAndMakeVisible(status);
        status.setFont(theme::font(11));
        status.setColour(Label::textColourId, theme::yellow);
        button("Salvar mapa no projeto", 24, 0, 190, [this] {
            try {
                apply();
                lighting.saveSettings();
                status.setText(
                    String::fromUTF8(
                        "Mapa atualizado. Salve o projeto .jl para guardar as atribuições."),
                    dontSendNotification);
            } catch (const std::exception &e) {
                error(String::fromUTF8(e.what()));
            }
        });
        exportButton = &button(
            String::fromUTF8("Exportar grandMA2…"), 222, 0, 190, [this] { exportFiles(); },
            Colour(0xff655c27));
        label(String::fromUTF8(
                  "No grandMA2, importe apenas o macro “Importar tudo” e execute uma vez."),
              24, 0, 730)
            .setName("instructions");
    }
    void resized() override {
        Panel::resized();
        table.setBounds(24, 198, getWidth() - 48, getHeight() - 356);
        midi.setBounds(24, getHeight() - 148, 330, 28);
        mtc.setBounds(370, getHeight() - 148, 350, 28);
        status.setBounds(24, getHeight() - 112, getWidth() - 48, 24);
        for (auto *c : owned) {
            if (auto *b = dynamic_cast<TextButton *>(c)) {
                if (b->getButtonText() == "Salvar mapa no projeto")
                    b->setTopLeftPosition(24, getHeight() - 78);
                if (b == exportButton)
                    b->setTopLeftPosition(222, getHeight() - 78);
            }
            if (c->getName() == "instructions")
                c->setTopLeftPosition(24, getHeight() - 38);
        }
    }

  private:
    Session &session;
    Lighting &lighting;
    std::function<void(String)> error;
    Array<TextEditor *> fields;
    TableListBox table;
    ComboBox midi;
    ToggleButton mtc;
    Label status;
    TextButton *exportButton = nullptr;
    std::unique_ptr<FileChooser> chooser;
    void apply() {
        auto integer = [&](int i, int max) {
            auto t = fields[i]->getText();
            if (t.isEmpty() || t.getIntValue() < 1 || t.getIntValue() > max)
                throw std::runtime_error("Numeração inválida no mapa grandMA2.");
            return t.getIntValue();
        };
        lighting.settings = {integer(0, 9999), integer(1, 9999), integer(2, 9999), integer(3, 9999),
                             integer(4, 8)};
        lighting.buildExports(false);
    }
    void refreshPreview() {
        try {
            apply();
            status.setText({}, dontSendNotification);
        } catch (const std::exception &e) {
            status.setText(String::fromUTF8(e.what()), dontSendNotification);
        }
        table.repaint();
    }
    void exportFiles() {
        try {
            apply();
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
            return;
        }
        chooser = std::make_unique<FileChooser>(
            "Escolher pasta para grandMA2", session.document.getParentDirectory(), String(), true);
        chooser->launchAsync(FileBrowserComponent::openMode |
                                 FileBrowserComponent::canSelectDirectories,
                             [safe = Component::SafePointer<MAPanel>(this)](const FileChooser &fc) {
                                 if (!safe)
                                     return;
                                 auto folder = fc.getResult();
                                 if (folder == File())
                                     return;
                                 try {
                                     auto installer = safe->lighting.exportGrandMA2(folder);
                                     safe->status.setText("Arquivos prontos. Importe: " + installer,
                                                          dontSendNotification);
                                     folder.revealToUser();
                                 } catch (const std::exception &e) {
                                     safe->error(String::fromUTF8(e.what()));
                                 }
                             });
    }
    int getNumRows() override { return (int)lighting.regions.size(); }
    void paintRowBackground(Graphics &g, int row, int w, int h, bool selected) override {
        g.fillAll(selected ? theme::green.withAlpha(.10f)
                           : (row % 2 ? Colour(0xff222222) : theme::background));
        g.setColour(theme::line.withAlpha(.5f));
        g.drawHorizontalLine(h - 1, 0, (float)w);
    }
    void paintCell(Graphics &g, int row, int col, int w, int h, bool) override {
        if (row < 0 || row >= (int)lighting.regions.size())
            return;
        auto &r = lighting.regions[(size_t)row];
        g.setFont(theme::font(12));
        g.setColour(Colours::white);
        String value;
        if (col == 1)
            value = String(lighting.selected.count(r.id) ? String::fromUTF8("☑  ")
                                                         : String::fromUTF8("☐  ")) +
                    r.name;
        if (col == 2)
            value = clockText(r.start, true);
        if (col == 3)
            value = String(lighting.settings.sequence + r.offset);
        if (col == 4)
            value = String(lighting.settings.page) + "." +
                    String(lighting.settings.executor + r.offset);
        if (col == 5)
            value = String(lighting.settings.timecode + r.offset);
        if (col == 6)
            value = String((int)r.cues.size());
        g.drawFittedText(value, 6, 0, w - 12, h, Justification::centredLeft, 1);
    }
    void cellClicked(int row, int col, const MouseEvent &) override {
        if (row < 0 || row >= (int)lighting.regions.size())
            return;
        if (col == 1) {
            auto id = lighting.regions[(size_t)row].id;
            if (lighting.selected.count(id))
                lighting.selected.erase(id);
            else
                lighting.selected.insert(id);
            table.repaint();
        }
    }
};
class LoginPanel final : public Panel {
  public:
    LoginPanel(Auth &a)
        : Panel("Bem-vindo ao CatLive", "Use o e-mail e o CPF da sua compra."), auth(a) {
        logo = ImageCache::getFromMemory(BinaryData::CatLiveSplash_png,
                                         BinaryData::CatLiveSplash_pngSize);
        title.setJustificationType(Justification::centred);
        title.setFont(theme::font(22, true));
        subtitle.setJustificationType(Justification::centred);
        subtitle.setText(String::fromUTF8("Use o e-mail e o CPF da sua compra.\nO trial começa no "
                                          "primeiro acesso neste dispositivo."),
                         dontSendNotification);
        email = &editor({}, 30, 317, 380, 30);
        email->setTextToShowWhenEmpty("E-mail cadastrado", theme::secondary);
        cpf = &editor({}, 30, 359, 380, 30);
        cpf->setTextToShowWhenEmpty("CPF", theme::secondary);
        cpf->setPasswordCharacter(0x2022);
        login = &button(
            "Entrar", 30, 401, 380,
            [this] {
                auth.login(email->getText(), cpf->getText(), auth.deviceName);
                cpf->clear();
            },
            Colour(0xff32593e));
        stage = &button("Login", 30, 261, 184, [this] {
            entering = true;
            stage->setToggleState(true, dontSendNotification);
            if (layoutChanged) layoutChanged();
            resized();
            email->grabKeyboardFocus();
        });
        trial = &button(String::fromUTF8("Trial teste · 7 dias"), 226, 261, 184,
                        [this] { auth.trial(auth.deviceName); });
        manage = &button("Gerenciar dispositivos", 30, 443, 380, [this] { devices(); });
        for (auto *b : {stage, trial, login}) {
            b->getProperties().set("fontSize", 18.f);
            b->setColour(TextButton::buttonColourId, Colour(0xff4b845c));
            b->setColour(TextButton::buttonOnColourId, theme::accent);
            b->setColour(TextButton::textColourOnId, Colours::black);
        }
        login->setToggleState(true, dontSendNotification);
        manage->getProperties().set("fontSize", 16.f);
        manage->getProperties().set("flat", true);
        for (auto *field : {email, cpf}) field->setFont(theme::font(18));
        subtitle.setFont(theme::font(14));
        email->onTextChange = cpf->onTextChange = [this] { update(); };
        addAndMakeVisible(message);
        message.setColour(Label::textColourId, theme::yellow);
        message.setFont(theme::font(12));
        message.setJustificationType(Justification::centred);
        cpf->onReturnKey = [this] { login->triggerClick(); };
        email->onReturnKey = [this] { cpf->grabKeyboardFocus(); };
        update();
    }
    void paint(Graphics &g) override {
        g.setColour(theme::panel);
        g.fillRoundedRectangle(getLocalBounds().toFloat(), 16);
        g.drawImageWithin(logo, (getWidth() - 160) / 2, 30, 160, 160, RectanglePlacement::centred);
    }
    int preferredHeight() const { return entering ? 630 : 440; }
    std::function<void()> layoutChanged;
    void resized() override {
        stage->setBounds((getWidth() - 238) / 2, 261, 70, 42);
        trial->setBounds((getWidth() - 238) / 2 + 82, 261, 156, 42);
        email->setBounds(30, 325, getWidth() - 60, 30);
        cpf->setBounds(30, 367, getWidth() - 60, 30);
        login->setBounds(30, 409, 80, 42);
        manage->setBounds(30, 463, 200, 30);
        title.setBounds(30, 212, getWidth() - 60, 27);
        for (auto *component : {static_cast<Component *>(email), static_cast<Component *>(cpf),
                                static_cast<Component *>(login), static_cast<Component *>(manage)})
            if (component)
                component->setVisible(entering);
        subtitle.setBounds(30, entering ? 523 : 329, getWidth() - 60, 42);
        message.setBounds(30, entering ? 572 : 378, getWidth() - 60, 50);
    }
    void update() {
        const bool credentials = email->getText().isNotEmpty() && cpf->getText().isNotEmpty();
        login->setEnabled(!auth.busy && credentials);
        manage->setEnabled(!auth.busy && credentials);
        trial->setEnabled(!auth.busy);
        stage->setEnabled(!auth.busy);
        message.setText(auth.busy ? String::fromUTF8("Validando acesso…") : auth.message,
                        dontSendNotification);
    }

  private:
    Auth &auth;
    Image logo;
    TextEditor *email = nullptr, *cpf = nullptr;
    TextButton *login = nullptr, *trial = nullptr, *stage = nullptr, *manage = nullptr;
    bool entering = false;
    Label message;
    void devices() {
        auto mail = email->getText(), password = cpf->getText();
        if (mail.isEmpty() || password.isEmpty()) {
            message.setText("Informe e-mail e CPF para gerenciar dispositivos.",
                            dontSendNotification);
            return;
        }
        auth.credentialDevices(
            mail, password,
            [safe = Component::SafePointer<LoginPanel>(this), mail, password](var data,
                                                                              String error) {
                if (!safe)
                    return;
                if (error.isNotEmpty()) {
                    safe->message.setText(error, dontSendNotification);
                    return;
                }
                PopupMenu menu;
                auto values = list(data);
                for (int i = 0; i < values.size(); ++i)
                    menu.addItem(i + 1, str(values[i], "deviceName") + String::fromUTF8(" · ") +
                                            str(values[i], "platform"));
                if (values.isEmpty()) {
                    safe->message.setText("Nenhum dispositivo conectado.", dontSendNotification);
                    return;
                }
                menu.showMenuAsync(
                    PopupMenu::Options().withTargetComponent(safe.getComponent()),
                    [safe, values, mail, password](int id) {
                        if (!safe || id <= 0 || id > values.size())
                            return;
                        auto installation = str(values[id - 1], "installationId");
                        AlertWindow::showOkCancelBox(
                            MessageBoxIconType::QuestionIcon, "Remover dispositivo?",
                            str(values[id - 1], "deviceName"), "Remover", "Cancelar",
                            safe.getComponent(),
                            ModalCallbackFunction::create([safe, mail, password,
                                                           installation](int result) {
                                if (safe && result)
                                    safe->auth.revokeCredentialDevice(
                                        mail, password, installation, [safe](String failure) {
                                            if (safe)
                                                safe->message.setText(
                                                    failure.isEmpty()
                                                        ? "Dispositivo removido. Entre novamente."
                                                        : failure,
                                                    dontSendNotification);
                                        });
                            }));
                    });
            });
    }
};
class LoginBackdrop final : public Component {
  public:
    explicit LoginBackdrop(Auth &auth) : panel(auth) {
        setOpaque(true);
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        viewport.setScrollBarsShown(true, false);
        viewport.setScrollBarThickness(8);
        content.addAndMakeVisible(panel);
        panel.layoutChanged = [this] { resized(); };
    }
    void paint(Graphics &g) override { g.fillAll(theme::background); }
    void resized() override {
        viewport.setBounds(getLocalBounds());
        const int height = std::max(getHeight(), panel.preferredHeight() + 48);
        content.setSize(std::max(1, getWidth() - 8), height);
        panel.setBounds((content.getWidth() - 440) / 2,
                        (height - panel.preferredHeight()) / 2, 440,
                        panel.preferredHeight());
    }
    Component content;
    LoginPanel panel;
    Viewport viewport;
};
} // namespace

class Workspace::Caption final : public Component {
    class Light final : public Button {
      public:
        Light(String name, Colour colour, String glyph)
            : Button(name), colour(colour), glyph(std::move(glyph)) {}
        void paintButton(Graphics &g, bool over, bool down) override {
            auto circle = getLocalBounds().toFloat().reduced(3);
            g.setColour(down ? colour.darker(.2f) : colour);
            g.fillEllipse(circle);
            if (over || down) {
                g.setColour(Colours::black.withAlpha(.7f));
                g.setFont(theme::font(10, true));
                g.drawText(glyph, getLocalBounds(), Justification::centred);
            }
        }

      private:
        Colour colour;
        String glyph;
    };

  public:
    explicit Caption(Workspace &owner) : w(owner) {
        for (auto *button : {&minimise, &maximise, &close}) {
            addAndMakeVisible(*button);
            button->setWantsKeyboardFocus(false);
        }
        minimise.setTooltip("Minimizar");
        maximise.setTooltip("Maximizar / Restaurar");
        close.setTooltip(String::fromUTF8("Fechar · Alt+F4"));
        minimise.onClick = [this] {
            if (auto *peer = getTopLevelComponent()->getPeer())
                peer->setMinimised(true);
        };
        maximise.onClick = [this] { toggleMaximise(); };
        close.onClick = [] { JUCEApplication::getInstance()->systemRequestedQuit(); };
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::titlebar);
        g.setColour(theme::line.withAlpha(.5f));
        g.drawHorizontalLine(getHeight() - 1, 0, (float)getWidth());
        g.setFont(theme::font(11));
        g.setColour(Colours::white.withAlpha(.9f));
        g.drawText(String("CatLive Version ") + JUCE_APPLICATION_VERSION_STRING,
                   getWidth() - 252, 0, 154, getHeight(), Justification::centredRight);
        if (w.browserVisible || w.loginPanel)
            return;
        auto saved = Time::fromISO8601(text(w.session.project().updatedAt));
        auto project = text(w.session.project().name) + (w.session.dirty ? " *" : "");
        g.setColour(Colours::white.withAlpha(.9f));
        g.setFont(theme::semiboldFont(11));
        g.drawFittedText(project + String::fromUTF8(" - ") +
                             (w.session.document == File() ? String(String::fromUTF8("Não salvo"))
                                                           : saved.formatted("%d/%m/%Y %H:%M")),
                         14, 0, std::max(180, getWidth() / 2 - 230), getHeight(),
                         Justification::centredLeft, 1);
        g.setColour(theme::green);
        g.drawFittedText(w.auth.title, getWidth() / 2 - 220, 0, 440, getHeight(),
                         Justification::centred, 1);
    }
    void resized() override {
        auto x = getWidth() - 88;
        minimise.setBounds(x, 7, 20, 20);
        maximise.setBounds(x + 26, 7, 20, 20);
        close.setBounds(x + 52, 7, 20, 20);
    }
    void mouseDown(const MouseEvent &e) override {
        if (e.mods.isLeftButtonDown())
            dragger.startDraggingComponent(getTopLevelComponent(), e);
    }
    void mouseDrag(const MouseEvent &e) override {
        if (e.mods.isLeftButtonDown())
            dragger.dragComponent(getTopLevelComponent(), e, nullptr);
    }
    void mouseDoubleClick(const MouseEvent &) override { toggleMaximise(); }

  private:
    Workspace &w;
    Light minimise{"Minimizar", Colour(0xffffbd2e), String::fromUTF8("−")},
        maximise{"Maximizar", Colour(0xff28c840), "+"},
        close{"Fechar", Colour(0xffff5f57), String::fromUTF8("×")};
    ComponentDragger dragger;
    void toggleMaximise() {
        if (auto *peer = getTopLevelComponent()->getPeer()) {
            auto hwnd = (HWND)peer->getNativeHandle();
            ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        }
    }
};

class Workspace::TrackRow final : public Component {
  public:
    TrackRow(Workspace &workspace, ID trackID) : w(workspace), id(std::move(trackID)) {
        for (auto *b : {&mute, &solo, &phase, &fx, &output, &env, &record}) {
            addAndMakeVisible(*b);
            b->setWantsKeyboardFocus(false);
            b->context = [this](Point<int> p) {
                ++w.contextCount;
                w.grabKeyboardFocus();
                w.showTrackMenu(id, p);
            };
        }
        mute.setButtonText("M");
        solo.setButtonText("S");
        phase.setButtonText(String::fromUTF8("Ø"));
        fx.setButtonText("FX");
        record.setButtonText("REC");
        record.setComponentID("trackRecord");
        record.setTooltip(String::fromUTF8("Gravação: desligada / armada / automática na pista "
                                           "selecionada. Clique direito: modo e monitoramento."));
        record.onClick = [this] { w.perform([&] { w.session.cycleRecordArm(id); }); };
        record.context = [this, weakSelf = SafePointer<TrackRow>(this)](Point<int>) {
            if (auto *track = this->track()) {
                PopupMenu menu, mode, format;
                mode.addItem(1, "Mono", true, track->recordingChannels == 1);
                mode.addItem(2, String::fromUTF8("Estéreo"), true,
                             track->recordingChannels.value_or(2) == 2);
                mode.addItem(3, "MIDI", true, track->recordingChannels == 0);
                menu.addSubMenu(String::fromUTF8("Modo de gravação"), mode);
                menu.addItem(4, String::fromUTF8("Monitorar entrada"), true,
                             track->inputMonitoring.value_or(true));
                format.addItem(5, "Advanced", true, !track->recordingFormat);
                format.addItem(6, "WAV 24", true, track->recordingFormat == "wav");
                format.addItem(7, "WAV 32", true, track->recordingFormat == "wav32");
                menu.addSubMenu("Formato", format);
                menu.showMenuAsync(
                    PopupMenu::Options().withTargetComponent(&record),
                    [safe = weakSelf](int result) {
                        if (!safe || !result)
                            return;
                        safe->w.perform([&] {
                            safe->w.session.edit([&](jaras::Project &p) {
                                for (auto &s : p.songs)
                                    for (auto &t : s.tracks)
                                        if (t.id == safe->id) {
                                            if (result <= 3)
                                                t.recordingChannels = result == 3 ? 0 : result;
                                            else if (result == 4)
                                                t.inputMonitoring =
                                                    !t.inputMonitoring.value_or(true);
                                            else if (result == 5)
                                                t.recordingFormat.reset();
                                            else
                                                t.recordingFormat = result == 6 ? "wav" : "wav32";
                                        }
                            });
                        });
                    });
            }
        };
        env.setButtonText("Env");
        env.setColour(TextButton::buttonColourId, Colour(0xffff4444));
        env.setColour(TextButton::textColourOffId, Colours::black);
        env.setTooltip(String::fromUTF8("Envelopes · clique direito abre configurações"));
        env.onClick = [this] {
            w.perform([&] {
                w.session.edit([&](jaras::Project &p) {
                    for (auto &s : p.songs)
                        for (auto &t : s.tracks)
                            if (t.id == id)
                                automation::toggle(t);
                });
            });
        };
        env.context = [this](Point<int>) { w.openAutomation(id); };
        output.setButtonText("1 / 2");
        mute.setTooltip("Mute");
        solo.setTooltip("Solo");
        phase.setTooltip("Inverter polaridade");
        output.setTooltip(String::fromUTF8("Roteamento de saída"));
        fx.setTooltip("Efeitos da pista");
        mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
        solo.setColour(TextButton::buttonOnColourId, theme::yellow);
        for (auto *b : {&mute, &solo, &phase, &fx, &output, &record}) {
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 10);
            b->setColour(TextButton::buttonColourId, Colours::white.withAlpha(.18f));
        }
        phase.setColour(TextButton::buttonOnColourId, Colour(0xffaab8e8));
        mute.onClick = [this] {
            w.perform([&] { w.session.command(jaras::CommandKind::mute, id); });
        };
        solo.onClick = [this] {
            w.perform([&] { w.session.command(jaras::CommandKind::solo, id); });
        };
        phase.onClick = [this] {
            w.perform([&] { w.session.command(jaras::CommandKind::phase, id); });
        };
        fx.onClick = [this] { w.openFX(id); };
        addAndMakeVisible(folder);
        folder.setWantsKeyboardFocus(false);
        folder.setTooltip(String::fromUTF8("Recolher / expandir grupo"));
        folder.getProperties().set("plain", true);
        folder.onClick = [this] { w.toggleGroup(id); };
        output.onClick = [this] {
            Workspace::showPanel(
                "Patch",
                std::make_unique<PatchPanel>(w.session, id,
                                             [safe = SafePointer<Workspace>(&w)](String error) {
                                                 if (safe)
                                                     safe->showError(error);
                                             }),
                360, 400);
        };
        addAndMakeVisible(volume);
        volume.setComponentID("trackVolume");
        volume.setRange(0, 2, .001);
        volume.setSliderStyle(Slider::LinearHorizontal);
        volume.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        volume.setDoubleClickReturnValue(true, 1);
        volume.setTooltip(String::fromUTF8("Volume · duplo clique = 0 dB"));
        volume.onValueChange = [this] {
            if (updating)
                return;
            w.perform(
                [&] { w.session.command(jaras::CommandKind::volume, id, volume.getValue()); });
        };
        addAndMakeVisible(pan);
        pan.setComponentID("trackPan");
        pan.setRange(-1, 1, .01);
        pan.setSliderStyle(Slider::LinearHorizontal);
        pan.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        pan.setDoubleClickReturnValue(true, 0);
        pan.setTooltip(String::fromUTF8("Pan · duplo clique = centro"));
        pan.setColour(Slider::trackColourId, theme::secondary);
        pan.onValueChange = [this] {
            if (updating)
                return;
            w.perform([&] { w.session.command(jaras::CommandKind::pan, id, pan.getValue()); });
        };
        setRepaintsOnMouseActivity(true);
        refresh();
    }
    const jaras::Track *track() const {
        if (auto *s = w.session.song())
            for (auto &t : s->tracks)
                if (t.id == id)
                    return &t;
        return nullptr;
    }
    bool isFolder() const {
        if (const auto *song = w.session.song())
            return std::any_of(song->tracks.begin(), song->tracks.end(),
                               [this](const auto &t) { return t.parentTrackID == id; });
        return false;
    }
    void refresh() {
        if (auto *t = track()) {
            updating = true;
            volume.setValue(t->volume, dontSendNotification);
            pan.setValue(t->pan, dontSendNotification);
            mute.setToggleState(t->mute, dontSendNotification);
            solo.setToggleState(t->solo, dontSendNotification);
            phase.setToggleState(t->phaseInverted.value_or(false), dontSendNotification);
            env.setToggleState(!automation::visible(*t).isEmpty(), dontSendNotification);
            const int arm = w.session.recordArm(id);
            record.setVisible(jaras::fixedTrackName(t->role).empty());
            record.setButtonText(arm == 2 ? "A" : String::fromUTF8("◎"));
            record.getProperties().set("fontSize", arm == 2 ? 11 : 15);
            record.setToggleState(w.session.recordingArmed(id), dontSendNotification);
            record.setColour(TextButton::buttonOnColourId, Colour(0xffec4848));
            record.setColour(TextButton::textColourOffId, Colour(0xffec4848));
            folder.setVisible(isFolder());
            folder.setButtonText({});
            folder.getProperties().set("icon",
                                       w.collapsedGroups.count(id) ? "folder" : "folderOpen");
            folder.setColour(TextButton::textColourOffId, theme::green);
            auto patches = t->outputPatches();
            auto p = patches.empty() ? jaras::OutputPatch{-1, 2} : patches.front();
            output.setButtonText("Patch");
            output.setTooltip(
                p.firstChannel == 0    ? String("Master")
                : p.firstChannel == -1 ? String("None")
                : p.firstChannel == -2
                    ? String("Group")
                    : String(p.firstChannel) +
                          (p.channelCount == 2 ? " / " + String(p.firstChannel + 1) : String()));
            updating = false;
            repaint();
        }
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        if (auto *t = track()) {
            auto colour = theme::track(*t);
            g.setColour(colour.withAlpha(w.selectedTrack == id ? .8f : .55f));
            const auto lanes = automation::visible(*t);
            const int body = getHeight() - lanes.size() * 32;
            g.fillRect(0, 0, getWidth(), body - 1);
            g.setColour(Colours::black.withAlpha(.38f));
            g.fillRect(3, 4, 4, body - 8);
            g.fillRect(10, 4, 4, body - 8);
            g.fillRect(18, 4, 3, body - 8);
            if (const auto *song = w.session.song()) {
                auto parent = t->parentTrackID;
                int depth = 0;
                while (parent && depth < 8) {
                    g.setColour(theme::green.withAlpha(.7f));
                    const int x = 22 + depth * 5;
                    g.drawVerticalLine(x, 0, (float)body);
                    g.drawHorizontalLine(8, (float)x, (float)x + 6);
                    const auto at = trackTree::index(*song, *parent);
                    if (at == song->tracks.size())
                        break;
                    parent = song->tracks[at].parentTrackID;
                    ++depth;
                }
            }
            const float peak = w.session.audio.trackPeak(id);
            if (peak > .00001f) {
                const int height =
                    (int)((body - 8) *
                          jlimit(0.f, 1.f, (Decibels::gainToDecibels(peak) + 60) / 60));
                g.setColour(peak > 1 ? Colour(0xffff4444) : theme::green);
                g.fillRect(3, body - 4 - height, 4, height);
                g.fillRect(10, body - 4 - height, 4, height);
            }
            g.setFont(theme::semiboldFont(12));
            g.setColour(colour.getPerceivedBrightness() > .45f ? Colours::black : Colours::white);
            String number;
            if (const auto *song = w.session.song())
                number = String((int)trackTree::index(*song, id) + 1).paddedLeft('0', 2) + "  ";
            g.drawFittedText(number + text(t->name), 26, 47, getWidth() - 30, 16,
                             Justification::centredLeft, 1);
            for (int i = 0; i < lanes.size(); ++i) {
                const int y = body + i * 32;
                g.setColour(theme::background);
                g.fillRect(0, y, getWidth(), 32);
                g.setColour(Colours::white);
                g.setFont(theme::semiboldFont(11));
                g.drawText(str(lanes[i], "name"), 8, y, getWidth() - 90, 32,
                           Justification::centredLeft);
                g.setColour(flag(lanes[i], "enabled", true) ? theme::green : theme::secondary);
                g.drawEllipse((float)getWidth() - 78, y + 11.f, 10, 10, 1);
                g.setColour(theme::secondary);
                drawInterfaceIcon(g, "mixer", {(float)getWidth() - 56, y + 8.f, 16, 16});
                drawInterfaceIcon(g, "close", {(float)getWidth() - 26, y + 9.f, 14, 14});
            }
        }
        g.setColour(theme::line.withAlpha(.7f));
        g.drawHorizontalLine(getHeight() - 1, 0, (float)getWidth());
    }
    void resized() override {
        const int right = getWidth() - 4;
        solo.setBounds(right - 22, 3, 22, 21);
        mute.setBounds(right - 47, 3, 22, 21);
        pan.setBounds(right - 92, 3, 42, 24);
        record.setBounds(right - 117, 3, 22, 21);
        fx.setBounds(right - 142, 3, 22, 21);
        env.setBounds(right - 176, 3, 30, 21);
        env.getProperties().set("flat", true);
        env.getProperties().set("fontSize", 10);
        output.setBounds(right - 217, 3, 38, 21);
        folder.setBounds(right - 241, 3, 20, 21);
        phase.setBounds(right - 22, 28, 22, 20);
        phase.getProperties().set("plain", true);
        volume.setBounds(22, 27, getWidth() - 52, 20);
    }
    void mouseDown(const MouseEvent &e) override {
        if (auto *t = track()) {
            const auto lanes = automation::visible(*t);
            const int body = getHeight() - lanes.size() * 32;
            if (e.y >= body && lanes.size()) {
                const int index = jlimit(0, lanes.size() - 1, (e.y - body) / 32);
                if (e.x > getWidth() - 30 || e.x > getWidth() - 82 && e.x < getWidth() - 60) {
                    const auto curveID = str(lanes[index], "id");
                    const bool hide = e.x > getWidth() - 30;
                    w.perform([&] {
                        w.session.edit([&](jaras::Project &p) {
                            for (auto &s : p.songs)
                                for (auto &t : s.tracks)
                                    if (t.id == id) {
                                        auto settings = automation::settings(t);
                                        auto curves = list(get(settings, "envelopes"));
                                        for (auto &curve : curves)
                                            if (str(curve, "id") == curveID)
                                                put(curve, hide ? "visible" : "enabled",
                                                    hide ? false : !flag(curve, "enabled", true));
                                        put(settings, "envelopes", curves);
                                        t.automationJSON = utf8(JSON::toString(settings, true));
                                    }
                        });
                    });
                } else
                    w.openAutomation(id);
                return;
            }
        }
        w.selectedTrack = id;
        w.selectedClip.clear();
        repaint();
        if (e.mods.isPopupMenu()) {
            ++w.contextCount;
            w.showTrackMenu(id, e.getScreenPosition());
        } else {
            dragging = true;
        }
    }
    void mouseDrag(const MouseEvent &e) override {
        if (dragging && e.getDistanceFromDragStart() > 8)
            setMouseCursor(MouseCursor::DraggingHandCursor);
    }
    void mouseUp(const MouseEvent &e) override {
        setMouseCursor(MouseCursor::NormalCursor);
        if (dragging && e.getDistanceFromDragStart() > 12) {
            auto inParent = e.getEventRelativeTo(&w.tracksContent);
            int index = w.rowAt(inParent.y);
            if (auto *song = w.session.song())
                if (index >= 0 && index < (int)song->tracks.size())
                    w.perform([&] { w.session.reorderTrack(id, song->tracks[(size_t)index].id); });
        }
        dragging = false;
    }
    void mouseDoubleClick(const MouseEvent &) override { w.editTrack(id); }

  private:
    Workspace &w;
    ID id;
    QuietButton mute, solo, phase, fx, output, env, record;
    TextButton folder;
    Slider volume, pan;
    bool updating = false, dragging = false;
};

class Workspace::Timeline final : public Component, private ScrollBar::Listener {
  public:
    explicit Timeline(Workspace &owner)
        : w(owner), horizontal(false), vertical(true), canvas(*this), heads(*this) {
        addAndMakeVisible(canvas);
        addAndMakeVisible(heads);
        addAndMakeVisible(horizontal);
        addAndMakeVisible(vertical);
        horizontal.addListener(this);
        vertical.addListener(this);
        canvas.setBufferedToImage(true);
        canvas.addAndMakeVisible(envelopeContent);
        envelopeContent.setInterceptsMouseClicks(false, true);
        heads.setInterceptsMouseClicks(false, false);
        setWantsKeyboardFocus(false);
    }
    void resized() override {
        auto area = getLocalBounds();
        horizontal.setBounds(area.removeFromBottom(12).withTrimmedRight(12));
        vertical.setBounds(area.removeFromRight(12));
        canvas.setBounds(area);
        heads.setBounds(area);
        updateRanges();
    }
    void updateRanges() {
        auto *s = w.session.song();
        double length = s ? s->duration : 120;
        horizontal.setRangeLimits(
            0, std::max((double)canvas.getWidth(), length * w.pixelsPerSecond + 120));
        horizontal.setCurrentRange(horizontal.getCurrentRangeStart(), canvas.getWidth());
        vertical.setRangeLimits(
            0, std::max(canvas.getHeight() - ruler, w.rowTop(s ? (int)s->tracks.size() : 0) + 16));
        vertical.setCurrentRange(w.verticalOffset, std::max(1, canvas.getHeight() - ruler));
        invalidate();
    }
    void invalidate() {
        if (lanesRevision != w.session.revision) {
            lanes.clear();
            lanePositions.clear();
            lanesRevision = w.session.revision;
            if (auto *s = w.session.song())
                for (size_t row = 0; row < s->tracks.size(); ++row) {
                    const auto &track = s->tracks[row];
                    int lane = 0;
                    for (auto curve : automation::visible(track)) {
                        auto *view = lanes.add(new EnvelopeLane(
                            w.session, track.id, curve, [this](double t) { return xAt(t); },
                            [this](float x) { return timeAt(x); },
                            [safe = SafePointer<Workspace>(&w)](String error) {
                                if (safe)
                                    safe->showError(error);
                            }));
                        envelopeContent.addAndMakeVisible(view);
                        lanePositions.push_back({(int)row, lane++});
                    }
                }
        }
        envelopeContent.setBounds(0, ruler, canvas.getWidth(),
                                  std::max(0, canvas.getHeight() - ruler));
        for (int i = 0; i < lanes.size(); ++i) {
            const auto [row, lane] = lanePositions[(size_t)i];
            lanes[i]->setVisible(!w.rowHidden(row));
            lanes[i]->setBounds(0,
                                w.rowTop(row) + w.rowBodyHeight(row) + lane * 32 - w.verticalOffset,
                                canvas.getWidth(), 32);
            lanes[i]->repaint();
        }
        canvas.repaint();
        heads.repaint();
    }
    void animate() {
        const auto &state = w.session.transport();
        int a = (int)std::floor(xAt(state.position)),
            b = (int)std::floor(xAt(state.subPlay.position));
        if (state.loop.enabled != lastLoop) {
            heads.repaint();
            lastLoop = state.loop.enabled;
        }
        if (a != lastMain) {
            heads.repaint(lastMain - 7, 0, 15, heads.getHeight());
            heads.repaint(a - 7, 0, 15, heads.getHeight());
            lastMain = a;
        }
        if (b != lastSub) {
            heads.repaint(lastSub - 7, 0, 15, heads.getHeight());
            heads.repaint(b - 7, 0, 15, heads.getHeight());
            lastSub = b;
        }
    }
    double timeAt(float x) const {
        return std::max(0.0, ((double)x + horizontal.getCurrentRangeStart()) / w.pixelsPerSecond);
    }
    float xAt(double t) const {
        return (float)(t * w.pixelsPerSecond - horizontal.getCurrentRangeStart());
    }
    void zoomAt(double scale, float anchor) {
        auto old = timeAt(anchor);
        w.pixelsPerSecond = jlimit(.005, 500.0, scale);
        updateRanges();
        horizontal.setCurrentRangeStart(old * w.pixelsPerSecond - anchor);
        invalidate();
    }
    void fit() {
        if (auto *s = w.session.song()) {
            w.pixelsPerSecond = jlimit(
                .005, 500.0, std::max(1, canvas.getWidth() - 40) / std::max(1., s->duration));
            horizontal.setCurrentRangeStart(0);
            updateRanges();
        }
    }
    void scroll(double x, double y) {
        if (x != 0)
            horizontal.setCurrentRangeStart(horizontal.getCurrentRangeStart() + x);
        if (y != 0)
            vertical.setCurrentRangeStart(vertical.getCurrentRangeStart() + y);
    }
    var state() const {
        auto v = object();
        put(v, "horizontal", horizontal.getCurrentRangeStart());
        put(v, "vertical", vertical.getCurrentRangeStart());
        put(v, "zoom", w.pixelsPerSecond);
        put(v, "width", canvas.getWidth());
        return v;
    }
    void mouseWheelMove(const MouseEvent &e, const MouseWheelDetails &d) override {
        ++w.wheelCount;
        if (e.mods.isCtrlDown())
            zoomAt(w.pixelsPerSecond * std::pow(1.3, d.deltaY * 4), e.position.x);
        else if (e.mods.isShiftDown())
            scroll(-d.deltaY * 500 - d.deltaX * 500, 0);
        else
            scroll(-d.deltaX * 500, -d.deltaY * 300);
    }

  private:
    Workspace &w;
    static constexpr int ruler = 64;
    ScrollBar horizontal, vertical;
    Component envelopeContent;
    OwnedArray<EnvelopeLane> lanes;
    std::vector<std::pair<int, int>> lanePositions;
    uint64 lanesRevision = ~uint64(0);
    int lastMain = -100, lastSub = -100;
    bool lastLoop = false;
    class Canvas final : public Component {
      public:
        explicit Canvas(Timeline &timeline) : t(timeline) { setOpaque(true); }
        void paint(Graphics &g) override {
            g.fillAll(t.w.appearance.colour("jaras.timeline.background", 0x1e1e1e));
            auto *song = t.w.session.song();
            if (!song)
                return;
            auto bounds = getLocalBounds();
            const auto viewStart = t.timeAt(0), viewEnd = t.timeAt((float)getWidth());
            g.setColour(theme::display);
            g.fillRect(0, 0, getWidth(), ruler);
            g.setFont(theme::font(10));
            const double beat = 60.0 / song->bpm * 4 / std::max(1, song->beatUnit);
            double bar = beat * song->beatsPerBar;
            int barStep = 1;
            while (bar * t.w.pixelsPerSecond * barStep < 42)
                barStep *= 2;
            int labelStep = barStep;
            const double labelSpacing = 130 + 50 * jlimit(0., 1., -std::log10(t.w.pixelsPerSecond));
            while (bar * t.w.pixelsPerSecond * labelStep < labelSpacing)
                labelStep *= 2;
            auto first = (int)std::floor(viewStart / (bar * barStep));
            for (int i = std::max(0, first); i * bar * barStep < viewEnd + bar * barStep; ++i) {
                double time = i * bar * barStep;
                float x = t.xAt(time);
                g.setColour(theme::line.withAlpha(.45f));
                g.drawVerticalLine((int)x, 48, (float)getHeight());
                g.setColour(theme::green.withAlpha(.65f));
                g.drawVerticalLine((int)x, 48, 53);
                if ((i * barStep) % labelStep == 0) {
                    const auto milliseconds = (int64)std::llround(time * 1000);
                    auto label = clockText(milliseconds / 1000., true);
                    if (milliseconds % 1000 != 0)
                        label += "." + String(milliseconds % 1000).paddedLeft('0', 3);
                    g.setFont(
                        Font(FontOptions(Font::getDefaultMonospacedFontName(), 9.f, Font::plain)));
                    g.drawText(label, (int)x + 3, 48, 120, 16, Justification::centredLeft);
                }
            }
            if (song->markers)
                for (const auto &m : *song->markers) {
                    float x = t.xAt(m.position);
                    if (x < -150 || x > getWidth())
                        continue;
                    auto colour = Colour(0xff000000 | m.color);
                    g.setColour(colour.withAlpha(.75f));
                    const int markerY = m.tempoBPM ? 32 : 16;
                    g.fillRoundedRectangle(x, (float)markerY + 1, 110, 14, 2);
                    g.setColour(Colours::white);
                    g.setFont(theme::font(10));
                    auto label =
                        m.tempoBPM
                            ? String(*m.tempoBPM, *m.tempoBPM == std::floor(*m.tempoBPM) ? 0 : 1) +
                                  "  " + String(m.tempoBeats.value_or(4)) + "/" +
                                  String(m.tempoUnit.value_or(4))
                            : text(m.name);
                    g.drawFittedText(label, (int)x + 5, markerY, 100, 16,
                                     Justification::centredLeft, 1);
                }
            for (const auto &p : song->parts) {
                float a = t.xAt(p.startTime), b = t.xAt(p.endTime);
                if (b < 0 || a > getWidth())
                    continue;
                g.setColour(Colour(0xff000000 | p.color.value_or(0x665566)));
                g.fillRect(a, 0.f, std::max(1.f, b - a - 1), 16.f);
                g.setColour(Colours::white);
                g.setFont(theme::font(10, true));
                g.drawFittedText(text(p.name), (int)a + 7, 0, std::max(0, (int)(b - a) - 12), 16,
                                 Justification::centredLeft, 1);
            }
            g.setColour(theme::line.withAlpha(.65f));
            for (int y : {16, 32, 48, 63})
                g.drawHorizontalLine(y, 0, (float)getWidth());
            g.saveState();
            g.reduceClipRegion(0, ruler, getWidth(), getHeight() - ruler);
            for (size_t row = 0; row < song->tracks.size(); ++row) {
                if (t.w.rowHidden((int)row))
                    continue;
                const int height = t.w.rowBodyHeight((int)row);
                int y = ruler + t.w.rowTop((int)row) - t.w.verticalOffset;
                if (y + height < ruler || y > getHeight())
                    continue;
                const auto &track = song->tracks[row];
                auto background = t.w.appearance.colour("jaras.timeline.background", 0x1e1e1e);
                g.setColour(row % 2 ? background.brighter(.02f) : background);
                g.fillRect(0, y, getWidth(), height);
                g.setColour(theme::line.withAlpha(.5f));
                g.drawHorizontalLine(y + height - 1, 0, (float)getWidth());
                if (t.w.appearance.gridlines()) {
                    for (int i = std::max(0, first); i * bar * barStep < viewEnd + bar * barStep;
                         ++i) {
                        const auto at = i * bar * barStep;
                        g.setColour(t.w.appearance.colour("jaras.timeline.primaryGrid", 0x535250));
                        g.drawVerticalLine((int)t.xAt(at), (float)y, (float)(y + height));
                        if (bar * barStep * t.w.pixelsPerSecond > 64) {
                            g.setColour(
                                t.w.appearance.colour("jaras.timeline.secondaryGrid", 0x333235));
                            for (int sub = 1; sub < 4; ++sub)
                                g.drawVerticalLine((int)t.xAt(at + bar * barStep * sub / 4.),
                                                   (float)y, (float)(y + height));
                        }
                    }
                }
                for (const auto &clip : track.clips) {
                    float left = t.xAt(clip.startTime),
                          right = t.xAt(clip.startTime + clip.duration);
                    if (right < 0 || left > getWidth())
                        continue;
                    auto colour = theme::track(track);
                    auto rect = juce::Rectangle<float>(
                        left, y + 3.f, std::max(2.f, right - left - 1), height - 6.f);
                    const bool muted = track.mute || clip.muted;
                    g.setGradientFill(ColourGradient(
                        colour.withAlpha(muted ? .55f : 1.f), 0, rect.getY(),
                        colour.withAlpha(muted ? .25f : .78f), 0, rect.getBottom(), false));
                    g.fillRoundedRectangle(rect, 3);
                    g.setColour(t.w.selectedClip == clip.id ? theme::green
                                                            : colour.withAlpha(.75f));
                    g.drawRoundedRectangle(rect, 3, t.w.selectedClip == clip.id ? 1.5f : .6f);
                    g.setColour(Colours::black.withAlpha(.16f));
                    g.fillRect(rect.withHeight(std::min(17.f, rect.getHeight())));
                    const float headerLeft = std::max(0.f, left);
                    const float headerRight = std::min((float)getWidth(), right);
                    const bool muteButton = !clip.text && headerRight - headerLeft >= 27.3f;
                    const float nameLeft = headerLeft + (muteButton ? 28.f : 6.f);
                    if (muteButton) {
                        auto button =
                            juce::Rectangle<float>(headerLeft + 2.6f, y + 3.f, 22.1f, 17.f);
                        g.setColour(clip.muted ? Colour(0xffff5555)
                                               : Colours::white.withAlpha(.12f));
                        g.fillRoundedRectangle(button, 2);
                        g.setFont(theme::font(9, true));
                        g.setColour(Colours::white);
                        g.drawText("M", button, Justification::centred);
                    }
                    g.setFont(theme::font(10, true));
                    g.setColour(Colours::white.withAlpha(track.mute ? .5f : .95f));
                    if (headerRight - nameLeft >= 12)
                        g.drawText(text(clip.name),
                                   juce::Rectangle<float>(nameLeft, y + 4.f,
                                                          headerRight - nameLeft - 3, 15),
                                   Justification::centredLeft, true);
                    if (clip.text && !clip.text->empty() && right - left >= 24) {
                        g.setFont(theme::font(14));
                        g.drawFittedText(text(*clip.text), (int)left + 6, y + 23,
                                         std::max(1, (int)(right - left) - 12),
                                         std::max(1, height - 28), Justification::centred,
                                         std::max(1, (height - 28) / 16), .5f);
                    }
                    const auto start = std::max(0, (int)std::floor(left)),
                               end = std::min(getWidth(), (int)std::ceil(right));
                    const float centre = y + height * .65f, amplitude = height * .23f;
                    if (!clip.waveform.empty()) {
                        g.setColour(Colours::white.withAlpha(muted ? .45f : .75f));
                        for (int x = start; x < end; x += 2) {
                            const auto fraction =
                                jlimit(0.0, 1.0, ((double)x - left) / std::max(1.0f, right - left));
                            auto index = (size_t)std::min<double>(
                                clip.waveform.size() - 1,
                                std::floor(fraction * clip.waveform.size()));
                            float peak = (float)std::min(1.0, clip.waveform[index]) * amplitude;
                            g.drawVerticalLine(x, centre - std::max(.5f, peak),
                                               centre + std::max(.5f, peak));
                        }
                    }
                }
            }
            g.restoreState();
            if (song->tracks.empty()) {
                g.setColour(theme::secondary);
                g.setFont(theme::font(15));
                g.drawText(String::fromUTF8("Arraste seus multitracks para cá"),
                           bounds.withTrimmedTop(ruler), Justification::centred);
                g.setFont(theme::font(11));
                g.drawText(
                    String::fromUTF8("WAV · AIFF · FLAC · MP3 · OGG   /   Ctrl+I para importar"),
                    bounds.withTrimmedTop(ruler + 58), Justification::centred);
            }
        }
        void paintOverChildren(Graphics &g) override {
            if (!dragPreview)
                return;
            const float x = t.xAt(previewStart), right = t.xAt(previewEnd);
            const float y = (float)(ruler + t.w.rowTop(previewRow) - t.w.verticalOffset + 3);
            auto bounds = juce::Rectangle<float>(x, y, std::max(2.f, right - x - 1),
                                                 (float)t.w.rowHeight(previewRow) - 6);
            g.setColour(theme::green.withAlpha(.16f));
            g.fillRoundedRectangle(bounds, 3);
            g.setColour(theme::green);
            g.drawRoundedRectangle(bounds, 3, 2);
        }
        void mouseDown(const MouseEvent &e) override {
            startTime = t.timeAt(e.position.x);
            startPosition = e.position;
            dragClip.clear();
            dragPreview = false;
            resizeEdge = 0;
            t.w.grabKeyboardFocus();
            if (e.y >= 16 && e.y < ruler) {
                if (e.mods.isPopupMenu()) {
                    ++t.w.contextCount;
                    PopupMenu m;
                    m.addItem(1, "Adicionar marcador aqui");
                    m.addItem(2, String::fromUTF8("Adicionar seção aqui"));
                    m.addItem(3, String::fromUTF8("Início do loop aqui"));
                    m.addItem(4, "Fim do loop aqui");
                    m.showMenuAsync(
                        PopupMenu::Options().withTargetScreenArea(
                            {e.getScreenX(), e.getScreenY(), 1, 1}),
                        [safe = Component::SafePointer<Canvas>(this),
                         time = startTime](int result) {
                            if (!safe)
                                return;
                            auto &w = safe->t.w;
                            if (result == 1 || result == 2)
                                w.prompt(
                                    result == 1 ? "Novo marcador" : String::fromUTF8("Nova seção"),
                                    "Nome", result == 1 ? "Marcador" : String::fromUTF8("Seção"),
                                    [safe, time, result](String name) {
                                        if (safe)
                                            safe->t.w.perform([&] {
                                                safe->t.w.session.addMarker(name, time,
                                                                            result == 2);
                                            });
                                    });
                            if (result == 3 || result == 4)
                                w.perform([&] {
                                    w.session.command(result == 3 ? jaras::CommandKind::loopStart
                                                                  : jaras::CommandKind::loopEnd,
                                                      {}, time);
                                });
                        });
                } else {
                    subDrag = e.mods.isAltDown();
                    mainDrag = true;
                    t.w.perform([&] {
                        t.w.session.command(subDrag ? jaras::CommandKind::subSeek
                                                    : jaras::CommandKind::editSeek,
                                            {}, startTime);
                    });
                }
                return;
            }
            if (e.y < 16) {
                if (auto *s = t.w.session.song())
                    for (const auto &p : s->parts)
                        if (startTime >= p.startTime && startTime < p.endTime) {
                            if (e.mods.isPopupMenu()) {
                                ++t.w.contextCount;
                                t.w.prompt(
                                    String::fromUTF8("Renomear região"), "Nome", text(p.name),
                                    [safe = Component::SafePointer<Canvas>(this),
                                     id = p.id](String name) {
                                        if (safe)
                                            safe->t.w.perform([&] {
                                                safe->t.w.session.edit([&](jaras::Project &p) {
                                                    for (auto &s : p.songs)
                                                        for (auto &part : s.parts)
                                                            if (part.id == id)
                                                                part.name = utf8(name);
                                                });
                                            });
                                    });
                            } else
                                t.w.perform([&] {
                                    t.w.session.command(t.w.session.transport().playing
                                                            ? jaras::CommandKind::queueRegion
                                                            : jaras::CommandKind::selectRegion,
                                                        p.id);
                                });
                            return;
                        }
                return;
            }
            int row = t.w.rowAt(e.y - ruler + t.w.verticalOffset);
            if (auto *s = t.w.session.song())
                if (row >= 0 && row < (int)s->tracks.size()) {
                    auto &track = s->tracks[(size_t)row];
                    t.w.selectedTrack = track.id;
                    for (const auto &c : track.clips)
                        if (startTime >= c.startTime && startTime < c.startTime + c.duration) {
                            t.w.selectedClip = c.id;
                            if (e.mods.isPopupMenu()) {
                                ++t.w.contextCount;
                                t.w.showClipMenu(c.id, e.getScreenPosition());
                            } else if (!c.text &&
                                       std::min((float)getWidth(),
                                                t.xAt(c.startTime + c.duration)) -
                                               std::max(0.f, t.xAt(c.startTime)) >=
                                           27.3f &&
                                       juce::Rectangle<float>(std::max(0.f, t.xAt(c.startTime)) +
                                                                  2.6f,
                                                              (float)(ruler + t.w.rowTop(row) -
                                                                      t.w.verticalOffset + 3),
                                                              22.1f, 17.f)
                                           .contains(e.position)) {
                                const auto clipID = c.id;
                                t.w.perform([&] {
                                    t.w.session.edit([&](jaras::Project &project) {
                                        for (auto &song : project.songs)
                                            for (auto &track : song.tracks)
                                                for (auto &item : track.clips)
                                                    if (item.id == clipID)
                                                        item.muted = !item.muted;
                                    });
                                });
                            } else {
                                dragClip = c.id;
                                originalStart = c.startTime;
                                clipLength = c.duration;
                                sourceRow = row;
                                resizeEdge =
                                    std::abs(e.position.x - t.xAt(c.startTime)) <= 5 ? -1
                                    : std::abs(e.position.x - t.xAt(c.startTime + c.duration)) <= 5
                                        ? 1
                                        : 0;
                            }
                            t.invalidate();
                            return;
                        }
                }
            t.w.selectedClip.clear();
            if (e.mods.isPopupMenu()) {
                ++t.w.contextCount;
                PopupMenu m;
                m.addItem(1, String::fromUTF8("Importar áudio…"));
                m.addItem(2, String::fromUTF8("Criar região a partir do cursor"));
                if (auto *song = t.w.session.song();
                    song && row >= 0 && row < (int)song->tracks.size()) {
                    const auto &role = song->tracks[(size_t)row].role;
                    if (jaras::isTeleprompterRole(role) || role.id == "chords")
                        m.addItem(3, "Adicionar texto");
                    else if (jaras::fixedTrackName(role).empty() && role.id != "group")
                        m.addItem(4, "Adicionar item MIDI");
                }
                m.showMenuAsync(
                    PopupMenu::Options().withTargetComponent(this),
                    [safe = Component::SafePointer<Canvas>(this), time = startTime,
                     trackID = t.w.selectedTrack](int id) {
                        if (!safe)
                            return;
                        if (id == 1)
                            safe->t.w.chooseImport();
                        if (id == 3)
                            safe->t.w.addTextItem(trackID, time);
                        if (id == 4)
                            safe->t.w.addMIDIItem(trackID, time);
                        if (id == 2)
                            safe->t.w.prompt(
                                String::fromUTF8("Nova região"), "Nome",
                                String::fromUTF8("Nova música"), [safe, time](String name) {
                                    if (safe)
                                        safe->t.w.perform([&] {
                                            auto *s = safe->t.w.session.song();
                                            if (s)
                                                safe->t.w.session.addRegion(
                                                    name, time, std::min(s->duration, time + 30));
                                        });
                                });
                    });
            }
        }
        void mouseDrag(const MouseEvent &e) override {
            if (mainDrag) {
                t.w.perform([&] {
                    t.w.session.command(subDrag ? jaras::CommandKind::subSeek
                                                : jaras::CommandKind::editSeek,
                                        {}, t.timeAt(e.position.x));
                });
            } else if (!dragClip.empty() && e.getDistanceFromDragStart() > 4) {
                updateDrag(e);
                setMouseCursor(resizeEdge ? MouseCursor::LeftRightResizeCursor
                                          : MouseCursor::DraggingHandCursor);
                repaint();
            }
        }
        void mouseUp(const MouseEvent &e) override {
            mainDrag = false;
            setMouseCursor(MouseCursor::NormalCursor);
            if (!dragClip.empty() && e.getDistanceFromDragStart() > 4) {
                updateDrag(e);
                auto id = dragClip;
                t.w.perform([&] {
                    ID destinationTrack;
                    if (auto *song = t.w.session.song();
                        song && previewRow >= 0 && previewRow < (int)song->tracks.size())
                        destinationTrack = song->tracks[(size_t)previewRow].id;
                    t.w.session.edit([&](jaras::Project &p) {
                        if (resizeEdge)
                            clipEditing::resize(p, id, previewStart, previewEnd);
                        else
                            clipEditing::move(p, id, previewStart, destinationTrack);
                    });
                    if (!resizeEdge && !destinationTrack.empty())
                        t.w.selectedTrack = destinationTrack;
                });
            }
            dragClip.clear();
            dragPreview = false;
            repaint();
        }
        void mouseDoubleClick(const MouseEvent &e) override {
            if (e.y < 46) {
                t.w.perform([&] {
                    t.w.session.command(jaras::CommandKind::seek, {}, t.timeAt(e.position.x));
                });
                return;
            }
            if (!t.w.selectedClip.empty()) {
                if (auto *song = t.w.session.song())
                    for (const auto &track : song->tracks)
                        for (const auto &clip : track.clips)
                            if (clip.id == t.w.selectedClip) {
                                if (clip.midi) {
                                    t.w.openMIDIEditor(clip.id);
                                    return;
                                }
                                if (clip.text && !clip.audioFile) {
                                    t.w.editTextItem(clip.id);
                                    return;
                                }
                            }
                t.w.showClipMenu(t.w.selectedClip, e.getScreenPosition());
            }
        }
        void mouseWheelMove(const MouseEvent &e, const MouseWheelDetails &d) override {
            t.mouseWheelMove(e, d);
        }

      private:
        Timeline &t;
        double startTime = 0, originalStart = 0, clipLength = 0;
        Point<float> startPosition;
        ID dragClip;
        bool mainDrag = false, subDrag = false;
        int sourceRow = 0;
        bool dragPreview = false;
        int resizeEdge = 0, previewRow = 0;
        double previewStart = 0, previewEnd = 0;
        void updateDrag(const MouseEvent &e) {
            double edge = (resizeEdge > 0 ? originalStart + clipLength : originalStart) +
                          t.timeAt(e.position.x) - startTime;
            edge = std::max(0., edge);
            if (!e.mods.isShiftDown())
                if (auto *song = t.w.session.song()) {
                    const double beat = 60. / song->bpm;
                    edge = std::round(edge / beat) * beat;
                }
            previewStart =
                resizeEdge > 0
                    ? originalStart
                    : std::min(edge, resizeEdge < 0 ? originalStart + clipLength - .01 : edge);
            previewEnd = resizeEdge < 0   ? originalStart + clipLength
                         : resizeEdge > 0 ? std::max(originalStart + .01, edge)
                                          : previewStart + clipLength;
            previewRow = resizeEdge ? sourceRow : t.w.rowAt(e.y - ruler + t.w.verticalOffset);
            if (previewRow < 0 || previewRow >= t.w.rows.size())
                previewRow = sourceRow;
            dragPreview = true;
        }
    } canvas;
    class Heads final : public Component {
      public:
        explicit Heads(Timeline &timeline) : t(timeline) {}
        void paint(Graphics &g) override {
            const auto &state = t.w.session.transport();
            auto head = [&](double position, Colour colour, int y) {
                float x = t.xAt(position);
                if (x < 0 || x > getWidth())
                    return;
                g.setColour(colour.withAlpha(.12f));
                g.fillRect(x - 3, 0.f, 6.f, (float)getHeight());
                g.setColour(colour);
                g.fillRect(x - .7f, 0.f, 1.4f, (float)getHeight());
                Path p;
                p.addTriangle(x - 5, (float)y, x + 5, (float)y, x, y + 9.f);
                g.fillPath(p);
            };
            head(state.editPosition, t.w.appearance.colour("jaras.timeline.editCursor", 0xb9e229),
                 46);
            if (state.playing || state.paused)
                head(state.position, t.w.appearance.colour("jaras.timeline.playCursor", 0x7548dd),
                     46);
            if (state.subPlay.playing || state.subPlay.position != state.editPosition)
                head(state.subPlay.position,
                     t.w.appearance.colour("jaras.timeline.subPlayCursor", 0xff6f00), 46);
            if (state.loop.enabled && t.w.session.song()) {
                auto a = t.xAt(state.loop.start.value_or(0)),
                     b = t.xAt(state.loop.end.value_or(t.w.session.song()->duration));
                g.setColour(theme::green.withAlpha(.10f));
                g.fillRect(a, 0.f, b - a, (float)getHeight());
            }
        }

      private:
        Timeline &t;
    } heads;
    void scrollBarMoved(ScrollBar *bar, double position) override {
        if (bar == &vertical) {
            w.verticalOffset = (int)std::round(position);
            w.tracksViewport.setViewPosition(0, w.verticalOffset);
        }
        invalidate();
    }
};

#include "SetlistView.h"

TextButton &Workspace::button(String id, const String &title, std::function<void()> action,
                              Colour colour) {
    auto *b = buttons.add(new QuietButton(title));
    addAndMakeVisible(b);
    controls[id] = b;
    b->setComponentID(id);
    b->getProperties().set("fontSize", 10);
    b->setWantsKeyboardFocus(false);
    b->setColour(TextButton::buttonColourId, colour.isTransparent() ? theme::panel : colour);
    b->onClick = [this, action] { perform(action); };
    return *b;
}
Workspace::Workspace(Session &s, Auth &a, Lighting &l, bool homePreview, File appearanceFile)
    : session(s), auth(a), lighting(l), appearance(std::move(appearanceFile)),
      actions(appearance, s.audio.devices), stage(appearance) {
    LookAndFeel::setDefaultLookAndFeel(&look);
    setLookAndFeel(&look);
    remotePresentation = std::make_unique<remote::Presentation>(session, stage);
    remoteHost = std::make_unique<remote::Host>(appearance);
    remotePresentation->save = [this] { chooseSave(); };
    remoteHost->presentation = [this](int panel) -> var {
        return projectReady && !loginPanel ? remotePresentation->snapshot(panel) : var();
    };
    remoteHost->perform = [this](const remote::Command &command) {
        return projectReady && !loginPanel && !browserVisible && remotePresentation->apply(command);
    };
    remoteHost->image = [this](const remote::Command &command) {
        return projectReady && !loginPanel ? remotePresentation->image(command) : remote::Bytes{};
    };
    appearance.addChangeListener(this);
    try {
        session.audio.configureMetronome(metronomePreferences(appearance));
    } catch (const std::exception &e) {
        session.message = String::fromUTF8(e.what());
    }
    for (int slot = 0; slot < 3; ++slot)
        session.audio.setMIDISlot(
            slot, appearance.value("catlive.midi.slot" + String(slot + 1)).toString());
    localization::english = appearance.value("jaras.language", "pt-BR").toString() == "en";
    actions.invoke = [this](const String &id, float value, int track) {
        if (projectReady && !loginPanel && !browserVisible)
            perform([&] { performAction(id, value, track); });
    };
    setOpaque(true);
    setWantsKeyboardFocus(true);
    setFocusContainerType(FocusContainerType::keyboardFocusContainer);
    caption = std::make_unique<Caption>(*this);
    timeline = std::make_unique<Timeline>(*this);
    setlist = std::make_unique<Setlist>(*this);
    addAndMakeVisible(*caption);
    addAndMakeVisible(*timeline);
    addAndMakeVisible(*setlist);
    stageTimer = std::make_unique<StageTimerControl>(stage, [this] { openTimer(true); });
    addAndMakeVisible(*stageTimer);
    tempoControl =
        std::make_unique<TempoControl>(session, [this](String error) { showError(error); });
    addAndMakeVisible(*tempoControl);
    footerMixer = std::make_unique<MixerPanel>(
        session, [this](ID id) { openFX(id); },
        [this](ID id) {
            selectedTrack = id;
            session.audio.setKeyboardTarget(id);
            repaint();
        },
        [this](String error) { showError(error); });
    addChildComponent(*footerMixer);
    partsPanel =
        std::make_unique<PartsPanel>(session, [this](String message) { showError(message); });
    addChildComponent(*partsPanel);
    partsSidebar =
        std::make_unique<PartsPanel>(session, [this](String message) { showError(message); }, true);
    addChildComponent(*partsSidebar);
    tuner = std::make_unique<TunerControl>(
        session,
        [this](int delta) {
            perform([&] { performAction(delta > 0 ? "tunerUp" : "tunerDown", 1, 0); });
        },
        [this] {
            if (auto *part = tuner->region()) {
                auto safe = SafePointer<Workspace>(this);
                ModalSheet::open(*this, String::fromUTF8("Pitch · ") + text(part->name),
                                 std::make_unique<PitchTargetsPanel>(
                                     session, part->id,
                                     [safe] {
                                         if (safe)
                                             ModalSheet::dismiss(*safe);
                                     },
                                     [safe](String message) {
                                         if (safe)
                                             safe->showError(message);
                                     }),
                                 410, 416);
            }
        });
    addAndMakeVisible(*tuner);
    addAndMakeVisible(tracksViewport);
    keyboard = std::make_unique<MidiKeyboardComponent>(session.audio.keyboardState,
                                                       MidiKeyboardComponent::horizontalKeyboard);
    keyboard->setAvailableRange(24, 108);
    keyboard->setKeyWidth(22);
    addAndMakeVisible(*keyboard);
    keyboard->setVisible(false);
    tracksViewport.setViewedComponent(&tracksContent, false);
    tracksViewport.setScrollBarsShown(false, false);
    tracksViewport.setScrollOnDragMode(Viewport::ScrollOnDragMode::never);
    tracksViewport.addMouseListener(this, true);
    for (auto *slider : {&masterVolume, &masterPan, &zoom}) {
        addAndMakeVisible(*slider);
        slider->setSliderStyle(Slider::LinearHorizontal);
        slider->setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
    }
    masterVolume.setRange(0, 2, .001);
    masterVolume.setComponentID("masterVolume");
    masterPan.setComponentID("masterPan");
    masterVolume.setDoubleClickReturnValue(true, 1);
    masterVolume.setTooltip(String::fromUTF8("Master · volume"));
    masterVolume.onValueChange = [this] {
        perform([&] { session.command(jaras::CommandKind::volume, {}, masterVolume.getValue()); });
    };
    masterPan.setRange(-1, 1, .01);
    masterPan.setDoubleClickReturnValue(true, 0);
    masterPan.setTooltip(String::fromUTF8("Master · pan"));
    masterPan.setColour(Slider::trackColourId, theme::secondary);
    masterPan.onValueChange = [this] {
        perform([&] { session.command(jaras::CommandKind::pan, {}, masterPan.getValue()); });
    };
    zoom.setRange(.005, 500);
    zoom.setSkewFactor(.5);
    zoom.setValue(pixelsPerSecond, dontSendNotification);
    zoom.setTooltip(String::fromUTF8("Zoom horizontal · Ctrl+roda do mouse"));
    zoom.onValueChange = [this] { timeline->zoomAt(zoom.getValue(), 0); };
    for (auto *label : {&songDisplay, &transportTime, &footer, &tempo}) {
        addAndMakeVisible(*label);
        label->setFont(theme::font(11));
    }
    songDisplay.setFont(theme::font(12, true));
    songDisplay.setColour(Label::backgroundColourId, theme::display);
    transportTime.setFont(theme::semiboldFont(12));
    transportTime.setColour(Label::textColourId, Colours::white);
    transportTime.setJustificationType(Justification::centred);
    transportTime.setColour(Label::backgroundColourId, theme::display);
    footer.setFont(theme::font(10));
    footer.setColour(Label::textColourId, theme::secondary);
    tempo.setJustificationType(Justification::centred);
    button(
        "play", String::fromUTF8("▶  Play"),
        [this] {
            session.command(session.transport().playing ? jaras::CommandKind::stop
                                                        : jaras::CommandKind::play);
        },
        Colour(0xff294f36))
        .setTooltip(String::fromUTF8("Play / Stop · Espaço"));
    button("pause", String::fromUTF8("Ⅱ"), [this] {
        session.command(jaras::CommandKind::pause);
    }).setTooltip(String::fromUTF8("Pause · P"));
    button(
        "subplay", String::fromUTF8("▶  Sub Play"),
        [this] {
            session.command(session.transport().subPlay.playing ? jaras::CommandKind::subStop
                                                                : jaras::CommandKind::subPlay);
        },
        Colour(0xff5e542a))
        .setTooltip(
            String::fromUTF8("Sub Play · Shift+Espaço | Alt+clique posiciona o cursor amarelo"));
    button("stopall", String::fromUTF8("■"), [this] {
        session.command(jaras::CommandKind::stopAll);
    }).setTooltip(String::fromUTF8("Stop All · Ctrl+Shift+Espaço"));
    button("loop", String::fromUTF8("↻"), [this] {
        session.command(jaras::CommandKind::toggleLoop);
    }).setTooltip(String::fromUTF8("Loop · L"));
    button("previous", String::fromUTF8("|◀"), [this] {
        session.command(jaras::CommandKind::previous);
    }).setTooltip(String::fromUTF8("Música anterior · Ctrl+←"));
    button("next", String::fromUTF8("▶|"), [this] {
        session.command(jaras::CommandKind::next);
    }).setTooltip(String::fromUTF8("Próxima música · Ctrl+→"));
    button("grandma2", "grandMA2", [this] { openGrandMA2(); }, Colour(0xff504a28));
    button("advanced", "Advanced", [this] { openAdvanced(); });
    auto &metronomeButton = button(
        "metronome", "",
        [this] {
            const bool active = !session.audio.metronomeEnabled.load();
            session.audio.metronomeEnabled = active;
            appearance.set("jaras.metronome.enabled", active);
        },
        Colour(0xffc44848));
    metronomeButton.getProperties().set("icon", "metronome");
    metronomeButton.setTooltip(String::fromUTF8("Metrônomo · clique direito para configurar"));
    static_cast<QuietButton &>(metronomeButton).context = [this](Point<int>) {
        showPanel(String::fromUTF8("Metrônomo"),
                  std::make_unique<MetronomePanel>(appearance, session.audio), 400, 356);
    };
    button("resolume", "Resolume", [this] { openResolume(); });
    button("export", "Exportar", [this] { chooseExport(); });
    button("settings", String::fromUTF8("⚙"), [this] {
        openSettings();
    }).setTooltip(String::fromUTF8("Configurações · Ctrl+, "));
    button("audio", String::fromUTF8("Áudio"), [this] {
        openAudioSettings();
    }).setTooltip("Dispositivo, taxa de amostragem, buffer e roteamento ASIO / WASAPI");
    button("save", "Save", [this] {
        chooseSave();
    }).setTooltip(String::fromUTF8("Salvar · Ctrl+S"));
    button("mixer", "Tracks", [this] {
        mixerVisible = !mixerVisible;
        resized();
    });
    button("setlist", "Setlist", [this] {
        setlistVisible = !setlistVisible;
        resized();
    });
    button("masterMute", "M", [this] { session.command(jaras::CommandKind::mute); });
    button("masterSolo", "S", [this] { session.command(jaras::CommandKind::solo); });
    button("masterMono", String::fromUTF8("Estéreo"),
           [this] { session.command(jaras::CommandKind::masterMono); });
    button("masterFX", "FX", [this] { openFX(); });
    button(
        "record", String::fromUTF8("● REC"), [this] { session.toggleRecording(); },
        Colour(0xff5f3030));
    button("menu", String::fromUTF8("☰"), [self = Component::SafePointer<Workspace>(this)] {
        if (!self)
            return;
        PopupMenu m;
        m.addItem(1, String::fromUTF8("Novo projeto…   Ctrl+N"));
        m.addItem(2, String::fromUTF8("Abrir projeto…   Ctrl+O"));
        m.addItem(3, "Salvar   Ctrl+S");
        m.addItem(4, String::fromUTF8("Salvar como…   Ctrl+Shift+S"));
        m.addSeparator();
        m.addItem(5, String::fromUTF8("Importar áudio…   Ctrl+I"));
        m.addItem(6, String::fromUTF8("Nova música…"));
        m.addSeparator();
        m.addItem(7, "Atalhos de teclado");
        m.showMenuAsync(PopupMenu::Options().withTargetComponent(self->controls["menu"]),
                        [self](int result) {
                            if (!self)
                                return;
                            self->perform([self, result] {
                                if (result == 1)
                                    self->newProject();
                                if (result == 2)
                                    self->chooseOpen();
                                if (result == 3)
                                    self->chooseSave();
                                if (result == 4)
                                    self->chooseSave(true);
                                if (result == 5)
                                    self->chooseImport();
                                if (result == 6)
                                    self->newSong();
                                if (result == 7)
                                    self->showShortcuts();
                            });
                        });
    });
    button("railProjects", String::fromUTF8("▤"), [this] {
        showProjectBrowser();
    }).setTooltip("Projetos");
    button("railImport", String::fromUTF8("↓"), [this] {
        chooseImport();
    }).setTooltip(String::fromUTF8("Importar áudio"));
    button("railUndo", String::fromUTF8("↶"), [this] {
        session.undo();
    }).setTooltip(String::fromUTF8("Desfazer · Ctrl+Z"));
    button("railRedo", String::fromUTF8("↷"), [this] {
        session.redo();
    }).setTooltip(String::fromUTF8("Refazer · Ctrl+Shift+Z"));
    button("railMixer", String::fromUTF8("≡"), [this] {
        footerMixerVisible = !footerMixerVisible;
        resized();
        repaint();
    }).setTooltip("Mixer");
    button("railSections", String::fromUTF8("¶"), [this] { openRegions(); }).setTooltip("Pads");
    button("railKeyboard", String::fromUTF8("♮"), [this] {
        keyboardVisible = !keyboardVisible;
        resized();
        repaint();
    }).setTooltip("Teclado");
    button("soundfont", "SF2", [this] { chooseSoundFont(); });
    button("video", "Video", [this] { openVideo(); });
    button("railTeleprompt", "T", [this] { showTeleprompter(); }).setTooltip("Teleprompter");
    button("tp1", "TP-1", [this] { showTeleprompter(1); }, Colour(0xffc44848));
    button("tp2", "TP-2", [this] { showTeleprompter(2); }, Colour(0xffc44848));
    button("notices", "Recados", [this] { openNotices(); }, Colour(0xff897934));
    button("preview", "Preview", [this] { stage.preview = !stage.preview; }, Colour(0xffc44848));
    auto &remoteButton = button("remote", "Remote", [this] { toggleRemote(); }, Colour(0xffc44848));
    remoteButton.getProperties().set("flat", true);
    remoteButton.setTooltip(String::fromUTF8("Remote · clique direito para configurar"));
    static_cast<QuietButton &>(remoteButton).context = [this](Point<int>) { openRemote(); };
    button("railNotice", "", [this] { openNotices(); }).getProperties().set("icon", "notice");
    button("railClock", "", [this] { openTimer(); }).getProperties().set("icon", "clock");
    controls["railNotice"]->getProperties().set("plain", true);
    controls["railClock"]->getProperties().set("plain", true);
    controls["railNotice"]->setColour(TextButton::textColourOffId, Colour(0xffe7c74c));
    controls["railClock"]->setColour(TextButton::textColourOffId, Colour(0xff299df8));
    button("railTeleprompt2", "TP2", [this] { showTeleprompter(2); }).setTooltip("Teleprompter 2");
    controls["railTeleprompt"]->setButtonText("TP1");
    button("railSettings", String::fromUTF8("⚙"), [this] {
        openSettings();
    }).setTooltip(String::fromUTF8("Configurações"));
    button("railHelp", "?", [this] { showShortcuts(); }).setTooltip("Atalhos");
    for (auto id : {"menu", "mixer", "railMixer", "railKeyboard", "railSections", "settings",
                    "loop", "pause"})
        controls[id]->getProperties().set("icon", id);
    for (auto id : {"menu", "mixer", "railMixer", "railKeyboard", "railSections", "settings",
                    "railTeleprompt", "railTeleprompt2"})
        controls[id]->getProperties().set("plain", true);
    for (auto id : {"play", "subplay", "record", "video", "tp1", "tp2", "masterMute", "masterSolo",
                    "masterMono", "masterFX"})
        controls[id]->getProperties().set("flat", true);
    for (auto id : {"railTeleprompt", "railTeleprompt2"})
        controls[id]->setColour(TextButton::textColourOffId, Colour(0xffff5555));
    controls["mixer"]->setColour(TextButton::textColourOffId, theme::green);
    controls["setlist"]->setColour(TextButton::buttonColourId, theme::green);
    controls["setlist"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["video"]->setColour(TextButton::buttonColourId, Colour(0xffc44848));
    controls["record"]->setButtonText(String::fromUTF8("◎  REC"));
    addTrack.setButtonText("Add");
    addTrack.getProperties().set("flat", true);
    addTrack.setColour(TextButton::textColourOffId, theme::green);
    addTrack.setColour(TextButton::buttonColourId, theme::green.withAlpha(.1f));
    addAndMakeVisible(addTrack);
    addTrack.setTooltip(String::fromUTF8("Criar pista · Ctrl+T"));
    addTrack.onClick = [this] { createTrack(); };
    projectBrowser = std::make_unique<ProjectBrowser>();
    addChildComponent(*projectBrowser);
    projectBrowser->createEmpty = [this] { createProject(false); };
    projectBrowser->createStems = [this] { createProject(true); };
    projectBrowser->createReaper = [this] { chooseMigration(false); };
    projectBrowser->createLogic = [this] { chooseMigration(true); };
    projectBrowser->addStems = [this] {
        if (!projectReady) {
            showError("Open a project before using Add Project.");
            return;
        }
        chooseImport();
    };
    projectBrowser->addPackage = [this] { choosePackage(); };
    projectBrowser->browse = [this] { chooseOpen(); };
    projectBrowser->open = [this](File file) { openProject(file); };
    projectBrowser->resume = [this] { projectOpened(false); };
    projectReady = session.inspection && !homePreview;
    browserVisible = !projectReady;
    session.changed = [this] {
        rebuild();
        updateState();
    };
    session.tick = [this] { updateState(); };
    auth.changed = [this] {
        updateLogin();
        caption->repaint();
    };
    logger.reset(FileLogger::createDefaultAppLogger("Hook Developer/CatLive", "windows.log",
                                                    String("CatLive Windows ") +
                                                        JUCE_APPLICATION_VERSION_STRING +
                                                        String::fromUTF8(" — native x64"),
                                                    1024 * 1024));
    if (logger)
        logger->logMessage("Workspace created");
    rebuild();
    updateState();
    updateLogin();
    if (!session.inspection && (bool)appearance.value("jaras.remote.hostEnabled", false)) {
        try { remoteHost->start(); } catch (const std::exception &e) { session.message = String::fromUTF8(e.what()); }
    }
    startTimerHz(30);
}
Workspace::~Workspace() {
    stopTimer();
    remoteHost->stop();
    appearance.removeChangeListener(this);
    floatingWindows.clear();
    session.changed = {};
    session.tick = {};
    auth.changed = {};
    tracksViewport.removeMouseListener(this);
    tracksViewport.setViewedComponent(nullptr, false);
    setLookAndFeel(nullptr);
    LookAndFeel::setDefaultLookAndFeel(nullptr);
}
void Workspace::perform(std::function<void()> work) {
    try {
        work();
    } catch (const std::exception &e) {
        showError(String::fromUTF8(e.what()));
    }
}
void Workspace::showError(const String &text) {
    if (logger)
        logger->logMessage(text);
    AlertWindow::showMessageBoxAsync(MessageBoxIconType::WarningIcon, "CatLive", text, "OK", this);
}
void Workspace::showPanel(const String &name, std::unique_ptr<Component> panel, int width,
                          int height) {
    const bool floating =
        name.startsWithIgnoreCase("Teleprompter") || name == "Video" || name.startsWith("FX");
    {
        auto &desktop = Desktop::getInstance();
        for (int i = desktop.getNumComponents(); --i >= 0;) {
            auto *window = dynamic_cast<DocumentWindow *>(desktop.getComponent(i));
            if (auto *workspace =
                    window ? dynamic_cast<Workspace *>(window->getContentComponent()) : nullptr) {
                if (floating)
                    workspace->openFloating(name, std::move(panel), width, height);
                else
                    ModalSheet::open(*workspace, name, std::move(panel), width, height);
                return;
            }
        }
    }
    panel->setSize(width, height);
    DialogWindow::LaunchOptions options;
    options.content.setOwned(panel.release());
    options.dialogTitle = name;
    options.dialogBackgroundColour = theme::background;
    options.useNativeTitleBar = false;
    options.resizable = true;
    options.useBottomRightCornerResizer = false;
    auto *window = options.launchAsync();
    window->setResizeLimits(width, height, 2560, 1440);
    window->setAlwaysOnTop(false);
}
void Workspace::openFloating(const String &name, std::unique_ptr<Component> panel, int width,
                             int height) {
    if (auto it = floatingWindows.find(name);
        it != floatingWindows.end() && it->second->isVisible()) {
        it->second->toFront(true);
        return;
    }
    class PanelWindow final : public DocumentWindow {
      public:
        PanelWindow(const String &title)
            : DocumentWindow(title, theme::background, DocumentWindow::allButtons, true) {
            setUsingNativeTitleBar(false);
            setTitleBarButtonsRequired(DocumentWindow::allButtons, false);
            setTitleBarHeight(32);
            setResizable(true, false);
        }
        std::function<void()> onClose;
        bool keyPressed(const KeyPress &key) override {
            if (key.getKeyCode() == KeyPress::F4Key && key.getModifiers().isAltDown()) {
                closeButtonPressed();
                return true;
            }
            if (retryEditorShortcut(key))
                return true;
            return DocumentWindow::keyPressed(key);
        }
        void closeButtonPressed() override {
            if (onClose)
                onClose();
            setVisible(false);
        }
    };
    auto window = std::make_unique<PanelWindow>(name);
    if (name == "Recados")
        window->onClose = [this] { stage.clearNotice(); };
    panel->setSize(width, height);
    window->setContentOwned(panel.release(), true);
    window->setResizeLimits(name.startsWith("Piano Roll") ? 760 : 360,
                            name.startsWith("Piano Roll") ? 440 : 240, 3840, 2160);
    window->centreAroundComponent(this, width, height + 32);
    window->setVisible(true);
    window->toFront(true);
    floatingWindows[name] = std::move(window);
}
void Workspace::paint(Graphics &g) {
    g.fillAll(theme::background);
    if (browserVisible || loginPanel)
        return;
    g.setColour(theme::panel);
    g.fillRect(transportBounds);
    g.fillRect(0, 32, 32, getHeight() - 32);
    g.fillRect(footerBounds);
    {
        auto area = footerBounds;
        const auto &state = session.transport();
        auto cpu = area.removeFromLeft(155),
             device = area.removeFromRight(getWidth() < 1400 ? 230 : 300);
        auto total = area.removeFromRight(120), queued = area.removeFromRight(area.getWidth() / 2);
        auto next = area;
        g.setColour(theme::line);
        for (auto r : {next, queued, total, device})
            g.drawVerticalLine(r.getX(), (float)r.getY(), (float)r.getBottom());
        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        GlobalMemoryStatusEx(&memory);
        g.setColour(theme::secondary);
        g.setFont(theme::font(9));
        g.drawText("CPU " + String(session.audio.cpu() * 100, 1) + "%     RAM " +
                       String((int)memory.dwMemoryLoad) + "%",
                   cpu.reduced(8, 0), Justification::centredLeft);
        auto label = [&](juce::Rectangle<int> r, String heading, String value) {
            g.setColour(theme::secondary);
            g.setFont(theme::semiboldFont(9));
            g.drawText(heading, r.getX() + 8, r.getY() + 1, r.getWidth() - 16, 11,
                       Justification::centredLeft);
            g.setColour(theme::yellow);
            g.setFont(theme::semiboldFont(10));
            g.drawText(value.isEmpty() ? String::fromUTF8("—") : value, r.getX() + 8, r.getY() + 12,
                       r.getWidth() - 16, 13, Justification::centredLeft);
        };
        String nextName, queueName;
        if (const auto *song = session.song()) {
            const auto order = setlist->orderedRoots();
            auto selected = state.regionId ? std::find(order.begin(), order.end(), *state.regionId)
                                           : order.end();
            std::optional<ID> nextID;
            if (selected != order.end() && ++selected != order.end())
                nextID = *selected;
            else if (!state.regionId && !order.empty())
                nextID = order.front();
            for (const auto &part : song->parts) {
                if (nextID == part.id)
                    nextName = text(part.name);
                if (state.queuedRegionId == part.id)
                    queueName = text(part.name);
            }
        }
        label(next, String::fromUTF8("Próxima  ›"), nextName);
        label(queued, String::fromUTF8("Fila de espera  ›"), queueName);
        g.setColour(theme::yellow);
        g.setFont(theme::semiboldFont(12));
        g.drawText(clockText(setlist->duration(), true), total, Justification::centred);
        g.setColour(theme::secondary);
        g.setFont(theme::font(9));
        String details = String::fromUTF8("Áudio não iniciado");
        if (auto *d = session.audio.devices.getCurrentAudioDevice())
            details = d->getName() + String::fromUTF8(" · ") +
                      String(d->getCurrentBufferSizeSamples()) + String::fromUTF8(" · ") +
                      String((int)d->getCurrentSampleRate()) + " Hz";
        g.drawFittedText(details, device.reduced(8, 0), Justification::centredRight, 1);
    }
    g.setColour(theme::line);
    g.drawVerticalLine(31, 32, (float)getHeight());
    g.drawHorizontalLine(transportBounds.getBottom(), 32, (float)getWidth());
    const auto masterColour = Colour(0xff000000 | session.project().masterColor.value_or(0x555555));
    g.setColour(masterColour.withAlpha(.55f));
    g.fillRoundedRectangle(40, 40, 230, 70, 5);
    g.setColour(Colours::black.withAlpha(.5f));
    g.fillRect(45, 44, 4, 62);
    g.fillRect(51, 44, 4, 62);
    g.setColour(Colours::white);
    g.setFont(theme::semiboldFont(11));
    g.drawText("Master", 67, 69, 190, 18, Justification::centred);
    if (mixerVisible) {
        g.setColour(theme::panel);
        g.fillRect(32, workspaceBounds.getY(), mixerWidth, 64);
        g.setColour(theme::secondary);
        g.setFont(theme::semiboldFont(10));
        g.drawText("Track-Mixer", 32, workspaceBounds.getY() + 15, mixerWidth - 60, 24,
                   Justification::centredLeft);
    }
}
void Workspace::resized() {
    const int mixerHeight = footerMixerVisible ? jlimit(240, 410, (int)(getHeight() * .4)) : 0;
    const int rail = 32, title = 32, transport = 86,
              bottom = 27 + (keyboardVisible ? 100 : 0) + mixerHeight + (partsVisible ? 180 : 0);
    caption->setBounds(0, 0, getWidth(), title);
    const bool editorVisible = !browserVisible && !loginPanel;
    for (auto *child : getChildren()) {
        if (dynamic_cast<ModalSheet *>(child))
            child->setBounds(getLocalBounds());
        else if (child != caption.get() && child != projectBrowser.get() &&
                 child != loginPanel.get())
            child->setVisible(editorVisible);
    }
    if (projectBrowser) {
        projectBrowser->setVisible(browserVisible && !loginPanel);
        projectBrowser->setBounds(0, title, getWidth(), getHeight() - title);
        projectBrowser->setProjectOpen(projectReady);
    }
    if (loginPanel) {
        loginPanel->setBounds(0, title, getWidth(), getHeight() - title);
        loginPanel->toFront(false);
    }
    caption->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child))
            child->toFront(false);
    if (!editorVisible)
        return;
    transportBounds = {rail, title, getWidth() - rail, transport};
    footerBounds = {rail, getHeight() - 27, getWidth() - rail, 27};
    workspaceBounds = {rail, title + transport, getWidth() - rail,
                       std::max(1, getHeight() - title - transport - bottom)};
    const int right = setlistVisible ? setlistWidth : 0, left = mixerVisible ? mixerWidth : 0;
    const int sectionsWidth =
        partsListVisible ? jlimit(200, 360, (int)(workspaceBounds.getWidth() * .22)) : 0;
    // The master is independent of track mixer visibility, as in the Mac transport.
    masterVolume.setBounds(64, 86, 196, 20);
    masterPan.setBounds(136, 45, 42, 25);
    controls["masterMono"]->setBounds(62, 46, 60, 20);
    controls["masterFX"]->setBounds(178, 46, 26, 20);
    controls["masterMute"]->setBounds(210, 46, 22, 20);
    controls["masterSolo"]->setBounds(240, 46, 22, 20);
    const int edge = getWidth() - 8, start = 276;
    int topRight = edge;
    for (auto spec : std::initializer_list<std::pair<const char *, int>>{{"settings", 30},
                                                                         {"export", 82},
                                                                         {"resolume", 64},
                                                                         {"grandma2", 72},
                                                                         {"advanced", 68}}) {
        topRight -= spec.second;
        controls[spec.first]->setBounds(topRight, 39, spec.second, 26);
        topRight -= 5;
    }
    topRight -= 124;
    tuner->setBounds(topRight, 39, 120, 26);
    topRight -= 5;
    const int displayWidth = std::max(80, topRight - start - 4);
    songDisplay.setBounds(start, 39, std::max(1, displayWidth - 100), 26);
    transportTime.setBounds(start + displayWidth - 100, 39, 100, 26);
    // Match the Mac's growing control widths. Fill the entire row so extra room
    // cannot accumulate between Remote and Save on wider windows.
    const float buttonWidth = std::max(52.f, std::floor(52.f + (getWidth() - rail - 1296) / 13.f));
    const float playbackWidth = std::max(46.f, buttonWidth - 8.f);
    const float iconWidth = std::max(30.f, std::round(playbackWidth * .5f));
    struct TransportItem { const char *id; float width, stretch; };
    const TransportItem items[]{
        {"play", playbackWidth, 1}, {"pause", playbackWidth, 1},
        {"subplay", playbackWidth, 1}, {"loop", iconWidth, .5f},
        {"record", playbackWidth, 1}, {"metronome", iconWidth, .5f},
        {"tempo", 171, 0}, {"timer", 157, 0},
        {"tp1", buttonWidth, 1}, {"tp2", buttonWidth, 1},
        {"notices", buttonWidth, 1}, {"preview", buttonWidth, 1},
        {"video", buttonWidth, 1}, {"remote", buttonWidth, 1},
        {"save", buttonWidth, 1}, {"setlist", buttonWidth, 1}};
    float naturalWidth = 0;
    for (const auto &item : items) naturalWidth += item.width;
    const float available = (float)(edge - start - 15 * 5);
    const float fit = std::min(1.f, available / naturalWidth);
    const float extra = std::max(0.f, available - naturalWidth) / 13.f;
    float x = (float)start;
    for (const auto &item : items) {
        const int leftEdge = roundToInt(x);
        x += item.width * fit + item.stretch * extra;
        const int width = roundToInt(x) - leftEdge;
        if (String(item.id) == "tempo")
            tempoControl->setBounds(leftEdge, 71, width, 43);
        else if (String(item.id) == "timer")
            stageTimer->setBounds(leftEdge, 71, width, 43);
        else
            controls[item.id]->setBounds(leftEdge, String(item.id) == "metronome" ? 75 : 80,
                                          width, String(item.id) == "metronome" ? 35 : 26);
        x += 5;
    }
    tempo.setVisible(false);
    // Commands not present in the Mac transport remain available through menus/shortcuts.
    for (auto id : {"stopall", "previous", "next", "audio", "soundfont", "railProjects",
                    "railImport", "railUndo", "railRedo", "railSettings", "railHelp"})
        controls[id]->setVisible(false);
    controls["menu"]->setBounds(2, 40, 28, 28);
    controls["mixer"]->setBounds(2, 80, 28, 28);
    controls["railTeleprompt"]->setBounds(2, 118, 28, 28);
    controls["railTeleprompt2"]->setBounds(2, 156, 28, 28);
    controls["railNotice"]->setBounds(2, 194, 28, 28);
    controls["railClock"]->setBounds(2, 232, 28, 28);
    controls["railMixer"]->setBounds(2, getHeight() - 120, 28, 28);
    controls["railKeyboard"]->setBounds(2, getHeight() - 80, 28, 28);
    controls["railSections"]->setBounds(2, getHeight() - 40, 28, 28);
    zoom.setVisible(false);
    tracksViewport.setVisible(mixerVisible);
    tracksViewport.setBounds(rail, workspaceBounds.getY() + 64, left,
                             std::max(1, workspaceBounds.getHeight() - 64));
    tracksContent.setSize(left, std::max(tracksViewport.getHeight(), rowTop(rows.size()) + 16));
    for (int i = 0; i < rows.size(); ++i) {
        rows[i]->setVisible(!rowHidden(i));
        rows[i]->setBounds(0, rowTop(i), left, rowHeight(i));
    }
    addTrack.setBounds(rail + left - 48, workspaceBounds.getY() + 20, 32, 24);
    addTrack.setVisible(mixerVisible);
    timeline->setBounds(rail + left, workspaceBounds.getY(),
                        std::max(1, workspaceBounds.getWidth() - left - right - sectionsWidth),
                        workspaceBounds.getHeight());
    setlist->setVisible(setlistVisible);
    setlist->setBounds(getWidth() - right - sectionsWidth, workspaceBounds.getY(), right,
                       workspaceBounds.getHeight());
    setlist->setPartsVisible(partsListVisible);
    partsSidebar->setVisible(partsListVisible);
    partsSidebar->setBounds(getWidth() - sectionsWidth, workspaceBounds.getY(), sectionsWidth,
                            workspaceBounds.getHeight());
    footer.setBounds(rail + 10, footerBounds.getY(), getWidth() - rail - 20, 27);
    footer.setVisible(false);
    keyboard->setVisible(keyboardVisible);
    footerMixer->setVisible(footerMixerVisible);
    footerMixer->setBounds(rail, getHeight() - bottom, getWidth() - rail, mixerHeight);
    if (footerMixerVisible)
        footerMixer->refresh();
    controls["railMixer"]->setColour(TextButton::textColourOffId,
                                     footerMixerVisible ? theme::green : Colours::white);
    partsPanel->setVisible(partsVisible);
    partsPanel->setBounds(rail,
                          getHeight() - 27 - (keyboardVisible ? 100 : 0) - (partsVisible ? 180 : 0),
                          getWidth() - rail, 180);
    controls["railSections"]->setColour(TextButton::textColourOffId,
                                        partsVisible ? theme::green : Colours::white);
    if (keyboardVisible)
        keyboard->setBounds(rail, getHeight() - 127, getWidth() - rail, 100);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child))
            child->toFront(false);
}
int Workspace::rowBodyHeight(int index) const {
    if (auto *s = session.song(); s && index >= 0 && index < (int)s->tracks.size())
        return jlimit(
            64, 640,
            (int)std::lround(trackHeight * s->tracks[(size_t)index].heightScale.value_or(1.0)));
    return trackHeight;
}
bool Workspace::rowHidden(int index) const {
    if (const auto *song = session.song())
        for (const auto &group : collapsedGroups)
            if (trackTree::descendant(*song, (size_t)index, group))
                return true;
    return false;
}
void Workspace::toggleGroup(const ID &id) {
    if (!collapsedGroups.erase(id))
        collapsedGroups.insert(id);
    resized();
    timeline->updateRanges();
    for (auto *row : rows)
        row->refresh();
    repaint();
}
int Workspace::rowHeight(int index) const {
    if (rowHidden(index))
        return 0;
    int height = rowBodyHeight(index);
    if (auto *song = session.song(); song && index >= 0 && index < (int)song->tracks.size())
        height += 32 * automation::visible(song->tracks[(size_t)index]).size();
    return height;
}
int Workspace::rowTop(int index) const {
    int top = 0;
    for (int i = 0; i < index; ++i)
        top += rowHeight(i);
    return top;
}
int Workspace::rowAt(int y) const {
    if (y < 0)
        return -1;
    if (auto *s = session.song())
        for (int i = 0; i < (int)s->tracks.size(); ++i) {
            y -= rowHeight(i);
            if (y < 0)
                return i;
        }
    return -1;
}
void Workspace::rebuild() {
    std::vector<ID> current;
    if (auto *s = session.song())
        for (auto &t : s->tracks)
            current.push_back(t.id);
    auto songID = session.song() ? session.song()->id : ID{};
    if (current != builtTracks || songID != builtSong) {
        rows.clear();
        for (auto &id : current) {
            auto *row = rows.add(new TrackRow(*this, id));
            tracksContent.addAndMakeVisible(row);
        }
        builtTracks = current;
        builtSong = songID;
        verticalOffset = 0;
        tracksViewport.setViewPosition(0, 0);
    }
    for (auto *row : rows)
        row->refresh();
    setlist->refresh();
    timeline->updateRanges();
    resized();
    caption->repaint();
    repaint();
}
void Workspace::updateState() {
    session.audio.setKeyboardTarget(selectedTrack);
    session.setRecordingSelection(selectedTrack);
    if (recordVisualSelection != selectedTrack) {
        recordVisualSelection = selectedTrack;
        for (auto *row : rows)
            row->refresh();
    }
    const auto &t = session.transport();
    stage.observe(t);
    controls["preview"]->setToggleState(stage.preview, dontSendNotification);
    controls["notices"]->setToggleState(stage.noticeActive(), dontSendNotification);
    for (int i = 1; i <= 2; ++i) {
        const auto found = floatingWindows.find("Teleprompter " + String(i));
        const bool visible = found != floatingWindows.end() && found->second->isVisible();
        controls[i == 1 ? "tp1" : "tp2"]->setToggleState(visible, dontSendNotification);
        controls[i == 1 ? "railTeleprompt" : "railTeleprompt2"]->setColour(
            TextButton::textColourOffId, visible ? theme::green : Colour(0xffff5555));
    }
    controls["play"]->setButtonText(t.playing ? String::fromUTF8("■  Stop")
                                              : String::fromUTF8("▶  Play"));
    controls["play"]->setToggleState(t.playing, dontSendNotification);
    controls["subplay"]->setToggleState(t.subPlay.playing, dontSendNotification);
    controls["subplay"]->setEnabled(t.playing);
    controls["pause"]->setEnabled(t.playing);
    controls["loop"]->setToggleState(t.loop.enabled, dontSendNotification);
    controls["record"]->setToggleState(session.audio.isRecording(), dontSendNotification);
    controls["metronome"]->setToggleState(session.audio.metronomeEnabled.load(),
                                          dontSendNotification);
    controls["record"]->setColour(TextButton::buttonOnColourId, Colour(0xffd95b5b));
    controls["save"]->setButtonText(session.dirty ? "Salvar *" : String::fromUTF8("✓  Salvo"));
    controls["railUndo"]->setEnabled(session.canUndo());
    controls["railRedo"]->setEnabled(session.canRedo());
    masterVolume.setValue(session.project().masterVolume, dontSendNotification);
    masterPan.setValue(session.project().masterPan, dontSendNotification);
    controls["masterMute"]->setToggleState(session.project().masterMute, dontSendNotification);
    controls["masterSolo"]->setToggleState(session.project().masterSolo, dontSendNotification);
    controls["masterMono"]->setToggleState(session.project().masterMono, dontSendNotification);
    controls["masterMono"]->setButtonText(
        session.project().masterMono ? "Mono" : String::fromUTF8("Estéreo"));
    if (auto *s = session.song()) {
        String selectedName = text(s->name);
        if (t.regionId)
            for (const auto &part : s->parts)
                if (part.id == *t.regionId)
                    selectedName = text(part.name);
        songDisplay.setText((t.playing ? String::fromUTF8("Reproduzindo  ›  ")
                                       : String::fromUTF8("Selecionada  ›  ")) +
                                selectedName,
                            dontSendNotification);
        tempo.setText(String(s->bpm, 1) + " BPM   " + String(s->beatsPerBar) + "/" +
                          String(s->beatUnit),
                      dontSendNotification);
        tempoControl->refresh();
    }
    transportTime.setText(clockText(t.position, true), dontSendNotification);
    auto *device = session.audio.devices.getCurrentAudioDevice();
    String audioInfo = device ? device->getName() + String::fromUTF8(" · ") +
                                    String(device->getCurrentSampleRate() / 1000, 1) +
                                    String::fromUTF8(" kHz · ") +
                                    String(device->getCurrentBufferSizeSamples()) + " samples"
                              : String::fromUTF8("Áudio não iniciado");
    String status = t.playing  ? String::fromUTF8("● PLAYING")
                    : t.paused ? String::fromUTF8("Ⅱ PAUSED")
                               : String::fromUTF8("■ STOPPED");
    if (t.subPlay.playing)
        status += String::fromUTF8("  ·  SUB PLAY ") + clockText(t.subPlay.position);
    if (session.busy)
        status +=
            String::fromUTF8("  ·  Importando ") + String(session.importProgress * 100, 0) + "%";
    footer.setText(status + "     " + audioInfo + "     CPU " +
                       String(session.audio.cpu() * 100, 1) + "%     " + session.message,
                   dontSendNotification);
    footer.setTooltip(session.message);
    repaint(footerBounds);
    timeline->animate();
    for (auto *row : rows)
        if (row->isShowing())
            row->repaint(0, 0, 22, row->getHeight());
    setlist->repaint();
}
void Workspace::showLoginPreview() {
    if (!session.inspection) return;
    loginPanel = std::make_unique<LoginBackdrop>(auth);
    addAndMakeVisible(*loginPanel);
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        const auto *display = Desktop::getInstance().getDisplays().getDisplayForRect(window->getBounds());
        window->centreWithSize(600, std::min(760, display ? display->userArea.getHeight() : 760));
    }
    resized();
}
void Workspace::showImportNoticePreview() {
    if (!session.inspection) return;
    StringArray warnings;
    for (int i = 0; i < 20; ++i)
        warnings.add(String::fromUTF8("#GUITARRAS: VST: ReaPitch (Cockos) não foi importado; confira os efeitos desta pista antes de reproduzir."));
    showPanel(String::fromUTF8("Migração de projeto"), std::make_unique<ImportNoticePanel>(warnings), 520, 316);
}
void Workspace::updateLogin() {
    session.audio.instrumentAllowed = auth.allowed();
    bool show = !auth.allowed() && !session.inspection;
    if (show && !loginPanel) {
        loginPanel = std::make_unique<LoginBackdrop>(auth);
        addAndMakeVisible(*loginPanel);
        if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
            const auto *display = Desktop::getInstance().getDisplays().getDisplayForRect(window->getBounds());
            if (display && window->getHeight() < 760)
                window->centreWithSize(std::max(600, window->getWidth()), std::min(760, display->userArea.getHeight()));
        }
    }
    if (!show && loginPanel) {
        loginPanel.reset();
        if (browserVisible)
            showProjectBrowser();
        grabKeyboardFocus();
    }
    if (auto *backdrop = dynamic_cast<LoginBackdrop *>(loginPanel.get()))
        backdrop->panel.update();
    resized();
}
void Workspace::timerCallback() {
    controls["remote"]->setColour(TextButton::buttonColourId, remoteHost->enabled() ? theme::green : Colour(0xffc44848));
    int y = tracksViewport.getViewPositionY();
    if (y != verticalOffset) {
        verticalOffset = y;
        timeline->updateRanges();
        resized();
    }
    if (session.transport().playing || session.transport().subPlay.playing)
        timeline->animate();
}
void Workspace::changeListenerCallback(ChangeBroadcaster *) {
    localization::english = appearance.value("jaras.language", "pt-BR").toString() == "en";
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child)) {
            localization::panel(*sheet);
            sheet->repaint();
        }
    timeline->invalidate();
    setlist->repaint();
    repaint();
}
bool Workspace::keyPressed(const KeyPress &key) {
    if (session.inspection && logger)
        logger->logMessage("QA key=" + String(key.getKeyCode()) +
                           " mods=" + String(key.getModifiers().getRawFlags()));
    if (key.getKeyCode() == KeyPress::F12Key) {
        capture(File::getSpecialLocation(File::userApplicationDataDirectory)
                    .getChildFile("Hook Developer/CatLive/qa/current.png"));
        return true;
    }
    auto *focused = Component::getCurrentlyFocusedComponent();
    if (dynamic_cast<TextEditor *>(focused))
        return retryEditorShortcut(key);
    const auto mods = key.getModifiers();
    int code = key.getKeyCode();
    // Windows may deliver Ctrl+A..Z through WM_CHAR as C0 characters (1..26).
    if (mods.isCtrlDown() && code >= 1 && code <= 26 &&
        !(code == KeyPress::tabKey && (GetKeyState(VK_TAB) & 0x8000)))
        code = 'A' + code - 1;
    if (code >= 'a' && code <= 'z')
        code -= ('a' - 'A');
    const bool ctrl = mods.isCtrlDown(), shift = mods.isShiftDown(), alt = mods.isAltDown();
    if (ctrl && code == 'Q') {
        JUCEApplication::getInstance()->systemRequestedQuit();
        return true;
    }
    if (ctrl && code == 'N') {
        ++shortcutCount;
        newProject();
        return true;
    }
    if (ctrl && code == 'O') {
        ++shortcutCount;
        chooseOpen();
        return true;
    }
    if (ctrl && code == 'S') {
        if (!projectReady || loginPanel)
            return false;
        ++shortcutCount;
        chooseSave(shift);
        return true;
    }
    if (ctrl && code == 'I') {
        if (!projectReady || loginPanel || browserVisible)
            return false;
        ++shortcutCount;
        chooseImport();
        return true;
    }
    if (ctrl && code == ',') {
        ++shortcutCount;
        openSettings();
        return true;
    }
    if (loginPanel || browserVisible)
        return false;
    const KeyPress normalised(code, mods, key.getTextCharacter());
    if (actions.key(normalised)) {
        ++shortcutCount;
        return true;
    }
    if (code == KeyPress::spaceKey) {
        ++shortcutCount;
        perform([&] {
            session.command(shift ? jaras::CommandKind::stopAll
                            : alt ? (session.transport().subPlay.playing
                                         ? jaras::CommandKind::subStop
                                         : jaras::CommandKind::subPlay)
                                  : (session.transport().playing ? jaras::CommandKind::stop
                                                                 : jaras::CommandKind::play));
        });
        return true;
    }
    if (code == KeyPress::escapeKey) {
        ++shortcutCount;
        perform([&] { session.command(jaras::CommandKind::escape); });
        return true;
    }
    if (ctrl && code == 'T') {
        ++shortcutCount;
        createTrack();
        return true;
    }
    if (ctrl && code == 'Z') {
        ++shortcutCount;
        perform([&] {
            if (shift)
                session.redo();
            else
                session.undo();
        });
        return true;
    }
    if (ctrl && code == 'Y') {
        ++shortcutCount;
        perform([&] { session.redo(); });
        return true;
    }
    if (ctrl && (code == KeyPress::leftKey || code == KeyPress::rightKey)) {
        ++shortcutCount;
        perform([&] {
            session.command(code == KeyPress::leftKey ? jaras::CommandKind::previous
                                                      : jaras::CommandKind::next);
        });
        return true;
    }
    if (code == KeyPress::homeKey || code == KeyPress::endKey) {
        ++shortcutCount;
        perform([&] {
            session.command(jaras::CommandKind::editSeek, {},
                            code == KeyPress::homeKey ? 0
                            : session.song()          ? session.song()->duration
                                                      : 0);
        });
        return true;
    }
    if (code == 'L' && !ctrl) {
        ++shortcutCount;
        perform([&] { session.command(jaras::CommandKind::toggleLoop); });
        return true;
    }
    if (code == 'P' && !ctrl) {
        ++shortcutCount;
        perform([&] { session.command(jaras::CommandKind::pause); });
        return true;
    }
    if (code == 'M' && !ctrl && !selectedTrack.empty()) {
        ++shortcutCount;
        perform([&] { session.command(jaras::CommandKind::mute, selectedTrack); });
        return true;
    }
    if (code == 'S' && !ctrl && !selectedTrack.empty()) {
        ++shortcutCount;
        perform([&] { session.command(jaras::CommandKind::solo, selectedTrack); });
        return true;
    }
    if (code == KeyPress::deleteKey || code == KeyPress::backspaceKey) {
        ++shortcutCount;
        if (!selectedClip.empty())
            perform([&] {
                session.removeClip(selectedClip);
                selectedClip.clear();
            });
        else if (!selectedTrack.empty())
            confirm("Excluir pista?", String::fromUTF8("Esta ação pode ser desfeita."),
                    [safe = Component::SafePointer<Workspace>(this), id = selectedTrack] {
                        if (safe)
                            safe->perform([&] {
                                safe->session.removeTrack(id);
                                safe->selectedTrack.clear();
                            });
                    });
        return true;
    }
    if (code == '+' || code == '=') {
        ++shortcutCount;
        timeline->zoomAt(pixelsPerSecond * 1.2, 0);
        return true;
    }
    if (code == '-') {
        ++shortcutCount;
        timeline->zoomAt(pixelsPerSecond / 1.2, 0);
        return true;
    }
    if (code == 'F' && !ctrl) {
        ++shortcutCount;
        timeline->fit();
        return true;
    }
    if (code == KeyPress::F1Key) {
        showShortcuts();
        return true;
    }
    return false;
}
bool Workspace::isInterestedInFileDrag(const StringArray &files) {
    for (auto &path : files)
        if (File(path).hasFileExtension("jl;wav;aif;aiff;flac;mp3;ogg"))
            return true;
    return false;
}
void Workspace::filesDropped(const StringArray &files, int, int) {
    if (loginPanel)
        return;
    perform([&] {
        Array<File> audio;
        for (auto &path : files) {
            File f(path);
            if (f.hasFileExtension("jl")) {
                openProject(f);
                return;
            }
            if (f.hasFileExtension("wav;aif;aiff;flac;mp3;ogg"))
                audio.add(f);
        }
        if (!browserVisible && projectReady)
            session.importAudio(audio);
    });
}
void Workspace::mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &details) {
    auto relative = event.getEventRelativeTo(this);
    if (tracksViewport.getBounds().contains(relative.getPosition())) {
        ++wheelCount;
        if (event.mods.isCtrlDown()) {
            trackHeight = jlimit(42, 160, trackHeight + (details.deltaY > 0 ? 4 : -4));
            resized();
            timeline->updateRanges();
        } else {
            verticalOffset =
                jlimit(0, std::max(0, tracksContent.getHeight() - tracksViewport.getHeight()),
                       verticalOffset - (int)(details.deltaY * 300));
            tracksViewport.setViewPosition(0, verticalOffset);
            timeline->updateRanges();
            resized();
        }
    }
}
void Workspace::prompt(const String &title, const String &label, const String &initial,
                       std::function<void(String)> done) {
    auto *dialog = new AlertWindow(title, label, MessageBoxIconType::NoIcon, this);
    dialog->addTextEditor("value", initial);
    dialog->addButton("Salvar", 1, KeyPress(KeyPress::returnKey));
    dialog->addButton("Cancelar", 0, KeyPress(KeyPress::escapeKey));
    dialog->enterModalState(true, ModalCallbackFunction::create([dialog, done](int result) {
                                if (result) {
                                    auto value = dialog->getTextEditorContents("value").trim();
                                    if (value.isNotEmpty())
                                        done(value);
                                }
                            }),
                            true);
}
void Workspace::confirm(const String &title, const String &message, std::function<void()> done) {
    AlertWindow::showOkCancelBox(MessageBoxIconType::QuestionIcon, title, message, "Continuar",
                                 "Cancelar", this,
                                 ModalCallbackFunction::create([done](int result) {
                                     if (result)
                                         done();
                                 }));
}
void Workspace::newProject() { showProjectBrowser(); }
void Workspace::showProjectBrowser() {
    if (session.busy || session.transport().playing || session.audio.isRecording()) {
        showError("Stop playback and wait for imports before opening Projects.");
        return;
    }
    if (projectReady && !browserVisible) {
        auto panel = std::make_unique<ProjectBrowser>();
        panel->setProjectOpen(false);
        panel->createEmpty = projectBrowser->createEmpty;
        panel->createStems = projectBrowser->createStems;
        panel->createReaper = projectBrowser->createReaper;
        panel->createLogic = projectBrowser->createLogic;
        panel->addStems = projectBrowser->addStems;
        panel->addPackage = projectBrowser->addPackage;
        panel->browse = projectBrowser->browse;
        panel->open = projectBrowser->open;
        auto safe = SafePointer<ProjectBrowser>(panel.get());
        panel->resume = [safe] {
            if (safe)
                ModalSheet::dismiss(*safe);
        };
        ModalSheet::open(*this, "Projetos", std::move(panel), 560, 424);
        return;
    }
    if (!browserVisible)
        editorWindowBounds = getTopLevelComponent()->getBounds();
    browserVisible = true;
    projectBrowser->refresh();
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        window->setResizeLimits(600, 492, 7680, 4320);
        window->centreWithSize(600, 492);
    }
    resized();
    repaint();
}
void Workspace::projectOpened(bool fitTimeline) {
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child);
            sheet && sheet->getName() == "Projetos")
            sheet->exitModalState(0);
    projectReady = true;
    browserVisible = false;
    if (session.document.existsAsFile())
        RecentProjects::remember(session.document);
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        window->setResizeLimits(1280, 720, 7680, 4320);
        if (!editorWindowBounds.isEmpty())
            window->setBounds(editorWindowBounds);
        else {
            auto area = Desktop::getInstance().getDisplays().getPrimaryDisplay()->userArea;
            window->centreWithSize(std::max(1280, std::min(1680, area.getWidth() - 16)),
                                   std::max(720, std::min(1020, area.getHeight() - 16)));
        }
    }
    resized();
    if (fitTimeline)
        timeline->fit();
    repaint();
    grabKeyboardFocus();
}
void Workspace::openProject(const File &file) {
    auto action = [safe = Component::SafePointer<Workspace>(this), file] {
        if (safe)
            safe->perform([&] {
                safe->session.load(file);
                safe->lighting.loadSettings();
                safe->projectOpened();
            });
    };
    if (session.dirty && projectReady)
        confirm("Open another project?", "The current project has unsaved changes.", action);
    else
        action();
}
void Workspace::createProject(bool withStems) {
    auto work = [safe = Component::SafePointer<Workspace>(this), withStems] {
        if (safe)
            safe->prompt(
                "Create Project", "Project name", "Untitled", [safe, withStems](String name) {
                    if (!safe || name.trim().isEmpty())
                        return;
                    auto legal = File::createLegalFileName(name.trim());
                    auto folder = File::getSpecialLocation(File::userDocumentsDirectory)
                                      .getChildFile("CatLive");
                    folder.createDirectory();
                    safe->chooser = std::make_unique<FileChooser>(
                        "Create Project", folder.getChildFile(legal + ".jl"), "*.jl", true);
                    safe->chooser->launchAsync(
                        FileBrowserComponent::saveMode | FileBrowserComponent::canSelectFiles |
                            FileBrowserComponent::warnAboutOverwriting,
                        [safe, name, withStems](const FileChooser &fc) {
                            if (!safe || fc.getResult() == File())
                                return;
                            auto chosen = fc.getResult().withFileExtension("jl");
                            // Match Mac's isolated project directory: every project owns its media
                            // folder.
                            auto target =
                                chosen.getParentDirectory().getFileName() ==
                                        chosen.getFileNameWithoutExtension()
                                    ? chosen
                                    : chosen.getParentDirectory()
                                          .getChildFile(chosen.getFileNameWithoutExtension())
                                          .getChildFile(chosen.getFileName());
                            safe->perform([&] {
                                if (target.existsAsFile())
                                    throw std::runtime_error("A project already exists at this "
                                                             "location. Choose another name.");
                                safe->session.newProject(name);
                                safe->session.save(target);
                                safe->lighting.loadSettings();
                                safe->projectOpened();
                                if (withStems)
                                    safe->chooseImport();
                            });
                        });
                });
    };
    if (session.dirty && projectReady)
        confirm(String::fromUTF8("Descartar alterações?"),
                String::fromUTF8("O projeto tem alterações que ainda não foram salvas."), work);
    else
        work();
}
void Workspace::newSong() {
    prompt(String::fromUTF8("Nova música"), "Nome", String::fromUTF8("Nova música"),
           [safe = Component::SafePointer<Workspace>(this)](String name) {
               if (safe)
                   safe->perform([&] {
                       safe->session.addSong(name);
                       safe->lighting.refresh();
                   });
           });
}
void Workspace::chooseOpen() {
    auto launch = [safe = Component::SafePointer<Workspace>(this)] {
        if (!safe)
            return;
        safe->chooser = std::make_unique<FileChooser>("Abrir projeto CatLive",
                                                      safe->session.document, "*.jl", true);
        safe->chooser->launchAsync(FileBrowserComponent::openMode |
                                       FileBrowserComponent::canSelectFiles,
                                   [safe](const FileChooser &fc) {
                                       if (!safe || fc.getResult() == File())
                                           return;
                                       safe->perform([&] {
                                           safe->session.load(fc.getResult());
                                           safe->lighting.loadSettings();
                                           safe->projectOpened();
                                       });
                                   });
    };
    if (session.dirty)
        confirm("Abrir outro projeto?",
                String::fromUTF8("As alterações atuais ainda não foram salvas."), launch);
    else
        launch();
}
void Workspace::chooseSave(bool saveAs, std::function<void()> saved) {
    if (!saveAs && session.document != File()) {
        perform([&] {
            session.save(session.document);
            RecentProjects::remember(session.document);
            if (saved)
                saved();
        });
        return;
    }
    auto suggested =
        File::getSpecialLocation(File::userDocumentsDirectory)
            .getChildFile("CatLive/" + File::createLegalFileName(text(session.project().name)) +
                          "/" + File::createLegalFileName(text(session.project().name)) + ".jl");
    chooser = std::make_unique<FileChooser>("Salvar projeto CatLive em uma pasta exclusiva",
                                            suggested, "*.jl", true);
    chooser->launchAsync(
        FileBrowserComponent::saveMode | FileBrowserComponent::canSelectFiles |
            FileBrowserComponent::warnAboutOverwriting,
        [safe = Component::SafePointer<Workspace>(this), saved](const FileChooser &fc) {
            if (!safe || fc.getResult() == File())
                return;
            safe->perform([&] {
                safe->session.save(fc.getResult());
                RecentProjects::remember(safe->session.document);
                if (saved)
                    saved();
            });
        });
}
void Workspace::chooseImport() {
    chooser = std::make_unique<FileChooser>("Importar multitracks",
                                            File::getSpecialLocation(File::userDocumentsDirectory),
                                            "*.wav;*.aif;*.aiff;*.flac;*.mp3;*.ogg", true);
    chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles |
                             FileBrowserComponent::canSelectMultipleItems,
                         [safe = Component::SafePointer<Workspace>(this)](const FileChooser &fc) {
                             if (safe)
                                 safe->perform([&] { safe->session.importAudio(fc.getResults()); });
                         });
}
void Workspace::choosePackage() {
    if (session.busy)
        return;
    chooser = std::make_unique<FileChooser>("Open CatLive package",
                                            File::getSpecialLocation(File::userDocumentsDirectory),
                                            "*.ziplive;*.zip", true);
    chooser->launchAsync(
        FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
        [safe = Component::SafePointer<Workspace>(this)](const FileChooser &fc) {
            if (!safe || fc.getResult() == File())
                return;
            auto archive = fc.getResult();
            // Replace the chooser only after its completion callback has returned.
            MessageManager::callAsync([safe, archive] {
                if (!safe)
                    return;
                safe->chooser = std::make_unique<FileChooser>(
                    "Choose where to extract the project",
                    File::getSpecialLocation(File::userDocumentsDirectory), "", true);
                safe->chooser->launchAsync(
                    FileBrowserComponent::openMode | FileBrowserComponent::canSelectDirectories,
                    [safe, archive](const FileChooser &destination) {
                        if (!safe || destination.getResult() == File())
                            return;
                        auto parent = destination.getResult();
                        safe->session.busy = true;
                        safe->projectBrowser->setEnabled(false);
                        Thread::launch([safe, archive, parent] {
                            File document;
                            String error;
                            try {
                                document = importPortablePackage(archive, parent);
                            } catch (const std::exception &e) {
                                error = String::fromUTF8(e.what());
                            }
                            MessageManager::callAsync([safe, document, error] {
                                if (!safe)
                                    return;
                                safe->session.busy = false;
                                safe->projectBrowser->setEnabled(true);
                                if (error.isNotEmpty())
                                    safe->showError(error);
                                else
                                    safe->openProject(document);
                            });
                        });
                    });
            });
        });
}
void Workspace::chooseMigration(bool logic) {
    if (session.busy)
        return;
    auto launch = [safe = Component::SafePointer<Workspace>(this), logic] {
        if (!safe)
            return;
        safe->chooser = std::make_unique<FileChooser>(
            logic ? "Select the Logic .logicx project folder" : "Select a REAPER project",
            File::getSpecialLocation(File::userDocumentsDirectory), logic ? "" : "*.rpp", true);
        safe->chooser->launchAsync(
            FileBrowserComponent::openMode | (logic ? FileBrowserComponent::canSelectDirectories
                                                    : FileBrowserComponent::canSelectFiles),
            [safe, logic](const FileChooser &fc) {
                if (!safe || fc.getResult() == File())
                    return;
                auto source = fc.getResult();
                MessageManager::callAsync([safe, logic, source] {
                    if (!safe)
                        return;
                    auto suggested = File::getSpecialLocation(File::userDocumentsDirectory)
                                         .getChildFile("CatLive");
                    suggested.createDirectory();
                    safe->chooser = std::make_unique<FileChooser>(
                        "Save the imported CatLive project",
                        suggested.getChildFile(source.getFileNameWithoutExtension() + ".jl"),
                        "*.jl", true);
                    safe->chooser->launchAsync(
                        FileBrowserComponent::saveMode | FileBrowserComponent::canSelectFiles,
                        [safe, logic, source](const FileChooser &destination) {
                            if (!safe || destination.getResult() == File())
                                return;
                            auto selected = destination.getResult();
                            safe->session.busy = true;
                            safe->projectBrowser->setEnabled(false);
                            safe->session.message = logic ? "Importing Logic project..."
                                                          : "Importing REAPER project...";
                            Thread::launch([safe, logic, source, selected] {
                                File document;
                                String error;
                                StringArray warnings;
                                try {
                                    auto imported = logic ? readLogicProject(source)
                                                          : readReaperProject(source);
                                    warnings = imported.warnings;
                                    document = saveMigratedProject(imported, selected);
                                } catch (const std::exception &e) {
                                    error = String::fromUTF8(e.what());
                                }
                                MessageManager::callAsync([safe, document, error, warnings] {
                                    if (!safe)
                                        return;
                                    safe->session.busy = false;
                                    safe->projectBrowser->setEnabled(true);
                                    if (error.isNotEmpty()) {
                                        safe->showError(error);
                                        return;
                                    }
                                    safe->perform([&] {
                                        safe->session.load(document);
                                        safe->lighting.loadSettings();
                                        safe->projectOpened();
                                        if (!warnings.isEmpty())
                                            safe->showPanel(String::fromUTF8("Migração de projeto"),
                                                std::make_unique<ImportNoticePanel>(warnings), 520, 316);
                                    });
                                });
                            });
                        });
                });
            });
    };
    if (session.dirty && projectReady)
        confirm("Create Project", "The current project has unsaved changes.", launch);
    else
        launch();
}
void Workspace::openGrandMA2() {
    lighting.refresh();
    showPanel(
        "grandMA2",
        std::make_unique<MAPanel>(session, lighting,
                                  [safe = Component::SafePointer<Workspace>(this)](String message) {
                                      if (safe)
                                          safe->showError(message);
                                  }),
        800, 660);
}
void Workspace::openResolume() {
    showPanel("Resolume",
              std::make_unique<ResolumePanel>(
                  session, lighting,
                  [safe = Component::SafePointer<Workspace>(this)](String message) {
                      if (safe)
                          safe->showError(message);
                  }),
              680, 454);
}
void Workspace::openAudioSettings() {
    auto safe = SafePointer<Workspace>(this);
    showPanel(String::fromUTF8("Configurações"),
              std::make_unique<SettingsPanel>(
                  session, auth, lighting, appearance, actions, 1,
                  [safe](String message) {
                      if (safe)
                          safe->showError(message);
                  },
                  [safe] {
                      if (safe)
                          safe->showPanel("Login", std::make_unique<LoginPanel>(safe->auth), 440,
                                          620);
                  }),
              940, 464);
}
void Workspace::openAdvanced() {
    showPanel(
        String::fromUTF8("Avançado"),
        std::make_unique<AdvancedPanel>(appearance, session,
                                        [self = SafePointer<Workspace>(this)](String message) {
                                            if (self)
                                                self->showError(message);
                                        }),
        760, 376);
}
void Workspace::openSettings() {
    auto safe = SafePointer<Workspace>(this);
    showPanel(String::fromUTF8("Configurações"),
              std::make_unique<SettingsPanel>(
                  session, auth, lighting, appearance, actions, 0,
                  [safe](String message) {
                      if (safe)
                          safe->showError(message);
                  },
                  [safe] {
                      if (safe)
                          safe->showPanel("Login", std::make_unique<LoginPanel>(safe->auth), 440,
                                          620);
                  }),
              940, 464);
}
void Workspace::showShortcuts() {
    auto panel = std::make_unique<Panel>(
        "Atalhos de teclado",
        String::fromUTF8("Os campos de texto recebem a digitação sem disparar o transporte."));
    auto &editor = panel->editor(
        String::fromUTF8(
            "Espaço — Play / Stop\nShift+Espaço — Sub Play / Stop\n"
            "Ctrl+Shift+Espaço — Parar tudo\nR — Repetição\n"
            "+ / − — Aumentar / diminuir BPM\nM / Shift+S — Mute / Solo da pista\n"
            "S — Dividir itens no cursor\nN — Normalizar item selecionado\n"
            "Q / [ — Início / fim do projeto\nA / D — Região anterior / próxima\n"
            "E / W — Marcador ou limite anterior / próximo\n"
            "Ctrl+Shift+T — Criar marcador de andamento\n"
            "Ctrl+N / O / S — Projetos / abrir / salvar\nCtrl+Shift+S — Salvar como\n"
            "Ctrl+I / Ctrl+T — Importar áudio / nova pista\n"
            "Ctrl+Z / Ctrl+Shift+Z — Desfazer / refazer\nDelete — Excluir item selecionado\n"
            "F — Ajustar timeline\nCtrl+roda — Zoom horizontal\n"
            "Shift+roda — Rolagem horizontal\nRoda — Rolagem vertical\n"
            "Alt+clique na régua — Posicionar Sub Play\n"
            "Ctrl+Enter — Aplicar texto / enviar recado\n"
            "Duplo clique no fader — Restaurar 0 dB / pan central\nAlt+F4 — Fechar"),
        24, 92, 650, 480);
    editor.setMultiLine(true);
    editor.setReadOnly(true);
    editor.setScrollbarsShown(true);
    editor.setFont(Font(FontOptions("Consolas", 12, Font::plain)));
    showPanel("Atalhos", std::move(panel), 700, 610);
}
void Workspace::createTrack() {
    ModalSheet::open(
        *this, "Criar pista",
        std::make_unique<CreateTrackPanel>(session,
                                           [safe = SafePointer<Workspace>(this)](String error) {
                                               if (safe)
                                                   safe->showError(error);
                                           }),
        370, 246);
}
void Workspace::editTrack(ID id) {
    const auto *song = session.song();
    if (!song)
        return;
    const auto at = trackTree::index(*song, id);
    if (at == song->tracks.size())
        return;
    const auto track = song->tracks[at];
    const auto safe = SafePointer<Workspace>(this);
    auto close = [safe] {
        if (safe)
            for (auto *child : safe->getChildren())
                if (auto *sheet = dynamic_cast<ModalSheet *>(child);
                    sheet && sheet->getName() == "Editar pista") {
                    sheet->exitModalState(0);
                    break;
                }
    };
    auto save = [safe, id, close](String name, unsigned colour, bool) {
        if (!safe)
            return;
        safe->perform([&] {
            safe->session.edit(
                [&](jaras::Project &p) {
                    for (auto &s : p.songs)
                        for (auto &t : s.tracks)
                            if (t.id == id) {
                                if (jaras::fixedTrackName(t.role).empty())
                                    t.name = utf8(name);
                                t.color = colour;
                            }
                },
                false);
            close();
        });
    };
    ModalSheet::open(*this, "Editar pista",
                     std::make_unique<RegionEditor>(text(track.name),
                                                    theme::track(track).getARGB() & 0xffffff, false,
                                                    save, close, false),
                     300, 326);
}
void Workspace::showTrackMenu(ID id, Point<int> point) {
    PopupMenu menu;
    menu.addItem(1, String::fromUTF8("Editar pista…"));
    menu.addItem(2, "Mute");
    menu.addItem(3, "Solo");
    menu.addItem(4, "Inverter polaridade");
    menu.addSeparator();
    menu.addItem(5, "Duplicar pista");
    menu.addItem(6, String::fromUTF8("Cor da pista…"));
    menu.addItem(7, "Excluir pista");
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            if (track.id == id &&
                (jaras::isTeleprompterRole(track.role) || track.role.id == "chords")) {
                menu.addSeparator();
                menu.addItem(11, "Adicionar texto");
            }
    if (const auto *song = session.song()) {
        const auto at = trackTree::index(*song, id);
        if (at < song->tracks.size() && jaras::fixedTrackName(song->tracks[at].role).empty()) {
            menu.addSeparator();
            menu.addItem(8, "Criar grupo com esta pista");
            if (song->tracks[at].parentTrackID)
                menu.addItem(9, "Retirar do grupo");
            if (trackTree::end(*song, at) > at + 1)
                menu.addItem(10, collapsedGroups.count(id) ? "Expandir grupo" : "Recolher grupo");
        }
    }
    menu.showMenuAsync(
        PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
        [safe = Component::SafePointer<Workspace>(this), id](int result) {
            if (!safe)
                return;
            safe->perform([&] {
                auto &w = *safe;
                if (result == 11) {
                    w.addTextItem(id, w.session.transport().editPosition);
                    return;
                }
                if (result == 1 || result == 6)
                    w.editTrack(id);
                if (result >= 2 && result <= 4)
                    w.session.command(result == 2   ? jaras::CommandKind::mute
                                      : result == 3 ? jaras::CommandKind::solo
                                                    : jaras::CommandKind::phase,
                                      id);
                if (result == 5)
                    w.session.edit([&](jaras::Project &p) {
                        for (auto &s : p.songs)
                            trackTree::duplicate(s, id);
                    });
                if (result == 7)
                    w.confirm("Excluir pista?", String::fromUTF8("Esta ação pode ser desfeita."),
                              [safe, id] {
                                  if (safe)
                                      safe->perform([&] { safe->session.removeTrack(id); });
                              });
                if (result == 10)
                    w.toggleGroup(id);
                if (result == 8)
                    w.prompt("Criar grupo", "Nome", "Grupo", [safe, id](String name) {
                        if (safe)
                            safe->perform([&] {
                                safe->session.edit([&](jaras::Project &p) {
                                    for (auto &song : p.songs) {
                                        const auto at = trackTree::index(song, id);
                                        if (at == song.tracks.size())
                                            continue;
                                        if (song.tracks.size() >= 512)
                                            throw std::runtime_error("Track limit reached.");
                                        jaras::Track group;
                                        group.id = uuid();
                                        group.name = utf8(name);
                                        group.color = song.tracks[at].color;
                                        group.parentTrackID = song.tracks[at].parentTrackID;
                                        song.tracks[at].parentTrackID = group.id;
                                        // A newly grouped track sends through its folder by
                                        // default.
                                        song.tracks[at].outputs.reset();
                                        song.tracks[at].secondaryPatch.reset();
                                        song.tracks[at].patch = jaras::OutputPatch{-2, 2};
                                        song.tracks.insert(song.tracks.begin() + at, group);
                                    }
                                });
                            });
                    });
                if (result == 9)
                    w.session.edit([&](jaras::Project &p) {
                        for (auto &song : p.songs) {
                            const auto at = trackTree::index(song, id);
                            if (at == song.tracks.size() || !song.tracks[at].parentTrackID)
                                continue;
                            const auto parent =
                                trackTree::index(song, *song.tracks[at].parentTrackID);
                            const auto last = trackTree::end(song, at),
                                       after = trackTree::end(song, parent);
                            std::vector<jaras::Track> moving(song.tracks.begin() + at,
                                                             song.tracks.begin() + last);
                            moving.front().parentTrackID = song.tracks[parent].parentTrackID;
                            trackTree::resetGroupOutput(moving.front());
                            song.tracks.erase(song.tracks.begin() + at, song.tracks.begin() + last);
                            song.tracks.insert(song.tracks.begin() + after - (last - at),
                                               moving.begin(), moving.end());
                        }
                    });
            });
        });
}
void Workspace::showClipMenu(ID id, Point<int> point) {
    PopupMenu menu;
    bool textItem = false, audioItem = false, midiItem = false, muted = false;
    int channelMode = 0;
    ID ownerID;
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            for (const auto &clip : track.clips)
                if (clip.id == id) {
                    ownerID = track.id;
                    textItem = clip.text && !clip.audioFile;
                    audioItem = jaras::fixedTrackName(track.role).empty();
                    midiItem = clip.midi.has_value();
                    muted = clip.muted;
                    channelMode = clip.channelMode.value_or(0);
                }
    if (textItem)
        menu.addItem(8, "Editar texto");
    else if (audioItem) {
        if (midiItem)
            menu.addItem(13, "Editar MIDI");
        menu.addItem(9, String::fromUTF8("Criar região do item"));
        menu.addItem(10, "Tuner", !midiItem);
        menu.addItem(11, String::fromUTF8("Normalizar…"), !midiItem);
        menu.addSeparator();
        menu.addItem(21, "Converter Mono - L", !midiItem, channelMode == 1);
        menu.addItem(22, "Converter Mono - R", !midiItem, channelMode == 2);
        menu.addItem(23, "Converter Mono L-R", !midiItem, channelMode == 3);
        menu.addItem(20, String::fromUTF8("Converter Estéreo"), !midiItem, channelMode == 0);
        menu.addSeparator();
        menu.addItem(2, muted ? "Desmutar itens" : "Mutar itens");
        menu.addSeparator();
        menu.addItem(12, "Exportar");
    }
    PopupMenu edit;
    edit.addItem(1, String::fromUTF8("Renomear item…"));
    if (audioItem) {
        edit.addItem(3, "Inverter polaridade");
        edit.addItem(4, String::fromUTF8("Ganho do item…"));
        edit.addItem(5, "Fade in / out de 20 ms");
    }
    edit.addItem(6, String::fromUTF8("Duplicar à direita"));
    edit.addItem(7, "Excluir item");
    menu.addSubMenu("Item", edit);
    menu.showMenuAsync(
        PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
        [safe = Component::SafePointer<Workspace>(this), id, ownerID](int action) {
            if (!safe || !action)
                return;
            safe->perform([&] {
                auto &w = *safe;
                if (action == 8) {
                    w.editTextItem(id);
                    return;
                }
                if (action == 13) {
                    w.openMIDIEditor(id);
                    return;
                }
                if (action == 10) {
                    ModalSheet::open(w, "Tuner",
                                     std::make_unique<ItemTunerPanel>(w.session, id,
                                                                      [safe](String message) {
                                                                          if (safe)
                                                                              safe->showError(
                                                                                  message);
                                                                      }),
                                     440, 120);
                    return;
                }
                if (action == 12) {
                    ModalSheet::open(w, "Exportar",
                                     std::make_unique<ExportPanel>(
                                         w.session, ownerID, id,
                                         [safe](String message) {
                                             if (safe)
                                                 safe->showError(message);
                                         },
                                         true),
                                     860, 510);
                    return;
                }
                if (action == 11) {
                    ModalSheet::open(
                        w, "Normalizar",
                        std::make_unique<NormalizationPanel>(w.session, w.appearance, id), 360,
                        230);
                    return;
                }
                if (action == 9) {
                    if (const auto *song = w.session.song())
                        for (const auto &track : song->tracks)
                            for (const auto &clip : track.clips)
                                if (clip.id == id) {
                                    for (const auto &region : song->parts)
                                        if (std::abs(region.startTime - clip.startTime) < .000001)
                                            throw std::runtime_error(
                                                "Já existe uma região começando nesta posição.");
                                    const auto name = text(clip.name);
                                    const auto start = clip.startTime, end = start + clip.duration;
                                    w.session.addRegion(name, start, end);
                                    return;
                                }
                    return;
                }
                if (action == 7) {
                    w.session.removeClip(id);
                    return;
                }
                if (action == 1 || action == 4) {
                    String initial = action == 1 ? "Item" : "0";
                    if (action == 1)
                        if (auto *s = w.session.song())
                            for (auto &t : s->tracks)
                                for (auto &c : t.clips)
                                    if (c.id == id)
                                        initial = text(c.name);
                    w.prompt(
                        action == 1 ? "Renomear item" : "Ganho do item",
                        action == 1 ? "Nome" : "dB (-60 a +12)", initial,
                        [safe, id, action](String value) {
                            if (safe)
                                safe->perform([&] {
                                    safe->session.edit([&](jaras::Project &p) {
                                        for (auto &s : p.songs)
                                            for (auto &t : s.tracks)
                                                for (auto &c : t.clips)
                                                    if (c.id == id) {
                                                        if (action == 1)
                                                            c.name = utf8(value);
                                                        else {
                                                            double db = value.getDoubleValue();
                                                            if (db < -60 || db > 12)
                                                                throw std::runtime_error(
                                                                    "Ganho fora do intervalo.");
                                                            c.gain = Decibels::decibelsToGain(db);
                                                        }
                                                    }
                                    });
                                });
                        });
                    return;
                }
                w.session.edit([&](jaras::Project &p) {
                    for (auto &s : p.songs)
                        for (auto &t : s.tracks)
                            for (size_t i = 0; i < t.clips.size(); ++i)
                                if (t.clips[i].id == id) {
                                    auto &c = t.clips[i];
                                    if (action == 2)
                                        c.muted = !c.muted;
                                    if (action == 3)
                                        c.phaseInverted = !c.phaseInverted.value_or(false);
                                    if (action >= 20 && action <= 23)
                                        c.channelMode = action - 20;
                                    if (action == 5) {
                                        c.fadeIn = .02;
                                        c.fadeOut = .02;
                                    }
                                    if (action == 6) {
                                        auto copy = c;
                                        copy.id = uuid();
                                        copy.startTime += copy.duration;
                                        s.duration =
                                            std::max(s.duration, copy.startTime + copy.duration);
                                        t.clips.push_back(copy);
                                    }
                                    return;
                                }
                });
            });
        });
}
void Workspace::openMIDIEditor(ID id) {
    const auto safe = SafePointer<Workspace>(this);
    const auto windowID = "Piano Roll - " + text(id);
    openFloating(windowID,
                 std::make_unique<MIDIEditorPanel>(
                     session, id,
                     [safe](ID track) {
                         if (safe)
                             safe->openFX(track);
                     },
                     [safe](String error) {
                         if (safe)
                             safe->showError(error);
                     }),
                 980, 610);
    if (auto window = floatingWindows.find(windowID); window != floatingWindows.end())
        window->second->setName(String::fromUTF8("CatLive — Piano Roll"));
}
void Workspace::addMIDIItem(ID trackID, double position) {
    perform([&] {
        const auto id = uuid();
        session.edit([&](jaras::Project &p) {
            if (!std::isfinite(position) || position < 0)
                throw std::runtime_error("Posição MIDI inválida.");
            for (auto &song : p.songs)
                for (auto &track : song.tracks)
                    if (track.id == trackID && jaras::fixedTrackName(track.role).empty() &&
                        track.role.id != "group") {
                        jaras::AudioClip clip;
                        clip.id = id;
                        clip.name = "MIDI";
                        clip.startTime = position;
                        clip.duration = 16 * 60. / song.bpm;
                        clip.regionOwnerID = jaras::regionOwnerAt(song, position);
                        clip.midi.emplace();
                        clip.midi->sourceBPM = song.bpm;
                        track.clips.push_back(clip);
                        song.duration = std::max(song.duration, position + clip.duration);
                        return;
                    }
            throw std::runtime_error("Pista MIDI indisponível.");
        });
        selectedClip = id;
        selectedTrack = trackID;
        openMIDIEditor(id);
    });
}
void Workspace::addTextItem(ID trackID, double position) {
    perform([&] {
        if (session.busy)
            throw std::runtime_error("Aguarde a operação atual terminar.");
        if (!std::isfinite(position) || position < 0)
            throw std::runtime_error("Posição de texto inválida.");
        ID itemID = uuid();
        session.edit(
            [&](jaras::Project &project) {
                for (auto &song : project.songs)
                    for (auto &track : song.tracks)
                        if (track.id == trackID &&
                            (jaras::isTeleprompterRole(track.role) || track.role.id == "chords")) {
                            for (const auto &clip : track.clips)
                                if (position < clip.startTime + clip.duration &&
                                    position + 10 > clip.startTime)
                                    throw std::runtime_error(
                                        "Já existe um item nesta posição da pista.");
                            jaras::AudioClip item;
                            item.id = itemID;
                            item.name = track.name;
                            item.startTime = position;
                            item.duration = 10;
                            item.text = "";
                            track.clips.push_back(item);
                            song.duration = std::max(song.duration, position + 10);
                            return;
                        }
                throw std::runtime_error("A pista de texto não existe mais.");
            },
            false);
        selectedClip = itemID;
        editTextItem(itemID);
    });
}
void Workspace::editTextItem(ID id) {
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            for (const auto &clip : track.clips)
                if (clip.id == id && clip.text && !clip.audioFile) {
                    auto safe = SafePointer<Workspace>(this);
                    ModalSheet::open(*this, "Editor de texto",
                                     std::make_unique<TextItemPanel>(
                                         text(*clip.text),
                                         [safe, id](String draft) {
                                             if (!safe)
                                                 return;
                                             safe->perform([&] {
                                                 if (safe->session.busy)
                                                     throw std::runtime_error(
                                                         "Aguarde a operação atual terminar.");
                                                 const auto value = utf8(draft);
                                                 jaras::validateClipText(value);
                                                 safe->session.edit(
                                                     [&](jaras::Project &project) {
                                                         for (auto &song : project.songs)
                                                             for (auto &track : song.tracks)
                                                                 for (auto &item : track.clips)
                                                                     if (item.id == id) {
                                                                         item.text = value;
                                                                         return;
                                                                     }
                                                         throw std::runtime_error(
                                                             "O item de texto não existe mais.");
                                                     },
                                                     false);
                                                 ModalSheet::dismiss(*safe);
                                             });
                                         }),
                                     430, 308);
                    return;
                }
}
void Workspace::showMixer() {
    mixerVisible = !mixerVisible;
    resized();
    repaint();
}
void Workspace::showTeleprompter(int index) {
    auto panel =
        std::make_unique<Projection>(session, index == 2 ? "teleprompt2" : "teleprompt", &stage);
    panel->configure = [safe = SafePointer<Workspace>(this), index] {
        if (safe)
            safe->openStageConfig(index);
    };
    panel->error = [safe = Component::SafePointer<Workspace>(this)](String message) {
        if (safe)
            safe->showError(message);
    };
    showPanel("Teleprompter " + String(index), std::move(panel), 800, 450);
}
void Workspace::openNotices() {
    openFloating("Recados", std::make_unique<NoticePanel>(stage), 520, 430);
}
void Workspace::toggleRemote() {
    perform([this] {
        if (remoteHost->enabled()) remoteHost->stop(); else remoteHost->start();
        appearance.set("jaras.remote.hostEnabled", remoteHost->enabled());
    });
}
void Workspace::openRemote() {
    ModalSheet::open(*this, "Remote", std::make_unique<RemotePanel>(*remoteHost, [this] { toggleRemote(); }), 440, 548);
}
void Workspace::openAutomation(ID id) {
    String name = "Master";
    if (auto *s = session.song())
        for (const auto &t : s->tracks)
            if (t.id == id)
                name = text(t.name);
    openFloating(
        String::fromUTF8("Envelopes · ") + name,
        std::make_unique<AutomationPanel>(session, id,
                                          [safe = SafePointer<Workspace>(this)](String error) {
                                              if (safe)
                                                  safe->showError(error);
                                          }),
        850, 560);
}
void Workspace::openStageConfig(int index) {
    openFloating(String::fromUTF8("Configurações do teleprompter"),
                 std::make_unique<StageConfigPanel>(stage, index,
                                                    [safe = SafePointer<Workspace>(this)] {
                                                        if (safe)
                                                            safe->openTimer(true);
                                                    }),
                 760, 700);
}
void Workspace::openTimer(bool settings) {
    if (!settings) {
        auto component =
            std::make_unique<StageTimerControl>(stage, [safe = SafePointer<Workspace>(this)] {
                if (safe)
                    safe->openTimer(true);
            });
        component->setSize(164, 30);
        CallOutBox::launchAsynchronously(std::move(component),
                                         controls["railClock"]->getScreenBounds(), this);
        return;
    }
    class TimerSettings final : public Component {
      public:
        TimerSettings(StageState &s) : state(s), control(s) {
            addAndMakeVisible(control);
            addAndMakeVisible(automatic);
            addAndMakeVisible(reset);
            addAndMakeVisible(instruction);
            automatic.setToggleState(state.autoStart, dontSendNotification);
            automatic.onClick = [this] {
                state.autoStart = automatic.getToggleState();
                state.saveTimer();
            };
            reset.onClick = [this] { state.reset(); };
            instruction.setText(String::fromUTF8("Horas : minutos : segundos\nO cronômetro "
                                                 "continua negativo quando o tempo termina."),
                                dontSendNotification);
            instruction.setFont(theme::font(13));
            instruction.setJustificationType(Justification::centred);
        }
        void paint(Graphics &g) override { g.fillAll(theme::panel); }
        void resized() override {
            instruction.setBounds(16, 18, getWidth() - 32, 48);
            control.setBounds(getWidth() / 2 - 96, 86, 192, 32);
            automatic.setBounds(30, 142, getWidth() - 60, 28);
            reset.setBounds(getWidth() / 2 - 60, 194, 120, 28);
        }

      private:
        StageState &state;
        StageTimerControl control;
        ToggleButton automatic{String::fromUTF8("Iniciar automaticamente com a reprodução")};
        TextButton reset{"Reiniciar"};
        Label instruction;
    };
    showPanel(String::fromUTF8("Configurações do cronômetro"),
              std::make_unique<TimerSettings>(stage), 420, 246);
}
void Workspace::requestClose(std::function<void()> done) {
    if (isCurrentlyBlockedByAnotherModalComponent()) {
        ModalComponentManager::getInstance()->bringModalComponentsToFront();
        return;
    }
    if (session.busy) {
        showError(String::fromUTF8("Aguarde a importação terminar antes de fechar."));
        return;
    }
    if (session.transport().playing || session.transport().subPlay.playing) {
        confirm("Encerrar o CatLive?", String::fromUTF8("A reprodução está em andamento."),
                [safe = Component::SafePointer<Workspace>(this), done] {
                    if (safe) {
                        safe->session.command(jaras::CommandKind::stopAll);
                        safe->requestClose(done);
                    }
                });
        return;
    }
    if (session.dirty) {
        auto *alert = new AlertWindow(String::fromUTF8("Salvar alterações?"),
                                      String::fromUTF8("O projeto tem alterações não salvas."),
                                      MessageBoxIconType::QuestionIcon, this);
        alert->addButton("Salvar", 1);
        alert->addButton("Descartar", 2);
        alert->addButton("Cancelar", 0, KeyPress(KeyPress::escapeKey));
        alert->enterModalState(
            true,
            ModalCallbackFunction::create(
                [safe = Component::SafePointer<Workspace>(this), done](int action) {
                    if (!safe)
                        return;
                    if (action == 2)
                        done();
                    if (action == 1) {
                        if (safe->session.document == File()) {
                            safe->chooseSave(false, done);
                            return;
                        }
                        safe->perform([&] {
                            safe->session.save(safe->session.document);
                            done();
                        });
                    }
                }),
            true);
        return;
    }
    done();
}
void Workspace::capture(const File &path) {
    path.getParentDirectory().createDirectory();
    auto image = createComponentSnapshot(getLocalBounds(), true, 1);
    FileOutputStream stream(path);
    if (stream.openedOk()) {
        stream.setPosition(0);
        stream.truncate();
        PNGImageFormat png;
        png.writeImageToStream(image, stream);
    }
    path.withFileExtension("json").replaceWithText(JSON::toString(diagnostics()));
}
var Workspace::diagnostics() const {
    auto value = object();
    put(value, "project", text(session.project().name));
    put(value, "noticeActive", stage.noticeActive());
    put(value, "noticeText",
        stage.noticeText(stage.preferences.value("jaras.notices.appearance", object())));
    Array<var> modalNames;
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child))
            modalNames.add(sheet->getName());
    put(value, "modals", modalNames);
    auto resolumeState = object();
    put(resolumeState, "host", lighting.host);
    put(resolumeState, "oscPort", lighting.port);
    put(resolumeState, "webPort", lighting.webPort);
    put(resolumeState, "regions", (int)lighting.resolumeRegions.size());
    put(value, "resolume", resolumeState);
    auto remoteState = object();
    put(remoteState, "enabled", remoteHost->enabled());
    put(remoteState, "status", remoteHost->status());
    put(remoteState, "port", remoteHost->port);
    put(remoteState, "discoveryStatus", (int64)remoteHost->discoveryStatus());
    put(value, "remote", remoteState);
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child))
            for (auto *content : sheet->getChildren())
                if (auto *panel = dynamic_cast<ExportPanel *>(content))
                    put(value, "export", panel->diagnostics());
                else if (auto *panel = dynamic_cast<ImportNoticePanel *>(content))
                    put(value, "importNotice", panel->diagnostics());
    put(value, "projectBrowser", browserVisible);
    put(value, "document", session.document.getFullPathName());
    put(value, "fontFamily", theme::font(13).getTypefaceName());
    put(value, "fontPointHeight", theme::font(13).getHeightInPoints());
    put(value, "tracks", rows.size());
    Array<var> textItems, trackRoles, trackClipCounts;
    if (const auto *song = session.song())
        for (const auto &track : song->tracks) {
            trackRoles.add(text(track.role.id));
            trackClipCounts.add((int)track.clips.size());
            for (const auto &clip : track.clips)
                if (clip.id == selectedClip) {
                    put(value, "selectedItemPitch", clip.pitchSemitones.value_or(0));
                    put(value, "selectedItemChannelMode", clip.channelMode.value_or(0));
                    put(value, "selectedItemNormalization", clip.normalizationGain.value_or(1));
                    put(value, "selectedItemMuted", clip.muted);
                    if (clip.midi) {
                        put(value, "selectedMIDINotes", (int)clip.midi->notes.size());
                        var notes(Array<var>{});
                        for (const auto &note : clip.midi->notes) {
                            auto data = object();
                            put(data, "start", note.start);
                            put(data, "length", note.length);
                            put(data, "pitch", note.pitch);
                            put(data, "velocity", note.velocity);
                            put(data, "channel", note.channel);
                            notes.append(data);
                        }
                        put(value, "midiNotes", notes);
                        put(value, "midiDivision", clip.midi->division);
                        put(value, "midiMode", text(clip.midi->mode));
                    }
                }
            for (const auto &clip : track.clips)
                if (clip.text) {
                    auto item = object();
                    put(item, "id", text(clip.id));
                    put(item, "text", text(*clip.text));
                    put(item, "role", text(track.role.id));
                    put(item, "start", clip.startTime);
                    put(item, "duration", clip.duration);
                    textItems.add(item);
                }
        }
    put(value, "textItems", textItems);
    put(value, "trackRoles", trackRoles);
    put(value, "trackClipCounts", trackClipCounts);
    int hiddenRows = 0;
    for (int i = 0; i < rows.size(); ++i)
        if (rowHidden(i))
            ++hiddenRows;
    put(value, "hiddenTracks", hiddenRows);
    put(value, "mixerVisible", footerMixerVisible);
    put(value, "mixerScroll", footerMixer->scrollX());
    put(value, "partsVisible", partsVisible);
    put(value, "partsListVisible", partsListVisible);
    put(value, "partsSidebar", partsSidebar->diagnostics());
    auto sectionBounds = object();
    put(sectionBounds, "x", partsSidebar->getX());
    put(sectionBounds, "y", partsSidebar->getY());
    put(sectionBounds, "width", partsSidebar->getWidth());
    put(sectionBounds, "height", partsSidebar->getHeight());
    put(value, "partsSidebarBounds", sectionBounds);
    put(value, "pads", partsPanel->diagnostics());
    Array<var> recordModes;
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            recordModes.add(session.recordArm(track.id));
    put(value, "recordModes", recordModes);
    put(value, "editPosition", session.transport().editPosition);
    put(value, "tunerPitch", tuner->region() ? tuner->region()->pitchSemitones.value_or(0) : 0);
    auto tunerBounds = object();
    put(tunerBounds, "x", tuner->getX());
    put(tunerBounds, "y", tuner->getY());
    put(tunerBounds, "width", tuner->getWidth());
    put(value, "tuner", tunerBounds);
    if (const auto *song = session.song())
        put(value, "bpm", song->bpm);
    put(value, "metronomeEnabled", session.audio.metronomeEnabled.load());
    const auto masterSettings =
        session.project().masterFXJSON ? JSON::parse(text(*session.project().masterFXJSON)) : var();
    put(value, "masterEffects", get(masterSettings, "inserted", Array<var>{}));
    put(value, "masterEQBands", list(get(masterSettings, "bands")).size());
    put(value, "masterPitchEnabled", flag(masterSettings, "pitchEnabled"));
    int envelopeCount = 0, envelopePoints = 0;
    if (auto *song = session.song())
        for (const auto &track : song->tracks)
            for (const auto &curve : automation::visible(track)) {
                ++envelopeCount;
                envelopePoints += list(get(curve, "points")).size();
            }
    put(value, "envelopeLanes", envelopeCount);
    put(value, "envelopePoints", envelopePoints);
    put(value, "shortcuts", shortcutCount);
    put(value, "contexts", contextCount);
    put(value, "wheelEvents", wheelCount);
    put(value, "timeline", timeline->state());
    put(value, "setlistScroll", setlist->scrollY());
    put(value, "setlist", setlist->diagnostics());
    put(value, "dirty", session.dirty);
    put(value, "nativeTitleBar", false);
    put(value, "uiRegressionPassed", uiRegressionPassed);
    auto layout = object();
    for (const auto &entry : controls) {
        auto bounds = object();
        put(bounds, "x", entry.second->getX());
        put(bounds, "y", entry.second->getY());
        put(bounds, "width", entry.second->getWidth());
        put(bounds, "height", entry.second->getHeight());
        put(layout, Identifier(entry.first), bounds);
    }
    put(value, "controls", layout);
    put(value, "grandMA2BeforeResolume",
        controls.at("grandma2")->getX() < controls.at("resolume")->getX());
    bool overlaps = false;
    for (auto a = controls.begin(); a != controls.end(); ++a) {
        if (!a->second->isVisible() || a->second->getY() < 32 || a->second->getBottom() > 118 ||
            a->second->getX() < 276)
            continue;
        for (auto b = std::next(a); b != controls.end(); ++b)
            if (b->second->isVisible() && a->second->getBounds().intersects(b->second->getBounds()))
                overlaps = true;
    }
    put(value, "overlappingTransport", overlaps);
    if (auto *peer = getTopLevelComponent()->getPeer()) {
        auto engines = peer->getAvailableRenderingEngines();
        put(value, "renderer", engines[peer->getCurrentRenderingEngine()]);
    }
    return value;
}
void Workspace::runUIRegression() {
    Timer::callAfterDelay(400, [safe = Component::SafePointer<Workspace>(this)] {
        if (!safe)
            return;
        safe->perform([&] {
            auto &w = *safe;
            w.grabKeyboardFocus();
            auto initial = w.rows.size();
            w.keyPressed(KeyPress('T', ModifierKeys::ctrlModifier, 0));
            bool opened = false;
            for (auto *child : w.getChildren())
                if (auto *sheet = dynamic_cast<ModalSheet *>(child))
                    for (auto *content : sheet->getChildren())
                        if (auto *creator = dynamic_cast<CreateTrackPanel *>(content)) {
                            opened = true;
                            creator->keyPressed(KeyPress(KeyPress::returnKey));
                            break;
                        }
            if (!opened)
                throw std::runtime_error("UI regression: Ctrl+T did not open the track editor");
            if (w.rows.size() != initial + 1)
                throw std::runtime_error("UI regression: Ctrl+T failed");
            w.keyPressed(KeyPress('Z', ModifierKeys::ctrlModifier, 0));
            if (w.rows.size() != initial)
                throw std::runtime_error("UI regression: undo failed");
            w.keyPressed(
                KeyPress('Z', ModifierKeys::ctrlModifier | ModifierKeys::shiftModifier, 0));
            if (w.rows.size() != initial + 1)
                throw std::runtime_error("UI regression: redo failed");
            w.keyPressed(KeyPress('Z', ModifierKeys::ctrlModifier, 0));
            w.timeline->scroll(300, 500);
            w.timeline->zoomAt(35, 300);
            w.setlist->scroll(6);
            w.keyPressed(KeyPress(KeyPress::homeKey));
            w.keyPressed(KeyPress('L'));
            w.keyPressed(KeyPress(KeyPress::escapeKey));
            w.timeline->scroll(-100000, -100000);
            w.setlist->scroll(-10000);
            w.uiRegressionPassed = true;
            w.session.dirty = false;
            w.session.message = String::fromUTF8("VISUAL TEST · NO AUDIO · UI regression passed");
            w.updateState();
        });
    });
}
} // namespace catlive

namespace catlive {
void Workspace::openRegions() {
    partsVisible = !partsVisible;
    if (partsVisible)
        partsListVisible = false;
    resized();
    repaint();
}
void Workspace::openPartsList() {
    partsListVisible = !partsListVisible;
    if (partsListVisible)
        partsVisible = false;
    resized();
    repaint();
}
void Workspace::chooseExport() {
    ModalSheet::open(
        *this, "Exportar",
        std::make_unique<ExportPanel>(session, selectedTrack, selectedClip,
                                      [safe = SafePointer<Workspace>(this)](String error) {
                                          if (safe)
                                              safe->showError(error);
                                      }),
        860, 510);
}
void Workspace::openFX(ID track) {
    String name = "Master";
    for (const auto &song : session.project().songs)
        for (const auto &t : song.tracks)
            if (t.id == track)
                name = text(t.name);
    openFloating("Gerenciador de FX - " + name,
                 std::make_unique<EffectsPanel>(
                     session, std::move(track),
                     [safe = Component::SafePointer<Workspace>(this)](String message) {
                         if (safe)
                             safe->showError(message);
                     }),
                 920, 560);
}
void Workspace::chooseSoundFont() {
    chooser = std::make_unique<FileChooser>(
        "SoundFont", File::getSpecialLocation(File::userDocumentsDirectory), "*.sf2", true);
    chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
                         [safe = Component::SafePointer<Workspace>(this)](const FileChooser &fc) {
                             if (!safe || fc.getResult() == File())
                                 return;
                             auto file = fc.getResult();
                             safe->perform(
                                 [safe, file] { safe->session.audio.loadSoundFont(file); });
                         });
}
void Workspace::openVideo() {
    auto panel = std::make_unique<Projection>(session);
    panel->error = [safe = Component::SafePointer<Workspace>(this)](String message) {
        if (safe)
            safe->showError(message);
    };
    showPanel("Video", std::move(panel), 960, 600);
}
} // namespace catlive

#include "WorkspaceActions.h"
