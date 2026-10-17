#include "MeterDisplay.h"
#include "SpecialTrackControls.h"
#include "MarkerRegionConversion.h"
#include "TempoMarkerPanel.h"
#include "TempoEditing.h"
#include "TeleprompterRemotePanel.h"
#include "StageContent.h"
#include "Workspace.h"
#include "Projection.h"
#include "PortablePackage.h"
#include "PortableExportPanel.h"
#include "TimelinePlaybackFollow.h"
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
#include "FXChain.h"
#include "PlaylistEditor.h"
#include "SetlistShareText.h"
#include "ProjectDeletion.h"
#include "TrackTree.h"
#include "TrackEditing.h"
#include "ClickSoundDesigner.h"
#include "CreateTrackPanel.h"
#include "MediaDropPanel.h"
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
#include "DesktopLayout.h"
#include "TimelineGrid.h"
#include "WindowControlButton.h"
#include "WaveformRenderer.h"
#include "RegionEditing.h"
#include "MultiLoopsPanel.h"
#include "CloseProjectSheet.h"
#include "RecordingProjectStep.h"
#include "TransportFadeoutPanel.h"
#include "TransportFadeoutOverlay.h"
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
    return new WindowControlButton(type);
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
    setColour(PopupMenu::backgroundColourId, MacPopupMenuLook::menuSurface());
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
    if ((bool)b.getProperties()["colourSwatch"]) {
        auto r=b.getLocalBounds().toFloat().reduced(.5f);
        g.setColour(b.findColour(TextButton::buttonColourId)); g.fillRoundedRectangle(r,3);
        g.setColour(Colours::white.withAlpha(.2f)); g.drawRoundedRectangle(r,3,1);
        if ((bool)b.getProperties()["selectedColour"]) { g.setColour(Colours::white); g.drawRoundedRectangle(r.reduced(1),3,2); g.setColour(Colours::black); g.drawRoundedRectangle(r.reduced(3),2,1); }
        return;
    }
    if (b.getProperties().contains("transportColour")) {
        const Colour base((uint32)(int64)b.getProperties()["transportColour"]);
        const bool active = b.getToggleState();
        const auto bounds = b.getLocalBounds().toFloat().reduced(.5f);
        g.setColour(active ? base : base.withAlpha(down ? .7f : .45f));
        g.fillRoundedRectangle(bounds, 6);
        g.setColour(active ? base : Colours::white.withAlpha(.45f));
        g.drawRoundedRectangle(bounds, 6, 1);
        return;
    }
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
    const float radius = (float)b.getProperties().getWithDefault("cornerRadius", 4.f);
    g.setColour(tint);
    g.fillRoundedRectangle(r, radius);
    if (!plain && !(bool)b.getProperties().getWithDefault("flat", false)) {
        g.setColour(b.getToggleState() ? tint.brighter(.25f) : Colours::white.withAlpha((float)b.getProperties().getWithDefault("borderAlpha",.45f)));
        g.drawRoundedRectangle(r, radius, .8f);
    }
}
void MacLook::drawButtonText(Graphics &g, TextButton &b, bool, bool) {
    const float size = (float)b.getProperties().getWithDefault("fontSize", 12.0f);
    g.setFont((bool)b.getProperties()["boldWeight"] ? theme::font(size, true)
              : (bool)b.getProperties()["mediumWeight"] ? theme::mediumFont(size) : theme::semiboldFont(size));
    g.setColour(
        b.findColour(b.getToggleState() ? TextButton::textColourOnId : TextButton::textColourOffId)
            .withMultipliedAlpha(b.isEnabled() || b.getProperties().contains("transportColour") ? 1.0f : .35f));
    const auto icon = b.getProperties().getWithDefault("icon", {}).toString();
    const auto leading = b.getProperties().getWithDefault("leadingIcon", {}).toString();
    if (leading.isNotEmpty() && (bool)b.getProperties()["centredIconLabel"]) {
        const auto label = b.getButtonText();
        const auto font = g.getCurrentFont();
        const float textWidth = GlyphArrangement::getStringWidth(font, label);
        const bool compact = b.getWidth() < 56;
        const float padding = compact ? 2.f : 6.f, gapSize = compact ? 2.f : 4.f;
        const float available = std::max(0.f, b.getWidth() - padding);
        const float scale = jlimit(.75f, 1.f, available / std::max(1.f, textWidth + 12.f + gapSize));
        const float iconSize = 12.f * scale, gap = gapSize * scale;
        const float labelWidth = std::max(0.f, std::min(textWidth * scale,
                                                      available - iconSize - gap));
        const float x = (b.getWidth() - iconSize - gap - labelWidth) * .5f;
        drawInterfaceIcon(g, leading, {x, (b.getHeight() - iconSize) * .5f, iconSize, iconSize});
        g.setFont(font.withPointHeight(font.getHeightInPoints() * scale));
        g.drawText(label, juce::Rectangle<float>(x + iconSize + gap, 0, labelWidth,
                                           (float)b.getHeight()), Justification::centredLeft, false);
        return;
    }
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
    // Keep compact labels such as Patch at their natural width. Use the spare
    // padding before truncating; horizontal glyph compression blurs small text.
    const int textWidth = (int)std::ceil(
        GlyphArrangement::getStringWidth(g.getCurrentFont(), b.getButtonText()));
    const int padding = jlimit(0, 3, (b.getWidth() - textWidth) / 2);
    g.drawFittedText(b.getButtonText(), b.getLocalBounds().reduced(padding, 0),
                     Justification::centred, 1, 1.f);
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
                String::fromUTF8("Selecione as músicas e exporte para o grandMA2. Timecode: 30 FPS.")),
          session(s), lighting(l), error(std::move(fail)) {
        lighting.refresh();
        const StringArray names{"Sequence inicial", String::fromUTF8("Página"), "Executor inicial",
                                "Timecode inicial", "MTC Slot"};
        const int values[]{l.settings.sequence, l.settings.page, l.settings.executor,
                           l.settings.timecode, l.settings.slot};
        for (int i = 0; i < 5; ++i) {
            advancedComponents.add(&label(names[i], 24 + i * 150, 120, 142));
            auto &e = editor(String(values[i]), 24 + i * 150, 144, 136);
            fields.add(&e);
            advancedComponents.add(&e);
            e.setInputRestrictions(4, "0123456789");
            e.onTextChange = [this] { refreshPreview(); };
        }
        advanced = &button(String::fromUTF8("Configuração avançada"), 24, 84, 190, [this] {
            advancedOpen = !advancedOpen;
            resized();
        });
        advanced->getProperties().set("fontSize", 11);
        advancedSummary = &label("", 226, 88, 530);
        auto &reset = button(String::fromUTF8("Restaurar padrões"), 24, 182, 145, [this] {
            const int defaults[]{1, 1, 1, 1, 2};
            for (int i = 0; i < fields.size(); ++i) fields[i]->setText(String(defaults[i]), false);
            refreshPreview();
        });
        advancedComponents.add(&reset);
        advancedComponents.add(&label(String::fromUTF8("Altere somente para evitar posições já ocupadas no show."), 185, 186, 560));
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
        selectAll = &button("Selecionar tudo", 24, 156, 125, [this] {
            for (auto &r : lighting.regions)
                lighting.selected.insert(r.id);
            table.repaint();
        });
        clearSelection = &button(String::fromUTF8("Limpar seleção"), 157, 156, 125, [this] {
            lighting.selected.clear();
            table.repaint();
        });
        auto &copy = button("Copiar mapa", 290, 156, 110, [this] {
            try {
                apply();
                SystemClipboard::copyTextToClipboard(lighting.exportMapCSV());
                status.setText("Mapa copiado.", dontSendNotification);
            } catch (const std::exception &e) {
                error(String::fromUTF8(e.what()));
            }
        });
        advancedComponents.add(&copy);
        copy.setBounds(594, 222, 150, 28);
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
        mtc.setButtonText("Enviar MTC");
        mtc.setToggleState(lighting.mtcEnabled.load(), dontSendNotification);
        addAndMakeVisible(mtc);
        mtc.onClick = [this] { lighting.enableMTC(mtc.getToggleState()); };
        addAndMakeVisible(status);
        status.setFont(theme::font(11));
        status.setColour(Label::textColourId, theme::yellow);
        auto &save = button("Salvar mapa no projeto", 24, 0, 190, [this] {
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
        advancedComponents.add(&save);
        save.setBounds(392, 222, 190, 28);
        midiLabel = &label(String::fromUTF8("Saída MIDI"), 24, 0, 86);
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
        for (auto *component : advancedComponents) component->setVisible(advancedOpen);
        advanced->setToggleState(advancedOpen, dontSendNotification);
        for (int column : {3, 4, 5}) table.getHeader().setColumnVisible(column, advancedOpen);
        updateSummary();
        const int selectionY = advancedOpen ? 222 : 126;
        selectAll->setBounds(24, selectionY, 125, 28);
        clearSelection->setBounds(157, selectionY, 125, 28);
        const int tableY = selectionY + 40;
        table.setBounds(24, tableY, getWidth() - 48, std::max(50, getHeight() - tableY - 164));
        midiLabel->setBounds(24, getHeight() - 148, 86, 28);
        midi.setBounds(112, getHeight() - 148, 320, 28);
        mtc.setBounds(450, getHeight() - 148, 180, 28);
        status.setBounds(24, getHeight() - 112, getWidth() - 48, 24);
        exportButton->setBounds(getWidth() - 232, getHeight() - 78, 208, 30);
        for (auto *c : owned)
            if (c->getName() == "instructions") c->setTopLeftPosition(24, getHeight() - 38);
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
    TextButton *exportButton = nullptr, *advanced = nullptr, *selectAll = nullptr, *clearSelection = nullptr;
    Label *advancedSummary = nullptr, *midiLabel = nullptr;
    Array<Component *> advancedComponents;
    bool advancedOpen = false;
    void updateSummary() {
        if (!advancedSummary) return;
        advancedSummary->setText("Seq " + fields[0]->getText() + String::fromUTF8(" · Página ") + fields[1]->getText()
            + " · Exec " + fields[2]->getText() + " · TC " + fields[3]->getText() + " · MTC " + fields[4]->getText(), dontSendNotification);
    }
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
        updateSummary();
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
        if (col == 1) {
            const bool chosen = lighting.selected.count(r.id) != 0;
            auto box = juce::Rectangle<float>(7, (h - 12.f) * .5f, 12, 12);
            g.setColour(chosen ? theme::green : theme::secondary);
            g.drawRoundedRectangle(box, 2, 1);
            if (chosen) {
                Path tick; tick.startNewSubPath(box.getX()+2, box.getCentreY());
                tick.lineTo(box.getX()+5, box.getBottom()-3); tick.lineTo(box.getRight()-2, box.getY()+3);
                g.strokePath(tick, PathStrokeType(1.5f));
            }
            g.setColour(Colours::white);
            g.drawText(r.name, 26, 0, w-32, h, Justification::centredLeft, true);
            return;
        }
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
    LoginPanel(Auth &a, bool offersTrial = true)
        : Panel("Bem-vindo ao CatLive", "Use o e-mail e o CPF da sua compra."), auth(a) {
        entering = !offersTrial;
        getProperties().set("selfContainedSheet", true);
        logo = ImageCache::getFromMemory(BinaryData::CatLiveSplash_png,
                                         BinaryData::CatLiveSplash_pngSize);
        title.setJustificationType(Justification::centred);
        title.setFont(theme::font(17, true));
        subtitle.setJustificationType(Justification::centred);
        subtitle.setText(String::fromUTF8("Use o e-mail e o CPF da sua compra.\nO trial começa no "
                                          "primeiro acesso neste dispositivo."),
                         dontSendNotification);
        email = &editor({}, 30, 317, 380, 30);
        email->setComponentID("loginEmail");
        email->setTextToShowWhenEmpty("E-mail cadastrado", theme::secondary);
        cpf = &editor({}, 30, 359, 380, 30);
        cpf->setTextToShowWhenEmpty("CPF", theme::secondary);
        cpf->setPasswordCharacter(0x2022);
        cpf->setComponentID("loginCPF");
        login = &button(
            "Entrar", 30, 401, 380,
            [this] {
                submitted = true;
                auth.login(email->getText(), cpf->getText(), auth.deviceName);
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
                        [this, offersTrial] { if (offersTrial) auth.trial(auth.deviceName); else ModalSheet::dismiss(*this); });
        if (!offersTrial) trial->setButtonText("Fechar");
        manage = &button("Gerenciar dispositivos", 30, 443, 380, [this] { devices(); });
        for (auto *b : {stage, trial, login}) {
            b->getProperties().set("fontSize", 13.f);
            b->setColour(TextButton::buttonColourId, Colour(0xff4b845c));
            b->setColour(TextButton::buttonOnColourId, theme::accent);
            b->setColour(TextButton::textColourOnId, Colours::black);
        }
        login->setComponentID("loginSubmit"); stage->setComponentID("loginShowFields");
        login->setToggleState(true, dontSendNotification);
        manage->getProperties().set("fontSize", 13.f);
        manage->getProperties().set("flat", true);
        for (auto *field : {email, cpf}) field->setFont(theme::font(13));
        subtitle.setFont(theme::font(11));
        if (!offersTrial) subtitle.setText(String::fromUTF8("Use o e-mail e o CPF da sua compra."), dontSendNotification);
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
        if (submitted && !auth.busy && auth.allowed()) { submitted = false; cpf->clear(); ModalSheet::dismiss(*this); }
        const bool credentials = email->getText().isNotEmpty() && cpf->getText().isNotEmpty();
        login->setEnabled(!auth.busy && credentials);
        manage->setEnabled(!auth.busy && credentials);
        trial->setEnabled(!auth.busy);
        stage->setEnabled(!auth.busy);
        login->setButtonText(auth.busy ? String::fromUTF8("Aguarde…") : "Entrar");
        message.setText(auth.busy ? String::fromUTF8("Validando acesso…") : auth.message,
                        dontSendNotification);
    }

  private:
    Auth &auth;
    Image logo;
    TextEditor *email = nullptr, *cpf = nullptr;
    TextButton *login = nullptr, *trial = nullptr, *stage = nullptr, *manage = nullptr;
    bool entering = false, submitted = false;
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
                   getWidth() - 302, 0, 154, getHeight(), Justification::centredRight);
        if (w.browserVisible || w.loginPanel)
            return;
        auto saved = Time::fromISO8601(text(w.session.project().updatedAt));
        auto project = text(w.session.project().name) + (w.session.dirty ? " *" : "");
        g.setColour(Colours::white.withAlpha(.9f));
        g.setFont(theme::semiboldFont(11));
        const int accessWidth = std::min(440, std::max(80, getWidth() - 604));
        g.drawFittedText(project + String::fromUTF8(" - ") +
                             (w.session.document == File() ? String(String::fromUTF8("Não salvo"))
                                                           : saved.formatted("%d/%m/%Y %H:%M")),
                         14, 0, std::max(0, (getWidth() - accessWidth) / 2 - 28), getHeight(),
                         Justification::centredLeft, 1, 1.f);
        g.setColour(theme::green);
        g.drawFittedText(w.auth.title, (getWidth() - accessWidth) / 2, 0, accessWidth, getHeight(),
                         Justification::centred, 1, 1.f);
    }
    void resized() override {
        auto x = getWidth() - 138;
        minimise.setBounds(x, 0, 46, getHeight());
        maximise.setBounds(x + 46, 0, 46, getHeight());
        close.setBounds(x + 92, 0, 46, getHeight());
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
    WindowControlButton minimise{DocumentWindow::minimiseButton},
        maximise{DocumentWindow::maximiseButton}, close{DocumentWindow::closeButton};
    ComponentDragger dragger;
    void toggleMaximise() {
        if (auto *peer = getTopLevelComponent()->getPeer()) {
            auto hwnd = (HWND)peer->getNativeHandle();
            ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        }
    }
};

class Workspace::TrackRow final : public Component, public DragAndDropTarget {
  public:
    TrackRow(Workspace &workspace, ID trackID) : w(workspace), id(std::move(trackID)) {
        setComponentID("trackRow:"+text(id));
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
                format.addItem(8, "MP3", true, track->recordingFormat == "mp3");
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
                                                t.recordingFormat = result == 6 ? "wav" : result == 7 ? "wav32" : "mp3";
                                        }
                            });
                        });
                    });
            }
        };
        env.setButtonText("Env");
        env.getProperties().set("fontSize", 10);
        env.setColour(TextButton::buttonColourId, theme::yellow);
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
        phase.setColour(TextButton::buttonOnColourId, theme::yellow);
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
        fxchain::bind(fx, w.session, id, [this](bool remove) { w.changeMixerFX(id, remove); });
        addAndMakeVisible(folder);
        folder.setWantsKeyboardFocus(false);
        folder.setTooltip(String::fromUTF8("Recolher / expandir grupo"));
        folder.getProperties().set("plain", true);
        folder.onClick = [this] { w.toggleGroup(id); };
        output.onClick = [this] {
            Workspace::showPanel(
                track() && track()->role.id == "timecode" ? "Timecode" : "Patch",
                std::make_unique<PatchPanel>(w.session, id,
                                             [safe = SafePointer<Workspace>(&w)](String error) {
                                                 if (safe)
                                                     safe->showError(error);
                                             }, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}),
                360, 400);
        };
        addAndMakeVisible(volume);
        volume.setComponentID("trackVolume");
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
        special=std::make_unique<SpecialTrackControls>(w.session,id,[this](ID target,String action){w.specialTrackAction(target,action);});addAndMakeVisible(*special);
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
            volume.setValue(w.session.trackDisplayVolume(id, t->volume), dontSendNotification);
            volume.setEnabled(!w.session.trackFaderLocked(id));
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
            record.setColour(TextButton::buttonOnColourId, Colour(0xffff1f1f));
            const auto settings = t->fxJSON ? JSON::parse(text(*t->fxJSON)) : var();
            fx.setColour(TextButton::textColourOffId, fxchain::colour(settings));
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
            if(special)special->refresh();resized();
            repaint();
        }
    }
    int groupIndent() const {
        const auto *song = w.session.song(); const auto *item = track();
        int depth = 0; auto parent = item ? item->parentTrackID : std::optional<ID>();
        while (song && parent && depth < 5) {
            ++depth; const auto i = trackTree::index(*song, *parent);
            if (i == song->tracks.size()) break;
            parent = song->tracks[i].parentTrackID;
        }
        return depth ? 16 + (depth - 1) * 8 : 0;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        if (auto *t = track()) {
            const int indent = groupIndent();
            if (indent > 0) {
                const auto *song = w.session.song();
                const auto index = trackTree::index(*song, id);
                const bool last = index + 1 >= song->tracks.size() || song->tracks[index + 1].parentTrackID != t->parentTrackID;
                const int x = indent - 11;
                g.setColour(theme::green.withAlpha(.7f));
                g.drawVerticalLine(x, 0, last ? 17.f : (float)getHeight());
                g.drawHorizontalLine(17, (float)x, (float)indent - 4);
            }
            const bool emphasized = w.trackSelected(id) && jaras::fixedTrackName(t->role).empty();
            const auto colour = theme::trackSurface(theme::track(*t), emphasized,
                w.session.song() ? trackTree::silenced(*w.session.song(), *t) : t->mute);
            g.setColour(colour);
            const auto lanes = automation::visible(*t);
            const int body = getHeight() - lanes.size() * 32;
            g.fillRect(indent, 0, getWidth() - indent, body - 1);
            if (emphasized) {
                g.setColour(Colours::white.withAlpha(.65f));
                g.drawRect((float)indent + .5f, .5f, (float)getWidth() - indent - 1, (float)body - 2, 1.f);
            }
            if (body >= 64) {
                const auto levels = w.session.audio.meterLevels(id);
                for (int ch = 0; ch < 2; ++ch)
                    meterDisplay::bar(g, {(float)indent + ch * 6.f, 4, 5, (float)body - 8}, levels[(size_t)ch]);
                g.setColour(Colours::black.withAlpha(.38f));
                g.fillRect(indent + 14, 4, 4, body - 8);
            }
            g.setFont(theme::semiboldFont(11));
            g.setColour(theme::surfaceText(colour));
            String number;
            if (const auto *song = w.session.song())
                number = String((int)trackTree::index(*song, id) + 1).paddedLeft('0', 2) + "  ";
            const bool expanded = body >= 64;
            const int titleX = indent + (expanded ? 22 : 4);
            const bool textTrack=jaras::isTeleprompterRole(t->role)||t->role.id=="chords";
            const int titleY = expanded ? (textTrack?3:47) : std::max(0, (body - 21) / 2);
            const int titleRight = textTrack&&special ? special->getX()-4 : expanded ? getWidth()-4 : (jaras::fixedTrackName(t->role).empty()?output.getX()-4:special?special->getX()-4:getWidth()-4);
            g.drawText(number + text(t->name), titleX, titleY,
                       std::max(1, titleRight - titleX), expanded ? 16 : 21,
                       Justification::centredLeft, true);
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
        const auto *t = track();
        const int body = getHeight() - (t ? automation::visible(*t).size() * 32 : 0);
        const bool expanded = body >= 64;
        const int y = expanded ? 3 : std::max(0, (body - 21) / 2);
        const int h = expanded ? 24 : 21;
        int x = getWidth() - 4;
        auto place = [&](Component &control, int width) {
            x -= width; control.setBounds(x, y, width, h); x -= 3;
        };
        const bool standard=t&&jaras::fixedTrackName(t->role).empty();
        const bool textTrack=t&&(jaras::isTeleprompterRole(t->role)||t->role.id=="chords");
        for(auto *b:{&record,&fx,&env,&output})b->setVisible(standard);
        const bool audioButtons=standard||(t&&(t->role.id=="timecode"||t->role.id=="generatedClick"));
        mute.setVisible(audioButtons);solo.setVisible(audioButtons);
        if(solo.isVisible())place(solo,22);if(mute.isVisible())place(mute,22);
        if(special){special->setVisible(!standard);special->setBounds(std::max(22,x-(t&&t->role.id=="timecode"?116:108)),y,t&&t->role.id=="timecode"?116:108,textTrack?48:h);}
        pan.setVisible(expanded&&standard);
        if (expanded&&standard) place(pan, 42);
        if(standard){place(record,22);place(fx,22);place(env,28);place(output,34);}
        folder.setBounds(output.getX() - 31, y + (h - 20) / 2, 28, 20);
        folder.setVisible(expanded && isFolder());
        phase.setVisible(expanded&&standard); volume.setVisible(expanded&&!textTrack);
        phase.setBounds(getWidth() - 26, 27, 22, 20);
        phase.getProperties().set("plain", true);
        volume.setBounds(22 + groupIndent(), 27, std::max(1, getWidth() - (standard ? 52 : 26) - groupIndent()), 20);
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
        w.selectMixerTrack(id, e.mods);
        w.selectedClip.clear();
        w.updateState();
        repaint();
        if (e.mods.isPopupMenu()) {
            ++w.contextCount;
            w.showTrackMenu(id, e.getScreenPosition());
        } else {
            dragging = true;
        }
    }
    void mouseDrag(const MouseEvent &e) override {
        if(dragging && e.getDistanceFromDragStart()>8 && track() && jaras::fixedTrackName(track()->role).empty() && w.session.song()) {
            dragging=false;w.startDragging(trackDrop::description(w.session.project(),*w.session.song(),id),this);
        }
    }
    void mouseUp(const MouseEvent &) override {dragging=false;setMouseCursor(MouseCursor::NormalCursor);}
    bool isInterestedInDragSource(const SourceDetails &d) override {return w.session.song()&&!trackDrop::source(d.description,w.session.project(),*w.session.song()).empty();}
    void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
    void itemDragMove(const SourceDetails &d) override {
        if(!w.session.song())return;
        w.trackDropPreview=trackDrop::resolve(*w.session.song(),trackDrop::source(d.description,w.session.project(),*w.session.song()),id,d.localPosition.y>getHeight()/2,d.localPosition.x<16);
        w.trackDropBlocked=w.trackDropPreview?ID{}:id;w.repaint();
    }
    void itemDragExit(const SourceDetails &) override {w.trackDropPreview.reset();w.trackDropBlocked.clear();w.repaint();}
    void itemDropped(const SourceDetails &d) override {
        itemDragMove(d);const auto destination=w.trackDropPreview;const ID song=w.session.song()?w.session.song()->id:ID{};
        itemDragExit(d);
        if(destination)w.perform([&]{w.session.edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==song)trackDrop::apply(s,*destination);});});
    }
    void mouseDoubleClick(const MouseEvent &) override { w.editTrack(id); }

  private:
    Workspace &w;
    ID id;
    std::unique_ptr<SpecialTrackControls> special;
    QuietButton mute, solo, phase, fx, output, env, record;
    TextButton folder;
    GainFader volume;
    ParameterSlider pan;
    bool updating = false, dragging = false;
};

