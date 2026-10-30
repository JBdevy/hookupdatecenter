#include "ConfirmationPanel.h"
#include "AudioPreparationOverlay.h"
#include "StemFolderImportPanel.h"
#include "Localization.h"
#include "TrackInstrumentPicker.h"
#include "ItemNamePanel.h"
#include "MIDIItemExport.h"
#include "AudioSeparation.h"
#include "AudioSeparationPanel.h"
#include "ProjectReductionPanel.h"
#include "MeterDisplay.h"
#include "SpecialTrackControls.h"
#include "MarkerRegionConversion.h"
#include "MarkerEditing.h"
#include "TempoMarkerPanel.h"
#include "TempoEditing.h"
#include "TeleprompterRemotePanel.h"
#include "StageContent.h"
#include "Workspace.h"
#include "Projection.h"
#include "PortablePackage.h"
#include "PortableExportPanel.h"
#include "ProjectSavePanel.h"
#include "TimelinePlaybackFollow.h"
#include "ProjectMigration.h"
#include "MissingMediaPanel.h"
#include "ValidationNoticePanel.h"
#include "ProjectOpenConfirmationPanel.h"
#include "RecordingProject.h"
#include "TrackDeletionConfirmationPanel.h"
#include "TimebaseConfirmationPanel.h"
#include "ImportNoticePanel.h"
#include "AdvancedPanel.h"
#include "SettingsPanel.h"
#include "StagePanels.h"
#include "StageTimerSettings.h"
#include "StagePreviewPanel.h"
#include "PatchPanel.h"
#include "AutomationPanel.h"
#include "EnvelopeLane.h"
#include "MetronomePanel.h"
#include "EffectsPanel.h"
#include "FloatingShortcuts.h"
#include "FooterAudioStatusButton.h"
#include "FXChain.h"
#include "PlaylistEditor.h"
#include "SetlistShareText.h"
#include "SetlistSearch.h"
#include "ProjectDeletionPanel.h"
#include "TrackTree.h"
#include "TrackVisibilityPanel.h"
#include "TrackEditing.h"
#include "ClickSoundDesigner.h"
#include "CreateTrackPanel.h"
#include "MediaDropPanel.h"
#include "GridMediaClipboard.h"
#include "ExportPanel.h"
#include "ModalSheet.h"
#include "SetlistBlockMIDIPanel.h"
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
#include "DottedGridPaint.h"
#include "TimelineMarqueeIndex.h"
#include "WindowControlButton.h"
#include "WaveformRenderer.h"
#include "RegionEditing.h"
#include "RegionLanes.h"
#include "TimelineRegionLabels.h"
#include "MultiLoopsPanel.h"
#include "CloseProjectSheet.h"
#include "UnifyRegionPanel.h"
#include "RecordingProjectStep.h"
#include "RecordingOptionsPanel.h"
#include "TransportFadeoutPanel.h"
#include "TransportFadeoutOverlay.h"
#include <BinaryData.h>
#include <fstream>
#include <windows.h>
#include "../../WindowsNative/Source/TransportButtons.h"
namespace catlive {
namespace {
String programHeadTitle(const jaras::ProgramChangeMarker &marker) {
    return marker.name.empty() ? "PC " + String(marker.program + 1) : text(marker.name);
}
float programHeadWidth(const jaras::ProgramChangeMarker &marker) {
    return std::ceil(GlyphArrangement::getStringWidth(theme::semiboldFont(10), programHeadTitle(marker))) + 10.f;
}
}
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
void MacLook::drawProgressBar(Graphics &g, ProgressBar &, int width, int height, double fraction, const String &) {
    theme::progressBar(g, {0.f, 0.f, float(width), float(height)}, fraction);
}
void MacLook::drawTooltip(Graphics &g,const String &text,int width,int height) {
    auto bounds=juce::Rectangle<float>(0,0,(float)width,(float)height).reduced(.5f);
    g.setColour(Colour(0xff353535)); g.fillRoundedRectangle(bounds,5);
    g.setColour(Colour(0xff707070)); g.drawRoundedRectangle(bounds,5,1);
    g.setColour(Colour(0xfff0f0f0)); g.setFont(theme::font(12));
    g.drawFittedText(text,juce::Rectangle<int>(width,height).reduced(7,4),Justification::centred,4,1.f);
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
        const bool active = b.getToggleState() || (bool)b.getProperties()["solidTransportColour"];
        const auto bounds = b.getLocalBounds().toFloat().reduced(.5f);
        g.setColour(active ? base : base.withAlpha(down ? .7f : .45f));
        g.fillRoundedRectangle(bounds, 6);
        if (!(bool)b.getProperties()["flat"]) {
            g.setColour(active ? base : Colours::white.withAlpha(.45f));
            g.drawRoundedRectangle(bounds, 6, 1);
        }
        return;
    }
    if ((bool)b.getProperties()["macMasterControl"]) {
        const bool compact = (bool)b.getProperties()["compactTrackStyle"];
        auto tint = b.findColour(b.getToggleState() ? TextButton::buttonOnColourId : TextButton::buttonColourId);
        if (down) tint = compact && b.getToggleState() ? tint.withMultipliedAlpha(.75f)
                          : Colours::white.withAlpha(compact ? .24f : .30f);
        if (!b.isEnabled()) tint = tint.withMultipliedAlpha(.35f);
        g.setColour(tint);
        g.fillRoundedRectangle(b.getLocalBounds().toFloat().reduced(.6f), 3.f);
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
    const auto icon = b.getProperties().getWithDefault("icon", {}).toString();
    g.setFont((bool)b.getProperties()["boldWeight"] ? theme::font(size, true)
              : (bool)b.getProperties()["mediumWeight"] ? theme::mediumFont(size) : theme::semiboldFont(size));
    const auto background=b.findColour(b.getToggleState()?TextButton::buttonOnColourId:TextButton::buttonColourId);
    const bool greenAction=background==theme::green || background==Colour(0xff60b746) ||
        background==Colour(0xff63b641) || background==Colour(0xff64b64a) ||
        background==Colour(0xff69b83d) || background==Colour(0xff60b53d);
    g.setColour(
        (greenAction?Colours::black:b.findColour(b.getToggleState() ? TextButton::textColourOnId : TextButton::textColourOffId))
            .withMultipliedAlpha(b.isEnabled() || icon == "pause" || b.getProperties().contains("transportColour") ? 1.0f : .35f));
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
        // Use the same rectangular cap and centre mark as the volume fader.
        // Reserve the bottom ten points for the pan readout.
        constexpr float middle = 7.f;
        g.setColour(Colours::white.withAlpha(.22f));
        g.fillRoundedRectangle((float)x, middle - 1.5f, (float)w, 3, 1.5f);
        g.setColour(Colours::white.withAlpha(.45f));
        g.fillRect(slider.getWidth() * .5f - .5f, middle - 5, 1.f, 10.f);
        g.setColour(Colour::greyLevel(.88f));
        g.fillRoundedRectangle(pos - 5, middle - 7, 10, 14, 2);
        g.setColour(Colour(0xff999999));
        g.drawVerticalLine((int)pos, middle - 5, middle + 5);
        g.setColour(Colours::white);
        g.setFont(theme::font(8));
        const double pan = slider.getValue();
        g.drawText(std::abs(pan) < .005
                       ? String("Center")
                       : String((int)std::round(std::abs(pan) * 100)) + (pan < 0 ? "% L" : "% R"),
                   0, 14, slider.getWidth(), 10, Justification::centred);
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
    if (slider.getComponentID().endsWith("Pan") && slider.isHorizontal())
        layout.sliderBounds = juce::Rectangle<int>(5, 0, std::max(1, slider.getWidth() - 10), 14);
    if (slider.getComponentID().endsWith("Volume"))
        layout.sliderBounds = slider.getLocalBounds().withTrimmedLeft(42).withTrimmedRight(8);
    return layout;
}
void MacLook::drawRotarySlider(Graphics &g, int x, int y, int w, int h, float fraction,
                              float start, float end, Slider &slider) {
    if (slider.getComponentID() != "mixerPan") {
        LookAndFeel_V4::drawRotarySlider(g, x, y, w, h, fraction, start, end, slider);
        return;
    }
    const auto bounds = slider.getLocalBounds().toFloat();
    const auto centre = bounds.getCentre();
    const float diameter = std::max(1.f, std::min(bounds.getWidth(), bounds.getHeight()) - 6);
    const auto circle = juce::Rectangle<float>(diameter, diameter).withCentre(centre);
    g.setColour(Colour::fromFloatRGBA(.18f, .18f, .18f, 1)); g.fillEllipse(circle);
    g.setColour(Colours::white.withAlpha(.35f)); g.drawEllipse(circle, 1);
    const float angle = (fraction * 270.f - 225.f) * MathConstants<float>::pi / 180.f;
    g.setColour(Colour(0xff30d158));
    g.drawLine(centre.x, centre.y, centre.x + std::cos(angle) * diameter * .4f,
               centre.y + std::sin(angle) * diameter * .4f, 2);
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
        title.setText(localization::translate(name), dontSendNotification);
        title.setFont(theme::font(20, true));
        subtitle.setText(localization::translate(description), dontSendNotification);
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
        l->setText(localization::translate(name), dontSendNotification);
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
        auto *b = new QuietButton(localization::translate(value));
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
        selectAll = &button(localization::translate("Selecionar tudo"), 24, 156, 125, [this] {
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
        midi.addItem(localization::translate(String::fromUTF8("Nenhuma saída MIDI")), 1);
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
        : Panel("Bem-vindo ao CatLive", "Use o e-mail e o CPF da sua compra."), auth(a), hasTrialOffer(offersTrial) {
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
                submissionRevision = auth.loginRevision;
                if (auth.requiresDeviceName) auth.completeDeviceNaming(deviceName->getText());
                else auth.beginLogin(email->getText(), cpf->getText());
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
        if (!offersTrial) trial->setButtonText(localization::translate("Fechar"));
        manage = &button("Gerenciar dispositivos", 30, 443, 380, [this] { devices(); });
        deviceName = &editor({}, 30, 325, 380, 30);
        deviceName->setComponentID("loginDeviceName");
        deviceName->setTextToShowWhenEmpty(localization::translate("Ex.: PC do palco"), theme::secondary);
        deviceName->setFont(theme::font(13));
        deviceName->onTextChange = [this] { update(); };
        deviceName->onReturnKey = [this] { login->triggerClick(); };
        back = &button(localization::translate("Voltar"), 30, 463, 80, [this] {
            submitted = false; auth.cancelDeviceNaming(); cpf->clear(); update();
        });
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
    ~LoginPanel() override { auth.cancelDeviceNaming(); }
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
        if (auth.requiresDeviceName) {
            stage->setVisible(false); trial->setVisible(false); email->setVisible(false);
            cpf->setVisible(false); manage->setVisible(false);
            title.setText(localization::translate("Nome deste dispositivo"), dontSendNotification);
            subtitle.setText(localization::translate(String::fromUTF8("Escolha um nome para identificar este PC na sua conta e na lista de conexão do iPad ou celular.")), dontSendNotification);
            subtitle.setBounds(30, 255, getWidth() - 60, 52);
            deviceName->setBounds(30, 325, getWidth() - 60, 30);
            login->setBounds(30, 383, 180, 42);
            back->setBounds(222, 383, 80, 42);
            message.setBounds(30, 443, getWidth() - 60, 76);
        } else {
            stage->setVisible(true); trial->setVisible(true);
            title.setText("Bem-vindo ao CatLive", dontSendNotification);
            subtitle.setText(hasTrialOffer ? String::fromUTF8("Use o e-mail e o CPF da sua compra.\nO trial começa no primeiro acesso neste dispositivo.") : "Use o e-mail e o CPF da sua compra.", dontSendNotification);
        }
        deviceName->setVisible(auth.requiresDeviceName);
        back->setVisible(auth.requiresDeviceName);
    }
    void update() {
        ModalSheet::blockDismiss(*this, auth.busy || auth.requiresDeviceName);
        const bool namingChanged = naming != auth.requiresDeviceName;
        naming = auth.requiresDeviceName;
        if (namingChanged && naming) { cpf->clear(); entering = true; }
        if (submitted && auth.loginRevision != submissionRevision && !auth.busy && auth.allowed() && !naming) { submitted = false; cpf->clear(); ModalSheet::dismiss(*this); }
        const bool credentials = email->getText().isNotEmpty() && cpf->getText().isNotEmpty();
        login->setEnabled(!auth.busy && (naming ? Auth::validatedDeviceName(deviceName->getText()).isNotEmpty() : credentials));
        back->setEnabled(!auth.busy);
        manage->setEnabled(!auth.busy && credentials);
        trial->setEnabled(!auth.busy);
        stage->setEnabled(!auth.busy);
        login->setButtonText(auth.busy ? localization::translate(String::fromUTF8("Aguarde…")) : naming ? localization::translate("Salvar e continuar") : localization::translate("Entrar"));
        message.setText(auth.busy ? localization::translate(String::fromUTF8("Validando acesso…")) : auth.message,
                        dontSendNotification);
        if (namingChanged) {
            if (layoutChanged) layoutChanged();
            resized();
            if (naming) deviceName->grabKeyboardFocus();
        }
    }

  private:
    Auth &auth;
    Image logo;
    TextEditor *email = nullptr, *cpf = nullptr, *deviceName = nullptr;
    TextButton *login = nullptr, *trial = nullptr, *stage = nullptr, *manage = nullptr, *back = nullptr;
    bool entering = false, submitted = false, naming = false, hasTrialOffer = true;
    uint64 submissionRevision = 0;
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
                        ConfirmationPanel::show(
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
    explicit LoginBackdrop(Auth &auth) : panel(auth, !auth.trialFinished) {
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
        g.setFont(theme::semiboldFont(11));
        g.setColour(Colours::white.withAlpha(.9f));
        g.drawText(String("CatLive Version ") + JUCE_APPLICATION_VERSION_STRING,
                   getWidth() - 302, 0, 154, getHeight(), Justification::centredRight);
        if (w.browserVisible || w.loginPanel)
            return;
        auto saved = Time::fromISO8601(text(w.session.project().updatedAt));
        auto project = text(w.session.project().name);
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
        peak=std::make_unique<meterDisplay::PeakReadout>([this]{return w.session.audio.heldPeak(id);},[this]{w.session.audio.clearPeak(id);},[this]{return track()?theme::surfaceText(theme::trackSurface(theme::track(*track()),w.trackSelected(id),track()->mute)):Colours::white;});addAndMakeVisible(*peak);
        record.setTooltip(String::fromUTF8("Gravação: desligada / armada / automática na pista "
                                           "selecionada. Clique direito: modo e monitoramento."));
        record.onClick = [this] { w.perform([&] { w.session.cycleRecordArm(id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}); }); };
        record.context = [this](Point<int>) {
            RecordingOptionsPanel::show(w.session, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}, record,
                [safe = SafePointer<Workspace>(&w)](String message) { if (safe) safe->showError(message); });
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
        phase.setTooltip("Inverter fase");
        output.setTooltip(String::fromUTF8("Roteamento de saída"));
        fx.setTooltip("Efeitos da pista");
        mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
        solo.setColour(TextButton::buttonOnColourId, theme::yellow);
        for (auto *b : {&mute, &solo, &phase, &fx, &output, &record}) {
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 10);
            b->setColour(TextButton::buttonColourId, Colours::white.withAlpha(.18f));
        }
        // Opaque Master grey keeps these controls neutral on every track colour.
        for (auto *b : {&mute, &solo, &fx, &output, &record})
            b->setColour(TextButton::buttonColourId, Colour(0xff414141));
        phase.setColour(TextButton::buttonOnColourId, theme::yellow);
        mute.onClick = [this] {
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::mute, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}); });
        };
        solo.onClick = [this] {
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::solo, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}); });
        };
        phase.onClick = [this] {
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::phase, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}); });
        };
        fx.onClick = [this] { w.openFX(id); };
        fxchain::bind(fx, w.session, id, [this](bool remove) { w.changeMixerFX(id, remove); });
        addAndMakeVisible(folder);
        folder.setWantsKeyboardFocus(false);
        folder.setComponentID("trackGroupAction");
        folder.getProperties().set("plain", true);
        folder.onClick = [this] {
            const auto *row=track();const auto *song=w.session.song();if(!row||!song)return;
            const auto project=w.session.project().id, songID=song->id, target=id;
            const auto parent=row->parentTrackID;
            w.confirm("Track group",parent?"Move this group out of its parent group?":"Dissolve this track group?",
                [safe=SafePointer<Workspace>(&w),project,songID,target,parent] {
                    if(!safe||safe->session.project().id!=project||!safe->session.song()||safe->session.song()->id!=songID)return;
                    const auto at=trackTree::index(*safe->session.song(),target);
                    if(at==safe->session.song()->tracks.size()||safe->session.song()->tracks[at].parentTrackID!=parent)return;
                    safe->perform([&]{safe->session.edit([&](jaras::Project &p){for(auto &song:p.songs)if(song.id==songID) {
                        if(parent)trackEditing::removeFromGroup(song,target);else trackEditing::ungroup(song,target);
                    }});});
                });
        };
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
        volume.backgroundDown=[this](const MouseEvent &e){mouseDown(e.getEventRelativeTo(this));};
        volume.backgroundDrag=[this](const MouseEvent &e){mouseDrag(e.getEventRelativeTo(this));};
        volume.backgroundUp=[this](const MouseEvent &e){mouseUp(e.getEventRelativeTo(this));};
        volume.setSliderStyle(Slider::LinearHorizontal);
        volume.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        volume.setDoubleClickReturnValue(true, 1);
        volume.setTooltip(String::fromUTF8("Volume · duplo clique = 0 dB"));
        volume.onDragStart = [this] { w.session.beginMixerGesture(jaras::CommandKind::volume, id); };
        volume.onDragEnd = [this] { w.session.endMixerGesture(); };
        volume.onValueChange = [this] {
            if (updating)
                return;
            w.perform(
                [&] { w.session.mixerCommand(jaras::CommandKind::volume, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}, volume.getValue()); });
        };
        addAndMakeVisible(pan);
        pan.setComponentID("trackPan");
        pan.setRange(-1, 1, .01);
        pan.setSliderStyle(Slider::LinearHorizontal);
        pan.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        pan.setDoubleClickReturnValue(true, 0);
        pan.setTooltip(String::fromUTF8("Pan · duplo clique = centro"));
        pan.setColour(Slider::trackColourId, theme::secondary);
        pan.onDragStart = [this] { w.session.beginMixerGesture(jaras::CommandKind::pan, id); };
        pan.onDragEnd = [this] { w.session.endMixerGesture(); };
        pan.onValueChange = [this] {
            if (updating)
                return;
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::pan, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}, pan.getValue()); });
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
    void refreshMixer() {
        if(const auto* t=track()) {
            const ScopedValueSetter<bool> guard(updating,true);
            volume.setValue(w.session.trackDisplayVolume(id,t->volume),dontSendNotification);
            volume.setEnabled(!w.session.trackFaderLocked(id));
            pan.setValue(t->pan,dontSendNotification);
            mute.setToggleState(t->mute,dontSendNotification);
            solo.setToggleState(t->solo,dontSendNotification);
            phase.setToggleState(t->phaseInverted.value_or(false),dontSendNotification);
            phase.setTooltip(t->phaseInverted.value_or(false)?"Fase invertida - Restaurar fase":"Inverter fase");
            if(special)special->refresh();
            repaint();
        }
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
            phase.setTooltip(t->phaseInverted.value_or(false) ? "Fase invertida - Restaurar fase" : "Inverter fase");
            env.setToggleState(!automation::visible(*t).isEmpty(), dontSendNotification);
            const int arm = w.session.recordArm(id);
            record.setVisible(jaras::fixedTrackName(t->role).empty());
            record.setButtonText(arm == 2 ? "A" : "");
            record.getProperties().set("icon", arm == 2 ? "" : "record.circle");
            record.getProperties().set("fontSize", arm == 2 ? 11 : 15);
            record.setToggleState(w.session.recordingArmed(id), dontSendNotification);
            record.setColour(TextButton::buttonOnColourId, Colour(0xffff1f1f));
            if (fxColourSource!=t->fxJSON) {
                fxColourSource=t->fxJSON;
                fxColour=fxchain::colour(t->fxJSON ? JSON::parse(text(*t->fxJSON)) : var());
            }
            fx.setColour(TextButton::textColourOffId, fxColour);
            record.setColour(TextButton::textColourOffId, Colour(0xffec4848));
            folder.setVisible(isFolder());
            folder.setTooltip(t->parentTrackID ? "Remove from group" : "Ungroup");
            folder.setButtonText({});
            folder.getProperties().set("icon",
                                       t->parentTrackID ? "folderNested" : "folderFilled");
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
    int iconWidth() const { return w.showsTrackIcons?40:0; }
    int bodyWidth() const { return getWidth()-iconWidth(); }
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
            const bool emphasized = w.trackSelected(id);
            const auto colour = theme::trackSurface(theme::track(*t), emphasized,
                w.session.song() ? trackTree::silenced(*w.session.song(), *t) : t->mute);
            g.setColour(colour);
            const auto lanes = automation::visible(*t);
            const int body = getHeight() - lanes.size() * 32;
            g.fillRect(indent, 0, bodyWidth() - indent, body - 1);
            if (emphasized) {
                g.setColour(Colours::white.withAlpha(.65f));
                g.drawRect((float)indent + .5f, .5f, (float)bodyWidth() - indent - 1, (float)body - 2, 1.f);
            }
            const float meterInset=body>=64?4.f:2.f;
            const auto levels = w.session.audio.meterLevels(id);
            for (int ch = 0; ch < (t->role.id=="programChange"?0:2); ++ch)
                meterDisplay::bar(g, {(float)indent + 2 + ch * 6.f, meterInset, 5, std::max(0.f,(float)body - 2*meterInset)}, levels[(size_t)ch]);
            if (body >= 64 && t->role.id!="vinhetas" && t->role.id!="programChange") {
                // Keep the audio bars and peak in place, with the Mac's four
                // points of clear space before MIDI and one before peak x21.
                g.setColour(Colours::black.withAlpha(.38f));
                g.fillRect(indent + 17, 4, 3, body - 8);
            }
            g.setFont(theme::semiboldFont(11));
            g.setColour(theme::surfaceText(colour));
            String number;
            if (const auto *song = w.session.song())
                number = String((int)trackTree::index(*song, id) + 1).paddedLeft('0', 2) + "  ";
            const bool expanded = body >= 64;
            const int titleX = indent + 24;
            const bool textTrack=jaras::isTeleprompterRole(t->role)||t->role.id=="chords";
            const int titleY = expanded ? (textTrack?3:47) : std::max(0, (body - 21) / 2);
            const int titleRight = textTrack&&special ? special->getX()-4 : expanded ? bodyWidth()-4 : (jaras::fixedTrackName(t->role).empty()?record.getX()-4:special?special->getX()-4:bodyWidth()-4);
            const auto scannedPC=t->role.id=="programChange"?w.session.scannedProgramChangePacket(id):uint64(0);
            const int scanWidth=scannedPC?88:0;
            g.drawText(number + text(t->name), titleX, titleY,
                       std::max(1, titleRight - titleX - scanWidth), expanded ? 16 : 21,
                       Justification::centredLeft, true);
            if(scannedPC) {
                g.setFont(theme::font(10));
                g.drawText("PC "+String(int(scannedPC&127)+1)+"  CH "+String(int((scannedPC>>7)&15)+1),
                           titleRight-scanWidth,titleY,scanWidth,expanded?16:21,Justification::centredRight);
            }
            for (int i = 0; i < lanes.size(); ++i) {
                const int y = body + i * 32;
                g.setColour(theme::background);
                g.fillRect(0, y, bodyWidth(), 32);
                g.setColour(Colours::white);
                g.setFont(theme::semiboldFont(11));
                g.drawText(str(lanes[i], "name"), 8, y, bodyWidth() - 90, 32,
                           Justification::centredLeft);
                g.setColour(flag(lanes[i], "enabled", true) ? theme::green : theme::secondary);
                g.drawEllipse((float)bodyWidth() - 78, y + 11.f, 10, 10, 1);
                g.setColour(theme::secondary);
                drawInterfaceIcon(g, "mixer", {(float)bodyWidth() - 56, y + 8.f, 16, 16});
                drawInterfaceIcon(g, "close", {(float)bodyWidth() - 26, y + 9.f, 14, 14});
            }
        }
        if(iconWidth()) {
            g.setColour(Colour(0xff202020));g.fillRect(bodyWidth(),0,iconWidth(),getHeight());
            g.setColour(theme::line);g.drawVerticalLine(bodyWidth(),0,(float)getHeight());
            if(const auto *t=track()) if(const auto *icon=trackIcons::find(t->instrumentIcon)) {
                const int body=getHeight()-automation::visible(*t).size()*32;
                const float size=std::max(0.f,std::min(32.f,(float)body-4));
                trackIcons::draw(g,*icon,{bodyWidth()+(40-size)/2,(body-size)/2,size,size});
            }
        }
        g.setColour(theme::line.withAlpha(.7f));
        g.drawHorizontalLine(getHeight() - 1, 0, (float)bodyWidth());
    }
    void resized() override {
        const auto *t = track();
        const int body = getHeight() - (t ? automation::visible(*t).size() * 32 : 0);
        const bool expanded = body >= 64;
        const int y = expanded ? 3 : std::max(0, (body - 21) / 2);
        const int h = expanded ? 24 : 21;
        int x = bodyWidth() - 4;
        auto place = [&](Component &control, int width) {
            x -= width; control.setBounds(x, y, width, h); x -= 3;
        };
        const bool standard=t&&jaras::fixedTrackName(t->role).empty();
        const bool textTrack=t&&(jaras::isTeleprompterRole(t->role)||t->role.id=="chords");
        const bool meterReadout = t && !textTrack && t->role.id != "timecode" && t->role.id != "programChange";
        // Match the Mac Track Mixer: the held peak belongs beside the meters,
        // centered on the volume fader, including nested track indentation.
        peak->setVisible(expanded&&meterReadout);
        peak->setBounds(groupIndent()+21, 31,43,12);
        record.setVisible(standard);
        for(auto *b:{&fx,&env,&output})b->setVisible(standard&&expanded);
        const bool audioButtons=standard||(t&&(t->role.id=="timecode"||t->role.id=="generatedClick"||t->role.id=="programChange"));
        mute.setVisible(audioButtons);solo.setVisible(audioButtons);
        if(solo.isVisible())place(solo,22);if(mute.isVisible())place(mute,22);
        if(special){special->setVisible(!standard);special->setBounds(std::max(22,x-(t&&t->role.id=="timecode"?116:t&&t->role.id=="generatedClick"?47:t&&t->role.id=="programChange"?159:108)),y,t&&t->role.id=="timecode"?116:t&&t->role.id=="generatedClick"?47:t&&t->role.id=="programChange"?159:108,textTrack?48:h);}
        pan.setVisible(expanded&&standard&&t->role.id!="vinhetas");
        if (pan.isVisible()) place(pan, 42);
        if(standard){env.setVisible(expanded&&t->role.id!="vinhetas");place(record,22);if(expanded){place(fx,22);if(env.isVisible())place(env,28);place(output,34);}}
        // Preserve the folder anchor even in deeply nested, narrow sidebars.
        // Keep the controls separate, matching the Mac layout's minimum origin.
        if(expanded && isFolder() && output.getX()<groupIndent()+51) {
            const int shift=groupIndent()+51-output.getX();
            for(auto *control:std::initializer_list<Component*>{&output,&env,&fx,&record,&pan,&mute,&solo})
                control->setTopLeftPosition(control->getX()+shift,control->getY());
        }
        folder.setBounds(groupIndent() + 20, y + (h - 20) / 2, 28, 20);
        folder.setVisible(expanded && isFolder());
        phase.setVisible(expanded&&standard&&t->role.id!="vinhetas"); volume.setVisible(expanded&&!textTrack&&t->role.id!="programChange");
        phase.setBounds(bodyWidth() - 26, 27, 22, 20);
        phase.getProperties().set("plain", true);
        const int volumeLeft = (meterReadout ? 68 : 22) + groupIndent();
        volume.setBounds(volumeLeft, 27, std::max(1, bodyWidth() - (standard ? 30 : 4) - volumeLeft), 20);
    }
    void mouseDown(const MouseEvent &e) override {
        if (auto *t = track()) {
            const auto lanes = automation::visible(*t);
            const int body = getHeight() - lanes.size() * 32;
            if (e.x < bodyWidth() && e.y >= body && lanes.size()) {
                const int index = jlimit(0, lanes.size() - 1, (e.y - body) / 32);
                if (e.x > bodyWidth() - 30 || e.x > bodyWidth() - 82 && e.x < bodyWidth() - 60) {
                    const auto curveID = str(lanes[index], "id");
                    const bool hide = e.x > bodyWidth() - 30;
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
        pendingSelection = w.trackSelected(id) && e.mods.isLeftButtonDown() && !e.mods.isShiftDown() && !e.mods.isCtrlDown() && !e.mods.isPopupMenu();
        if (!pendingSelection) w.selectMixerTrack(id, e.mods);
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
            pendingSelection=false;dragging=false;w.scrollingTrackDrag=id;w.startDragging(trackDrop::description(w.session.project(),*w.session.song(),id,w.selectedTracks),this);
        }
    }
    void mouseUp(const MouseEvent &e) override {if(pendingSelection&&e.getDistanceFromDragStart()<=8)w.selectMixerTrack(id,e.mods);pendingSelection=false;dragging=false;setMouseCursor(MouseCursor::NormalCursor);}
    bool isInterestedInDragSource(const SourceDetails &d) override {return w.session.song()&&!trackDrop::source(d.description,w.session.project(),*w.session.song()).empty();}
    void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
    void itemDragMove(const SourceDetails &d) override {
        if(!w.session.song())return;
        w.trackDropPreview=trackDrop::resolve(*w.session.song(),trackDrop::sources(d.description,w.session.project(),*w.session.song()),id,d.localPosition.y>getHeight()/2,d.localPosition.x<16);
        w.trackDropBlocked=w.trackDropPreview?ID{}:id;w.repaint();
    }
    void itemDragExit(const SourceDetails &) override {w.trackDropPreview.reset();w.trackDropBlocked.clear();w.repaint();}
    void itemDropped(const SourceDetails &d) override {
        itemDragMove(d);const auto destination=w.trackDropPreview;const ID song=w.session.song()?w.session.song()->id:ID{};
        itemDragExit(d);
        if(destination)w.perform([&]{w.session.editTrackHierarchy(song,[&](jaras::Song &s){trackDrop::apply(s,*destination,trackDrop::sources(d.description,w.session.project(),s));});});
    }

  private:
    Workspace &w;
    ID id;
    std::unique_ptr<SpecialTrackControls> special;
    std::unique_ptr<meterDisplay::PeakReadout> peak;
    QuietButton mute, solo, phase, fx, output, env, record;
    TextButton folder;
    GainFader volume;
    ParameterSlider pan;
    bool updating = false, dragging = false, pendingSelection = false;
    std::optional<std::string> fxColourSource;
    Colour fxColour=Colours::white;
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
    const jaras::Song *displaySong() const { return regionPreview ? &*regionPreview : w.session.song(); }
    const RegionLanes &regionLanes() const {
        if (regionLayoutRevision != w.session.revision) {
            regionLayout = RegionLanes(displaySong() ? displaySong()->parts : std::vector<jaras::Part>{});
            regionLayoutRevision = w.session.revision;
        }
        return regionLayout;
    }
    int regionHeight() const { return regionLanes().count * 16; }
    int headerHeight() const { return regionHeight() + 48; }
    std::optional<std::pair<double,double>> visualTimeRange() const {
        const auto &loop=w.session.transport().loop;
        if(loop.enabled && loop.start && loop.end && *loop.end>*loop.start)
            return std::pair<double,double>{*loop.start,*loop.end};
        return w.session.selectedTimeRange();
    }
    const ItemLanes *previewItemLanes(int index) const {
        return regionPreview && index >= 0 && index < (int)regionItemLayouts.size() ? &regionItemLayouts[(size_t)index] : nullptr;
    }
    void setRegionPreview(std::optional<jaras::Song> next) {
        if (!next && !regionPreview) return;
        const int oldHeader = headerHeight();
        std::vector<int> oldCounts;
        if (const auto *song = displaySong()) for (int i = 0; i < (int)song->tracks.size(); ++i)
            oldCounts.push_back(w.itemLanes(i).count);
        regionPreview = std::move(next);
        regionItemLayouts.clear();
        if (regionPreview) for (const auto &track : regionPreview->tracks) regionItemLayouts.emplace_back(track);
        regionLayoutRevision = markerRevision = ~uint64(0);
        bool layoutChanged = oldHeader != headerHeight();
        if (const auto *song = displaySong()) for (int i = 0; i < (int)song->tracks.size(); ++i)
            layoutChanged = layoutChanged || i >= (int)oldCounts.size() || oldCounts[(size_t)i] != w.itemLanes(i).count;
        if (layoutChanged) { w.resized(); updateRanges(); w.repaint(); }
        else invalidate();
    }
    void updateRanges() {
        canvas.invalidateSelectionLayout();
        const auto *s = displaySong();
        double length = s ? s->duration : 120;
        horizontal.setRangeLimits(
            0, std::max((double)canvas.getWidth(), length * w.pixelsPerSecond + 120));
        horizontal.setCurrentRange(horizontal.getCurrentRangeStart(), canvas.getWidth());
        vertical.setRangeLimits(
            0, std::max(canvas.getHeight() - headerHeight(), w.rowTop(s ? (int)s->tracks.size() : 0) + w.trackHeight * 2));
        vertical.setCurrentRange(w.verticalOffset, std::max(1, canvas.getHeight() - headerHeight()));
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
        envelopeContent.setBounds(0, headerHeight(), canvas.getWidth(),
                                  std::max(0, canvas.getHeight() - headerHeight()));
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
    void scrollVerticallyTo(int y) {
        vertical.setCurrentRangeStart(y,dontSendNotification);
        invalidate();
    }
    void refreshMixer(bool markersChanged = false) {
        // Pitch changes marker labels; ordinary mixer toggles retain their layout.
        const auto revision=w.session.revision;
        if(regionLayoutRevision+1==revision)regionLayoutRevision=revision;
        if(markersChanged)markerRevision=~uint64(0);
        else if(markerRevision+1==revision)markerRevision=revision;
        if(lanesRevision+1==revision)lanesRevision=revision;
        canvas.retainGeometryAfterStateChange();
        canvas.repaint();heads.repaint();
    }
    void refreshWaveforms() {
        bool layoutChanged = false;
        if (const auto *song = w.session.song())
            for (auto &item : w.session.recordingItems) {
                item.preview->drain();
                const double duration = std::max(1., (double)item.preview->frames.load(std::memory_order_acquire)) / item.preview->rate;
                for (size_t row = 0; row < song->tracks.size(); ++row) if (song->tracks[row].id == item.track) {
                    auto others = ItemLanes::references(song->tracks[row]);
                    for (const auto &take : w.session.recordingItems)
                        if (take.track == item.track) others.push_back(&take.clip);
                    layoutChanged |= ItemLanes::growRecordingClip(item.clip, duration, others);
                    if (!w.rowHidden((int)row))
                        canvas.repaint(0, headerHeight() + w.rowTop((int)row) - w.verticalOffset,
                                       canvas.getWidth(), w.rowBodyHeight((int)row));
                }
            }
        if (layoutChanged) {
            w.itemLayoutRevision = ~uint64(0);
            w.resized(); updateRanges(); w.repaint();
        }
        const auto current = waveforms.revision();
        if (current != waveformRevision) { waveformRevision = current; canvas.repaint(); }
    }
    void revealEditPosition() {
        if (w.session.transport().playing || w.session.transport().subPlay.playing) return;
        const double cursor = w.session.transport().editPosition * w.pixelsPerSecond;
        const double left = horizontal.getCurrentRangeStart();
        const double leftInset = std::min(14.0, cursor);
        const double rightLimit = std::max(14.0, canvas.getWidth() * (547.0 / 1003.0));
        if (cursor < left + leftInset - 0.5)
            horizontal.setCurrentRangeStart(std::max(0.0, cursor - leftInset), sendNotificationSync);
        else if (cursor > left + rightLimit + 0.5)
            horizontal.setCurrentRangeStart(std::max(0.0, cursor - rightLimit), sendNotificationSync);
    }
    void pausePlaybackFollow() { followPolicy.pause(w.session.presentationTransport()); }
    // Scroll and needles must share one device-clock observation. Sampling
    // again during paint moves the needle ahead of the transform, visibly even
    // at moderate zoom (and by hundreds of pixels at the maximum zoom).
    std::optional<jaras::TransportState> playbackFrame;
    bool followFramePending = false;
    void followPlayback() {
        playbackFrame = w.session.presentationTransport();
        followFramePending = true;
        const auto& state = *playbackFrame;
        if(followPolicy.isPaused(state))return;
        if (!w.appearance.continuousScroll() || !(state.playing || state.subPlay.playing)) { followPolicy.reset(); return; }
        if (gestureMode != 0 || Component::isMouseButtonDownAnywhere() || Component::getNumCurrentlyModalComponents() != 0) return;
        const double position = state.subPlay.playing ? state.subPlay.position : state.position;
        const auto *song=w.session.song();
        const String source=(song?text(song->id):String{})+(state.subPlay.playing?"-sub":"-main");
        const auto next=followPolicy.destination(position,w.pixelsPerSecond,horizontal.getMaximumRangeLimit(),
            horizontal.getCurrentRangeStart(),canvas.getWidth(),source,0);
        if(next)horizontal.setCurrentRangeStart(*next,sendNotificationSync);
    }
    void animate() {
        if(!followFramePending) playbackFrame = w.session.presentationTransport();
        followFramePending = false;
        const auto& state = *playbackFrame;
        playbackFrames.setRunning(isShowing() && (state.playing || state.subPlay.playing));
        const auto range=visualTimeRange();
        if(range!=lastVisualTimeRange){lastVisualTimeRange=range;canvas.repaint();}
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
    void updateZoomRange() {
        canvas.invalidateSelectionLayout();
        const auto *song = displaySong();
        horizontal.setRangeLimits(0, std::max((double)canvas.getWidth(),
            (song ? song->duration : 120) * w.pixelsPerSecond + 120), dontSendNotification);
        horizontal.setCurrentRange(horizontal.getCurrentRangeStart(), canvas.getWidth(), dontSendNotification);
    }
    void repaintZoom() {
        // Horizontal scale never changes track heights or automation row bounds.
        // Avoid rebuilding vertical ranges and walking the track tree per frame.
        for (auto *lane : lanes) if (lane->isVisible()) lane->repaint();
        canvas.repaint(); heads.repaint();
    }
    double zoomPosition() {
        const auto state = w.session.presentationTransport();
        return timelineZoomPosition(state, followPolicy.isPaused(state));
    }
    void applyCursorZoom(double scale, std::optional<double> screenAnchor = {}) {
        const double cursor = gestureZoomPosition.value_or(zoomPosition());
        w.pixelsPerSecond = jlimit(timelineGrid::minimumZoom, timelineGrid::maximumZoom, scale);
        w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
        updateZoomRange();
        horizontal.setCurrentRangeStart(timelineAnchoredZoomOffset(cursor, w.pixelsPerSecond,
            horizontal.getMaximumRangeLimit(), canvas.getWidth(), screenAnchor.value_or(canvas.getWidth()/2.)), dontSendNotification);
        repaintZoom();
    }
    void applyZoom(double scale, float anchor) {
        auto old = timeAt(anchor);
        w.pixelsPerSecond = jlimit(timelineGrid::minimumZoom, timelineGrid::maximumZoom, scale);
        w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
        updateZoomRange();
        horizontal.setCurrentRangeStart(old * w.pixelsPerSecond - anchor, dontSendNotification);
        repaintZoom();
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
    juce::Rectangle<int> regionHeaderBounds(const ID &id) const {
        if (const auto *song = displaySong()) for (const auto &part : song->parts) if (part.id == id) {
            const float left = std::max(0.f, xAt(part.startTime));
            const float right = std::min((float)canvas.getWidth(), xAt(part.endTime));
            return juce::Rectangle<float>(left, (float)(16*regionLanes().lane(id)), std::max(1.f, right-left), 16.f).getSmallestIntegerContainer();
        }
        return {0, 0, 1, 16};
    }
    var paintProfile() const {
        auto result=object();put(result,"zoom",w.pixelsPerSecond);put(result,"frames",(int64)paintCount);
        put(result,"lastMs",paintMilliseconds);put(result,"maxMs",maxPaintMilliseconds);
        put(result,"totalMs",totalPaintMilliseconds);Array<var> stages;for(auto value:paintStages)stages.add(value);put(result,"stages",stages);return result;
    }
    var state() const {
        auto v = object();
        if(const auto range=visualTimeRange()) {auto selection=object();put(selection,"start",range->first);put(selection,"end",range->second);put(v,"timeSelection",selection);}
        put(v, "horizontal", horizontal.getCurrentRangeStart());
        put(v, "horizontalScrollbarVisible", horizontal.isVisible());
        put(v, "waveforms", waveforms.diagnostics());
        put(v,"waveformRasterBuilds",(int64)canvas.overviewBuilds);
        put(v,"waveformRasterHits",(int64)canvas.overviewHits);
        put(v,"waveformRasterBytes",(int64)canvas.overviewBytes);
        Array<var> recording;
        for(const auto &item:w.session.recordingItems) {
            auto take=object();put(take,"name",text(item.clip.name));put(take,"frames",item.preview->frames.load());
            put(take,"peaks",(int)item.preview->history.size());
            float peak=0;for(const auto &bin:item.preview->history)for(int c=0;c<item.preview->channels;++c)peak=std::max(peak,std::max(std::abs(bin.low[c]),std::abs(bin.high[c])));
            put(take,"amplitude",peak);recording.add(take);
        }
        put(v,"recording",recording);
        put(v, "paintMilliseconds", paintMilliseconds);
        put(v, "maxPaintMilliseconds", maxPaintMilliseconds);
        put(v, "paintCount", (int64)paintCount);
        Array<var> stages;for(auto ms:paintStages) stages.add(ms);put(v,"paintStagesMilliseconds",stages);
        put(v, "vertical", vertical.getCurrentRangeStart());
        put(v, "zoom", w.pixelsPerSecond);
        if(playbackFrame)put(v,"framePlaybackPosition",playbackFrame->position);
        if(heads.hasPainted){put(v,"paintedMainNeedleX",heads.paintedMainX);put(v,"paintedMainPosition",heads.paintedMainPosition);}
        if(selectedHeaderRegion && selectedHeaderProject==w.session.project().id)put(v,"selectedHeaderRegion",text(*selectedHeaderRegion));
        put(v, "subCursorVisible", w.session.subCursorVisible());
        put(v, "gestureActive", gestureMode != 0);
        put(v, "trackHeight", w.trackHeight);
        put(v, "width", canvas.getWidth());
        put(v, "headerHeight", headerHeight());
        put(v, "regionLaneCount", regionLanes().count);
        Array<var> regions;
        if (const auto *song=displaySong()) {
          const auto parents=timelineRegionLabels::parents(*song);
          for (size_t index=0;index<song->parts.size();++index) {
            const auto &part=song->parts[index];
            if (part.parentRegionID) continue;
            auto region=object(), bounds=object();
            put(region,"id",text(part.id)); put(region,"lane",regionLanes().lane(part.id));
            put(region,"identifier",timelineRegionLabels::identifier(*song,index,parents));
            put(region,"start",part.startTime); put(region,"end",part.endTime);
            put(bounds,"x",getX()+xAt(part.startTime)); put(bounds,"y",getY()+16*regionLanes().lane(part.id));
            put(bounds,"width",std::max(1.f,xAt(part.endTime)-xAt(part.startTime))); put(bounds,"height",16);
            put(region,"bounds",bounds); regions.add(region);
          }
        }
        put(v,"regions",regions);
        Array<var> markerHeads;
        for (const auto &flag:markerFlags) {
            auto marker=object();put(marker,"id",text(flag.id));put(marker,"label",flag.label);put(marker,"width",flag.width);
            put(marker,"visibleWidth",timelineRegionLabels::markerHeadWidth(flag.position,flag.next,flag.regionEnd,flag.width,w.pixelsPerSecond));
            markerHeads.add(marker);
        }
        put(v,"markerHeads",markerHeads);
        Array<var> items;
        if (const auto *song=displaySong()) for(size_t row=0;row<song->tracks.size();++row) {
            if(w.rowHidden((int)row)) continue;
            const auto &track=song->tracks[row];
            for(const auto &clip:track.clips) {
                const auto geometry=w.itemGeometry((int)row,clip.id);
                const juce::Rectangle<float> r(xAt(clip.startTime),headerHeight()+w.rowTop((int)row)-w.verticalOffset+geometry.top+3,std::max(2.f,(float)(clip.duration*w.pixelsPerSecond)-2),geometry.height-6);
                if(!r.intersects(canvas.getLocalBounds().toFloat().withTrimmedTop((float)headerHeight()))) continue;
                const ItemHeader header(r,(float)canvas.getWidth(),track,clip,w.itemTitle(clip));
                auto item=object(); put(item,"id",text(clip.id));put(item,"track",text(track.id));put(item,"name",text(clip.name));put(item,"title",w.itemTitle(clip));put(item,"lane",w.itemLanes((int)row).lane(clip.id));
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
            if (!pan) gestureZoomPosition = zoomPosition();
            gestureTarget = pan ? horizontal.getCurrentRangeStart() : std::log(w.pixelsPerSecond);
        }
        gestureDirection = direction;

        gestureTarget = pan
            ? jlimit(0., std::max(0., horizontal.getMaximumRangeLimit() - horizontal.getCurrentRangeSize()), gestureTarget + delta)
            : jlimit(std::log(timelineGrid::minimumZoom), std::log(timelineGrid::maximumZoom), gestureTarget + delta);
        gestureOrigin = pan ? horizontal.getCurrentRangeStart() : std::log(w.pixelsPerSecond);
        if(!pan) gestureZoomScreenX=*gestureZoomPosition*w.pixelsPerSecond-horizontal.getCurrentRangeStart();
        lastGestureInput = now;
        if (!isTimerRunning()) { startTimerHz(60); timerCallback(); }
    }

  private:
    Workspace &w;
    class PlaybackFrames final : private Timer {
      public:
        explicit PlaybackFrames(Timeline &owner) : timeline(owner) {}
        void setRunning(bool running) {
            if(running && !isTimerRunning())startTimerHz(60);
            else if(!running)stopTimer();
        }
      private:
        Timeline &timeline;
        void timerCallback() override {
            if(!timeline.isShowing()){stopTimer();return;}
            timeline.followPlayback();timeline.animate();
        }
    } playbackFrames{*this};
    int gestureMode = 0, gestureDirection = 0;
    double gestureTarget = 0, gestureOrigin = 0, lastGestureInput = 0;
    std::optional<double> gestureZoomPosition;
    double gestureZoomScreenX = 0;

    void stopGesture() { stopTimer(); gestureMode = 0; gestureDirection = 0; gestureZoomPosition.reset(); }
    void timerCallback() override {
        if (!gestureMode) return;
        const auto now = Time::getMillisecondCounterHiRes();
        // A finite ease-out reaches one exact transform. An exponential tail
        // kept moving thin grid lines by fractions of a pixel after the wheel stopped.
        const double progress = jlimit(0., 1., (now - lastGestureInput) / 130.);
        const bool settled = progress >= 1.;
        const double eased = 1. - std::pow(1. - progress, 3.);
        const double next = settled ? gestureTarget : gestureOrigin + (gestureTarget - gestureOrigin) * eased;
        if (gestureMode == 1) {
            const double anchor=gestureZoomScreenX+(canvas.getWidth()/2.-gestureZoomScreenX)*eased;
            applyCursorZoom(std::exp(next),anchor);
        }
        else horizontal.setCurrentRangeStart(next);
        if (settled) stopGesture();
    }
    WaveformCache waveforms;
    uint64 waveformRevision = 0;
    struct MarkerFlag {ID id;double position=0,next=std::numeric_limits<double>::infinity(),regionEnd=std::numeric_limits<double>::infinity();String label;float width=0;unsigned colour=0;bool tempo=false,section=false,linked=false;};
    std::optional<std::pair<ID,double>> markerPreview;
    void previewMarker(std::optional<std::pair<ID,double>> value) { markerPreview=std::move(value); markerRevision=~uint64(0); invalidate(); }
    uint64 markerRevision=~uint64(0);
    std::vector<MarkerFlag> markerFlags;
    void refreshMarkers(const jaras::Song &song) {
        if(markerRevision==w.session.revision) return;
        markerFlags.clear();markerRevision=w.session.revision;
        if(song.markers) for(auto m:*song.markers) {
            if(markerPreview && markerPreview->first==m.id) m.position=markerPreview->second;
            MarkerFlag flag;flag.id=m.id;flag.position=m.position;flag.colour=m.color;flag.tempo=bool(m.tempoBPM);
            flag.section=!flag.tempo && m.section.value_or(false);flag.linked=bool(m.sourceRegionID || m.unifiedRegionID);
            flag.label=timelineRegionLabels::marker(song,m);
            flag.regionEnd=timelineRegionLabels::markerRegionEnd(song,m);
            flag.width=std::ceil(GlyphArrangement::getStringWidth(theme::mediumFont(9),flag.label))+10;
            markerFlags.push_back(std::move(flag));
        }
        std::stable_sort(markerFlags.begin(),markerFlags.end(),[](const auto &a,const auto &b){return a.position<b.position;});
        for(int type=0;type<2;++type) {
            double next=std::numeric_limits<double>::infinity();
            for(auto at=markerFlags.rbegin();at!=markerFlags.rend();++at) if(at->tempo==bool(type)) {
                at->next=next;next=at->position;
            }
        }
    }

    double paintMilliseconds = 0, maxPaintMilliseconds = 0, totalPaintMilliseconds = 0;
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
    std::optional<jaras::Song> regionPreview;
    std::vector<ItemLanes> regionItemLayouts;
    mutable RegionLanes regionLayout{std::vector<jaras::Part>{}};
    mutable uint64 regionLayoutRevision = ~uint64(0);
    ScrollBar horizontal, vertical;
    TimelinePlaybackFollowPolicy followPolicy;
    std::optional<ID> selectedHeaderRegion;
    ID selectedHeaderProject;
    Component envelopeContent;
    OwnedArray<EnvelopeLane> lanes;
    std::vector<std::pair<int, int>> lanePositions;
    uint64 lanesRevision = ~uint64(0);
    int lastMain = -100, lastSub = -100;
    float lastSubOpacity = 1;
    bool lastSubVisible = false;
    bool lastLoop = false;
    std::optional<std::pair<double,double>> lastVisualTimeRange;
    class Canvas final : public Component, private Timer {
      public:
        int headerHeight() const { return t.headerHeight(); }
        explicit Canvas(Timeline &timeline) : t(timeline) { setOpaque(true); setComponentID("timelineCanvas"); }
        void invalidateSelectionLayout() { selectionIndexRevision = ~uint64(0); }
        void retainGeometryAfterStateChange() {
            for(auto *revision:{&clipIndexRevision,&selectionIndexRevision,&itemSnapRevision,&waveformTimingRevision})
                if(*revision+1==t.w.session.revision)*revision=t.w.session.revision;
        }
        void resized() override { invalidateSelectionLayout(); }
        struct CachedWaveformTiming {double start,duration,offset,rate;ClipTempo timing;};
        std::map<ID,CachedWaveformTiming> waveformTimings;
        uint64 waveformTimingRevision=~uint64(0);
        std::unique_ptr<jaras::TempoEditMap::PlaybackRates> waveformTempo;
        const ClipTempo &waveformTiming(const jaras::AudioClip &clip,const jaras::Song &song) {
            if(waveformTimingRevision!=t.w.session.revision){waveformTimings.clear();waveformTimingRevision=t.w.session.revision;waveformTempo=std::make_unique<jaras::TempoEditMap::PlaybackRates>(song);}
            auto at=waveformTimings.find(clip.id);
            if(at==waveformTimings.end() || std::tie(at->second.start,at->second.duration,at->second.offset,at->second.rate)!=
                std::tie(clip.startTime,clip.duration,clip.sourceOffset,clip.playbackRate)) {
                if(at!=waveformTimings.end())waveformTimings.erase(at);
                at=waveformTimings.emplace(clip.id,CachedWaveformTiming{clip.startTime,clip.duration,clip.sourceOffset,clip.playbackRate,ClipTempo(clip,&song,waveformTempo.get())}).first;
            }
            return at->second.timing;
        }
        struct OverviewWaveform {
            Image image;
            const WaveformCache::Data *source=nullptr;
            String version;
            float width=0,height=0;
            double gain=0;
            uint32 colour=0;
            uint64 used=0;
            size_t bytes=0;
        };
        std::map<ID,OverviewWaveform> overviewWaveforms;
        uint64 overviewRevision=~uint64(0),overviewClock=0,overviewBuilds=0,overviewHits=0;
        double overviewZoom=0;
        float overviewScale=0;
        size_t overviewBytes=0;
        bool drawOverviewWaveform(Graphics &g,const std::shared_ptr<const WaveformCache::Data> &data,
            const jaras::AudioClip &clip,juce::Rectangle<float> rect,Colour ink,const jaras::Song &song) {
            // Derive width before the viewport subtraction. Subtracting two
            // rounded screen endpoints changes it by fractions every scroll frame.
            rect.setWidth(std::max(2.f,(float)(clip.duration*t.w.pixelsPerSecond)-2.f));
            const float physical=jlimit(1.f,8.f,g.getInternalContext().getPhysicalPixelScaleFactor());
            // At close zoom a long item can span billions of offscreen pixels.
            // Reject it before conversion/allocation and use the clipped live renderer.
            if(!std::isfinite(rect.getWidth()) || rect.getWidth()*physical>16384 ||
               !std::isfinite(rect.getHeight()) || rect.getHeight()*physical>4096)return false;
            const int width=(int)std::ceil(rect.getWidth()*physical)+2;
            const int height=(int)std::ceil(rect.getHeight()*physical)+2;
            const size_t bytes=(size_t)std::max(0,width)*(size_t)std::max(0,height)*4;
            constexpr size_t capacity=16*1024*1024;
            if(width<=0 || height<=0 || bytes>capacity/4)return false;
            // Detailed PCM pages arrive asynchronously; keep those live rather
            // than retaining an envelope rendered before the samples arrive.
            const auto &timing=waveformTiming(clip,song);
            for(const auto &span:timing.spans)
                if(data->sampleRate*std::max(.001,span.rate)/(t.w.pixelsPerSecond*physical)<=32)return false;
            if(overviewRevision!=t.w.session.revision || overviewZoom!=t.w.pixelsPerSecond || overviewScale!=physical) {
                overviewWaveforms.clear();overviewBytes=0;overviewRevision=t.w.session.revision;
                overviewZoom=t.w.pixelsPerSecond;overviewScale=physical;
            }
            const double gain=WaveformRenderer::gain(clip);
            auto found=overviewWaveforms.find(clip.id);
            if(found!=overviewWaveforms.end() && (found->second.source!=data.get() || found->second.version!=data->version ||
                found->second.width!=rect.getWidth() || found->second.height!=rect.getHeight() ||
                found->second.gain!=gain || found->second.colour!=ink.getARGB())) {
                overviewBytes-=found->second.bytes;overviewWaveforms.erase(found);found=overviewWaveforms.end();
            }
            if(found==overviewWaveforms.end()) {
                while(overviewBytes+bytes>capacity && !overviewWaveforms.empty()) {
                    const auto oldest=std::min_element(overviewWaveforms.begin(),overviewWaveforms.end(),
                        [](const auto &a,const auto &b){return a.second.used<b.second.used;});
                    overviewBytes-=oldest->second.bytes;overviewWaveforms.erase(oldest);
                }
                ++overviewBuilds;
                OverviewWaveform entry;
                entry.image=Image(Image::ARGB,width,height,true);entry.source=data.get();entry.version=data->version;
                entry.width=rect.getWidth();entry.height=rect.getHeight();entry.gain=gain;entry.colour=ink.getARGB();entry.bytes=bytes;
                Graphics thumbnail(entry.image);thumbnail.addTransform(AffineTransform::scale(physical));
                const auto local=rect.withPosition(1.f/physical,1.f/physical);
                WaveformRenderer::draw(thumbnail,t.waveforms,data,clip,local,
                    {0,0,width/physical,height/physical},t.w.pixelsPerSecond,ink,false,{},&song,&waveformTiming(clip,song));
                found=overviewWaveforms.emplace(clip.id,std::move(entry)).first;overviewBytes+=bytes;
            }
            else ++overviewHits;
            found->second.used=++overviewClock;
            // Stable audio previews of every width share this bounded raster cache.
            // Keep each source pixel on a device pixel during Continuous Scroll.
            // Resampling a dense click waveform at a different fractional phase
            // every frame makes its lower/upper edges appear to pulse.
            g.drawImageTransformed(found->second.image,AffineTransform::scale(1.f/physical)
                .translated(WaveformRenderer::pixelAlignedPosition(rect.getX(),physical)-1.f/physical,
                    WaveformRenderer::pixelAlignedPosition(rect.getY(),physical)-1.f/physical));
            return true;
        }
        void refreshClipIntervals(const jaras::Song &song) {
            const auto revision=t.w.session.revision;
            if(clipIndexSong==song.id && clipIndexRevision==revision && clipIndexes.size()==song.tracks.size())return;
            clipIndexSong=song.id;clipIndexRevision=revision;clipIndexes.clear();clipIndexes.reserve(song.tracks.size());
            for(const auto &track:song.tracks) {
                TrackClipIndex index;index.track=track.id;index.entries.reserve(track.clips.size());
                for(size_t clip=0;clip<track.clips.size();++clip)
                    index.entries.push_back({track.clips[clip].startTime,track.clips[clip].startTime+track.clips[clip].duration,clip});
                std::stable_sort(index.entries.begin(),index.entries.end(),[](const auto &a,const auto &b) {
                    return a.start==b.start?a.index<b.index:a.start<b.start;
                });
                index.maximumEnds.reserve(index.entries.size());double maximum=-std::numeric_limits<double>::infinity();
                for(const auto &entry:index.entries){maximum=std::max(maximum,entry.end);index.maximumEnds.push_back(maximum);}
                clipIndexes.push_back(std::move(index));
            }
        }
        std::vector<size_t> visibleClipIndices(int row,const jaras::Track &track,double from,double through) const {
            if(row<0 || row>=(int)clipIndexes.size() || clipIndexes[(size_t)row].track!=track.id) {
                std::vector<size_t> result;for(size_t i=0;i<track.clips.size();++i)
                    if(track.clips[i].startTime<=through && track.clips[i].startTime+track.clips[i].duration>=from)result.push_back(i);
                return result;
            }
            const auto &index=clipIndexes[(size_t)row];
            const auto end=std::upper_bound(index.entries.begin(),index.entries.end(),through,
                [](double value,const auto &entry){return value<entry.start;});
            const auto count=(size_t)std::distance(index.entries.begin(),end);
            const auto first=std::lower_bound(index.maximumEnds.begin(),index.maximumEnds.begin()+(ptrdiff_t)count,from);
            std::vector<size_t> result;result.reserve(count-(size_t)std::distance(index.maximumEnds.begin(),first));
            for(auto at=(size_t)std::distance(index.entries.begin(),index.entries.begin()+std::distance(index.maximumEnds.begin(),first));at<count;++at)
                if(index.entries[at].end>=from)result.push_back(index.entries[at].index);
            std::sort(result.begin(),result.end());
            return result;
        }
        void refreshPreviewPlacements(const jaras::Song &song) {
            previewPlacements.clear();
            refreshClipIntervals(song);
            struct Candidate { int row; const jaras::AudioClip *clip; };
            std::vector<Candidate> candidates;
            const bool groupMove=movingClipPreview && !resizeEdge && t.w.selectedClips.count(dragClip) && t.w.selectedClips.size()>1;
            if(groupMove) {
                const int rowDelta=previewRow-sourceRow;
                candidates.reserve(dragSelectionPreviews.size());
                for(const auto &entry:dragSelectionPreviews)
                    candidates.push_back({entry.row+rowDelta,&entry.preview});
            } else if(resizedClipPreview) candidates.push_back({sourceRow,&*resizedClipPreview});
            else if(movingClipPreview) candidates.push_back({previewRow,&*movingClipPreview});
            if(candidates.empty())return;

            const auto isExcluded=[&](const ID &id) {
                return groupMove ? t.w.selectedClips.count(id)>0 : id==dragClip;
            };
            std::map<int,std::vector<std::pair<double,double>>> ranges;
            for(const auto &[row,clip]:candidates)
                if(clip && row>=0 && row<(int)song.tracks.size())
                    ranges[row].push_back({clip->startTime,clip->startTime+clip->duration});
            if(groupMove) {
                for(const auto &entry:dragSelectionPreviews)
                    ranges[entry.row].push_back({entry.originalStart,entry.originalStart+entry.preview.duration});
            } else if(dragOriginalClip && sourceRow>=0 && sourceRow<(int)song.tracks.size())
                ranges[sourceRow].push_back({dragOriginalClip->startTime,dragOriginalClip->startTime+dragOriginalClip->duration});
            for(const auto &[row,seeds]:ranges) {
                const auto &track=song.tracks[(size_t)row];
                std::set<size_t> included;
                // Recompute only the overlap components affected by the move.
                // Use the same chronological placement as the committed layout.
                for(const auto &seed:seeds) {
                    double from=seed.first,through=seed.second;
                    bool expanded;
                    do {
                        expanded=false;
                        for(const auto index:visibleClipIndices(row,track,from,through)) {
                            const auto &other=track.clips[index];
                            if(isExcluded(other.id) || other.startTime>=through-1e-9 ||
                               other.startTime+other.duration<=from+1e-9)continue;
                            included.insert(index);
                            const double nextFrom=std::min(from,other.startTime),nextThrough=std::max(through,other.startTime+other.duration);
                            expanded=expanded || nextFrom<from || nextThrough>through;
                            from=nextFrom;through=nextThrough;
                        }
                        for(const auto &[candidateRow,clip]:candidates) {
                            if(candidateRow!=row || !clip || clip->startTime>=through-1e-9 ||
                               clip->startTime+clip->duration<=from+1e-9)continue;
                            const double nextFrom=std::min(from,clip->startTime),nextThrough=std::max(through,clip->startTime+clip->duration);
                            expanded=expanded || nextFrom<from || nextThrough>through;
                            from=nextFrom;through=nextThrough;
                        }
                    } while(expanded);
                }
                std::vector<const jaras::AudioClip*> local;
                local.reserve(included.size()+candidates.size());
                for(const auto index:included)local.push_back(&track.clips[index]);
                for(const auto &[candidateRow,clip]:candidates)if(candidateRow==row && clip)local.push_back(clip);
                const ItemLanes layout(std::move(local));
                previewPlacements.insert(layout.placements.begin(),layout.placements.end());
            }
        }
        ItemLanes::Geometry previewItemGeometry(int row,const jaras::AudioClip &clip) const {
            const auto placement=previewPlacements.find(clip.id);
            if(placement==previewPlacements.end())return t.w.itemGeometry(row,clip.id);
            const float body=(float)t.w.rowBodyHeight(row);
            const float height=body/(float)std::max(1,placement->second.count);
            return {placement->second.lane*height,height};
        }
        void paint(Graphics &g) override {
            const auto started = Time::getMillisecondCounterHiRes();
            auto measurePaint = [&] {
                if (t.w.capturingSnapshot) return;
                t.paintMilliseconds = Time::getMillisecondCounterHiRes() - started;
                t.maxPaintMilliseconds = std::max(t.maxPaintMilliseconds, t.paintMilliseconds);
                ++t.paintCount;t.totalPaintMilliseconds+=t.paintMilliseconds;
            };
            const ScopeGuard measure{measurePaint};
            auto stageStart=started;int stageIndex=0;
            auto stage=[&]{const auto now=Time::getMillisecondCounterHiRes();if(!t.w.capturingSnapshot && stageIndex<(int)t.paintStages.size())t.paintStages[(size_t)stageIndex]=now-stageStart;++stageIndex;stageStart=now;};
            const auto gridBackground = t.w.appearance.colour("jaras.timeline.background", 0x161616);
            g.fillAll(gridBackground);
            const auto *song = t.displaySong();
            if (!song)
                return;
            refreshClipIntervals(*song);
            std::set<ID> cutItems;
            if (t.w.itemClipboard && t.w.itemClipboard->moving && t.w.itemClipboard->song == song->id &&
                gridMediaClipboard::ownsItems(true, t.w.itemClipboardSequence, GetClipboardSequenceNumber()))
                for (const auto &track : t.w.itemClipboard->tracks)
                    for (const auto &clip : track.clips) cutItems.insert(clip.id);
            const auto viewStart = t.timeAt(0), viewEnd = t.timeAt((float)getWidth());
            g.setColour(theme::panel);
            g.fillRect(0, 0, getWidth(), headerHeight());
            g.setFont(theme::font(10));
            const auto grid = timelineGrid::ticks(*song, viewStart, viewEnd, t.w.pixelsPerSecond);
            const float pixel = 1.f / std::max(.01f, g.getInternalContext().getPhysicalPixelScaleFactor());
            // Share the items' fractional viewport transform. Snapping each
            // line to a physical pixel makes it step independently at low zoom.
            const auto lineX = [&](double time) { return t.xAt(time); };
            for (const auto &tick : grid) {
                const float x = lineX(tick.time);
                g.setColour(theme::green.withAlpha(.65f));
                g.fillRect(x, (float)t.regionHeight()+32, pixel, tick.primary ? 5.f : 3.f);
                if (tick.label.isNotEmpty()) {
                    g.setFont(theme::mediumFont(8.5f));
                    g.setColour(Colour(0xff54ff93));
                    g.drawText(tick.label, juce::Rectangle<float>(x + 3, (float)t.regionHeight()+32, 124, 16),
                               Justification::centredLeft);
                }
            }
            const bool showGrid = t.w.appearance.gridlines() &&
                (!song->timeSettings || song->timeSettings->divisions != 0);
            const auto drawGrid = [&](float top, float bottom) {
                if (!showGrid || bottom <= top) return;
                Graphics::ScopedSaveState gridState(g);
                const auto primary = t.w.appearance.colour("jaras.timeline.primaryGrid", 0x535250);
                const auto secondary = t.w.appearance.colour("jaras.timeline.secondaryGrid", 0x333235).withAlpha(.85f);
                for (const auto &tick : grid) {
                    auto &pattern=tick.primary?primaryGridPattern:secondaryGridPattern;
                    pattern.draw(g,tick.primary?primary:secondary,lineX(tick.time),top,bottom,pixel,(float)headerHeight());
                }
            };
            drawGrid((float)headerHeight(), (float)getHeight());
            stage();
            t.refreshMarkers(*song);
            for(const auto &m:t.markerFlags) {
                const float x=t.xAt(m.position);
                if(x>getWidth()) break;
                const float width=timelineRegionLabels::markerHeadWidth(m.position,m.next,m.regionEnd,m.width,t.w.pixelsPerSecond);
                if(width<18 || x+width<0) continue;
                const juce::Rectangle<float> flag(x,(float)t.regionHeight()+(m.tempo?17.f:1.f),width,14);
                if(m.tempo) {
                    g.setColour(theme::display);g.fillRoundedRectangle(flag.reduced(.5f),4);
                    g.setColour(theme::line);g.drawRoundedRectangle(flag.reduced(.5f),4,1);
                } else {
                    g.setColour(Colour(0xff000000|m.colour));
                    if(m.section) {
                        const float inset=std::min(7.f,flag.getWidth()/2);
                        Path head;head.startNewSubPath(flag.getX(),flag.getCentreY());
                        head.lineTo(flag.getX()+inset,flag.getY());head.lineTo(flag.getRight(),flag.getY());
                        head.lineTo(flag.getRight(),flag.getBottom());head.lineTo(flag.getX()+inset,flag.getBottom());
                        head.closeSubPath();g.fillPath(head);
                    } else if(m.linked) {
                        g.fillRoundedRectangle(flag.reduced(.6f),3);
                        g.setColour(theme::yellow);g.drawRoundedRectangle(flag.reduced(.6f),3,1.2f);
                    } else g.fillRect(flag);
                }
                g.setColour(m.tempo?Colours::white:Colours::black);g.setFont(theme::mediumFont(9));
                g.drawText(m.label,flag.reduced(4,0),m.tempo?Justification::centred:Justification::centredLeft,true);
            }
            const auto parentRegions=timelineRegionLabels::parents(*song);
            for (size_t index=0;index<song->parts.size();++index) {
                const auto &p=song->parts[index];
                if (p.parentRegionID) continue;
                float a = t.xAt(p.startTime), b = t.xAt(p.endTime);
                if (b < 0 || a > getWidth())
                    continue;
                g.setColour(Colour(0xff000000 | p.color.value_or(0x665566)));
                const int laneTop = t.regionLanes().lane(p.id) * 16;
                g.fillRect(a, (float)laneTop, std::max(1.f, b - a), 16.f);
                g.setColour(Colours::white);
                const auto identifier=timelineRegionLabels::identifier(*song,index,parentRegions);
                const auto identifierFont=theme::semiboldFont(9);
                const auto identifierWidth=std::ceil(GlyphArrangement::getStringWidth(identifierFont,identifier));
                if (b-a>=identifierWidth+8) {
                    Graphics::ScopedSaveState scope(g);
                    g.reduceClipRegion(juce::Rectangle<float>(a,(float)laneTop,std::max(1.f,b-a),16.f).getSmallestIntegerContainer());
                    g.setFont(identifierFont);
                    g.drawText(identifier,juce::Rectangle<float>(b-4-identifierWidth,(float)laneTop+2,identifierWidth,12),
                               Justification::centredRight,false);
                    const auto nameWidth=b-a-identifierWidth-16;
                    if (nameWidth>=10) {
                        g.setFont(theme::semiboldFont(9));
                        g.drawText(timelineRegionLabels::displayName(p),
                                   juce::Rectangle<float>(a+4,(float)laneTop+2,nameWidth,12),Justification::centredLeft,true);
                    }
                }
                if(t.selectedHeaderRegion==p.id && t.selectedHeaderProject==t.w.session.project().id) {
                    g.setColour(Colours::white);
                    g.drawRect(juce::Rectangle<float>(a,(float)laneTop,std::max(1.f,b-a),16.f).reduced(.75f),1.5f);
                }
            }
            g.setColour(theme::line);
            for (int lane = 0; lane <= t.regionLanes().count; ++lane)
                g.drawHorizontalLine(lane * 16, 0, (float)getWidth());
            for (int y : {t.regionHeight()+16, t.regionHeight()+32, headerHeight()-1})
                g.drawHorizontalLine(y, 0, (float)getWidth());
            stage();
            g.saveState();
            g.reduceClipRegion(0, headerHeight(), getWidth(), getHeight() - headerHeight());
            int rowTop = 0;
            for (size_t row = 0; row < song->tracks.size(); ++row) {
                if (t.w.rowHidden((int)row))
                    continue;
                const int height = t.w.rowBodyHeight((int)row);
                const int y = headerHeight() + rowTop - t.w.verticalOffset;
                rowTop += height + 32 * (int)automation::visible(song->tracks[row]).size();
                if (y + height < headerHeight() || y > getHeight())
                    continue;
                if (!g.clipRegionIntersects({0, y - 3, getWidth(), height + 6})) continue;
                const auto &track = song->tracks[row];
                const bool trackMuted=trackTree::silenced(*song,track);
                // Unselected rows already have this background and grid from the
                // canvas pass. Only the selected row needs a different fill.
                if(t.w.trackSelected(track.id)) {
                    // Match the Mac's 0x16 -> 0x1d highlight, relative to the
                    // chosen grid colour. A fixed panel colour disappears when
                    // the user sets the grid itself to (or near) 0x1d1d1d.
                    const int step = gridBackground.getPerceivedBrightness() > .8f ? -7 : 7;
                    const auto channel = [step](uint8 value) { return (uint8)jlimit(0, 255, (int)value + step); };
                    g.setColour(Colour(channel(gridBackground.getRed()), channel(gridBackground.getGreen()),
                                       channel(gridBackground.getBlue())));
                    g.fillRect(0,y,getWidth(),height);
                    drawGrid((float)y,(float)(y+height));
                }
                g.setColour(theme::line.withAlpha(.8f));
                g.drawHorizontalLine(y + height - 1, 0, (float)getWidth());
                const ProgramChangeLanes stacks(track);
                if(track.role.id=="programChange")for(const auto &marker:track.programChanges) {
                    const float markerY=float(y+4+stacks.lanes.at(marker.id)*24);
                    const float x=t.xAt(marker.position), headWidth=timelineRegionLabels::programChangeHeadWidth(*song,marker.position,programHeadWidth(marker),t.w.pixelsPerSecond);
                    if(x+headWidth<0 || x>getWidth())continue;
                    const auto colour=trackMuted?theme::secondary:Colour(0xff91a8ff);
                    g.setColour(colour);g.fillRect(x,markerY,1.f,float(y+height-4)-markerY);
                    if(headWidth<=0)continue;
                    const juce::Rectangle<float> head(x,markerY,headWidth,19);
                    if(t.w.session.selectedProgramChange==marker.id)g.setColour(theme::green);
                    g.fillRoundedRectangle(head,4);g.setColour(Colours::black);g.setFont(theme::semiboldFont(10));
                    g.drawText(programHeadTitle(marker),head.reduced(5,0),Justification::centredLeft);
                }
                const bool groupMove = movingClipPreview && !resizeEdge && t.w.selectedClips.count(dragClip) && t.w.selectedClips.size()>1;
                std::vector<const jaras::AudioClip*> movingClips;
                const double visibleStart=viewStart-9/t.w.pixelsPerSecond, visibleEnd=viewEnd+9/t.w.pixelsPerSecond;
                const auto visibleIndices=visibleClipIndices((int)row,track,visibleStart,visibleEnd);
                bool resizedPreviewIncluded=false;
                for(const auto clipIndex:visibleIndices) {
                    const auto &clip=track.clips[clipIndex];
                    if(groupMove && t.w.selectedClips.count(clip.id))continue;
                    if(!groupMove && movingClipPreview && clip.id==movingClipPreview->id)continue;
                    if(resizedClipPreview && clip.id==resizedClipPreview->id) {
                        movingClips.push_back(&*resizedClipPreview);resizedPreviewIncluded=true;
                    } else movingClips.push_back(&clip);
                }
                const bool movingHere = !groupMove && movingClipPreview && previewRow == (int)row;
                const bool resizedHere = !groupMove && resizedClipPreview && sourceRow == (int)row && !resizedPreviewIncluded &&
                    resizedClipPreview->startTime <= visibleEnd && resizedClipPreview->startTime + resizedClipPreview->duration >= visibleStart;
                if(groupMove) {
                    const int rowDelta=previewRow-sourceRow;
                    for(const auto &entry:dragSelectionPreviews)
                        if(entry.row+rowDelta==(int)row && entry.preview.startTime<=visibleEnd &&
                           entry.preview.startTime+entry.preview.duration>=visibleStart)
                            movingClips.push_back(&entry.preview);
                }
                const size_t renderedClipCount=movingClips.size();
                const jaras::AudioClip *transientClip=movingHere?&*movingClipPreview:resizedHere?&*resizedClipPreview:nullptr;
                for (size_t itemIndex = 0; itemIndex < renderedClipCount + (transientClip ? 1 : 0); ++itemIndex) {
                    const bool movedItem = itemIndex == renderedClipCount;
                    const auto &sourceClip = movedItem ? *transientClip : *movingClips[itemIndex];
                    if (!groupMove && !movedItem && movingClipPreview && sourceClip.id == movingClipPreview->id) continue;
                    const jaras::AudioClip *clipValue=&sourceClip;
                    std::optional<jaras::AudioClip> editedClip;
                    std::optional<double> gainOverride;
                    std::optional<bool> mutedOverride;
                    const bool controlApplies=controlClip && (controlClip->id==sourceClip.id ||
                        (sharedControl() && controlSelection.count(sourceClip.id)));
                    if(controlApplies && controlKind==ItemHeader::gain) {
                        gainOverride=controlClip->gain.value_or(1);
                    } else if(controlApplies && controlKind==ItemHeader::pan) {
                        // The waveform and source identity remain the original item's.
                    } else if(controlApplies && controlKind==ItemHeader::mute) {
                        if(controlKind==ItemHeader::mute) mutedOverride=controlClip->muted;
                    } else if(controlApplies && controlKind!=ItemHeader::pan) {
                        editedClip=*clipValue;
                        if(controlClip->id==sourceClip.id) {
                            editedClip->fadeIn=controlClip->fadeIn; editedClip->fadeOut=controlClip->fadeOut;
                            editedClip->fadeInCurve=controlClip->fadeInCurve; editedClip->fadeInSCurve=controlClip->fadeInSCurve;
                            editedClip->fadeOutCurve=controlClip->fadeOutCurve; editedClip->fadeOutSCurve=controlClip->fadeOutSCurve;
                        } else applySelectedControl(*editedClip,*controlClip);
                        clipValue=&*editedClip;
                    }
                    const auto &clip = *clipValue;
                    float left = t.xAt(clip.startTime),
                          right = t.xAt(clip.startTime + clip.duration);
                    if (right < 0 || left > getWidth())
                        continue;
                    const auto geometry=previewItemGeometry((int)row,clip);
                    const float itemHeight = geometry.height;
                    const float itemY = y + geometry.top;
                    auto colour = theme::track(track);
                    auto rect = juce::Rectangle<float>(
                        left, itemY + 3.f, std::max(2.f, right - left - 2), itemHeight - 6.f);
                    if (!g.clipRegionIntersects(rect.expanded(3.f).getSmallestIntegerContainer())) continue;
                    const bool muted = trackMuted || mutedOverride.value_or(clip.muted);
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
                    const auto outline=itemOutline(clip,rect,(float)getWidth(),t.w.pixelsPerSecond,
                        clip.loopLength?&waveformTiming(clip,*song):nullptr);
                    // Overview items have square corners and no visible controls.
                    // A path clip creates an alpha mask for every tiny item; avoid
                    // hundreds of those masks while retaining shaped loop/fade edges.
                    const bool simpleOverview=compact && (clip.audioFile || track.audioFile) && !clip.text && !clip.midi &&
                        clip.fadeIn.value_or(0)<=0 && clip.fadeOut.value_or(0)<=0 &&
                        (!clip.loopLength || itemLoopSeams(clip,rect,(float)getWidth(),t.w.pixelsPerSecond,&waveformTiming(clip,*song)).empty());
                    g.setColour(colour);
                    if(simpleOverview)g.fillRect(rect);else g.fillPath(outline);
                    if(!selected && !compact) {g.setColour(colour.withAlpha(.75f));g.strokePath(outline,PathStrokeType(.6f));}
                    g.saveState();
                    if(simpleOverview)g.reduceClipRegion(rect.getSmallestIntegerContainer());else g.reduceClipRegion(outline);
                    const ItemHeader header(rect,(float)getWidth(),track,clip,t.w.itemTitle(clip));
                    if(!compact) {
                        g.setColour(Colour(0xff484848));g.fillRect(rect.withHeight(std::min(17.f,rect.getHeight())));
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
                        g.setColour(Colour::greyLevel(waveGray));g.fillPath(pulses);g.restoreState();
                    } else if (!clip.text && (!clip.midi || clip.frozenMIDI.value_or(false))) {
                        const auto &source = clip.audioFile ? clip.audioFile : track.audioFile;
                        const auto data = source ? t.waveforms.request(t.waveformFile(source->path)) : nullptr;
                        if (data) {
                            const auto ink=Colour::greyLevel(waveGray);
                            const bool overview=t.gestureMode==0 && !controlApplies && !movingClipPreview && !resizedClipPreview && !t.regionPreview;
                            if(!overview || !drawOverviewWaveform(g,data,clip,rect,ink,*song))
                                WaveformRenderer::draw(g, t.waveforms, data, clip, rect,
                                    getLocalBounds().toFloat(), t.w.pixelsPerSecond, ink, false, gainOverride,song,&waveformTiming(clip,*song),
                                    controlApplies && controlKind==ItemHeader::pan ? controlClip->pan : std::nullopt);
                        } else if (!source) {
                            // Legacy/generated items may contain their own overview.
                            // Never substitute these coarse peaks for pending real PCM.
                            const int channels = std::max(1, (int)clip.waveformChannels.size());
                            const float top = rect.getY() + 18.f;
                            const float laneHeight = std::max(1.f, rect.getBottom() - top - 2.f) / channels;
                            const float baseAmplitude = WaveformRenderer::fullScale(laneHeight) * (float)WaveformRenderer::gain(clip,gainOverride);
                            g.setColour(Colour::greyLevel(waveGray));
                            for (int channel = 0; channel < channels; ++channel) {
                                const auto pan = controlApplies && controlKind==ItemHeader::pan ? controlClip->pan : clip.pan;
                                const float amplitude = baseAmplitude * (float)WaveformRenderer::panGain(pan.value_or(0), channel, channels);
                                const auto &embedded = clip.waveformChannels.empty() ? clip.waveform : clip.waveformChannels[(size_t)(clip.channelMode.value_or(0)==4 && channels>1 && channel<2 ? 1-channel : channel)];
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
                    if(!simpleOverview)header.drawFades(g,clip);
                    g.restoreState();
                    // Text goes directly onto the opaque canvas, outside the
                    // alpha geometry layer used to clip waveform/fade corners.
                    // Rectangular clipping keeps the native ClearType renderer.
                    if(!compact) {
                        Graphics::ScopedSaveState textClip(g);
                        g.reduceClipRegion(rect.getSmallestIntegerContainer());
                        header.draw(g,clip,gainOverride,controlApplies && controlKind==ItemHeader::pan ? controlClip->pan : std::nullopt);
                        const float headerRight=header.visible.getRight(),nameLeft=header.titleLeft;
                        if(headerRight-nameLeft>=12) {
                            g.setFont(theme::semiboldFont(9));g.setColour(selected ? theme::yellow : Colours::white.withAlpha(track.mute?.5f:.95f));
                            g.drawText(t.w.itemTitle(clip),juce::Rectangle<float>(nameLeft,rect.getY(),headerRight-nameLeft-3,17),Justification::centredLeft,true);
                        }
                        if(clip.text && !clip.text->empty() && right-left>=24) {
                            g.setFont(theme::font(14));g.setColour(Colours::white);
                            if((text(*clip.text).startsWith(ItemTextColors::prefix()) || text(*clip.text).startsWith(ItemTextColors::columnsPrefix())))
                                ItemTextColors::draw(g,text(*clip.text),{left+6,(float)itemY+23,std::max(1.f,right-left-12),std::max(1.f,(float)itemHeight-28)},theme::font(14),Colours::white,Justification::centred);
                            else g.drawFittedText(text(*clip.text),(int)left+6,(int)itemY+23,
                                std::max(1,(int)(right-left)-12),std::max(1,(int)itemHeight-28),
                                Justification::centred,std::max(1,((int)itemHeight-28)/16),.5f);
                        }
                    }
                    if(selected) {
                        g.setColour(Colours::black);g.strokePath(outline,PathStrokeType(.8f));
                        g.setColour(Colour(0xff80ff9c));g.strokePath(outline,PathStrokeType(.7f));
                    }
                    if (cutItems.count(clip.id)) {
                        g.setColour(t.w.appearance.colour("jaras.timeline.background", 0x161616).withAlpha(.55f));
                        g.fillRoundedRectangle(rect, 3.f);
                    }
                }
                for (const auto &item : t.w.session.recordingItems) if (item.track == track.id) {
                    const auto &preview = *item.preview;
                    const double duration = preview.frames.load(std::memory_order_acquire) / preview.rate;
                    const float left = t.xAt(item.clip.startTime);
                    const float right = t.xAt(item.clip.startTime + duration);
                    if (right < 0 || left > getWidth()) continue;
                    const auto geometry=t.w.itemGeometry((int)row,item.clip.id);
                    const float height = geometry.height;
                    const float top = y + geometry.top;
                    auto rect = juce::Rectangle<float>(left, top + 3.f, std::max(2.f, right-left-2), height-6.f);
                    g.saveState();
                    Path outline; outline.addRoundedRectangle(rect, 3.f);
                    g.reduceClipRegion(outline);
                    g.setColour(theme::track(track)); g.fillRect(rect);
                    // Compact recording lanes still need room for their waveform.
                    const float titleHeight = std::min(17.f, rect.getHeight() * .35f);
                    g.setColour(Colours::darkred); g.fillRect(rect.withHeight(titleHeight));
                    const auto body = rect.withTrimmedTop(titleHeight + 1).withTrimmedBottom(1);
                    if (body.getHeight() > 0) {
                        g.reduceClipRegion(body.getSmallestIntegerContainer());
                        const float laneHeight = body.getHeight()/preview.channels;
                        const double firstFrame = std::max(0., (t.timeAt(0)-item.clip.startTime)*preview.rate);
                        auto begin = std::lower_bound(preview.history.begin(), preview.history.end(), firstFrame,
                            [](const RecordingPreview::Peak &peak, double frame) { return peak.end < frame; });
                        const auto colour = theme::track(track);
                        const float luminance = .2126f*colour.getFloatRed()+.7152f*colour.getFloatGreen()+.0722f*colour.getFloatBlue();
                        g.setColour(Colour::greyLevel(luminance > .68f ? .3f : .92f));
                        for (int channel = 0; channel < preview.channels; ++channel) {
                            Path peaks;
                            int column = -1; float low = 0, high = 0, endColumn = 0;
                            const float middle = body.getY()+laneHeight*(channel+.5f), amplitude = WaveformRenderer::fullScale(laneHeight);
                            auto emit = [&] {
                                if (column >= 0) peaks.addRectangle((float)column, middle-high*amplitude,
                                    std::max(1.f, endColumn-column), std::max(1.f, (high-low)*amplitude));
                            };
                            for (auto peak = begin; peak != preview.history.end(); ++peak) {
                                const float x = t.xAt(item.clip.startTime + peak->start/preview.rate);
                                if (x > getWidth()) break;
                                const int next = std::max(0, (int)std::floor(x));
                                if (next != column) { emit(); column=next; low=high=0; }
                                endColumn=std::min((float)getWidth(),t.xAt(item.clip.startTime + peak->end/preview.rate));
                                low=std::min(low, peak->low[(size_t)channel]);
                                high=std::max(high, peak->high[(size_t)channel]);
                            }
                            emit(); g.fillPath(peaks);
                        }
                    }
                    g.restoreState();
                    g.setColour(Colours::white); g.setFont(theme::semiboldFont(9));
                    const auto visibleTitle = rect.withHeight(titleHeight).getIntersection(
                        juce::Rectangle<float>(0, rect.getY(), (float)getWidth(), titleHeight));
                    g.drawText(text(item.clip.name), visibleTitle.reduced(4,0), Justification::centredLeft, true);
                }
            }
            g.restoreState();
            stage();
            for (const auto &region : song->parts) {
                if (region.parentRegionID) continue;
                const auto colour = Colour(0xff000000 | region.color.value_or(0x705264));
                const float left = lineX(region.startTime), right = lineX(region.endTime), top = (float)(t.regionLanes().lane(region.id)+1)*16;
                g.saveState();
                g.reduceClipRegion(juce::Rectangle<float>(left, top, std::max(0.f, right-left), std::max(0.f, getHeight()-top)).getSmallestIntegerContainer());
                for (const auto spec : {std::pair<float,float>{6,.14f}, {3,.30f}, {2,1.f}}) {
                    g.setColour(colour.withAlpha(spec.second));
                    for (int side=0; side<2; ++side) {
                        const float x=side==0?left:right-pixel*.5f;
                        if (x >= -6 && x <= getWidth()+6)
                            g.fillRect(x-spec.first/2, top, spec.first, getHeight()-top);
                    }
                }
                g.restoreState();
            }
            if (song->markers) for (auto marker : *song->markers) {
                if(t.markerPreview && t.markerPreview->first==marker.id) marker.position=t.markerPreview->second;
                const float x = lineX(marker.position), top = (float)t.regionHeight() + (marker.tempoBPM ? 32.f : 16.f);
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
        }
        void paintOverChildren(Graphics &g) override {
            if (itemValueTooltip.isNotEmpty()) {
                const auto bounds=valueTooltipBounds();
                g.setColour(Colour(0xf0262626));g.fillRoundedRectangle(bounds.toFloat(),5.f);
                g.setColour(Colour(0xff777777));g.drawRoundedRectangle(bounds.toFloat(),5.f,1.f);
                g.setFont(theme::semiboldFont(12));g.setColour(Colours::white);
                g.drawText(itemValueTooltip,bounds,Justification::centred);
            }
            const auto &gripID=regionEdge && !dragRegion.empty()?dragRegion:hoverRegion;
            const int gripSide=regionEdge && !dragRegion.empty()?regionEdge:hoverRegionEdge;
            if(gripSide && !timelineGrid::movementLocked(t.w.session.project()))
                if(const auto *song=t.displaySong())for(const auto &part:song->parts)
                    if(part.id==gripID && !part.parentRegionID && !regionEditing::hasChildren(*song,part.id)) {
                        const float left=t.xAt(part.startTime),right=t.xAt(part.endTime);
                        g.setColour(Colour(0xff54ff94));
                        g.fillRoundedRectangle((gripSide<0?left:right)-2,
                            (float)RegionLanes(song->parts).lane(part.id)*16+3,4,10,2);
                    }
            if (!dragClip.empty() && !timelineGrid::movementLocked(t.w.session.project())) {
                const double from=dragPreview?previewStart:originalStart;
                const double to=dragPreview?previewEnd:originalStart+clipLength;
                g.setColour(Colours::yellow);
                g.drawVerticalLine((int)std::round(t.xAt(from)),(float)headerHeight(),(float)getHeight());
                g.drawVerticalLine((int)std::round(t.xAt(to)),(float)headerHeight(),(float)getHeight());
            }
            if (const auto range=t.visualTimeRange()) {
                const float left=t.xAt(range->first),right=t.xAt(range->second),top=(float)t.regionHeight()+32,bottom=(float)getHeight();
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
                Graphics::ScopedSaveState selectionClip(g);
                g.reduceClipRegion(0, headerHeight(), getWidth(), std::max(0, getHeight()-headerHeight()));
                g.setColour(Colour(0xff34c759).withAlpha(.12f));
                g.fillRect(*selectionBox);
                g.setColour(Colour(0xff34c759).withAlpha(.9f));
                g.drawRect(selectionBox->reduced(.5f),1.f);
            }
            if (dragPreview && !dragMarker.empty()) {
                g.setColour(theme::green);
                g.drawVerticalLine((int)t.xAt(previewStart),(float)t.regionHeight(),(float)getHeight());
            }
        }

        void mouseMove(const MouseEvent &e) override {
            String tooltip;
            MouseCursor cursor(MouseCursor::NormalCursor);
            if(e.y>=t.regionHeight()+32 && e.y<headerHeight()) cursor=MouseCursor::PointingHandCursor;
            if(e.y>=t.regionHeight()+32 && e.y<headerHeight() && timeRangeEdge(e.position.x)) cursor=MouseCursor::LeftRightResizeCursor;
            const auto hit=regionHit(e.position,true);
            const ID nextHover=hit.first && hit.second?hit.first->id:ID{};
            if(nextHover!=hoverRegion || hit.second!=hoverRegionEdge) {
                hoverRegion=nextHover;hoverRegionEdge=hit.second;repaint(0,0,getWidth(),t.regionHeight());
            }
            if(hit.second)cursor=regionResizeCursor();
            if (const auto *song=t.w.session.song()) {
                const int row=t.w.rowAt(e.y-headerHeight()+t.w.verticalOffset);
                if (e.y>=headerHeight() && row>=0 && row<(int)song->tracks.size()) {
                    const auto &track=song->tracks[(size_t)row];
                    for (const auto &clip:track.clips) if (itemRect(row,clip).contains(e.position)) {
                        const ItemHeader header(itemRect(row,clip),(float)getWidth(),track,clip,t.w.itemTitle(clip));
                        if (!timelineGrid::movementLocked(t.w.session.project()) && header.hit(e.position,clip)==ItemHeader::none && header.resizeSide(e.position) &&
                            (track.role.id!="generatedClick" || clipEditing::projection(clip))) cursor=MouseCursor::LeftRightResizeCursor;
                        const auto hit = header.hit(e.position,clip);
                        if(hit==ItemHeader::gain) tooltip="Volume: " + ItemHeader::gainText(clip.gain.value_or(1));
                        else if(hit==ItemHeader::pan) tooltip="Pan: " + ItemHeader::panText(clip.pan.value_or(0));
                        if (hit == ItemHeader::fadeIn || hit == ItemHeader::fadeOut) cursor=ItemHeader::fadeCursor(hit==ItemHeader::fadeIn);
                        break;
                    }
                }
            }
            setItemValueTooltip(tooltip,e.position);
            setMouseCursor(cursor);
        }
        void mouseExit(const MouseEvent &) override {
            if(!controlClip)setItemValueTooltip({},controlPointer);
            hoverRegion.clear();hoverRegionEdge=0;repaint(0,0,getWidth(),t.regionHeight());
        }
        void mouseDown(const MouseEvent &e) override {
            setItemValueTooltip({},e.position);
            collapseSelectionOnRelease.clear(); clearSelectionOnRelease=false;
            t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
            t.stopGesture();
            startTime = t.timeAt(e.position.x);
            startPosition = e.position;
            stopTimer(); rightSelection = false; itemEdgeActive = false;
            itemDragSong.clear();
            dragClip.clear(); dragRegion.clear(); dragMarker.clear(); regionEdge=0;
            dragOriginalClip.reset();
            dragOriginalValid=false;
            previewPlacements.clear();
            rulerPan=false; rulerPanDragged=false;
            mainDrag=false; dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset();
            resizeEdge = 0;
            controlClip.reset(); controlKind=ItemHeader::none; controlOriginals.clear();
            t.w.grabKeyboardFocus();
            // Match NativeTimelineNeedlesView.target(at:) on macOS, including
            // the tip that extends just below the ruler into the first row.
            const bool editHeadHit = e.y >= headerHeight() - 16 && e.y <= headerHeight() + 6 &&
                std::abs(e.position.x - t.xAt(t.w.session.transport().editPosition)) <= 14.f;
            if(e.y<headerHeight() && e.mods.isLeftButtonDown())t.pausePlaybackFollow();
            if (editHeadHit && e.mods.isLeftButtonDown() && !e.mods.isAltDown()) {
                mainDrag = true;
                subDrag = false;
                t.w.perform([&] { t.w.session.command(jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods, false)); });
                return;
            }
            if (e.y >= t.regionHeight() && e.y < headerHeight()) {
                if (e.y>=t.regionHeight()+32 && (e.mods.isPopupMenu() || timeRangeEdge(e.position.x))) {
                    timeRangeGesture=true;timeRangeDragged=false;timeRangeRight=e.mods.isPopupMenu();
                    timeRangeResize=timeRangeEdge(e.position.x);
                    timeRangeBefore=t.visualTimeRange();
                    return;
                }
                if (const auto *song = t.w.session.song()) {
                    t.refreshMarkers(*song);
                    for (const auto &flag : t.markerFlags) {
                        const float width = timelineRegionLabels::markerHeadWidth(flag.position,flag.next,flag.regionEnd,flag.width,t.w.pixelsPerSecond);
                        if (!juce::Rectangle<float>(t.xAt(flag.position),(float)t.regionHeight()+(flag.tempo?17.f:1.f),std::max(8.f,width),14).contains(e.position)) continue;
                        if (e.mods.isPopupMenu()) { ++t.w.contextCount; t.w.showMarkerMenu(flag.id, e.getScreenPosition()); }
                        else if (e.mods.isAltDown()) t.w.perform([&] {
                            t.w.session.editTimeline([&](auto &p) {auto edit=t.w.session.core;edit.deleteManualMarker(flag.id);p=edit.project();}, flag.tempo);
                        });
                        else { dragMarker=flag.id; originalStart=flag.position; }
                        return;
                    }
                }
                if (e.y >= t.regionHeight()+32 && e.mods.isLeftButtonDown() && !e.mods.isAltDown()) {
                    rulerPan=true; rulerPanOffset=t.horizontal.getCurrentRangeStart(); return;
                }
                subDrag = e.mods.isPopupMenu() || e.mods.isAltDown();
                mainDrag = true;
                t.w.perform([&] { t.w.session.command(subDrag ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods, subDrag)); });
                return;
            }
            if (e.y < t.regionHeight()) {
                const auto hit=regionHit(e.position,!e.mods.isPopupMenu());
                if (hit.first) {
                            const auto &p=*hit.first;
                            t.selectedHeaderRegion=p.id;t.selectedHeaderProject=t.w.session.project().id;
                            repaint(0,0,getWidth(),t.regionHeight());
                            if (e.mods.isPopupMenu()) {
                                ++t.w.contextCount;
                                t.w.showRegionMenu(p.id, e.getScreenPosition());
                            } else {
                                dragRegion=p.id; originalStart=p.startTime; clipLength=p.endTime-p.startTime;
                                regionEdge=hit.second;
                                regionRepulsion.emplace(*t.w.session.song(),p,10./t.w.pixelsPerSecond);
                                if(regionEdge)setMouseCursor(regionResizeCursor());
                            }
                }
                return;
            }
            const int programRow=t.w.rowAt(e.y-headerHeight()+t.w.verticalOffset);
            if(const auto *song=t.w.session.song();song && programRow>=0 && programRow<(int)song->tracks.size() && song->tracks[size_t(programRow)].role.id=="programChange") {
                const auto &track=song->tracks[size_t(programRow)];
                const float top=headerHeight()+t.w.rowTop(programRow)-t.w.verticalOffset+4;
                ID markerID;const ProgramChangeLanes stacks(track);
                for(const auto &m:track.programChanges)
                    if(juce::Rectangle<float>(t.xAt(m.position),top+stacks.lanes.at(m.id)*24,timelineRegionLabels::programChangeHeadWidth(*song,m.position,programHeadWidth(m),t.w.pixelsPerSecond),19).contains(e.position)){markerID=m.id;break;}
                if(!markerID.empty())t.w.selectProgramMarker(markerID);
                if(e.mods.isPopupMenu()) {
                    PopupMenu menu;menu.addItem(1,localization::translate("Copy"),!markerID.empty());
                    menu.addItem(2,localization::translate("Paste"),t.w.session.programChangeClipboard.has_value());
                    if(!markerID.empty())menu.addItem(3,localization::translate("Delete"));
                    const auto project=t.w.session.project().id,trackID=track.id;
                    menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this).withTargetScreenArea(juce::Rectangle<int>(e.getScreenX(), e.getScreenY(), 1, 1)),[safe=SafePointer<Workspace>(&t.w),project,trackID,markerID](int choice){
                        if(!safe||safe->session.project().id!=project)return;
                        safe->perform([&]{if(choice==1)safe->copyGridItems();else if(choice==2)safe->pasteProgramMarker();else if(choice==3)safe->session.removeProgramChange(trackID,markerID);});
                    });return;
                }
                if(!markerID.empty())return;
            }
            if (e.mods.isPopupMenu()) {
                rightSelection = true;
                selectionAnchor = {e.position.x + (float)t.horizontal.getCurrentRangeStart(), e.position.y + t.w.verticalOffset};
                selectionPointer = e.position;
                selectionBox.reset();
                selectionIndexRevision = ~uint64(0);
                selectionPending = false;
                additiveSelection = e.mods.isCtrlDown() || e.mods.isShiftDown();
                selectionBase = additiveSelection ? t.w.selectedClips : std::set<ID>{};
                if (additiveSelection && !t.w.selectedClip.empty()) selectionBase.insert(t.w.selectedClip);
                selectionSong = t.w.session.song() ? t.w.session.song()->id : ID{};
                return;
            }
            int row = t.w.rowAt(e.y - headerHeight() + t.w.verticalOffset);
            if (auto *s = t.w.session.song())
                if (row >= 0 && row < (int)s->tracks.size()) {
                    auto &track = s->tracks[(size_t)row];
                    t.w.session.selectProgramChange({});
                    t.w.selectMixerTrack(track.id, e.mods, false);
                    t.invalidate();
                    for (const auto &c : track.clips)
                        if (itemRect(row,c).contains(e.position)) {
                            {
                                if (e.mods.isCtrlDown() || e.mods.isShiftDown()) {
                                    if (t.w.selectedClips.empty() && !t.w.selectedClip.empty()) t.w.selectedClips.insert(t.w.selectedClip);
                                    if (!t.w.selectedClips.erase(c.id)) t.w.selectedClips.insert(c.id);
                                } else collapseSelectionOnRelease=c.id;
                            }
                            t.w.selectedClip = t.w.selectedClips.count(c.id) ? c.id : t.w.selectedClips.empty() ? ID{} : *t.w.selectedClips.begin();
                            if (const auto control=ItemHeader(itemRect(row,c),(float)getWidth(),track,c,t.w.itemTitle(c)).hit(e.position,c); control!=ItemHeader::none) {
                                controlKind=control;
                                controlPointer=e.position;
                                controlSelection=t.w.selectedClips.count(c.id)?t.w.selectedClips:std::set<ID>{c.id};
                                controlOriginals.clear();
                                if(controlSelection.size()==1) controlOriginals.emplace_back(row,controlSnapshot(c));
                                else for(int selectedRow=0;selectedRow<(int)s->tracks.size();++selectedRow)
                                    for(const auto &selectedClip:s->tracks[(size_t)selectedRow].clips)
                                        if(controlSelection.count(selectedClip.id)) controlOriginals.emplace_back(selectedRow,controlSnapshot(selectedClip));
                                collapseSelectionOnRelease.clear();
                                controlClip=controlSnapshot(c);
                                controlOriginal=controlSnapshot(c);
                                controlTrack=track.id;
                                controlRow=row;
                                if(control==ItemHeader::gain)setItemValueTooltip("Volume: "+ItemHeader::gainText(c.gain.value_or(1)),e.position);
                                else if(control==ItemHeader::pan)setItemValueTooltip("Pan: "+ItemHeader::panText(c.pan.value_or(0)),e.position);
                                else setItemValueTooltip({},e.position);
                            } else {
                                // Preserve the existing edit cursor as a drag magnet.
                                // A plain click seeks on release; Shift still seeks
                                // immediately to the exact pointer time.
                                if (e.mods.isShiftDown() && !e.mods.isCtrlDown())
                                    t.w.perform([&] { t.w.session.command(e.mods.isAltDown() ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek, {}, pointerPosition(startTime,e.mods,e.mods.isAltDown())); });
                                dragClip = c.id;
                                itemDragSong=s->id;
                                dragOriginalClip=c; dragOriginalValid=true;
                                dragSelectionPreviews.clear();
                                if(t.w.selectedClips.count(c.id) && t.w.selectedClips.size()>1) {
                                    for(int selectedRow=0;selectedRow<(int)s->tracks.size();++selectedRow)
                                        for(const auto &selectedClip:s->tracks[(size_t)selectedRow].clips)
                                            if(t.w.selectedClips.count(selectedClip.id)) dragSelectionPreviews.push_back({selectedRow,selectedClip.startTime,selectedClip});
                                }
                                originalStart = c.startTime;
                                clipLength = c.duration;
                                sourceRow = row;
                                resizeEdge = track.role.id == "generatedClick" && !clipEditing::projection(c) ? 0
                                    : ItemHeader(itemRect(row,c),(float)getWidth(),track,c,t.w.itemTitle(c)).resizeSide(e.position);
                            }
                            t.invalidate();
                            return;
                        }
                }
            if (!e.mods.isPopupMenu() && !e.mods.isCtrlDown())
                t.w.perform([&] { t.w.session.command(e.mods.isAltDown() ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek, {}, pointerPosition(startTime,e.mods,e.mods.isAltDown())); });
            clearSelectionOnRelease=true;
        }

        void mouseDrag(const MouseEvent &e) override {
            if (rulerPan) {
                if (e.getDistanceFromDragStart() >= 3) rulerPanDragged=true;
                if (rulerPanDragged) {
                    t.horizontal.setCurrentRangeStart(rulerPanOffset-(e.position.x-startPosition.x), sendNotificationSync);
                    setMouseCursor(MouseCursor::DraggingHandCursor);
                }
                return;
            }

            if(!dragClip.empty() && !t.w.selectedClips.count(dragClip) && e.getDistanceFromDragStart() > 4) {t.w.selectedClips={dragClip};t.w.selectedClip=dragClip;}
            if (timeRangeGesture) { updateTimeRange(e); return; }
            if (rightSelection) { updateAreaSelection(e); return; }
            if (timelineGrid::movementLocked(t.w.session.project()) &&
                (!dragClip.empty() || !dragRegion.empty() || !dragMarker.empty())) {
                t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
                dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset();
                setMouseCursor(MouseCursor::NormalCursor); repaint(); return;
            }
            if (!dragRegion.empty() || !dragMarker.empty()) {
                if (e.getDistanceFromDragStart() >= 3) {
                    previewStart=std::max(0., originalStart+(e.position.x-startPosition.x)/t.w.pixelsPerSecond);
                    if (!dragRegion.empty() && t.w.session.song()) {
                        const auto bounds=regionEditBounds(e);
                        previewStart=bounds.first; previewEnd=bounds.second;
                        t.setRegionPreview(previewRegionEdit(*t.w.session.song(),dragRegion,previewStart,previewEnd,regionEdge!=0));
                    }
                    if (!dragMarker.empty()) { previewStart=markerEditPosition(e); t.previewMarker(std::make_pair(dragMarker,previewStart)); }
                    dragPreview=true; setMouseCursor(regionEdge?regionResizeCursor():MouseCursor(MouseCursor::DraggingHandCursor)); repaint();
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
                if(!t.w.session.busy) previewControl(*controlClip);
                if(controlKind==ItemHeader::gain) setItemValueTooltip("Volume: " + ItemHeader::gainText(controlClip->gain.value_or(1)),e.position);
                else if(controlKind==ItemHeader::pan) setItemValueTooltip("Pan: " + ItemHeader::panText(controlClip->pan.value_or(0)),e.position);
                for(const auto &[row,clip]:controlOriginals) repaint(itemRect(row,clip).expanded(4.f).getSmallestIntegerContainer());
                return;
            }
            if (mainDrag) {
                t.w.perform([&] {
                    t.w.session.command(subDrag ? jaras::CommandKind::subSeek
                                                : jaras::CommandKind::editSeek,
                                        {}, pointerPosition(t.timeAt(e.position.x),e.mods,subDrag));
                });
            } else if (!dragClip.empty() && e.getDistanceFromDragStart() > 4) {
                if(previewRow>=0 && previewRow<(int)t.w.rows.size())
                    repaint(0,headerHeight()+t.w.rowTop(previewRow)-t.w.verticalOffset,getWidth(),t.w.rowHeight(previewRow));
                const bool began = !dragPreview;
                updateDrag(e);
                if (!resizeEdge) {
                    if (began) t.pausePlaybackFollow();
                    itemEdgeActive=true; itemEdgePointer=e.position; itemEdgeModifiers=e.mods;
                    startEdgeScroll();
                }
                setMouseCursor(resizeEdge ? MouseCursor::LeftRightResizeCursor
                                          : MouseCursor::DraggingHandCursor);
                repaintDragPreview();
            }
        }
        void mouseUp(const MouseEvent &e) override {
            stopTimer(); itemEdgeActive=false;
            if (rulerPan) {
                rulerPan=false;
                if (!rulerPanDragged) t.w.perform([&]{t.w.session.command(jaras::CommandKind::editSeek,{},pointerPosition(startTime,e.mods,false));});
                setMouseCursor(MouseCursor::PointingHandCursor);return;
            }

            if(e.getDistanceFromDragStart() < 4) {
                if(!collapseSelectionOnRelease.empty()) { t.w.selectedClips={collapseSelectionOnRelease}; t.w.selectedClip=collapseSelectionOnRelease; }
                else if(clearSelectionOnRelease) t.w.clearItemSelection();
            }
            collapseSelectionOnRelease.clear();clearSelectionOnRelease=false;
            if (timeRangeGesture) {
                updateTimeRange(e);timeRangeGesture=false;
                if(!timeRangeDragged && timeRangeRight) t.w.perform([&]{t.w.session.command(jaras::CommandKind::subSeek,{},startTime);});
                timeRangeBefore.reset();timeRangeResize=0;setMouseCursor(MouseCursor::NormalCursor);t.invalidate();return;
            }
            if (rightSelection) {
                updateAreaSelection(e);
                if (selectionPending) updateMarqueeSelection();
                rightSelection = false; stopTimer();
                const bool dragged = selectionBox.has_value();
                if (selectionBox) repaint(selectionBox->expanded(2.f).getSmallestIntegerContainer());
                selectionBox.reset(); selectionIndex.clear();
                if (!dragged && t.w.session.song() && t.w.session.song()->id == selectionSong) showItemContext(e);
                selectionBase.clear();
                return;
            }
            if (timelineGrid::movementLocked(t.w.session.project()) &&
                (!dragClip.empty() || !dragRegion.empty() || !dragMarker.empty())) {
                t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
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
                    if (!marker.empty()) { t.w.session.moveMarker(marker,markerEditPosition(e)); return; }
                    const auto bounds=regionEditBounds(e);
                    t.w.session.edit([&](auto &p) {
                        auto edit=t.w.session.core;
                        if (!region.empty()) {
                            if (regionEdge) edit.resizeRegion(region,bounds.first,bounds.second);
                            else edit.moveRegion(region,bounds.first);
                        }
                        p=edit.project();
                    });
                });
                else t.w.perform([&] {
                    if (!region.empty()) t.w.session.command(t.w.session.transport().playing?jaras::CommandKind::queueRegion:jaras::CommandKind::selectRegion,region);
                    else t.w.session.command(jaras::CommandKind::editSeek,{},originalStart);
                });
                t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
                t.previewMarker(std::nullopt);
                dragRegion.clear();dragMarker.clear();dragPreview=false;setMouseCursor(MouseCursor::NormalCursor);t.invalidate();return;
            }
            if (controlClip) {
                const auto kind=controlKind;
                if(kind==ItemHeader::mute || kind==ItemHeader::phase || kind==ItemHeader::fx) {
                    const auto *song=t.w.session.song();
                    const bool activate=song && controlRow>=0 && controlRow<(int)song->tracks.size() &&
                        song->tracks[(size_t)controlRow].id==controlTrack && e.getDistanceFromDragStart()<3 &&
                        ItemHeader(itemRect(controlRow,*controlClip),(float)getWidth(),song->tracks[(size_t)controlRow],*controlClip,t.w.itemTitle(*controlClip)).hit(e.position,*controlClip)==kind;
                    if(activate) {
                        if(kind==ItemHeader::fx && !e.mods.isAltDown()) {const auto id=controlClip->id; controlClip.reset();controlKind=ItemHeader::none;t.w.openItemFX(id);return;}
                        if(kind==ItemHeader::mute) controlClip->muted=!controlClip->muted;
                        if(kind==ItemHeader::phase) controlClip->phaseInverted=!controlClip->phaseInverted.value_or(false);
                        if(kind==ItemHeader::fx) controlClip->fxBypassed=!controlClip->fxBypassed.value_or(false);
                        commitControl();
                    }
                } else if(e.getDistanceFromDragStart()>0) commitControl();
                controlClip.reset();controlKind=ItemHeader::none;mouseMove(e);repaint();return;
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
                    if (resizeEdge) t.w.session.resizeItem(id, previewStart, previewEnd);
                    else t.w.session.editTimeline([&](jaras::Project &p) {
                        if(t.w.selectedClips.count(id) && t.w.selectedClips.size()>1) {
                            for(auto &song:p.songs) if(song.id==t.w.session.song()->id) {
                                struct Selected {int row;jaras::AudioClip clip;};std::vector<Selected> items;
                                double earliest=originalStart;
                                for(int row=0;row<(int)song.tracks.size();++row) for(const auto &clip:song.tracks[(size_t)row].clips) if(t.w.selectedClips.count(clip.id)) {items.push_back({row,clip});earliest=std::min(earliest,clip.startTime);}
                                const double delta=std::max(previewStart-originalStart,-earliest);
                                const int rows=previewRow-sourceRow;
                                for(const auto &item:items) if(item.row+rows<0 || item.row+rows>=(int)song.tracks.size()) throw std::runtime_error("Cannot move the selection beyond the available tracks.");
                                for(auto &track:song.tracks) track.clips.erase(std::remove_if(track.clips.begin(),track.clips.end(),[&](const auto &clip){return t.w.selectedClips.count(clip.id)!=0;}),track.clips.end());
                                for(const auto &item:items) {
                                    song.tracks[(size_t)item.row].clips.push_back(item.clip);
                                    clipEditing::move(p,item.clip.id,item.clip.startTime+delta,song.tracks[(size_t)(item.row+rows)].id);
                                }
                                break;
                            }
                        } else clipEditing::move(p, id, previewStart, destinationTrack);
                    });
                    if (!resizeEdge && !destinationTrack.empty())
                        t.w.selectedTrack = destinationTrack;
                });
            }
            if (!dragClip.empty() && e.getDistanceFromDragStart() <= 4 && !e.mods.isCtrlDown() && !e.mods.isShiftDown())
                t.w.perform([&] { t.w.session.command(e.mods.isAltDown() ? jaras::CommandKind::subSeek : jaras::CommandKind::editSeek,
                    {}, pointerPosition(startTime,e.mods,e.mods.isAltDown())); });
            dragClip.clear();
            dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset();
            dragOriginalClip.reset();dragOriginalValid=false;previewPlacements.clear();dragSelectionPreviews.clear();
            repaint();
        }
        void mouseDoubleClick(const MouseEvent &e) override {
            if (const auto *song=t.w.session.song()) {
                const int row=t.w.rowAt(e.y-headerHeight()+t.w.verticalOffset);
                if (row>=0 && row<(int)song->tracks.size()) for (const auto &clip:song->tracks[(size_t)row].clips) {
                    const auto hit=ItemHeader(itemRect(row,clip),(float)getWidth(),song->tracks[(size_t)row],clip,t.w.itemTitle(clip)).hit(e.position,clip);
                    if (hit==ItemHeader::gain || hit==ItemHeader::pan || hit==ItemHeader::fadeIn || hit==ItemHeader::fadeOut || ItemHeader::isShape(hit)) {
                        controlClip=controlSnapshot(clip); controlOriginal=controlSnapshot(clip); controlKind=hit;
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
            t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
            rulerPan=false;rulerPanDragged=false;
            timeRangeGesture=false;timeRangeDragged=false;timeRangeResize=0;timeRangeBefore.reset();
            stopTimer(); rightSelection = false; itemEdgeActive=false; itemDragSong.clear(); selectionBox.reset(); selectionBase.clear(); selectionPending = false; selectionIndex.clear();
            dragRegion.clear(); dragMarker.clear();
            if(controlClip) t.w.perform([&]{previewControl(controlOriginal);});
            controlClip.reset();controlKind=ItemHeader::none;
            setItemValueTooltip({},controlPointer);
            dragClip.clear();dragOriginalClip.reset();dragOriginalValid=false;previewPlacements.clear();dragSelectionPreviews.clear();
            dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); mainDrag = subDrag = false; setMouseCursor(MouseCursor::NormalCursor); repaint();
        }

      private:
        Timeline &t;
        DottedGridPaint primaryGridPattern, secondaryGridPattern;
        String itemValueTooltip;
        struct ClipIntervalEntry { double start=0,end=0;size_t index=0; };
        struct TrackClipIndex { ID track;std::vector<ClipIntervalEntry> entries;std::vector<double> maximumEnds; };
        ID clipIndexSong;
        uint64 clipIndexRevision=~uint64(0);
        std::vector<TrackClipIndex> clipIndexes;
        std::map<ID,ItemLanes::Placement> previewPlacements;
        std::pair<const jaras::Part*,int> regionHit(Point<float> point,bool edges) const {
            const auto *song=t.w.session.song(); if(!song || point.y<0 || point.y>=t.regionHeight())return {nullptr,0};
            for(const auto &part:song->parts) {
                if(part.parentRegionID || (int)point.y/16!=t.regionLanes().lane(part.id))continue;
                const float left=t.xAt(part.startTime),right=t.xAt(part.endTime);
                if(point.x<left || point.x>=right)continue;
                int edge=0;
                if(edges && !timelineGrid::movementLocked(t.w.session.project()) && !regionEditing::hasChildren(*song,part.id)) {
                    const float width=std::min(34.f,std::max(0.f,(right-left-8)/2));
                    if(point.x-left<width)edge=-1;
                    else if(right-point.x<width)edge=1;
                }
                return {&part,edge};
            }
            return {nullptr,0};
        }
        static const MouseCursor &regionResizeCursor() {
            static const auto cursor=[] {
                Image image(Image::ARGB,32,32,true);Graphics g(image);Path p;
                p.startNewSubPath(4,16);p.lineTo(28,16);
                p.startNewSubPath(11,9);p.lineTo(4,16);p.lineTo(11,23);
                p.startNewSubPath(21,9);p.lineTo(28,16);p.lineTo(21,23);
                g.setColour(Colours::black);g.strokePath(p,PathStrokeType(5,PathStrokeType::curved,PathStrokeType::rounded));
                g.setColour(Colours::white);g.strokePath(p,PathStrokeType(2,PathStrokeType::curved,PathStrokeType::rounded));
                return MouseCursor(image,8,8,2.f);
            }();
            return cursor;
        }
        ID hoverRegion;
        int hoverRegionEdge=0;
        std::optional<RegionMarkerRepulsion> regionRepulsion;
        double markerEditPosition(const MouseEvent &e) const {
            const double at=std::max(0.,originalStart+(e.position.x-startPosition.x)/t.w.pixelsPerSecond);
            const auto *song=t.w.session.song();
            return song?timelineGrid::snap(at,*song,t.w.pixelsPerSecond,t.w.freeTimelinePosition(e.mods),false,&t.w.session.transport(),false,nullptr,nullptr,&dragMarker):at;
        }
        std::pair<double,double> regionEditBounds(const MouseEvent &e) const {
            const double delta=(e.position.x-startPosition.x)/t.w.pixelsPerSecond;
            if(!regionEdge) {
                double start=std::max(0.,originalStart+delta);
                if(const auto *song=t.w.session.song())start=timelineGrid::snap(start,*song,t.w.pixelsPerSecond,
                    t.w.freeTimelinePosition(e.mods),false,&t.w.session.transport(),true,nullptr,&dragRegion);
                if(regionRepulsion)start=regionRepulsion->resolve(start);
                return {start,start+clipLength};
            }
            double boundary=(regionEdge<0?originalStart:originalStart+clipLength)+delta;
            if(const auto *song=t.w.session.song())boundary=timelineGrid::snap(boundary,*song,t.w.pixelsPerSecond,
                t.w.freeTimelinePosition(e.mods),false,&t.w.session.transport(),true,nullptr,&dragRegion);
            return {regionEdge<0?std::max(0.,std::min(originalStart+clipLength-.01,boundary)):originalStart,
                    regionEdge>0?std::max(originalStart+.01,boundary):originalStart+clipLength};
        }
        bool rulerPan=false,rulerPanDragged=false;
        double rulerPanOffset=0;
        bool timeRangeGesture=false,timeRangeDragged=false,timeRangeRight=false;
        int timeRangeResize=0;
        std::optional<std::pair<double,double>> timeRangeBefore;
        int timeRangeEdge(float x) const {
            const auto range=t.visualTimeRange();if(!range)return 0;
            const auto left=std::abs(x-t.xAt(range->first)),right=std::abs(x-t.xAt(range->second));
            return std::min(left,right)<=8 ? (left<=right?-1:1) : 0;
        }
        void updateTimeRange(const MouseEvent &e) {
            if(!timeRangeDragged && e.position.getDistanceFrom(startPosition)<3)return;
            const auto *song=t.w.session.song();if(!song)return;
            timeRangeDragged=true;
            refreshItemSnapEdges(*song);
            auto snap=[&](double value){return timelineGrid::snapSelection(value,*song,t.w.pixelsPerSecond,t.w.session.transport(),t.w.freeTimelinePosition(e.mods),nullptr,&itemSnapEdges);};
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
        Point<float> selectionAnchor, selectionPointer;
        double selectionScrollTime = 0;
        bool itemEdgeActive = false;
        ID itemDragSong;
        Point<float> itemEdgePointer;
        ModifierKeys itemEdgeModifiers;
        bool selectionPending = false;
        TimelineMarqueeIndex selectionIndex;
        uint64 selectionIndexRevision = ~uint64(0);
        double selectionIndexZoom = 0;
        int selectionIndexHeight = 0, selectionIndexHeader = 0;
        void rebuildSelectionIndex(const jaras::Song &song) {
            if (selectionIndexRevision == t.w.session.revision && selectionIndexZoom == t.w.pixelsPerSecond &&
                selectionIndexHeight == t.w.trackHeight && selectionIndexHeader == headerHeight()) return;
            selectionIndex.clear();
            int top = headerHeight();
            for (int row = 0; row < (int)song.tracks.size(); ++row) {
                if (t.w.rowHidden(row)) continue;
                const auto &track = song.tracks[(size_t)row];
                const auto &lanes = t.w.itemLanes(row);
                const int laneHeight = t.w.itemLaneHeight(row), bodyHeight = laneHeight * lanes.count;
                std::vector<TimelineMarqueeIndex::Item> items;
                items.reserve(track.clips.size());
                for (const auto &clip : track.clips) {
                    const double left = clip.startTime * t.w.pixelsPerSecond;
                    const auto geometry=t.w.itemGeometry(row,clip.id);
                    const double y = top + geometry.top + 3;
                    items.push_back({clip.id, {left, y, left + std::max(2., clip.duration * t.w.pixelsPerSecond - 2), y + geometry.height - 6}});
                }
                selectionIndex.addRow(top, top + bodyHeight, std::move(items));
                top += bodyHeight + 32 * (int)automation::visible(track).size();
            }
            selectionIndexRevision = t.w.session.revision; selectionIndexZoom = t.w.pixelsPerSecond;
            selectionIndexHeight = t.w.trackHeight; selectionIndexHeader = headerHeight();
        }
        void updateAreaSelection(const MouseEvent &e) {
            selectionPointer = e.position;
            if (!selectionBox && e.position.getDistanceFrom(startPosition) < 3.f) return;
            selectionPending = true;
            if (!selectionBox) { t.pausePlaybackFollow(); updateMarqueeSelection(); }
            startEdgeScroll();
        }
        void startEdgeScroll() {
            if (!isTimerRunning()) { selectionScrollTime = Time::getMillisecondCounterHiRes(); startTimerHz(60); }
        }
        void updateMarqueeSelection() {
            const auto *song = t.w.session.song();
            if (!song || song->id != selectionSong) { cancelDrag(); return; }
            selectionPending = false;
            rebuildSelectionIndex(*song);
            const Point<float> offset{(float)t.horizontal.getCurrentRangeStart(), (float)t.w.verticalOffset};
            const Point<float> point{jlimit(0.f, (float)getWidth(), selectionPointer.x),
                jlimit((float)headerHeight(), (float)std::max(headerHeight(), getHeight()), selectionPointer.y)};
            const auto anchor = selectionAnchor - offset;
            const auto oldBox = selectionBox;
            selectionBox = juce::Rectangle<float>(anchor, point);
            if (selectionBox->getWidth() < 1) selectionBox->setWidth(1);
            if (selectionBox->getHeight() < 1) selectionBox->setHeight(1);
            auto selected = selectionBase;
            const auto documentBox = selectionBox->translated(offset.x, offset.y);
            selectionIndex.select({documentBox.getX(), documentBox.getY(), documentBox.getRight(), documentBox.getBottom()}, selected);
            auto previous = t.w.selectedClips;
            if (!t.w.selectedClip.empty()) previous.insert(t.w.selectedClip);
            std::vector<ID> changed;
            std::set_symmetric_difference(previous.begin(), previous.end(), selected.begin(), selected.end(), std::back_inserter(changed));
            for (const auto &id : changed) if (const auto *bounds = selectionIndex.bounds(id)) {
                repaint(juce::Rectangle<float>((float)bounds->left-offset.x, (float)bounds->top-offset.y,
                    (float)(bounds->right-bounds->left), (float)(bounds->bottom-bounds->top)).expanded(3.f).getSmallestIntegerContainer());
            }
            t.w.selectedClips = std::move(selected);
            t.w.selectedClip = t.w.selectedClips.empty() ? ID{} : *t.w.selectedClips.begin();
            if (oldBox) repaint(oldBox->expanded(2.f).getSmallestIntegerContainer());
            repaint(selectionBox->expanded(2.f).getSmallestIntegerContainer());
        }
        void timerCallback() override {
            const bool marquee=rightSelection && selectionBox.has_value();
            const bool itemMove=itemEdgeActive && !dragClip.empty() && dragPreview && !resizeEdge;
            const auto *song=t.w.session.song();
            if ((!marquee && !itemMove) || !isShowing() || isCurrentlyBlockedByAnotherModalComponent() ||
                !song || song->id != (marquee ? selectionSong : itemDragSong) ||
                (itemMove && timelineGrid::movementLocked(t.w.session.project()))) { cancelDrag(); return; }
            const double now = Time::getMillisecondCounterHiRes();
            const double dt = jlimit(0., .05, (now - selectionScrollTime) / 1000.);
            selectionScrollTime = now;
            auto velocity=[](float value, float low, float high) {
                const float band=std::min(28.f,std::max(1.f,(high-low)/3));
                if(value<low+band)return -600.f*jlimit(0.f,1.f,(low+band-value)/band);
                if(value>high-band)return 600.f*jlimit(0.f,1.f,(value-high+band)/band);
                return 0.f;
            };
            const auto pointer=marquee ? selectionPointer : itemEdgePointer;
            const auto dx=velocity(pointer.x,0.f,(float)getWidth())*dt;
            const auto dy=velocity(pointer.y,(float)headerHeight(),(float)getHeight())*dt;
            const double oldX=t.horizontal.getCurrentRangeStart(), oldY=t.vertical.getCurrentRangeStart();
            if(dx!=0)t.horizontal.setCurrentRangeStart(oldX+dx,sendNotificationSync);
            if(dy!=0)t.vertical.setCurrentRangeStart(oldY+dy,sendNotificationSync);
            const bool scrolled=oldX!=t.horizontal.getCurrentRangeStart() || oldY!=t.vertical.getCurrentRangeStart();
            if (marquee && (selectionPending || scrolled)) updateMarqueeSelection();
            else if (itemMove && scrolled) {
                // timeAt/rowAt use the new native offsets, preserving the held
                // item's original document anchor without another mouse event.
                updateDrag(itemEdgePointer,itemEdgeModifiers);
                repaintDragPreview();
            }
        }
        void showItemContext(const MouseEvent &e) {
            const auto *song=t.w.session.song(); if(!song)return;
            const int row=t.w.rowAt(startPosition.y-headerHeight()+t.w.verticalOffset);
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
        std::optional<jaras::AudioClip> dragOriginalClip;
        bool dragOriginalValid=false;
        struct DragSelectionPreview { int row=0; double originalStart=0; jaras::AudioClip preview; };
        std::vector<DragSelectionPreview> dragSelectionPreviews;
        std::vector<std::pair<int,jaras::AudioClip>> controlOriginals;
        ID itemSnapSong;
        uint64 itemSnapRevision=~uint64(0);
        std::vector<std::pair<ID,double>> itemSnapEdges;
        std::set<ID> controlSelection;
        ID controlTrack; int controlRow=-1;
        ItemHeader::Control controlKind=ItemHeader::none;
        Point<float> controlPointer;
        juce::Rectangle<int> valueTooltipBounds() const {
            if(itemValueTooltip.isEmpty())return {};
            const int width=std::max(88,roundToInt(GlyphArrangement::getStringWidth(theme::semiboldFont(12),itemValueTooltip))+18);
            return juce::Rectangle<int>(roundToInt(controlPointer.x)+12,roundToInt(controlPointer.y)-30,width,24)
                .constrainedWithin(getLocalBounds());
        }
        void setItemValueTooltip(const String &label,Point<float> point) {
            const auto old=valueTooltipBounds();
            if(itemValueTooltip==label && (label.isEmpty() || controlPointer==point))return;
            itemValueTooltip=label;controlPointer=point;
            repaint(old.getUnion(valueTooltipBounds()).expanded(1).getIntersection(getLocalBounds()));
        }
        juce::Rectangle<float> itemRect(int row, const jaras::AudioClip &clip) const {
            const auto geometry=t.w.itemGeometry(row,clip.id);
            return {t.xAt(clip.startTime), headerHeight()+t.w.rowTop(row)-t.w.verticalOffset+geometry.top+3,
                    std::max(2.f,(float)(clip.duration*t.w.pixelsPerSecond)-2), geometry.height-6};
        }
        void repaintDragPreview() {
            const auto *song=t.w.session.song();
            if(!song || sourceRow<0 || sourceRow>=(int)song->tracks.size()) { repaint(); return; }
            using TimeBounds=std::pair<double,double>;
            std::map<int,TimeBounds> oldTimes,newTimes;
            auto include=[&](auto &regions,int row,double start,double end) {
                if(row<0 || row>=(int)song->tracks.size())return;
                const auto found=regions.find(row);
                if(found==regions.end()) regions.emplace(row,TimeBounds{start,end});
                else {found->second.first=std::min(found->second.first,start);found->second.second=std::max(found->second.second,end);}
            };
            if(!resizeEdge && t.w.selectedClips.count(dragClip) && t.w.selectedClips.size()>1) {
                const int rowDelta=previewRow-sourceRow;
                for(const auto &entry:dragSelectionPreviews) {
                    include(oldTimes,entry.row,entry.originalStart,entry.originalStart+entry.preview.duration);
                    include(newTimes,entry.row+rowDelta,entry.preview.startTime,entry.preview.startTime+entry.preview.duration);
                }
            } else {
                if(dragOriginalValid && dragOriginalClip) {
                    include(oldTimes,sourceRow,dragOriginalClip->startTime,dragOriginalClip->startTime+dragOriginalClip->duration);
                    include(newTimes,previewRow,previewStart,previewEnd);
                }
            }
            auto repaintRows=[&](const auto &regions) {
                for(const auto &[row,times]:regions) {
                    const float top=headerHeight()+t.w.rowTop(row)-t.w.verticalOffset;
                    // Overlap neighbours can change height outside the moved
                    // item's own bounds. Clear the affected row, not every row.
                    const juce::Rectangle<float> dirty(0,top,(float)getWidth(),(float)t.w.rowHeight(row));
                    repaint(dirty.expanded(4.f).getIntersection(getLocalBounds().toFloat()).getSmallestIntegerContainer());
                }
            };
            repaintRows(oldTimes); repaintRows(newTimes);
        }
        void applySelectedControl(jaras::AudioClip &clip,const jaras::AudioClip &value) const {
            if(controlKind==ItemHeader::gain)clip.gain=value.gain;
            else if(controlKind==ItemHeader::pan)clip.pan=value.pan;
            else if(controlKind==ItemHeader::mute)clip.muted=value.muted;
        }
        static jaras::AudioClip controlSnapshot(const jaras::AudioClip &source) {
            // Shared MIDI instruments need the complete take to recompute note
            // velocities while previewing. Audio controls need only scalars.
            if(source.midi) return source;
            jaras::AudioClip result;
            result.id=source.id;result.name=source.name;result.startTime=source.startTime;result.duration=source.duration;
            result.gain=source.gain;result.pan=source.pan;result.phaseInverted=source.phaseInverted;
            result.normalizationGain=source.normalizationGain;result.muted=source.muted;result.fxBypassed=source.fxBypassed;
            result.fadeIn=source.fadeIn;result.fadeOut=source.fadeOut;result.fadeInCurve=source.fadeInCurve;
            result.fadeInSCurve=source.fadeInSCurve;result.fadeOutCurve=source.fadeOutCurve;result.fadeOutSCurve=source.fadeOutSCurve;
            return result;
        }
        bool sharedControl() const {return controlKind==ItemHeader::gain || controlKind==ItemHeader::pan || controlKind==ItemHeader::mute;}
        void previewControl(const jaras::AudioClip &value) {
            if(const auto *song=t.w.session.song())for(auto &[row,clip]:controlOriginals) {
                if(clip.id==value.id || (sharedControl() && controlSelection.count(clip.id))) {
                    if(clip.id==value.id) {
                        clip.gain=value.gain; clip.pan=value.pan; clip.phaseInverted=value.phaseInverted;
                        clip.muted=value.muted; clip.fadeIn=value.fadeIn; clip.fadeOut=value.fadeOut;
                        clip.fxBypassed=value.fxBypassed; clip.fadeInCurve=value.fadeInCurve;
                        clip.fadeInSCurve=value.fadeInSCurve; clip.fadeOutCurve=value.fadeOutCurve;
                        clip.fadeOutSCurve=value.fadeOutSCurve;
                    } else applySelectedControl(clip,value);
                    if(clip.midi)t.w.session.audio.previewMIDIItem(*song,clip);
                    else t.w.session.audio.setItemControls(clip);
                }
            }
        }
        void refreshItemSnapEdges(const jaras::Song &song) {
            const auto revision=t.w.session.revision;
            if(itemSnapSong==song.id && itemSnapRevision==revision)return;
            itemSnapSong=song.id;itemSnapRevision=revision;itemSnapEdges.clear();
            size_t count=0;for(const auto &track:song.tracks)count+=track.clips.size();
            itemSnapEdges.reserve(count*2);
            for(const auto &track:song.tracks)for(const auto &clip:track.clips) {
                itemSnapEdges.emplace_back(clip.id,clip.startTime);
                itemSnapEdges.emplace_back(clip.id,clip.startTime+clip.duration);
            }
            std::stable_sort(itemSnapEdges.begin(),itemSnapEdges.end(),[](const auto &a,const auto &b) {
                return a.second==b.second?a.first<b.first:a.second<b.second;
            });
        }
        void commitControl() {
            if (!controlClip) return;
            const auto value=*controlClip;
            bool committed=false;
            t.w.perform([&] { t.w.session.editItemControls([&](jaras::Project &project) {
                for(auto &song:project.songs) for(auto &track:song.tracks) for(auto &clip:track.clips) if(clip.id==value.id) {
                    clip.gain=value.gain; clip.pan=value.pan; clip.phaseInverted=value.phaseInverted; clip.muted=value.muted;
                    clip.fadeIn=value.fadeIn; clip.fadeOut=value.fadeOut; clip.fxBypassed=value.fxBypassed;
                    clip.fadeInCurve=value.fadeInCurve; clip.fadeInSCurve=value.fadeInSCurve; clip.fadeOutCurve=value.fadeOutCurve; clip.fadeOutSCurve=value.fadeOutSCurve;
                } else if(sharedControl() && controlSelection.count(clip.id))applySelectedControl(clip,value);
            }); previewControl(value); committed=true; });
            controlClip.reset(); controlKind=ItemHeader::none;
            repaint();
            if(!committed) t.w.perform([&]{previewControl(controlOriginal);});
        }
        double startTime = 0, originalStart = 0, clipLength = 0;
        Point<float> startPosition;
        ID dragClip, dragRegion, dragMarker, collapseSelectionOnRelease;
        bool clearSelectionOnRelease=false;
        int regionEdge=0;
        bool mainDrag = false, subDrag = false;
        int sourceRow = 0;
        bool dragPreview = false;
        int resizeEdge = 0, previewRow = 0;
        double previewStart = 0, previewEnd = 0;
        double pointerPosition(double time, ModifierKeys modifiers, bool subplay) const {
            const auto *song=t.w.session.song();
            return !subplay && song ? timelineGrid::snapCursor(time,*song,t.w.pixelsPerSecond,t.w.freeTimelinePosition(modifiers)) : time;
        }
        void updateDrag(const MouseEvent &e) { updateDrag(e.position,e.mods); }
        void repaintItemEdgeGuides() {
            if (dragClip.empty()) return;
            const double from=dragPreview ? previewStart : originalStart;
            const double to=dragPreview ? previewEnd : originalStart+clipLength;
            // These guides span every track, while the item preview only
            // invalidates its affected rows. Clear both old and new columns
            // in the buffered canvas without redrawing the entire grid.
            for (const auto time : {from,to})
                repaint(roundToInt(t.xAt(time))-2,headerHeight(),5,std::max(0,getHeight()-headerHeight()));
        }
        void updateDrag(Point<float> point, ModifierKeys modifiers) {
            repaintItemEdgeGuides();
            double edge = (resizeEdge > 0 ? originalStart + clipLength : originalStart) +
                          t.timeAt(point.x) - startTime;
            edge = std::max(0., edge);
            auto excluded = t.w.selectedClips; excluded.insert(dragClip);
            if (const auto *song = t.w.session.song()) {
                refreshItemSnapEdges(*song);
                edge = timelineGrid::snapSelection(edge,*song,t.w.pixelsPerSecond,
                                                   t.w.session.transport(),t.w.freeTimelinePosition(modifiers), &excluded, &itemSnapEdges);
            }
            previewStart =
                resizeEdge > 0
                    ? originalStart
                    : std::min(edge, resizeEdge < 0 ? originalStart + clipLength - .01 : edge);
            previewEnd = resizeEdge < 0   ? originalStart + clipLength
                         : resizeEdge > 0 ? std::max(originalStart + .01, edge)
                                          : previewStart + clipLength;
            previewRow = resizeEdge ? sourceRow : t.w.rowAt(roundToInt(point.y) - headerHeight() + t.w.verticalOffset);
            if (previewRow < 0 || previewRow >= t.w.rows.size())
                previewRow = sourceRow;
            if(const auto *song=t.w.session.song(); song && dragOriginalValid && dragOriginalClip && sourceRow>=0 && sourceRow<(int)song->tracks.size()) {
                const auto &source=song->tracks[(size_t)sourceRow];
                const auto &target=song->tracks[(size_t)previewRow];
                if(resizeEdge) std::tie(previewStart,previewEnd)=clipEditing::constrainedEdges(target,*dragOriginalClip,previewStart,previewEnd);
                else {previewStart=clipEditing::constrainedStart(target,*dragOriginalClip,previewStart);previewEnd=previewStart+clipLength;}
                if (resizeEdge) {
                    auto moved=*dragOriginalClip;
                    if (source.role.id == "timecode" && !clipEditing::projection(moved)) {
                        moved.startTime=previewStart; moved.duration=previewEnd-previewStart;
                    } else moved=clipEditing::resizedSource(moved,previewStart,previewEnd);
                    resizedClipPreview=moved;
                } else {
                    if(!movingClipPreview) movingClipPreview=*dragOriginalClip;
                    movingClipPreview->startTime=previewStart;
                    movingClipPreview->duration=previewEnd-previewStart;
                    if(t.w.selectedClips.count(dragClip) && t.w.selectedClips.size()>1) {
                        double earliest=originalStart;
                        for(const auto &entry:dragSelectionPreviews) earliest=std::min(earliest,entry.originalStart);
                        const double delta=std::max(previewStart-originalStart,-earliest);
                        for(auto &entry:dragSelectionPreviews) entry.preview.startTime=entry.originalStart+delta;
                    }
                }
                refreshPreviewPlacements(*song);
            } else {
                previewPlacements.clear();
            }
            dragPreview = true;
            repaintItemEdgeGuides();
        }
    } canvas;
    class Heads final : public Component {
      public:
        int headerHeight() const { return t.headerHeight(); }
        explicit Heads(Timeline &timeline) : t(timeline) {}
        bool hasPainted=false;double paintedMainX=0,paintedMainPosition=0;
        void paint(Graphics &g) override {
            const auto state = t.playbackFrame ? *t.playbackFrame : t.w.session.presentationTransport();
            hasPainted=true;paintedMainX=t.xAt(state.position);paintedMainPosition=state.position;
            auto head = [&](double position, Colour colour, bool playback) {
                float x = t.xAt(position);
                if (x < 0 || x > getWidth())
                    return;
                // Current Mac native geometry: the edit tip crosses the ruler
                // by one point; playback's head begins at the track boundary.
                const float top = playback ? (float)headerHeight() : headerHeight() - 11.f;
                const float tip = playback ? headerHeight() + 9.f : headerHeight() + 1.f;
                const float lineStart = playback ? (float)headerHeight() : tip;
                g.setColour(colour.withMultipliedAlpha(.12f));
                g.fillRect(x - 3, lineStart, 6.f, std::max(0.f, getHeight() - lineStart));
                g.setColour(colour);
                g.fillRect(x - .75f, lineStart, 1.5f, std::max(0.f, getHeight() - lineStart));
                Path p;
                p.addTriangle(x - 7, top, x + 7, top, x, tip);
                g.fillPath(p);
            };
            head(state.editPosition, t.w.appearance.colour("jaras.timeline.editCursor", 0xb9e229),
                 false);
            if (state.playing || state.paused)
                head(state.position, t.w.appearance.colour("jaras.timeline.playCursor", 0x7548dd),
                     true);
            if (t.w.session.subCursorVisible()) {
                head(state.subPlay.position,
                     t.w.appearance.colour("jaras.timeline.subPlayCursor", 0xff6f00).withMultipliedAlpha(
                         Session::subCursorOpacity(Time::getMillisecondCounterHiRes() / 1000)), false);
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

class Workspace::DetachedSetlistPanel final : public Component {
  public:
    explicit DetachedSetlistPanel(Workspace &owner) : w(owner) {
        addAndMakeVisible(*w.setlist);
        addChildComponent(*w.partsSidebar);
        addChildComponent(w.partsRightDivider);
        addAndMakeVisible(divider);
        divider.scrollMetrics=[this]{return w.setlist->scrollMetrics();};
        divider.scrollTo=[this](int y){w.setlist->scrollTo(y);};
    }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
    void resized() override {
        const int parts = w.partsRightVisible
            ? jlimit(160,std::max(160,getWidth()-minimumSetlistWidth),w.partsRightWidth>0?w.partsRightWidth:360) : 0;
        const int listWidth=std::max(1,getWidth()-parts);
        w.setlist->setBounds(0,0,listWidth,getHeight());
        w.setlist->setVisible(true);
        w.setlist->setPartsVisible(w.partsRightVisible);
        w.partsSidebar->setBounds(listWidth,0,parts,getHeight());
        w.partsSidebar->setVisible(w.partsRightVisible);
        divider.setBounds(listWidth-6,0,6,getHeight());
        divider.setVisible(!w.partsRightVisible);
        divider.refreshScroll();
        w.partsRightDivider.setVisible(w.partsRightVisible);
        w.partsRightDivider.setBounds(listWidth-3,0,6,getHeight());
        w.partsRightDivider.refreshScroll();w.partsRightDivider.toFront(false);
    }
  private:
    Workspace &w;
    DragDivider divider;
};

TextButton &Workspace::button(String id, const String &title, std::function<void()> action,
                              Colour colour) {
    auto *b = buttons.add(id=="audioStatus" ? new FooterAudioStatusButton() : new QuietButton(title));
    if (!StringArray{"play", "pause", "subplay", "loop", "record", "metronome"}.contains(id))
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
class Workspace::TrackHeightHandle final : public Component, private Timer {
    Workspace &w;
    ID trackID, songID; int startY=0, count=1; double startHeight=0, denominator=1, initialScale=1;
    double pendingScale=1;
    bool pendingHeight=false;
    void timerCallback() override {
        if(trackID.empty()) {stopTimer();return;}
        if(!w.session.song() || w.session.song()->id!=songID){cancel();return;}
        if(!pendingHeight)return;
        pendingHeight=false;
        w.trackHeightPreview=std::pair<ID,double>{trackID,pendingScale};
        w.resized();w.timeline->updateRanges();w.tracksViewport.repaint();
    }
    std::optional<int> edge(int x,int y) const {
        if(!w.session.song() || !w.projectReady || w.browserVisible) return {};
        auto p=getParentComponent()->getLocalPoint(this,Point<int>{x,y});
        if(!w.mixerVisible || !w.tracksViewport.getBounds().contains(p) ||
           w.mixerDivider.getBounds().contains(p)) return {};
        const int local=y+w.tracksViewport.getViewPositionY();
        for(int i=0;i<w.rows.size();++i) if(!w.rowHidden(i)) {
            int top=w.rowTop(i),bottom=top+w.rowBodyHeight(i);
            // The footer belongs to this row only. The next row's top and the
            // timeline at the same Y position retain their ordinary input.
            if(local>=std::max(top,bottom-6) && local<bottom)return i;
        }
        return {};
    }
  public:
    explicit TrackHeightHandle(Workspace &owner):w(owner){setComponentID("trackHeightHandle");setMouseCursor(MouseCursor::UpDownResizeCursor);setWantsKeyboardFocus(true);}
    bool hitTest(int x,int y) override {auto m=ModifierKeys::getCurrentModifiers();return !m.isAnyModifierKeyDown() && edge(x,y).has_value();}
    void mouseDown(const MouseEvent &e) override {
        if(!e.mods.isLeftButtonDown() || e.mods.isAnyModifierKeyDown())return;
        if(auto at=edge(e.x,e.y)) {int i=*at;const auto &track=w.session.song()->tracks[(size_t)i];
            trackID=track.id;songID=w.session.song()->id;startY=e.getScreenY();count=w.itemLanes(i).count;
            startHeight=w.rowBodyHeight(i);denominator=w.trackHeight*(count>1?.7:1.);initialScale=track.heightScale.value_or(1.);
            pendingScale=initialScale;pendingHeight=false;
            w.trackHeightPreview=std::pair<ID,double>{trackID,initialScale};grabKeyboardFocus();
        }
    }
    void mouseDrag(const MouseEvent &e) override {
        if(trackID.empty())return;
        if(!w.session.song() || w.session.song()->id!=songID){cancel();return;}
        const double scale=std::max(.01,(double)getApproximateScaleFactorForComponent(this));
        double lane=jlimit(count>1?26.:24.,count>1?168.:240.,std::round((startHeight+(e.getScreenY()-startY)/scale)/count));
        const double next=jlimit(.1,10.,lane/denominator);
        if(next==pendingScale)return;
        pendingScale=next;pendingHeight=true;
        if(!isTimerRunning())startTimerHz(60);
    }
    void mouseUp(const MouseEvent &e) override {
        if(trackID.empty())return;mouseDrag(e);stopTimer();if(trackID.empty())return;
        const auto value=std::pair<ID,double>{trackID,pendingScale};pendingHeight=false;const auto song=songID;bool changed=std::abs(value.second-initialScale)>1e-8;
        trackID.clear();w.trackHeightPreview.reset();
        if(changed)w.perform([&]{w.session.edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==song)for(auto &t:s.tracks)if(t.id==value.first)t.heightScale=value.second;},false);});
        w.resized();w.timeline->updateRanges();w.repaint();w.grabKeyboardFocus();
    }
    void cancel(){stopTimer();pendingHeight=false;trackID.clear();w.trackHeightPreview.reset();w.resized();w.timeline->updateRanges();w.repaint();}
    bool keyPressed(const KeyPress &key) override {if(key.getKeyCode()==KeyPress::escapeKey && !trackID.empty()){cancel();w.grabKeyboardFocus();return true;}return false;}
    void mouseWheelMove(const MouseEvent &e,const MouseWheelDetails &wheel) override {
        // JUCE may retain the last mouse target while layout moves underneath
        // a stationary pointer. Route the wheel by its current position.
        if(w.timeline->getBounds().contains(e.getEventRelativeTo(&w).getPosition()))
            w.timeline->mouseWheelMove(e,wheel);
        else w.mouseWheelMove(e,wheel);
    }
};

void Workspace::paintOverChildren(Graphics &g) {
    if(externalDropPoint&&session.song()&&!externalDropFiles.empty()) {
        const auto local=timeline->getLocalPoint(this,*externalDropPoint);
        if(timeline->getLocalBounds().contains(local)&&local.y>=timeline->headerHeight()){
            const auto at=timelineGrid::snapSelection(timeline->timeAt((float)local.x),*session.song(),pixelsPerSecond,session.transport(),freeTimelinePosition(ModifierKeys::getCurrentModifiers()));
            const float x=timeline->getX()+timeline->xAt(at);
            const int row=rowAt(local.y-timeline->headerHeight()+verticalOffset);
            const int end=rowTop((int)session.song()->tracks.size());
            const auto colour=row>=0?theme::track(session.song()->tracks[(size_t)row]):Colour(0xff828282);
            const int top=timeline->getY()+timeline->headerHeight()-verticalOffset;
            Graphics::ScopedSaveState save(g);
            g.reduceClipRegion(timeline->getBounds().withTrimmedTop(timeline->headerHeight()));
            for(size_t i=0;i<externalDropFiles.size();++i) {
                const auto &file=externalDropFiles[i];
                const int y=top+(i==0&&row>=0?rowTop(row):end+(int)(i-(row>=0&&i>0?1:0))*trackHeight);
                const int height=i==0&&row>=0?itemLaneHeight(row):trackHeight;
                const juce::Rectangle<float> rect(x,y+3.f,std::max(1.f,file.duration?(float)(*file.duration*pixelsPerSecond):100.f),std::max(12.f,height-6.f));
                if(!rect.intersects(timeline->getBounds().toFloat()))continue;
                g.setColour(colour.withAlpha(.32f));g.fillRect(rect);
                const auto bar=rect.withHeight(std::min(15.f,rect.getHeight()));
                g.setColour(colour.withAlpha(.9f));g.fillRect(bar);
                Path edge,dashed;edge.addRectangle(rect);const float dash[]{4,2};
                PathStrokeType(1).createDashedStroke(dashed,edge,dash,2);
                g.setColour(Colours::white.withAlpha(.85f));g.fillPath(dashed);
                g.saveState();g.reduceClipRegion(bar.getSmallestIntegerContainer());
                g.setFont(theme::semiboldFont(10));g.setColour(Colours::white);
                g.drawText(file.file.getFileNameWithoutExtension(),bar.withLeft(std::max(bar.getX()+4,(float)timeline->getX()+4)),Justification::centredLeft,true);
                g.restoreState();
            }
            g.setColour(Colour::greyLevel(.9f).withAlpha(.6f));
            g.fillRect(x,(float)timeline->getY()+timeline->headerHeight(),1.f,(float)timeline->getHeight()-timeline->headerHeight());
        }
    }
    auto boundsFor=[&](const ID &id)->juce::Rectangle<int>{if(const auto *song=session.song()){auto i=trackTree::index(*song,id);if(i<(size_t)rows.size())return getLocalArea(rows[(int)i],rows[(int)i]->getLocalBounds().withWidth(rows[(int)i]->bodyWidth()));}return {};};
    Graphics::ScopedSaveState saved(g);g.reduceClipRegion(tracksViewport.getBounds());
    if(trackDropPreview){auto r=boundsFor(trackDropPreview->indicator);g.setColour(trackDropPreview->joins?theme::yellow:theme::green);g.fillRect(r.getX(),trackDropPreview->after?r.getBottom()-2:r.getY(),r.getWidth(),2);}
    if(!trackDropBlocked.empty()){auto r=boundsFor(trackDropBlocked);g.setColour(Colours::red);g.drawRect(r.reduced(2),2);g.setFont(theme::font(11));g.drawText("Destino indisponível",r,Justification::centred);}
}

Workspace::Workspace(Session &s, Auth &a, Lighting &l, bool homePreview, File appearanceFile, std::shared_ptr<remote::Host> host)
    : session(s), auth(a), lighting(l), appearance(std::move(appearanceFile)),
      actions(appearance, s.audio.devices), stage(appearance) {
    LookAndFeel::setDefaultLookAndFeel(&look);
    setLookAndFeel(&look);
    remotePresentation = std::make_unique<remote::Presentation>(session, stage);
    remoteHost = host ? std::move(host) : std::make_shared<remote::Host>(appearance);
    remoteHost->setHostName(auth.deviceName);
    const auto transportFont = auth.dataDirectory().getChildFile("Fonts/Inter-SemiBold.ttf");
    transportFont.getParentDirectory().createDirectory();
    if (!transportFont.existsAsFile() && !transportFont.replaceWithData(BinaryData::InterSemiBold_ttf, BinaryData::InterSemiBold_ttfSize))
        throw std::runtime_error("Não foi possível preparar a fonte do transporte.");
    masterPeakReadout=std::make_unique<meterDisplay::PeakReadout>([this]{return session.audio.heldPeak();},[this]{session.audio.clearPeak();},[this]{return theme::surfaceText(Colour(0xff000000|session.project().masterColor.value_or(0x414141)).withAlpha(.5f));});addAndMakeVisible(*masterPeakReadout);
    nativeTransport = std::make_unique<native::TransportButtons>(transportFont.getFullPathName().toWideCharPointer());
    remotePresentation->save = [this] { chooseSave(); };
    appearance.addChangeListener(this);
    try {
        session.audio.configureMetronome(metronomePreferences(appearance));
    } catch (const std::exception &e) {
        session.message = String::fromUTF8(e.what());
    }
    for (int slot = 0; slot < 6; ++slot)
        session.audio.setMIDISlot(
            slot, appearance.value("catlive.midi.slot" + String(slot + 1)).toString());
    for (int slot = 0; slot < 6; ++slot)
        session.audio.setMIDIOutputSlot(slot, appearance.value("catlive.midi.outputSlot" + String(slot + 1), slot == 0 ? session.audio.devices.getDefaultMidiOutputIdentifier() : String()).toString());
    localization::english = appearance.value("jaras.language", "pt-BR").toString() == "en";
    actions.invoke = [this](const String &id, float value, int track) {
        if (actions.inputEnabled.load() && projectReady && !loginPanel && !browserVisible) {
            ++actionInvocations[id];
            perform([&] { performAction(id, value, track); });
        }
    };
    trackVisibility.load(appearance,session.project().id);
    setOpaque(true);
    setWantsKeyboardFocus(true);
    setFocusContainerType(FocusContainerType::keyboardFocusContainer);
    caption = std::make_unique<Caption>(*this);
    timeline = std::make_unique<Timeline>(*this);
    trackHeightHandle=std::make_unique<TrackHeightHandle>(*this);addAndMakeVisible(*trackHeightHandle);
    setlist = std::make_unique<Setlist>(*this);
    setlist->setComponentID("setlistPanel");
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
            }, [this] { tempoTaps = {}; });
    addAndMakeVisible(*tempoControl);
    footerMixer = std::make_unique<MixerPanel>(
        session, [this](ID id, String effect) { openFX(id, effect); },
        [this](ID id, ModifierKeys mods) { selectMixerTrack(id, mods, true, true); },
        [this](String error) { showError(error); },
        [this](ID id, bool remove) { changeMixerFX(id, remove); },
        [this](ID id) { return trackSelected(id); }, [this](ID id,Point<int> point){showTrackMenu(id,point);},[this](ID id,String action){specialTrackAction(id,action);},
        [this](ID id){return !session.song()||trackVisibility.visible(*session.song(),TrackVisibility::Panel::barMixer,id);});
    syncBarMixerMasterSide();
    footerMixer->slotsOnlyChanged=[safe=SafePointer<Workspace>(this)](bool value){if(safe)safe->setHozMixerSlotsOnly(value);};
    syncHozMixerMode();
    addAndMakeVisible(dockViewport);
    dockViewport.setViewedComponent(&dockContent, false);
    dockViewport.setScrollBarsShown(true, false);
    dockViewport.setScrollBarThickness(10);
    dockViewport.setScrollOnDragMode(Viewport::ScrollOnDragMode::never);
    dockContent.addChildComponent(*footerMixer);
    partsLeft =
        std::make_unique<PartsPanel>(session, [this](String message) { showError(message); });
    addChildComponent(*partsLeft);
    partsLeft->setComponentID("partsLeft");
    partsSidebar =
        std::make_unique<PartsPanel>(session, [this](String message) { showError(message); });
    addChildComponent(*partsSidebar);
    partsSidebar->setComponentID("partsRight");
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
    vinhetasPanel = std::make_unique<VinhetasPanel>(session.audio.vinhetas, appearance);
    dockContent.addChildComponent(*vinhetasPanel);
    actions.rawMIDI = [this](int status,int number,int value,int channel) { return projectReady&&!loginPanel&&!browserVisible&&vinhetasPanel->midi(status,number,value,channel); };
    actions.externalMIDIConflict = [this](const var &input) { return vinhetasPanel->setlistBlockMIDIConflict(input); };
    actions.transferExternalMIDI = [this](const var &input) { return vinhetasPanel->removeSetlistBlockMIDIConflicts(input); };
    vinhetasPanel->createTrack = [this] { perform([&] {
        if (!session.song()) return;
        session.edit([&](jaras::Project &project) {
            for (auto &song : project.songs) if (song.id == session.song()->id) {
                if (std::any_of(song.tracks.begin(), song.tracks.end(), [](const auto &track) { return track.role.id == "vinhetas"; })) return;
                jaras::Track track; track.id=uuid(); track.name="VINHETAS-FX"; track.role.id="vinhetas"; track.color=0x828282;
                auto at=std::find_if(song.tracks.begin(),song.tracks.end(),[](const auto &t){return t.role.id=="generatedClick";});
                song.tracks.insert(at,track);
            }
        });
    }); };
    vinhetasPanel->edit = [this](String name,unsigned colour,std::function<void(String,unsigned)> save) {
        auto safe=SafePointer<Workspace>(this);
        auto close=[safe]{if(safe)ModalSheet::dismiss(*safe);};
        ModalSheet::open(*this,"Editar",std::make_unique<RegionEditor>(name,colour,false,[save,close](String n,unsigned c,bool){save(n,c);close();},close,false),300,370);
    };

    tracksViewport.setViewedComponent(&tracksContent, false);
    tracksViewport.setScrollBarsShown(false, false, false, false);
    tracksViewport.setScrollBarThickness(8);
    tracksViewport.setScrollOnDragMode(Viewport::ScrollOnDragMode::never);
    tracksViewport.pressed=[this](const MouseEvent &event){mouseDown(event);};
    tracksViewport.wheel=[this](const MouseEvent &event,const MouseWheelDetails &details){mouseWheelMove(event,details);};
    tracksViewport.moved=[this] {
        const auto y=tracksViewport.getViewPositionY();
        if(y==verticalOffset)return;
        verticalOffset=y;timeline->scrollVerticallyTo(y);mixerDivider.refreshScroll();
    };
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
    button("export", localization::translate("Exportar"), [this] { chooseExport(); });
    button("settings", String::fromUTF8("⚙"), [this] {
        openSettings();
    }).setTooltip(String::fromUTF8("Configurações · Ctrl+, "));
    button("audio", localization::translate(String::fromUTF8("Áudio")), [this] {
        openAudioSettings();
    }).setTooltip("Dispositivo, taxa de amostragem, buffer e roteamento ASIO / WASAPI");
    auto &audioStatus = button("audioStatus", "", [this] { openAudioSettings(); });
    static_cast<FooterAudioStatusButton &>(audioStatus).status=[this] {
        if(auto *device=session.audio.devices.getCurrentAudioDevice())
            return device->getName()+String::fromUTF8(" · ")+String(device->getCurrentBufferSizeSamples())+
                String::fromUTF8(" · ")+String((int)device->getCurrentSampleRate())+" Hz";
        return String::fromUTF8("Áudio não iniciado");
    };
    audioStatus.getProperties().set("plain", true);
    audioStatus.setColour(TextButton::buttonColourId, Colours::transparentBlack);
    audioStatus.setMouseCursor(MouseCursor::PointingHandCursor);
    audioStatus.setTitle(String::fromUTF8("Configurações de áudio"));
    audioStatus.setTooltip(String::fromUTF8("Abrir Configurações · Áudio"));
    for (const auto &spec : std::initializer_list<std::pair<const char *, int>>{{"previousProjectTab", -1}, {"nextProjectTab", 1}}) {
        const int direction = spec.second;
        auto &arrow = button(spec.first, {}, [this, direction] { if(navigateProjectTab) navigateProjectTab(direction); });
        arrow.getProperties().set("icon", direction < 0 ? "chevron.left" : "chevron.right");
        arrow.setTooltip(localization::translate(direction < 0 ? "Previous project tab" : "Next project tab"));
    }
    button("save", "Save", [this] {
        chooseSave();
    }).setTooltip(String::fromUTF8("Salvar · Ctrl+S"));
    static_cast<QuietButton &>(*controls["save"]).context = [this](Point<int>) {
        if (!projectReady || session.busy || session.audio.isRecording()) return;
        auto safe = SafePointer<Workspace>(this);
        auto panel=std::make_unique<ProjectSavePanel>(session.document == File() ? text(session.project().name) : session.document.getFileNameWithoutExtension(), [safe](String name) {
            if(!safe) return;
            const auto previous=safe->session.document;
            safe->session.renameProject(name);
            if(previous!=File()) { RecentProjects::forget(previous); RecentProjects::remember(safe->session.document); }
            else safe->chooseSave(false);
        }, [safe] {
            if(safe) safe->showPanel("Exportar para CatLive iPadOS", std::make_unique<PortableExportPanel>(safe->session,
                [safe](std::function<void()> saved) { if(safe) safe->chooseSave(false,std::move(saved)); }),540,376);
        }, [safe] {
            if(safe) safe->showPanel("Reduzir projeto",std::make_unique<ProjectReductionPanel>(safe->session,
                [safe](std::function<void()> saved){if(safe)safe->chooseSave(false,std::move(saved));}),760,
                safe->session.dirty||safe->session.isSaving()||!safe->session.document.existsAsFile()?206:560);
        });
        CallOutBox::launchAsynchronously(std::move(panel),controls["save"]->getScreenBounds(),nullptr);
    };
    button("mixer", "Tracks", [this] {
        mixerVisible = !mixerVisible;
        resized();
    }).setTooltip("Track Mixer");
    button("setlist", "Setlist", [this] {
        setlistVisible = !setlistVisible;
        resized();
    });
    static_cast<QuietButton &>(*controls["setlist"]).context = [this](Point<int> point) { setlistMenu(point); };
    button("masterMute", "M", [this] { session.command(jaras::CommandKind::mute); });
    button("masterSolo", "S", [this] { session.command(jaras::CommandKind::solo); });
    button("masterMono", localization::translate(String::fromUTF8("Estéreo")),
           [this] { session.command(jaras::CommandKind::masterMono); });
    button("masterPatch", "Patch", [this] { handleMasterMenu(1, false); });
    button("masterFX", "FX", [this] { openFX(); });
    fxchain::bind(static_cast<QuietButton &>(*controls["masterFX"]), session, {},
                  [this](bool remove) { changeMixerFX({}, remove); });
    button(
        "record", String::fromUTF8("● REC"), [this] {
            try { session.toggleRecording(); }
            catch (const std::exception &error) { showError(String::fromUTF8(error.what()), "Recording"); }
        },
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
            refreshMixerIndicator();
            return;
        }
        footerMixerVisible = !footerMixerVisible;
        resized();
        repaint();
    }).setTooltip("Hoz-Mixer");
    static_cast<QuietButton *>(controls["railMixer"])->context = [this](Point<int> point) { mixerMenu(point); };
    button("railParts", "Parts", [this] { toggleLeftParts(); }).setTooltip("Parts");
    static_cast<QuietButton *>(controls["railParts"])->context = [this](Point<int> point) { leftPartsMenu(point); };
    button("railVinhetas", "▦", [this] {
        if(vinhetasDetached) { auto at=floatingWindows.find("Vinhetas");if(at!=floatingWindows.end())at->second->setVisible(!at->second->isVisible()); }
        else { vinhetasVisible=!vinhetasVisible;resized(); }
    });
    static_cast<QuietButton &>(*controls["railVinhetas"]).context=[this](Point<int>){
        PopupMenu menu;menu.addItem(1,vinhetasDetached?localization::translate("Indexar"):localization::translate("Desindexar"));
        auto safe=Component::SafePointer<Workspace>(this);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(controls["railVinhetas"]),[safe](int result){if(safe&&result==1)safe->toggleVinhetasDock();});
    };
    button("railKeyboard", String::fromUTF8("♮"), [this] {
        keyboardVisible = !keyboardVisible;
        resized();
        repaint();
    }).setTooltip("Keyboard");
    button("soundfont", "SF2", [this] { chooseSoundFont(); });
    button("video", "Video", [this] { openVideo(); });
    static_cast<QuietButton &>(*controls["video"]).context=[safe=SafePointer<Workspace>(this)](Point<int> point){
        PopupMenu menu;
        menu.addItem(1,"Stretch",true,(bool)safe->appearance.value("jaras.video.stretch", false));
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe](int choice){
            if(!safe||choice!=1)return;
            const bool stretched=(bool)safe->appearance.value("jaras.video.stretch", false);
            safe->appearance.set("jaras.video.stretch", !stretched);
        });
    };
    button("railTeleprompt", "T", [this] { showTeleprompter(); }).setTooltip("TP 1 - Teleprompter 1");
    button("tp1", "TP-1", [this] { showTeleprompter(1); }, Colour(0xffc44848));
    button("tp2", "TP-2", [this] { showTeleprompter(2); }, Colour(0xffc44848));
    button("notices", localization::translate("Recados"), [this] { openNotices(); }, Colour(0xff897934));
    for(int i=0;i<2;++i) {
        teleprompterHTTP[(size_t)i]=std::make_unique<TeleprompterHTTP>();
        static_cast<QuietButton &>(*controls[i?"tp2":"tp1"]).context=[safe=SafePointer<Workspace>(this),i](Point<int> point){
            PopupMenu menu;menu.addItem(1,localization::translate(String::fromUTF8("Configurações")));menu.addItem(2,localization::translate("TP Remoto"));
            menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe,i](int choice){
                if(!safe)return;if(choice==1)safe->openStageConfig(i+1);if(choice==2)safe->openTPRemote(i+1);
            });
        };
    }
    auto &previewButton=button("preview", "Preview", [this] { stage.preview = !stage.preview; }, Colour(0xffc44545));
    static_cast<QuietButton &>(previewButton).context=[safe=SafePointer<Workspace>(this)](Point<int>){
        if(!safe)return;
        auto panel = std::make_unique<StagePreviewPanel>(safe->stage);
        CallOutBox::launchAsynchronously(std::move(panel), safe->controls["preview"]->getBounds(), safe.getComponent());
    };
    auto &remoteButton = button("remote", "Remote", [this] { toggleRemote(); }, theme::liveOffRed);
    remoteButton.getProperties().set("flat", true);
    remoteButton.setTooltip(String::fromUTF8("Remote · clique direito para configurar"));
    static_cast<QuietButton &>(remoteButton).context = [this](Point<int>) { openRemote(); };
    button("railNotice", "", [this] { openNotices(); }).getProperties().set("icon", "notice");
    button("railClock", "", [this] { openTimer(); }).getProperties().set("icon", "clock");
    controls["railNotice"]->setTooltip("Recados");
    controls["railClock"]->setTooltip(String::fromUTF8("Cronômetro"));
    controls["railNotice"]->getProperties().set("plain", true);
    controls["railClock"]->getProperties().set("plain", true);
    controls["railNotice"]->setColour(TextButton::textColourOffId, Colour(0xffe7c74c));
    controls["railClock"]->setColour(TextButton::textColourOffId, Colour(0xff299df8));
    button("railTeleprompt2", "TP2", [this] { showTeleprompter(2); }).setTooltip("TP 2 - Teleprompter 2");
    controls["railTeleprompt"]->setButtonText("TP1");
    button("railSettings", String::fromUTF8("⚙"), [this] {
        openSettings();
    }).setTooltip(String::fromUTF8("Configurações"));
    button("railHelp", "?", [this] { showShortcuts(); }).setTooltip(localization::translate("Atalhos"));
    for (auto id : {"menu", "mixer", "railMixer", "railKeyboard", "railParts", "railVinhetas", "settings",
                    "loop", "pause"})
        controls[id]->getProperties().set("icon", id);
    for (auto id : {"menu", "mixer", "railMixer", "railKeyboard", "railParts", "railVinhetas", "settings",
                    "railTeleprompt", "railTeleprompt2"})
        controls[id]->getProperties().set("plain", true);
    for (auto id : {"play", "pause", "subplay", "loop", "record", "metronome", "video", "tp1", "tp2",
                    "notices", "preview", "remote", "save", "setlist", "export", "resolume", "grandma2", "advanced",
                    "masterMute", "masterSolo", "masterMono", "masterPatch", "masterFX"})
        controls[id]->getProperties().set("flat", true);
    for (auto id : {"railTeleprompt", "railTeleprompt2"})
        controls[id]->setColour(TextButton::textColourOffId, Colour(0xffff5555));
    controls["mixer"]->setColour(TextButton::textColourOffId, theme::green);
    controls["setlist"]->setColour(TextButton::buttonColourId, theme::green);
    controls["setlist"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["video"]->setColour(TextButton::buttonColourId, theme::liveOffRed);
    for(auto id:{"tp1","tp2","preview"})controls[id]->setColour(TextButton::buttonColourId,theme::liveOffRed);
    controls["loop"]->setColour(TextButton::buttonColourId, theme::liveOffRed);
    controls["loop"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["subplay"]->setColour(TextButton::buttonOnColourId, Colour(0xffffff00));
    controls["subplay"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["subplay"]->setColour(TextButton::textColourOnId, Colours::black);
    controls["subplay"]->getProperties().set("solidTransportColour", true);
    for (auto id : {"play", "subplay"}) {
        const auto colour = String(id) == "play" ? theme::transportPlay : Colour(0xffffff00);
        controls[id]->getProperties().set("transportColour", (int64)colour.getARGB());
    }
    controls["pause"]->setColour(TextButton::buttonColourId, Colour(0xff454545));
    for (auto id : {"masterMono", "masterPatch", "masterFX", "masterMute", "masterSolo"}) {
        auto &control = *controls[id];
        const bool compact = String(id) == "masterMute" || String(id) == "masterSolo";
        control.getProperties().set("macMasterControl", true);
        control.getProperties().set("compactTrackStyle", compact);
        control.setColour(TextButton::buttonColourId, Colours::white.withAlpha(compact ? .12f : .22f));
        control.setColour(TextButton::textColourOffId, Colours::white);
        control.setColour(TextButton::textColourOnId, compact ? Colours::black : theme::green);
    }
    controls["masterMono"]->setColour(TextButton::buttonOnColourId, Colours::white.withAlpha(.22f));
    controls["masterMute"]->setColour(TextButton::buttonOnColourId, Colour(0xffff4245));
    controls["masterSolo"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["metronome"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["metronome"]->setColour(TextButton::textColourOffId, Colours::white);
    controls["metronome"]->setColour(TextButton::textColourOnId, Colours::black);
    controls["metronome"]->setColour(TextButton::buttonColourId, Colour(0xff454545));
    controls["remote"]->setColour(TextButton::textColourOffId, Colours::black);
    for(auto id:{"record","tp1","tp2","notices","preview","video"}) {
        controls[id]->setColour(TextButton::buttonColourId,theme::liveOffRed);
        controls[id]->setColour(TextButton::textColourOffId,Colours::black);
        controls[id]->setColour(TextButton::textColourOnId,Colours::black);
    }
    for(auto id:{"advanced","grandma2","resolume","export"})
        controls[id]->setColour(TextButton::buttonColourId,Colour(0xff454545));
    controls["record"]->setColour(TextButton::buttonColourId, theme::liveOffRed);
    controls["record"]->setButtonText("REC");
    for (auto spec : std::initializer_list<std::pair<const char *, const char *>>{
             {"play", "play"}, {"subplay", "play"}, {"record", "record"},
             {"tp1", "teleprompter"}, {"tp2", "teleprompter"}, {"notices", "notice"},
             {"video", "video"}, {"save", "save"}}) {
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
    addAndMakeVisible(timelineTimebase);
    timelineTimebase.setComponentID("timelineTimebase");
    timelineTimebase.setTitle("Relative timebase");
    timelineTimebase.getProperties().set("icon", "itemTimebase");
    timelineTimebase.getProperties().set("flat", true);
    timelineTimebase.setWantsKeyboardFocus(false);
    timelineTimebase.setColour(TextButton::buttonColourId, Colours::transparentBlack);
    timelineTimebase.setColour(TextButton::buttonOnColourId, Colours::transparentBlack);
    timelineTimebase.setColour(TextButton::textColourOffId, theme::yellow);
    timelineTimebase.setColour(TextButton::textColourOnId, theme::green);
    timelineTimebase.onClick = [safe=Component::SafePointer<Workspace>(this)] {
        if(!safe)return;
        const auto *song=safe->session.song();if(!song)return;
        const auto project=safe->session.project().id,songID=song->id;
        const bool relative=song->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase!=jaras::ProjectTimebase::relative;
        auto panel=std::make_unique<TimebaseConfirmationPanel>(relative,
            [safe,project,songID,relative] {
                if(!safe || safe->session.project().id!=project || !safe->session.song() || safe->session.song()->id!=songID)return;
                safe->perform([&]{const auto current=*safe->session.song();auto settings=current.timeSettings.value_or(jaras::ProjectTimeSettings{});
                    settings.timebase=relative?jaras::ProjectTimebase::relative:jaras::ProjectTimebase::free;
                    safe->session.configureTiming(current.bpm,current.beatsPerBar,current.beatUnit,settings);
                });
            });
        const int height=panel->preferredHeight();
        ModalSheet::open(*safe,localization::translate("Relative timebase"),std::move(panel),confirmationStyle::width,height);
    };
    addAndMakeVisible(timelineSnap);
    timelineSnap.setComponentID("timelineSnap");
    timelineSnap.getProperties().set("icon", "magnet");
    timelineSnap.getProperties().set("flat", true);
    timelineSnap.setColour(TextButton::buttonColourId, Colours::transparentBlack);
    timelineSnap.setColour(TextButton::buttonOnColourId, Colours::transparentBlack);
    timelineSnap.setWantsKeyboardFocus(false);
    timelineSnap.setColour(TextButton::textColourOnId, theme::green);
    timelineSnap.setColour(TextButton::textColourOffId, Colours::grey);
    timelineSnap.onClick = [this] {
        const auto result=appearance.set("jaras.timeline.snapEnabled", !(bool)appearance.value("jaras.timeline.snapEnabled",true));
        if (result.failed()) showError(result.getErrorMessage());
        updateState();
    };
    addAndMakeVisible(trackVisibilityButton);
    trackVisibilityButton.setComponentID("trackVisibilityManager");
    trackVisibilityButton.getProperties().set("icon","visibility");
    trackVisibilityButton.getProperties().set("flat",true);
    trackVisibilityButton.setWantsKeyboardFocus(false);
    trackVisibilityButton.setTooltip(String::fromUTF8("Gerenciar visibilidade das pistas"));
    trackVisibilityButton.onClick=[this]{openTrackVisibility();};
    timelineLock.onClick = [this] { perform([&] { session.edit([](jaras::Project &p) {
        p.timelineMovementLocked = !p.timelineMovementLocked.value_or(false);
    }, false); }); };
    projectBrowser = std::make_unique<ProjectBrowser>();
    addChildComponent(*projectBrowser);
    projectBrowser->createEmpty = [this] { createProject(false); };
    projectBrowser->createEmptyInNewTab = [this] {
        if (projectReady && openInNewProjectTab) createProject(false, 0, true);
    };
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
    projectBrowser->open = [safe = Component::SafePointer<Workspace>(this)](File file) {
        if (!safe) return;
        safe->openProject(file);
    };
    projectBrowser->openInNewTab = [this](File file) { if (projectReady && openInNewProjectTab) openInNewProjectTab(file); };
    projectBrowser->deleteProject = [this](File file) { deleteRecentProject(file); };
    projectBrowser->resume = [this] { projectOpened(false); };
    projectReady = session.inspection && !homePreview;
    browserVisible = !projectReady;
    session.changed = [this] {
        rebuild();
        updateState();
    };
    session.timingChanged = [this](bool geometry) {
        if (geometry) {
            timeline->updateRanges(); resized(); setlist->refresh();
        } else {
            if(itemLayoutRevision+1==session.revision)itemLayoutRevision=session.revision;
            if(itemTitleRevision+1==session.revision)itemTitleRevision=session.revision;
            tempoControl->retainTempoAfterMixerChange();
            timeline->refreshMixer(true);
        }
        tuner->repaint(); caption->repaint(); updateState();
    };
    session.mixerChanged = [this] {
        // Retain cached item layouts while repainting all affected group/solo
        // colours immediately. A toggle must not reconstruct the whole project.
        if(itemLayoutRevision+1==session.revision)itemLayoutRevision=session.revision;
        if(itemTitleRevision+1==session.revision)itemTitleRevision=session.revision;
        tempoControl->retainTempoAfterMixerChange();
        for(auto* row:rows)row->refreshMixer();
        if(footerMixerVisible)footerMixer->refreshVisible();
        for(const auto& entry:floatingWindows)
            if(auto* mixer=dynamic_cast<MixerPanel*>(entry.second->getContentComponent()))mixer->refreshVisible();
        timeline->refreshMixer();caption->repaint();updateState();
    };
    session.setlistChanged = [this] { refreshPlaybackState(); };
    session.transportChanged = [this] { refreshPlaybackState(); };
    session.selectionChanged = [this] {
        setlist->refresh();
        timeline->revealEditPosition();
        timeline->repaint();
        updateState();
    };
    session.tick = [this] { updateState(); };
    activateProjectTab();
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
    if (!remoteHost->enabled() && !session.inspection && (bool)appearance.value("jaras.remote.hostEnabled", false)) {
        try { remoteHost->start(); } catch (const std::exception &e) { session.message = String::fromUTF8(e.what()); }
    }
    mixerWidth = jlimit(281, 900, (int)appearance.value("jaras.trackColumnWidth", 281));
    setlistWidth = jlimit(minimumSetlistWidth, 900, (int)appearance.value("jaras.setlistWidth", 336));
    partsLeftWidth = jlimit(160,900,(int)appearance.value("catlive.partsLeftWidth",260));
    partsRightWidth = (int)appearance.value("catlive.partsRightWidth",0);
    if (partsRightWidth>0) partsRightWidth=jlimit(160,900,partsRightWidth);
    footerHeightSetting = jlimit(27, 161, (int)appearance.value("catlive.footerDisplayHeight", 27));
    mixerHeightSetting = jlimit(273, 724, (int)appearance.value("jaras.footerMixerHeight", 300));
    auto bindDivider = [this](DragDivider &divider, const String &id, int &value, int minimum, int maximum, int sign, const String &key) {
        addAndMakeVisible(divider); divider.setComponentID(id);
        divider.started = [this, &value] { resizeStart = value; };
        divider.moved = [this, &value, minimum, maximum, sign](int delta) { value = jlimit(minimum, maximum, resizeStart + sign * delta); resized(); repaint(); };
        divider.ended = [this, &value, key] { if (key.isNotEmpty()) appearance.set(key, value); };
    };
    bindDivider(mixerDivider, "trackMixerDivider", mixerWidth, 281, 900, 1, "jaras.trackColumnWidth");
    bindDivider(setlistDivider, "setlistDivider", setlistWidth, minimumSetlistWidth, 900, -1, "jaras.setlistWidth");
    setlistDivider.moved = [this](int delta) {
        setlistWidth=jlimit(minimumSetlistWidth,900,resizeStart+(setlistPlacement==SetlistPlacement::left?delta:-delta));
        resized(); repaint();
    };
    mixerDivider.scrollMetrics=[this] { return DragDivider::ScrollMetrics{tracksViewport.getViewPositionY(),tracksViewport.getViewHeight(),tracksContent.getHeight()}; };
    mixerDivider.scrollTo=[this](int y) {
        tracksViewport.scrollTo(y);
    };
    setlistDivider.scrollMetrics=[this] { return setlist->scrollMetrics(); };
    setlistDivider.scrollTo=[this](int y) { setlist->scrollTo(y); };
    for (auto *divider:{&partsLeftDivider,&partsRightDivider}) {
        addChildComponent(*divider);divider->setThinRail(true);
    }
    partsLeftDivider.setComponentID("partsLeftDivider");partsRightDivider.setComponentID("partsRightDivider");
    partsLeftDivider.started=[this]{resizeStart=partsLeft->getWidth();};
    partsRightDivider.started=[this]{resizeStart=partsSidebar->getWidth();};
    partsLeftDivider.moved=[this](int delta){resizePartsWidth(true,delta);};
    partsRightDivider.moved=[this](int delta){resizePartsWidth(false,delta);};
    partsLeftDivider.ended=[this]{const auto result=appearance.set("catlive.partsLeftWidth",partsLeftWidth);if(result.failed())showError(result.getErrorMessage());};
    partsRightDivider.ended=[this]{const auto result=appearance.set("catlive.partsRightWidth",partsRightWidth);if(result.failed())showError(result.getErrorMessage());};
    // Detached Setlist already used this boundary as its scroll rail. Keep that
    // vertical gesture while adding horizontal resizing of its Parts panel.
    partsRightDivider.scrollMetrics=[this]{return setlistPlacement==SetlistPlacement::detached?setlist->scrollMetrics():DragDivider::ScrollMetrics{};};
    partsRightDivider.scrollTo=[this](int y){if(setlistPlacement==SetlistPlacement::detached)setlist->scrollTo(y);};
    bindDivider(footerHeightDivider, "footerHeightDivider", footerHeightSetting, 27, 161, -1, "catlive.footerDisplayHeight");
    bindDivider(mixerHeightDivider, "mixerHeightDivider", mixerHeightSetting, 273, 724, -1, "jaras.footerMixerHeight");
    resourceUsage.sample();
    fadeoutOverlay = std::make_unique<TransportFadeoutOverlay>(session, [this] {
        session.cancelTransportFadeout();
    });
    addChildComponent(*fadeoutOverlay);
    session.audioOutputWarning = [safe = SafePointer<Workspace>(this)](String text) {
        if(safe) safe->showError(localization::translate(text));
    };
    session.transportFadeoutWarning = [safe = SafePointer<Workspace>(this)](String text) {
        if (safe && safe->fadeoutOverlay) safe->fadeoutOverlay->showWarning(std::move(text));
    };
    selectionAreas.add(tracksViewport, "tracks", [this] { return selectAllTracks(); });
    selectionAreas.add(*footerMixer, "tracks", [this] { return selectAllTracks(true); });
    selectionAreas.add(*timeline, "grid", [this] { return selectAllGridItems(); });
    selectionAreas.add(*setlist, "setlist", [this] { return setlist->selectAllItems(); });
    selectionAreas.activate(*timeline);
    layoutInitialized = true;
    restoreWorkspaceLayout();
    startTimerHz(30);
}
void Workspace::saveWorkspaceLayout() {
    if (!layoutInitialized || !layoutActive || restoringLayout || !projectReady || browserVisible) return;
    auto state = object();
    put(state,"tracksVisible",mixerVisible); put(state,"setlistVisible",setlistVisible);
    put(state,"mixerDetached",mixerDetached); put(state,"mixerOpen",footerMixerVisible);
    put(state,"partsDetached",partsLeftDetached); put(state,"partsOpen",partsLeftVisible);
    put(state,"partsRightOpen",partsRightVisible);
    put(state,"vinhetasDetached",vinhetasDetached);put(state,"vinhetasOpen",vinhetasVisible);
    put(state,"setlistPlacement",(int)setlistPlacement); put(state,"setlistDockSide",(int)setlistDockSide);
    put(state,"trackWidth",mixerWidth); put(state,"setlistWidth",setlistWidth);
    put(state,"partsLeftWidth",partsLeftWidth); put(state,"partsRightWidth",partsRightWidth);
    put(state,"mixerHeight",mixerHeightSetting); put(state,"footerHeight",footerHeightSetting);
    for (const auto &name : {String("Mixer"), String("Parts"), String("Vinhetas")}) {
        const auto at = floatingWindows.find(name);
        const bool visible = at != floatingWindows.end() && at->second->isVisible();
        put(state,name+"Visible",visible);
        if (at != floatingWindows.end()) put(state,name+"Frame",at->second->getWindowStateAsString());
        else put(state,name+"Frame",get(appearance.value("jaras.workspace.layout"),Identifier(name+"Frame")));
    }
    if (setlistWindow) put(state,"SetlistFrame",setlistWindow->getWindowStateAsString());
    else put(state,"SetlistFrame",get(appearance.value("jaras.workspace.layout"),"SetlistFrame"));
    const auto encoded=JSON::toString(state,true);
    if (encoded == lastSavedLayout) return;
    if (appearance.set("jaras.workspace.layout",state).wasOk()) lastSavedLayout=encoded;
}
void Workspace::restoreWorkspaceLayout() {
    if (!layoutInitialized || restoringLayout) return;
    const ScopedValueSetter<bool> restoring(restoringLayout,true);
    appearance.reload();
    syncHozMixerMode();
    const auto state=appearance.value("jaras.workspace.layout");
    if (!state.isObject()) return;
    mixerVisible=flag(state,"tracksVisible",true); setlistVisible=flag(state,"setlistVisible",true);
    footerMixerVisible=flag(state,"mixerOpen"); mixerDetached=flag(state,"mixerDetached");
    partsLeftVisible=flag(state,"partsOpen"); partsRightVisible=flag(state,"partsRightOpen");
    partsLeftDetached=flag(state,"partsDetached");
    mixerWidth=jlimit(281,900,(int)appearance.value("jaras.trackColumnWidth",num(state,"trackWidth",mixerWidth)));
    setlistWidth=jlimit(minimumSetlistWidth,900,(int)appearance.value("jaras.setlistWidth",num(state,"setlistWidth",setlistWidth)));
    partsLeftWidth=jlimit(160,900,(int)appearance.value("catlive.partsLeftWidth",num(state,"partsLeftWidth",partsLeftWidth)));
    partsRightWidth=jlimit(0,900,(int)appearance.value("catlive.partsRightWidth",num(state,"partsRightWidth",partsRightWidth)));
    mixerHeightSetting=jlimit(273,724,(int)appearance.value("jaras.footerMixerHeight",num(state,"mixerHeight",mixerHeightSetting)));
    footerHeightSetting=jlimit(27,161,(int)appearance.value("catlive.footerDisplayHeight",num(state,"footerHeight",footerHeightSetting)));
    const auto placement=(SetlistPlacement)jlimit(0,2,(int)num(state,"setlistPlacement",0));
    setlistDockSide=(SetlistPlacement)jlimit(0,1,(int)num(state,"setlistDockSide",0));
    if (projectReady && !browserVisible) {
        const bool wantedVinhetasDetached=flag(state,"vinhetasDetached");
        if(vinhetasDetached!=wantedVinhetasDetached)toggleVinhetasDock();
        vinhetasVisible=flag(state,"vinhetasOpen");
        if(auto at=floatingWindows.find("Vinhetas");at!=floatingWindows.end())at->second->setVisible(wantedVinhetasDetached&&flag(state,"VinhetasVisible",true));
        const bool showSetlist=setlistVisible, showParts=partsLeftVisible;
        setSetlistPlacement(placement);
        setlistDockSide=(SetlistPlacement)jlimit(0,1,(int)num(state,"setlistDockSide",0));
        setlistVisible=showSetlist; partsLeftVisible=showParts;
        if (setlistWindow && str(state,"SetlistFrame").isNotEmpty())
            setlistWindow->restoreWindowStateFromString(str(state,"SetlistFrame"));
        if (mixerDetached && flag(state,"MixerVisible",true)) showDetachedMixer();
        else if (auto at=floatingWindows.find("Mixer");at!=floatingWindows.end()) at->second->setVisible(false);
        if (partsLeftDetached && flag(state,"PartsVisible",true)) detachLeftParts();
        else {
            if (!partsLeftDetached) addChildComponent(*partsLeft);
            if (auto at=floatingWindows.find("Parts");at!=floatingWindows.end()) at->second->setVisible(false);
        }
        for (const auto &name : {String("Mixer"), String("Parts"), String("Vinhetas")})
            if (auto at=floatingWindows.find(name);at!=floatingWindows.end() && str(state,Identifier(name+"Frame")).isNotEmpty())
                at->second->restoreWindowStateFromString(str(state,Identifier(name+"Frame")));
        resized(); repaint();
    } else setlistPlacement=placement;
    lastSavedLayout.clear();
}
Component &Workspace::windowCaption() { return *caption; }
void Workspace::resetProjectTab() {
    saveWorkspaceLayout();
    addChildComponent(*partsLeft); partsLeftDetached = false;
    for (const auto &entry : floatingWindows)
        if (entry.first == "Mixer" || entry.first == "Parts")
            appearance.set("jaras.detached." + entry.first, entry.second->getWindowStateAsString());
    floatingWindows.clear(); setlistWindow.reset();
    selectedTracks.clear(); selectedTrack.clear(); collapsedGroups.clear();
    session.newProject(); projectReady = false; browserVisible = true;
    showProjectBrowser();
}
void Workspace::deactivateProjectTab() {
    saveWorkspaceLayout();
    layoutActive = false;
    for (const auto &name : {"Mixer", "Parts"})
        if (auto it = floatingWindows.find(name); it != floatingWindows.end()) it->second->setVisible(false);
    if (setlistWindow) setlistWindow->setVisible(false);
    for (const auto &name : {String::fromUTF8("Configurações"), String::fromUTF8("Avançado"), String("Editor de texto")})
        if (auto it = floatingWindows.find(name); it != floatingWindows.end())
            it->second->closeButtonPressed();
    session.audio.keyboardState.allNotesOff(0);
    session.audio.liveInputEnabled = false;
    actions.inputEnabled = false;
    if (nativeTransport) nativeTransport->hide();
}
void Workspace::activateProjectTab() {
    layoutActive = true;
    restoreWorkspaceLayout();
    session.audio.liveInputEnabled = true;
    actions.resetMIDIState();
    actions.inputEnabled = true;
    remoteHost->presentation = [this](int panel) -> var {
        if (loginPanel) return var();
        if (!projectReady) return remoteHost->projectSnapshot(panel, var());
        auto state = remotePresentation->snapshot(panel);
        if (vinhetasPanel) {
            const auto *song=session.song();
            const bool available=song&&std::any_of(song->tracks.begin(),song->tracks.end(),[](const auto &track){return track.role.id=="vinhetas";});
            put(state,"vinhetas",vinhetasPanel->remoteSnapshot(available));
        }
        if (remoteProjectTabs) put(state, "projectTabs", remoteProjectTabs());
        const auto now = Time::getMillisecondCounterHiRes();
        if (remoteRecentReadAt == 0 || now - remoteRecentReadAt >= 1000) {
            remoteRecentPaths = RecentProjects::read(); remoteRecentReadAt = now;
        }
        auto projects = object();
        put(projects, "recent", remoteProjectCatalog.update(remoteRecentPaths, session.document));
        put(projects, "busy", session.busy);
        put(projects, "canOpen", !session.busy && !session.audio.isRecording());
        put(projects, "canOpenInNewTab", bool(openInNewProjectTab));
        put(projects, "status", session.busy ? "Opening project…" : session.audio.isRecording() ? "Stop recording on the PC to open a project." : "");
        put(projects, "error", remoteProjectError);
        put(state, "projects", projects);
        return remoteHost->projectSnapshot(panel, state);
    };
    remoteHost->perform = [safe = SafePointer<Workspace>(this)](const remote::Command &command) {
        if (!safe) return false;
        if(command.action=="vinhetasUp"&&safe->vinhetasPanel){safe->vinhetasPanel->remoteUp(command.target);return true;}
        if (!safe->projectReady || safe->loginPanel || safe->browserVisible) return false;
        if(command.action.startsWith("vinhetas")){
            if(!safe->vinhetasPanel||remote::wireID(command.project)!=remote::wireID(safe->session.project().id))return false;
            auto &panel=*safe->vinhetasPanel;
            if(command.action=="vinhetasDown")return panel.remoteDown(command.target,command.preset,command.pad);
            if(command.action=="vinhetasPreset"){panel.select((int)command.value);return true;}
            if(command.action=="vinhetasVolume"){panel.remoteVolume(command.preset,command.pad,command.value);return true;}
            if(command.action=="vinhetasGate"){panel.remoteGate(command.preset,command.pad,*command.enabled);return true;}
            if(command.action=="vinhetasPanic"){panel.remotePanic();return true;}
            return false;
        }
        if (command.action == "selectProjectTab" || command.action == "closeProjectTab") {
            const bool close = command.action == "closeProjectTab";
            if (!(close ? bool(safe->closeRemoteProjectTab) : bool(safe->selectRemoteProjectTab)) ||
                remote::wireID(command.project) != remote::wireID(safe->session.project().id)) return false;
            // Activate after the current Remote callback returns: activation replaces
            // that callback while keeping the existing clients connected.
            const auto project = safe->session.project().id;
            const auto target = command.target;
            MessageManager::callAsync([safe, project, target, close] {
                if (!safe || safe->session.project().id != project || safe->remoteHost->projectOpening.active()) return;
                const auto action = close ? safe->closeRemoteProjectTab : safe->selectRemoteProjectTab;
                if (action) action(remote::wireID(target));
            });
            return true;
        }
        if (command.action == "openRecentProject" || command.action == "openRecentProjectInNewTab") {
            if (remote::wireID(command.project) != remote::wireID(safe->session.project().id)) return false;
            auto host = safe->remoteHost;
            if (!host->projectOpening.begin(command.id)) return false;
            // Capture before a new tab replaces the presentation callback.
            (void)host->presentation(0);
            const auto reject = [host, id = command.id](const String &message) {
                host->projectOpening.update(id, remote::ProjectOpening::State::failed, {}, utf8(message));
                return false;
            };
            if (safe->session.busy || safe->session.audio.isRecording())
                return reject("Wait for the current operation or stop recording on the PC.");
            safe->remoteProjectError.clear();
            // Revalidate the catalog before resolving a potentially stale command.
            safe->remoteRecentPaths = RecentProjects::read();
            safe->remoteProjectCatalog.update(safe->remoteRecentPaths, safe->session.document);
            const auto file = safe->remoteProjectCatalog.file(command.target);
            if (!file || !file->existsAsFile()) {
                safe->remoteProjectError = "This project is no longer available in the PC's recent projects.";
                return reject(safe->remoteProjectError);
            }
            const bool inNewTab = command.action == "openRecentProjectInNewTab";
            if (inNewTab && !safe->openRemoteProjectInNewTab) return reject("Opening another tab is unavailable.");
            if (*file == safe->session.document) {
                host->projectOpening.update(command.id, remote::ProjectOpening::State::completed);
                return true;
            }
            const auto project = safe->session.project().id;
            MessageManager::callAsync([safe, host, request = command.id, project, file = *file, inNewTab] {
                if (!safe || safe->session.project().id != project || safe->session.busy || safe->session.audio.isRecording()) {
                    host->projectOpening.update(request, remote::ProjectOpening::State::cancelled);
                    return;
                }
                try {
                    if (inNewTab) safe->openRemoteProjectInNewTab(file, request);
                    else safe->openProject(file, {}, false, false, request);
                } catch (const std::exception &error) {
                    host->projectOpening.update(request, remote::ProjectOpening::State::failed, {}, error.what());
                    safe->showError(String::fromUTF8(error.what()));
                }
            });
            return true;
        }
        return safe->remotePresentation->apply(command);
    };
    remoteHost->image = [this](const remote::Command &command) {
        return projectReady && !loginPanel ? remotePresentation->image(command) : remote::Bytes{};
    };
    auth.changed = [this] {
        try { remoteHost->setHostName(auth.deviceName); }
        catch (const std::exception &e) { session.message = String::fromUTF8(e.what()); }
        updateLogin(); caption->repaint();
    };
    LookAndFeel::setDefaultLookAndFeel(&look);
    resized(); updateState(); repaint();
}
Workspace::~Workspace() {
    saveWorkspaceLayout();
    if(externalDropCancelled)externalDropCancelled->store(true);
    nativeTransport.reset();
    stopTimer();
    if (remoteHost.use_count() == 1) remoteHost->stop();
    appearance.removeChangeListener(this);
    floatingWindows.clear();
    setlistWindow.reset();
    session.changed = {};
    session.mixerChanged = {};
    session.timingChanged = {};
    session.setlistChanged = {};
    session.transportChanged = {};
    session.selectionChanged = {};
    session.tick = {};
    session.transportFadeoutWarning = {};
    session.audioOutputWarning = {};
    auth.changed = {};
    tracksViewport.clearCallbacks();
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
void Workspace::showError(const String &text, const String &title) {
    if (logger)
        logger->logMessage(text);
    auto panel = std::make_unique<ValidationNoticePanel>(title, text);
    const int height = panel->preferredHeight();
    ModalSheet::open(*this, title, std::move(panel), 416, height);
}
void Workspace::showPanel(const String &name, std::unique_ptr<Component> panel, int width,
                          int height) {
    const bool floating =
        name.startsWithIgnoreCase("Teleprompter") || name == "Video" || name.startsWith("FX") ||
        name == "Patch" || name == "Timecode" || name == "Resolume" || name == "grandMA2" ||
        name == "Atalhos" || name == String::fromUTF8("Metrônomo") || name == String::fromUTF8("Cronômetro");
    {
        // The main window contains ProjectTabsHost; the active Workspace is
        // a visible descendant, not necessarily the direct content component.
        const auto findWorkspace = [](auto &&self, Component *component) -> Workspace * {
            if (!component || !component->isVisible()) return nullptr;
            if (auto *workspace = dynamic_cast<Workspace *>(component)) return workspace;
            for (auto *child : component->getChildren())
                if (auto *workspace = self(self, child)) return workspace;
            return nullptr;
        };
        auto &desktop = Desktop::getInstance();
        for (int i = desktop.getNumComponents(); --i >= 0;) {
            auto *window = dynamic_cast<DocumentWindow *>(desktop.getComponent(i));
            if (auto *workspace = findWorkspace(findWorkspace, window)) {
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
        // A Patch request may target another track while the previous window
        // stays open. Replace the editor, preserving its placement.
        if (name == "Patch" || name == "Timecode") {
            panel->setSize(width, height);
            it->second->setContentOwned(panel.release(), true);
        }
        it->second->setMinimised(false);
        it->second->toFront(true);
        return;
    }
    String savedPlacement;
    if (name == "Mixer" || name == "Parts") {
        auto previous = floatingWindows.find(name);
        savedPlacement = previous != floatingWindows.end()
            ? previous->second->getWindowStateAsString()
            : appearance.value("jaras.detached." + name).toString();
    }
    class PanelWindow final : public DocumentWindow {
      public:
        PanelWindow(const String &title, bool frameless)
            : DocumentWindow(title, theme::background, frameless ? 0 : DocumentWindow::allButtons, false) {
            setUsingNativeTitleBar(false);
            setTitleBarButtonsRequired(frameless ? 0 : DocumentWindow::allButtons, false);
            setTitleBarHeight(frameless ? 0 : 32);
            setResizable(!frameless, false);
            if (frameless) { setBackgroundColour(Colours::transparentBlack); setOpaque(false); }
            addToDesktop();
        }
        std::function<void()> onClose;
        std::function<bool(const KeyPress &)> selectAll;
        std::function<bool(const KeyPress &)> globalKey;
        std::function<void(bool)> globalKeyState;
        std::unique_ptr<FloatingShortcuts> shortcuts;
        bool escapeCloses = false;
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
            if (escapeCloses && key == KeyPress::escapeKey &&
                Component::getCurrentlyModalComponent() == nullptr) {
                closeButtonPressed();
                return true;
            }
            if (selectAll && selectAll(key))
                return true;
            if (FloatingShortcuts::allows(key) && globalKey && globalKey(key)) return true;
            return DocumentWindow::keyPressed(key);
        }
        bool keyStateChanged(bool down) override {
            if (globalKeyState) globalKeyState(down);
            return DocumentWindow::keyStateChanged(down);
        }
        void maximiseButtonPressed() override {
            if (auto *projection = dynamic_cast<Projection *>(getContentComponent())) {
                projection->toggleFullScreen();
                return;
            }
            DocumentWindow::maximiseButtonPressed();
        }
        void closeButtonPressed() override {
            if (onClose)
                onClose();
            setVisible(false);
        }
    };
    const bool effectsPanel = dynamic_cast<EffectsPanel *>(panel.get()) != nullptr;
    if (effectsPanel) {
        width = std::max(width, EffectsPanel::minimumContentWidth);
        height = std::max(height, EffectsPanel::minimumContentHeight);
    }
    const bool patchPanel = dynamic_cast<PatchPanel *>(panel.get()) != nullptr;
    auto window = std::make_unique<PanelWindow>(localization::translate(name == "Mixer" ? "Hoz-Mixer" : name), patchPanel);
    auto *settings = dynamic_cast<SettingsPanel *>(panel.get());
    const bool preferencesPanel = settings || dynamic_cast<AdvancedPanel *>(panel.get());
    window->escapeCloses = preferencesPanel || name == "Editor de texto" || name == "Patch" || name == "Timecode";
    window->globalKey = [safe = SafePointer<Workspace>(this),
                         settings = SafePointer<SettingsPanel>(settings)](const KeyPress &key) {
        if (settings && settings->keyPressed(key)) return true;
        return safe && safe->keyPressed(key);
    };
    window->globalKeyState = [safe = SafePointer<Workspace>(this)](bool down) {
        if (safe) safe->keyStateChanged(down);
    };
    if (auto *effects = dynamic_cast<EffectsPanel *>(panel.get())) {
        effects->globalKey = window->globalKey; effects->globalKeyState = window->globalKeyState;
        window->shortcuts = std::make_unique<FloatingShortcuts>(*window, window->globalKey, window->globalKeyState);
    } else if (preferencesPanel || name == "Parts" || name == "Patch" || name == "Timecode") {
        window->shortcuts = std::make_unique<FloatingShortcuts>(*window, window->globalKey, window->globalKeyState);
    }
    // Projection windows participate in normal window ordering so settings,
    // FX and plug-in windows can come to the front when opened.
    window->setAlwaysOnTop(false);
    if (name == "Mixer") window->selectAll = [safe = SafePointer<Workspace>(this)](const KeyPress &key) {
        return safe && safe->selectionAreas.selectAll(key);
    };
    panel->setSize(width, height);
    window->setContentOwned(panel.release(), true);
    const auto contentBorder = window->getContentComponentBorder();
    window->setResizeLimits(effectsPanel ? EffectsPanel::minimumContentWidth + contentBorder.getLeftAndRight() : preferencesPanel ? width : name.startsWith("Piano Roll") ? 760 : 360,
                            effectsPanel ? EffectsPanel::minimumContentHeight + contentBorder.getTopAndBottom() : preferencesPanel ? height + 32 : name.startsWith("Piano Roll") ? 440 : name == "Mixer" ? 305 : 240, 3840, 2160);
    window->centreAroundComponent(this, effectsPanel ? width + contentBorder.getLeftAndRight() : width,
                                  effectsPanel ? height + contentBorder.getTopAndBottom() : height + (patchPanel ? 0 : 32));
    if (savedPlacement.isNotEmpty()) window->restoreWindowStateFromString(savedPlacement);
    window->onClose = [safe = SafePointer<Workspace>(this), name, preferencesPanel,
                       closed = SafePointer<DocumentWindow>(window.get()),
                       settings = SafePointer<SettingsPanel>(settings)] {
        if (safe && closed && (name == "Mixer" || name == "Parts"))
            safe->appearance.set("jaras.detached." + name, closed->getWindowStateAsString());
        if (settings) settings->cancelLearning();
        if (safe && name == "Recados") safe->stage.clearNotice();
        Timer::callAfterDelay(1, [safe, name, preferencesPanel, closed] {
            if (!safe) return;
            if (preferencesPanel && closed && !closed->isVisible()) {
                auto it = safe->floatingWindows.find(name);
                if (it != safe->floatingWindows.end() && it->second.get() == closed.getComponent())
                    safe->floatingWindows.erase(it);
            }
            safe->updateState();
        });
    };
    window->setVisible(true);
    window->toFront(true);
    floatingWindows[name] = std::move(window);
}
void Workspace::syncNativeTransport() {
    if (!nativeTransport) return;
    auto *peer = getPeer();
    const bool visible = isShowing() && peer && projectReady && !browserVisible && !loginPanel && !audioPreparationOverlay;
    if (!visible) { nativeTransport->hide(); return; }
    // Match ComponentPeer::handlePaint: the peer size includes the application
    // scale, while getLocalArea is still in component coordinates. Monitor DPI
    // alone is insufficient when General is set to 60–120%.
    const auto peerBounds = peer->getBounds();
    const auto componentBounds = peer->getComponent().getLocalBounds();
    const float scaleX = (float)peer->getPlatformScaleFactor() * peerBounds.getWidth() / std::max(1, componentBounds.getWidth());
    const float scaleY = (float)peer->getPlatformScaleFactor() * peerBounds.getHeight() / std::max(1, componentBounds.getHeight());
    size_t index = 0;
    for (auto id : {"play", "pause", "subplay", "loop", "record", "metronome", "tp1", "tp2", "notices", "preview", "video", "remote", "save", "setlist", "export", "resolume", "grandma2", "advanced"}) {
        auto *model = controls[id];
        const auto area = peer->getComponent().getLocalArea(this, model->getBounds()).toFloat()
            .transformedBy(AffineTransform::scale(scaleX, scaleY)).getSmallestIntegerContainer();
        native::TransportButtons::State state;
        state.surface=theme::panel.getARGB();
        state.rect = {area.getX(), area.getY(), area.getRight(), area.getBottom()};
        state.scale = scaleY;
        state.dimming=1.f-model->getAlpha();
        state.savePulse=String(id)=="save" && session.dirty;
        state.recordPulse=String(id)=="record" && session.audio.isRecording();
        state.fontSize = theme::semiboldFont((float)model->getProperties().getWithDefault("fontSize", 10.f)).getHeightInPoints();
        state.active = model->getToggleState() || (bool)model->getProperties()["solidTransportColour"]; state.enabled = model->isEnabled();
        state.blocked = Component::getCurrentlyModalComponent() != nullptr;
        // Native child HWNDs draw above the parent surface. Keep the same dim
        // layer as the sheet, hiding only controls covered by its content.
        for (auto *child : getChildren()) {
            if (!child->isVisible()) continue;
            juce::Rectangle<int> cover;
            float dim = 0;
            if (auto *sheet = dynamic_cast<ModalSheet *>(child)) { cover = sheet->contentFrame(); dim = .48f; }
            else if (auto *sheet = dynamic_cast<CloseProjectSheet *>(child)) { cover = sheet->contentFrame(); dim = .18f; }
            if (dim > 0) {
                state.dimming = 1.f - (1.f - state.dimming) * (1.f - dim);
                if (getLocalArea(child, cover.expanded(2)).intersects(model->getBounds())) state.visible = false;
            }
        }
        if (auto *modal = Component::getCurrentlyModalComponent(); modal && modal->getPeer() == peer &&
            !dynamic_cast<ModalSheet *>(modal) && !dynamic_cast<CloseProjectSheet *>(modal) &&
            getLocalArea(modal, modal->getLocalBounds()).intersects(model->getBounds())) state.visible = false;
        state.background = model->findColour(TextButton::buttonColourId).getARGB();
        state.activeBackground = model->findColour(TextButton::buttonOnColourId).getARGB();
        state.foreground = model->findColour(state.active ? TextButton::textColourOnId : TextButton::textColourOffId).getARGB();
        state.accent = (uint32)(int64)model->getProperties()["transportColour"];
        auto icon = model->getProperties()["leadingIcon"].toString();
        if (icon.isEmpty() && StringArray{"play", "pause", "subplay", "loop", "record", "metronome"}.contains(id)) icon = id;
        state.icon = icon.toWideCharPointer();
        if (!StringArray{"pause", "loop", "metronome"}.contains(id)) state.text = model->getButtonText().toWideCharPointer();
        state.tooltip = localization::translate(model->getTooltip()).toWideCharPointer();
        nativeTransport->update(index++, (HWND)peer->getNativeHandle(), state, [safe = SafePointer<Workspace>(this), id](bool right) {
            if (!safe || Component::getCurrentlyModalComponent()) return;
            auto *button = static_cast<QuietButton *>(safe->controls[id]);
            if (right) { if (button->context) button->context(Desktop::getMousePosition()); }
            else {
                const auto modifiers = ModifierKeys::getCurrentModifiersRealtime();
                if (button->modifiedClick && button->modifiedClick(modifiers)) return;
                const auto action = button->onClick;
                if (action) action();
            }
            if (safe) {
                // A transport action can open a floating editor (Advanced,
                // Settings, FX). Do not raise the workspace over that editor
                // again when this native button's mouse-up finishes.
                if (!Component::getCurrentlyModalComponent())
                    if (auto *peer=safe->getPeer();peer && GetForegroundWindow()==(HWND)peer->getNativeHandle())
                        safe->grabKeyboardFocus();
                safe->syncNativeTransport();
            }
        });
    }
}

void Workspace::paint(Graphics &g) {
    g.fillAll(theme::background);
    if (browserVisible || loginPanel)
        return;
    g.setColour(theme::panel);
    g.fillRect(transportBounds);
    g.fillRect(0, 32, getWidth(), 28);
    g.fillRect(footerBounds);
    g.fillRect(tracksViewport.getX(), workspaceBounds.getY(), tracksViewport.getWidth(), workspaceBounds.getHeight());
    {
        const auto state = session.presentationTransport();
        const auto cpu = footerBounds.withWidth(footerSongBounds.getX() - footerBounds.getX());
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
        const auto durationText = clockText(setlist->duration(), true);
        auto durationFont = theme::semiboldFont(12 * fontScale);
        const auto durationBounds = total.reduced(3, 1);
        const float textWidth = GlyphArrangement::getStringWidth(durationFont, durationText);
        const float available = (float)std::max(1, durationBounds.getWidth() - 1);
        if (textWidth > available)
            durationFont = durationFont.withHeight(durationFont.getHeight() * available / textWidth);
        g.setFont(durationFont);
        g.drawText(durationText, durationBounds, Justification::centred, false);
    }
    auto displayFrame = songDisplay.getBounds().getUnion(transportTime.getBounds());
    g.setColour(theme::line);
    g.drawRoundedRectangle(displayFrame.toFloat().expanded(.5f), 4, 1);
    g.drawVerticalLine(transportInfo.getX() - 1, (float)displayFrame.getY(), (float)displayFrame.getBottom());
    g.drawVerticalLine(transportTime.getX() - 1, (float)displayFrame.getY(), (float)displayFrame.getBottom());
    g.setColour(theme::line);
    g.drawHorizontalLine(59, 0, (float)getWidth());
    g.drawHorizontalLine(transportBounds.getBottom(), 0, (float)getWidth());
    {
    Graphics::ScopedSaveState masterState(g);
    g.addTransform(AffineTransform::translation(0, 28));
    const auto masterColour = Colour(0xff000000 | session.project().masterColor.value_or(0x414141)).withAlpha(.5f);
    g.setColour(masterColour);
    g.fillRoundedRectangle(4, 40, 266, 70, 5);
    const auto masterLevels = session.audio.meterLevels();
    for (int ch = 0; ch < 2; ++ch)
        meterDisplay::bar(g, {9.f + ch * 6, 44, 5, 62}, masterLevels[(size_t)ch]);
    g.setColour(theme::surfaceText(masterColour));
    g.setFont(theme::semiboldFont(11));
    g.drawText("Master", 31, 69, 226, 18, Justification::centred);
    }
    if (mixerVisible) {
        g.setColour(theme::panel);
        g.fillRect(tracksViewport.getX(), workspaceBounds.getY(), tracksViewport.getWidth(), timeline->headerHeight());
        g.setColour(theme::secondary);
        g.setFont(theme::semiboldFont(10));
        g.drawText("Track-Mixer", tracksViewport.getX(), workspaceBounds.getY() + 15, tracksViewport.getWidth() - 60, 24,
                   Justification::centredLeft);
        g.setColour(theme::line);
        g.drawHorizontalLine(workspaceBounds.getY() + timeline->headerHeight() - 1,
                             (float)tracksViewport.getX(), (float)tracksViewport.getRight());
    }
}
void Workspace::resized() {
    if(audioPreparationOverlay)audioPreparationOverlay->setBounds(getLocalBounds());
    if (fadeoutOverlay) fadeoutOverlay->setBounds(getLocalBounds());
    const bool compactTransport = getWidth() < 1270, narrowTransport = getWidth() < 900;
    const int rail = 0, title = 32, toolBarHeight = 28;
    const int transport = toolBarHeight + (narrowTransport ? 166 : compactTransport ? 126 : 86);
    const int footerHeight = jlimit(27, 161, footerHeightSetting);
    const int otherPanels=(keyboardVisible?108:0)+(vinhetasVisible&&!vinhetasDetached?240:0);
    const int mixerLimit=std::max(0,getHeight()-title-transport-footerHeight-128-otherPanels);
    const int mixerHeight=footerMixerVisible?std::min(jlimit(273,724,mixerHeightSetting),mixerLimit):0;
    const int dockHeight = (keyboardVisible ? 108 : 0) + mixerHeight + (vinhetasVisible && !vinhetasDetached ? 240 : 0);
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
        if (canNavigateProjectTab && (canNavigateProjectTab(-1) || canNavigateProjectTab(1)))
            projectBrowser->setBounds(juce::Rectangle<int>(0,title,getWidth(),getHeight()-title).withSizeKeepingCentre(std::min(560,getWidth()),std::min(456,getHeight()-title)));
        else projectBrowser->setBounds(0, title, getWidth(), getHeight() - title);
        projectBrowser->setProjectOpen(projectReady);
    }
    if (loginPanel) {
        loginPanel->setBounds(0, title, getWidth(), getHeight() - title);
        loginPanel->toFront(false);
    }
    navigation->setBounds(rail, title + transport, getWidth() - rail,
                          std::max(1, getHeight() - title - transport - bottom));
    if (navigation->isVisible()) navigation->toFront(false);
    caption->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child))
            child->toFront(false);
    if (setlistWindow) setlistWindow->setVisible(layoutActive && editorVisible && setlistVisible && setlistPlacement==SetlistPlacement::detached);
    if (!editorVisible) { if (nativeTransport) nativeTransport->hide(); return; }
    transportBounds = {rail, title + toolBarHeight, getWidth() - rail, transport - toolBarHeight};
    footerBounds = {rail, getHeight() - footerHeight, getWidth() - rail, footerHeight};
    workspaceBounds = {rail, title + transport, getWidth() - rail,
                       std::max(1, getHeight() - title - transport - bottom)};
    const int availableWidth = workspaceBounds.getWidth();
    const bool detachedSetlist = setlistPlacement == SetlistPlacement::detached;
    const int mixerGap=mixerVisible?20:0;
    const int setlistGap=setlistVisible&&!detachedSetlist?14:0;
    const int columnsBudget=std::max(0,availableWidth-100-mixerGap-setlistGap);
    const int mixerMinimum=mixerVisible?std::min(180,columnsBudget):0;
    const int setlistMinimum=setlistVisible&&!detachedSetlist?std::min(minimumSetlistWidth,std::max(0,columnsBudget-mixerMinimum)):0;
    const bool rightPartsDocked=partsRightVisible&&setlistVisible&&!detachedSetlist;
    const int partsCount=(partsLeftVisible?1:0)+(rightPartsDocked?1:0);
    const int partsBudget=std::max(0,columnsBudget-mixerMinimum-setlistMinimum);
    const int partsMinimum=partsCount?std::min(160,partsBudget/partsCount):0;
    const int sectionsWidth=rightPartsDocked?jlimit(partsMinimum,
        std::max(partsMinimum,partsBudget-(partsLeftVisible?partsMinimum:0)),
        partsRightWidth>0?partsRightWidth:std::min(360,(int)(availableWidth*.22))):0;
    const int leftPartsWidth=partsLeftVisible?jlimit(partsMinimum,std::max(partsMinimum,partsBudget-sectionsWidth),partsLeftWidth):0;
    const int right=setlistVisible&&!detachedSetlist?jlimit(setlistMinimum,
        std::max(setlistMinimum,columnsBudget-sectionsWidth-mixerMinimum-leftPartsWidth),setlistWidth):0;
    // mixerWidth remains the user's control-area width. Append the icon column
    // rather than squeezing Patch/faders/M/S into a narrower track body.
    const int mixerBodyWidth=mixerVisible?std::min(mixerWidth,std::max(mixerMinimum,columnsBudget-right-sectionsWidth-leftPartsWidth)):0;
    const int left=mixerBodyWidth+(mixerVisible&&showsTrackIcons?40:0);
    const int leadingSetlist = setlistPlacement == SetlistPlacement::left ? right+setlistGap : 0;
    const int partsX = rail + leadingSetlist;
    const int mixerX = partsX + leftPartsWidth;
    // The master is independent of track mixer visibility, as in the Mac transport.
    masterVolume.setBounds(28, 86, 232, 20);
    if(masterPeakReadout)masterPeakReadout->setBounds(31,73,43,12);
    masterPan.setBounds(128, 45, 46, 25);
    controls["masterMono"]->setBounds(26, 46, 49, 20);
    controls["masterPatch"]->setBounds(79, 46, 45, 20);
    controls["masterFX"]->setBounds(178, 46, 26, 20);
    controls["masterMute"]->setBounds(210, 46, 22, 20);
    controls["masterSolo"]->setBounds(240, 46, 22, 20);
    const bool multipleProjects = canNavigateProjectTab && (canNavigateProjectTab(-1) || canNavigateProjectTab(1));
    for (auto id : {"previousProjectTab", "nextProjectTab"}) controls[id]->setVisible(multipleProjects);
    controls["previousProjectTab"]->setBounds(276, 39, 26, 26);
    controls["nextProjectTab"]->setBounds(304, 39, 26, 26);
    const int edge = getWidth() - 8, start = multipleProjects ? 336 : 276;
    int topRight = edge;
    for (auto spec : std::initializer_list<std::pair<const char *, int>>{{"export", 66},
                                                                         {"resolume", 58},
                                                                         {"grandma2", 62},
                                                                         {"advanced", 60}}) {
        topRight -= spec.second;
        controls[spec.first]->setBounds(topRight, narrowTransport ? 119 : 39, spec.second, 26);
        topRight -= 5;
    }
    const int toolsLeft = topRight + 5;
    if (narrowTransport)
        topRight = edge;
    const int displayWidth = std::max(80, topRight - start - 4);
    const int nameWidth = std::max(1, roundToInt((displayWidth - 102 - (narrowTransport ? 0 : 35)) * .75));
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
        {"subplay", std::max(64.f, playbackWidth), 1}, {"loop", iconWidth, .5f},
        {"record", playbackWidth, 1}, {"metronome", iconWidth, .5f},
        {"tempo", 171, 0}, {"tuner", 157, 0},
        {"tp1", buttonWidth, 1}, {"tp2", buttonWidth, 1},
        {"notices", std::max(72.f,buttonWidth), 1}, {"preview", std::max(60.f,buttonWidth), 1},
        {"video", std::max(58.f,buttonWidth), 1}, {"remote", std::max(48.f,buttonWidth-8.f), 1},
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
                tempoControl->setBounds(leftEdge, y - 8, width, 43);
            else if (String(item.id) == "tuner")
                tuner->setBounds(leftEdge, y + 1, width, 25);
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
        tuner->setBounds(45 + tempoWidth, 120, available - tempoWidth, 25);
    }
    // The tools occupy their own top row; retain the transport's internal layout.
    for (auto id : {"masterMono", "masterPatch", "masterFX", "masterMute", "masterSolo",
                    "previousProjectTab", "nextProjectTab", "export", "resolume",
                    "grandma2", "advanced", "play", "pause", "subplay", "loop", "record",
                    "metronome", "tp1", "tp2", "notices", "preview", "video", "remote", "save", "setlist"})
        controls[id]->setTopLeftPosition(controls[id]->getX(), controls[id]->getY() + toolBarHeight);
    for (Component *component : std::initializer_list<Component *>{&masterVolume, &masterPan,
            &songDisplay, &transportInfo, &transportTime, tempoControl.get(), tuner.get(), masterPeakReadout.get()})
        if (component) component->setTopLeftPosition(component->getX(), component->getY() + toolBarHeight);
    stageTimer->setVisible(false);stageTimer->setBounds({});
    tempo.setVisible(false);
    // Commands not present in the Mac transport remain available through menus/shortcuts.
    for (auto id : {"stopall", "previous", "next", "audio", "soundfont", "railProjects",
                    "railImport", "railUndo", "railRedo", "railSettings", "railHelp"})
        controls[id]->setVisible(false);
    controls["railTeleprompt"]->setVisible(false);
    controls["railTeleprompt2"]->setVisible(false);
    int toolX = 4;
    for (auto id : {"menu", "mixer", "railMixer", "railParts", "railNotice", "railClock", "railKeyboard", "railVinhetas"}) {
        controls[id]->setBounds(toolX, title + 2, 26, 24);
        toolX += 32;
    }
    controls["settings"]->setBounds(getWidth() - 30, title + 2, 26, 24);
    const int audioWidth = std::min(300, std::max(1, getWidth() - toolX - 40));
    controls["audioStatus"]->setBounds(getWidth() - 36 - audioWidth, title + 2, audioWidth, 24);
    zoom.setVisible(false);
    for (auto id : {"zoomOut", "zoomIn", "zoomFit"}) controls[id]->setVisible(false);
    tracksViewport.setVisible(mixerVisible);
    tracksViewport.setBounds(mixerX, workspaceBounds.getY() + timeline->headerHeight(), left,
                             std::max(1, workspaceBounds.getHeight() - timeline->headerHeight()));
    tracksContent.setSize(std::max(1, left), std::max(tracksViewport.getHeight(), rowTop(rows.size()) + trackHeight * 2));
    for (int i = 0; i < rows.size(); ++i) {
        rows[i]->setVisible(!rowHidden(i));
        rows[i]->setBounds(0, rowTop(i), std::max(1, left), rowHeight(i));
    }
    addTrack.setBounds(mixerX + mixerBodyWidth - 48, workspaceBounds.getY() + 20, 32, 24);
    addTrack.setVisible(mixerVisible);
    timelineLock.setBounds(addTrack.getX() - 30, addTrack.getY(), 24, 24);
    timelineLock.setVisible(mixerVisible);
    timelineTimebase.setBounds(timelineLock.getX()-30,timelineLock.getY(),24,24);
    timelineTimebase.setVisible(mixerVisible);
    trackVisibilityButton.setBounds(timelineTimebase.getX()-30,timelineLock.getY(),24,24);
    trackVisibilityButton.setVisible(mixerVisible);
    timelineSnap.setBounds(trackVisibilityButton.getX()-28,trackVisibilityButton.getY(),24,24);
    timelineSnap.setVisible(mixerVisible);
    timeline->setBounds(mixerX + left + mixerGap, workspaceBounds.getY(),
                        std::max(1, workspaceBounds.getWidth() - left - right - sectionsWidth - leftPartsWidth - mixerGap - setlistGap),
                        workspaceBounds.getHeight());
    if (!detachedSetlist) {
        setlist->setVisible(setlistVisible);
        setlist->setBounds(leadingSetlist ? rail : getWidth()-right-sectionsWidth,workspaceBounds.getY(),right,workspaceBounds.getHeight());
        setlist->setPartsVisible(partsRightVisible);
        partsSidebar->setVisible(partsRightVisible && setlistVisible);
        partsSidebar->setBounds(getWidth()-sectionsWidth,workspaceBounds.getY(),sectionsWidth,workspaceBounds.getHeight());
        partsRightDivider.setVisible(partsRightVisible&&setlistVisible);
        partsRightDivider.setBounds(partsSidebar->getX()-3,workspaceBounds.getY(),6,workspaceBounds.getHeight());
    } else if (setlistWindow) {
        setlistWindow->setVisible(layoutActive && setlistVisible && editorVisible);
        layoutDetachedSetlist();
    }
    footer.setBounds(rail + 10, footerBounds.getY(), getWidth() - rail - 20, 27);
    footer.setVisible(false);
    keyboard->setVisible(keyboardVisible);
    if(!vinhetasDetached) {vinhetasPanel->setVisible(vinhetasVisible);vinhetasPanel->setBounds(0,mixerHeight+(keyboardVisible?108:0),getWidth()-rail,240);}

    footerMixer->setVisible(footerMixerVisible);
    dockViewport.setVisible(dockHeight > 0);
    dockViewport.setBounds(rail, getHeight() - bottom, getWidth() - rail, visibleDockHeight);
    const int dockWidth = getWidth() - rail - (dockHeight > visibleDockHeight ? 10 : 0);
    dockContent.setSize(dockWidth, dockHeight);
    footerMixer->setBounds(0, 0, dockWidth, mixerHeight);
    if (footerMixerVisible)
        footerMixer->refresh();
    refreshMixerIndicator();
    controls["railKeyboard"]->setColour(TextButton::textColourOffId, keyboardVisible ? theme::green : Colours::white);
    const auto padWindow=floatingWindows.find("Vinhetas");
    const bool padsOpen=vinhetasDetached?padWindow!=floatingWindows.end()&&padWindow->second->isVisible():vinhetasVisible;
    controls["railVinhetas"]->setColour(TextButton::textColourOffId,padsOpen?theme::green:Colours::white);
    controls["setlist"]->setColour(TextButton::buttonColourId, setlistVisible ? theme::green : Colour(0xff454545));
    controls["setlist"]->setColour(TextButton::textColourOffId, setlistVisible ? Colours::black : Colours::white);
    controls["mixer"]->setColour(TextButton::textColourOffId, mixerVisible ? theme::green : Colour(0xffc44545));
    if (!partsLeftDetached) {
        partsLeft->setVisible(partsLeftVisible);
        partsLeft->setBounds(partsX, workspaceBounds.getY(), leftPartsWidth, workspaceBounds.getHeight());
    }
    partsLeftDivider.setVisible(partsLeftVisible);
    partsLeftDivider.setBounds(partsLeft->getRight()-3,workspaceBounds.getY(),6,workspaceBounds.getHeight());
    controls["railParts"]->setColour(TextButton::textColourOffId,
                                        (partsLeftVisible || (partsLeftDetached && floatingWindows.count("Parts") && floatingWindows.at("Parts")->isVisible())) ? theme::green : Colours::white);
    if (keyboardVisible)
        keyboard->setBounds(0, mixerHeight, dockWidth, 108);
    mixerDivider.setVisible(mixerVisible); setlistDivider.setVisible(setlistVisible && !detachedSetlist);
    mixerDivider.setBounds(mixerX + left, workspaceBounds.getY(), mixerGap, workspaceBounds.getHeight());
    setlistDivider.setBounds(leadingSetlist?setlist->getRight():setlist->getX()-setlistGap, workspaceBounds.getY(), setlistGap, workspaceBounds.getHeight());
    footerHeightDivider.setBounds(rail, footerBounds.getY() - 3, getWidth() - rail, 6);
    mixerHeightDivider.setVisible(footerMixerVisible);
    mixerHeightDivider.setBounds(rail, dockViewport.getY() - 3, getWidth() - rail, 6);
    mixerDivider.refreshScroll();setlistDivider.refreshScroll();partsRightDivider.refreshScroll();
    footerSongBounds = footerBounds.withTrimmedLeft(std::min(footerLeftWidth, footerBounds.getWidth() / 3));
    trackHeightHandle->setBounds(tracksViewport.getBounds());
    trackHeightHandle->setVisible(projectReady && !browserVisible && mixerVisible);trackHeightHandle->toFront(false);
    for (auto *divider : {&mixerDivider, &setlistDivider, &partsLeftDivider, &partsRightDivider, &footerHeightDivider, &mixerHeightDivider}) divider->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child)) child->toFront(false);
    if (navigation->isVisible()) navigation->toFront(false);
    if(audioPreparationOverlay)audioPreparationOverlay->toFront(false);
}
String Workspace::itemTitle(const jaras::AudioClip &clip) const {
    const auto *song=session.song();
    if(itemTitleRevision!=session.revision || itemTitleSong!=(song?song->id:ID{})) {
        itemTitles.clear();itemTitleRevision=session.revision;itemTitleSong=song?song->id:ID{};
        itemTitleTempo=song?std::make_unique<jaras::TempoEditMap::PlaybackRates>(*song):nullptr;
    }
    const auto found=itemTitles.find(clip.id);
    if(found!=itemTitles.end())return found->second;
    const auto title=ClipTempo(clip,song,itemTitleTempo.get()).itemTitle(clip);
    itemTitles.emplace(clip.id,title);return title;
}
const ItemLanes &Workspace::itemLanes(int index) const {
    if (timeline) if (const auto *preview = timeline->previewItemLanes(index)) return *preview;
    if (itemLayoutRevision != session.revision) {
        itemLayouts.clear();
        if (const auto *song = session.song()) for (const auto &track : song->tracks) {
            auto items = ItemLanes::references(track);
            for (const auto &item : session.recordingItems)
                if (item.track == track.id) items.push_back(&item.clip);
            itemLayouts.emplace_back(std::move(items));
        }
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
    const int base=itemLaneHeight(index) * itemLanes(index).count;
    const auto *song=session.song();
    if(song && index>=0 && index<(int)song->tracks.size() && song->tracks[size_t(index)].role.id=="programChange")
        return std::max(base,ProgramChangeLanes(song->tracks[size_t(index)]).count*24+8);
    return base;
}
ItemLanes::Geometry Workspace::itemGeometry(int index, const ID &clip, const ItemLanes *preview) const {
    const auto *song=session.song();
    const bool recording=song && index>=0 && index<(int)song->tracks.size() &&
        std::any_of(session.recordingItems.begin(),session.recordingItems.end(),[&](const auto &item){return item.track==song->tracks[(size_t)index].id;});
    const auto &layout=preview && !recording?*preview:itemLanes(index);
    return layout.geometry(clip,(float)rowBodyHeight(index));
}
void Workspace::openTrackVisibility() {
    if(session.busy)return;
    for(auto *child:getChildren())
        if(auto *sheet=dynamic_cast<ModalSheet*>(child);sheet&&sheet->getName()=="Visibilidade das pistas") {sheet->toFront(true);return;}
    trackVisibility.load(appearance,session.project().id);
    const auto project=session.project().id;
    ModalSheet::open(*this,"Visibilidade das pistas",std::make_unique<TrackVisibilityPanel>(session,trackVisibility,
        [safe=SafePointer<Workspace>(this),project](TrackVisibility::Panel panel,const ID &id,bool visible) {
            if(safe&&safe->session.project().id==project)safe->setTrackVisibility(panel,id,visible);
        }),460,480);
}
void Workspace::setTrackVisibility(TrackVisibility::Panel panel,const ID &id,bool visible) {
    if(!session.song()||trackTree::index(*session.song(),id)>=session.song()->tracks.size())return;
    const auto result=trackVisibility.set(appearance,session.project().id,panel,id,visible);
    if(result.failed()){showError(result.getErrorMessage());return;}
    pruneTrackVisibilitySelection(panel==TrackVisibility::Panel::barMixer);
    refreshTrackVisibility();
}
void Workspace::pruneTrackVisibilitySelection(bool footer) {
    const auto *song=session.song();if(!song)return;
    const auto panel=footer?TrackVisibility::Panel::barMixer:TrackVisibility::Panel::trackMixer;
    const auto visible=[&](const ID &id){return id.empty()||trackVisibility.visible(*song,panel,id);};
    for(auto at=selectedTracks.begin();at!=selectedTracks.end();)
        if(!visible(*at))at=selectedTracks.erase(at);else ++at;
    if(!visible(selectedTrack))selectedTrack=selectedTracks.empty()?ID{}:*selectedTracks.begin();
    if(!visible(trackSelectionAnchor))trackSelectionAnchor.clear();
    std::set<ID> hiddenItems;
    for(const auto &track:song->tracks)
        if(!trackVisibility.visible(*song,TrackVisibility::Panel::trackMixer,track.id))
            for(const auto &clip:track.clips)hiddenItems.insert(clip.id);
    for(auto at=selectedClips.begin();at!=selectedClips.end();)
        if(hiddenItems.count(*at))at=selectedClips.erase(at);else ++at;
    if(hiddenItems.count(selectedClip))selectedClip=selectedClips.empty()?ID{}:*selectedClips.begin();
    if(trackHeightPreview&&!trackVisibility.visible(*song,TrackVisibility::Panel::trackMixer,trackHeightPreview->first))
        trackHeightPreview.reset();
}
void Workspace::refreshTrackVisibility() {
    footerMixer->refresh();
    for(const auto &entry:floatingWindows)
        if(auto *mixer=dynamic_cast<MixerPanel*>(entry.second->getContentComponent()))mixer->refresh();
    timeline->updateRanges();resized();timeline->invalidate();
    updateState();repaint();
}
bool Workspace::rowHidden(int index) const {
    if (const auto *song = session.song()) {
        if(index>=0&&index<(int)song->tracks.size()&&
           !trackVisibility.visible(*song,TrackVisibility::Panel::trackMixer,song->tracks[(size_t)index]))return true;
        for (const auto &group : collapsedGroups)
            if (trackTree::descendant(*song, (size_t)index, group))
                return true;
    }
    return false;
}
void Workspace::toggleGroup(const ID &id) {
    if (!collapsedGroups.erase(id))
        collapsedGroups.insert(id);
    resized();
    timeline->updateRanges();
    for (auto *row : rows)
        row->refresh();
    syncNativeTransport();
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
void Workspace::refreshPlaybackState() {
    // Queue, playlist and Stop policy edits keep the same media and geometry.
    // Retain their caches before a repaint can interpret revision as a new grid.
    if(itemLayoutRevision+1==session.revision)itemLayoutRevision=session.revision;
    if(itemTitleRevision+1==session.revision)itemTitleRevision=session.revision;
    tempoControl->retainTempoAfterMixerChange();
    timeline->refreshMixer();
    setlist->refresh();caption->repaint();updateState();
}
void Workspace::rebuild() {
    if(!session.preparingLiveAudio()){audioPreparationOverlay.reset();audioPreparationStarted.reset();}
    showsTrackIcons=trackIcons::visible(session.song());
    if(trackVisibility.load(appearance,session.project().id))pruneTrackVisibilitySelection(trackSelectionFromFooter);
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
        if (builtSong != songID) {
            verticalOffset = 0;
            tracksViewport.setViewPosition(0, 0);
        }
        builtSong = songID;
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
    const auto &t = session.transport();
    const auto audible = session.presentationTransport();
    stage.observe(audible);
    for(int i=0;i<2;++i)if(teleprompterHTTP[(size_t)i]->enabled()) {
        const auto content=StageContent::make(session,stage,i+1);
        teleprompterHTTP[(size_t)i]->publish(content.payload,content.media);
    }
    // Hidden project tabs still advance transport, lighting and projections.
    // Their controls and timeline need one refresh on activation, not 60 per
    // second competing with the visible tab during an Auto transition.
    if (!layoutActive) return;
    // Owned, non-topmost projection windows stay visible above the workspace,
    // while independent FX/plugin windows can take focus and move in front.
    // A sheet is painted inside this HWND, so temporarily drop the ownership
    // while it is open; otherwise the video would obscure its controls.
    if(auto *peer=getPeer()) {
        const auto main=static_cast<HWND>(peer->getNativeHandle());
        const auto *activeSheet=dynamic_cast<ModalSheet*>(Component::getCurrentlyModalComponent());
        // A palette inside an independent editor must not lower the projection.
        const bool sheet=activeSheet && activeSheet->getPeer()==peer;
        auto followWorkspace = [&](DocumentWindow *window, bool fullscreen) {
            if (!window || !window->isVisible()) return;
            auto *floatingPeer=window->getPeer();if(!floatingPeer)return;
            const auto handle=static_cast<HWND>(floatingPeer->getNativeHandle());
            const auto owner=reinterpret_cast<HWND>(GetWindowLongPtrW(handle,GWLP_HWNDPARENT));
            if ((sheet || fullscreen) && owner == main) {
                SetWindowLongPtrW(handle,GWLP_HWNDPARENT,0);
                if (sheet && !fullscreen) SetWindowPos(handle,HWND_BOTTOM,0,0,0,0,
                                       SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
            } else if (!sheet && !fullscreen && owner != main) {
                SetWindowLongPtrW(handle,GWLP_HWNDPARENT,reinterpret_cast<LONG_PTR>(main));
                SetWindowPos(handle,HWND_TOP,0,0,0,0,
                             SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
            }
        };
        for(const auto &entry:floatingWindows) {
            const auto *projection = dynamic_cast<Projection*>(entry.second->getContentComponent());
            if (projection || entry.first == "Parts")
                followWorkspace(entry.second.get(), projection && projection->isPresentationFullscreen());
        }
        followWorkspace(setlistWindow.get(), false);
    }
    if (fadeoutOverlay) fadeoutOverlay->update();
    if (session.transportFadeoutActive() || lastFadeoutActive)
        for (auto *row : rows) if (row->isShowing()) row->refresh();
    lastFadeoutActive = session.transportFadeoutActive();
    const bool movementLocked = session.project().timelineMovementLocked.value_or(false);
    timelineLock.setToggleState(movementLocked, dontSendNotification);
    const bool relativeTimebase=session.song() && session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase==jaras::ProjectTimebase::relative;
    timelineTimebase.setToggleState(relativeTimebase,dontSendNotification);
    timelineTimebase.setEnabled(session.song() && !session.busy && !session.audio.isRecording());
    timelineLock.getProperties().set("icon", movementLocked ? "lock" : "unlock");
    timelineLock.setTooltip(movementLocked ? String::fromUTF8("Desbloquear movimento no grid")
                                          : String::fromUTF8("Bloquear movimento de itens, regiões e marcadores"));
    timelineLock.setEnabled(!session.busy && !session.audio.isRecording());
    trackVisibilityButton.setEnabled(!session.busy);
    timelineSnap.setEnabled(!session.busy);
    const bool snapEnabled=(bool)appearance.value("jaras.timeline.snapEnabled",true);
    timelineSnap.setToggleState(snapEnabled,dontSendNotification);
    timelineSnap.setTooltip(TRANS(snapEnabled ? "Snap on — Shift temporarily disables snapping" : "Snap off — free positioning"));
    session.audio.keyboardChannel = jlimit(0, 16, (int)appearance.value("jaras.keyboard.channel", 0));
    session.setRecordingSelection(selectedTrack, selectedTracks);
    if (recordVisualSelection != selectedTrack) {
        recordVisualSelection = selectedTrack;
        for (auto *row : rows)
            row->refresh();
    }
    controls["preview"]->setToggleState(stage.preview, dontSendNotification);
    refreshMixerIndicator();
    controls["notices"]->setToggleState(false, dontSendNotification);
    const auto video = floatingWindows.find("Video");
    controls["video"]->setToggleState(video != floatingWindows.end() && video->second->isVisible(), dontSendNotification);
    if(masterFXColourSource!=session.project().masterFXJSON) {
        masterFXColourSource=session.project().masterFXJSON;
        masterFXColour=fxchain::colour(masterFXColourSource ? JSON::parse(text(*masterFXColourSource)) : var(),true);
    }
    controls["masterFX"]->setColour(TextButton::textColourOffId, masterFXColour);
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
    controls["record"]->setColour(TextButton::buttonOnColourId, theme::liveOffRed);
    controls["save"]->setButtonText(session.isSaving() ? "Salvando..." : session.dirty ? localization::translate("Salvar") : localization::translate("Salvo"));
    controls["save"]->setEnabled(!session.isSaving());
    controls["save"]->getProperties().set("leadingIcon", session.dirty ? "save" : "check");
    controls["save"]->setColour(TextButton::buttonColourId,
                                session.dirty ? theme::green.withAlpha(.16f) : Colour(0xff454545));
    controls["save"]->setColour(TextButton::textColourOffId,
                                session.dirty ? theme::green : Colours::white);
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
    controls["masterMono"]->setColour(TextButton::buttonOnColourId, Colours::white.withAlpha(.22f));
    if (auto *s = session.song()) {
        String selectedName;
        if (audible.playing && audible.regionId)
            for (const auto &part : s->parts)
                if (part.id == *audible.regionId)
                    selectedName = regionCaption(*s, &part, audible.playing ? std::optional<double>(audible.position) : std::nullopt);
        if (!audible.playing) {
            const jaras::Part *selected=nullptr;
            for (const auto &part : s->parts) {
                if (t.editPosition < part.startTime || t.editPosition >= part.endTime) continue;
                if (!selected || part.startTime > selected->startTime ||
                    (part.startTime == selected->startTime && part.endTime < selected->endTime)) selected=&part;
            }
            if (selected) selectedName=regionCaption(*s,selected,std::nullopt);
        }
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
    transportTime.setText(clockText(audible.position, true), dontSendNotification);
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
    timeline->followPlayback();
    timeline->animate();
    for (auto *row : rows)
        if (row->isShowing())
            row->repaint(0, 0, 22, row->getHeight());
    for (const auto &entry : controls) {
        auto *button = entry.second;
        button->setButtonText(localization::translate(button->getButtonText()));
        button->setTooltip(localization::translate(button->getTooltip()));
    }
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
            if(projectReady && !browserVisible)editorWindowBounds=window->getBounds();
            fitLoginWindow(*window);
        }
    }
    if (!show && loginPanel) {
        loginPanel.reset();
        if (browserVisible) showProjectBrowser();
        else if(auto *window=findParentComponentOfClass<DocumentWindow>()) fitEditorWindow(*window,editorWindowBounds);
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
    if (!isShowing()) { if(nativeTransport) nativeTransport->hide(); return; }
    for (const auto &spec : std::initializer_list<std::pair<const char *, int>>{{"previousProjectTab", -1}, {"nextProjectTab", 1}})
        controls[spec.first]->setEnabled(canNavigateProjectTab && canNavigateProjectTab(spec.second));
    try { session.audio.refreshStemLatency(); }
    catch (const std::exception &e) { session.message = String::fromUTF8(e.what()); }
    const double now = Time::getMillisecondCounterHiRes() / 1000.0;
    if (now - layoutSaveTime >= 1 && !ModifierKeys::getCurrentModifiersRealtime().isAnyMouseButtonDown()) {
        layoutSaveTime = now; saveWorkspaceLayout();
        if(session.inspection) {
            const auto profile=SystemStats::getEnvironmentVariable("CATLIVE_ZOOM_PROFILE",{});
            if(profile.isNotEmpty())File(profile).appendText(JSON::toString(timeline->paintProfile(),true)+"\n");
        }
    }
    // Live edits keep the previous graph running until the replacement is
    // ready. Covering the workspace here hid native transport buttons and
    // blocked interaction during Patch changes and recording finalization.
    audioPreparationOverlay.reset(); audioPreparationStarted.reset();
    syncNativeTransport();
    if (fadeoutOverlay) fadeoutOverlay->update();
    timeline->refreshWaveforms();
    if (resourceUsage.sample()) repaint(footerBounds);
    // Master bars are drawn at x=9/15, y=44 plus the 28px toolbar offset.
    // Include the complete bars and antialiased edges in the timer invalidation.
    repaint(8, 71, 14, 64);
    for (auto *row : rows) if (row->isShowing()) row->repaint(0, 0, 22 + row->groupIndent(), row->getHeight());
    controls["remote"]->setColour(TextButton::buttonColourId, remoteHost->enabled() ? theme::green : theme::liveOffRed);
    controls["remote"]->setColour(TextButton::textColourOffId, Colours::black);
    if(!scrollingTrackDrag.empty()) {
        if(!isDragAndDropActive() || !ModifierKeys::getCurrentModifiersRealtime().isAnyMouseButtonDown()) scrollingTrackDrag.clear();
        else if(const auto *song=session.song()) {
            const auto point=tracksViewport.getLocalPoint(nullptr,Desktop::getMousePosition());
            if(tracksViewport.getLocalBounds().contains(point)) {
                if(tracksViewport.autoScroll(point.x,point.y,40,18)) {
                    const int row=rowAt(point.y+tracksViewport.getViewPositionY());
                    if(row>=0 && row<(int)song->tracks.size()) {
                        const auto &target=song->tracks[(size_t)row];
                        const bool after=point.y+tracksViewport.getViewPositionY()-rowTop(row)>rowHeight(row)/2;
                        trackDropPreview=trackDrop::resolve(*song,scrollingTrackDrag,target.id,after,point.x<16);
                        trackDropBlocked=trackDropPreview?ID{}:target.id;repaint();
                    }
                }
            }
        }
    }
    mixerDivider.refreshScroll();setlistDivider.refreshScroll();partsRightDivider.refreshScroll();
    const bool subVisible = session.subCursorVisible();
    const auto presentation=session.presentationTransport();
    // The timeline's separate 60 Hz clock moves the grid and needles together.
    // This slower timer only animates the temporary stopped Subplay preview.
    if (!presentation.playing && !presentation.subPlay.playing && (subVisible || subVisible != lastSubCursorVisible))
        timeline->animate();
    lastSubCursorVisible = subVisible;
}
void Workspace::changeListenerCallback(ChangeBroadcaster *) {
    session.audio.keyboardChannel = jlimit(0, 16, (int)appearance.value("jaras.keyboard.channel", 0));
    syncBarMixerMasterSide();
    syncHozMixerMode();
    if(trackVisibility.load(appearance,session.project().id)) {pruneTrackVisibilitySelection(trackSelectionFromFooter);refreshTrackVisibility();}
    auto &desktop = Desktop::getInstance();
    const auto scale = appearance.interfaceScale();
    if (std::abs(desktop.getGlobalScaleFactor() - scale) > .0001f) {
        setInterfaceScalePreservingWindow(findParentComponentOfClass<DocumentWindow>(), scale);
        resized();
    }
    localization::english = appearance.value("jaras.language", "pt-BR").toString() == "en";
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child)) {
            localization::panel(*sheet);
            sheet->repaint();
        }
    for (const auto &entry : floatingWindows) {
        auto *panel = entry.second->getContentComponent();
        if (dynamic_cast<SettingsPanel *>(panel) || dynamic_cast<AdvancedPanel *>(panel)) {
            entry.second->setName(localization::translate(entry.first));
            localization::panel(*panel); panel->repaint();
        }
    }
    projectBrowser->refresh();
    partsLeft->refresh(); partsSidebar->refresh();
    updateState();
    timeline->invalidate();
    for(const auto &entry:floatingWindows)
        if(auto *projection=dynamic_cast<Projection*>(entry.second->getContentComponent()))
            projection->refreshVideoAppearance();
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
    if(audioPreparationOverlay)return true;
    if (session.inspection && logger)
        logger->logMessage("QA key=" + String(key.getKeyCode()) +
                           " mods=" + String(key.getModifiers().getRawFlags()));
    if ((session.inspection || SystemStats::getEnvironmentVariable("CATLIVE_AUDIO_DIAGNOSTICS", {}) == "1") && key.getKeyCode() == KeyPress::F12Key) {
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
    if (ctrl && !alt && !shift && (code == KeyPress::upKey || code == KeyPress::downKey)) {
        if (!projectReady || loginPanel) return false;
        return setlist->stepPlaylist(code == KeyPress::downKey ? 1 : -1);
    }
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
    if (ctrl && shift && !alt && code == 'S') {
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
    if (!ctrl && !alt && !shift && selectionAreas.activeScope()=="grid" &&
        (code==KeyPress::leftKey || code==KeyPress::rightKey)) {
        timeline->pausePlaybackFollow();
        perform([&]{session.command(jaras::CommandKind::editSeek,{},std::max(0.,session.transport().editPosition+
            (code==KeyPress::leftKey ? -10. : 10.)/std::max(1.,pixelsPerSecond)));});
        return true;
    }
    if (ctrl && !alt && !shift && (code == 'C' || code == 'X' || code == 'V' || code == 'D')) {
        if (isRepeat) return true;
        ++shortcutCount;
        if (code == 'V' || code == 'D') pasteGridItems(code == 'D');
        else copyGridItems(code == 'X');
        return true;
    }
    if (code == KeyPress::tabKey && !ctrl && !shift && !alt && projectReady) {
        if (!isRepeat) { ++shortcutCount; setlist->toggleSearch(); }
        return true;
    }
    if (code == KeyPress::returnKey && !ctrl && !shift && !alt && selectionAreas.activeScope()=="setlist") {
        if (!isRepeat) perform([&]{setlist->activateSelection();});
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
    if (code == 'M' && !ctrl && alt && !shift) {
        if (isRepeat) return true;
        ++shortcutCount;
        editMarker({}, session.transport().editPosition, true);
        return true;
    }
    if (code == KeyPress::escapeKey) {
        if (isRepeat) return true;
        if (itemClipboard && itemClipboard->moving) {
            itemClipboard.reset(); timeline->invalidate(); return true;
        }
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
        if (selectionAreas.activeScope() == "setlist") return setlist->deleteSelectedEntries();
        if(selectionAreas.activeScope()=="grid" && session.selectedProgramMarker()) {
            const auto marker=session.selectedProgramChange;
            for(const auto &track:session.song()->tracks)if(track.role.id=="programChange") {
                const auto id=track.id;perform([&]{session.removeProgramChange(id,marker);});break;
            }
            return true;
        }
        if (selectionAreas.activeScope() != "tracks" && (!selectedClip.empty() || !selectedClips.empty()))
            perform([&] {
                const auto ids = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
                session.removeClips(ids);
                clearItemSelection();
            });
        else if (selectionAreas.activeScope() == "tracks" && (!selectedTrack.empty() || !selectedTracks.empty())) {
            const auto ids = selectedTracks.empty() ? std::set<ID>{selectedTrack} : selectedTracks;
            const auto project = session.project().id;
            const auto song = session.song() ? session.song()->id : ID{};
            confirmTrackDeletion(ids,
                    [safe = Component::SafePointer<Workspace>(this), ids, project, song] {
                        if (safe && safe->session.project().id == project && safe->session.song() && safe->session.song()->id == song)
                            safe->perform([&] {
                                safe->session.removeTracks(ids);
                                // A busy/read-only session can decline an edit. Keep
                                // surviving tracks selected so Delete can be retried;
                                // closing the confirmation is not a successful edit.
                                const auto exists = [&](const ID &id) {
                                    const auto *current = safe->session.song();
                                    return current && trackTree::index(*current, id) < current->tracks.size();
                                };
                                for (auto at = safe->selectedTracks.begin(); at != safe->selectedTracks.end();)
                                    if (!exists(*at)) at = safe->selectedTracks.erase(at);
                                    else ++at;
                                if (!exists(safe->selectedTrack))
                                    safe->selectedTrack = safe->selectedTracks.empty() ? ID{} : *safe->selectedTracks.begin();
                                safe->updateState();
                                safe->repaint();
                            });
                    });
        }
        return true;
    }
    return false;
}
bool Workspace::isInterestedInFileDrag(const StringArray &files) {
    for(auto &path:files)if(File(path).hasFileExtension("jl;bkjl;ziplive;zip")||externalMedia::supported(File(path)))return true;
    return false;
}
void Workspace::clearExternalDrop(){
    if(externalDropCancelled)externalDropCancelled->store(true);
    externalDropCancelled.reset();externalDropPoint.reset();externalDropFiles.clear();repaint();
}
void Workspace::fileDragEnter(const StringArray &files,int x,int y){
    clearExternalDrop();
    ++fileDragEntries;
    fileDropStatus="drag entered";
    if(loginPanel||session.busy||browserVisible||!projectReady||!session.song())return;
    for(const auto &path:files)if(externalMedia::supported(File(path)))externalDropFiles.push_back({File(path),{}});
    externalDropPoint=Point<int>{x,y};
    auto cancelled=externalDropCancelled=std::make_shared<std::atomic<bool>>(false);
    Thread::launch([safe=SafePointer<Workspace>(this),sources=externalDropFiles,cancelled]{
        for(size_t i=0;i<sources.size();++i){
            if(cancelled->load())return;
            const auto duration=externalMedia::duration(sources[i].file);
            if(cancelled->load())return;
            MessageManager::callAsync([safe,cancelled,i,duration]{
                if(safe&&!cancelled->load()&&safe->externalDropCancelled==cancelled&&i<safe->externalDropFiles.size()){
                    safe->externalDropFiles[i].duration=duration;safe->repaint();
                }
            });
        }
    });
    repaint();
}
void Workspace::fileDragMove(const StringArray &,int x,int y){externalDropPoint=Point<int>{x,y};repaint();}
void Workspace::fileDragExit(const StringArray &){clearExternalDrop();}
void Workspace::filesDropped(const StringArray &files,int x,int y) {
    clearExternalDrop();++fileDropCount;
    fileDropStatus="drop received";
    if(loginPanel||session.busy){fileDropStatus=loginPanel?"login required":"import busy";return;}
    for(auto &path:files)if(File(path).hasFileExtension("jl;bkjl;ziplive;zip")){perform([&]{openProject(File(path));});return;}
    if(browserVisible||!projectReady||!session.song()){fileDropStatus="project not open";return;}
    const auto local=timeline->getLocalPoint(this,Point<int>{x,y});
    if(!timeline->getLocalBounds().contains(local)||local.y<timeline->headerHeight()){fileDropStatus="outside grid";return;}
    const int row=rowAt(local.y-timeline->headerHeight()+tracksViewport.getViewPositionY());
    const ID target=row>=0&&row<(int)session.song()->tracks.size()?session.song()->tracks[(size_t)row].id:ID{};
    const double at=timelineGrid::snapSelection(timeline->timeAt((float)local.x),*session.song(),pixelsPerSecond,session.transport(),freeTimelinePosition(ModifierKeys::getCurrentModifiers()));
    Array<File> media;for(auto &path:files)media.add(File(path));
    importMediaAt(media,at,target);
    fileDropStatus=media.size()>1?"awaiting import options":"import submitted";
}
void Workspace::importMediaAt(const Array<File> &media,double at,ID target) {
    if(loginPanel||session.busy||browserVisible||!projectReady||!session.song()||media.isEmpty())return;
    const ID project=session.project().id,song=session.song()->id;
    auto submit=[safe=SafePointer<Workspace>(this),media,target,at,project,song](MediaDropLayout layout,double gap){if(safe)safe->perform([&]{
        if(safe->session.project().id!=project||!safe->session.song()||safe->session.song()->id!=song)throw std::runtime_error("O projeto ou grid de destino mudou.");
        safe->session.importMedia(media,at,target,layout,gap,[safe](String error){
            if(safe&&error.isNotEmpty())safe->showError(error);
        }, true);
    });};
    if(media.size()>1)ModalSheet::open(*this,String::fromUTF8("Importar mídia"),std::make_unique<MediaDropPanel>(submit),440,188);
    else submit(MediaDropLayout::separateTracks,0);
}
void Workspace::mouseDoubleClick(const MouseEvent &event) {
    // The Mac shortcut belongs to the empty mixer area below the last track.
    // Child controls, items and the ruler keep their own double-click actions.
    if(event.eventComponent!=&tracksContent||!event.mods.isLeftButtonDown()||event.mods.isAnyModifierKeyDown())return;
    const auto local=event.getEventRelativeTo(&tracksContent).getPosition();
    if(session.song()&&local.y>=rowTop((int)session.song()->tracks.size()))addStandardTrackAtEnd();
}
void Workspace::addStandardTrackAtEnd() {
    if(loginPanel||session.busy||browserVisible||!projectReady||!session.song())return;
    perform([&]{
        const auto songID=session.song()->id;
        int number=(int)session.song()->tracks.size()+1;
        String name;
        do{name="Pista "+String(number++);}while(std::any_of(session.song()->tracks.begin(),session.song()->tracks.end(),[&](const auto &track){return text(track.name)==name;}));
        int channels=0;
        if(auto *device=session.audio.devices.getCurrentAudioDevice())channels=device->getInputChannelNames().size();
        ID after = selectedTrack;
        for (const auto &row : session.song()->tracks) if (selectedTracks.count(row.id)) after = row.id;
        const auto id=uuid();
        session.edit([&](jaras::Project &project){for(auto &song:project.songs)if(song.id==songID){
            jaras::Track track;track.id=id;track.name=utf8(name);track.role.id="other";track.color=0x828282;
            if(channels>0)track.inputPatch=jaras::OutputPatch{1,std::min(2,channels)};
            trackTree::insertAfter(song,std::move(track),after);
        }});
        selectMixerTrack(id,ModifierKeys{});timeline->invalidate();
    });
}
void Workspace::mouseDown(const MouseEvent &event) {
    if (event.eventComponent == &tracksContent && event.mods.isLeftButtonDown() &&
        !event.mods.isPopupMenu() && session.song() &&
        event.getEventRelativeTo(&tracksContent).y >= rowTop((int)session.song()->tracks.size())) {
        // An empty mixer click still owns Delete/Select All, but has no track
        // target. Do not fall back to a selection retained in another panel.
        selectionAreas.activate(tracksViewport);
        trackSelectionFromFooter = false;
        selectedTracks.clear(); selectedTrack.clear(); trackSelectionAnchor.clear();
        if (isShowing()) grabKeyboardFocus();
        updateState();
        for (auto *row : rows) row->repaint();
        timeline->invalidate(); repaint();
    }
    if (event.eventComponent == this && event.mods.isPopupMenu() && !browserVisible && juce::Rectangle<int>(4,68,266,70).contains(event.getPosition()))
        showMasterMenu(event.getScreenPosition());
}
void Workspace::mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &details) {
    auto relative = event.getEventRelativeTo(this);
    if (tracksViewport.getBounds().contains(relative.getPosition())) {
        ++wheelCount;
        if (event.mods.isCtrlDown()) {
            tracksViewport.cancelWheel();
            timeline->adjustTrackHeight(details.deltaY);
        } else {
            tracksViewport.scrollByWheel(-details.deltaY*300.,details.isSmooth || details.isInertial);
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
void Workspace::confirmTrackDeletion(const std::set<ID> &ids, std::function<void()> remove) {
    if (!tracksContainItems(session.project(), ids)) { remove(); return; }
    ModalSheet::open(*this, localization::translate("Delete selected tracks and their items?"),
        std::make_unique<TrackDeletionConfirmationPanel>(std::move(remove)), confirmationStyle::width, 138);
}
void Workspace::confirm(const String &title, const String &message, std::function<void()> done, std::function<void()> cancelled, String action, bool destructive, bool vertical) {
    if(action.isEmpty())action=localization::translate("Continuar");
    auto panel=std::make_unique<ConfirmationPanel>(localization::translate(title),localization::translate(message),action,destructive,vertical,std::move(done),std::move(cancelled));
    const int height=panel->getHeight();
    ModalSheet::open(*this,title,std::move(panel),confirmationStyle::width,height);
}

void Workspace::confirmProjectReplacement(const String &name, std::function<void()> action, std::function<void()> cancelled, bool confirmedRemotely) {
    auto proceed = [safe = SafePointer<Workspace>(this), action] {
        if (!safe) return;
        // Match macOS: save the outgoing document before replacing it.
        if (safe->projectReady && (safe->session.dirty || safe->session.isSaving())) {
            if (safe->session.document == File()) { safe->chooseSave(false, action); return; }
            auto finish = safe->beginProjectLoading(safe->session.document, localization::translate(String::fromUTF8("Salvando…")));
            try { safe->session.saveAsync(safe->session.document, [safe, finish, action](String error) {
                finish(error);
                if (!safe || error.isNotEmpty()) return;
                if (safe->session.dirty) safe->chooseSave(false, action);
                else action();
            }); } catch (const std::exception &e) { finish(String::fromUTF8(e.what())); }
        } else action();
    };
    if (!projectReady || confirmedRemotely) { proceed(); return; }
    ModalSheet::open(*this, localization::translate("Open another project?"),
        std::make_unique<ProjectOpenConfirmationPanel>(name, proceed, cancelled), confirmationStyle::width, 180);
}
std::function<void(String)> Workspace::beginProjectLoading(const File &file, const String &status) {
    std::vector<SafePointer<ProjectBrowser>> browsers;
    browsers.emplace_back(projectBrowser.get());
    auto collect = [&] {
        for (auto *child : getChildren())
            if (auto *sheet = dynamic_cast<ModalSheet *>(child); sheet && sheet->getName() == "Projetos")
                for (auto *content : sheet->getChildren())
                    if (auto *browser = dynamic_cast<ProjectBrowser *>(content)) browsers.emplace_back(browser);
    };
    collect();
    if (std::none_of(browsers.begin(), browsers.end(), [](const auto &b) { return b && b->isShowing(); })) {
        showProjectBrowser(); collect();
    }
    for (const auto &b : browsers) if (b) {
        b->beginLoading(file); b->updateLoading(status); ModalSheet::blockDismiss(*b, true);
    }
    return [browsers](String error) {
        for (const auto &b : browsers) if (b) { b->finishLoading(error); ModalSheet::blockDismiss(*b, false); }
    };
}
void Workspace::deleteRecentProject(const File &file) {
    if(session.busy || session.audio.isRecording())return;
    const auto owner=SafePointer<Workspace>(this);
    perform([&]{
        auto plan=std::make_shared<ProjectDeletion>(file);
        auto panel=std::make_unique<ProjectDeletionPanel>(plan,[safe=owner,plan]{
            if(!safe) return;
            auto &w=*safe;
            if(w.session.busy || w.session.audio.isRecording())
                throw std::runtime_error("Conclua a gravação e aguarde as operações antes de apagar o projeto.");
            plan->validate();
            const bool deletingCurrent=w.session.document==plan->document;
            if(!deletingCurrent && w.session.dirty && w.projectReady){if(w.session.document==File{})throw std::runtime_error("Salve o projeto aberto antes de excluir outro projeto.");w.session.save(w.session.document);}
            if(deletingCurrent) {
                // This point is reached only after the explicit destructive
                // confirmation and countdown. Release this project's readers
                // before Windows removes its media; keep recovery data if a
                // filesystem error prevents completing the deletion.
                const auto previous=w.session.snapshot();
                const auto document=w.session.document, media=w.session.mediaDirectory;
                const bool dirty=w.session.dirty;
                w.floatingWindows.clear();
                w.session.command(jaras::CommandKind::stopAll);
                w.session.newProject();
                try { plan->remove(); }
                catch(...) {
                    w.session.document=document; w.session.mediaDirectory=media;
                    w.session.restoreSnapshot(previous); w.session.dirty=dirty;
                    throw;
                }
                w.projectReady=false;w.browserVisible=true;
            } else plan->remove();
            RecentProjects::forget(plan->document);w.projectBrowser->refresh();
            for(auto *child:w.getChildren())if(auto *sheet=dynamic_cast<ModalSheet*>(child);sheet && sheet->getName()=="Projetos") {
                if(deletingCurrent)sheet->exitModalState(0);
                else for(auto *content:sheet->getChildren())if(auto *browser=dynamic_cast<ProjectBrowser*>(content))browser->refresh();
            }
            if(deletingCurrent)w.showProjectBrowser();w.resized();w.repaint();
        });
        ModalSheet::open(*this,localization::translate("Delete project"),std::move(panel),460,298);
    });
}
void Workspace::newProject() { showProjectBrowser(); }
void Workspace::showProjectBrowser() {
    saveWorkspaceLayout();
    timeline->cancelInteraction();
    if (session.busy || session.audio.isRecording()) {
        showError("Wait for recording and imports before opening Projects.");
        return;
    }
    if (projectReady && !browserVisible) {
        auto panel = std::make_unique<ProjectBrowser>();
        panel->setProjectOpen(projectReady);
        panel->setPlaybackRunning(session.transport().playing || session.transport().subPlay.playing);
        panel->createEmpty = projectBrowser->createEmpty;
        panel->createEmptyInNewTab = projectBrowser->createEmptyInNewTab;
        panel->createStems = projectBrowser->createStems;
        panel->createRecording = projectBrowser->createRecording;
        panel->createReaper = projectBrowser->createReaper;
        panel->createLogic = projectBrowser->createLogic;
        panel->addStems = projectBrowser->addStems;
        panel->addPackage = projectBrowser->addPackage;
        panel->browse = projectBrowser->browse;
        panel->open = projectBrowser->open;
        panel->openInNewTab = projectBrowser->openInNewTab;
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
    tempoTaps = {};
    clearItemSelection();
    itemClipboard.reset();
    itemClipboardSequence.reset();
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child);
            sheet && sheet->getName() == "Projetos")
            sheet->exitModalState(0);
    projectReady = true;
    browserVisible = false;
    restoreWorkspaceLayout();
    if (session.document.existsAsFile())
        RecentProjects::remember(session.document);
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        if(loginPanel)fitLoginWindow(*window);
        else showEditorWindow(*window, editorWindowBounds);
    }
    resized();
    if (fitTimeline)
        timeline->initialView();
    repaint();
    grabKeyboardFocus();
}
void Workspace::openProject(const File &file, std::function<void()> loaded, bool confirmed, bool allowMissing, ID remoteRequest) {
    const auto host = remoteHost;
    saveWorkspaceLayout();
    if (session.busy) {
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, "Wait for the current operation on the PC.");
        return;
    }
    if (activateExistingProjectTab && activateExistingProjectTab(file)) {
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::completed);
        return;
    }
    timeline->cancelInteraction();
    if (file.hasFileExtension("ziplive;zip")) {
        if (!remoteRequest.empty()) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, "Import this package on the PC before opening it from Recent projects.");
        } else choosePackageDestination(file);
        return;
    }
    auto action = [safe = Component::SafePointer<Workspace>(this), host, remoteRequest, file, loaded, allowMissing] {
        if (!safe || safe->session.busy) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled);
            return;
        }
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::opening, "Opening project…");
        try {
            if (safe->session.audio.isRecording())
                throw std::runtime_error("Conclua a gravação antes de abrir outro projeto.");
            // Keep the same Projects view while preparing the next document,
            // like ProjectBrowserView on Mac. A second modal obscured the
            // clicked recent and made the transition look like a separate task.
            std::vector<Component::SafePointer<ProjectBrowser>> browsers;
            browsers.emplace_back(safe->projectBrowser.get());
            for (auto *child : safe->getChildren())
                if (auto *sheet = dynamic_cast<ModalSheet *>(child); sheet && sheet->getName() == "Projetos")
                    for (auto *content : sheet->getChildren())
                        if (auto *browser = dynamic_cast<ProjectBrowser *>(content))
                            browsers.emplace_back(browser);
            if (std::none_of(browsers.begin(), browsers.end(), [](const auto &browser) {
                    return browser && browser->isShowing();
                })) {
                safe->showProjectBrowser();
                for (auto *child : safe->getChildren())
                    if (auto *sheet = dynamic_cast<ModalSheet *>(child); sheet && sheet->getName() == "Projetos")
                        for (auto *content : sheet->getChildren())
                            if (auto *browser = dynamic_cast<ProjectBrowser *>(content))
                                browsers.emplace_back(browser);
            }
            for (const auto &browser : browsers) if (browser) {
                browser->beginLoading(file);
                ModalSheet::blockDismiss(*browser, true);
            }
            const auto finish = [browsers](const String &error) {
                for (const auto &browser : browsers) if (browser) {
                    browser->finishLoading(error);
                    ModalSheet::blockDismiss(*browser, false);
                }
            };
            try { safe->session.loadAsync(file,
                [browsers, host, remoteRequest](String status, double) {
                    host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::opening, utf8(status));
                    for (const auto &browser : browsers) if (browser) browser->updateLoading(status);
                },
                [safe] {
                    if (!safe) return;
                    safe->timeline->cancelInteraction();
                    // Close project-bound editors while their outgoing processors
                    // and document still exist (including native plug-in HWNDs).
                    safe->floatingWindows.clear();
                    safe->selectedTracks.clear(); safe->selectedTrack.clear();
                    safe->trackSelectionAnchor.clear(); safe->collapsedGroups.clear();
                },
                [safe, host, remoteRequest, finish, loaded](String error) {
                    finish(error);
                    if (!safe) {
                        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled);
                        return;
                    }
                    try {
                        if (error.isEmpty()) { safe->lighting.loadSettings(); safe->projectOpened(); if (loaded) loaded(); }
                    } catch (const std::exception &failure) { error = String::fromUTF8(failure.what()); }
                    host->projectOpening.update(remoteRequest, error.isEmpty() ? remote::ProjectOpening::State::completed : remote::ProjectOpening::State::failed, {}, utf8(error));
                    if (safe->projectTabLoadFinished) safe->projectTabLoadFinished(error);
                }, allowMissing ? std::function<void(StringArray)>{} :
                    [safe, host, remoteRequest, finish, file, loaded](StringArray paths) {
                        finish({});
                        if (!safe) {
                            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled);
                            return;
                        }
                        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::waiting, "Resolve the missing audio files on the PC to continue opening the project.");
                        ModalSheet::open(*safe, localization::translate("Missing audio files"),
                            std::make_unique<MissingMediaPanel>(file, paths, [safe, host, remoteRequest, file, loaded](bool proceed) {
                                if (safe && proceed) safe->openProject(file, loaded, true, true, remoteRequest);
                                else {
                                    host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled);
                                    if (safe && safe->projectTabLoadFinished)
                                        safe->projectTabLoadFinished(String::fromUTF8("Abertura cancelada."));
                                }
                            }), 560, 396);
                    });
            } catch (const std::exception &error) {
                const auto message = String::fromUTF8(error.what());
                finish(message);
                host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, utf8(message));
                if (safe->projectTabLoadFinished) safe->projectTabLoadFinished(message);
            }
        } catch (const std::exception &error) {
            const auto message = String::fromUTF8(error.what());
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, utf8(message));
            if (safe->projectTabLoadFinished) safe->projectTabLoadFinished(message);
            else safe->showError(message);
        }
    };
    if (!confirmed && projectReady && file != session.document) {
        if (remoteRequest.empty()) host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::waiting, "Confirm opening the project on the PC. The current project has unsaved changes.");
        confirmProjectReplacement(file.getFileNameWithoutExtension(), action,
            [host, remoteRequest] { host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled); }, !remoteRequest.empty());
    } else
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
void Workspace::createProject(bool withStems, int recordingChannels, bool inNewTab) {
    if (withStems) { chooseImport(false, inNewTab); return; }
    auto work = [safe = Component::SafePointer<Workspace>(this), withStems, recordingChannels, inNewTab] {
        if (!safe) return;
        auto chooseLocation = [safe, withStems, recordingChannels, inNewTab](String name) {
            if (!safe || name.trim().isEmpty())
                return;
            auto legal = File::createLegalFileName(name.trim());
            auto folder = File::getSpecialLocation(File::userDocumentsDirectory)
                              .getChildFile("CatLive");
            folder.createDirectory();
            safe->chooser = std::make_unique<FileChooser>(
                localization::translate("Create Project"), folder.getChildFile(legal + ".jl"), "*.jl", true);
            safe->chooser->launchAsync(
                FileBrowserComponent::saveMode | FileBrowserComponent::canSelectFiles |
                    FileBrowserComponent::warnAboutOverwriting,
                [safe, withStems, recordingChannels, inNewTab](const FileChooser &fc) {
                    if (!safe || fc.getResult() == File())
                        return;
                    auto chosen = fc.getResult().withFileExtension("jl");
                    const auto name = chosen.getFileNameWithoutExtension();
                    // Match Mac's isolated project directory: every project owns its media
                    // folder.
                    auto target =
                        chosen.getParentDirectory().getFileName() ==
                                chosen.getFileNameWithoutExtension()
                            ? chosen
                            : chosen.getParentDirectory()
                                  .getChildFile(chosen.getFileNameWithoutExtension())
                                  .getChildFile(chosen.getFileName());
                    auto create = [safe, target, name, recordingChannels, withStems, inNewTab] {
                        if (!safe || safe->session.busy || safe->session.audio.isRecording()) return;
                        if (target.existsAsFile()) { safe->showError("A project already exists at this location. Choose another name."); return; }
                        auto finish = safe->beginProjectLoading(target, localization::translate(String::fromUTF8("Copying audio and saving project…")));
                        safe->session.busy = true;
                        // Write the new document off the message thread; keep the
                        // outgoing session intact until normal asynchronous loading succeeds.
                        Thread::launch([safe, target, name, recordingChannels, withStems, inNewTab, finish] {
                            String error;
                            try {
                                auto project = recordingChannels > 0 ? makeRecordingProject(name, recordingChannels) : Session::makeEmptyProject(name);
                                project.projectSyncID = uuid();
                                ProjectCodec::write(target, ProjectCodec::encode(project));
                            } catch (const std::exception &e) { error = String::fromUTF8(e.what()); }
                            MessageManager::callAsync([safe, target, recordingChannels, withStems, inNewTab, finish, error] {
                                if (!safe) return;
                                safe->session.busy = false;
                                if (error.isNotEmpty()) { finish(error); return; }
                                if (inNewTab) { finish({}); if (safe->openInNewProjectTab) safe->openInNewProjectTab(target); return; }
                                safe->openProject(target, [safe, recordingChannels, withStems] {
                                    if (!safe) return;
                                    if (recordingChannels > 0 && safe->session.song()) {
                                        std::set<ID> tracks;
                                        for (const auto &track : safe->session.song()->tracks) tracks.insert(track.id);
                                        if (!tracks.empty()) safe->session.cycleRecordArm(*tracks.begin(), tracks);
                                    }
                                    if (withStems) safe->chooseImport();
                                }, true);
                            });
                        });
                    };
                    if (inNewTab) create();
                    else safe->confirmProjectReplacement(name, create);
                });
        };
        chooseLocation("Untitled");
    };
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
    timeline->cancelInteraction();
    auto launch = [safe = Component::SafePointer<Workspace>(this)] {
        if (!safe)
            return;
        safe->chooser = std::make_unique<FileChooser>(localization::translate("Open Project"),
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
    launch();
}
void Workspace::chooseSave(bool saveAs, std::function<void()> saved) {
    auto finish = [safe = SafePointer<Workspace>(this), saved](String error) {
        if (!safe) return;
        if (error.isNotEmpty()) { safe->showError(error); return; }
        RecentProjects::remember(safe->session.document);
        if (saved) {
            // Close/export callbacks need the latest edit, not just the first
            // snapshot when the user kept editing during a regular Save.
            if (safe->session.dirty) safe->chooseSave(false, saved);
            else saved();
        }
    };
    if (!saveAs && session.document != File()) {
        perform([&] { session.saveAsync(session.document, finish); });
        return;
    }
    if (session.isSaving()) {
        if (saveAs) {
            session.waitForSave([safe = SafePointer<Workspace>(this), project = session.project().id, saved](String error) {
                if (!safe || safe->session.project().id != project) return;
                if (error.isNotEmpty()) { safe->showError(error); return; }
                safe->chooseSave(true, saved);
            });
        } else session.waitForSave(finish);
        return;
    }
    auto suggested =
        File::getSpecialLocation(File::userDocumentsDirectory)
            .getChildFile("CatLive/" + File::createLegalFileName(text(session.project().name)) +
                          "/" + File::createLegalFileName(text(session.project().name)) + ".jl");
    chooser = std::make_unique<FileChooser>(localization::translate("Save Project"),
                                            suggested, "*.jl", true);
    chooser->launchAsync(
        FileBrowserComponent::saveMode | FileBrowserComponent::canSelectFiles |
            FileBrowserComponent::warnAboutOverwriting,
        [safe = Component::SafePointer<Workspace>(this), finish](const FileChooser &fc) {
            if (!safe || fc.getResult() == File()) return;
            safe->perform([&] { safe->session.saveAsync(fc.getResult(), finish); });
        });
}
void Workspace::chooseImport(bool adding, bool inNewTab) {
    if(session.busy || session.audio.isRecording())return;
    if(adding && session.document==File{}) { chooseSave(false,[safe=SafePointer<Workspace>(this)]{if(safe)safe->chooseImport();});return; }
    const auto projectID=session.project().id;
    chooser=std::make_unique<FileChooser>(localization::translate("Select stem folders"),File::getSpecialLocation(File::userDocumentsDirectory),"",true);
    chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectDirectories|FileBrowserComponent::canSelectMultipleItems,
        [safe=SafePointer<Workspace>(this),adding,inNewTab,projectID](const FileChooser& picker){
            if(!safe||picker.getResults().isEmpty())return;
            auto scan=std::make_shared<stemImport::Scan>();
            for(const auto& directory:picker.getResults())scan->folders.push_back({directory,{}});
                    safe->showPanel(localization::translate("Review stems"),std::make_unique<StemFolderImportPanel>(scan,adding,
                        [safe,adding,inNewTab,projectID](std::shared_ptr<stemImport::Scan> scan,String removal,bool detectBPM,std::function<void()> closeReview){
                            if(!safe||safe->session.busy)return;
                            auto build=[safe,scan,removal,detectBPM,adding,inNewTab,projectID,closeReview](File target){
                                if(!safe||safe->session.busy)return;
                                if(adding&&safe->session.project().id!=projectID){safe->showError("The project changed during import.");return;}
                                if(!adding&&target.existsAsFile()){safe->showError("A project already exists at this location. Choose another name.");return;}
                                auto launch=[safe,scan,removal,detectBPM,adding,inNewTab,target,closeReview]{
                                    if(!safe)return;
                                    closeReview();
                                    auto base=adding?safe->session.project():Session::makeEmptyProject(target.getFileNameWithoutExtension());
                                    if(!adding)base.projectSyncID=uuid();
                                    const auto original=adding?safe->session.snapshot():var();
                                    int totalFiles=0;for(const auto& folder:scan->folders)totalFiles+=(int)folder.files.size();
                                    auto finish=safe->beginProjectLoading(target,localization::translate("Importing")+" 0/"+String(totalFiles));
                                    safe->session.busy=true;
                                    Thread::launch([safe,scan,removal,detectBPM,adding,inNewTab,target,base,original,finish,totalFiles]{
                                        String error;StringArray warnings=scan->warnings;Array<File> copied;
                                        try {
                                            auto progress=[safe,totalFiles](String file,double value){MessageManager::callAsync([safe,file,value,totalFiles]{if(safe){safe->session.message=file.startsWith("Detecting BPM:")?localization::translate(String::fromUTF8("Detecting BPM…"))+" "+file.fromFirstOccurrenceOf(":",false,false).trim():localization::translate("Importing")+" "+String((int)std::lround(value*totalFiles))+"/"+String(totalFiles)+": "+file;safe->session.importProgress=value;safe->session.notify();std::function<void(Component&)> update=[&](Component& component){if(auto* browser=dynamic_cast<ProjectBrowser*>(&component))browser->updateLoading(safe->session.message);for(auto* child:component.getChildren())update(*child);};update(*safe);}});};
                                            auto project=stemImport::build(*scan,removal,base,target,detectBPM,progress,warnings,&copied);
                                            ProjectCodec::write(target,ProjectCodec::encode(project,original));
                                        }catch(const std::exception& e){for(const auto& file:copied)file.deleteFile();error=String::fromUTF8(e.what());}
                                        MessageManager::callAsync([safe,target,inNewTab,finish,error,warnings]{
                                            if(!safe)return;safe->session.busy=false;
                                            if(error.isNotEmpty()){finish(error);return;}
                                            if(inNewTab){finish({});if(safe->openInNewProjectTab)safe->openInNewProjectTab(target);return;}
                                            safe->openProject(target,[safe,warnings]{if(safe&&!warnings.isEmpty())safe->showPanel("Review stems",std::make_unique<ImportNoticePanel>(warnings),560,360);},true);
                                        });
                                    });
                                };
                                if(adding){if(safe->session.dirty)safe->chooseSave(false,launch);else launch();}
                                else if(inNewTab)launch();else safe->confirmProjectReplacement(target.getFileNameWithoutExtension(),launch);
                            };
                            if(adding){build(safe->session.document);return;}
                            safe->chooser=std::make_unique<FileChooser>(localization::translate("Create Project"),File::getSpecialLocation(File::userDocumentsDirectory).getChildFile("Untitled.jl"),"*.jl",true);
                            safe->chooser->launchAsync(FileBrowserComponent::saveMode|FileBrowserComponent::canSelectFiles,
                                [safe,build](const FileChooser& picker){
                                    if(!safe||picker.getResult()==File{})return;
                                    auto chosen=picker.getResult().withFileExtension("jl");auto parent=chosen.getParentDirectory();
                                    auto target=parent.getFileName()==chosen.getFileNameWithoutExtension()?chosen:parent.getChildFile(chosen.getFileNameWithoutExtension()).getChildFile(chosen.getFileName());
                                    MessageManager::callAsync([safe,build,target]{if(safe)build(target);});
                                });
                        },true),760,570);
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
                            std::vector<SafePointer<ProjectBrowser>> browsers;
                            browsers.emplace_back(safe->projectBrowser.get());
                            for (auto *child : safe->getChildren())
                                if (auto *sheet = dynamic_cast<ModalSheet *>(child); sheet && sheet->getName() == "Projetos")
                                    for (auto *content : sheet->getChildren())
                                        if (auto *browser = dynamic_cast<ProjectBrowser *>(content)) browsers.emplace_back(browser);
                            // 0 = importing, 1 = cancelled, 2 = saving. Claiming
                            // the save phase prevents a late click from reporting
                            // cancellation after the destination has been written.
                            auto importPhase = std::make_shared<std::atomic<int>>(0);
                            const auto cancelImport = [importPhase, browsers] {
                                int importing = 0;
                                if (!importPhase->compare_exchange_strong(importing, 1)) return;
                                for (const auto &browser : browsers) if (browser)
                                    browser->setLoadingCancellation({});
                            };
                            const auto status = String::fromUTF8(logic ? "Importando projeto do Logic…" : "Importando projeto do REAPER…");
                            safe->session.message = status;
                            for (const auto &browser : browsers) if (browser) {
                                browser->beginLoading(source);
                                browser->updateLoading(status);
                                if (!logic) browser->setLoadingCancellation(cancelImport);
                                ModalSheet::blockDismiss(*browser, true);
                            }
                            Thread::launch([safe, logic, source, selected, browsers, importPhase] {
                                File document;
                                String error;
                                StringArray warnings;
                                bool cancelled = false;
                                try {
                                    auto imported = logic ? readLogicProject(source)
                                                          : readReaperProject(source, makeReaperVST3Resolver(
                                                                [importPhase] { return importPhase->load() == 1; }));
                                    int importing = 0;
                                    if (!importPhase->compare_exchange_strong(importing, 2))
                                        throw ReaperImportCancelled{};
                                    MessageManager::callAsync([browsers] {
                                        for (const auto &browser : browsers) if (browser)
                                            browser->setLoadingCancellation({});
                                    });
                                    warnings = imported.warnings;
                                    document = saveMigratedProject(imported, selected);
                                } catch (const ReaperImportCancelled &) {
                                    cancelled = true;
                                } catch (const std::exception &e) {
                                    error = String::fromUTF8(e.what());
                                }
                                MessageManager::callAsync([safe, document, error, warnings, browsers,
                                                           cancelled] {
                                    if (!safe)
                                        return;
                                    safe->session.busy = false;
                                    for (const auto &browser : browsers) if (browser) {
                                        browser->finishLoading(error);
                                        ModalSheet::blockDismiss(*browser, false);
                                    }
                                    if (cancelled) {
                                        safe->session.message = String::fromUTF8("Importação cancelada.");
                                        return;
                                    }
                                    if (error.isNotEmpty()) {
                                        safe->showError(error);
                                        return;
                                    }
                                    safe->openProject(document, [safe, warnings] {
                                        if (safe && !warnings.isEmpty())
                                            safe->showPanel(String::fromUTF8("Migração de projeto"),
                                                std::make_unique<ImportNoticePanel>(warnings), 520, 316);
                                    }, true);
                                });
                            });
                        });
                });
            });
    };
    if (session.dirty && projectReady)
        confirmProjectReplacement("Untitled", launch);
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
    openSettingsPage(1);
}
void Workspace::openAdvanced() {
    const auto name = String::fromUTF8("Avançado");
    if (auto it = floatingWindows.find(name);
        it != floatingWindows.end() && it->second->isVisible()) {
        it->second->setMinimised(false);
        it->second->toFront(true);
        return;
    }
    openFloating(
        name,
        std::make_unique<AdvancedPanel>(appearance, session,
                                        [self = SafePointer<Workspace>(this)](String message) {
                                            if (self)
                                                self->showError(message);
                                        }),
        760, 376);
}
void Workspace::openSettings() {
    openSettingsPage(-1);
}
void Workspace::openSettingsPage(int initial) {
    const auto name = String::fromUTF8("Configurações");
    if (auto it = floatingWindows.find(name);
        it != floatingWindows.end() && it->second->isVisible()) {
        if (auto *settings = dynamic_cast<SettingsPanel *>(it->second->getContentComponent()))
            settings->selectPage(initial);
        it->second->setMinimised(false);
        it->second->toFront(true);
        return;
    }
    auto safe = SafePointer<Workspace>(this);
    openFloating(name,
              std::make_unique<SettingsPanel>(
                  session, auth, lighting, appearance, actions, std::max(0, initial),
                  [safe](String message) {
                      if (safe)
                          safe->showError(message);
                  },
                  [safe] {
                      if (safe)
                          safe->showPanel("Login", std::make_unique<LoginPanel>(safe->auth, false), 440,
                                          620);
                  },
                  [safe] {
                      if(safe)safe->showError(localization::english
                          ? "Playback is running. Changing the audio device, sample rate or buffer size may interrupt the audio."
                          : String::fromUTF8("A reprodução está em andamento. Alterar o dispositivo de áudio, a taxa de amostragem ou o tamanho do buffer pode interromper o áudio."),
                          localization::english ? "Audio settings" : String::fromUTF8("Configurações de áudio"));
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
    ID after = selectedTrack;
    if (session.song()) for (const auto &track : session.song()->tracks)
        if (selectedTracks.count(track.id)) after = track.id;
    ModalSheet::open(
        *this, "Criar pista",
        std::make_unique<CreateTrackPanel>(session,
                                           [safe = SafePointer<Workspace>(this)](String error) {
                                               if (safe)
                                                   safe->showError(error);
                                           }, after),
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
    menu.addItem(1, localization::translate("Editar")); menu.addItem(2, localization::translate(String::fromUTF8("Detectar BPM…")));
    if (regionEditing::overlapping(*session.song(),id).size()>1) menu.addItem(3,localization::translate("Unificar"));
    if (unified) menu.addItem(4,localization::translate("Desunificar"));
    menu.addItem(5,localization::translate(String::fromUTF8("Exportar áudio"))); menu.addItem(6,localization::translate(String::fromUTF8("Excluir região")));
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe=SafePointer<Workspace>(this),id](int action){
        if(!safe||!safe->session.song())return;
        if(action==1)safe->editRegion(id);
        if(action==2)safe->detectRegions({id});
        if(action==3){
            const auto roots=regionEditing::overlapping(*safe->session.song(),id);
            const bool existing=std::any_of(roots.begin(),roots.end(),[&](const auto &part){return regionEditing::hasChildren(*safe->session.song(),part.id);});
            const auto songID = safe->session.song()->id;
            auto unify=[safe,id,songID](String name) {
                bool applied = false;
                if (safe && safe->session.song() && safe->session.song()->id == songID) safe->perform([&] {
                    safe->session.edit([&](auto &p){regionEditing::unify(p,songID,id,name);}); applied = true;
                });
                return applied;
            };
            if (existing) unify({});
            else {
                auto panel = std::make_unique<UnifyRegionPanel>(unify);
                const auto anchor = safe->getLocalArea(safe->timeline.get(), safe->timeline->regionHeaderBounds(id));
                auto &popover = CallOutBox::launchAsynchronously(std::move(panel), anchor, safe.getComponent());
                popover.setDismissalMouseClicksAreAlwaysConsumed(true);
            }
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
        safe->perform([&] { safe->session.editTimeline([&](jaras::Project &project) {
            regionEditing::erase(project, songID, ids, withContents);
        }); });
    }, {}, localization::translate("Delete"), true);
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
                    if (song.markers) for (auto &marker : *song.markers) if (marker.sourceRegionID == id) {
                        marker.name = part.name; marker.color = colour;
                    }
                }
            }, false); close(); });
        };
        ModalSheet::open(*this, String::fromUTF8("Editar música"), std::make_unique<RegionEditor>(text(part.name), part.color.value_or(0x705264), part.uppercaseName.value_or(true), save, close), 300, 404);
        return;
    }
}
void Workspace::showMarkerMenu(ID id, Point<int> point) {
    const auto *song=session.song();if(!song || !song->markers)return;
    auto found=std::find_if(song->markers->begin(),song->markers->end(),[&](const auto &m){return m.id==id;});
    if(found==song->markers->end())return;
    if(!markerRegions::outsideRegions(*found,*song)){editMarker(id,found->position);return;}
    const auto projectID=session.project().id,songID=song->id;
    PopupMenu menu;menu.addItem(1,localization::translate("Editar"));menu.addItem(2,String::fromUTF8("Converter para região"));
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
void Workspace::editMarker(ID id, double position, bool section) {
    if (!session.song()) return;
    if(section && !markerEditing::canCreateSection(*session.song(),position)) {
        showError(localization::translate(String::fromUTF8("Marcadores de trecho só podem ser criados dentro de uma música.")));
        return;
    }
    jaras::TimelineMarker marker; marker.id = id.empty() ? uuid() : id;
    marker.position = position; marker.color = 0x51ef93;
    if(section) marker.section=true;
    if (!id.empty() && session.song()->markers) for (const auto &m : *session.song()->markers) if (m.id == id) marker = m;
    if (marker.tempoBPM) {editTempoMarker(id,position);return;}
    if (marker.sourceRegionID && std::any_of(session.song()->parts.begin(), session.song()->parts.end(),
            [&](const auto &part) { return part.id == *marker.sourceRegionID; })) {
        editRegion(*marker.sourceRegionID); return;
    }
    auto safe = SafePointer<Workspace>(this);
    auto close = [safe] { if (safe) ModalSheet::dismiss(*safe); };
    auto save = [safe, marker, songID = session.song()->id, projectID = session.project().id, close](String name, unsigned colour, bool) mutable {
        if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID) return;
        marker.name = utf8(name); marker.color = colour; marker.section=false; marker.loopSection=false;
        if (safe) safe->perform([&] { safe->session.edit([&](jaras::Project &p) {
            for (auto &song : p.songs) if (song.id == songID) {
                const auto updated=markerEditing::prepare(song,marker);
                if (!song.markers) song.markers.emplace();
                auto it = std::find_if(song.markers->begin(), song.markers->end(), [&](const auto &m) { return m.id == marker.id; });
                if (it == song.markers->end()) song.markers->push_back(updated); else *it = updated;
                song.duration=std::max(song.duration,updated.position);
            }
        }, false); close(); });
    };
    ModalSheet::open(*this, String::fromUTF8(marker.section.value_or(false)?"Marcador de trecho":"Editar marcador"), std::make_unique<RegionEditor>(markerEditing::editorName(marker), marker.color, false, save, close, false), 300, 370);
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
PopupMenu Workspace::masterMenu(bool barMixer) const {
    PopupMenu menu;
    menu.addItem(1,"Patch"); menu.addItem(2,"FX"); menu.addItem(3,"Env");
    menu.addItem(4,localization::translate(String::fromUTF8("Editar pista")));
    if(barMixer) {
        menu.addSeparator();
        menu.addItem(5,String::fromUTF8((bool)appearance.value("catlive.barMixer.masterRight",false)
            ?"Mostrar Master à esquerda":"Mostrar Master à direita"));
    }
    return menu;
}
void Workspace::showMasterMenu(Point<int> point, bool barMixer) {
    auto menu=masterMenu(barMixer);
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),
        [safe=SafePointer<Workspace>(this),barMixer](int choice) {
            if(safe)safe->handleMasterMenu(choice,barMixer);
        });
}
void Workspace::handleMasterMenu(int choice, bool barMixer) {
    auto safe=SafePointer<Workspace>(this);
    if(choice==1)showPanel("Patch",std::make_unique<PatchPanel>(session,ID{},[safe](String error){if(safe)safe->showError(error);}),360,400);
    if(choice==2)openFX({});
    if(choice==3)openAutomation({});
    if(choice==4)editMasterColour();
    if(choice==5&&barMixer)setBarMixerMasterRight(!(bool)appearance.value("catlive.barMixer.masterRight",false));
}
void Workspace::setBarMixerMasterRight(bool right) {
    const auto result=appearance.set("catlive.barMixer.masterRight",right);
    if(result.failed()){showError(result.getErrorMessage());return;}
    syncBarMixerMasterSide();
}
void Workspace::syncBarMixerMasterSide() {
    const bool right=(bool)appearance.value("catlive.barMixer.masterRight",false);
    if(footerMixer)footerMixer->setMasterRight(right);
    for(const auto &entry:floatingWindows)
        if(auto *panel=dynamic_cast<MixerPanel*>(entry.second->getContentComponent()))panel->setMasterRight(right);
}
void Workspace::setHozMixerSlotsOnly(bool value) {
    const auto result=appearance.set("catlive.hozMixer.slotsOnly",value);
    syncHozMixerMode();
    if(result.failed())showError(result.getErrorMessage());
}
void Workspace::syncHozMixerMode() {
    const bool value=(bool)appearance.value("catlive.hozMixer.slotsOnly",false);
    if(footerMixer)footerMixer->setSlotsOnly(value);
    for(const auto &entry:floatingWindows)
        if(auto *panel=dynamic_cast<MixerPanel*>(entry.second->getContentComponent()))panel->setSlotsOnly(value);
}
void Workspace::editMasterColour() {
    auto safe=SafePointer<Workspace>(this);
    auto close=[safe] { if(safe) for(auto *child:safe->getChildren()) if(auto *sheet=dynamic_cast<ModalSheet*>(child);sheet && sheet->getName()=="Editar pista") {sheet->exitModalState(0);break;} };
    auto save=[safe,close](String,unsigned colour,bool) { if(safe) safe->perform([&] { safe->session.edit([&](jaras::Project &project){project.masterColor=colour;},false);close();}); };
    auto editor=std::make_unique<RegionEditor>("Master",session.project().masterColor.value_or(0x414141),false,save,close,false,false);
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
                                if (jaras::fixedTrackName(t.role).empty()&&t.role.id!="vinhetas")
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
                                                    save, close, false, track.role.id!="vinhetas"),
                     300, 370);
}
void Workspace::editTrackIcon(ID id) {
    const auto *song=session.song(); if(!song) return;
    const auto at=trackTree::index(*song,id); if(at==song->tracks.size()) return;
    const auto targets=trackSelected(id)?selectedTracks:std::set<ID>{id};
    const auto project=session.project().id;
    const auto &track=song->tracks[at];
    auto save=[safe=SafePointer<Workspace>(this),targets,project](std::optional<std::string> value) {
        if(!safe || safe->session.project().id!=project) return;
        safe->perform([&]{safe->session.setTrackInstrumentIcon(targets,std::move(value));});
    };
    ModalSheet::open(*this,String::fromUTF8("Ícone da pista"),
        std::make_unique<TrackInstrumentPicker>(targets.size()>1?String((int)targets.size())+" pistas selecionadas":text(track.name),track.instrumentIcon,save),530,504);
}
void Workspace::specialTrackAction(ID id,const String &action) {
    if(action=="pcCopyPaste"){
        perform([&]{if(session.programChangePasteReady)pasteProgramMarker();else copyGridItems();});return;
    }
    if(action=="pcScan"){
        const Component::SafePointer<Workspace> owner(this);
        perform([this,id,owner]{
            auto marker=session.scanProgramChange(id);if(!marker)return;
            const auto project=session.project().id;
            auto close=[owner]{if(owner)ModalSheet::dismiss(*owner);};
            auto save=[safe=owner,id,project,marker=*marker,close](String name) mutable {
                if(!safe||safe->session.project().id!=project){close();return;}
                safe->perform([&]{marker.name=utf8(name);const auto inserted=safe->session.insertProgramChange(id,marker);
                    if(!inserted.empty()){safe->selectProgramMarker(inserted);safe->session.programChangeScanTrack.clear();safe->session.programChangeScanProject.clear();close();}});
            };
            ModalSheet::open(*this,"Program Change",std::make_unique<ItemNamePanel>(String{},save,close,12),360,150,
                [owner]{if(owner){owner->syncNativeTransport();if(owner->nativeTransport)owner->nativeTransport->repaintVisible();}});
            syncNativeTransport();
        });return;
    }
    if(action=="pcPatch"){showPanel("Patch",std::make_unique<PatchPanel>(session,id,[safe=SafePointer<Workspace>(this)](String error){if(safe)safe->showError(error);}),360,270);return;}
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
        chooser=std::make_unique<FileChooser>(localization::translate(String::fromUTF8("Adicionar mídia")),File{},"*.mp4;*.mov;*.m4v;*.avi;*.mkv;*.webm;*.png;*.jpg;*.jpeg;*.bmp");
        chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectFiles,[safe=SafePointer<Workspace>(this),id,project](const FileChooser &picker){
            if(!safe||safe->session.project().id!=project)return;const auto file=picker.getResult();if(!file.existsAsFile())return;
            safe->perform([&]{safe->session.importMedia({file},safe->session.transport().editPosition,id,MediaDropLayout::sameTrack,0);});
        });
    }
}

void Workspace::showTrackMenu(ID id, Point<int> point) {
    if(id.empty()){showMasterMenu(point,true);return;}
    const auto *song = session.song(); if (!song) return;
    const auto at = trackTree::index(*song,id); if (at == song->tracks.size()) return;
    const auto &track = song->tracks[at];
    auto targets = trackSelected(id) ? selectedTracks : std::set<ID>{id};
    targets.insert(id);
    const bool standard = jaras::fixedTrackName(track.role).empty();
    const bool groupable = trackEditing::canCreateGroup(*song,id);
    PopupMenu menu;
    if (standard || track.role.id=="timecode" || track.role.id=="video" || track.role.id=="generatedClick" || track.role.id=="programChange") menu.addItem(1,"Patch");
    if (track.role.id=="generatedClick") menu.addItem(2,"Sound Designer");
    if (standard) { menu.addItem(3,"FX"); if(track.role.id!="vinhetas")menu.addItem(4,"Criar item MIDI"); if(groupable)menu.addItem(5,localization::translate(String::fromUTF8("Criar grupo"))); }
    if (trackTree::end(*song,at)>at+1) menu.addItem(6,localization::translate("Ungroup"));
    if (track.parentTrackID) menu.addItem(7,localization::translate("Remover do grupo"));
    if (standard && trackEditing::linkable(*song,targets)) menu.addItem(8,localization::translate("Link tracks"));
    if (track.stereoLinkPartner) menu.addItem(9,localization::translate("Unlink tracks"));
    menu.addItem(10,localization::translate(String::fromUTF8("Editar pista")));
    menu.addItem(13,String::fromUTF8("Ícone da pista"));
    if (standard && track.role.id!="vinhetas") menu.addItem(12, targets.size() > 1 ? localization::translate("Duplicar pistas") : localization::translate("Duplicar pista"));
    menu.addSeparator(); menu.addItem(11,targets.size()>1 ? localization::translate("Delete tracks") : localization::translate("Delete track"));
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
            if(choice==13)w.editTrackIcon(id);
            if(choice==12)w.perform([&] {
                const auto copies=w.session.duplicateTracks(targets);
                if (!copies.empty()) {
                    w.selectedTracks=std::set<ID>(copies.begin(),copies.end());
                    w.selectedTrack=copies.front();
                    w.rebuild(); w.updateState();
                }
            });
            if(choice>=5 && choice<=7)w.perform([&]{w.session.editTrackHierarchy(songID,[&](jaras::Song &s){
                if(choice==5)trackEditing::createGroup(s,id);
                if(choice==6)trackEditing::ungroup(s,id);
                if(choice==7)trackEditing::removeFromGroup(s,id);
            });});
            if(choice>=8 && choice<=9)w.perform([&] {w.session.edit([&](jaras::Project &p) {
                if(choice==8){const auto &song=*w.session.song();const auto first=std::find_if(song.tracks.begin(),song.tracks.end(),[&](const auto &t){return targets.count(t.id);});trackEditing::link(p,songID,targets,1,theme::track(*first).getARGB()&0xffffff);}
                if(choice==9)trackEditing::unlink(p,id);
            });});
            if(choice==11){
                const auto remove=[safe,targets,project]{
                    if(!safe || safe->session.project().id!=project)return;
                    safe->perform([&]{safe->session.edit([&](jaras::Project &p){for(auto &song:p.songs)for(const auto &target:targets)trackTree::remove(song,target);});});
                };
                w.confirmTrackDeletion(targets, remove);
            }
        });
}
void Workspace::showClipMenu(ID id, Point<int> point) {
    PopupMenu menu;
    bool textItem = false, audioItem = false, midiItem = false, muted = false;
    bool projection = false, hasFX = false;
    ID ownerID;
    bool fileItem = false, separable = false;
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            for (const auto &clip : track.clips)
                if (clip.id == id) {
                    ownerID = track.id;
                    separable = audioSeparation::eligible(track,clip);
                    fileItem = clip.audioFile.has_value() && !clip.midi;
                    textItem = clip.text && !clip.audioFile;
                    audioItem = jaras::fixedTrackName(track.role).empty();
                    midiItem = clip.midi.has_value();
                    muted = clip.muted;
                    projection = track.role.id == "video" && clip.audioFile.has_value();
                    hasFX = clip.fxJSON && !list(get(JSON::parse(text(*clip.fxJSON)), "inserted")).isEmpty();
                }
    if ((fileItem || midiItem) && (!clipSelected(id) || selectedClips.size() <= 1)) {
        menu.addItem(41, "Editar nome"); menu.addSeparator();
    }
    if (fileItem && (!clipSelected(id) || selectedClips.size() <= 1)) {
        menu.addItem(40, localization::translate("Open file location")); menu.addSeparator();
    }
    if (midiItem) {
        menu.addItem(42, "Exportar MIDI", !clipSelected(id) || selectedClips.size() <= 1);
        menu.addItem(2,muted?localization::translate("Desmutar itens"):localization::translate("Mutar itens"));menu.addItem(31,localization::translate("Converter Mono"));menu.addItem(32,localization::translate(String::fromUTF8("Converter Estéreo")));menu.addItem(14,localization::translate("Unificar itens"));if(hasFX)menu.addItem(15,"FX");
    } else {
        if(audioItem || projection) {
            menu.addItem(9,localization::translate(String::fromUTF8("Criar região do item")));menu.addItem(13,"Re-render");menu.addItem(14,localization::translate("Unificar itens"));menu.addItem(10,"Tuner");
            if(separable&&(!clipSelected(id)||selectedClips.size()<=1))menu.addItem(16,"Separation audio");
            menu.addItem(11,localization::translate(String::fromUTF8("Normalizar…")));
            if(audioItem){menu.addSeparator();menu.addItem(24,localization::translate("Inverter - LR"));menu.addItem(21,localization::translate("Converter Mono - L"));menu.addItem(22,localization::translate("Converter Mono - R"));menu.addItem(23,localization::translate("Converter Mono L-R"));menu.addItem(20,localization::translate(String::fromUTF8("Converter Estéreo")));}
        }
        if(audioItem){menu.addSeparator();menu.addItem(2,muted?localization::translate("Desmutar itens"):localization::translate("Mutar itens"));}
        menu.addSeparator();menu.addItem(12,localization::translate("Exportar"),audioItem && !textItem);
    }
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
                       clipMenuAction(id, ownerID));
}
std::function<void(int)> Workspace::clipMenuAction(ID id, ID ownerID) {
    const auto targets = clipSelected(id) && !selectedClips.empty() ? selectedClips : std::set<ID>{id};
    const auto projectID = session.project().id;
    const auto songID = session.song() ? session.song()->id : ID{};
    return [safe = Component::SafePointer<Workspace>(this), id, ownerID, targets, projectID, songID](int action) {
            if (!safe || !action)
                return;
            safe->perform([safe,id,ownerID,targets,projectID,songID,action] {
                auto &w = *safe;
                if (action == 41 || action == 42) {
                    if(targets.size()!=1 || w.session.project().id!=projectID || !w.session.song() || w.session.song()->id!=songID)return;
                    for(const auto &track:w.session.song()->tracks)for(const auto &clip:track.clips)if(clip.id==id) {
                        if(action==41) {
                            auto close=[safe]{if(safe)ModalSheet::dismiss(*safe);};
                            ModalSheet::open(w,"Editar nome",std::make_unique<ItemNamePanel>(text(clip.name),
                                [safe,id,projectID,songID,close](String name){
                                    if(!safe||safe->session.project().id!=projectID||!safe->session.song()||safe->session.song()->id!=songID)return;
                                    safe->perform([&]{safe->session.edit([&](jaras::Project &p){
                                        for(auto &s:p.songs)if(s.id==songID)for(auto &t:s.tracks)for(auto &c:t.clips)if(c.id==id)c.name=utf8(name);
                                    },false);close();});
                                },close),380,112);
                        } else if(clip.midi) {
                            w.chooser=std::make_unique<FileChooser>("Exportar MIDI",File::getSpecialLocation(File::userDocumentsDirectory).getChildFile(File::createLegalFileName(text(clip.name))+".mid"),"*.mid",true);
                            w.chooser->launchAsync(FileBrowserComponent::saveMode|FileBrowserComponent::canSelectFiles|FileBrowserComponent::warnAboutOverwriting,
                                [safe,clip](const FileChooser &fc){if(safe && fc.getResult()!=File())safe->perform([&]{exportMIDIItem(clip,fc.getResult().withFileExtension("mid"));});});
                        }
                        return;
                    }
                    return;
                }
                if (action == 40) {
                    if (w.session.project().id != projectID || !w.session.song() || w.session.song()->id != songID) return;
                    for (const auto &track : w.session.song()->tracks) for (const auto &clip : track.clips)
                        if (clip.id == id && clip.audioFile) ProjectCodec::resolveMedia(w.session.mediaDirectory, clip.audioFile->path).revealToUser();
                    return;
                }
                if (action == 8) {
                    w.editTextItem(id);
                    return;
                }
                if(action==13 || action==14 || action==31 || action==32) {
                    if(w.session.project().id!=projectID || !w.session.song() || w.session.song()->id!=songID)return;
                    w.session.renderItems(targets,action==14,action>=31?action-30:0,
                        [safe,projectID,songID](std::set<ID> rendered) {
                            if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID)return;
                            safe->selectedClips=std::move(rendered);
                            safe->selectedClip=safe->selectedClips.empty()?ID{}:*safe->selectedClips.begin();
                            safe->updateState();
                        });
                    if(w.session.busy) {
                        const auto title=String::fromUTF8(action==14 ? "Unificar itens" : "Renderizar itens");
                        ModalSheet::open(w,title,std::make_unique<AudioSeparationPanel>(w.session,title),440,204);
                    }
                    return;
                }
                if(action==16){
                    if(w.session.project().id!=projectID||!w.session.song()||w.session.song()->id!=songID)return;
                    w.session.separateAudioItem(id,[safe,projectID,songID](std::set<ID> ids){
                        if(!safe||safe->session.project().id!=projectID||!safe->session.song()||safe->session.song()->id!=songID)return;
                        safe->selectedClips=std::move(ids);safe->selectedClip=safe->selectedClips.empty()?ID{}:*safe->selectedClips.begin();safe->updateState();
                    });
                    if(w.session.busy)ModalSheet::open(w,"Separation audio",std::make_unique<AudioSeparationPanel>(w.session),440,204);
                    return;
                }
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
                    if(w.session.project().id!=projectID || !w.session.song() || w.session.song()->id!=songID)return;
                    std::set<ID> audioTargets;
                    for(const auto &track:w.session.song()->tracks)if(jaras::fixedTrackName(track.role).empty())
                        for(const auto &clip:track.clips)if(targets.count(clip.id) && !clip.midi && (clip.audioFile || track.audioFile))
                            audioTargets.insert(clip.id);
                    if(audioTargets.empty())return;
                    ModalSheet::open(w, "Exportar",
                        std::make_unique<ItemExportProcessingPanel>([safe,audioTargets,projectID,songID](bool preProcessing) {
                            if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID)return;
                            auto panel=std::make_unique<ExportPanel>(safe->session,ID{},ID{},
                                [safe](String message){if(safe)safe->showError(message);},true,preProcessing,safe->appearance.storageFile());
                            panel->selectItems(audioTargets);
                            ModalSheet::open(*safe,"Exportar",std::move(panel),860,510);
                        }),confirmationStyle::width,186);
                    return;
                }
                if (action == 11) {
                    ModalSheet::open(
                        w, "Normalizar",
                        std::make_unique<NormalizationPanel>(w.session, w.appearance, targets), 440,
                        256 + std::min(5, (int)targets.size()) * 36);
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
                if (action >= 20 && action <= 24) {
                    if(w.session.project().id!=projectID || !w.session.song() || w.session.song()->id!=songID)return;
                    w.session.edit([&](jaras::Project &p) {
                        for(auto &song:p.songs) if(song.id==songID) for(auto &track:song.tracks)
                            if(jaras::fixedTrackName(track.role).empty()) for(auto &clip:track.clips)
                                if(targets.count(clip.id))clip.channelMode=action-20;
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
                                    return;
                                }
                });
            });
        };
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
        double itemEnd = position;
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
                        itemEnd = position + clip.duration;
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
        session.command(jaras::CommandKind::editSeek, {}, itemEnd);
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
        session.command(jaras::CommandKind::editSeek, {}, position + 10);
        editTextItem(itemID);
    });
}
void Workspace::editTextItem(ID id) {
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            for (const auto &clip : track.clips)
                if (clip.id == id && clip.text && !clip.audioFile) {
                    auto safe = SafePointer<Workspace>(this);
                    openFloating("Editor de texto",
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
                                                 if (auto window = safe->floatingWindows.find("Editor de texto");
                                                     window != safe->floatingWindows.end())
                                                     window->second->closeButtonPressed();
                                             });
                                         }),
                                     700, 336);
                    return;
                }
}
void Workspace::selectProgramMarker(const ID &id) {
    selectedClips.clear();selectedClip.clear();selectedTracks.clear();selectedTrack.clear();
    session.selectProgramChange(id);selectionAreas.activate(*timeline);
    timeline->invalidate();updateState();
}
void Workspace::pasteProgramMarker() {
    if(session.pasteProgramChange()) {
        selectedClips.clear();selectedClip.clear();selectedTracks.clear();selectedTrack.clear();
        selectionAreas.activate(*timeline);timeline->invalidate();updateState();
    }
}
void Workspace::copyGridItems(bool moving) {
    if(session.selectedProgramMarker()) {
        if(!moving && session.copyProgramChange()){itemClipboard.reset();itemClipboardSequence=GetClipboardSequenceNumber();}
        return;
    }
    if (!session.song() || session.busy || (moving && timelineGrid::movementLocked(session.project()))) return;
    const auto selection = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
    if (auto copied = GridItemClipboard::copy(session.project(), session.song()->id, selection, moving)) {
        session.programChangeClipboard.reset();session.programChangePasteReady=false;
        itemClipboard = std::move(copied);
        itemClipboardSequence = GetClipboardSequenceNumber();
        timeline->invalidate();
    }
}
void Workspace::pasteGridItems(bool duplicate) {
    if (!session.song() || session.busy) return;
    if(!duplicate && session.programChangeClipboard) {perform([&]{pasteProgramMarker();});return;}
    if (!duplicate && !gridMediaClipboard::ownsItems(itemClipboard.has_value(), itemClipboardSequence,
                                                    GetClipboardSequenceNumber())) {
        perform([&] {
            const auto paths = gridMediaClipboard::files();
            if (paths.isEmpty()) return;
            Array<File> media;
            for (const auto &path : paths) media.add(File(path));
            auto target = selectedTrack;
            if (std::none_of(session.song()->tracks.begin(), session.song()->tracks.end(),
                             [&](const auto &track) { return track.id == target; })) target.clear();
            importMediaAt(media, session.transport().editPosition, target);
        });
        return;
    }
    const auto selection = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
    const auto clipboard = duplicate ? GridItemClipboard::copy(session.project(), session.song()->id, selection) : itemClipboard;
    if (!clipboard || clipboard->song != session.song()->id ||
        (clipboard->moving && timelineGrid::movementLocked(session.project()))) return;
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
void Workspace::selectMixerTrack(const ID &id, ModifierKeys mods, bool clearItems, bool footer) {
    trackSelectionFromFooter=footer;
    if(clearItems) { if(footer && footerMixer)selectionAreas.activate(*footerMixer);else selectionAreas.activate(tracksViewport); }
    if (mods.isPopupMenu() && trackSelected(id)) return;
    if (mods.isShiftDown() && !trackSelectionAnchor.empty() && session.song()) {
        const auto &tracks = session.song()->tracks;
        auto a = std::find_if(tracks.begin(), tracks.end(), [&](const auto &t) { return t.id == trackSelectionAnchor; });
        auto b = std::find_if(tracks.begin(), tracks.end(), [&](const auto &t) { return t.id == id; });
        if (!mods.isCtrlDown()) selectedTracks.clear();
        if (a != tracks.end() && b != tracks.end()) {
            for (auto at = std::min(a, b); at <= std::max(a, b); ++at)
                if(footer ? TrackVisibility::supportsBarMixer(*at)&&trackVisibility.visible(*session.song(),TrackVisibility::Panel::barMixer,at->id)
                          : !rowHidden(int(std::distance(tracks.begin(),at))))selectedTracks.insert(at->id);
        } else selectedTracks.insert(id);
    } else if (mods.isCtrlDown()) {
        if (selectedTracks.empty() && !selectedTrack.empty()) selectedTracks.insert(selectedTrack);
        if (!selectedTracks.erase(id)) selectedTracks.insert(id);
        trackSelectionAnchor = id;
    } else {
        selectedTracks = {id}; trackSelectionAnchor = id;
    }
    selectedTrack = selectedTracks.count(id) ? id : selectedTracks.empty() ? ID{} : *selectedTracks.begin();
    if (clearItems) clearItemSelection();
    pruneTrackVisibilitySelection(footer);
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
bool Workspace::selectAllTracks(bool footer) {
    trackSelectionFromFooter=footer;
    selectedTracks.clear();
    if (const auto *song = session.song()) for (const auto &track : song->tracks)
        if (!jaras::isTeleprompterRole(track.role) && track.role.id != "video" && track.role.id != "timecode" && track.role.id != "chords"&&
            (footer?trackVisibility.visible(*song,TrackVisibility::Panel::barMixer,track.id):!rowHidden(int(trackTree::index(*song,track.id)))))selectedTracks.insert(track.id);
    selectedTrack = selectedTracks.empty() ? ID{} : *selectedTracks.begin();
    clearItemSelection(); updateState();
    for (auto *row : rows) row->repaint();
    timeline->invalidate(); repaint(); return true;
}
bool Workspace::selectAllGridItems() {
    selectedClips.clear();
    if (const auto *song = session.song()) for (const auto &track : song->tracks)
        if(!rowHidden(int(trackTree::index(*song,track.id))))for (const auto &clip : track.clips) selectedClips.insert(clip.id);
    selectedClip = selectedClips.empty() ? ID{} : *selectedClips.begin();
    timeline->invalidate(); repaint(); return true;
}
void Workspace::refreshMixerIndicator() {
    const auto window = floatingWindows.find("Mixer");
    const bool visible = mixerDetached
        ? window != floatingWindows.end() && window->second->isVisible()
        : footerMixerVisible;
    auto *button = controls["railMixer"];
    const auto colour = visible ? theme::green : Colours::white;
    if (button->findColour(TextButton::textColourOffId) != colour)
        button->setColour(TextButton::textColourOffId, colour);
}
void Workspace::showDetachedMixer() {
    mixerDetached = true; footerMixerVisible = false;
    auto panel = std::make_unique<MixerPanel>(session, [this](ID id, String key) { openFX(id, key); },
        [this](ID id, ModifierKeys mods) { selectMixerTrack(id, mods, true, true); }, [this](String message) { showError(message); },
        [this](ID id, bool remove) { changeMixerFX(id, remove); },
        [this](ID id) { return trackSelected(id); }, [this](ID id,Point<int> point){showTrackMenu(id,point);},[this](ID id,String action){specialTrackAction(id,action);},
        [this](ID id){return !session.song()||trackVisibility.visible(*session.song(),TrackVisibility::Panel::barMixer,id);});
    panel->setMasterRight((bool)appearance.value("catlive.barMixer.masterRight",false));
    panel->setSlotsOnly((bool)appearance.value("catlive.hozMixer.slotsOnly",false));
    panel->slotsOnlyChanged=[safe=SafePointer<Workspace>(this)](bool value){if(safe)safe->setHozMixerSlotsOnly(value);};
    selectionAreas.add(*panel, "tracks", [this] { return selectAllTracks(true); });
    openFloating("Mixer", std::move(panel), 1000, 420);
    resized(); repaint();
}
void Workspace::mixerMenu(Point<int> point) {
    PopupMenu menu;
    menu.addItem(1, localization::translate(mixerDetached ? "Dock mixer" : "Undock mixer"));
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
        std::make_unique<Projection>(session, appearance, index == 2 ? "teleprompt2" : "teleprompt", &stage);
    panel->configure = [safe = SafePointer<Workspace>(this), index] {
        if (safe)
            safe->openStageConfig(index);
    };
    panel->error = [safe = Component::SafePointer<Workspace>(this)](String message) {
        if (safe)
            safe->showError(message);
    };
    openFloating("Teleprompter " + String(index), std::move(panel), 800, 450);
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
    auto panel=std::make_unique<RemotePopover>(*remoteHost,[safe=SafePointer<Workspace>(this)]{if(safe)safe->toggleRemote();});
    auto *button=controls["remote"];
    const auto anchor=button?button->getScreenBounds():getScreenBounds().withSizeKeepingCentre(1,1);
    const auto *display=Desktop::getInstance().getDisplays().getDisplayForRect(anchor);
    panel->setSize(440,display?jlimit(280,820,display->userArea.getHeight()-100):650);
    CallOutBox::launchAsynchronously(std::move(panel),anchor,nullptr);
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
    showPanel(String::fromUTF8("Cronômetro"),
              std::make_unique<StageTimerSettings>(stage), 380, 348);
}
void Workspace::requestClose(std::function<void()> done, bool application) {
    if(jaras::projectSync::readOnly()) return;
    if (session.isSaving()) {
        session.waitForSave([safe = SafePointer<Workspace>(this), done, application](String error) {
            if (!safe) return;
            if (error.isNotEmpty()) safe->showError(error);
            else safe->requestClose(done, application);
        });
        return;
    }
    if (isCurrentlyBlockedByAnotherModalComponent()) {
        ModalComponentManager::getInstance()->bringModalComponentsToFront();
        return;
    }
    if (session.busy) {
        showError(String::fromUTF8("Aguarde a importação terminar antes de fechar."));
        return;
    }
    if (session.transport().playing || session.transport().subPlay.playing) {
        CloseProjectSheet::open(*this,
                [safe = Component::SafePointer<Workspace>(this), done, application](int action) {
                    if (safe && action == 2) {
                        safe->session.command(jaras::CommandKind::stopAll);
                        safe->requestClose(done, application);
                    }
                }, true, application);
        return;
    }
    if (session.dirty) {
        CloseProjectSheet::open(*this,
                [safe = Component::SafePointer<Workspace>(this), done](int action) {
                    if (!safe)
                        return;
                    if (action == 2)
                        done();
                    if (action == 1) safe->chooseSave(false, done);
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
    auto drops = object();
    put(drops,"entries",fileDragEntries);put(drops,"drops",fileDropCount);
    put(drops,"status",fileDropStatus);put(drops,"previewItems",(int)externalDropFiles.size());
    put(drops,"modalBlocked",isCurrentlyBlockedByAnotherModalComponent());
    put(value,"externalMediaDrop",drops);
    put(value, "project", text(session.project().name));
    put(value, "authAllowed", auth.allowed());
    put(value, "authBusy", auth.busy);
    put(value, "authMessage", auth.message);
    if (auto *device = session.audio.devices.getCurrentAudioDevice()) {
        auto audioDevice = object();
        put(audioDevice, "driver", session.audio.devices.getCurrentAudioDeviceType());
        put(audioDevice, "name", device->getName());
        put(audioDevice, "inputChannels", var(device->getInputChannelNames()));
        put(audioDevice, "outputChannels", var(device->getOutputChannelNames()));
        put(audioDevice, "activeInputs", device->getActiveInputChannels().countNumberOfSetBits());
        put(audioDevice, "activeOutputs", device->getActiveOutputChannels().countNumberOfSetBits());
        Array<var> rates, buffers;
        for (auto rate : device->getAvailableSampleRates()) rates.add(rate);
        for (auto size : device->getAvailableBufferSizes()) buffers.add(size);
        put(audioDevice, "sampleRates", rates);
        put(audioDevice, "bufferSizes", buffers);
        put(audioDevice, "sampleRate", device->getCurrentSampleRate());
        put(audioDevice, "bufferSize", device->getCurrentBufferSizeSamples());
        put(audioDevice, "xruns", device->getXRunCount());
        // Fraction of the callback budget (0..1), including every project tab
        // sharing this device manager, rather than this session's render alone.
        put(audioDevice, "callbackCpuUsage", session.audio.cpu());
        put(audioDevice, "nativeDeviceHost", usesNativeAudioDeviceHost(session.audio.devices));
        put(audioDevice, "open", device->isOpen());
        put(audioDevice, "running", device->isPlaying());
        put(value, "audioDevice", audioDevice);
    }
    put(value, "missingMedia", var(session.audio.missingFiles));
    put(value, "audioUnderruns", (int64)session.audio.getUnderruns());
    put(value, "audioCallback", session.audio.callbackMetrics.snapshot());
    put(value, "residentStreams", session.audio.residentStreams());
    put(value, "streaming", session.audio.streamDiagnostics());
    put(value, "audioPreparation", session.audio.preparationDiagnostics);
    put(value, "audioPeak", session.audio.peak());
    put(value, "playing", session.transport().playing);
    put(value, "position", session.transport().position);
    const auto audible = session.presentationTransport();
    put(value, "presentationPlaying", audible.playing);
    put(value, "presentationPosition", audible.position);
    put(value, "presentationLatencyFrames", (int64)session.audio.presentationLatencyFrames());
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
    put(value,"setlistPlacement",setlistPlacement==SetlistPlacement::left?"left":setlistPlacement==SetlistPlacement::right?"right":"detached");
    put(value,"setlistDetachedVisible",setlistWindow && setlistWindow->isVisible());
    put(value,"trackMixerVisible",tracksViewport.isVisible());
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
    Array<var> visibleTrackMixer,visibleBarMixer;
    if(const auto *song=session.song())for(size_t i=0;i<song->tracks.size();++i) {
        const auto &track=song->tracks[i];
        if(!rowHidden((int)i))visibleTrackMixer.add(text(track.id));
        if(TrackVisibility::supportsBarMixer(track)&&trackVisibility.visible(*song,TrackVisibility::Panel::barMixer,track))
            visibleBarMixer.add(text(track.id));
    }
    put(value,"visibleTrackMixerIDs",visibleTrackMixer);put(value,"visibleBarMixerIDs",visibleBarMixer);
    put(value, "mixerVisible", footerMixerVisible);
    put(value, "mixerScroll", footerMixer->scrollX());
    put(value, "partsLeftVisible", partsLeftVisible);
    put(value, "partsRightVisible", partsRightVisible);
    put(value,"partsLeftPreferredWidth",partsLeftWidth);put(value,"partsRightPreferredWidth",partsRightWidth);
    put(value, "partsSidebar", partsSidebar->diagnostics());
    auto sectionBounds = object();
    put(sectionBounds, "x", partsSidebar->getX());
    put(sectionBounds, "y", partsSidebar->getY());
    put(sectionBounds, "width", partsSidebar->getWidth());
    put(sectionBounds, "height", partsSidebar->getHeight());
    put(value, "partsSidebarBounds", sectionBounds);
    put(value, "partsLeft", partsLeft->diagnostics());
    auto leftPartsBounds = object();
    put(leftPartsBounds,"x",partsLeft->getX()); put(leftPartsBounds,"y",partsLeft->getY());
    put(leftPartsBounds,"width",partsLeft->getWidth()); put(leftPartsBounds,"height",partsLeft->getHeight());
    put(value,"partsLeftBounds",leftPartsBounds);
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
    const StringArray nativeButtons{"play", "pause", "subplay", "loop", "record", "metronome"};
    const auto transportFont = theme::semiboldFont((float)controls.at("setlist")->getProperties().getWithDefault("fontSize", 10.f));
    put(value, "nativeTransportFontEmSize", transportFont.getHeightInPoints());
    for (const auto &entry : controls) {
        auto bounds = object();
        put(bounds, "x", entry.second->getX());
        put(bounds, "y", entry.second->getY());
        put(bounds, "width", entry.second->getWidth());
        put(bounds, "height", entry.second->getHeight());
        put(bounds, "text", entry.second->getButtonText());
        put(bounds, "active", entry.second->getToggleState());
        put(layout, Identifier(entry.first), bounds);
        if (StringArray{"play", "subplay", "record"}.contains(entry.first)) {
            if (GlyphArrangement::getStringWidth(transportFont, entry.second->getButtonText()) + 18.f > entry.second->getWidth() + .5f)
                clippedButtonLabels.add(entry.first);
        } else if (entry.second->isVisible() && (bool)entry.second->getProperties()["centredIconLabel"]) {
            const auto font = theme::semiboldFont((float)entry.second->getProperties().getWithDefault("fontSize", 12.f));
            const auto width = entry.second->getWidth();
            const float padding = width < 56 ? 2.f : 6.f, gap = width < 56 ? 2.f : 4.f;
            if ((GlyphArrangement::getStringWidth(font, entry.second->getButtonText()) + 12.f + gap) * .75f > width - padding + .5f)
                clippedButtonLabels.add(entry.first);
        }
    }
    for (const auto *divider : {&mixerDivider, &setlistDivider, &partsLeftDivider, &partsRightDivider, &footerHeightDivider, &mixerHeightDivider}) {
        auto b = object(); put(b, "x", divider->getX()); put(b, "y", divider->getY()); put(b, "width", divider->getWidth()); put(b, "height", divider->getHeight());
        put(layout, Identifier(divider->getComponentID()), b);
    }
    put(value, "controls", layout);
    put(value, "clippedButtonLabels", clippedButtonLabels);
    put(value, "grandMA2BeforeResolume",
        controls.at("grandma2")->getX() < controls.at("resolume")->getX());
    bool overlaps = false, outside = false;
    std::vector<const Component *> transportItems{tempoControl.get(), tuner.get(), &songDisplay, &transportTime, &transportInfo};
    for (const auto &entry : controls)
        if ((entry.second->isVisible() || nativeButtons.contains(entry.first)) && entry.second->getY() >= transportBounds.getY() &&
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
void Workspace::resizePartsWidth(bool left,int delta) {
    int maximum=900;
    if (!left && setlistPlacement==SetlistPlacement::detached && partsSidebar->getParentComponent())
        maximum=partsSidebar->getParentComponent()->getWidth()-minimumSetlistWidth;
    else {
        const bool dockedSetlist=setlistVisible&&setlistPlacement!=SetlistPlacement::detached;
        const int other=left?(partsRightVisible&&dockedSetlist?partsSidebar->getWidth():0)
                            :(partsLeftVisible?partsLeft->getWidth():0);
        maximum=workspaceBounds.getWidth()-100-other-(mixerVisible?180:0)-(dockedSetlist?minimumSetlistWidth:0);
    }
    auto &width=left?partsLeftWidth:partsRightWidth;
    width=jlimit(160,std::max(160,std::min(900,maximum)),resizeStart+(left?delta:-delta));
    resized();repaint();
}
void Workspace::detachLeftParts() {
    class Host final : public Component {
      public:
        explicit Host(PartsPanel &p) : panel(p) { addAndMakeVisible(panel); }
        void resized() override { if (panel.getParentComponent() == this) panel.setBounds(getLocalBounds()); }
      private:
        PartsPanel &panel;
    };
    // Reparent the same panel: retain its current/queued tab and scroll position.
    partsLeftDetached = true; partsLeftVisible = false;
    auto host = std::make_unique<Host>(*partsLeft);
    openFloating("Parts", std::move(host), std::max(280, partsLeftWidth), 600);
    if (auto it = floatingWindows.find("Parts"); it != floatingWindows.end()) {
        auto *content = it->second->getContentComponent();
        content->addAndMakeVisible(*partsLeft); content->resized();
    }
    resized(); repaint();
}
void Workspace::leftPartsMenu(Point<int> point) {
    PopupMenu menu;
    menu.addItem(1, localization::translate(partsLeftDetached ? "Dock Parts" : "Undock Parts"));
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
        [safe = SafePointer<Workspace>(this)](int choice) {
            if (!safe || choice != 1) return;
            if (!safe->partsLeftDetached) { safe->detachLeftParts(); return; }
            safe->addAndMakeVisible(*safe->partsLeft);
            if (auto it = safe->floatingWindows.find("Parts"); it != safe->floatingWindows.end()) it->second->setVisible(false);
            safe->partsLeftDetached = false; safe->partsLeftVisible = true;
            safe->resized(); safe->repaint();
        });
}
void Workspace::toggleLeftParts() {
    if (partsLeftDetached) {
        if (auto it = floatingWindows.find("Parts"); it != floatingWindows.end()) {
            it->second->setVisible(!it->second->isVisible());
            if (it->second->isVisible()) it->second->toFront(true);
        } else detachLeftParts();
        resized(); repaint(); return;
    }
    partsLeftVisible = !partsLeftVisible;
    resized();
    repaint();
}
void Workspace::toggleRightParts() {
    partsRightVisible = !partsRightVisible;
    const int desiredWidth=std::max(650,partsRightWidth+minimumSetlistWidth);
    if (setlistWindow && setlistPlacement==SetlistPlacement::detached && partsRightVisible && setlistWindow->getWidth()<desiredWidth)
        setlistWindow->setSize(desiredWidth,setlistWindow->getHeight());
    resized();
    repaint();
}
void Workspace::layoutDetachedSetlist() {
    if (!setlistWindow) return;
    const int minimumWidth=partsRightVisible?620:235;
    setlistWindow->setResizeLimits(minimumWidth,300,2400,1800);
    if(setlistWindow->getWidth()<minimumWidth)setlistWindow->setSize(minimumWidth,setlistWindow->getHeight());
    if (auto *panel=setlistWindow->getContentComponent()) panel->resized();
}
void Workspace::setlistMenu(Point<int> point) {
    PopupMenu menu;
    menu.addItem(1,localization::translate("Undock Setlist"),true,setlistPlacement==SetlistPlacement::detached);
    menu.addItem(2,localization::translate(String::fromUTF8("Setlist à direita")),true,setlistPlacement==SetlistPlacement::right);
    menu.addItem(3,localization::translate(String::fromUTF8("Setlist à esquerda")),true,setlistPlacement==SetlistPlacement::left);
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),
        [safe=SafePointer<Workspace>(this)](int choice) {
            if (!safe || !choice) return;
            safe->setSetlistPlacement(choice==1?SetlistPlacement::detached:choice==2?SetlistPlacement::right:SetlistPlacement::left);
        });
}
void Workspace::setSetlistPlacement(SetlistPlacement placement) {
    timeline->cancelInteraction();
    setlistVisible=true;
    if (placement!=SetlistPlacement::detached) {
        setlistPlacement=setlistDockSide=placement;
        if (placement==SetlistPlacement::left) partsLeftVisible=false;
        addAndMakeVisible(*setlist);
        addChildComponent(*partsSidebar);
        addChildComponent(partsRightDivider);
        if (setlistWindow) setlistWindow->setVisible(false);
        resized(); repaint(); return;
    }
    if (setlistPlacement!=SetlistPlacement::detached) setlistDockSide=setlistPlacement;
    setlistPlacement=placement;
    class SetlistWindow final : public DocumentWindow {
      public:
        explicit SetlistWindow(Workspace &owner)
            : DocumentWindow("Setlist",theme::background,DocumentWindow::allButtons,true), w(owner) {
            setUsingNativeTitleBar(false);setTitleBarHeight(32);setResizable(true,false);
            setAlwaysOnTop(false);setComponentID("detachedSetlistWindow");
            shortcuts=std::make_unique<FloatingShortcuts>(*this,
                [safe=SafePointer<Workspace>(&w)](const KeyPress &key){return safe && safe->keyPressed(key);},
                [safe=SafePointer<Workspace>(&w)](bool down){if(safe)safe->keyStateChanged(down);});
        }
        void closeButtonPressed() override {
            setVisible(false);
            MessageManager::callAsync([safe=SafePointer<Workspace>(&w)] {
                if (safe && safe->setlistPlacement==SetlistPlacement::detached)
                    safe->setSetlistPlacement(safe->setlistDockSide);
            });
        }
        bool keyPressed(const KeyPress &key) override {
            if(key.getKeyCode()==KeyPress::F4Key && key.getModifiers().isAltDown()){closeButtonPressed();return true;}
            if(retryEditorShortcut(key))return true;
            if(w.selectionAreas.selectAll(key))return true;
            if(FloatingShortcuts::allows(key) && w.keyPressed(key))return true;
            return DocumentWindow::keyPressed(key);
        }
      private:
        Workspace &w;
        std::unique_ptr<FloatingShortcuts> shortcuts;
    };
    if (!setlistWindow) {
        auto window=std::make_unique<SetlistWindow>(*this);
        auto panel=std::make_unique<DetachedSetlistPanel>(*this);
        const int width=partsRightVisible?std::max(650,partsRightWidth+setlistWidth):std::max(336,setlistWidth);
        panel->setSize(width,std::max(320,workspaceBounds.getHeight()));
        window->setContentOwned(panel.release(),true);
        window->setResizeLimits(336,300,2400,1800);
        window->centreAroundComponent(this,width,std::max(352,workspaceBounds.getHeight()+32));
        setlistWindow=std::move(window);
    } else {
        auto *panel=setlistWindow->getContentComponent();
        panel->addAndMakeVisible(*setlist);panel->addChildComponent(*partsSidebar);panel->addChildComponent(partsRightDivider);
    }
    setlistWindow->setVisible(true);setlistWindow->toFront(true);
    resized();repaint();
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
void Workspace::openFX(ID track, String preferredEffect) {
    if(jaras::projectSync::readOnly()) return;
    std::vector<ID> targets;
    if (trackSelected(track))
        if (const auto *song = session.song())
            for (const auto &t : song->tracks)
                if (selectedTracks.count(t.id) && jaras::fixedTrackName(t.role).empty()) targets.push_back(t.id);
    String name = "Master";
    for (const auto &song : session.project().songs)
        for (const auto &t : song.tracks)
            if (t.id == track)
                name = text(t.name);
    const String windowName = "Gerenciador de FX - " + name;
    if (const auto it = floatingWindows.find(windowName); it != floatingWindows.end() && it->second->isVisible()) {
        it->second->toFront(true);
        if (auto *panel = dynamic_cast<EffectsPanel *>(it->second->getContentComponent()); panel && preferredEffect.isNotEmpty())
            panel->selectEffect(preferredEffect);
        return;
    }
    auto panel = std::make_unique<EffectsPanel>(
                     session, track,
                     [safe = Component::SafePointer<Workspace>(this)](String message) {
                         if (safe)
                             safe->showError(message);
                     }, false, targets);
    const auto editor = SafePointer<EffectsPanel>(panel.get());
    openFloating(windowName, std::move(panel), 920, 560);
    if (editor && preferredEffect.isNotEmpty()) editor->selectEffect(preferredEffect);
}
void Workspace::openItemFX(ID id) {
    if(jaras::projectSync::readOnly()) return;
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
    if (auto it = floatingWindows.find("Video"); it != floatingWindows.end()) {
        if (it->second->isVisible()) it->second->closeButtonPressed();
        else { it->second->setVisible(true); it->second->toFront(true); }
        updateState();
        return;
    }
    auto panel = std::make_unique<Projection>(session, appearance);
    panel->error = [safe = Component::SafePointer<Workspace>(this)](String message) {
        if (safe)
            safe->showError(message);
    };
    openFloating("Video", std::move(panel), 960, 600);
}
} // namespace catlive

#include "WorkspaceActions.h"
#include "WorkspaceMediaImportRegression.h"

namespace catlive {
void Workspace::toggleVinhetasDock() {
    if(vinhetasDetached){floatingWindows.erase("Vinhetas");dockContent.addAndMakeVisible(*vinhetasPanel);vinhetasDetached=false;vinhetasVisible=true;}
    else {
        class Holder final : public Component { public: VinhetasPanel &panel; explicit Holder(VinhetasPanel &p):panel(p){addAndMakeVisible(panel);} void resized() override {panel.setBounds(getLocalBounds());} };
        vinhetasDetached=true;vinhetasVisible=false;openFloating("Vinhetas",std::make_unique<Holder>(*vinhetasPanel),1100,260);
    }
    resized();
}
}