class Workspace::Timeline final : public Component, private ScrollBar::Listener, private Timer {
  public:
    explicit Timeline(Workspace &owner)
        : w(owner), horizontal(false), vertical(true), canvas(*this), heads(*this) {
        addAndMakeVisible(canvas);
        canvas.setBufferedToImage(true);
        addAndMakeVisible(heads);
        addChildComponent(horizontal);
        horizontal.setVisible(false);
        addChildComponent(vertical);
        vertical.setVisible(false);
        horizontal.addListener(this);
        vertical.addListener(this);
        horizontal.addMouseListener(this, false);
        vertical.addMouseListener(this, false);
        canvas.addAndMakeVisible(envelopeContent);
        envelopeContent.setInterceptsMouseClicks(false, true);
        heads.setInterceptsMouseClicks(false, false);
        setWantsKeyboardFocus(false);
    }
    void resized() override {
        auto area = getLocalBounds();
        horizontal.setBounds({});
        vertical.setBounds({});
        canvas.setBounds(area);
        heads.setBounds(area);
        updateRanges();
    }
    void mouseDown(const MouseEvent&) override { stopGesture(); }
    void cancelInteraction() { canvas.cancelDrag(); }
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
    void refreshWaveforms() {
        const auto current = waveforms.revision();
        if (current != waveformRevision) { waveformRevision = current; canvas.repaint(); }
    }
    void followPlayback() {
        const auto &state = w.session.transport();
        if (!w.appearance.continuousScroll() || !(state.playing || state.subPlay.playing)) { followPolicy.reset(); return; }
        if (gestureMode != 0 || Component::isMouseButtonDownAnywhere() || Component::getNumCurrentlyModalComponents() != 0) return;
        const double position = state.subPlay.playing ? state.subPlay.position : state.position;
        const auto *song=w.session.song();
        const String source=(song?text(song->id):String{})+(state.subPlay.playing?"-sub":"-main");
        const auto next=followPolicy.destination(position,w.pixelsPerSecond,horizontal.getMaximumRangeLimit(),
            horizontal.getCurrentRangeStart(),canvas.getWidth(),source,Component::getApproximateScaleFactorForComponent(this));
        if(next)horizontal.setCurrentRangeStart(*next,sendNotificationSync);
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
        const float subOpacity = Session::subCursorOpacity(Time::getMillisecondCounterHiRes() / 1000);
        if (b != lastSub || w.session.subCursorVisible() != lastSubVisible || (lastSubVisible && subOpacity != lastSubOpacity)) {
            lastSubOpacity = subOpacity;
            lastSubVisible = w.session.subCursorVisible();
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
        stopGesture();
        applyZoom(scale, anchor);
    }
    void zoomOnCursor(double scale) {
        stopGesture();
        applyCursorZoom(scale);
    }
    void applyCursorZoom(double scale) {
        const double cursor = w.session.transport().editPosition;
        const float anchor = jlimit(0.f, (float)canvas.getWidth(), xAt(cursor));
        w.pixelsPerSecond = jlimit(timelineGrid::minimumZoom, timelineGrid::maximumZoom, scale);
        w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
        updateRanges();
        horizontal.setCurrentRangeStart(cursor * w.pixelsPerSecond - anchor);
        invalidate();
    }
    void applyZoom(double scale, float anchor) {
        auto old = timeAt(anchor);
        w.pixelsPerSecond = jlimit(timelineGrid::minimumZoom, timelineGrid::maximumZoom, scale);
        w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
        updateRanges();
        horizontal.setCurrentRangeStart(old * w.pixelsPerSecond - anchor);
        invalidate();
    }
    void fit() {
        stopGesture();
        if (auto *s = w.session.song()) {
            w.pixelsPerSecond = jlimit(
                timelineGrid::minimumZoom, timelineGrid::maximumZoom, std::max(1, canvas.getWidth() - 40) / std::max(1., s->duration));
            w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
            horizontal.setCurrentRangeStart(0);
            updateRanges();
        }
    }
    void initialView() {
        zoomAt(std::max(1, canvas.getWidth() - 40) / 180.0, 0);
        horizontal.setCurrentRangeStart(std::max(0., w.session.transport().editPosition - 10) * w.pixelsPerSecond);
    }
    void scroll(double x, double y) {
        if (x != 0)
            horizontal.setCurrentRangeStart(horizontal.getCurrentRangeStart() + x);
        if (y != 0)
            vertical.setCurrentRangeStart(vertical.getCurrentRangeStart() + y);
    }
    var state() const {
        auto v = object();
        if(const auto range=w.session.selectedTimeRange()) {auto selection=object();put(selection,"start",range->first);put(selection,"end",range->second);put(v,"timeSelection",selection);}
        put(v, "horizontal", horizontal.getCurrentRangeStart());
        put(v, "horizontalScrollbarVisible", horizontal.isVisible());
        put(v, "waveforms", waveforms.diagnostics());
        put(v, "paintMilliseconds", paintMilliseconds);
        put(v, "maxPaintMilliseconds", maxPaintMilliseconds);
        put(v, "paintCount", (int64)paintCount);
        Array<var> stages;for(auto ms:paintStages) stages.add(ms);put(v,"paintStagesMilliseconds",stages);
        put(v, "vertical", vertical.getCurrentRangeStart());
        put(v, "zoom", w.pixelsPerSecond);
        put(v, "subCursorVisible", w.session.subCursorVisible());
        put(v, "gestureActive", gestureMode != 0);
        put(v, "trackHeight", w.trackHeight);
        put(v, "width", canvas.getWidth());
        Array<var> items;
        if (const auto *song=w.session.song()) for(size_t row=0;row<song->tracks.size();++row) {
            if(w.rowHidden((int)row)) continue;
            const auto &track=song->tracks[row];
            const int h=w.itemLaneHeight((int)row);
            for(const auto &clip:track.clips) {
                const juce::Rectangle<float> r(xAt(clip.startTime),(float)(ruler+w.rowTop((int)row)-w.verticalOffset+w.itemLanes((int)row).lane(clip.id)*h+3),std::max(2.f,(float)(clip.duration*w.pixelsPerSecond)-2),(float)h-6);
                if(!r.intersects(canvas.getLocalBounds().toFloat().withTrimmedTop((float)ruler))) continue;
                const ItemHeader header(r,(float)canvas.getWidth(),track,clip);
                auto item=object(); put(item,"id",text(clip.id));put(item,"track",text(track.id));put(item,"name",text(clip.name));put(item,"lane",w.itemLanes((int)row).lane(clip.id));
                auto rect=[&](const char *key,juce::Rectangle<float> b){auto data=object();put(data,"x",b.getX()+getX());put(data,"y",b.getY()+getY());put(data,"width",b.getWidth());put(data,"height",b.getHeight());put(item,Identifier(key),data);};
                rect("bounds",r);rect("gain",header.gainRect);rect("pan",header.panRect);rect("fx",header.fxRect);rect("fadeIn",header.fadeRect(clip,true));rect("fadeOut",header.fadeRect(clip,false));
                rect("fadeInCurve",header.shapeRect(clip,true,false));rect("fadeInSCurve",header.shapeRect(clip,true,true));rect("fadeOutCurve",header.shapeRect(clip,false,false));rect("fadeOutSCurve",header.shapeRect(clip,false,true));
                put(item,"fadeInCurveValue",clip.fadeInCurve.value_or(0));put(item,"fadeInSCurveValue",clip.fadeInSCurve.value_or(1));put(item,"fadeOutCurveValue",clip.fadeOutCurve.value_or(0));put(item,"fadeOutSCurveValue",clip.fadeOutSCurve.value_or(1));
                put(item,"gainValue",clip.gain.value_or(1));put(item,"panValue",clip.pan.value_or(0));put(item,"fadeInValue",clip.fadeIn.value_or(0));put(item,"fadeOutValue",clip.fadeOut.value_or(0));items.add(item);
            }
        }
        put(v,"visibleItems",items);
        put(v, "x", getX());
        put(v, "y", getY());
        return v;
    }
    void adjustTrackHeight(float delta) {
        stopGesture();
        if (delta == 0 || !std::isfinite(delta)) return;
        w.trackHeight = jlimit(24, 240, (int)std::lround(w.trackHeight * std::exp(delta * .6)));
        w.resized();
        updateRanges();
    }
    void mouseWheelMove(const MouseEvent &e, const MouseWheelDetails &d) override {
        ++w.wheelCount;
        if (e.mods.isCtrlDown()) {
            adjustTrackHeight(d.deltaY);
            return;
        }
        const bool pan = e.mods.isShiftDown() || e.mods.isLeftButtonDown() || std::abs(d.deltaX) > std::abs(d.deltaY);
        if (pan && e.mods.isLeftButtonDown()) canvas.cancelDrag();
        const double delta = pan ? -500 * (std::abs(d.deltaX) > std::abs(d.deltaY) ? d.deltaX : d.deltaY)
                                 : d.deltaY * std::log(1.3) * 4;
        if (delta == 0 || !std::isfinite(delta)) return;
        const int mode = pan ? 2 : 1, direction = delta > 0 ? 1 : -1;
        const auto now = Time::getMillisecondCounterHiRes();
        if (gestureMode != mode || direction != gestureDirection || now - lastGestureInput > 250) {
            stopGesture();
            gestureMode = mode;
            gestureTarget = pan ? horizontal.getCurrentRangeStart() : std::log(w.pixelsPerSecond);
        }
        gestureDirection = direction;

        gestureTarget = pan
            ? jlimit(0., std::max(0., horizontal.getMaximumRangeLimit() - horizontal.getCurrentRangeSize()), gestureTarget + delta)
            : jlimit(std::log(timelineGrid::minimumZoom), std::log(timelineGrid::maximumZoom), gestureTarget + delta);
        lastGestureInput = now;
        if (!isTimerRunning()) { lastGestureFrame = now - 16; startTimerHz(60); }
        timerCallback();
    }

  private:
    Workspace &w;
    int gestureMode = 0, gestureDirection = 0;
    double gestureTarget = 0, lastGestureInput = 0, lastGestureFrame = 0;

    void stopGesture() { stopTimer(); gestureMode = 0; gestureDirection = 0; }
    void timerCallback() override {
        if (!gestureMode) return;
        const auto now = Time::getMillisecondCounterHiRes();
        const double dt = jlimit(0., .1, (now - lastGestureFrame) / 1000.);
        lastGestureFrame = now;
        const double current = gestureMode == 1 ? std::log(w.pixelsPerSecond) : horizontal.getCurrentRangeStart();
        const double distance = gestureTarget - current;
        const bool settled = std::abs(distance) < (gestureMode == 1 ? .0005 : .2);
        const double next = settled ? gestureTarget : current + distance * (1 - std::exp(-dt / .065));
        if (gestureMode == 1) applyCursorZoom(std::exp(next));
        else horizontal.setCurrentRangeStart(next);
        if (settled) stopGesture();
    }
    WaveformCache waveforms;
    uint64 waveformRevision = 0;
    struct MarkerFlag {ID id;double position=0,next=std::numeric_limits<double>::infinity();String label;float width=0;unsigned colour=0;bool tempo=false;};
    uint64 markerRevision=~uint64(0);
    std::vector<MarkerFlag> markerFlags;
    void refreshMarkers(const jaras::Song &song) {
        if(markerRevision==w.session.revision) return;
        markerFlags.clear();markerRevision=w.session.revision;
        if(song.markers) for(const auto &m:*song.markers) {
            MarkerFlag flag;flag.id=m.id;flag.position=m.position;flag.colour=m.color;flag.tempo=bool(m.tempoBPM);
            flag.label=m.tempoBPM ? String(*m.tempoBPM,*m.tempoBPM==std::floor(*m.tempoBPM)?0:1)+"  "+String(m.tempoBeats.value_or(4))+"/"+String(m.tempoUnit.value_or(4)) : text(m.name);
            flag.width=std::ceil(GlyphArrangement::getStringWidth(theme::mediumFont(9),flag.label))+10;
            markerFlags.push_back(std::move(flag));
        }
        std::stable_sort(markerFlags.begin(),markerFlags.end(),[](const auto &a,const auto &b){return a.position<b.position;});
        for(int type=0;type<2;++type) {
            double next=std::numeric_limits<double>::infinity(),position=next;
            for(auto at=markerFlags.rbegin();at!=markerFlags.rend();++at) if(at->tempo==bool(type)) {
                if(at->position<position) {next=position;position=at->position;}
                at->next=next;
            }
        }
    }

    double paintMilliseconds = 0, maxPaintMilliseconds = 0;
    std::array<double,4> paintStages{};
    std::map<std::string,File> waveformFiles;
    File waveformDirectory;
    File waveformFile(const std::string &relative) {
        if(waveformDirectory!=w.session.mediaDirectory) {waveformFiles.clear();waveformDirectory=w.session.mediaDirectory;}
        auto at=waveformFiles.find(relative);
        if(at==waveformFiles.end()) at=waveformFiles.emplace(relative,ProjectCodec::resolveMedia(waveformDirectory,relative,false)).first;
        return at->second;
    }
    uint64 paintCount = 0;
    static constexpr int ruler = 64;
    ScrollBar horizontal, vertical;
    TimelinePlaybackFollowPolicy followPolicy;
    Component envelopeContent;
    OwnedArray<EnvelopeLane> lanes;
    std::vector<std::pair<int, int>> lanePositions;
    uint64 lanesRevision = ~uint64(0);
    int lastMain = -100, lastSub = -100;
    float lastSubOpacity = 1;
    bool lastSubVisible = false;
    bool lastLoop = false;
    class Canvas final : public Component {
      public:
        explicit Canvas(Timeline &timeline) : t(timeline) { setOpaque(true); setComponentID("timelineCanvas"); }
        void paint(Graphics &g) override {
            const auto started = Time::getMillisecondCounterHiRes();
            auto measurePaint = [&] {
                if (t.w.capturingSnapshot) return;
                t.paintMilliseconds = Time::getMillisecondCounterHiRes() - started;
                t.maxPaintMilliseconds = std::max(t.maxPaintMilliseconds, t.paintMilliseconds);
                ++t.paintCount;
            };
            const ScopeGuard measure{measurePaint};
            auto stageStart=started;int stageIndex=0;
            auto stage=[&]{const auto now=Time::getMillisecondCounterHiRes();if(!t.w.capturingSnapshot && stageIndex<(int)t.paintStages.size())t.paintStages[(size_t)stageIndex]=now-stageStart;++stageIndex;stageStart=now;};
            g.fillAll(t.w.appearance.colour("jaras.timeline.background", 0x1e1e1e));
            auto *song = t.w.session.song();
            if (!song)
                return;
            auto bounds = getLocalBounds();
            const auto viewStart = t.timeAt(0), viewEnd = t.timeAt((float)getWidth());
            g.setColour(theme::panel);
            g.fillRect(0, 0, getWidth(), ruler);
            g.setFont(theme::font(10));
            const auto grid = timelineGrid::ticks(*song, viewStart, viewEnd, t.w.pixelsPerSecond);
            const float pixel = 1.f / std::max(.01f, g.getInternalContext().getPhysicalPixelScaleFactor());
            const auto lineX = [&](double time) { return std::floor(t.xAt(time) / pixel) * pixel; };
            for (const auto &tick : grid) {
                const float x = lineX(tick.time);
                g.setColour(theme::green.withAlpha(.65f));
                g.fillRect(x, 48.f, pixel, tick.primary ? 5.f : 3.f);
                if (tick.label.isNotEmpty()) {
                    g.setFont(Font(FontOptions(Font::getDefaultMonospacedFontName(), 9.f, Font::plain)));
                    g.drawText(tick.label, (int)x + 3, 48, 124, 16, Justification::centredLeft);
                }
            }
            const bool showGrid = t.w.appearance.gridlines() &&
                (!song->timeSettings || song->timeSettings->divisions != 0);
            const auto drawGrid = [&](float top, float bottom) {
                if (!showGrid || bottom <= top) return;
                for (const auto &tick : grid) {
                    g.setColour(tick.primary ? t.w.appearance.colour("jaras.timeline.primaryGrid", 0x535250)
                        : t.w.appearance.colour("jaras.timeline.secondaryGrid", 0x333235).withAlpha(.85f));
                    g.fillRect(lineX(tick.time), top, pixel, bottom - top);
                }
            };
            drawGrid((float)ruler, (float)getHeight());
            stage();
            t.refreshMarkers(*song);
            for(const auto &m:t.markerFlags) {
                const float x=t.xAt(m.position);
                if(x>getWidth()) break;
                const float width=std::min(m.width,(float)((m.next-m.position)*t.w.pixelsPerSecond-3));
                if(width<18 || x+width<0) continue;
                const juce::Rectangle<float> flag(x,m.tempo?33.f:17.f,width,14);
                if(m.tempo) {
                    g.setColour(theme::display);g.fillRoundedRectangle(flag.reduced(.5f),4);
                    g.setColour(theme::line);g.drawRoundedRectangle(flag.reduced(.5f),4,1);
                } else {g.setColour(Colour(0xff000000|m.colour));g.fillRect(flag);}
                g.setColour(m.tempo?Colours::white:Colours::black);g.setFont(theme::mediumFont(9));
                g.drawText(m.label,flag.reduced(4,0),m.tempo?Justification::centred:Justification::centredLeft,true);
            }
            for (const auto &p : song->parts) {
                if (p.parentRegionID) continue;
                float a = t.xAt(p.startTime), b = t.xAt(p.endTime);
                if (b < 0 || a > getWidth())
                    continue;
                g.setColour(Colour(0xff000000 | p.color.value_or(0x665566)));
                g.fillRect(a, 0.f, std::max(1.f, b - a - 1), 16.f);
                g.setColour(Colours::white);
                g.setFont(theme::font(10, true));
                g.drawFittedText(p.uppercaseName.value_or(false) ? unicodeCase(text(p.name)) : text(p.name), (int)a + 7, 0, std::max(0, (int)(b - a) - 12), 16,
                                 Justification::centredLeft, 1);
            }
            g.setColour(theme::line);
            for (int y : {16, 32, 48, 63})
                g.drawHorizontalLine(y, 0, (float)getWidth());
            stage();
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
                const bool trackMuted=trackTree::silenced(*song,track);
                auto background = t.w.appearance.colour("jaras.timeline.background", 0x1e1e1e);
                g.setColour(background);
                g.fillRect(0, y, getWidth(), height);
                if (t.w.trackSelected(track.id)) {
                    g.setColour(theme::trackSurface(theme::track(track), true, false).withAlpha(.12f));
                    g.fillRect(0, y, getWidth(), height);
                    g.setColour(Colours::white.withAlpha(.025f));
                    g.fillRect(0, y, getWidth(), height);
                }
                g.setColour(theme::line.withAlpha(.8f));
                g.drawHorizontalLine(y + height - 1, 0, (float)getWidth());
                drawGrid((float)y, (float)(y + height));
                const bool movingHere = movingClipPreview && previewRow == (int)row;
                for (size_t itemIndex = 0; itemIndex < track.clips.size() + (movingHere ? 1 : 0); ++itemIndex) {
                    const bool movedItem = itemIndex == track.clips.size();
                    const auto &sourceClip = movedItem ? *movingClipPreview : track.clips[itemIndex];
                    if (!movedItem && movingClipPreview && sourceClip.id == movingClipPreview->id) continue;
                    const auto &clip = controlClip && controlClip->id == sourceClip.id ? *controlClip
                        : resizedClipPreview && resizedClipPreview->id == sourceClip.id ? *resizedClipPreview : sourceClip;
                    const int itemHeight = t.w.itemLaneHeight((int)row);
                    const int itemY = y + (movedItem ? previewLane : t.w.itemLanes((int)row).lane(clip.id))*itemHeight;
                    float left = t.xAt(clip.startTime),
                          right = t.xAt(clip.startTime + clip.duration);
                    if (right < 0 || left > getWidth())
                        continue;
                    auto colour = theme::track(track);
                    auto rect = juce::Rectangle<float>(
                        left, itemY + 3.f, std::max(2.f, right - left - 2), itemHeight - 6.f);
                    const bool muted = trackMuted || clip.muted;
                    const bool selected = t.w.clipSelected(clip.id);
                    if (selected) {
                        const float peak = std::max({colour.getFloatRed(), colour.getFloatGreen(), colour.getFloatBlue()});
                        const auto emphasize = [peak](float channel) { return jlimit(0.f, 1.f, (peak - (peak - channel) * 1.45f) * 1.15f); };
                        colour = Colour::fromFloatRGBA(emphasize(colour.getFloatRed()), emphasize(colour.getFloatGreen()), emphasize(colour.getFloatBlue()), 1);
                    }
                    const float luminance = .2126f * colour.getFloatRed() + .7152f * colour.getFloatGreen() + .0722f * colour.getFloatBlue();
                    const float waveGray = muted ? .78f : luminance > .68f ? .52f : luminance > .42f ? .9f : .8f;
                    if (muted) colour = Colour::greyLevel(selected ? .7f : .55f);
                    const bool compact=rect.getWidth()<20;
                    const auto outline=itemOutline(clip,rect,(float)getWidth(),t.w.pixelsPerSecond);
                    if(compact) g.setColour(colour.withAlpha(muted?.55f:.88f));
                    else g.setGradientFill(ColourGradient(colour.withAlpha(muted?.55f:1.f),0,rect.getY(),colour.withAlpha(muted?.25f:selected?1.f:.78f),0,rect.getBottom(),false));
                    g.fillPath(outline);
                    if(selected || !compact) {g.setColour(selected?theme::green:colour.withAlpha(.75f));g.strokePath(outline,PathStrokeType(selected?1.5f:.6f));}
                    g.saveState();g.reduceClipRegion(outline);
                    const ItemHeader header(rect,(float)getWidth(),track,clip);
                    if(!compact) {
                        g.setColour(Colours::black.withAlpha(.16f));g.fillRect(rect.withHeight(std::min(17.f,rect.getHeight())));
                        header.draw(g,clip);
                        const float headerRight=header.visible.getRight(),nameLeft=header.titleLeft;
                        if(headerRight-nameLeft>=12) {
                            g.setFont(theme::semiboldFont(9));g.setColour(Colours::white.withAlpha(track.mute?.5f:.95f));
                            g.drawText(text(clip.name),juce::Rectangle<float>(nameLeft,rect.getY(),headerRight-nameLeft-3,17),Justification::centredLeft,true);
                        }
                    }
                    if (clip.midi && !clip.frozenMIDI.value_or(false) && rect.getHeight() > 26) {
                        const auto body = rect.withTrimmedTop(18).withTrimmedBottom(2);
                        const double begin = std::max(clip.startTime, t.timeAt(0)),
                                     finish = std::min(clip.startTime + clip.duration, t.timeAt((float)getWidth()));
                        if (finish > begin) {
                            auto visible = clip;
                            visible.sourceOffset = ClipTempo(clip, song).sourceAt(begin);
                            visible.startTime = begin; visible.duration = finish - begin;
                            visible.gain = 1; visible.muted = false;
                            visible.fadeIn.reset(); visible.fadeOut.reset();
                            jaras::Track display; display.clips.push_back(std::move(visible));
                            int low = 60, high = 72;
                            if (!clip.midi->notes.empty()) {
                                low = 127; high = 0;
                                for (const auto &note : clip.midi->notes) { low = std::min(low,note.pitch); high = std::max(high,note.pitch); }
                                low = std::max(0,low-2); high = std::min(127,high+2);
                            }
                            const float step = body.getHeight() / std::max(12,high-low+1);
                            g.saveState(); g.reduceClipRegion(body.getSmallestIntegerContainer());
                            g.setColour(Colours::white.withAlpha(muted ? .45f : .85f));
                            for (const auto &note : playbackNotes(display, song, true))
                                g.fillRect(t.xAt(note.start), body.getBottom()-(note.pitch-low+1)*step,
                                           std::max(1.f,t.xAt(note.end)-t.xAt(note.start)),std::max(1.f,step*.75f));
                            g.restoreState();
                        }
                    }
                    if (clip.text && !clip.text->empty() && right - left >= 24) {
                        g.setFont(theme::font(14));
                        g.drawFittedText(text(*clip.text), (int)left + 6, itemY + 23,
                                         std::max(1, (int)(right - left) - 12),
                                         std::max(1, itemHeight - 28), Justification::centred,
                                         std::max(1, (itemHeight - 28) / 16), .5f);
                    }
                    const auto start = std::max(0, (int)std::floor(left)),
                               end = std::min(getWidth(), (int)std::ceil(right));
                    if (track.role.id=="generatedClick" && !clipEditing::projection(clip)) {
                        auto body=rect.withTrimmedTop(18).withTrimmedBottom(2);
                        Path pulses;const float middle=body.getCentreY(),amplitude=body.getHeight()*.45f;
                        for(double time:timelineGrid::clickBeats(*song,clip,std::max(clip.startTime,t.timeAt(0)),std::min(clip.startTime+clip.duration,t.timeAt((float)getWidth())),t.w.pixelsPerSecond)) {
                            const float x=t.xAt(time),tail=jlimit(1.f,16.f,(float)(.08*t.w.pixelsPerSecond));
                            pulses.addTriangle(x,middle-amplitude,x+tail,middle,x,middle+amplitude);
                        }
                        g.saveState();g.reduceClipRegion(body.getSmallestIntegerContainer());
                        g.setColour(Colour::greyLevel(.88f).withAlpha(muted?.5f:.9f));g.fillPath(pulses);g.restoreState();
                    } else if (!clip.text && (!clip.midi || clip.frozenMIDI.value_or(false))) {
                        const auto &source = clip.audioFile ? clip.audioFile : track.audioFile;
                        const auto data = source ? t.waveforms.request(t.waveformFile(source->path)) : nullptr;
                        if (data) {
                            WaveformRenderer::draw(g, t.waveforms, data, clip, rect,
                                getLocalBounds().toFloat(), t.w.pixelsPerSecond, Colour::greyLevel(waveGray), false);
                        } else if (!source) {
                            // Legacy/generated items may contain their own overview.
                            // Never substitute these coarse peaks for pending real PCM.
                            const int channels = std::max(1, (int)clip.waveformChannels.size());
                            const float top = rect.getY() + 18.f;
                            const float laneHeight = std::max(1.f, rect.getBottom() - top - 2.f) / channels;
                            const float amplitude = laneHeight * .98f * (float)jlimit(0., std::pow(10., 24. / 20), clip.gain.value_or(1));
                            g.setColour(Colour::greyLevel(waveGray));
                            for (int channel = 0; channel < channels; ++channel) {
                                const auto &embedded = clip.waveformChannels.empty() ? clip.waveform : clip.waveformChannels[(size_t)channel];
                                if (embedded.empty()) continue;
                                const float middle = top + laneHeight * (channel + .5f);
                                Path envelope;
                                for (int x = start; x < end; ++x) {
                                    const auto fraction = jlimit(0., 1., ((double)x - left) / std::max(1.f, right - left));
                                    const auto index = std::min(embedded.size() - 1, (size_t)(fraction * embedded.size()));
                                    const float y = middle - (float)std::abs(embedded[index]) * amplitude * (float)jaras::itemFadeGain(clip, t.timeAt((float)x));
                                    if (x == start) envelope.startNewSubPath((float)x, y); else envelope.lineTo((float)x, y);
                                }
                                for (int x = end - 1; x >= start; --x) {
                                    const auto fraction = jlimit(0., 1., ((double)x - left) / std::max(1.f, right - left));
                                    const auto index = std::min(embedded.size() - 1, (size_t)(fraction * embedded.size()));
                                    envelope.lineTo((float)x, middle + (float)std::abs(embedded[index]) * amplitude * (float)jaras::itemFadeGain(clip, t.timeAt((float)x)));
                                }
                                envelope.closeSubPath();
                                g.saveState();
                                g.reduceClipRegion(juce::Rectangle<float>((float)start, top + channel * laneHeight, (float)(end - start), laneHeight).getSmallestIntegerContainer());
                                g.fillPath(envelope); g.restoreState();
                            }
                        }
                    }
                    header.drawFades(g,clip);
                    g.restoreState();
                }
            }
            g.restoreState();
            stage();
            for (const auto &region : song->parts) {
                if (region.parentRegionID) continue;
                const auto colour = Colour(0xff000000 | region.color.value_or(0x705264));
                const float left = lineX(region.startTime), right = lineX(region.endTime), top = 16;
                g.saveState();
                g.reduceClipRegion(juce::Rectangle<float>(left, top, std::max(0.f, right-left), std::max(0.f, getHeight()-top)).getSmallestIntegerContainer());
                for (const auto spec : {std::pair<float,float>{6,.14f}, {3,.30f}, {2,1.f}}) {
                    g.setColour(colour.withAlpha(spec.second));
                    for (float x : {left, right}) if (x >= -6 && x <= getWidth()+6)
                        g.fillRect(x-spec.first/2, top, spec.first, getHeight()-top);
                }
                g.restoreState();
            }
            if (song->markers) for (const auto &marker : *song->markers) {
                const float x = lineX(marker.position), top = marker.tempoBPM ? 48.f : 32.f;
                if (x < 0 || x > getWidth()) continue;
                auto colour = Colour(0xff000000 | (marker.tempoBPM ? 0x999999 : marker.color));
                g.setColour(colour.withAlpha(marker.unifiedRegionID || marker.sourceRegionID ? 1.f : .45f));
                if (marker.tempoBPM) {
                    // Reuse the same 2-on/3-off pattern instead of tessellating
                    // hundreds of individual dashed paths during whole-show zoom.
                    static const Image dash=[] {Image tile(Image::ARGB,1,5,true);tile.setPixelAt(0,0,Colour(0xff999999));tile.setPixelAt(0,1,Colour(0xff999999));return tile;}();
                    g.setTiledImageFill(dash,0,(int)top,marker.unifiedRegionID || marker.sourceRegionID ? 1.f:.45f);
                    g.fillRect(x,top,pixel,getHeight()-top);
                } else g.fillRect(x, top, pixel, getHeight()-top);
            }
            stage();
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
            if (!dragClip.empty() && !timelineGrid::movementLocked(t.w.session.project())) {
                const double from=dragPreview?previewStart:originalStart;
                const double to=dragPreview?previewEnd:originalStart+clipLength;
                g.setColour(Colours::yellow);
                g.drawVerticalLine((int)std::round(t.xAt(from)),(float)ruler,(float)getHeight());
                g.drawVerticalLine((int)std::round(t.xAt(to)),(float)ruler,(float)getHeight());
            }
            if (const auto range=t.w.session.selectedTimeRange()) {
                const float left=t.xAt(range->first),right=t.xAt(range->second),top=48.f,bottom=(float)getHeight();
                g.setColour(Colours::white.withAlpha(.12f));g.fillRect(left,top,right-left,bottom-top);
                g.setColour(theme::yellow);
                Path edges;edges.startNewSubPath(left,top);edges.lineTo(left,bottom);
                edges.startNewSubPath(right,top);edges.lineTo(right,bottom);
                edges.startNewSubPath(left,top+10);edges.lineTo(right,top+10);
                const float head=std::min(12.f,(right-left)/2);
                edges.addTriangle(left,top,left+head,top,left,top+12);
                edges.addTriangle(right,top,right-head,top,right,top+12);
                g.strokePath(edges,PathStrokeType(1.f));
            }
            if (selectionBox) {
                g.setColour(Colour(0xff34c759).withAlpha(.12f));
                g.fillRect(*selectionBox);
                g.setColour(Colour(0xff34c759).withAlpha(.9f));
                g.drawRect(selectionBox->reduced(.5f),1.f);
            }
            if (dragPreview && (!dragRegion.empty() || !dragMarker.empty())) {
                g.setColour(theme::green);
                if (!dragRegion.empty()) {
                    const double delta=previewStart-originalStart;
                    const float left=t.xAt(regionEdge>0?originalStart:previewStart);
                    const float right=t.xAt(originalStart+clipLength+(regionEdge<0?0:delta));
                    g.drawRect(juce::Rectangle<float>(left,0,std::max(1.f,right-left),16),2);
                    g.drawVerticalLine((int)left,16,(float)getHeight());
                    g.drawVerticalLine((int)right,16,(float)getHeight());
                } else g.drawVerticalLine((int)t.xAt(previewStart),16,(float)getHeight());
                return;
            }
        }
        void mouseMove(const MouseEvent &e) override {
            auto cursor=MouseCursor::NormalCursor;
            if(e.y>=48 && e.y<ruler && timeRangeEdge(e.position.x)) cursor=MouseCursor::LeftRightResizeCursor;
            if (const auto *song=t.w.session.song()) {
                const int row=t.w.rowAt(e.y-ruler+t.w.verticalOffset);
                if (e.y>=ruler && row>=0 && row<(int)song->tracks.size()) {
                    const auto &track=song->tracks[(size_t)row];
                    for (const auto &clip:track.clips) if (itemRect(row,clip).contains(e.position)) {
                        const ItemHeader header(itemRect(row,clip),(float)getWidth(),track,clip);
                        if (!timelineGrid::movementLocked(t.w.session.project()) && header.hit(e.position,clip)==ItemHeader::none && header.resizeSide(e.position) &&
                            (track.role.id!="generatedClick" || clipEditing::projection(clip))) cursor=MouseCursor::LeftRightResizeCursor;
                        break;
                    }
                }
            }
            setMouseCursor(cursor);
        }
        void mouseDown(const MouseEvent &e) override {
            t.stopGesture();
            startTime = t.timeAt(e.position.x);
            startPosition = e.position;
            dragClip.clear(); dragRegion.clear(); dragMarker.clear(); regionEdge=0;
            mainDrag=false; dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset();
            resizeEdge = 0;
            controlClip.reset(); controlKind=ItemHeader::none;
            t.w.grabKeyboardFocus();
            if (e.y >= 16 && e.y < ruler) {
                if(e.mods.isPopupMenu() && e.y>=46 && e.y<=56 && std::abs(e.position.x-t.xAt(t.w.session.transport().editPosition))<=6) {
                    PopupMenu menu;menu.addItem(1,"Criar marcador");menu.addItem(2,"Criar marcador de tempo");
                    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({e.getScreenX(),e.getScreenY(),1,1}),[safe=SafePointer<Canvas>(this)](int choice){
                        if(!safe)return;const auto time=safe->t.w.session.transport().editPosition;
                        if(choice==1)safe->t.w.editMarker({},time);if(choice==2)safe->t.w.editTempoMarker({},time);
                    });return;
                }
                if (e.y>=48 && (e.mods.isPopupMenu() || timeRangeEdge(e.position.x))) {
                    timeRangeGesture=true;timeRangeDragged=false;timeRangeRight=e.mods.isPopupMenu();
                    timeRangeResize=timeRangeEdge(e.position.x);
                    timeRangeBefore=t.w.session.selectedTimeRange();
                    return;
                }
                if (const auto *song = t.w.session.song()) {
                    t.refreshMarkers(*song);
                    for (const auto &flag : t.markerFlags) {
                        const float width = std::min(flag.width, (float)((flag.next-flag.position)*t.w.pixelsPerSecond-3));
                        if (!juce::Rectangle<float>(t.xAt(flag.position),flag.tempo?33.f:17.f,std::max(8.f,width),14).contains(e.position)) continue;
                        if (e.mods.isPopupMenu()) { ++t.w.contextCount; t.w.showMarkerMenu(flag.id, e.getScreenPosition()); }
                        else if (e.mods.isAltDown()) t.w.perform([&] {
                            t.w.session.edit([&](auto &p) {auto edit=t.w.session.core;edit.deleteManualMarker(flag.id);p=edit.project();}, true, flag.tempo);
                        });
                        else { dragMarker=flag.id; originalStart=flag.position; }
                        return;
                    }
                }
                subDrag = e.mods.isPopupMenu() || e.mods.isAltDown();
                mainDrag = true;
                t.w.perform([&] { t.w.session.command(subDrag ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods, subDrag)); });
                return;
            }
            if (e.y < 16) {
                if (auto *s = t.w.session.song())
                    for (const auto &p : s->parts)
                        if (!p.parentRegionID && startTime >= p.startTime && startTime < p.endTime) {
                            if (e.mods.isPopupMenu()) {
                                ++t.w.contextCount;
                                t.w.showRegionMenu(p.id, e.getScreenPosition());
                            } else {
                                dragRegion=p.id; originalStart=p.startTime; clipLength=p.endTime-p.startTime;
                                const bool resize=!regionEditing::hasChildren(*s,p.id);
                                regionEdge=resize && std::abs(e.position.x-t.xAt(p.startTime))<10 ? -1
                                    : resize && std::abs(e.position.x-t.xAt(p.endTime))<10 ? 1 : 0;
                            }
                            return;
                        }
                return;
            }
            if (e.mods.isPopupMenu()) {
                rightSelection = true;
                selectionBox.reset();
                additiveSelection = e.mods.isCtrlDown() || e.mods.isShiftDown();
                selectionBase = additiveSelection ? t.w.selectedClips : std::set<ID>{};
                if (additiveSelection && !t.w.selectedClip.empty()) selectionBase.insert(t.w.selectedClip);
                selectionSong = t.w.session.song() ? t.w.session.song()->id : ID{};
                return;
            }
            int row = t.w.rowAt(e.y - ruler + t.w.verticalOffset);
            if (auto *s = t.w.session.song())
                if (row >= 0 && row < (int)s->tracks.size()) {
                    auto &track = s->tracks[(size_t)row];
                    t.w.selectMixerTrack(track.id, e.mods, false);
                    t.invalidate();
                    for (const auto &c : track.clips)
                        if (itemRect(row,c).contains(e.position)) {
                            {
                                if (e.mods.isCtrlDown() || e.mods.isShiftDown()) {
                                    if (t.w.selectedClips.empty() && !t.w.selectedClip.empty()) t.w.selectedClips.insert(t.w.selectedClip);
                                    if (!t.w.selectedClips.erase(c.id)) t.w.selectedClips.insert(c.id);
                                } else t.w.selectedClips = {c.id};
                            }
                            t.w.selectedClip = t.w.selectedClips.count(c.id) ? c.id : t.w.selectedClips.empty() ? ID{} : *t.w.selectedClips.begin();
                            if (const auto control=ItemHeader(itemRect(row,c),(float)getWidth(),track,c).hit(e.position,c); control!=ItemHeader::none) {
                                controlKind=control;
                                controlClip=c;
                                controlOriginal=c;
                                controlTrack=track.id;
                                controlRow=row;
                            } else {
                                if (!e.mods.isCtrlDown() && !e.mods.isShiftDown())
                                    t.w.perform([&] { t.w.session.command(e.mods.isAltDown() ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek, {}, pointerPosition(startTime,e.mods,e.mods.isAltDown())); });
                                dragClip = c.id;
                                originalStart = c.startTime;
                                clipLength = c.duration;
                                sourceRow = row;
                                resizeEdge = track.role.id == "generatedClick" && !clipEditing::projection(c) ? 0
                                    : ItemHeader(itemRect(row,c),(float)getWidth(),track,c).resizeSide(e.position);
                            }
                            t.invalidate();
                            return;
                        }
                }
            if (!e.mods.isPopupMenu() && !e.mods.isCtrlDown())
                t.w.perform([&] { t.w.session.command(e.mods.isAltDown() ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek, {}, pointerPosition(startTime,e.mods,e.mods.isAltDown())); });
            t.w.clearItemSelection();
        }

        void mouseDrag(const MouseEvent &e) override {
            if (timeRangeGesture) { updateTimeRange(e); return; }
            if (rightSelection) { updateAreaSelection(e); return; }
            if (timelineGrid::movementLocked(t.w.session.project()) &&
                (!dragClip.empty() || !dragRegion.empty() || !dragMarker.empty())) {
                dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset();
                setMouseCursor(MouseCursor::NormalCursor); repaint(); return;
            }
            if (!dragRegion.empty() || !dragMarker.empty()) {
                if (e.getDistanceFromDragStart() >= 3) {
                    previewStart=std::max(0., originalStart+(e.position.x-startPosition.x)/t.w.pixelsPerSecond);
                    dragPreview=true; setMouseCursor(MouseCursor::DraggingHandCursor); repaint();
                }
                return;
            }
            if (controlClip) {
                if(controlKind==ItemHeader::mute || controlKind==ItemHeader::phase || controlKind==ItemHeader::fx) return;
                const double delta=e.position.y-startPosition.y;
                if (controlKind==ItemHeader::pan) controlClip->pan=jlimit(-1.,1.,controlOriginal.pan.value_or(0)-delta/60.);
                if (controlKind==ItemHeader::gain) {
                    const double pos=jlimit(0.,1.,(20*std::log10(std::max(.000001,controlOriginal.gain.value_or(1)))+60)/84-delta/120);
                    controlClip->gain=pos==0 ? 0 : std::pow(10.,(pos*84-60)/20);
                }
                const double dx=(e.position.x-startPosition.x)/t.w.pixelsPerSecond;
                if (controlKind==ItemHeader::fadeIn) controlClip->fadeIn=jlimit(0.,controlClip->duration,controlOriginal.fadeIn.value_or(0)+dx);
                if (controlKind==ItemHeader::fadeOut) controlClip->fadeOut=jlimit(0.,controlClip->duration,controlOriginal.fadeOut.value_or(0)-dx);
                if (ItemHeader::isShape(controlKind)) {
                    const bool left = ItemHeader::shapeIn(controlKind), s = ItemHeader::shapeS(controlKind);
                    const double width = std::max(26., t.w.pixelsPerSecond * (left ? controlOriginal.fadeIn : controlOriginal.fadeOut).value_or(0));
                    ItemHeader::shapeValue(*controlClip,controlKind) = jlimit(-1.,1.,ItemHeader::shapeValue(controlOriginal,controlKind).value_or(s ? 1 : 0) + (e.position.x-startPosition.x)*(left ? 1 : -1)*2/width);
                }
                if(!t.w.session.busy) t.w.perform([&] {previewControl(*controlClip);});
                repaint(); return;
            }
            if (mainDrag) {
                t.w.perform([&] {
                    t.w.session.command(subDrag ? jaras::CommandKind::subSeek
                                                : jaras::CommandKind::editSeek,
                                        {}, pointerPosition(t.timeAt(e.position.x),e.mods,subDrag));
                });
            } else if (!dragClip.empty() && e.getDistanceFromDragStart() > 4) {
                updateDrag(e);
                setMouseCursor(resizeEdge ? MouseCursor::LeftRightResizeCursor
                                          : MouseCursor::DraggingHandCursor);
                repaint();
            }
        }
        void mouseUp(const MouseEvent &e) override {
            if (timeRangeGesture) {
                updateTimeRange(e);timeRangeGesture=false;
                if(!timeRangeDragged && timeRangeRight) t.w.perform([&]{t.w.session.command(jaras::CommandKind::subSeek,{},startTime);});
                timeRangeBefore.reset();timeRangeResize=0;setMouseCursor(MouseCursor::NormalCursor);t.invalidate();return;
            }
            if (rightSelection) {
                updateAreaSelection(e);
                rightSelection = false;
                const bool dragged = selectionBox.has_value();
                selectionBox.reset(); repaint();
                if (!dragged && t.w.session.song() && t.w.session.song()->id == selectionSong) showItemContext(e);
                selectionBase.clear();
                return;
            }
            if (timelineGrid::movementLocked(t.w.session.project()) &&
                (!dragClip.empty() || !dragRegion.empty() || !dragMarker.empty())) {
                if (e.getDistanceFromDragStart() < 3) t.w.perform([&] {
                    if (!dragRegion.empty()) t.w.session.command(t.w.session.transport().playing ? jaras::CommandKind::queueRegion : jaras::CommandKind::selectRegion, dragRegion);
                    else if (!dragMarker.empty()) t.w.session.command(jaras::CommandKind::editSeek, {}, originalStart);
                });
                dragClip.clear(); dragRegion.clear(); dragMarker.clear();
                dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); resizeEdge = 0; regionEdge = 0;
                setMouseCursor(MouseCursor::NormalCursor); t.invalidate(); return;
            }
            if (!dragRegion.empty() || !dragMarker.empty()) {
                const auto region=dragRegion, marker=dragMarker;
                if (e.getDistanceFromDragStart() >= 3) t.w.perform([&] {
                    const double delta=(e.position.x-startPosition.x)/t.w.pixelsPerSecond;
                    t.w.session.edit([&](auto &p) {
                        auto edit=t.w.session.core;
                        if (!region.empty()) {
                            if (regionEdge) edit.resizeRegion(region, regionEdge<0?std::max(0.,std::min(originalStart+clipLength-.01,originalStart+delta)):originalStart,
                                regionEdge>0?std::max(originalStart+.01,originalStart+clipLength+delta):originalStart+clipLength);
                            else edit.moveRegion(region,std::max(0.,originalStart+delta));
                        } else if (edit.currentSong() && edit.currentSong()->markers) {
                            for (const auto &m:*edit.currentSong()->markers) if (m.id==marker) {
                                const auto next=m;
                                edit.setMarker(next.id,next.name,std::max(0.,next.position+delta),next.color,next.tempoBPM,next.tempoBeats,next.tempoUnit,next.tempoTimebase,next.section,next.loopSection);break;
                            }
                        }
                        p=edit.project();
                    });
                });
                else t.w.perform([&] {
                    if (!region.empty()) t.w.session.command(t.w.session.transport().playing?jaras::CommandKind::queueRegion:jaras::CommandKind::selectRegion,region);
                    else t.w.session.command(jaras::CommandKind::editSeek,{},originalStart);
                });
                dragRegion.clear();dragMarker.clear();dragPreview=false;setMouseCursor(MouseCursor::NormalCursor);t.invalidate();return;
            }
            if (controlClip) {
                const auto kind=controlKind;
                if(kind==ItemHeader::mute || kind==ItemHeader::phase || kind==ItemHeader::fx) {
                    const auto *song=t.w.session.song();
                    const bool activate=song && controlRow>=0 && controlRow<(int)song->tracks.size() &&
                        song->tracks[(size_t)controlRow].id==controlTrack && e.getDistanceFromDragStart()<3 &&
                        ItemHeader(itemRect(controlRow,*controlClip),(float)getWidth(),song->tracks[(size_t)controlRow],*controlClip).hit(e.position,*controlClip)==kind;
                    if(activate) {
                        if(kind==ItemHeader::fx && !e.mods.isAltDown()) {const auto id=controlClip->id; controlClip.reset();controlKind=ItemHeader::none;t.w.openItemFX(id);return;}
                        if(kind==ItemHeader::mute) controlClip->muted=!controlClip->muted;
                        if(kind==ItemHeader::phase) controlClip->phaseInverted=!controlClip->phaseInverted.value_or(false);
                        if(kind==ItemHeader::fx) controlClip->fxBypassed=!controlClip->fxBypassed.value_or(false);
                        commitControl();
                    }
                } else if(e.getDistanceFromDragStart()>0) commitControl();
                controlClip.reset();controlKind=ItemHeader::none;repaint();return;
            }
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
            dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset();
            repaint();
        }
        void mouseDoubleClick(const MouseEvent &e) override {
            if (const auto *song=t.w.session.song()) {
                const int row=t.w.rowAt(e.y-ruler+t.w.verticalOffset);
                if (row>=0 && row<(int)song->tracks.size()) for (const auto &clip:song->tracks[(size_t)row].clips) {
                    const auto hit=ItemHeader(itemRect(row,clip),(float)getWidth(),song->tracks[(size_t)row],clip).hit(e.position,clip);
                    if (hit==ItemHeader::gain || hit==ItemHeader::pan || hit==ItemHeader::fadeIn || hit==ItemHeader::fadeOut || ItemHeader::isShape(hit)) {
                        controlClip=clip; controlOriginal=clip; controlKind=hit;
                        if (hit==ItemHeader::gain) controlClip->gain=1;
                        if (hit==ItemHeader::pan) controlClip->pan=0;
                        if (hit==ItemHeader::fadeIn) controlClip->fadeIn=0;
                        if (hit==ItemHeader::fadeOut) controlClip->fadeOut=0;
                        if (ItemHeader::isShape(hit)) ItemHeader::shapeValue(*controlClip,hit) = ItemHeader::shapeS(hit) ? 1 : 0;
                        commitControl(); return;
                    }
                }
            }
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
        void cancelDrag() {
            timeRangeGesture=false;timeRangeDragged=false;timeRangeResize=0;timeRangeBefore.reset();
            rightSelection = false; selectionBox.reset(); selectionBase.clear();
            dragRegion.clear(); dragMarker.clear();
            if(controlClip) t.w.perform([&]{previewControl(controlOriginal);});
            controlClip.reset();controlKind=ItemHeader::none;
            dragClip.clear(); dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); mainDrag = subDrag = false; setMouseCursor(MouseCursor::NormalCursor); repaint();
        }

      private:
        Timeline &t;
        bool timeRangeGesture=false,timeRangeDragged=false,timeRangeRight=false;
        int timeRangeResize=0;
        std::optional<std::pair<double,double>> timeRangeBefore;
        int timeRangeEdge(float x) const {
            const auto range=t.w.session.selectedTimeRange();if(!range)return 0;
            const auto left=std::abs(x-t.xAt(range->first)),right=std::abs(x-t.xAt(range->second));
            return std::min(left,right)<=8 ? (left<=right?-1:1) : 0;
        }
        void updateTimeRange(const MouseEvent &e) {
            if(!timeRangeDragged && e.position.getDistanceFrom(startPosition)<3)return;
            const auto *song=t.w.session.song();if(!song)return;
            timeRangeDragged=true;
            auto snap=[&](double value){return timelineGrid::snapSelection(value,*song,t.w.pixelsPerSecond,t.w.session.transport(),e.mods.isShiftDown());};
            double from=snap(startTime),to=snap(t.timeAt(e.position.x));
            if(timeRangeBefore && timeRangeResize) {
                if(timeRangeResize<0){from=std::min(to,timeRangeBefore->second-.001);to=timeRangeBefore->second;}
                else {from=timeRangeBefore->first;to=std::max(from+.001,to);}
            }
            t.w.perform([&]{t.w.session.selectTimeRange(from,to);});
            setMouseCursor(MouseCursor::LeftRightResizeCursor);t.invalidate();
        }
        bool rightSelection = false, additiveSelection = false;
        ID selectionSong;
        std::set<ID> selectionBase;
        std::optional<juce::Rectangle<float>> selectionBox;
        void updateAreaSelection(const MouseEvent &e) {
            const auto *song = t.w.session.song();
            if (!song || song->id != selectionSong) return;
            if (!selectionBox && e.position.getDistanceFrom(startPosition) < 3.f) return;
            const float top = std::max((float)ruler,std::min(startPosition.y,e.position.y));
            selectionBox = juce::Rectangle<float>(std::min(startPosition.x,e.position.x),top,
                std::max(1.f,std::abs(e.position.x-startPosition.x)),std::max(1.f,std::max(startPosition.y,e.position.y)-top));
            auto selected = selectionBase;
            for (int row=0; row<(int)song->tracks.size(); ++row) {
                if (t.w.rowHidden(row)) continue;
                for (const auto &clip:song->tracks[(size_t)row].clips)
                    if (selectionBox->intersects(itemRect(row,clip))) selected.insert(clip.id);
            }
            t.w.selectedClips = std::move(selected);
            t.w.selectedClip = t.w.selectedClips.empty() ? ID{} : *t.w.selectedClips.begin();
            repaint();
        }
        void showItemContext(const MouseEvent &e) {
            const auto *song=t.w.session.song(); if(!song)return;
            const int row=t.w.rowAt(startPosition.y-ruler+t.w.verticalOffset);
            if(row<0 || row>=(int)song->tracks.size()) {
                if(!additiveSelection)t.w.clearItemSelection();
                return;
            }
            const auto &track=song->tracks[(size_t)row];
            for(const auto &clip:track.clips) if(itemRect(row,clip).contains(startPosition)) {
                if(!t.w.clipSelected(clip.id))t.w.selectedClips={clip.id};
                t.w.selectedClip=clip.id;
                ++t.w.contextCount;t.w.showClipMenu(clip.id,e.getScreenPosition());repaint();return;
            }
            if(!additiveSelection)t.w.clearItemSelection();
            if(!jaras::fixedTrackName(track.role).empty() || track.role.id=="group")return;
            PopupMenu menu;menu.addItem(1,"Criar item MIDI");
            menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this).withTargetScreenArea({e.getScreenX(),e.getScreenY(),1,1}),
                [safe=SafePointer<Canvas>(this),time=startTime,trackID=track.id,songID=song->id](int action) {
                    if(safe && action==1 && safe->t.w.session.song() && safe->t.w.session.song()->id==songID)
                        safe->t.w.addMIDIItem(trackID,time);
                });
        }
        std::optional<jaras::AudioClip> controlClip, resizedClipPreview, movingClipPreview;
        jaras::AudioClip controlOriginal;
        ID controlTrack; int controlRow=-1;
        ItemHeader::Control controlKind=ItemHeader::none;
        juce::Rectangle<float> itemRect(int row, const jaras::AudioClip &clip) const {
            const int h=t.w.itemLaneHeight(row);
            return {t.xAt(clip.startTime), (float)(ruler+t.w.rowTop(row)-t.w.verticalOffset+t.w.itemLanes(row).lane(clip.id)*h+3),
                    std::max(2.f,(float)(clip.duration*t.w.pixelsPerSecond)-2), (float)h-6};
        }
        void previewControl(const jaras::AudioClip &clip) {
            if(clip.midi){if(const auto *song=t.w.session.song())t.w.session.audio.previewMIDIItem(*song,clip);}
            else t.w.session.audio.setItemControls(clip);
        }
        void commitControl() {
            if (!controlClip) return;
            const auto value=*controlClip;
            controlClip.reset(); controlKind=ItemHeader::none;
            bool committed=false;
            t.w.perform([&] { t.w.session.edit([&](jaras::Project &project) {
                for(auto &song:project.songs) for(auto &track:song.tracks) for(auto &clip:track.clips) if(clip.id==value.id) {
                    clip.gain=value.gain; clip.pan=value.pan; clip.phaseInverted=value.phaseInverted; clip.muted=value.muted;
                    clip.fadeIn=value.fadeIn; clip.fadeOut=value.fadeOut; clip.fxBypassed=value.fxBypassed;
                    clip.fadeInCurve=value.fadeInCurve; clip.fadeInSCurve=value.fadeInSCurve; clip.fadeOutCurve=value.fadeOutCurve; clip.fadeOutSCurve=value.fadeOutSCurve;
                }
            },false); previewControl(value); committed=true; });
            if(!committed) t.w.perform([&]{previewControl(controlOriginal);});
        }
        double startTime = 0, originalStart = 0, clipLength = 0;
        Point<float> startPosition;
        ID dragClip, dragRegion, dragMarker;
        int regionEdge=0;
        bool mainDrag = false, subDrag = false;
        int sourceRow = 0;
        bool dragPreview = false;
        int resizeEdge = 0, previewRow = 0, previewLane = 0;
        double previewStart = 0, previewEnd = 0;
        double pointerPosition(double time, ModifierKeys modifiers, bool subplay) const {
            const auto *song=t.w.session.song();
            return !subplay && song ? timelineGrid::snapCursor(time,*song,t.w.pixelsPerSecond,modifiers.isShiftDown()) : time;
        }
        void updateDrag(const MouseEvent &e) {
            double edge = (resizeEdge > 0 ? originalStart + clipLength : originalStart) +
                          t.timeAt(e.position.x) - startTime;
            edge = std::max(0., edge);
            if (const auto *song = t.w.session.song())
                edge = timelineGrid::snapSelection(edge,*song,t.w.pixelsPerSecond,
                                                   t.w.session.transport(),e.mods.isShiftDown());
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
            if(const auto *song=t.w.session.song(); song && sourceRow>=0 && sourceRow<(int)song->tracks.size()) {
                const auto &source=song->tracks[(size_t)sourceRow];
                const auto at=std::find_if(source.clips.begin(),source.clips.end(),[&](const auto &c){return c.id==dragClip;});
                if(at!=source.clips.end()) {
                    const auto &target=song->tracks[(size_t)previewRow];
                    if(resizeEdge) std::tie(previewStart,previewEnd)=clipEditing::constrainedEdges(target,*at,previewStart,previewEnd);
                    else {previewStart=clipEditing::constrainedStart(target,*at,previewStart);previewEnd=previewStart+clipLength;}
                    auto layoutTrack=target;
                    layoutTrack.clips.erase(std::remove_if(layoutTrack.clips.begin(),layoutTrack.clips.end(),[&](const auto &c){return c.id==dragClip;}),layoutTrack.clips.end());
                    auto moved=*at;
                    if (resizeEdge) {
                        if (source.role.id == "timecode" && !clipEditing::projection(moved)) {
                            moved.startTime=previewStart; moved.duration=previewEnd-previewStart;
                        } else moved=clipEditing::resizedSource(moved,previewStart,previewEnd);
                        resizedClipPreview=moved;
                    } else {
                        moved.startTime=previewStart; moved.duration=previewEnd-previewStart;
                        movingClipPreview=moved;
                    }
                    layoutTrack.clips.push_back(moved);
                    previewLane=ItemLanes(layoutTrack).lane(dragClip);
                }
            }
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
                g.setColour(colour.withMultipliedAlpha(.12f));
                g.fillRect(x - 3, y + 9.f, 6.f, std::max(0.f, getHeight() - y - 9.f));
                g.setColour(colour);
                g.fillRect(x - .7f, y + 9.f, 1.4f, std::max(0.f, getHeight() - y - 9.f));
                Path p;
                p.addTriangle(x - 5, (float)y, x + 5, (float)y, x, y + 9.f);
                g.fillPath(p);
            };
            head(state.editPosition, t.w.appearance.colour("jaras.timeline.editCursor", 0xb9e229),
                 46);
            if (state.playing || state.paused)
                head(state.position, t.w.appearance.colour("jaras.timeline.playCursor", 0x7548dd),
                     46);
            if (t.w.session.subCursorVisible()) {
                head(state.subPlay.position,
                     t.w.appearance.colour("jaras.timeline.subPlayCursor", 0xff6f00).withMultipliedAlpha(
                         Session::subCursorOpacity(Time::getMillisecondCounterHiRes() / 1000)), 46);
            }
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
    b->getProperties().set("cornerRadius", 6.f);
    b->setWantsKeyboardFocus(false);
    b->setColour(TextButton::buttonColourId, colour.isTransparent() ? theme::panel : colour);
    b->onClick = [this, action] { perform(action); };
    return *b;
}
class Workspace::TrackHeightHandle final : public Component {
    Workspace &w;
    ID trackID, songID; int startY=0, direction=1, count=1; double startHeight=0, denominator=1, initialScale=1;
    std::optional<std::pair<int,int>> edge(int x,int y) const {
        if(!w.session.song() || !w.projectReady || w.browserVisible) return {};
        auto p=getParentComponent()->getLocalPoint(this,Point<int>{x,y});
        if(p.x>=w.mixerDivider.getX() && p.x<w.mixerDivider.getRight()) return {};
        const int local=y+w.tracksViewport.getViewPositionY();
        for(int i=0;i<w.rows.size();++i) if(!w.rowHidden(i)) {
            int top=w.rowTop(i),bottom=top+w.rowBodyHeight(i);
            if(local>=top && local<top+3)return std::pair<int,int>{i,-1};
            if(local>=bottom-3 && local<bottom)return std::pair<int,int>{i,1};
        }
        return {};
    }
  public:
    explicit TrackHeightHandle(Workspace &owner):w(owner){setComponentID("trackHeightHandle");setMouseCursor(MouseCursor::UpDownResizeCursor);setWantsKeyboardFocus(true);}
    bool hitTest(int x,int y) override {auto m=ModifierKeys::getCurrentModifiers();return !m.isAnyModifierKeyDown() && edge(x,y).has_value();}
    void mouseDown(const MouseEvent &e) override {
        if(!e.mods.isLeftButtonDown() || e.mods.isAnyModifierKeyDown())return;
        if(auto at=edge(e.x,e.y)) {int i=at->first;const auto &track=w.session.song()->tracks[(size_t)i];
            trackID=track.id;songID=w.session.song()->id;direction=at->second;startY=e.y;count=w.itemLanes(i).count;
            startHeight=w.rowBodyHeight(i);denominator=w.trackHeight*(count>1?.7:1.);initialScale=track.heightScale.value_or(1.);
            w.trackHeightPreview=std::pair<ID,double>{trackID,initialScale};grabKeyboardFocus();
        }
    }
    void mouseDrag(const MouseEvent &e) override {
        if(trackID.empty())return;
        if(!w.session.song() || w.session.song()->id!=songID){cancel();return;}
        double lane=jlimit(count>1?26.:24.,count>1?168.:240.,std::round((startHeight+(e.y-startY)*direction)/count));
        w.trackHeightPreview=std::pair<ID,double>{trackID,jlimit(.1,10.,lane/denominator)};w.resized();w.timeline->updateRanges();w.repaint();
    }
    void mouseUp(const MouseEvent &e) override {
        if(trackID.empty())return;mouseDrag(e);if(!w.trackHeightPreview)return;
        const auto value=*w.trackHeightPreview;const auto song=songID;bool changed=std::abs(value.second-initialScale)>1e-8;
        trackID.clear();w.trackHeightPreview.reset();
        if(changed)w.perform([&]{w.session.edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==song)for(auto &t:s.tracks)if(t.id==value.first)t.heightScale=value.second;},false);});
        w.resized();w.timeline->updateRanges();w.repaint();w.grabKeyboardFocus();
    }
    void cancel(){trackID.clear();w.trackHeightPreview.reset();w.resized();w.timeline->updateRanges();w.repaint();}
    bool keyPressed(const KeyPress &key) override {if(key.getKeyCode()==KeyPress::escapeKey && !trackID.empty()){cancel();w.grabKeyboardFocus();return true;}return false;}
    void mouseWheelMove(const MouseEvent &e,const MouseWheelDetails &wheel) override {w.mouseWheelMove(e,wheel);}
};

void Workspace::paintOverChildren(Graphics &g) {
    if(externalDropPoint&&session.song()) {
        const auto local=timeline->getLocalPoint(this,*externalDropPoint);
        if(timeline->getLocalBounds().contains(local)&&local.y>=64){
            const auto at=timelineGrid::snapSelection(timeline->timeAt((float)local.x),*session.song(),pixelsPerSecond,session.transport(),ModifierKeys::getCurrentModifiers().isShiftDown());
            const int x=timeline->getX()+roundToInt(timeline->xAt(at));
            Graphics::ScopedSaveState save(g);g.reduceClipRegion(timeline->getBounds().withTrimmedTop(64));g.setColour(theme::yellow);g.fillRect(x,timeline->getY()+64,2,timeline->getHeight()-64);
        }
    }
    auto boundsFor=[&](const ID &id)->juce::Rectangle<int>{if(const auto *song=session.song()){auto i=trackTree::index(*song,id);if(i<(size_t)rows.size())return getLocalArea(rows[(int)i],rows[(int)i]->getLocalBounds());}return {};};
    Graphics::ScopedSaveState saved(g);g.reduceClipRegion(tracksViewport.getBounds());
    if(trackDropPreview){auto r=boundsFor(trackDropPreview->indicator);g.setColour(trackDropPreview->joins?theme::yellow:theme::green);g.fillRect(r.getX(),trackDropPreview->after?r.getBottom()-2:r.getY(),r.getWidth(),2);}
    if(!trackDropBlocked.empty()){auto r=boundsFor(trackDropBlocked);g.setColour(Colours::red);g.drawRect(r.reduced(2),2);g.setFont(theme::font(11));g.drawText("Destino indisponível",r,Justification::centred);}
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
        if (projectReady && !loginPanel && !browserVisible) {
            ++actionInvocations[id];
            perform([&] { performAction(id, value, track); });
        }
    };
    setOpaque(true);
    setWantsKeyboardFocus(true);
    setFocusContainerType(FocusContainerType::keyboardFocusContainer);
    caption = std::make_unique<Caption>(*this);
    timeline = std::make_unique<Timeline>(*this);
    trackHeightHandle=std::make_unique<TrackHeightHandle>(*this);addAndMakeVisible(*trackHeightHandle);
    setlist = std::make_unique<Setlist>(*this);
    addAndMakeVisible(*caption);
    addAndMakeVisible(*timeline);
    addAndMakeVisible(*setlist);
    stageTimer = std::make_unique<StageTimerControl>(stage, [this] { openTimer(true); });
    addAndMakeVisible(*stageTimer);
    tempoControl =
        std::make_unique<TempoControl>(session, [this](String error) { showError(error); },
            [this] { perform([&] { performAction("tapTempo", 1, 0); }); },
            [this](String action) {
                auto page = std::make_unique<ActionsPage>(actions);
                page->showAction(action);
                ModalSheet::open(*this, "Mapear controle", std::move(page), 430, 280);
            });
    addAndMakeVisible(*tempoControl);
    footerMixer = std::make_unique<MixerPanel>(
        session, [this](ID id) { openFX(id); },
        [this](ID id, ModifierKeys mods) { selectMixerTrack(id, mods); },
        [this](String error) { showError(error); },
        [this](ID id, bool remove) { changeMixerFX(id, remove); },
        [this](ID id) { return trackSelected(id); }, [this](ID id,Point<int> point){showTrackMenu(id,point);},[this](ID id,String action){specialTrackAction(id,action);});
    addAndMakeVisible(dockViewport);
    dockViewport.setViewedComponent(&dockContent, false);
    dockViewport.setScrollBarsShown(true, false);
    dockViewport.setScrollBarThickness(10);
    dockViewport.setScrollOnDragMode(Viewport::ScrollOnDragMode::never);
    dockContent.addChildComponent(*footerMixer);
    partsPanel =
        std::make_unique<PartsPanel>(session, [this](String message) { showError(message); });
    dockContent.addChildComponent(*partsPanel);
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
    keyboard = std::make_unique<FooterKeyboard>(session.audio.keyboardState, appearance);
    dockContent.addAndMakeVisible(*keyboard);
    keyboard->setVisible(false);
    tracksViewport.setViewedComponent(&tracksContent, false);
    tracksViewport.setScrollBarsShown(true, false);
    tracksViewport.setScrollBarThickness(8);
    tracksViewport.setScrollOnDragMode(Viewport::ScrollOnDragMode::never);
    tracksViewport.addMouseListener(this, true);
    for (auto *slider : std::initializer_list<Slider *>{&masterVolume, &masterPan, &zoom}) {
        addAndMakeVisible(*slider);
        slider->setSliderStyle(Slider::LinearHorizontal);
        slider->setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
    }
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
    zoom.setRange(timelineGrid::minimumZoom, timelineGrid::maximumZoom);
    zoom.setSkewFactorFromMidPoint(5);
    zoom.setValue(pixelsPerSecond, dontSendNotification);
    zoom.setTooltip(String::fromUTF8("Zoom: rolagem · Altura das pistas: Ctrl+rolagem · Deslocar: Shift+rolagem"));
    zoom.onValueChange = [this] { timeline->zoomOnCursor(zoom.getValue()); };
    button("zoomOut", String::fromUTF8("−"), [this] { timeline->zoomOnCursor(pixelsPerSecond / 1.3); })
        .setTooltip("Diminuir zoom (-)");
    button("zoomIn", "+", [this] { timeline->zoomOnCursor(pixelsPerSecond * 1.3); })
        .setTooltip("Aumentar zoom (+)");
    button("zoomFit", "Ajustar", [this] { timeline->fit(); }).setTooltip("Mostrar o projeto inteiro");
    for (auto *label : std::initializer_list<Label *>{&songDisplay, &transportTime, &transportInfo, &footer, &tempo}) {
        addAndMakeVisible(*label);
        label->setFont(theme::font(11));
    }
    transportInfo.setJustificationType(Justification::centred);
    transportInfo.setFont(theme::semiboldFont(10));
    transportInfo.setColour(Label::backgroundColourId, theme::display);
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
        "play", "Play",
        [this] {
            session.command(session.transport().playing ? jaras::CommandKind::stop
                                                        : jaras::CommandKind::play);
        },
        theme::green.withAlpha(.45f))
        .setTooltip(String::fromUTF8("Play / Stop · Espaço"));
    static_cast<QuietButton &>(*controls["play"]).context = [this](Point<int>) { openTransportFadeout(); };
    button("pause", String::fromUTF8("Ⅱ"), [this] {
        session.command(jaras::CommandKind::pause);
    }).setTooltip(String::fromUTF8("Pause · P"));
    button(
        "subplay", "Sub Play",
        [this] {
            session.command(session.transport().subPlay.playing ? jaras::CommandKind::subStop
                                                                : jaras::CommandKind::subPlay);
        },
        theme::yellow.withAlpha(.45f))
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
    button("grandma2", "grandMA2", [this] { openGrandMA2(); });
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
    auto &audioStatus = button("audioStatus", "", [this] { openAudioSettings(); });
    audioStatus.getProperties().set("plain", true);
    audioStatus.setColour(TextButton::buttonColourId, Colours::transparentBlack);
    audioStatus.setMouseCursor(MouseCursor::PointingHandCursor);
    audioStatus.setTitle(String::fromUTF8("Configurações de áudio"));
    audioStatus.setTooltip(String::fromUTF8("Abrir Configurações · Áudio"));
    button("save", "Save", [this] {
        chooseSave();
    }).setTooltip(String::fromUTF8("Salvar · Ctrl+S"));
    static_cast<QuietButton &>(*controls["save"]).context = [this](Point<int>) {
        if (!projectReady || session.busy || session.audio.isRecording()) return;
        auto safe = SafePointer<Workspace>(this);
        showPanel("Exportar projeto CatLive", std::make_unique<PortableExportPanel>(session,
            [safe](std::function<void()> saved) { if (safe) safe->chooseSave(false, std::move(saved)); }), 540, 376);
    };
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
    fxchain::bind(static_cast<QuietButton &>(*controls["masterFX"]), session, {},
                  [this](bool remove) { changeMixerFX({}, remove); });
    button(
        "record", String::fromUTF8("● REC"), [this] { session.toggleRecording(); },
        Colour(0xff5f3030));
    navigation = std::make_unique<NavigationPanel>([this] { showProjectBrowser(); }, [this] {
        navigation->setVisible(false);
        grabKeyboardFocus();
    });
    addChildComponent(*navigation);
    button("menu", String::fromUTF8("☰"), [this] {
        navigation->setVisible(!navigation->isVisible());
        if (navigation->isVisible()) navigation->toFront(false);
    }).setTooltip("Menu");
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
        if (mixerDetached) {
            auto found = floatingWindows.find("Mixer");
            if (found != floatingWindows.end() && found->second->isVisible()) found->second->setVisible(false);
            else showDetachedMixer();
            return;
        }
        footerMixerVisible = !footerMixerVisible;
        resized();
        repaint();
    }).setTooltip("Barra Mixer");
    static_cast<QuietButton *>(controls["railMixer"])->context = [this](Point<int> point) { mixerMenu(point); };
    button("railSections", String::fromUTF8("¶"), [this] { openRegions(); }).setTooltip("Pads");
    button("railKeyboard", String::fromUTF8("♮"), [this] {
        keyboardVisible = !keyboardVisible;
        resized();
        repaint();
    }).setTooltip("Teclado");
    button("soundfont", "SF2", [this] { chooseSoundFont(); });
    button("video", "Video", [this] { openVideo(); });
    static_cast<QuietButton &>(*controls["video"]).context=[safe=SafePointer<Workspace>(this)](Point<int> point){
        PopupMenu menu;
        menu.addItem(1,"Stretch",true,Projection::videoStretchEnabled());
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe](int choice){
            if(!safe||choice!=1)return;
            Projection::setVideoStretchEnabled(!Projection::videoStretchEnabled());
            auto found=safe->floatingWindows.find("Video");
            if(found!=safe->floatingWindows.end())
                if(auto *projection=dynamic_cast<Projection*>(found->second->getContentComponent()))
                    projection->refreshVideoAppearance();
        });
    };
    button("railTeleprompt", "T", [this] { showTeleprompter(); }).setTooltip("Teleprompter");
    button("tp1", "TP-1", [this] { showTeleprompter(1); }, Colour(0xffc44848));
    button("tp2", "TP-2", [this] { showTeleprompter(2); }, Colour(0xffc44848));
    button("notices", "Recados", [this] { openNotices(); }, Colour(0xff897934));
    for(int i=0;i<2;++i) {
        teleprompterHTTP[(size_t)i]=std::make_unique<TeleprompterHTTP>();
        static_cast<QuietButton &>(*controls[i?"tp2":"tp1"]).context=[safe=SafePointer<Workspace>(this),i](Point<int> point){
            PopupMenu menu;menu.addItem(1,String::fromUTF8("Configurações"));menu.addItem(2,"TP Remoto");
            menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe,i](int choice){
                if(!safe)return;if(choice==1)safe->openStageConfig(i+1);if(choice==2)safe->openTPRemote(i+1);
            });
        };
    }
    auto &previewButton=button("preview", "Preview", [this] { stage.preview = !stage.preview; }, Colour(0xffc44545));
    static_cast<QuietButton &>(previewButton).context=[safe=SafePointer<Workspace>(this)](Point<int> point){
        if(!safe)return;
        PopupMenu menu;for(int i=0;i<6;++i)menu.addItem(i+1,"Blocos "+String(i*4+1)+String::fromUTF8("–")+String(i*4+4),true,safe->stage.previewPage==i);
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe](int choice){if(safe&&choice>0)safe->stage.previewPage=choice-1;});
    };
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
    controls["video"]->setColour(TextButton::buttonColourId, Colour(0xffc44545));
    for(auto id:{"tp1","tp2","preview"})controls[id]->setColour(TextButton::buttonColourId,Colour(0xffc44545));
    controls["loop"]->setColour(TextButton::buttonColourId, Colours::red.withAlpha(.45f));
    controls["loop"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["subplay"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    for (auto id : {"play", "pause", "subplay"}) {
        const auto colour = String(id) == "play" ? theme::green : String(id) == "subplay" ? theme::yellow : theme::panel;
        controls[id]->getProperties().set("transportColour", (int64)colour.getARGB());
    }
    controls["masterMute"]->setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
    controls["masterSolo"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["metronome"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["metronome"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["remote"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["record"]->setColour(TextButton::textColourOffId, theme::secondary);
    controls["record"]->setColour(TextButton::buttonColourId, Colours::red.withAlpha(.45f));
    controls["record"]->setButtonText("REC");
    for (auto spec : std::initializer_list<std::pair<const char *, const char *>>{
             {"play", "play"}, {"subplay", "play"}, {"record", "record"},
             {"tp1", "teleprompter"}, {"tp2", "teleprompter"}, {"notices", "notice"},
             {"video", "video"}, {"remote", "remote"}, {"save", "save"}}) {
        controls[spec.first]->getProperties().set("leadingIcon", spec.second);
        controls[spec.first]->getProperties().set("centredIconLabel", true);
    }
    addTrack.setButtonText("Add");
    addTrack.getProperties().set("flat", true);
    addTrack.setColour(TextButton::textColourOffId, theme::green);
    addTrack.setColour(TextButton::buttonColourId, theme::green.withAlpha(.1f));
    addAndMakeVisible(addTrack);
    addTrack.setTooltip(String::fromUTF8("Criar pista · Ctrl+T"));
    addTrack.onClick = [this] { createTrack(); };
    addAndMakeVisible(timelineLock);
    timelineLock.setComponentID("timelineMovementLock");
    timelineLock.getProperties().set("icon", "unlock");
    timelineLock.getProperties().set("flat", true);
    timelineLock.setWantsKeyboardFocus(false);
    timelineLock.setColour(TextButton::buttonColourId, Colours::white.withAlpha(.18f));
    timelineLock.setColour(TextButton::buttonOnColourId, theme::yellow);
    timelineLock.setColour(TextButton::textColourOffId, Colours::white);
    timelineLock.setColour(TextButton::textColourOnId, Colours::black);
    timelineLock.onClick = [this] { perform([&] { session.edit([](jaras::Project &p) {
        p.timelineMovementLocked = !p.timelineMovementLocked.value_or(false);
    }, false); }); };
    projectBrowser = std::make_unique<ProjectBrowser>();
    addChildComponent(*projectBrowser);
    projectBrowser->createEmpty = [this] { createProject(false); };
    projectBrowser->createStems = [this] { createProject(true); };
    projectBrowser->createRecording = [this] { chooseRecordingProject(); };
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
    projectBrowser->deleteProject = [this](File file) { deleteRecentProject(file); };
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
    mixerWidth = jlimit(281, 900, (int)appearance.value("jaras.trackColumnWidth", 281));
    setlistWidth = jlimit(minimumSetlistWidth, 900, (int)appearance.value("jaras.setlistWidth", 336));
    footerHeightSetting = jlimit(27, 161, (int)appearance.value("catlive.footerDisplayHeight", 27));
    mixerHeightSetting = jlimit(232, 724, (int)appearance.value("jaras.footerMixerHeight", 300));
    auto bindDivider = [this](DragDivider &divider, const String &id, int &value, int minimum, int maximum, int sign, const String &key) {
        addAndMakeVisible(divider); divider.setComponentID(id);
        divider.started = [this, &value] { resizeStart = value; };
        divider.moved = [this, &value, minimum, maximum, sign](int delta) { value = jlimit(minimum, maximum, resizeStart + sign * delta); resized(); repaint(); };
        divider.ended = [this, &value, key] { if (key.isNotEmpty()) appearance.set(key, value); };
    };
    bindDivider(mixerDivider, "trackMixerDivider", mixerWidth, 281, 900, 1, "jaras.trackColumnWidth");
    bindDivider(setlistDivider, "setlistDivider", setlistWidth, minimumSetlistWidth, 900, -1, "jaras.setlistWidth");
    bindDivider(footerHeightDivider, "footerHeightDivider", footerHeightSetting, 27, 161, -1, "catlive.footerDisplayHeight");
    bindDivider(mixerHeightDivider, "mixerHeightDivider", mixerHeightSetting, 232, 724, -1, "jaras.footerMixerHeight");
    resourceUsage.sample();
    fadeoutOverlay = std::make_unique<TransportFadeoutOverlay>(session, [this] {
        session.cancelTransportFadeout();
    });
    addChildComponent(*fadeoutOverlay);
    session.transportFadeoutWarning = [safe = SafePointer<Workspace>(this)](String text) {
        if (safe && safe->fadeoutOverlay) safe->fadeoutOverlay->showWarning(std::move(text));
    };
    selectionAreas.add(tracksViewport, "tracks", [this] { return selectAllTracks(); });
    selectionAreas.add(*footerMixer, "tracks", [this] { return selectAllTracks(); });
    selectionAreas.add(*timeline, "grid", [this] { return selectAllGridItems(); });
    selectionAreas.add(*setlist, "setlist", [this] { return setlist->selectAllItems(); });
    selectionAreas.activate(*timeline);
    startTimerHz(30);
}
Workspace::~Workspace() {
    stopTimer();
    remoteHost->stop();
    appearance.removeChangeListener(this);
    floatingWindows.clear();
    session.changed = {};
    session.tick = {};
    session.transportFadeoutWarning = {};
    auth.changed = {};
    tracksViewport.removeMouseListener(this);
    tracksViewport.setViewedComponent(nullptr, false);
    dockViewport.setViewedComponent(nullptr, false);
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
        std::function<bool(const KeyPress &)> selectAll;
        BorderSize<int> getBorderThickness() const override {
            return getTitleBarHeight() == 0 ? BorderSize<int>(0) : DocumentWindow::getBorderThickness();
        }
        BorderSize<int> getContentComponentBorder() const override {
            return getTitleBarHeight() == 0 ? BorderSize<int>(0) : DocumentWindow::getContentComponentBorder();
        }
        bool keyPressed(const KeyPress &key) override {
            if (key.getKeyCode() == KeyPress::F4Key && key.getModifiers().isAltDown()) {
                closeButtonPressed();
                return true;
            }
            if (retryEditorShortcut(key))
                return true;
            if (selectAll && selectAll(key))
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
    // Projection windows participate in normal window ordering so settings,
    // FX and plug-in windows can come to the front when opened.
    window->setAlwaysOnTop(false);
    if (name == "Mixer") window->selectAll = [safe = SafePointer<Workspace>(this)](const KeyPress &key) {
        return safe && safe->selectionAreas.selectAll(key);
    };
    panel->setSize(width, height);
    window->setContentOwned(panel.release(), true);
    window->setResizeLimits(name.startsWith("Piano Roll") ? 760 : 360,
                            name.startsWith("Piano Roll") ? 440 : 240, 3840, 2160);
    window->centreAroundComponent(this, width, height + 32);
    window->onClose = [safe = SafePointer<Workspace>(this), name] {
        if (safe && name == "Recados") safe->stage.clearNotice();
        Timer::callAfterDelay(1, [safe] { if (safe) safe->updateState(); });
    };
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
    g.fillRect(tracksViewport.getX(), workspaceBounds.getY(), tracksViewport.getWidth(), workspaceBounds.getHeight());
    {
        const auto &state = session.transport();
        const auto cpu = footerBounds.withWidth(footerSongBounds.getX() - footerBounds.getX());
        const auto device = footerBounds.withLeft(footerSongBounds.getRight());
        const int totalWidth = roundToInt(footerSongBounds.getWidth() * .10);
        auto names = footerSongBounds.withTrimmedRight(totalWidth);
        auto next = names.removeFromLeft(roundToInt(footerSongBounds.getWidth() * .45));
        auto queued = names;
        auto total = footerSongBounds.withLeft(footerSongBounds.getRight() - totalWidth);
        g.setColour(theme::display); g.fillRoundedRectangle(footerSongBounds.toFloat(), 4);
        g.setColour(theme::line); g.drawRoundedRectangle(footerSongBounds.toFloat().reduced(.5f), 4, 1);
        g.drawVerticalLine(total.getX(), (float)total.getY() + 1, (float)total.getBottom() - 1);
        g.drawVerticalLine(queued.getX(), (float)queued.getY()+1, (float)queued.getBottom()-1);
        g.setColour(theme::secondary); g.setFont(theme::mediumFont(9));
        g.drawText("CPU " + ResourceUsage::percent(resourceUsage.cpu), cpu.getX() + 8, cpu.getY(), 70, cpu.getHeight(), Justification::centredLeft);
        g.drawText("RAM " + ResourceUsage::percent(resourceUsage.ram), cpu.getX() + 84, cpu.getY(), std::max(1, cpu.getWidth() - 90), cpu.getHeight(), Justification::centredLeft);
        const float fontScale = std::sqrt(std::max(25, footerBounds.getHeight() - 2) / 25.f);
        auto label = [&](juce::Rectangle<int> r, String heading, String value) {
            // Match SongNameDisplay's stacked footer: the caption grows more
            // slowly than the song name, with padding derived from the height.
            const float height = (float)std::max(25, r.getHeight() - 2);
            const float padding = std::min(6.f, std::max(0.f, (height - 25) * .05f));
            const float spacing = std::min(3.f, std::max(0.f, (height - 25) * .04f));
            const auto captionFont = theme::font(8 * (1 + (fontScale - 1) * .35f), true, true);
            const int captionHeight = (int)std::ceil(captionFont.getHeight());
            const int top = r.getY() + 1 + roundToInt(padding);
            const int bottom = r.getBottom() - roundToInt(padding);
            g.setColour(theme::secondary);
            g.setFont(captionFont);
            g.drawText(heading, r.getX() + 8, top, std::max(1, r.getWidth() - 16), captionHeight, Justification::centredLeft);
            g.setColour(theme::yellow); g.setFont(theme::semiboldFont(12 * fontScale));
            const int y = top + captionHeight + roundToInt(spacing);
            g.drawFittedText(value.isEmpty() ? String::fromUTF8("—") : value, r.getX() + 8, y, std::max(1, r.getWidth() - 16), std::max(1, bottom - y), Justification::topLeft, std::max(1, (bottom - y) / roundToInt(14 * fontScale)), 1.f);
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
                if (state.playing && !state.ignoreNextAfter && nextID == part.id)
                    nextName = regionCaption(*song, &part);
                if ((!state.subPlay.playing && state.queuedRegionId == part.id) ||
                    (state.subPlay.playing && part.startTime <= state.subPlay.position && part.endTime > state.subPlay.position))
                    queueName = regionCaption(*song, &part, state.subPlay.playing ? std::optional<double>(state.subPlay.position) : std::nullopt);
            }
        }
        label(next, String::fromUTF8("Próxima  ›"), nextName);
        label(queued, state.subPlay.playing ? String::fromUTF8("Sub Play  ›") : String::fromUTF8("Fila de espera  ›"), queueName);
        g.setColour(theme::yellow);
        g.setFont(theme::semiboldFont(12 * fontScale));
        g.drawFittedText(clockText(setlist->duration(), true), total, Justification::centred, 1, 1.f);
        g.setColour(theme::secondary);
        g.setFont(theme::font(9));
        String details = String::fromUTF8("Áudio não iniciado");
        if (auto *d = session.audio.devices.getCurrentAudioDevice())
            details = d->getName() + String::fromUTF8(" · ") +
                      String(d->getCurrentBufferSizeSamples()) + String::fromUTF8(" · ") +
                      String((int)d->getCurrentSampleRate()) + " Hz";
        g.drawFittedText(details, device.reduced(8, 0), Justification::centredRight, 1, 1.f);
    }
    auto displayFrame = songDisplay.getBounds().getUnion(transportTime.getBounds());
    g.setColour(theme::line);
    g.drawRoundedRectangle(displayFrame.toFloat().expanded(.5f), 4, 1);
    g.drawVerticalLine(transportInfo.getX() - 1, (float)displayFrame.getY(), (float)displayFrame.getBottom());
    g.drawVerticalLine(transportTime.getX() - 1, (float)displayFrame.getY(), (float)displayFrame.getBottom());
    g.setColour(theme::line);
    g.drawVerticalLine(31, 32, (float)getHeight());
    g.drawHorizontalLine(transportBounds.getBottom(), 32, (float)getWidth());
    const auto masterColour = Colour(0xff000000 | session.project().masterColor.value_or(0xffdc52)).withAlpha(.5f);
    g.setColour(masterColour);
    g.fillRoundedRectangle(40, 40, 230, 70, 5);
    const auto masterLevels = session.audio.meterLevels();
    for (int ch = 0; ch < 2; ++ch)
        meterDisplay::bar(g, {45.f + ch * 6, 44, 5, 62}, masterLevels[(size_t)ch]);
    g.setColour(theme::surfaceText(masterColour));
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
    if (fadeoutOverlay) fadeoutOverlay->setBounds(getLocalBounds());
    const int mixerHeight = footerMixerVisible ? jlimit(232, 724, mixerHeightSetting) : 0;
    const bool compactTransport = getWidth() < 1270, narrowTransport = getWidth() < 900;
    const int rail = 32, title = 32, transport = narrowTransport ? 166 : compactTransport ? 126 : 86;
    const int footerHeight = jlimit(27, 161, footerHeightSetting);
    const int dockHeight = (keyboardVisible ? 108 : 0) + mixerHeight + (partsVisible ? 180 : 0);
    // Keep the timeline usable; scroll the lower panels at their original sizes
    // when the monitor cannot display all of them together.
    const int visibleDockHeight = std::min(dockHeight, std::max(0, getHeight() - title - transport - footerHeight - 128));
    const int bottom = footerHeight + visibleDockHeight;
    caption->setBounds(0, 0, getWidth(), title);
    const bool editorVisible = !browserVisible && !loginPanel;
    const bool visibilityChanged = !lastEditorVisible || *lastEditorVisible != editorVisible;
    lastEditorVisible = editorVisible;
    for (auto *child : getChildren()) {
        if (dynamic_cast<ModalSheet *>(child))
            child->setBounds(getLocalBounds());
        else if (visibilityChanged && child != navigation.get() && child != caption.get() && child != projectBrowser.get() &&
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
    navigation->setBounds(0, title, getWidth(), std::max(1, getHeight() - title));
    if (navigation->isVisible()) navigation->toFront(false);
    caption->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child))
            child->toFront(false);
    if (!editorVisible)
        return;
    transportBounds = {rail, title, getWidth() - rail, transport};
    footerBounds = {rail, getHeight() - footerHeight, getWidth() - rail, footerHeight};
    workspaceBounds = {rail, title + transport, getWidth() - rail,
                       std::max(1, getHeight() - title - transport - bottom)};
    const int availableWidth = workspaceBounds.getWidth();
    const int right = setlistVisible ? jlimit(minimumSetlistWidth, std::max(minimumSetlistWidth, availableWidth - (mixerVisible ? 281 : 0) - 100), setlistWidth) : 0;
    const int left = mixerVisible ? std::min(mixerWidth, std::max(180, availableWidth - right - 100)) : 0;
    const int sectionsWidth =
        partsListVisible ? jlimit(160, 360, (int)(workspaceBounds.getWidth() * .22)) : 0;
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
        controls[spec.first]->setBounds(topRight, narrowTransport ? 119 : 39, spec.second, 26);
        topRight -= 5;
    }
    const int toolsLeft = topRight + 5;
    if (narrowTransport)
        topRight = edge;
    topRight -= 124;
    tuner->setBounds(topRight, 39, 120, 26);
    topRight -= 5;
    const int displayWidth = std::max(80, topRight - start - 4);
    const int nameWidth = std::max(1, roundToInt((displayWidth - 102) * .75));
    songDisplay.setBounds(start, 39, nameWidth, 26);
    transportInfo.setBounds(start + nameWidth + 1, 39, std::max(1, displayWidth - 102 - nameWidth), 26);
    transportTime.setBounds(start + displayWidth - 100, 39, 100, 26);
    // Match the Mac's growing control widths. Fill the entire row so extra room
    // cannot accumulate between Remote and Save on wider windows.
    const float buttonWidth = std::max(52.f, std::floor(52.f + (getWidth() - rail - 1296) / 13.f));
    const float playbackWidth = std::max(46.f, buttonWidth - 8.f);
    const float iconWidth = std::max(30.f, std::round(playbackWidth * .5f));
    struct TransportItem { const char *id; float width, stretch; };
    const TransportItem items[]{
        {"play", playbackWidth, 1}, {"pause", playbackWidth, 1},
        {"subplay", std::max(58.f, playbackWidth), 1}, {"loop", iconWidth, .5f},
        {"record", playbackWidth, 1}, {"metronome", iconWidth, .5f},
        {"tempo", 171, 0}, {"timer", 157, 0},
        {"tp1", buttonWidth, 1}, {"tp2", buttonWidth, 1},
        {"notices", buttonWidth, 1}, {"preview", buttonWidth, 1},
        {"video", buttonWidth, 1}, {"remote", buttonWidth, 1},
        {"save", buttonWidth, 1}, {"setlist", buttonWidth, 1}};
    const auto layoutRow = [&](int begin, int end, int rowStart, int y) {
        float natural = 0, stretch = 0;
        for (int i = begin; i < end; ++i) { natural += items[i].width; stretch += items[i].stretch; }
        const float available = (float)(edge - rowStart - (end - begin - 1) * 5);
        const float fit = std::min(1.f, available / natural);
        const float extra = std::max(0.f, available - natural) / std::max(1.f, stretch);
        float x = (float)rowStart;
        for (int i = begin; i < end; ++i) {
            const auto &item = items[i];
            const int leftEdge = roundToInt(x);
            x += item.width * fit + item.stretch * extra;
            const int width = roundToInt(x) - leftEdge;
            if (String(item.id) == "tempo")
                tempoControl->setBounds(leftEdge, y - 9, width, 43);
            else if (String(item.id) == "timer")
                stageTimer->setBounds(leftEdge, y - 9, width, 43);
            else
                controls[item.id]->setBounds(leftEdge, String(item.id) == "metronome" ? y - 5 : y,
                                              width, String(item.id) == "metronome" ? 35 : 26);
            x += 5;
        }
    };
    layoutRow(0, narrowTransport ? 6 : compactTransport ? 8 : 16, start, 80);
    if (compactTransport)
        layoutRow(8, 16, narrowTransport ? 40 : start, narrowTransport ? 160 : 120);
    if (narrowTransport) {
        const int available = std::max(1, toolsLeft - 40 - 13);
        const int tempoWidth = roundToInt(available * 171.f / 328.f);
        tempoControl->setBounds(40, 111, tempoWidth, 43);
        stageTimer->setBounds(45 + tempoWidth, 111, available - tempoWidth, 43);
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
    for (auto id : {"zoomOut", "zoomIn", "zoomFit"}) controls[id]->setVisible(false);
    tracksViewport.setVisible(mixerVisible);
    tracksViewport.setBounds(rail, workspaceBounds.getY() + 64, left,
                             std::max(1, workspaceBounds.getHeight() - 64));
    tracksContent.setSize(std::max(1, left - 8), std::max(tracksViewport.getHeight(), rowTop(rows.size()) + 16));
    for (int i = 0; i < rows.size(); ++i) {
        rows[i]->setVisible(!rowHidden(i));
        rows[i]->setBounds(0, rowTop(i), std::max(1, left - 8), rowHeight(i));
    }
    addTrack.setBounds(rail + left - 48, workspaceBounds.getY() + 20, 32, 24);
    addTrack.setVisible(mixerVisible);
    timelineLock.setBounds(addTrack.getX() - 30, addTrack.getY(), 24, 24);
    timelineLock.setVisible(mixerVisible);
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
    dockViewport.setVisible(dockHeight > 0);
    dockViewport.setBounds(rail, getHeight() - bottom, getWidth() - rail, visibleDockHeight);
    const int dockWidth = getWidth() - rail - (dockHeight > visibleDockHeight ? 10 : 0);
    dockContent.setSize(dockWidth, dockHeight);
    footerMixer->setBounds(0, 0, dockWidth, mixerHeight);
    if (footerMixerVisible)
        footerMixer->refresh();
    controls["railMixer"]->setColour(TextButton::textColourOffId,
                                     footerMixerVisible || (mixerDetached && floatingWindows.count("Mixer") && floatingWindows["Mixer"]->isVisible()) ? theme::green : Colours::white);
    controls["railKeyboard"]->setColour(TextButton::textColourOffId, keyboardVisible ? theme::green : Colours::white);
    controls["setlist"]->setColour(TextButton::buttonColourId, setlistVisible ? theme::green : theme::panel);
    controls["setlist"]->setColour(TextButton::textColourOffId, setlistVisible ? Colours::black : Colours::white);
    controls["mixer"]->setColour(TextButton::textColourOffId, mixerVisible ? theme::green : Colour(0xffc44545));
    partsPanel->setVisible(partsVisible);
    partsPanel->setBounds(0, mixerHeight, dockWidth, 180);
    controls["railSections"]->setColour(TextButton::textColourOffId,
                                        partsVisible ? theme::green : Colours::white);
    if (keyboardVisible)
        keyboard->setBounds(0, mixerHeight + (partsVisible ? 180 : 0), dockWidth, 108);
    mixerDivider.setVisible(mixerVisible); setlistDivider.setVisible(setlistVisible);
    mixerDivider.setBounds(rail + left - 3, workspaceBounds.getY(), 6, workspaceBounds.getHeight());
    setlistDivider.setBounds(setlist->getX() - 3, workspaceBounds.getY(), 6, workspaceBounds.getHeight());
    footerHeightDivider.setBounds(rail, footerBounds.getY() - 3, getWidth() - rail, 6);
    mixerHeightDivider.setVisible(footerMixerVisible);
    mixerHeightDivider.setBounds(rail, dockViewport.getY() - 3, getWidth() - rail, 6);
    footerSongBounds = footerBounds.withTrimmedLeft(std::min(footerLeftWidth, footerBounds.getWidth() / 3))
                                   .withTrimmedRight(std::min(footerRightWidth, footerBounds.getWidth() / 3));
    controls["audioStatus"]->setBounds(footerBounds.withLeft(footerSongBounds.getRight()));
    trackHeightHandle->setBounds(tracksViewport.getX(),tracksViewport.getY(),timeline->getRight()-tracksViewport.getX(),tracksViewport.getHeight());
    trackHeightHandle->setVisible(projectReady && !browserVisible);trackHeightHandle->toFront(false);
    for (auto *divider : {&mixerDivider, &setlistDivider, &footerHeightDivider, &mixerHeightDivider}) divider->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child)) child->toFront(false);
    if (navigation->isVisible()) navigation->toFront(false);
}
const ItemLanes &Workspace::itemLanes(int index) const {
    if (itemLayoutRevision != session.revision) {
        itemLayouts.clear();
        if (const auto *song = session.song()) for (const auto &track : song->tracks) itemLayouts.emplace_back(track);
        itemLayoutRevision = session.revision;
    }
    return itemLayouts.at((size_t)index);
}
int Workspace::itemLaneHeight(int index) const {
    if (const auto *song=session.song(); song && index>=0 && index<(int)song->tracks.size())
        return jlimit(itemLanes(index).count>1?26:24,itemLanes(index).count>1?168:240,
            roundToInt(trackHeight * (itemLanes(index).count>1 ? .7 : 1.) *
                (trackHeightPreview && trackHeightPreview->first==song->tracks[(size_t)index].id ? trackHeightPreview->second : song->tracks[(size_t)index].heightScale.value_or(1.))));
    return trackHeight;
}
int Workspace::rowBodyHeight(int index) const {
    return itemLaneHeight(index) * itemLanes(index).count;
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
    std::set<ID> liveItems;
    if (const auto *song = session.song()) for (const auto &track : song->tracks)
        for (const auto &clip : track.clips) liveItems.insert(clip.id);
    for (auto at = selectedClips.begin(); at != selectedClips.end();)
        if (!liveItems.count(*at)) at = selectedClips.erase(at); else ++at;
    if (!liveItems.count(selectedClip)) selectedClip = selectedClips.empty() ? ID{} : *selectedClips.begin();
    std::vector<ID> current;
    if (auto *s = session.song())
        for (auto &t : s->tracks)
            current.push_back(t.id);
    auto songID = session.song() ? session.song()->id : ID{};
    if (current != builtTracks || songID != builtSong) {
        for (auto at = selectedTracks.begin(); at != selectedTracks.end();)
            if (std::find(current.begin(), current.end(), *at) == current.end()) at = selectedTracks.erase(at);
            else ++at;
        if (std::find(current.begin(), current.end(), selectedTrack) == current.end()) selectedTrack.clear();
        if (std::find(current.begin(), current.end(), trackSelectionAnchor) == current.end()) trackSelectionAnchor.clear();
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
    // Owned, non-topmost projection windows stay visible above the workspace,
    // while independent FX/plugin windows can take focus and move in front.
    // A sheet is painted inside this HWND, so temporarily drop the ownership
    // while it is open; otherwise the video would obscure its controls.
    if(auto *peer=getPeer()) {
        const auto main=static_cast<HWND>(peer->getNativeHandle());
        const bool sheet=dynamic_cast<ModalSheet*>(Component::getCurrentlyModalComponent())!=nullptr;
        for(const auto &entry:floatingWindows) {
            if(!dynamic_cast<Projection*>(entry.second->getContentComponent()))continue;
            auto *floatingPeer=entry.second->getPeer();if(!floatingPeer)continue;
            const auto handle=static_cast<HWND>(floatingPeer->getNativeHandle());
            const auto owner=reinterpret_cast<HWND>(GetWindowLongPtrW(handle,GWLP_HWNDPARENT));
            if(sheet && owner==main) {
                SetWindowLongPtrW(handle,GWLP_HWNDPARENT,0);
                SetWindowPos(handle,HWND_BOTTOM,0,0,0,0,
                             SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
            } else if(!sheet && owner!=main) {
                SetWindowLongPtrW(handle,GWLP_HWNDPARENT,reinterpret_cast<LONG_PTR>(main));
                SetWindowPos(handle,HWND_TOP,0,0,0,0,
                             SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
            }
        }
    }
    if (fadeoutOverlay) fadeoutOverlay->update();
    if (session.transportFadeoutActive() || lastFadeoutActive)
        for (auto *row : rows) if (row->isShowing()) row->refresh();
    lastFadeoutActive = session.transportFadeoutActive();
    const bool movementLocked = session.project().timelineMovementLocked.value_or(false);
    timelineLock.setToggleState(movementLocked, dontSendNotification);
    timelineLock.getProperties().set("icon", movementLocked ? "lock" : "unlock");
    timelineLock.setTooltip(movementLocked ? String::fromUTF8("Desbloquear movimento no grid")
                                          : String::fromUTF8("Bloquear movimento de itens, regiões e marcadores"));
    timelineLock.setEnabled(!session.busy && !session.audio.isRecording());
    session.audio.setKeyboardTarget(selectedTrack);
    session.setRecordingSelection(selectedTrack);
    if (recordVisualSelection != selectedTrack) {
        recordVisualSelection = selectedTrack;
        for (auto *row : rows)
            row->refresh();
    }
    const auto &t = session.transport();
    stage.observe(t);
    for(int i=0;i<2;++i)if(teleprompterHTTP[(size_t)i]->enabled()) {
        const auto content=StageContent::make(session,stage,i+1);
        teleprompterHTTP[(size_t)i]->publish(content.payload,content.media);
    }
    controls["preview"]->setToggleState(stage.preview, dontSendNotification);
    controls["notices"]->setToggleState(false, dontSendNotification);
    const auto video = floatingWindows.find("Video");
    controls["video"]->setToggleState(video != floatingWindows.end() && video->second->isVisible(), dontSendNotification);
    const auto masterFX = session.project().masterFXJSON ? JSON::parse(text(*session.project().masterFXJSON)) : var();
    controls["masterFX"]->setColour(TextButton::textColourOffId, fxchain::colour(masterFX));
    for (int i = 1; i <= 2; ++i) {
        const auto found = floatingWindows.find("Teleprompter " + String(i));
        const bool visible = found != floatingWindows.end() && found->second->isVisible();
        controls[i == 1 ? "tp1" : "tp2"]->setToggleState(visible, dontSendNotification);
        controls[i == 1 ? "railTeleprompt" : "railTeleprompt2"]->setColour(
            TextButton::textColourOffId, visible ? theme::green : Colour(0xffff5555));
    }
    controls["play"]->setButtonText(t.playing ? "Stop" : "Play");
    controls["play"]->getProperties().set("leadingIcon", t.playing ? "stopall" : "play");
    controls["subplay"]->getProperties().set("leadingIcon", t.subPlay.playing ? "pause" : "play");
    controls["play"]->setToggleState(t.playing, dontSendNotification);
    controls["subplay"]->setToggleState(t.subPlay.playing, dontSendNotification);
    controls["subplay"]->setEnabled(t.playing);
    controls["pause"]->setEnabled(t.playing);
    controls["loop"]->setToggleState(t.loop.enabled, dontSendNotification);
    controls["record"]->setToggleState(session.audio.isRecording(), dontSendNotification);
    controls["metronome"]->setToggleState(session.audio.metronomeEnabled.load(),
                                          dontSendNotification);
    controls["record"]->setColour(TextButton::buttonOnColourId, Colour(0xffff1f1f));
    controls["save"]->setButtonText(session.dirty ? "Salvar" : "Salvo");
    controls["save"]->getProperties().set("leadingIcon", session.dirty ? "save" : "check");
    controls["save"]->setColour(TextButton::buttonColourId,
                                session.dirty ? theme::green.withAlpha(.16f) : theme::panel);
    controls["save"]->setColour(TextButton::textColourOffId,
                                session.dirty ? theme::green : theme::secondary);
    controls["railUndo"]->setEnabled(session.canUndo());
    controls["railRedo"]->setEnabled(session.canRedo());
    masterVolume.setValue(session.project().masterVolume, dontSendNotification);
    masterPan.setValue(session.project().masterPan, dontSendNotification);
    controls["masterMute"]->setToggleState(session.project().masterMute, dontSendNotification);
    controls["masterSolo"]->setToggleState(session.project().masterSolo, dontSendNotification);
    controls["masterMono"]->setToggleState(session.project().masterMono, dontSendNotification);
    controls["masterMono"]->setButtonText(session.project().masterMono ? "" : String::fromUTF8("Estéreo"));
    controls["masterMono"]->getProperties().set("icon", session.project().masterMono ? "mono" : "");
    controls["masterMono"]->setColour(TextButton::textColourOnId, theme::green);
    controls["masterMono"]->setColour(TextButton::buttonOnColourId, theme::display);
    if (auto *s = session.song()) {
        String selectedName = text(s->name);
        if (t.regionId)
            for (const auto &part : s->parts)
                if (part.id == *t.regionId)
                    selectedName = regionCaption(*s, &part, t.playing ? std::optional<double>(t.position) : std::nullopt);
        songDisplay.setColour(Label::textColourId, t.playing ? theme::green : Colours::white);
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
    const auto information = t.loop.enabled ? String("Loop Ativo") : t.ignoreNextAfter ? String("Ignore Next") : String();
    transportInfo.setText(information, dontSendNotification);
    const int phase = (int)(Time::getMillisecondCounterHiRes() / 500) % 4;
    transportInfo.setColour(Label::textColourId, information.isNotEmpty() && phase % 2 == 0 ? Colours::red : phase == 1 ? theme::green : theme::yellow);
    transportInfo.setColour(Label::backgroundColourId, information.isNotEmpty() && phase % 2 == 0 ? theme::yellow : theme::display);
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
    const bool hadLogin = loginPanel != nullptr;
    session.audio.instrumentAllowed = auth.allowed();
    bool show = !auth.allowed() && !session.inspection;
    if (show && !loginPanel) {
        // Logging out returns ownership of keyboard/mouse input to the login view.
        // Keep an in-flight account-switch form so it can display its server error.
        for (auto *child : getChildren()) if (auto *sheet = dynamic_cast<ModalSheet *>(child)) {
            bool loginSheet = false;
            for (auto *content : sheet->getChildren()) loginSheet |= dynamic_cast<LoginPanel *>(content) != nullptr;
            if (!loginSheet) sheet->exitModalState(0);
        }
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
    if (auto *backdrop = dynamic_cast<LoginBackdrop *>(loginPanel.get())) backdrop->panel.update();
    for (auto *child : getChildren()) if (auto *sheet = dynamic_cast<ModalSheet *>(child))
        for (auto *content : sheet->getChildren()) if (auto *panel = dynamic_cast<LoginPanel *>(content)) {
            panel->update();
        }
    if (hadLogin != (loginPanel != nullptr)) { resized(); repaint(); }
}
void Workspace::timerCallback() {
    if (fadeoutOverlay) fadeoutOverlay->update();
    timeline->refreshWaveforms();
    timeline->followPlayback();
    if (resourceUsage.sample()) repaint(footerBounds);
    repaint(44, 43, 14, 64);
    for (auto *row : rows) if (row->isShowing()) row->repaint(0, 0, 22 + row->groupIndent(), row->getHeight());
    controls["remote"]->setColour(TextButton::buttonColourId, remoteHost->enabled() ? theme::green : Colour(0xffc44848));
    int y = tracksViewport.getViewPositionY();
    if (y != verticalOffset) {
        verticalOffset = y;
        timeline->updateRanges();
        resized();
    }
    const bool subVisible = session.subCursorVisible();
    if (session.transport().playing || subVisible || subVisible != lastSubCursorVisible)
        timeline->animate();
    lastSubCursorVisible = subVisible;
}
void Workspace::changeListenerCallback(ChangeBroadcaster *) {
    auto &desktop = Desktop::getInstance();
    const auto scale = appearance.interfaceScale();
    if (std::abs(desktop.getGlobalScaleFactor() - scale) > .0001f) {
        desktop.setGlobalScaleFactor(scale);
        if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
            if (isProjectBrowserShowing()) fitProjectBrowserWindow(*window);
            else fitEditorWindow(*window, window->getBounds());
        }
        resized();
    }
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
bool Workspace::keyStateChanged(bool) {
    for (auto i = heldShortcutKeys.begin(); i != heldShortcutKeys.end();)
        if (!KeyPress::isKeyCurrentlyDown(*i)) i = heldShortcutKeys.erase(i);
        else ++i;
    return false;
}
bool Workspace::keyPressed(const KeyPress &key) {
    if (session.inspection && logger)
        logger->logMessage("QA key=" + String(key.getKeyCode()) +
                           " mods=" + String(key.getModifiers().getRawFlags()));
    if (session.inspection && key.getKeyCode() == KeyPress::F12Key) {
        capture(File::getSpecialLocation(File::userApplicationDataDirectory)
                    .getChildFile("Hook Developer/CatLive/qa/current.png"));
        return true;
    }
    if (navigation->isVisible()) {
        if (key.getKeyCode() == KeyPress::escapeKey) navigation->setVisible(false);
        return true;
    }
    auto *focused = Component::getCurrentlyFocusedComponent();
    if (dynamic_cast<TextEditor *>(focused))
        return retryEditorShortcut(key);
    if (Component::getCurrentlyModalComponent() != nullptr) return false;
    const auto mods = key.getModifiers();
    int code = key.getKeyCode();
    // Windows may deliver Ctrl+A..Z through WM_CHAR as C0 characters (1..26).
    if (mods.isCtrlDown() && code >= 1 && code <= 26 &&
        !(code == KeyPress::tabKey && (GetKeyState(VK_TAB) & 0x8000)))
        code = 'A' + code - 1;
    if (code >= 'a' && code <= 'z')
        code -= ('a' - 'A');
    const bool isRepeat = !heldShortcutKeys.insert(code).second;
    const bool ctrl = mods.isCtrlDown(), shift = mods.isShiftDown(), alt = mods.isAltDown();
    if (ctrl && !alt && !shift && code == 'Q') {
        JUCEApplication::getInstance()->systemRequestedQuit();
        return true;
    }
    if (ctrl && !alt && !shift && code == 'N') {
        ++shortcutCount;
        newProject();
        return true;
    }
    if (ctrl && !alt && !shift && code == 'O') {
        ++shortcutCount;
        chooseOpen();
        return true;
    }
    if (ctrl && !alt && code == 'S') {
        if (!projectReady || loginPanel)
            return false;
        ++shortcutCount;
        chooseSave(shift);
        return true;
    }
    if (ctrl && !alt && !shift && code == 'I') {
        if (!projectReady || loginPanel || browserVisible)
            return false;
        ++shortcutCount;
        chooseImport();
        return true;
    }
    if (ctrl && !alt && !shift && code == ',') {
        ++shortcutCount;
        openSettings();
        return true;
    }
    if (loginPanel || browserVisible)
        return false;
    if (ctrl && !alt && !shift && (code == 'C' || code == 'X' || code == 'V' || code == 'D')) {
        if (isRepeat) return true;
        ++shortcutCount;
        if (code == 'V' || code == 'D') pasteGridItems(code == 'D');
        else copyGridItems(code == 'X');
        return true;
    }
    const KeyPress normalised(code, mods, key.getTextCharacter());
    if (selectionAreas.selectAll(normalised)) return true;
    if (actions.key(normalised, isRepeat)) {
        ++shortcutCount;
        return true;
    }
    if (code == 'M' && !ctrl && !alt && shift) {
        if (isRepeat) return true;
        ++shortcutCount;
        editMarker({}, session.transport().editPosition);
        return true;
    }
    if (code == KeyPress::escapeKey) {
        timeline->cancelInteraction();
        ++shortcutCount;
        perform([&] { session.command(jaras::CommandKind::escape); });
        return true;
    }
    if (ctrl && !alt && code == 'Z') {
        ++shortcutCount;
        perform([&] {
            if (shift)
                session.redo();
            else
                session.undo();
        });
        return true;
    }
    if (code == KeyPress::deleteKey || code == KeyPress::backspaceKey) {
        ++shortcutCount;
        if (!selectedClip.empty())
            perform([&] {
                const auto ids = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
                session.edit([&](auto &project) {
                    for (auto &song : project.songs) for (auto &track : song.tracks)
                        track.clips.erase(std::remove_if(track.clips.begin(), track.clips.end(),
                            [&](const auto &clip) { return ids.count(clip.id) != 0; }), track.clips.end());
                });
                clearItemSelection();
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
    return false;
}
bool Workspace::isInterestedInFileDrag(const StringArray &files) {
    for(auto &path:files)if(File(path).hasFileExtension("jl;bkjl;ziplive;zip;wav;wave;aif;aiff;flac;mp3;ogg;m4a;aac;mp4;mov;m4v;avi;mkv;webm;wmv;png;jpg;jpeg;bmp;gif;tif;tiff"))return true;
    return false;
}
void Workspace::fileDragMove(const StringArray &,int x,int y){externalDropPoint=Point<int>{x,y};repaint();}
void Workspace::fileDragExit(const StringArray &){externalDropPoint.reset();repaint();}
void Workspace::filesDropped(const StringArray &files,int x,int y) {
    externalDropPoint.reset();repaint();if(loginPanel||session.busy)return;
    for(auto &path:files)if(File(path).hasFileExtension("jl;bkjl;ziplive;zip")){perform([&]{openProject(File(path));});return;}
    if(browserVisible||!projectReady||!session.song())return;
    const auto local=timeline->getLocalPoint(this,Point<int>{x,y});
    if(!timeline->getLocalBounds().contains(local)||local.y<64)return;
    const int row=rowAt(local.y-64+tracksViewport.getViewPositionY());
    const ID target=row>=0&&row<(int)session.song()->tracks.size()?session.song()->tracks[(size_t)row].id:ID{};
    const double at=timelineGrid::snapSelection(timeline->timeAt((float)local.x),*session.song(),pixelsPerSecond,session.transport(),ModifierKeys::getCurrentModifiers().isShiftDown());
    const ID project=session.project().id,song=session.song()->id;
    Array<File> media;for(auto &path:files)media.add(File(path));
    auto submit=[safe=SafePointer<Workspace>(this),media,target,at,project,song](bool same,double gap){if(safe)safe->perform([&]{
        if(safe->session.project().id!=project||!safe->session.song()||safe->session.song()->id!=song)throw std::runtime_error("O projeto ou grid de destino mudou.");
        safe->session.importMedia(media,at,target,same,gap);
    });};
    if(media.size()>1)ModalSheet::open(*this,String::fromUTF8("Importar mídia"),std::make_unique<MediaDropPanel>(submit),400,155);
    else submit(false,0);
}
void Workspace::mouseDown(const MouseEvent &event) {
    if (event.eventComponent == this && event.mods.isPopupMenu() && !browserVisible && juce::Rectangle<int>(40,40,230,70).contains(event.getPosition()))
        showMasterMenu(event.getScreenPosition());
}
void Workspace::mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &details) {
    auto relative = event.getEventRelativeTo(this);
    if (tracksViewport.getBounds().contains(relative.getPosition())) {
        ++wheelCount;
        if (event.mods.isCtrlDown()) {
            timeline->adjustTrackHeight(details.deltaY);
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
void Workspace::deleteRecentProject(const File &file) {
    if(session.busy || session.transport().playing || session.transport().subPlay.playing || session.audio.isRecording())return;
    const auto owner=SafePointer<Workspace>(this);
    perform([&]{
        auto plan=std::make_shared<ProjectDeletion>(file);
        auto *dialog=new AlertWindow("Excluir projeto?",String::fromUTF8("O projeto e suas mídias exclusivas serão excluídos. Arquivos compartilhados e a pasta serão preservados.\n\n")+file.getFullPathName(),MessageBoxIconType::WarningIcon,this);
        dialog->addButton("Excluir projeto",1);dialog->addButton("Cancelar",0,KeyPress(KeyPress::escapeKey));dialog->getButton(0)->setEnabled(false);
        auto safeDialog=SafePointer<AlertWindow>(dialog);
        Timer::callAfterDelay(3100,[safeDialog]{if(safeDialog)safeDialog->getButton(0)->setEnabled(true);});
        dialog->enterModalState(true,ModalCallbackFunction::create([safe=owner,plan](int choice){
            if(!safe || choice!=1)return;
            safe->perform([&]{auto &w=*safe;if(w.session.busy || w.session.transport().playing || w.session.transport().subPlay.playing || w.session.audio.isRecording())return;plan->validate();
                if(w.session.document!=plan->document && w.session.dirty && w.projectReady){if(w.session.document==File{})throw std::runtime_error("Salve o projeto aberto antes de excluir outro projeto.");w.session.save(w.session.document);}
                w.floatingWindows.clear();
                plan->remove();w.session.newProject();w.projectReady=false;w.browserVisible=true;RecentProjects::forget(plan->document);w.projectBrowser->refresh();
                for(auto *child:w.getChildren())if(auto *sheet=dynamic_cast<ModalSheet*>(child);sheet && sheet->getName()=="Projetos")sheet->exitModalState(0);
                if(w.browserVisible)w.showProjectBrowser();w.resized();w.repaint();
            });
        }),true);
    });
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
        panel->createRecording = projectBrowser->createRecording;
        panel->createReaper = projectBrowser->createReaper;
        panel->createLogic = projectBrowser->createLogic;
        panel->addStems = projectBrowser->addStems;
        panel->addPackage = projectBrowser->addPackage;
        panel->browse = projectBrowser->browse;
        panel->open = projectBrowser->open;
        panel->deleteProject = projectBrowser->deleteProject;
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
        fitProjectBrowserWindow(*window);
    }
    resized();
    repaint();
}
void Workspace::projectOpened(bool fitTimeline) {
    clearItemSelection();
    itemClipboard.reset();
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child);
            sheet && sheet->getName() == "Projetos")
            sheet->exitModalState(0);
    projectReady = true;
    browserVisible = false;
    if (session.document.existsAsFile())
        RecentProjects::remember(session.document);
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        fitEditorWindow(*window, editorWindowBounds);
    }
    resized();
    if (fitTimeline)
        timeline->initialView();
    repaint();
    grabKeyboardFocus();
}
void Workspace::openProject(const File &file) {
    if (file.hasFileExtension("ziplive;zip")) { choosePackageDestination(file); return; }
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
void Workspace::openTransportFadeout() {
    if (!projectReady || loginPanel || browserVisible) return;
    ModalSheet::open(*this, "Fadeout", std::make_unique<TransportFadeoutPanel>(session, appearance, actions), 440, 452);
}
void Workspace::triggerTransportFadeout() {
    const auto config = TransportFadeoutPanel::read(appearance, session.project());
    session.toggleTransportFadeout(config.enabled, config.tracks, config.duration);
}
void Workspace::chooseRecordingProject() {
    ModalSheet::open(*this, "REC Multitrack", std::make_unique<RecordingProjectStep>(
        [safe = SafePointer<Workspace>(this)](int channels) {
            if (safe) safe->createProject(false, channels);
        }), 400, 190);
}
void Workspace::createProject(bool withStems, int recordingChannels) {
    auto work = [safe = Component::SafePointer<Workspace>(this), withStems, recordingChannels] {
        if (safe)
            safe->prompt(
                "Create Project", "Project name", "Untitled", [safe, withStems, recordingChannels](String name) {
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
                        [safe, name, withStems, recordingChannels](const FileChooser &fc) {
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
                                if (recordingChannels > 0)
                                    safe->session.createRecordingProject(name, recordingChannels, target);
                                else {
                                    safe->session.newProject(name);
                                    safe->session.save(target);
                                }
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
                                                      safe->session.document, "*.jl;*.bkjl;*.ziplive;*.zip", true);
        safe->chooser->launchAsync(FileBrowserComponent::openMode |
                                       FileBrowserComponent::canSelectFiles,
                                   [safe](const FileChooser &fc) {
                                       if (!safe || fc.getResult() == File())
                                           return;
                                       const auto file=fc.getResult();
                                       MessageManager::callAsync([safe,file]{if(safe)safe->openProject(file);});
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
    if (session.busy) return;
    chooser = std::make_unique<FileChooser>("Abrir pacote CatLive", File::getSpecialLocation(File::userDocumentsDirectory), "*.ziplive;*.zip", true);
    chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
        [safe=SafePointer<Workspace>(this)](const FileChooser &fc) {
            if (!safe || fc.getResult()==File{}) return;
            const auto archive=fc.getResult();
            MessageManager::callAsync([safe,archive]{if(safe)safe->choosePackageDestination(archive);});
        });
}
void Workspace::choosePackageDestination(const File &archive) {
    if (session.busy || session.audio.isRecording()) return;
    chooser=std::make_unique<FileChooser>("Escolha onde salvar o projeto descompactado",File::getSpecialLocation(File::userDocumentsDirectory),"",true);
    chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectDirectories,
        [safe=SafePointer<Workspace>(this),archive](const FileChooser &fc){
            if(!safe || fc.getResult()==File{})return;
            const auto parent=fc.getResult();safe->session.busy=true;safe->projectBrowser->setEnabled(false);
            Thread::launch([safe,archive,parent]{
                File document;String error;
                try{document=importPortablePackage(archive,parent);}catch(const std::exception &e){error=String::fromUTF8(e.what());}
                MessageManager::callAsync([safe,document,error]{
                    if(!safe)return;safe->session.busy=false;safe->projectBrowser->setEnabled(true);
                    if(error.isNotEmpty())safe->showError(error);else safe->openProject(document);
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
                          safe->showPanel("Login", std::make_unique<LoginPanel>(safe->auth, false), 440,
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
                          safe->showPanel("Login", std::make_unique<LoginPanel>(safe->auth, false), 440,
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
            "R — Repetição\nShift+M — Criar marcador\n"
            "+ / − — Aumentar / diminuir BPM\nM / Shift+S — Mute / Solo da pista\n"
            "S — Dividir itens no cursor\nN — Normalizar item selecionado\n"
            "Q / [ — Início / fim do projeto\nA / D — Região anterior / próxima\n"
            "E / W — Marcador ou limite anterior / próximo\n"
            "Ctrl+Shift+T — Criar marcador de andamento\n"
            "Ctrl+N / O / S — Projetos / abrir / salvar\nCtrl+Shift+S — Salvar como\n"
            "Ctrl+I / Ctrl+T — Importar áudio / nova pista\n"
            "Ctrl+Z / Ctrl+Shift+Z — Desfazer / refazer\nDelete — Excluir item selecionado\n"
            "Roda sobre o grid — Zoom horizontal\n"
            "Shift+roda — Rolagem horizontal\nRoda sobre as pistas — Rolagem vertical\n"
            "Clique no grid — Posicionar cursor de edição\nAlt+clique — Posicionar Sub Play\n"
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
void Workspace::exportRegions(std::set<ID> ids) {
    if (!session.song()) return;
    auto panel = std::make_unique<ExportPanel>(session, ID{}, ID{}, [safe=SafePointer<Workspace>(this)](String message) { if (safe) safe->showError(message); });
    panel->selectRegions(std::move(ids));
    ModalSheet::open(*this, String::fromUTF8("Exportar áudio"), std::move(panel), 760, 620);
}
void Workspace::detectRegions(std::set<ID> ids) {
    confirm("Detectar BPM", "Detectar BPM a partir da pista Click?", [safe=SafePointer<Workspace>(this),ids] { if(safe) safe->perform([&] { safe->session.detectRegionBPM(ids); }); });
}
void Workspace::editMultiLoops(ID id) {
    ModalSheet::open(*this, "Multiloop Manager", std::make_unique<MultiLoopsPanel>(session,id,[safe=SafePointer<Workspace>(this)](String message){if(safe)safe->showError(message);}),660,490);
}
void Workspace::showRegionMenu(ID id, Point<int> point) {
    if (!session.song()) return;
    const bool unified = regionEditing::hasChildren(*session.song(),id);
    PopupMenu menu;
    menu.addItem(1, "Editar"); menu.addItem(2, String::fromUTF8("Detectar BPM…"));
    if (regionEditing::overlapping(*session.song(),id).size()>1) menu.addItem(3,"Unificar");
    if (unified) menu.addItem(4,"Desunificar");
    menu.addItem(5,String::fromUTF8("Exportar áudio")); menu.addItem(6,String::fromUTF8("Excluir região"));
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe=SafePointer<Workspace>(this),id](int action){
        if(!safe||!safe->session.song())return;
        if(action==1)safe->editRegion(id);
        if(action==2)safe->detectRegions({id});
        if(action==3){
            const auto roots=regionEditing::overlapping(*safe->session.song(),id);
            const bool existing=std::any_of(roots.begin(),roots.end(),[&](const auto &part){return regionEditing::hasChildren(*safe->session.song(),part.id);});
            auto unify=[safe,id](String name){if(safe)safe->perform([&]{const auto songID=safe->session.song()->id;safe->session.edit([&](auto &p){regionEditing::unify(p,songID,id,name);});});};
            if(existing)unify({});else safe->prompt(String::fromUTF8("Unificar regiões"),"Nome",{},unify);
        }
        if(action==4)safe->perform([&]{const auto songID=safe->session.song()->id;safe->session.edit([&](auto &p){regionEditing::disunify(p,songID,id);});});
        if(action==5)safe->exportRegions({id});
        if(action==6)safe->deleteRegions({id});
    });
}
void Workspace::deleteRegions(std::set<ID> ids, bool withContents) {
    if (!session.song()) return;
    const auto songID=session.song()->id;
    confirm(String::fromUTF8("Excluir região"), withContents ? String::fromUTF8("Excluir as músicas selecionadas, seus itens e marcadores? Os arquivos de mídia permanecem na pasta do projeto.") : String::fromUTF8("Excluir esta região?"),
        [safe=SafePointer<Workspace>(this),ids,withContents,songID] {
        if (!safe || !safe->session.song() || safe->session.song()->id!=songID) return;
        safe->perform([&] { safe->session.edit([&](jaras::Project &project) {
            regionEditing::erase(project, songID, ids, withContents);
        }); });
    });
}
void Workspace::editRegion(ID id) {
    if (!session.song()) return;
    for (const auto &part : session.song()->parts) if (part.id == id) {
        auto safe = SafePointer<Workspace>(this);
        auto close = [safe] { if (safe) ModalSheet::dismiss(*safe); };
        auto save = [safe, id, close](String name, unsigned colour, bool upper) {
            if (safe) safe->perform([&] { safe->session.edit([&](jaras::Project &p) {
                for (auto &song : p.songs) for (auto &part : song.parts) if (part.id == id) {
                    part.name = utf8(name); part.color = colour; part.uppercaseName = upper;
                }
            }, false); close(); });
        };
        ModalSheet::open(*this, String::fromUTF8("Editar região"), std::make_unique<RegionEditor>(text(part.name), part.color.value_or(0x705264), part.uppercaseName.value_or(true), save, close), 300, 404);
        return;
    }
}
void Workspace::showMarkerMenu(ID id, Point<int> point) {
    const auto *song=session.song();if(!song || !song->markers)return;
    auto found=std::find_if(song->markers->begin(),song->markers->end(),[&](const auto &m){return m.id==id;});
    if(found==song->markers->end())return;
    if(!markerRegions::outsideRegions(*found,*song)){editMarker(id,found->position);return;}
    const auto projectID=session.project().id,songID=song->id;
    PopupMenu menu;menu.addItem(1,"Editar");menu.addItem(2,String::fromUTF8("Converter para região"));
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe=SafePointer<Workspace>(this),id,projectID,songID](int choice){
        if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID)return;
        const auto *song=safe->session.song();
        if(choice==1 && song->markers)for(const auto &m:*song->markers)if(m.id==id){safe->editMarker(id,m.position);break;}
        if(choice==2)safe->perform([&]{
            const auto result=markerRegions::plan(*safe->session.song(),id);
            if(!result.plans.empty())safe->session.edit([&](auto &project){markerRegions::apply(project,songID,result);});
            AlertWindow::showMessageBoxAsync(MessageBoxIconType::InfoIcon,String::fromUTF8("Conversão de marcadores"),result.message(),"OK",safe);
        });
    });
}
void Workspace::editMarker(ID id, double position) {
    if (!session.song()) return;
    jaras::TimelineMarker marker; marker.id = id.empty() ? uuid() : id;
    marker.position = position; marker.color = 0x51ef93;
    if (!id.empty() && session.song()->markers) for (const auto &m : *session.song()->markers) if (m.id == id) marker = m;
    if (marker.tempoBPM) {editTempoMarker(id,position);return;}
    auto safe = SafePointer<Workspace>(this);
    auto close = [safe] { if (safe) ModalSheet::dismiss(*safe); };
    auto save = [safe, marker, songID = session.song()->id, close](String name, unsigned colour, bool) mutable {
        marker.name = utf8(name); marker.color = colour;
        if (safe) safe->perform([&] { safe->session.edit([&](jaras::Project &p) {
            for (auto &song : p.songs) if (song.id == songID) {
                if (!song.markers) song.markers.emplace();
                auto it = std::find_if(song.markers->begin(), song.markers->end(), [&](const auto &m) { return m.id == marker.id; });
                if (it == song.markers->end()) song.markers->push_back(marker); else *it = marker;
            }
        }); close(); });
    };
    ModalSheet::open(*this, String::fromUTF8("Editar marcador"), std::make_unique<RegionEditor>(text(marker.name), marker.color, false, save, close, false), 300, 370);
}
void Workspace::editTempoMarker(ID id, double position) {
    if (!session.song()) return;
    auto marker=tempoEditing::boundary(*session.song(),position);
    if (!id.empty() && session.song()->markers) for (const auto &m:*session.song()->markers) if(m.id==id) marker=m;
    const auto safe=SafePointer<Workspace>(this);
    const auto project=session.project().id,song=session.song()->id;
    auto close=[safe]{if(safe)ModalSheet::dismiss(*safe);};
    auto save=[safe,project,song,close](jaras::TimelineMarker value) {
        if(!safe || safe->session.project().id!=project || !safe->session.song() || safe->session.song()->id!=song) return;
        safe->perform([&]{safe->session.edit([&](auto &p){auto edit=safe->session.core;
            edit.setMarker(value.id,value.name,value.position,value.color,value.tempoBPM,value.tempoBeats,value.tempoUnit,value.tempoTimebase);
            p=edit.project();}, true, true);close();});
    };
    ModalSheet::open(*this,String::fromUTF8("Marcador de tempo"),std::make_unique<TempoMarkerPanel>(marker,save,close),420,164);
}
void Workspace::showMasterMenu(Point<int> point) {
    PopupMenu menu;
    menu.addItem(1,"Patch"); menu.addItem(2,"FX"); menu.addItem(3,"Env");
    menu.addItem(4,String::fromUTF8("Editar pista"));
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),
        [safe=SafePointer<Workspace>(this)](int choice) {
            if (!safe) return;
            if (choice == 1) showPanel("Patch",std::make_unique<PatchPanel>(safe->session,ID{},[safe](String error){if(safe)safe->showError(error);}),360,400);
            if (choice == 2) safe->openFX({});
            if (choice == 3) safe->openAutomation({});
            if (choice == 4) safe->editMasterColour();
        });
}
void Workspace::editMasterColour() {
    auto safe=SafePointer<Workspace>(this);
    auto close=[safe] { if(safe) for(auto *child:safe->getChildren()) if(auto *sheet=dynamic_cast<ModalSheet*>(child);sheet && sheet->getName()=="Editar pista") {sheet->exitModalState(0);break;} };
    auto save=[safe,close](String,unsigned colour,bool) { if(safe) safe->perform([&] { safe->session.edit([&](jaras::Project &project){project.masterColor=colour;},false);close();}); };
    auto editor=std::make_unique<RegionEditor>("Master",session.project().masterColor.value_or(0xffdc52),false,save,close,false,false);
    ModalSheet::open(*this,"Editar pista",std::move(editor),300,320);
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
                     300, 370);
}
void Workspace::specialTrackAction(ID id,const String &action) {
    if(action=="settings") {showPanel("Timecode",std::make_unique<PatchPanel>(session,id,[safe=SafePointer<Workspace>(this)](String error){if(safe)safe->showError(error);}),360,400);return;}
    if(action=="text"){addTextItem(id,session.transport().editPosition);return;}
    if(action=="mtc"||action=="ltc"||action=="click") {
        perform([&]{session.edit([&](jaras::Project &p){for(auto &song:p.songs)for(auto &track:song.tracks)if(track.id==id){
            if(action=="click"&&track.role.id=="generatedClick") {
                for(const auto &part:song.parts)if(!part.parentRegionID&&part.endTime>part.startTime) {
                    if(std::any_of(track.clips.begin(),track.clips.end(),[&](const auto &c){return c.startTime<=part.startTime+1e-6&&c.startTime+c.duration>=part.endTime-1e-6;}))continue;
                    jaras::AudioClip clip;clip.id=part.id;if(!clip.id.empty()){const int digit=CharacterFunctions::getHexDigitValue(clip.id[0]);if(digit>=0)clip.id[0]="0123456789abcdef"[digit^4];}
                    clip.name="Click · "+part.name;clip.startTime=part.startTime;clip.duration=part.endTime-part.startTime;track.clips.push_back(clip);
                }
                std::sort(track.clips.begin(),track.clips.end(),[](const auto &a,const auto &b){return a.startTime<b.startTime;});
            } else if(track.role.id=="timecode"){auto tc=track.timecode.value_or(jaras::TimecodeSettings{});tc.mode=utf8(action);track.timecode=tc;}
        }});});return;
    }
    if(action=="media") {
        const ID project=session.project().id;
        chooser=std::make_unique<FileChooser>(String::fromUTF8("Adicionar mídia"),File{},"*.mp4;*.mov;*.m4v;*.avi;*.mkv;*.webm;*.png;*.jpg;*.jpeg;*.bmp");
        chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectFiles,[safe=SafePointer<Workspace>(this),id,project](const FileChooser &picker){
            if(!safe||safe->session.project().id!=project)return;const auto file=picker.getResult();if(!file.existsAsFile())return;
            safe->perform([&]{safe->session.importMedia({file},safe->session.transport().editPosition,id,true,0);});
        });
    }
}

void Workspace::showTrackMenu(ID id, Point<int> point) {
    const auto *song = session.song(); if (!song) return;
    const auto at = trackTree::index(*song,id); if (at == song->tracks.size()) return;
    const auto &track = song->tracks[at];
    auto targets = trackSelected(id) ? selectedTracks : std::set<ID>{id};
    targets.insert(id);
    const bool standard = jaras::fixedTrackName(track.role).empty();
    const bool groupable = standard && targets.size()>1 && std::none_of(song->tracks.begin(),song->tracks.end(),[&](const auto &t) {return targets.count(t.id) && (t.stereoLinkPartner || !jaras::fixedTrackName(t.role).empty());});
    PopupMenu menu;
    if (standard || track.role.id=="timecode" || track.role.id=="video" || track.role.id=="generatedClick") menu.addItem(1,"Patch");
    if (track.role.id=="generatedClick") menu.addItem(2,"Sound Designer");
    if (standard) { menu.addItem(3,"FX"); menu.addItem(4,"Criar item MIDI"); if(groupable)menu.addItem(5,String::fromUTF8("Criar grupo")); }
    if (trackTree::end(*song,at)>at+1) menu.addItem(6,"Desagrupar");
    if (track.parentTrackID) menu.addItem(7,"Retirar do grupo");
    if (standard && trackEditing::linkable(*song,targets)) menu.addItem(8,"Vincular pistas");
    if (track.stereoLinkPartner) menu.addItem(9,String::fromUTF8("Desvincular pistas"));
    menu.addItem(10,String::fromUTF8("Editar pista"));
    if (standard) menu.addItem(12, targets.size() > 1 ? "Duplicar pistas" : "Duplicar pista");
    menu.addSeparator(); menu.addItem(11,targets.size()>1 ? "Excluir pistas" : "Excluir pista");
    const auto project = session.project().id, songID = song->id;
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),
        [safe=SafePointer<Workspace>(this),id,targets,project,songID](int choice) {
            if(!safe || !choice || safe->session.project().id!=project || !safe->session.song() || safe->session.song()->id!=songID)return;
            auto &w=*safe;
            if(choice==1)showPanel("Patch",std::make_unique<PatchPanel>(w.session,id,[safe](String error){if(safe)safe->showError(error);},targets),360,400);
            if(choice==2)ModalSheet::open(w,"Sound Designer",std::make_unique<ClickSoundDesigner>(w.session,id),390,280);
            if(choice==3)w.openFX(id);
            if(choice==4)w.addMIDIItem(id,w.session.transport().editPosition);
            if(choice==10)w.editTrack(id);
            if(choice==12)w.perform([&] {
                const auto copies=w.session.duplicateTracks(targets);
                if (!copies.empty()) {
                    w.selectedTracks=std::set<ID>(copies.begin(),copies.end());
                    w.selectedTrack=copies.front();
                    w.rebuild(); w.updateState();
                }
            });
            if(choice>=5 && choice<=9)w.perform([&] {w.session.edit([&](jaras::Project &p) {
                if(choice==5){auto core=w.session.core;core.groupTracks(std::vector<ID>(targets.begin(),targets.end()));p=core.project();}
                if(choice==6)for(auto &song:p.songs)if(song.id==songID)trackEditing::ungroup(song,id);
                if(choice==7)for(auto &song:p.songs)if(song.id==songID)trackEditing::removeFromGroup(song,id);
                if(choice==8){const auto &song=*w.session.song();const auto first=std::find_if(song.tracks.begin(),song.tracks.end(),[&](const auto &t){return targets.count(t.id);});trackEditing::link(p,songID,targets,1,theme::track(*first).getARGB()&0xffffff);}
                if(choice==9)trackEditing::unlink(p,id);
            });});
            if(choice==11){
                const auto remove=[safe,targets,project]{
                    if(!safe || safe->session.project().id!=project)return;
                    safe->perform([&]{safe->session.edit([&](jaras::Project &p){for(auto &song:p.songs)for(const auto &target:targets)trackTree::remove(song,target);});});
                };
                bool containsItems=false;for(const auto &song:w.session.project().songs)for(const auto &track:song.tracks)if(targets.count(track.id) && !track.clips.empty())containsItems=true;
                if(containsItems)w.confirm(targets.size()>1?"Excluir pistas?":"Excluir pista?",String::fromUTF8("Excluir as pistas selecionadas e seus itens?"),remove);
                else remove();
            }
        });
}
void Workspace::showClipMenu(ID id, Point<int> point) {
    PopupMenu menu;
    bool textItem = false, audioItem = false, midiItem = false, muted = false;
    bool projection = false, hasFX = false;
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
                    projection = track.role.id == "video" && clip.audioFile.has_value();
                    hasFX = clip.fxJSON && !list(get(JSON::parse(text(*clip.fxJSON)), "inserted")).isEmpty();
                }
    if (midiItem) {
        menu.addItem(2,muted?"Desmutar itens":"Mutar itens");menu.addItem(31,"Converter Mono");menu.addItem(32,String::fromUTF8("Converter Estéreo"));menu.addItem(14,"Unificar itens");if(hasFX)menu.addItem(15,"FX");
    } else {
        if(audioItem || projection) {
            menu.addItem(9,String::fromUTF8("Criar região do item"));menu.addItem(13,"Re-render");menu.addItem(14,"Unificar itens");menu.addItem(10,"Tuner");menu.addItem(11,String::fromUTF8("Normalizar…"));
            if(audioItem){menu.addSeparator();menu.addItem(21,"Converter Mono - L");menu.addItem(22,"Converter Mono - R");menu.addItem(23,"Converter Mono L-R");menu.addItem(20,String::fromUTF8("Converter Estéreo"));}
        }
        if(audioItem){menu.addSeparator();menu.addItem(2,muted?"Desmutar itens":"Mutar itens");}
        menu.addSeparator();menu.addItem(12,"Exportar",audioItem && !textItem);
    }
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
                if(action==13 || action==14 || action==31 || action==32){w.session.renderItems({id},action==14,action>=31?action-30:0);return;}
                if(action==15){w.openItemFX(id);return;}
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
                w.session.edit([&](jaras::Project &p) {
                    for (auto &s : p.songs)
                        for (auto &t : s.tracks)
                            for (size_t i = 0; i < t.clips.size(); ++i)
                                if (t.clips[i].id == id) {
                                    auto &c = t.clips[i];
                                    if (action == 2)
                                        c.muted = !c.muted;
                                    if (action >= 20 && action <= 23)
                                        c.channelMode = action - 20;
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
        selectedClips = {id};
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
        selectedClips = {itemID};
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
void Workspace::copyGridItems(bool moving) {
    if (!session.song()) return;
    const auto selection = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
    if (auto copied = GridItemClipboard::copy(session.project(), session.song()->id, selection, moving))
        itemClipboard = std::move(copied);
}
void Workspace::pasteGridItems(bool duplicate) {
    if (!session.song() || session.busy) return;
    const auto selection = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
    const auto clipboard = duplicate ? GridItemClipboard::copy(session.project(), session.song()->id, selection) : itemClipboard;
    if (!clipboard || clipboard->song != session.song()->id) return;
    perform([&] {
        const auto entries = clipboard->items(session.project(), duplicate ? clipboard->endPosition() : session.transport().editPosition);
        session.edit([&](auto &project) {
            auto edit = session.core;
            edit.pasteItems(clipboard->song, entries, clipboard->moving);
            project = edit.project();
        });
        selectedClips.clear();
        for (const auto &track : entries) for (const auto &clip : track.clips) selectedClips.insert(clip.id);
        selectedClip = selectedClips.empty() ? ID{} : *selectedClips.begin();
        if (clipboard->moving)
            itemClipboard = GridItemClipboard::copy(session.project(), session.song()->id, selectedClips);
        timeline->invalidate();
        repaint();
    });
}
void Workspace::selectMixerTrack(const ID &id, ModifierKeys mods, bool clearItems) {
    if (mods.isPopupMenu() && trackSelected(id)) return;
    if (mods.isShiftDown() && !trackSelectionAnchor.empty() && session.song()) {
        const auto &tracks = session.song()->tracks;
        auto a = std::find_if(tracks.begin(), tracks.end(), [&](const auto &t) { return t.id == trackSelectionAnchor; });
        auto b = std::find_if(tracks.begin(), tracks.end(), [&](const auto &t) { return t.id == id; });
        if (!mods.isCtrlDown()) selectedTracks.clear();
        if (a != tracks.end() && b != tracks.end())
            for (auto at = std::min(a, b); at <= std::max(a, b); ++at) selectedTracks.insert(at->id);
        else selectedTracks.insert(id);
    } else if (mods.isCtrlDown()) {
        if (selectedTracks.empty() && !selectedTrack.empty()) selectedTracks.insert(selectedTrack);
        if (!selectedTracks.erase(id)) selectedTracks.insert(id);
        trackSelectionAnchor = id;
    } else {
        selectedTracks = {id}; trackSelectionAnchor = id;
    }
    selectedTrack = selectedTracks.count(id) ? id : selectedTracks.empty() ? ID{} : *selectedTracks.begin();
    if (clearItems) clearItemSelection();
    updateState();
    for (auto *row : rows) row->repaint();
    timeline->invalidate();
    repaint();
}
void Workspace::changeMixerFX(const ID &id, bool remove) {
    perform([&] {
        std::vector<ID> targets;
        if (id.empty()) targets.push_back({});
        else if (session.song()) for (const auto &track : session.song()->tracks)
            if ((trackSelected(id) ? trackSelected(track.id) : track.id == id) &&
                jaras::fixedTrackName(track.role).empty()) targets.push_back(track.id);
        fxchain::change(session, targets, remove);
    });
}
bool Workspace::selectAllTracks() {
    selectedTracks.clear();
    if (const auto *song = session.song()) for (const auto &track : song->tracks)
        if (!jaras::isTeleprompterRole(track.role) && track.role.id != "video" && track.role.id != "timecode" && track.role.id != "chords") selectedTracks.insert(track.id);
    selectedTrack = selectedTracks.empty() ? ID{} : *selectedTracks.begin();
    clearItemSelection(); updateState();
    for (auto *row : rows) row->repaint();
    timeline->invalidate(); repaint(); return true;
}
bool Workspace::selectAllGridItems() {
    selectedClips.clear();
    if (const auto *song = session.song()) for (const auto &track : song->tracks)
        for (const auto &clip : track.clips) selectedClips.insert(clip.id);
    selectedClip = selectedClips.empty() ? ID{} : *selectedClips.begin();
    timeline->invalidate(); repaint(); return true;
}
void Workspace::showDetachedMixer() {
    mixerDetached = true; footerMixerVisible = false;
    auto panel = std::make_unique<MixerPanel>(session, [this](ID id) { openFX(id); },
        [this](ID id, ModifierKeys mods) { selectMixerTrack(id, mods); }, [this](String message) { showError(message); },
        [this](ID id, bool remove) { changeMixerFX(id, remove); },
        [this](ID id) { return trackSelected(id); }, [this](ID id,Point<int> point){showTrackMenu(id,point);},[this](ID id,String action){specialTrackAction(id,action);});
    selectionAreas.add(*panel, "tracks", [this] { return selectAllTracks(); });
    openFloating("Mixer", std::move(panel), 1000, 420);
    resized(); repaint();
}
void Workspace::mixerMenu(Point<int> point) {
    PopupMenu menu;
    menu.addItem(1, mixerDetached ? "Acoplar Mixer" : "Destacar Mixer");
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
        [safe = SafePointer<Workspace>(this)](int result) {
            if (!safe || result != 1) return;
            if (safe->mixerDetached) {
                if (auto found = safe->floatingWindows.find("Mixer"); found != safe->floatingWindows.end()) found->second->setVisible(false);
                safe->mixerDetached = false; safe->footerMixerVisible = true;
                safe->resized(); safe->repaint();
            } else safe->showDetachedMixer();
        });
}
void Workspace::showMixer() {
    mixerVisible = !mixerVisible;
    resized();
    repaint();
}
void Workspace::showTeleprompter(int index) {
    const auto key="Teleprompter "+String(index);
    if(auto at=floatingWindows.find(key);at!=floatingWindows.end()) {at->second->setVisible(!at->second->isVisible());return;}
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
void Workspace::openTPRemote(int index) {
    ModalSheet::open(*this,"TP "+String(index)+String::fromUTF8(" · TP Remoto"),std::make_unique<TeleprompterRemotePanel>(*teleprompterHTTP[(size_t)(index-1)],index),420,408);
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
        CloseProjectSheet::open(*this,
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
                });
        return;
    }
    done();
}
void Workspace::capture(const File &path) {
    path.getParentDirectory().createDirectory();
    if (SystemStats::getEnvironmentVariable("CATLIVE_QA_NO_IMAGES", {}) != "1") {
    const ScopedValueSetter<bool> snapshotScope(capturingSnapshot, true);
    auto image = createComponentSnapshot(getLocalBounds(), true, 1);
    FileOutputStream stream(path);
    if (stream.openedOk()) {
        stream.setPosition(0);
        stream.truncate();
        PNGImageFormat png;
        png.writeImageToStream(image, stream);
    }
    }
    path.withFileExtension("json").replaceWithText(JSON::toString(diagnostics()));
}
var Workspace::diagnostics() const {
    auto value = object();
    put(value, "project", text(session.project().name));
    put(value, "authAllowed", auth.allowed());
    put(value, "authBusy", auth.busy);
    put(value, "authMessage", auth.message);
    if (auto *device = session.audio.devices.getCurrentAudioDevice()) {
        auto audioDevice = object();
        put(audioDevice, "driver", session.audio.devices.getCurrentAudioDeviceType());
        Array<var> rates, buffers;
        for (auto rate : device->getAvailableSampleRates()) rates.add(rate);
        for (auto size : device->getAvailableBufferSizes()) buffers.add(size);
        put(audioDevice, "sampleRates", rates);
        put(audioDevice, "bufferSizes", buffers);
        put(audioDevice, "sampleRate", device->getCurrentSampleRate());
        put(audioDevice, "bufferSize", device->getCurrentBufferSizeSamples());
        put(value, "audioDevice", audioDevice);
    }
    put(value, "missingMedia", var(session.audio.missingFiles));
    put(value, "audioUnderruns", (int64)session.audio.getUnderruns());
    put(value, "residentStreams", session.audio.residentStreams());
    put(value, "streaming", session.audio.streamDiagnostics());
    put(value, "audioPreparation", session.audio.preparationDiagnostics);
    put(value, "audioPeak", session.audio.peak());
    put(value, "playing", session.transport().playing);
    put(value, "position", session.transport().position);
    put(value, "selectedTrack", text(selectedTrack));
    Array<var> selectedItemIDs;
    for (const auto &id : selectedClips) selectedItemIDs.add(text(id));
    put(value, "selectedItems", selectedItemIDs);
    Array<var> selectedTrackIDs;
    for (const auto &id : selectedTracks) selectedTrackIDs.add(text(id));
    put(value, "selectedTracks", selectedTrackIDs);
    put(value, "keyboardVisible", keyboardVisible);
    if (session.song()) put(value, "markerCount", session.song()->markers ? (int)session.song()->markers->size() : 0);
    put(value, "noticeActive", stage.noticeActive());
    put(value, "noticeText",
        stage.noticeText(stage.preferences.value("jaras.notices.appearance", object())));
    Array<var> modalNames;
    auto modalControls = object();
    const auto collectModalControls = [&](const auto &self, Component *component) -> void {
        if (!component->isVisible())
            return;
        if (component->getComponentID().isNotEmpty()) {
            const auto r = getLocalArea(component, component->getLocalBounds());
            auto item = object();
            put(item, "x", r.getX()); put(item, "y", r.getY());
            put(item, "width", r.getWidth()); put(item, "height", r.getHeight());
            put(item, "enabled", component->isEnabled());
            if (auto *button = dynamic_cast<Button *>(component)) {
                put(item, "label", button->getButtonText());
                put(item, "selected", button->getToggleState());
            }
            put(modalControls, Identifier(component->getComponentID()), item);
        }
        for (auto *child : component->getChildren())
            self(self, child);
    };
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child)) {
            modalNames.add(sheet->getName());
            collectModalControls(collectModalControls, sheet);
        }
    put(value, "modalControls", modalControls);
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
    put(value, "resourceCPU", resourceUsage.cpu ? var(*resourceUsage.cpu) : var());
    put(value, "resourceRAM", resourceUsage.ram ? var(*resourceUsage.ram) : var());
    put(value, "resourceSamples", (int64)resourceUsage.samples);
    put(value, "resourceSampleIntervalSeconds", 1);
    put(value, "resourceMemoryScope", "process physical working set / installed physical RAM");
    put(value, "mixerDetached", mixerDetached);
    put(value, "trackMixerWidth", tracksViewport.getWidth());
    put(value, "setlistWidth", setlist->getWidth());
    put(value, "mixerDockHeight", footerMixer->getHeight());
    put(value, "currentSongDisplay", songDisplay.getText());
    put(value, "navigationVisible", navigation->isVisible());
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
                    put(value,"selectedItemGain",clip.gain.value_or(1));put(value,"selectedItemPan",clip.pan.value_or(0));
                    put(value,"selectedItemFadeIn",clip.fadeIn.value_or(0));put(value,"selectedItemFadeOut",clip.fadeOut.value_or(0));
                    put(value,"selectedItemEffects",clip.fxJSON ? get(JSON::parse(text(*clip.fxJSON)),"inserted") : var(Array<var>{}));
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
    auto invoked = object();
    for (const auto &entry : actionInvocations) put(invoked, Identifier(entry.first), entry.second);
    put(value, "actionInvocations", invoked);
    put(value, "contexts", contextCount);
    put(value, "wheelEvents", wheelCount);
    put(value, "timeline", timeline->state());
    put(value, "setlistScroll", setlist->scrollY());
    put(value, "setlist", setlist->diagnostics());
    put(value, "dirty", session.dirty);
    put(value, "nativeTitleBar", false);
    put(value, "uiRegressionPassed", uiRegressionPassed);
    auto layout = object();
    Array<var> clippedButtonLabels;
    for (const auto &entry : controls) {
        auto bounds = object();
        put(bounds, "x", entry.second->getX());
        put(bounds, "y", entry.second->getY());
        put(bounds, "width", entry.second->getWidth());
        put(bounds, "height", entry.second->getHeight());
        put(layout, Identifier(entry.first), bounds);
        if (entry.second->isVisible() && (bool)entry.second->getProperties()["centredIconLabel"]) {
            const auto font = theme::semiboldFont((float)entry.second->getProperties().getWithDefault("fontSize", 12.f));
            const auto width = entry.second->getWidth();
            const float padding = width < 56 ? 2.f : 6.f, gap = width < 56 ? 2.f : 4.f;
            if ((GlyphArrangement::getStringWidth(font, entry.second->getButtonText()) + 12.f + gap) * .75f > width - padding + .5f)
                clippedButtonLabels.add(entry.first);
        }
    }
    for (const auto *divider : {&mixerDivider, &setlistDivider, &footerHeightDivider, &mixerHeightDivider}) {
        auto b = object(); put(b, "x", divider->getX()); put(b, "y", divider->getY()); put(b, "width", divider->getWidth()); put(b, "height", divider->getHeight());
        put(layout, Identifier(divider->getComponentID()), b);
    }
    put(value, "controls", layout);
    put(value, "clippedButtonLabels", clippedButtonLabels);
    put(value, "grandMA2BeforeResolume",
        controls.at("grandma2")->getX() < controls.at("resolume")->getX());
    bool overlaps = false, outside = false;
    std::vector<const Component *> transportItems{tempoControl.get(), stageTimer.get(),
                                                  tuner.get(), &songDisplay, &transportTime, &transportInfo};
    for (const auto &entry : controls)
        if (entry.second->isVisible() && entry.second->getY() >= 32 &&
            entry.second->getBottom() <= transportBounds.getBottom() && entry.second->getX() >= 40)
            transportItems.push_back(entry.second);
    for (size_t a = 0; a < transportItems.size(); ++a) {
        outside = outside || !transportBounds.contains(transportItems[a]->getBounds());
        for (size_t b = a + 1; b < transportItems.size(); ++b)
            overlaps = overlaps || transportItems[a]->getBounds().intersects(transportItems[b]->getBounds());
    }
    put(value, "overlappingTransport", overlaps);
    put(value, "transportOutsideWindow", outside);
    put(value, "logicalWidth", getWidth());
    put(value, "logicalHeight", getHeight());
    put(value, "transportHeight", transportBounds.getHeight());
    put(value, "footerHeight", footerBounds.getHeight());
    put(value, "footerTop", footerBounds.getY());
    put(value, "footerBottom", footerBounds.getBottom());
    put(value, "footerDisplayTop", footerSongBounds.getY());
    put(value, "footerDisplayBottom", footerSongBounds.getBottom());
    put(value, "dockScrollable", dockContent.getHeight() > dockViewport.getHeight());
    put(value, "dockScrollY", dockViewport.getViewPositionY());
    put(value, "dockVisibleHeight", dockViewport.getHeight());
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
            w.keyPressed(KeyPress('Q'));
            w.keyPressed(KeyPress('R'));
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
void Workspace::openItemFX(ID id) {
    String name;
    if (const auto *song=session.song()) for(const auto &track:song->tracks) for(const auto &clip:track.clips)
        if(clip.id==id) name=text(clip.name);
    openFloating("FX - "+name, std::make_unique<EffectsPanel>(session,id,
        [safe=SafePointer<Workspace>(this)](String error){if(safe) safe->showError(error);},true),920,560);
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
