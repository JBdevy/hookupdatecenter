#include "TimelineGridCache.h"
#include "TimelineSelection.h"
#include "../../Core/Project/RegionArrangement.hpp"
#include "../../Core/Songs/ItemDuration.hpp"
#include "AudioFormats.h"
#include "MediaSource.h"
#include "MatrixPatchPanel.h"
#include "ConfirmationPanel.h"
#include "AudioPreparationOverlay.h"
#include "StemFolderImportPanel.h"
#include "Localization.h"
#include "TrackInstrumentPicker.h"
#include "ItemNamePanel.h"
#include "ItemRatePanel.h"
#include "FullLyricsPanel.h"
#include "../../Core/Project/FullLyrics.hpp"
#include "MIDIItemExport.h"
#include "AudioSeparation.h"
#include "AudioSeparationPanel.h"
#include "MultitrackExportPanel.h"
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
#include "DesktopUpdateService.h"
#include "ProjectBackups.h"
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
#include "WorkspaceLibrary.h"
#include "SettingsPanel.h"
#include "StagePanels.h"
#include "StageTimerSettings.h"
#include "StagePreviewPanel.h"
#include "PatchPanel.h"
#include "AutomationPanel.h"
#include "EnvelopeLane.h"
#include "MetronomePanel.h"
#include "EffectsPanel.h"
#include "ProjectionSelection.h"
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
#include "DesktopToolbarSymbols.h"
#include "TimelineGrid.h"
#include "TimelineMarqueeIndex.h"
#include "WindowControlButton.h"
#include "WaveformRenderer.h"
#include "WaveformRasterIdentity.h"
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
Colour workspaceToolbarColour() {
    return theme::background == theme::darkBackground ? theme::background : Colour(0xff2a2a2a);
}
constexpr int mainStripWidth = 222;
}

namespace {
String audioFormatText(const AudioDeviceManager &devices) {
    auto *device = devices.getCurrentAudioDevice();
    if (device == nullptr || !device->isOpen()) return "No Device";
    const auto frames = device->getCurrentBufferSizeSamples();
    const auto rate = device->getCurrentSampleRate();
    const auto unavailable = String::fromUTF8("—");
    return (frames > 0 ? String(frames) : unavailable) + String::fromUTF8(" · ") +
           (rate > 0 && std::isfinite(rate) ? String(rate, 0) : unavailable) + " Hz";
}

void invalidateThemeImages(Component &component) {
    if (auto *image = component.getCachedComponentImage())
        image->invalidateAll();
    for (auto *child : component.getChildren())
        invalidateThemeImages(*child);
}

bool independentWorkspaceWindow(const String &name, const Component *content) {
    return name == "Mixer" || name == "Parts" || dynamic_cast<const Projection *>(content) != nullptr;
}
constexpr int compactTrackHeight = 28;
constexpr int expandedTrackHeight = 64;
bool allowsCompactTrackHeight(const jaras::Track &track) {
    return track.supportsMixerComponents() || track.role.id == "programChange" ||
        track.role.id == "generatedClick" || jaras::isTeleprompterRole(track.role);
}
double desktopLaneMinimum(int lanes, bool compact = false) {
    const double minimum = compact ? compactTrackHeight : double(theme::trackMixerMinHeight);
    return lanes > 1 ? std::max(26., minimum / lanes) : minimum;
}
int valueTooltipWidth(const String &label) {
    return std::max(88,roundToInt(GlyphArrangement::getStringWidth(theme::semiboldFont(12),label))+18);
}
void drawValueTooltip(Graphics &g, juce::Rectangle<int> bounds, const String &label) {
    g.setColour(Colour(0xf0262626));g.fillRoundedRectangle(bounds.toFloat(),5.f);
    g.setColour(Colour(0xff777777));g.drawRoundedRectangle(bounds.toFloat(),5.f,1.f);
    g.setFont(theme::semiboldFont(12));g.setColour(Colours::white);
    g.drawText(label,bounds,Justification::centred);
}
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
    refreshThemeColours();
}
void MacLook::refreshThemeColours() {
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
juce::Rectangle<int> MacLook::getTooltipBounds(const String &text, juce::Point<int> pointer,
                                              juce::Rectangle<int> area) {
    const auto font = theme::font(12);
    const int width = std::min(area.getWidth(), int(std::ceil(GlyphArrangement::getStringWidth(font, text))) + 18);
    const int height = std::min(area.getHeight(), std::max(24, int(std::ceil(font.getHeight())) + 8));
    const int x = pointer.x + width + 12 <= area.getRight() ? pointer.x + 12 : pointer.x - width - 6;
    const int y = pointer.y + height + 16 <= area.getBottom() ? pointer.y + 16 : pointer.y - height - 6;
    return juce::Rectangle<int>(x, y, width, height).constrainedWithin(area);
}
void MacLook::drawTooltip(Graphics &g,const String &text,int width,int height) {
    auto bounds=juce::Rectangle<float>(0,0,(float)width,(float)height).reduced(.5f);
    g.setColour(Colour(0xff353535)); g.fillRoundedRectangle(bounds,5);
    g.setColour(Colour(0xff707070)); g.drawRoundedRectangle(bounds,5,1);
    g.setColour(Colour(0xfff0f0f0)); g.setFont(theme::font(12));
    g.drawText(text, juce::Rectangle<int>(width,height).reduced(8, 2), Justification::centred, false);
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
        auto tint = b.findColour(b.getToggleState() ? TextButton::buttonOnColourId : TextButton::buttonColourId);
        if (down) tint = tint.brighter(.12f);
        if (!b.isEnabled()) tint = tint.withMultipliedAlpha(.35f);
        g.setColour(tint);
        g.fillRoundedRectangle(b.getLocalBounds().toFloat().reduced(.6f), 3.f);
        return;
    }
    if ((bool)b.getProperties()["zoomSegment"]) {
        if (over || down) {
            g.setColour(Colours::white.withAlpha(down ? .14f : .06f));
            g.fillRoundedRectangle(b.getLocalBounds().toFloat().reduced(1.f), 3.f);
        }
        return;
    }
    const bool plain = (bool)b.getProperties().getWithDefault("plain", false);
    if ((bool)b.getProperties()["toolbarLabel"]) return;
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
    const bool toolbar = (bool)b.getProperties()["toolbarLabel"];
    const bool greenAction=!toolbar && (background==theme::green || background==Colour(0xff60b746) ||
        background==Colour(0xff63b641) || background==Colour(0xff64b64a) ||
        background==Colour(0xff69b83d) || background==Colour(0xff60b53d));
    const auto opacity = b.isEnabled() || icon == "pause" || b.getProperties().contains("transportColour") ? 1.0f : .35f;
    auto ink = greenAction ? Colours::black : b.findColour(b.getToggleState() ? TextButton::textColourOnId : TextButton::textColourOffId);
    const auto toolbarSignal = (int)b.getProperties()["toolbarSignal"];
    if ((bool)b.getProperties()["zoomSegment"])
        ink = b.getToggleState() ? theme::green : Colour(0xffd5d5d5);
    if (toolbar) ink = toolbarSignal == 1 ? theme::green : theme::toolbarInactive;
    const auto foreground = ink.withMultipliedAlpha(opacity);
    g.setColour(foreground);
    if (toolbar && icon.isNotEmpty() && drawControlIcon(g, icon, toolbarSignal == 1 || b.isDown(),
            b.getLocalBounds().toFloat().withSizeKeepingCentre(18.f, 18.f), opacity)) return;
    if (toolbar && icon.isNotEmpty() && drawDesktopToolbarSymbol(g, icon,
            b.getLocalBounds().toFloat().withSizeKeepingCentre(18.f, 18.f))) return;
    const auto leading = b.getProperties().getWithDefault("leadingIcon", {}).toString();
    if (leading.isNotEmpty() && (bool)b.getProperties()["centredIconLabel"]) {
        const auto label = b.getButtonText();
        const auto font = g.getCurrentFont();
        const float textWidth = GlyphArrangement::getStringWidth(font, label);
        const bool compact = b.getWidth() < 56;
        const float preferredIcon = toolbar ? 14.f : 12.f;
        const float padding = compact ? 2.f : 6.f, gapSize = toolbar ? 4.f : compact ? 2.f : 4.f;
        const float available = std::max(0.f, b.getWidth() - padding);
        const float scale = jlimit(.75f, 1.f, available / std::max(1.f, textWidth + preferredIcon + gapSize));
        const float iconSize = preferredIcon * scale, gap = gapSize * scale;
        const float labelWidth = std::max(0.f, std::min(textWidth * scale,
                                                      available - iconSize - gap));
        const float x = (b.getWidth() - iconSize - gap - labelWidth) * .5f;
        if (leading == "record" && !b.getToggleState()) g.setColour(theme::liveOffRed.withMultipliedAlpha(opacity));
        const juce::Rectangle<float> iconBounds{x, (b.getHeight() - iconSize) * .5f, iconSize, iconSize};
        if (!drawControlIcon(g, leading, b.getToggleState(), iconBounds, opacity) &&
            (!toolbar || !drawDesktopToolbarSymbol(g, leading, iconBounds))) drawInterfaceIcon(g, leading, iconBounds);
        g.setColour(foreground);
        g.setFont(font.withPointHeight(font.getHeightInPoints() * scale));
        g.drawText(label, juce::Rectangle<float>(x + iconSize + gap, 0, labelWidth,
                                           (float)b.getHeight()), Justification::centredLeft, false);
        return;
    }
    if (leading.isNotEmpty()) {
        const juce::Rectangle<float> iconBounds{10, (b.getHeight() - 16) * .5f, 16, 16};
        if (!drawControlIcon(g, leading, b.getToggleState(), iconBounds, opacity))
            drawInterfaceIcon(g, leading, iconBounds);
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
    const float iconSize = (float)b.getProperties().getWithDefault("iconSize", 17.f);
    if (icon.isNotEmpty()) {
        const auto bounds = b.getLocalBounds().toFloat().withSizeKeepingCentre(iconSize, iconSize);
        const auto artwork = icon == "visibility" ? String("eye") : icon;
        if ((icon != "automationLanes" || b.getComponentID() == "track-envelopes") &&
            drawControlIcon(g, artwork, b.getToggleState() || b.isDown(), bounds, opacity)) return;
        if (drawDesktopToolbarSymbol(g, icon, bounds) || drawInterfaceIcon(g, icon, bounds)) return;
    }
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
    const auto axis = slider.getProperties()["zoomAxis"].toString();
    if (axis.isNotEmpty()) {
        const float center = y + h * .5f;
        g.setColour(Colour(0xffc5c5c5));
        drawControlIcon(g, axis, false, {3.f, center - 6.5f, 13.f, 13.f}, 1.f);
        g.setColour(Colour(0xff202020));
        g.fillRoundedRectangle(float(x) + 5.f, center - 2.f, std::max(1.f, w - 10.f), 4.f, 2.f);
        g.setColour(Colour(0xffa4a4a4));
        g.fillEllipse(pos - 5.f, center - 5.f, 10.f, 10.f);
        return;
    }
    const bool samplePreview = slider.getComponentID() == "library-sampler-preview-volume";
    if (samplePreview || (bool)slider.getProperties().getWithDefault("stageScale", false)) {
        const float middle = y + h * .5f;
        if (samplePreview) {
            g.setColour(Colours::white);
            drawDesktopToolbarSymbol(g, "speaker.wave.2", {0.f, middle - 6.f, 12.f, 12.f});
            g.setFont(theme::font(10));
            g.drawText(slider.getTextFromValue(slider.getValue()), slider.getWidth() - 37, y, 37, h,
                       Justification::centredRight);
        }
        g.setColour(Colour(0xff505050));
        g.fillRoundedRectangle((float)x, middle - 3, (float)w, 6, 3);
        g.setColour(theme::green);
        if (pos > x) g.fillRoundedRectangle((float)x, middle - 3, pos - x, 6, 3);
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
        const int gainX = slider.getComponentID() == "trackVolume" ? slider.getWidth() - 39 : 2;
        g.drawText(value >= 1 ? "+" + db : db, gainX, 0, 37, slider.getHeight(), Justification::centred);
        const float mid = (float)y + h * .5f;
        const auto background = slider.isColourSpecified(Slider::trackColourId) ? slider.findColour(Slider::trackColourId) : Colours::white.withAlpha(.25f);
        if (const auto *fader = dynamic_cast<const GainFader *>(&slider)) {
            const auto width = meterDisplay::railThickness;
            meterDisplay::rail(g, {(float)x, mid - width / 2, (float)w, width},
                               fader->meterLevels(), false, slider.getComponentID() == "trackVolume");
        } else {
            g.setColour(background);
            g.fillRoundedRectangle((float)x, mid - 3, (float)w, 6, 3);
        }
        meterDisplay::faderThumb(g, {pos, mid}, false);
        return;
    }
    g.setColour(Colour(0xff505050));
    if (style == Slider::LinearVertical) {
        if (slider.getComponentID() == "mixerFader") {
            const auto background = slider.isColourSpecified(Slider::trackColourId) ? slider.findColour(Slider::trackColourId) : Colours::white.withAlpha(.25f);
            if (const auto *fader = dynamic_cast<const GainFader *>(&slider)) {
                const auto width = meterDisplay::railThickness;
                meterDisplay::rail(g, {x + w * .5f - width / 2, (float)y, width, (float)h},
                                   fader->meterLevels(), true);
                meterDisplay::gainReduction(g, {x + w * .5f + width / 2 + 3, float(y + 6), 3, float(std::max(0, h - 12))},
                                            std::max(0.f, fader->gainReduction()));
            } else {
                g.setColour(background);
                g.fillRoundedRectangle(x + w * .5f - 3, (float)y, 6, (float)h, 3);
            }
            const float centre = x + w * .5f;
            meterDisplay::faderThumb(g, {centre, pos}, true);
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
    if (slider.getProperties().contains("zoomAxis")) {
        layout.sliderBounds = slider.getLocalBounds().withTrimmedLeft(18).withTrimmedRight(3);
        return layout;
    }
    if (slider.getComponentID() == "library-sampler-preview-volume")
        layout.sliderBounds = slider.getLocalBounds().withTrimmedLeft(18).withTrimmedRight(42);
    if (slider.getComponentID() == "mixerFader" && slider.isVertical()) {
        layout.sliderBounds = slider.getLocalBounds().reduced(0, 8);
    }
    if (slider.getComponentID().endsWith("Volume") && slider.isHorizontal()) {
        const bool track = slider.getComponentID() == "trackVolume";
        layout.sliderBounds = slider.getLocalBounds().withTrimmedLeft(track ? 8 : 42).withTrimmedRight(track ? 42 : 8);
    }
    return layout;
}
void MacLook::drawRotarySlider(Graphics &g, int x, int y, int w, int h, float fraction,
                              float start, float end, Slider &slider) {
    const auto id = slider.getComponentID();
    if (id == "trackPan" || id == "mixerPan" || id == "masterPan") {
        const auto bounds = slider.getLocalBounds().toFloat();
        const auto center = bounds.getCentre();
        const float diameter = std::max(1.f, std::min(18.f, std::min(bounds.getWidth(), bounds.getHeight()) - 2));
        const auto circle = bounds.withSizeKeepingCentre(diameter, diameter);
        const auto angle = (jlimit(-1., 1., slider.getValue()) * 135 - 90) * MathConstants<double>::pi / 180;
        const auto tip = center + juce::Point<float>((float)std::cos(angle), (float)std::sin(angle)) * (diameter * .4f);
        g.setColour(Colour(0xff2e2e2e));
        g.fillEllipse(circle);
        g.setColour(Colours::white.withAlpha(.35f));
        g.drawEllipse(circle, 1.f);
        g.setColour(Colour(0xff33c759));
        g.drawLine(Line<float>(center, tip), 2.f);
        return;
    }
    if (id == "trackVolume" || id == "mixerFader" || id.endsWith("Pan")) {
        const bool pan = id.endsWith("Pan");
        const auto bounds = slider.getLocalBounds().toFloat();
        const auto radius = std::max(1.f, std::min(bounds.getWidth(), bounds.getHeight()) / 2 - 3);
        const auto position = pan ? (slider.getValue() + 1) / 2
            : (20 * std::log10(std::max(.000001, slider.getValue())) + 60) / 84;
        drawMixerKnob(g, bounds.getCentre(), std::min(7.5f, radius), position, pan);
        return;
    }
    LookAndFeel_V4::drawRotarySlider(g, x, y, w, h, fraction, start, end, slider);
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
    MAPanel(Session &s, Lighting &l, std::function<void(String)> fail, std::function<void()> openIntegration)
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
        integrationButton = &button(String::fromUTF8("CatLive Integration…"),24,0,210,std::move(openIntegration));
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
        integrationButton->setBounds(24,getHeight()-78,210,30);
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
    TextButton *integrationButton = nullptr, *exportButton = nullptr, *advanced = nullptr, *selectAll = nullptr, *clearSelection = nullptr;
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
        trial = &button(auth.trialFinished ? String::fromUTF8("Verificar teste") : String::fromUTF8("Trial teste · 7 dias"), 226, 261, 184,
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
    explicit LoginBackdrop(Auth &auth) : panel(auth, true) {
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

class Workspace::Caption final : public Component, private ChangeListener {
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
        addChildComponent(update);
        update.setComponentID("desktopUpdate");
        update.setWantsKeyboardFocus(false);
        update.setColour(TextButton::buttonColourId, theme::yellow);
        update.setColour(TextButton::textColourOffId, Colours::black);
        update.getProperties().set("fontSize", 11.0f);
        update.onClick = [this] { updates->openInBrowser(); };
        updates->addChangeListener(this);
        refreshUpdate();
    }
    ~Caption() override { updates->removeChangeListener(this); }
    void setMaximiseEnabled(bool enabled) { maximise.setEnabled(enabled); }
    void paint(Graphics &g) override {
        g.fillAll(workspaceToolbarColour());
        g.setColour(theme::line.withAlpha(.5f));
        g.drawHorizontalLine(getHeight() - 1, 0, (float)getWidth());
        g.setFont(theme::semiboldFont(11));
        g.setColour(Colours::white.withAlpha(.9f));
        g.drawText(versionLabel(), versionBounds(), Justification::centredRight);
        if (w.browserVisible || w.loginPanel)
            return;
        auto saved = Time::fromISO8601(text(w.session.project().updatedAt));
        auto project = text(w.session.project().name);
        g.setColour(Colours::white.withAlpha(.9f));
        g.setFont(theme::semiboldFont(11));
        const int accessWidth = accessTitleWidth();
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
        update.setBounds(versionBounds().getX() - 8 - 62, std::max(2, (getHeight() - 22) / 2), 62, std::min(22, std::max(0, getHeight() - 4)));
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
    const String displayVersion = [] {
        const auto value = desktopUpdate::publicVersion(JUCE_APPLICATION_VERSION_STRING);
        return value.empty() ? String(JUCE_APPLICATION_VERSION_STRING) : String::fromUTF8(value.c_str());
    }();
    SharedResourcePointer<DesktopUpdateService> updates;
    TextButton update{"Update"};
    WindowControlButton minimise{DocumentWindow::minimiseButton},
        maximise{DocumentWindow::maximiseButton}, close{DocumentWindow::closeButton};
    ComponentDragger dragger;
    String versionLabel() const { return String("CatLive Version ") + displayVersion; }
    juce::Rectangle<int> versionBounds() const {
        const int width = (int)std::ceil(GlyphArrangement::getStringWidth(theme::semiboldFont(11), versionLabel()));
        return {getWidth() - 148 - width, 0, width, getHeight()};
    }
    int accessTitleWidth() const {
        return std::min(440, std::max(update.isVisible() ? 0 : 80, getWidth() - (update.isVisible() ? 760 : 604)));
    }
    void refreshUpdate() {
        update.setVisible(updates->available().has_value());
        update.setTooltip(updates->available() ? "CatLive " + String::fromUTF8(updates->available()->version.c_str()) : String());
        resized(); repaint();
    }
    void changeListenerCallback(ChangeBroadcaster *) override { refreshUpdate(); }
    void toggleMaximise() {
        if (w.browserVisible && !w.projectReady && !w.loginPanel) return;
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
        for (auto *b : {&mute, &solo, &phase, &fx, &output, &env, &record, &monitor}) {
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
        mute.setComponentID("trackMute");
        solo.setComponentID("trackSolo");
        phase.setButtonText(String::fromUTF8("Ø"));
        fx.setButtonText("FX");
        record.setButtonText("REC");
        record.setComponentID("trackRecord");
        monitor.setComponentID("trackInputMonitor");
        monitor.setButtonText("I");
        monitor.setTooltip(localization::translate("Input monitoring"));
        monitor.setColour(TextButton::buttonOnColourId, theme::green);
        monitor.setColour(TextButton::textColourOnId, Colours::black);
        monitor.onClick = [this] {
            if (auto *t = track()) w.perform([&] { w.session.setTrackInputMonitoring(id, !t->inputMonitoring.value_or(false)); });
        };
        peak=std::make_unique<meterDisplay::PeakReadout>([this]{return w.session.audio.heldPeak(id);},[this]{w.session.audio.clearPeak(id);},[this]{return track()?theme::surfaceText(rowSurface(*track())):Colours::white;});addAndMakeVisible(*peak);
        record.setTooltip(String::fromUTF8("REC: clique para armar ou desarmar. Shift+clique: automático. Clique direito: configurações."));
        record.onClick = [this] { w.perform([&] { w.session.cycleRecordArm(id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}, ModifierKeys::getCurrentModifiers().isShiftDown()); }); };
        record.context = [this](Point<int>) {
            RecordingOptionsPanel::show(w.session, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}, record,
                [safe = SafePointer<Workspace>(&w)](String message) { if (safe) safe->showError(message); });
        };
        env.setTitle("Envelopes");
        env.setComponentID("trackEnvelope");
        env.getProperties().set("icon", "automationLanes");
        env.getProperties().set("iconSize", 15.f);
        env.setColour(TextButton::buttonOnColourId, theme::green);
        env.setColour(TextButton::textColourOnId, Colours::black);
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
        output.setComponentID("trackPatch");
        mute.setTooltip("Mute");
        solo.setTooltip("Solo");
        phase.setTooltip("Inverter fase");
        output.setTooltip(String::fromUTF8("Roteamento de saída"));
        fx.setTooltip("Efeitos da pista");
        mute.setColour(TextButton::buttonOnColourId, theme::trackMute);
        solo.setColour(TextButton::buttonOnColourId, theme::yellow);
        for (auto *b : {&mute, &solo, &phase, &fx, &output, &env, &record, &monitor}) {
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 10);
            b->setColour(TextButton::buttonColourId, theme::trackControl);
            b->getProperties().set("cornerRadius", theme::trackButtonRadius);
        }
        phase.setColour(TextButton::buttonOnColourId, theme::yellow);
        mute.onClick = [this] {
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::mute, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}); });
        };
        solo.onClick = [this] {
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::solo, id, w.trackSelected(id) ? w.selectedTracks : std::set<ID>{id}); });
        };
        mute.context = [this](Point<int>) { w.mapMixerControl(id, jaras::CommandKind::mute); };
        solo.context = [this](Point<int>) { w.mapMixerControl(id, jaras::CommandKind::solo); };
        volume.mapControl = [this] { w.mapMixerControl(id, jaras::CommandKind::volume); };
        mute.modifiedClick = [this](ModifierKeys mods) {
            if (!mods.isCtrlDown()) return false;
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::mute, id, {}, 0, true); });
            return true;
        };
        solo.modifiedClick = [this](ModifierKeys mods) {
            if (!mods.isCtrlDown()) return false;
            w.perform([&] { w.session.mixerCommand(jaras::CommandKind::solo, id, {}, 0, true); });
            return true;
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
        addAndMakeVisible(pan);
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
        pan.setComponentID("trackPan");
        pan.setRange(-1, 1, .01);
        pan.setSliderStyle(Slider::RotaryVerticalDrag);
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
        addChildComponent(rename);
        rename.navigate = [this](int direction) { w.stepMixerTrack(direction, true); };
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
    void refreshInputMonitor(const jaras::Track &track) {
        const bool available = !track.receivesMain();
        monitor.setEnabled(available);
        monitor.setToggleState(available && track.inputMonitoring.value_or(false), dontSendNotification);
    }
    void refreshMixer() {
        if(const auto* t=track()) {
            const ScopedValueSetter<bool> guard(updating,true);
            refreshInputMonitor(*t);
            pan.setValue(t->pan,dontSendNotification);
            volume.setValue(w.session.trackDisplayVolume(id,t->volume),dontSendNotification);
            volume.setEnabled(!w.session.trackFaderLocked(id));
            mute.setToggleState(w.session.trackDisplayMute(id,t->mute),dontSendNotification);
            solo.setToggleState(w.session.trackDisplaySolo(id,t->solo),dontSendNotification);
            phase.setToggleState(t->phaseInverted.value_or(false),dontSendNotification);
            phase.setTooltip(t->phaseInverted.value_or(false)?"Fase invertida - Restaurar fase":"Inverter fase");
            if(special)special->refresh();
            repaint();
        }
    }
    void refresh() {
        if (auto *t = track()) {
            updating = true;
            pan.setValue(t->pan,dontSendNotification);
            volume.setValue(w.session.trackDisplayVolume(id, t->volume), dontSendNotification);
            volume.setEnabled(!w.session.trackFaderLocked(id));
            mute.setToggleState(w.session.trackDisplayMute(id,t->mute), dontSendNotification);
            solo.setToggleState(w.session.trackDisplaySolo(id,t->solo), dontSendNotification);
            phase.setToggleState(t->phaseInverted.value_or(false), dontSendNotification);
            phase.setTooltip(t->phaseInverted.value_or(false) ? "Fase invertida - Restaurar fase" : "Inverter fase");
            env.setToggleState(!automation::visible(*t).isEmpty(), dontSendNotification);
            const int arm = w.session.recordArm(id);
            record.setVisible(jaras::fixedTrackName(t->role).empty());
            refreshInputMonitor(*t);
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
                p.firstChannel == 0    ? String("Main")
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
    int bodyWidth() const { return getWidth(); }
    juce::Rectangle<int> signalLight;
    Colour signalColour{0xff151515};
    juce::Rectangle<int> titleBounds(const jaras::Track &t, int body) const {
        if ((t.role.id == "programChange" && body < 40 || jaras::isTeleprompterRole(t.role) && body < expandedTrackHeight) && special) {
            const int left = groupIndent() + stripeWidth() + 4;
            return {left, std::max(0, (body - 22) / 2), std::max(1, special->getX() - left - 4), 22};
        }
        if ((t.supportsMixerComponents() || t.role.id == "generatedClick") && body < expandedTrackHeight) {
            const int left = groupIndent() + stripeWidth() + (isFolder() ? 50 : 28);
            int right = signalLight.getX() - 3;
            for (const auto *button : {&record, &monitor, &mute, &solo})
                if (button->isVisible()) right = std::min(right, button->getX() - 4);
            return {left, std::max(0, (body - 22) / 2), std::max(1, right - left), 22};
        }
        if (t.compactMixerControls()) {
            const int left = groupIndent() + stripeWidth() + 4;
            return {left,std::max(25,body-17),std::max(1,bodyWidth()-left-40),16};
        }
        const bool expanded = body >= 64;
        const int x = groupIndent() + stripeWidth() + 4;
        const bool textTrack = jaras::isTeleprompterRole(t.role) || t.role.id == "chords";
        const int height = expanded ? 16 : 21;
        const int right = peak->isVisible() && peak->getBottom() > body - height - 1 ? peak->getX() - 3 :
            textTrack && special && !expanded ? special->getX() - 4 :
            expanded ? bodyWidth() - 4 : (jaras::fixedTrackName(t.role).empty() ? fx.getX() - 4 :
                special ? special->getX() - 4 : bodyWidth() - 4);
        return {x, std::max(0, body - height - 1), std::max(1, right - x), height};
    }
    void refreshMeters() {
        if (peak) peak->refresh();
        const auto levels = w.session.audio.meterLevels(id);
        if (volume.isVisible() && volume.isHorizontal()) {
            volume.setMeterLevels(levels);
        }
        if (!signalLight.isEmpty()) {
            const auto amplitude = std::max(levels[0], levels[1]);
            const Colour next = amplitude > 1.f ? Colour(0xfff44336) :
                amplitude >= .14125376f ? Colour(0xffffdc52) :
                amplitude > .001f ? Colour(0xff239653) : Colour(0xff151515);
            if (next != signalColour) { signalColour = next; repaint(signalLight.expanded(1)); }
        }
    }
    bool stripeOnly() const { return w.appearance.mixerStripeOnly(theme::trackMixerStyleKey); }
    int stripeWidth() const { return stripeOnly() ? theme::trackMixerStripeWidth : 0; }
    Colour rowSurface(const jaras::Track &track) const {
        const bool selected = w.trackSelected(id);
        if (stripeOnly()) return theme::trackStripeSurface(selected);
        const auto *song = w.session.song();
        return theme::trackSurface(theme::track(track), selected, song ? trackTree::silenced(*song, track) : track.mute);
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
                const auto parent = trackTree::index(*song, *t->parentTrackID);
                g.setColour(parent < song->tracks.size() ? theme::track(song->tracks[parent]) : theme::green);
                g.drawVerticalLine(x, 0, last ? 17.f : (float)getHeight());
                g.drawHorizontalLine(17, (float)x, (float)indent - 4);
            }
            const auto colour = rowSurface(*t);
            g.setColour(colour);
            const auto lanes = automation::visible(*t);
            const int body = getHeight() - lanes.size() * 32;
            g.fillRect(indent, 0, bodyWidth() - indent, body - 1);
            const int stripe = stripeWidth();
            if (stripe > 0) {
                g.setColour(theme::track(*t));
                g.fillRect(indent, 0, stripe, body - 1);
            }
            g.setFont(theme::semiboldFont(11));
            g.setColour(theme::surfaceText(colour));
            String number;
            if (const auto *song = w.session.song())
                number = String((int)trackTree::index(*song, id) + 1).paddedLeft('0', 2) + "  ";
            const auto name = titleBounds(*t, body);
            const auto scannedPC=t->role.id=="programChange"?w.session.scannedProgramChangePacket(id):uint64(0);
            const int scanWidth=scannedPC?88:0;
            g.drawText(number + text(t->name), name.withWidth(std::max(1, name.getWidth() - scanWidth)),
                       Justification::centredLeft, true);
            if(scannedPC) {
                g.setFont(theme::font(10));
                g.drawText("PC "+String(int(scannedPC&127)+1)+"  CH "+String(int((scannedPC>>7)&15)+1),
                           name.getRight()-scanWidth,name.getY(),scanWidth,name.getHeight(),Justification::centredRight);
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
        if (const auto *t = track(); t && !signalLight.isEmpty()) {
            trackIcons::draw(g, t->instrumentIcon, {float(groupIndent() + stripeWidth() + 4), float(signalLight.getCentreY() - 10), 20.f, 20.f});
            g.setColour(signalColour);
            g.fillEllipse(signalLight.toFloat());
            g.setColour(Colour(0xff2d3236));
            g.drawEllipse(signalLight.toFloat(), .5f);
        } else if (const auto *t = track(); t && volume.isVisible() && volume.getSliderStyle() == Slider::LinearHorizontal) {
            if (t->compactMixerControls())
                trackIcons::draw(g,t->instrumentIcon,{float(groupIndent()+stripeWidth()+4),float(volume.getY()-1),24.f,22.f});
            else if (volume.getHeight() > 0)
                trackIcons::draw(g, t->instrumentIcon, {float(groupIndent() + stripeWidth() + 4),
                    std::max(0.f, float(volume.getBounds().getCentreY()) - 28.f), 40.f, 40.f});
        }
        g.setColour(theme::line.withAlpha(.7f));
        g.drawHorizontalLine(getHeight() - 1, 0, (float)bodyWidth());
    }
    void resized() override {
        const auto *t = track();
        const int body = getHeight() - (t ? automation::visible(*t).size() * 32 : 0);
        const int contentStart = groupIndent() + stripeWidth();
        const bool expanded = body >= 64;
        const int titleY = std::max(0, body - (expanded ? 16 : 21) - 1);
        const bool teleprompter = t && jaras::isTeleprompterRole(t->role);
        const int groupHeight = t && (t->role.id=="chords" || t->role.id=="programChange") ? 24 : 44;
        const bool centerSpecial = t && (t->role.id == "programChange" && body < 40 || teleprompter && !expanded);
        const int y = centerSpecial ? std::max(0, (body - 21) / 2) : expanded ? std::max(0, std::min((body - groupHeight) / 2, titleY - groupHeight)) : (body <= theme::trackMixerMinHeight ? titleY : std::max(0, (body - 21) / 2));
        const int h = expanded ? 24 : 21;
        const int volumeY = y + h;
        const int volumeHeight = jlimit(0, 20, body - 17 - volumeY);
        const bool metronome = t && t->role.id == "generatedClick";
        const bool heightCompact = t && (t->supportsMixerComponents() || metronome) && body < expandedTrackHeight;
        signalLight = heightCompact ? juce::Rectangle<int>{bodyWidth() - 17, std::max(0, (body - 10) / 2), 10, 10} : juce::Rectangle<int>{};
        int x = bodyWidth() - 4;
        auto place = [&](Component &control, int width) {
            x -= width; control.setBounds(x, y, width, h); x -= 3;
        };
        const bool standard=t&&jaras::fixedTrackName(t->role).empty();
        const bool textTrack=teleprompter||(t&&t->role.id=="chords");
        const bool meterReadout = t && !textTrack && t->role.id != "timecode" && t->role.id != "programChange";
        peak->setVisible(expanded&&meterReadout);
        record.setVisible(standard);
        monitor.setVisible(standard && t->role.id != "vinhetas");
        pan.setVisible(standard && t->showsComponent(jaras::Track::panBit));
        fx.setVisible(standard);
        env.setVisible(standard&&expanded);
        output.setVisible(expanded && standard);
        const bool audioButtons=standard||(t&&(t->role.id=="timecode"||t->role.id=="generatedClick"||t->role.id=="programChange"));
        mute.setVisible(audioButtons);solo.setVisible(audioButtons);
        if (standard) {
            env.setVisible(expanded && t->showsComponent(jaras::Track::envelopeBit));
            output.setVisible(output.isVisible() && t->showsComponent(jaras::Track::patchBit));
            fx.setVisible(t->showsComponent(jaras::Track::fxBit));
            record.setVisible(t->showsComponent(jaras::Track::recBit));
            monitor.setVisible(monitor.isVisible() && t->showsComponent(jaras::Track::inputBit));
            mute.setVisible(t->showsComponent(jaras::Track::muteBit)); solo.setVisible(t->showsComponent(jaras::Track::soloBit));
            const std::pair<Component*, int> buttons[] = {
                {&solo, 22}, {&mute, 22}, {&pan, 22}, {&monitor, 22},
                {&record, 22}, {&fx, 22}, {&env, 28}, {&output, 34}
            };
            int idealWidth = -3;
            for (const auto& [button, width] : buttons)
                if (button->isVisible()) idealWidth += width + 3;
            const int left = contentStart + (expanded && isFolder() ? 51 : 0);
            const double scale = std::min(1.0, std::max(0, x - left) / double(std::max(1,idealWidth)));
            double right = x;
            for (const auto& [button, width] : buttons) {
                if (!button->isVisible()) continue;
                const int buttonRight = roundToInt(right);
                right -= scale * width;
                const int buttonLeft = roundToInt(right);
                button->setBounds(buttonLeft, y, buttonRight - buttonLeft, h);
                right -= scale * 3;
            }
        } else {
            if (solo.isVisible()) place(solo, 22);
            if (mute.isVisible()) place(mute, 22);
        }
        if (special) {
            special->setVisible(!standard);
            if (teleprompter) {
                const int width = std::max(0, std::min(208, x - contentStart - (expanded ? 0 : 67)));
                special->setBounds(x - width, y, width, h);
            } else {
                const int width = t && t->role.id=="timecode" ? 116 : metronome ? 100 :
                    t && t->role.id=="programChange" ? 159 : 108;
                special->setBounds(std::max(22, x - width), y, width, textTrack ? 48 : h);
            }
        }
        folder.setBounds(contentStart + 20, y + (h - 20) / 2, 28, 20);
        folder.setVisible(expanded && isFolder());
        phase.setVisible(standard && expanded && !t->compactMixerControls() && t->role.id != "vinhetas" && t->showsComponent(jaras::Track::phaseBit));
        volume.setVisible(t && expanded && (!textTrack || teleprompter) && t->role.id != "programChange");
        phase.setBounds(bodyWidth() - 26, volumeY, 22, volumeHeight);
        phase.getProperties().set("plain", true);
        const int volumeRight = bodyWidth() - (standard || metronome || teleprompter || t && t->role.id == "timecode" ? 30 : 4);
        const int volumeLeft = std::max(contentStart + 48, volumeRight - 186);
        peak->setBounds(bodyWidth() - 38, volumeY + volumeHeight + 1, 34, 12);
        if (expanded) volume.setBounds(volumeLeft, volumeY, std::max(1, volumeRight - volumeLeft), volumeHeight);
        if (heightCompact) {
            if (metronome && special) special->setVisible(false);
            for (auto *button : {&fx, &env, &output}) button->setVisible(false);
            pan.setVisible(false);
            peak->setVisible(false);
            volume.setVisible(false);
            const int top = std::max(0, (body - 22) / 2);
            int right = signalLight.getX() - 6;
            for (auto *button : {&solo, &mute, &monitor, &record}) if (button->isVisible()) {
                button->setBounds(right - 22, top, 22, 22);
                right -= 25;
            }
            if (isFolder()) { folder.setVisible(true); folder.setBounds(contentStart + 28, top + 1, 20, 20); }
        } else if (standard && t->compactMixerControls()) {
            const int top = std::max(0, std::min((body - 22) / 2, body - 17 - 22));
            const int iconSpace = 28;
            const int visibleCount = (int)monitor.isVisible() + (int)mute.isVisible() + (int)solo.isVisible();
            int start = std::max(contentStart + 4 + iconSpace + (isFolder() ? 23 : 0),
                                 bodyWidth() - 4 - 186 - 25 * visibleCount);
            if(isFolder()) { folder.setVisible(true);folder.setBounds(contentStart+4+iconSpace,top+1,20,20); }
            for (auto *button : {&monitor, &mute, &solo}) if (button->isVisible()) {
                button->setBounds(start, top, 22, 22); start += 25;
            }
            const int right = bodyWidth() - (phase.isVisible() ? 28 : 4);
            const int width = jlimit(1, 186, right-start);
            volume.setBounds(right-width, top+1, width, 20);
            phase.setBounds(bodyWidth()-25,top+1,21,20);
            peak->setVisible(meterReadout); peak->setBounds(bodyWidth()-38,top+22,34,12);
        }
        if (t) rename.layoutIn(titleBounds(*t, body).withTrimmedLeft(20));
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
    void mouseDoubleClick(const MouseEvent &event) override {
        const auto *t = track();
        if (!t || !event.mods.isLeftButtonDown() ||
            event.mods.isAnyModifierKeyDown()) return;
        const int body = getHeight() - automation::visible(*t).size() * 32;
        if (titleBounds(*t, body).withTrimmedLeft(20).contains(event.getPosition())) beginRename();
    }
    void confirmRename() { rename.confirm(); }
    void beginRename() {
        const auto *t = track();
        const auto *song = w.session.song();
        if (!t || !song || !canRenameMixerTrack(*t)) return;
        const int body = getHeight() - automation::visible(*t).size() * 32;
        const auto bounds = titleBounds(*t, body).withTrimmedLeft(20);
        dragging = pendingSelection = false;
        rename.open(bounds, text(t->name),
            [workspace = SafePointer<Workspace>(&w), project = w.session.project().id,
             songID = song->id, target = id](String name) {
                if (!workspace || workspace->session.project().id != project || !workspace->session.song() ||
                    workspace->session.song()->id != songID) return;
                workspace->perform([&] { workspace->session.renameTrack(target, name); });
            });
    }
    bool isInterestedInDragSource(const SourceDetails &d) override {
        if (isLibraryEffectDrag(d.description)) return track() && jaras::fixedTrackName(track()->role).empty();
        return w.session.song() && !trackDrop::source(d.description,w.session.project(),*w.session.song()).empty();
    }
    void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
    void itemDragMove(const SourceDetails &d) override {
        if (isLibraryEffectDrag(d.description)) { libraryEffectOver = true; repaint(); return; }
        if(!w.session.song())return;
        w.trackDropPreview=trackDrop::resolve(*w.session.song(),trackDrop::sources(d.description,w.session.project(),*w.session.song()),id,d.localPosition.y>getHeight()/2,d.localPosition.x<16);
        w.trackDropBlocked=w.trackDropPreview?ID{}:id;w.repaint();
    }
    void itemDragExit(const SourceDetails &) override {
        libraryEffectOver = false; repaint();
        w.trackDropPreview.reset(); w.trackDropBlocked.clear(); w.repaint();
    }
    void itemDropped(const SourceDetails &d) override {
        if (isLibraryEffectDrag(d.description)) {
            itemDragExit(d);
            w.perform([&] { w.session.insertLibraryEffect(id, str(d.description, "identity"), str(d.description, "preset")); });
            return;
        }
        itemDragMove(d);const auto destination=w.trackDropPreview;const ID song=w.session.song()?w.session.song()->id:ID{};
        itemDragExit(d);
        if(destination)w.perform([&]{w.session.editTrackHierarchy(song,[&](jaras::Song &s){trackDrop::apply(s,*destination,trackDrop::sources(d.description,w.session.project(),s));});});
    }
    void paintOverChildren(Graphics &g) override {
        if (libraryEffectOver) {
            g.setColour(theme::green.withAlpha(.20f));
            g.fillRect(getLocalBounds());
        }
    }

  private:
    bool isLibraryEffectDrag(const var &description) const {
        return str(description, "type") == "catlive-library-effect" && str(description, "project") == text(w.session.project().id);
    }
    Workspace &w;
    ID id;
    std::unique_ptr<SpecialTrackControls> special;
    std::unique_ptr<meterDisplay::PeakReadout> peak;
    QuietButton mute, solo, phase, fx, output, env, record, monitor;
    TextButton folder;
    GainFader volume;
    ParameterSlider pan;
    InlineMixerTrackName rename;
    bool updating = false, dragging = false, pendingSelection = false;
    bool libraryEffectOver = false;
    std::optional<std::string> fxColourSource;
    Colour fxColour=Colours::white;
};

namespace {
void drawTimelineNeedle(Graphics &graphics, float x, float top, float tip, float bottom, Colour colour) {
    graphics.setColour(colour.withMultipliedAlpha(.12f));
    graphics.fillRect(x-3, tip, 6.f, std::max(0.f,bottom-tip));
    graphics.setColour(colour);
    graphics.fillRect(x-.75f, tip, 1.5f, std::max(0.f,bottom-tip));
    Path head;
    head.startNewSubPath(x-5,top);
    head.lineTo(x+5,top);
    head.quadraticTo(x+7.5f,top,x+6.25f,top+2.25f);
    head.lineTo(x+.9f,tip-1.1f);
    head.quadraticTo(x+.5f,tip,x,tip);
    head.quadraticTo(x-.5f,tip,x-.9f,tip-1.1f);
    head.lineTo(x-6.25f,top+2.25f);
    head.quadraticTo(x-7.5f,top,x-5,top);
    head.closeSubPath();
    graphics.fillPath(head);
}
}

class RecordingPianoCanvas final : public Component, private ScrollBar::Listener {
public:
    RecordingPianoCanvas(MIDIEditorPanel &editor, Session &value, Appearance &style,
                         std::function<bool(double, double, bool, ModifierKeys)> seek)
        : editor(editor), session(value), appearance(style), seek(std::move(seek)) {
        setOpaque(true);
        setWantsKeyboardFocus(true);
        setName("MIDI Preview");
        setComponentID("midiPreviewLiveCanvas");
        addAndMakeVisible(horizontal);
        addAndMakeVisible(vertical);
        for (auto *bar : {&horizontal,&vertical}) {
            bar->setAutoHide(false);
            bar->addListener(this);
        }
        horizontal.setTitle("MIDI Preview time");
        horizontal.setComponentID("midiPreviewHorizontalScroll");
        vertical.setTitle("MIDI Preview pitch");
        vertical.setComponentID("midiPreviewVerticalScroll");
        vertical.setSingleStepSize(1);
        vertical.setRangeLimits(0,128,dontSendNotification);
    }
    ~RecordingPianoCanvas() override {
        horizontal.removeListener(this);
        vertical.removeListener(this);
    }
    void resized() override {
        horizontal.setBounds(keyboardWidth, canvasHeight(), std::max(0,canvasWidth()-keyboardWidth), scrollbarSize);
        vertical.setBounds(canvasWidth(),0,scrollbarSize,canvasHeight());
        refresh();
    }
    void setView(const jaras::Track* track, const jaras::AudioClip* item, double zoom, double rowHeight) {
        const ID current = item ? item->id : ID{};
        if (current != projectedItem || projectedRevision != session.revision) {
            projectedRevision = session.revision;
            projectedItem = current;
            projected.clear();
            if (item && track && session.song()) {
                try { projected = takePlaybackNotes(*track, *item, *session.song(), true); }
                catch (const std::exception&) { projected.clear(); }
            }
            rulerSections.clear();
        }
        timeZoom = zoom;
        keyHeight = rowHeight;
        refresh();
    }
    void refresh() {
        const auto transport = session.presentationTransport();
        const bool playing = transport.playing || transport.paused;
        const double position = playing ? transport.position : transport.editPosition;
        frame = session.recordingPianoFrame();
        const auto loop = session.transport().loop;
        if (frame && loop.enabled && loop.start && loop.end &&
            std::abs(frame->position - position) >= (*loop.end - *loop.start) / 2)
            frame.reset();
        const double passOffset = frame ? frame->passOffset : -1;
        const auto song = session.song();
        const auto songID = song ? song->id : ID{};
        if (songID != previousSong || playing != playbackCursor || std::abs(passOffset-previousPass) > .000001 ||
            position + .03 < cursor || (!playing && position != cursor))
            manualTime.reset();
        previousSong = songID; previousPass = passOffset;
        playbackCursor = playing;
        cursor = position;
        const auto meter = song ? ClickProgram::meterAt(*song, cursor) : ClickProgram::Section{0, 0, 0, 120, 4, 4};
        beat = 240. / (std::max(1., meter.bpm) * std::max(1, meter.unit));
        timeSpan = std::max(1, canvasWidth() - keyboardWidth) * beat / timeZoom;
        firstTime = frame ? std::min(cursor,frame->position-(frame->elapsed-frame->passOffset)) : (playing ? 0 : -timeSpan / 2);
        const double duration = song && !frame ? song->duration : 0;
        const double lastTime = std::max({firstTime+timeSpan, cursor+timeSpan / 2, duration});
        maxLeft = std::max(firstTime,lastTime-timeSpan);
        followLeft = jlimit(firstTime,maxLeft,cursor-timeSpan*(playing ? .875 : .5));
        left = jlimit(firstTime,maxLeft,manualTime.value_or(followLeft));
        horizontal.setSingleStepSize(beat);
        horizontal.setRangeLimits(firstTime,lastTime,dontSendNotification);
        horizontal.setCurrentRange(left,timeSpan,dontSendNotification);
        visibleKeys = jlimit(1.,128.,(canvasHeight()-rulerHeight)/keyHeight);
        if (song && (rulerSections.empty() || rulerSections.back().end < left + timeSpan))
            rulerSections = timelineGrid::rulerSections(*song, std::max(song->duration,left + timeSpan + 60));
        collectTakes();
        topPitch = jlimit(0., 128-visibleKeys, pitchOffset.value_or(67-visibleKeys/2));
        if (latestNote != previousNote) {
            previousNote = latestNote;
            if (latestNote) {
                const double row = 127 - latestNote->second;
                if (row < topPitch + 1 || row + 2 > topPitch + visibleKeys) {
                    topPitch = jlimit(0., 128-visibleKeys, row-visibleKeys/2);
                    pitchOffset = topPitch;
                }
            }
        }
        vertical.setCurrentRange(topPitch,visibleKeys,dontSendNotification);
        editor.previewGeometry = {left,std::max(1,canvasWidth()-keyboardWidth)/timeSpan,topPitch,keyHeight,keyboardWidth,rulerHeight};
        repaint();
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        const auto x = wheel.deltaX, y = wheel.deltaY;
        if (event.mods.isAltDown()) {
            pitchOffset = jlimit(0.,128 - visibleKeys,topPitch - y * 300 / keyHeight);
        } else if (event.mods.isCtrlDown()) {
            if (wheel.isInertial) return;
            editor.setPreviewHeight(keyHeight * std::pow(1.3,y * 4));
            const auto nextHeight = editor.previewKeyHeight();
            pitchOffset = topPitch + visibleKeys * .5 * (1 - keyHeight / nextHeight);
            keyHeight = nextHeight;
        } else if (event.mods.isShiftDown() || event.mods.isLeftButtonDown() || std::abs(x) > std::abs(y)) {
            const auto delta = std::abs(x) > std::abs(y) ? x : y;
            browseTime(left - delta * 500 * beat / timeZoom);
        } else if (!wheel.isInertial && y != 0) {
            const auto old = editor.previewZoom();
            editor.setPreviewZoom(old * std::pow(1.3,y * 4));
            timeZoom = editor.previewZoom();
            if (!playbackCursor || manualTime)
                manualTime = left + std::max(0,event.x - keyboardWidth) * beat * (1 / old - 1 / timeZoom);
        }
        refresh();
    }
    void mouseMove(const MouseEvent& event) override {
        if (event.x < keyboardWidth || event.x >= canvasWidth() || event.y >= canvasHeight())
            setMouseCursor(MouseCursor::NormalCursor);
        else
            setMouseCursor(editor.previewCursor(event.position));
    }
    void mouseExit(const MouseEvent&) override { setMouseCursor(MouseCursor::NormalCursor); }
    void mouseDown(const MouseEvent &event) override {
        emptyPress = event.getNumberOfClicks() == 1 && event.mods.isLeftButtonDown() &&
                     !event.mods.isPopupMenu() && !editor.hasPreviewNote(event.position);
        if (editor.editsPreview() && event.x >= keyboardWidth && event.x < canvasWidth() && event.y >= rulerHeight && event.y < canvasHeight()) {
            grabKeyboardFocus();
            editor.previewInput().mouseDown(event);
            editingGesture = true; repaint(); return;
        }
        editingGesture = false;
        if (event.mods.isLeftButtonDown() && !event.mods.isPopupMenu()) seekAt(event);
    }
    void seekAt(const MouseEvent& event) {
        if (event.x < keyboardWidth || event.x >= canvasWidth() || event.y >= canvasHeight()) return;
        const double scale = std::max(1, canvasWidth() - keyboardWidth) / timeSpan;
        const double priorLeft = left;
        if (seek(left + (event.position.x - keyboardWidth) / scale, scale, event.y < rulerHeight, event.mods)) {
            if (!session.transport().playing) {
                cursor = session.transport().editPosition;
                playbackCursor = false;
                manualTime = priorLeft;
            }
            refresh();
        }
    }
    void mouseDrag(const MouseEvent& e) override {
        if (editingGesture && editor.editsPreview()) { editor.previewInput().mouseDrag(e); repaint(); }
    }
    void mouseUp(const MouseEvent& e) override {
        if (!editingGesture) return;
        editor.previewInput().mouseUp(e);
        editingGesture = false;
        if (emptyPress && e.getDistanceFromDragStart() <= 3) seekAt(e);
        repaint();
    }
    bool keyPressed(const KeyPress& key) override {
        return editor.editsPreview() && editor.previewInput().keyPressed(key);
    }
    void paint(Graphics &g) override {
        const float width = float(canvasWidth()), height = float(canvasHeight());
        const auto x = [&](double seconds) { return float(keyboardWidth + (seconds-left)*std::max(1.f,width-keyboardWidth)/timeSpan); };
        const auto y = [&](int pitch) { return float(rulerHeight+(127-pitch-topPitch)*keyHeight); };
        g.fillAll(Colour(0xff262626));
        {
            Graphics::ScopedSaveState keys(g);
            g.reduceClipRegion(0,rulerHeight,canvasWidth(),std::max(0,canvasHeight()-rulerHeight));
            const int high = 127-int(topPitch);
            const int low = std::max(0,high-int(std::ceil(height/keyHeight)));
            for (int pitch=low; pitch<=high; ++pitch) {
                const int key = pitch % 12;
                const bool black = key==1 || key==3 || key==6 || key==8 || key==10;
                g.setColour(Colour(black ? 0xff191919 : 0xff262626));
                g.fillRect(0.f,y(pitch),width,float(keyHeight));
                g.setColour(Colour(black ? 0xff333333 : 0xffbfbfbf));
                g.fillRect(0.f,y(pitch),40.f,float(keyHeight-.5));
                if (!key) {
                    g.setColour(Colours::black);
                    g.setFont(theme::font(9));
                    g.drawText("C"+String(pitch/12-1),0,int(y(pitch)),40,int(keyHeight),Justification::centred);
                }
            }
        }
        g.reduceClipRegion(keyboardWidth,0,std::max(0,canvasWidth()-keyboardWidth),canvasHeight());
        g.setColour(Colour(0xff171717));
        g.fillRect(keyboardWidth, 0, canvasWidth() - keyboardWidth, rulerHeight);
        const auto pixelsPerSecond = std::max(1.f,width-keyboardWidth) / timeSpan;
        g.setFont(theme::font(11));
        for (const auto& tick : timelineGrid::ticks(rulerSections,4,std::max(0.,left),left+timeSpan,pixelsPerSecond,true)) {
            const auto tx = roundToInt(x(tick.time));
            g.setColour(Colours::white.withAlpha(tick.primary ? .27f : .12f));
            g.drawVerticalLine(tx,0,tick.drawsInGrid ? height : float(rulerHeight));
            if (tick.label.isNotEmpty()) {
                g.setColour(Colours::white);
                g.drawText(tick.label,tx+3,0,55,rulerHeight,Justification::centredLeft);
            }
        }
        {
            Graphics::ScopedSaveState notes(g);
            g.reduceClipRegion(keyboardWidth,rulerHeight,std::max(0,canvasWidth()-keyboardWidth),std::max(0,canvasHeight()-rulerHeight));
            g.setColour(theme::green);
            if (editor.editsPreview()) editor.drawPreviewNotes(g);
            else for (const auto &note : projected)
                if (note.end > left && note.start < left + timeSpan) {
                    juce::Rectangle<float> rect{x(note.start),y(note.pitch),std::max(1.f,x(note.end)-x(note.start)),float(keyHeight-1)};
                    g.fillRoundedRectangle(rect,2.f);
                    drawPianoNoteLabel(g,rect,note.pitch,note.velocity);
                }
            for (const auto &take : takes) {
                const auto &preview = *take.preview;
                for (const auto &note : preview.midi.notes) {
                    const double start = std::max(take.start,note.start/preview.rate);
                    const double end = note.end < 0 ? take.end : std::min(take.end,note.end/preview.rate);
                    if (end > start && take.origin+end >= left && take.origin+start <= left+timeSpan) {
                        juce::Rectangle<float> rect{x(take.origin+start),y(note.pitch),
                            std::max(1.f,x(take.origin+end)-x(take.origin+start)),float(keyHeight-1)};
                        g.setColour(theme::green);
                        g.fillRect(rect);
                        drawPianoNoteLabel(g,rect,note.pitch,note.velocity);
                    }
                }
            }
        }
        if (cursor >= left && cursor <= left+timeSpan) {
            const auto colour = playbackCursor
                ? appearance.colour("jaras.timeline.playCursor",theme::timelinePlayCursorRGB)
                : appearance.colour("jaras.timeline.editCursor",theme::timelineEditCursorRGB);
            drawTimelineNeedle(g,x(cursor),0,rulerHeight,height,colour);
        }
    }
private:
    MIDIEditorPanel& editor;
    bool editingGesture = false, emptyPress = false;
    struct Take { std::shared_ptr<const RecordingPreview> preview; double start, end, origin; };
    Session &session;
    Appearance &appearance;
    std::function<bool(double, double, bool, ModifierKeys)> seek;
    ScrollBar horizontal{false},vertical{true};
    static constexpr int keyboardWidth = 42, rulerHeight = 16, scrollbarSize = 13;
    double keyHeight = 18, timeZoom = 100;
    ID projectedItem;
    uint64 projectedRevision = ~uint64(0);
    std::vector<PlaybackNote> projected;
    std::vector<timelineGrid::Section> rulerSections;
    std::optional<double> manualTime, pitchOffset;
    std::optional<Session::RecordingPianoFrame> frame;
    std::vector<Take> takes;
    ID previousSong;
    double previousPass = -1, cursor = 0, beat = .5, timeSpan = 8, firstTime = 0, maxLeft = 0, left = 0, topPitch = 0;
    double followLeft = 0, visibleKeys = 1;
    bool playbackCursor = false;
    std::optional<std::pair<double, int>> latestNote, previousNote;
    int canvasWidth() const { return std::max(0,getWidth()-scrollbarSize); }
    int canvasHeight() const { return std::max(0,getHeight()-scrollbarSize); }
    void collectTakes() {
        takes.clear();
        latestNote.reset();
        if (frame) for (const auto &item : session.recordingItems) {
            if (item.clip.sourceOffset != 0 || !item.preview->midiLog) continue;
            const auto &preview = *item.preview;
            const double start = std::max(0.,frame->passOffset-item.captureOffset);
            const double origin = frame->position-frame->elapsed+item.captureOffset;
            // The capture can lead the audible grid at the wrap. Keep only
            // the currently audible portion of the current pass.
            const double end = std::min({frame->elapsed-item.captureOffset,
                                         preview.frames.load(std::memory_order_acquire)/preview.rate,cursor-origin});
            if (end <= start) continue;
            takes.push_back({item.preview,start,end,origin});
            for (const auto &note : preview.midi.notes) {
                if (note.start/preview.rate >= end || (note.end >= 0 && note.end/preview.rate <= start)) continue;
                const double onset = item.captureOffset + note.start / preview.rate;
                if (!latestNote || onset > latestNote->first ||
                    (onset == latestNote->first && note.pitch > latestNote->second))
                    latestNote = std::pair{onset, note.pitch};
            }
        }
    }
    void browseTime(double position) {
        const auto target = jlimit(firstTime, maxLeft, position);
        if (std::abs(target - left) < .000001) return;
        if (playbackCursor && std::abs(target - followLeft) < .000001) manualTime.reset();
        else manualTime = target;
    }
    void scrollBarMoved(ScrollBar *bar,double position) override {
        if (bar == &vertical) pitchOffset = position;
        else browseTime(position);
        refresh();
    }
};

class RecordingPianoPreview final : public Component, public DragAndDropTarget {
public:
    RecordingPianoPreview(Session &session, Appearance &appearance, const ID &selectedTrack,
                          std::function<void(String)> error,
                          std::function<bool(double,double,bool,ModifierKeys)> seek)
        : session(session), selectedTrack(selectedTrack),
          editor(session, {}, std::move(error), true),
          live(editor, session, appearance, std::move(seek)) {
        setName("MIDI Preview");
        addAndMakeVisible(editor);
        addAndMakeVisible(live);
    }
    void resized() override {
        editor.setBounds(getLocalBounds());
        live.setBounds(editor.pianoBounds());
    }
    bool isInterestedInDragSource(const SourceDetails& source) override {
        return editor.isInterestedInDragSource(source);
    }
    void itemDropped(const SourceDetails& source) override {
        refresh();
        editor.itemDropped(source);
        live.repaint();
    }
    void refresh() {
        const auto state = session.presentationTransport();
        const bool recording = session.audio.isRecording();
        const bool playing = state.playing || state.subPlay.playing;
        const auto position = state.playing || state.paused ? state.position : state.editPosition;
        const jaras::Track *track = nullptr;
        const jaras::AudioClip *item = nullptr;
        if (!recording && session.song()) {
            for (const auto &candidate : session.song()->tracks) if (candidate.id == selectedTrack) {
                track = &candidate;
                for (const auto &clip : candidate.clips)
                    if (clip.midi && clip.startTime <= position && position < clip.startTime + clip.duration &&
                        (!item || clip.startTime >= item->startTime)) item = &clip;
                break;
            }
        }
        const bool edit = item && !playing && !state.paused && !recording;
        editor.setPreviewItem(edit ? item->id : ID{});
        live.setView(track,item,editor.previewZoom(),editor.previewKeyHeight());
    }
private:
    Session &session;
    const ID &selectedTrack;
    MIDIEditorPanel editor;
    RecordingPianoCanvas live;
};

class Workspace::Timeline final : public Component, private ScrollBar::Listener, private Timer {
  public:
    bool suspendsTimebase() const { return regionTimebaseSuspended; }
    explicit Timeline(Workspace &owner)
        : w(owner), horizontal(false), vertical(owner), canvas(*this), heads(*this) {
        addAndMakeVisible(canvas);
        canvas.setBufferedToImage(true);
        addAndMakeVisible(heads);
        addChildComponent(horizontal);
        horizontal.setVisible(false);
        addAndMakeVisible(vertical);
        vertical.setAutoHide(false);
        vertical.setLookAndFeel(&scrollLook);
        vertical.setComponentID("timelineVerticalScroll");
        horizontal.addListener(this);
        vertical.addListener(this);
        horizontal.addMouseListener(this, false);
        vertical.addMouseListener(this, false);
        canvas.addAndMakeVisible(envelopeContent);
        envelopeContent.setInterceptsMouseClicks(false, true);
        heads.setInterceptsMouseClicks(false, false);
        setWantsKeyboardFocus(false);
    }
    ~Timeline() override { vertical.setLookAndFeel(nullptr); }
    void resized() override {
        auto area = getLocalBounds();
        const bool heightChanged = canvas.getHeight() != area.getHeight();
        horizontal.setBounds({});
        area.removeFromRight(timelineGrid::verticalScrollbarWidth);
        canvas.setBounds(area);
        heads.setBounds(area);
        w.zoom.setRange(minimumZoom(), timelineGrid::maximumZoom);
        w.zoom.setSkewFactorFromMidPoint(5);
        w.pixelsPerSecond = w.zoomMemory ? minimumZoom() : std::max(minimumZoom(), w.pixelsPerSecond);
        w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
        updateRanges(heightChanged);
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
    static constexpr int headerLaneHeight = 16, rulerHeight = 2 * headerLaneHeight;
    int visibleRegionRows() const { return w.showRegionLanes ? regionLanes().count : 0; }
    int regionLaneTop(int lane) const { return lane * headerLaneHeight; }
    int regionRowsBottom() const { return regionLaneTop(visibleRegionRows()); }
    int tempoTop() const { return regionRowsBottom() + (w.showRegionLanes ? headerLaneHeight : 0); }
    int rulerTop() const { return tempoTop() + (w.showTempoLane ? headerLaneHeight : 0); }
    int cursorLaneTop() const { return rulerTop() + headerLaneHeight; }
    int markerTop(bool tempo) const { return tempo ? tempoTop() : regionRowsBottom(); }
    bool showsMarker(bool tempo) const { return tempo ? w.showTempoLane : w.showRegionLanes; }
    bool inRegionRows(float y) const { return y >= 0 && y < regionRowsBottom(); }
    bool onRuler(float y) const { return y >= rulerTop() && y < headerHeight(); }
    int headerHeight() const { return rulerTop() + rulerHeight; }
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
        canvas.invalidateGrid();
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
    void updateRanges(bool rowGeometryChanged = true) {
        if (rowGeometryChanged) w.invalidateRowGeometry();
        canvas.invalidateSelectionLayout();
        const auto *s = displaySong();
        const int top = std::min(canvas.getHeight(), headerHeight());
        vertical.setBounds(canvas.getRight(), top, getWidth() - canvas.getRight(), canvas.getHeight() - top);
        updateHorizontalRange(sendNotificationSync);
        vertical.setRangeLimits(
            0, std::max(canvas.getHeight() - headerHeight(), w.rowTop(s ? (int)s->tracks.size() : 0) + w.trackHeight * 2));
        vertical.setCurrentRange(w.verticalOffset, std::max(1, canvas.getHeight() - headerHeight()));
        invalidate();
    }
    void refreshTimingGeometry() {
        const auto previousRows=w.rowGeometry;
        const int previousHeader = rulerHeight + (w.showRegionLanes ? (regionLayout.count + 1) * headerLaneHeight : 0) +
            (w.showTempoLane ? headerLaneHeight : 0);
        updateRanges();
        bool changed=previousHeader!=headerHeight() || previousRows.size()!=w.rowGeometry.size();
        for(int i=0;!changed && i<previousRows.size();++i)
            changed=previousRows.height(i)!=w.rowGeometry.height(i) || previousRows.body(i)!=w.rowGeometry.body(i);
        // Tempo changes usually move items horizontally. Rebuild panel geometry
        // only if overlap lanes or region lanes actually changed their height.
        if(changed)w.resized();
    }
    void invalidate() {
        if (lanesRevision != w.session.revision) {
            std::vector<std::tuple<ID,var,int,int>> desired;
            if(const auto *song=w.session.song())for(size_t row=0;row<song->tracks.size();++row) {
                int lane=0;for(auto curve:automation::visible(song->tracks[row]))desired.emplace_back(song->tracks[row].id,curve,int(row),lane++);
            }
            bool retain=lanes.size()==int(desired.size());
            for(int i=0;retain && i<lanes.size();++i)retain=lanes[i]->displays(std::get<0>(desired[size_t(i)]),std::get<1>(desired[size_t(i)]));
            if(retain) {
                lanePositions.clear();
                for(size_t i=0;i<desired.size();++i) {
                    lanes[int(i)]->refreshEnvelope(std::get<1>(desired[i]));
                    lanePositions.push_back({std::get<2>(desired[i]),std::get<3>(desired[i])});
                }
                lanesRevision=w.session.revision;
            }
        }
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
    void refreshTheme() {
        canvas.invalidateGrid();
        invalidate();
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
        bool layoutChanged = w.session.extendRecordingLoops();
        if (const auto *song = w.session.song())
            for (auto &item : w.session.recordingItems) {
                item.preview->drain();
                const double duration = std::min(item.passLimit, std::max(1. / item.preview->rate, item.preview->frames.load(std::memory_order_acquire) / item.preview->rate - item.clip.sourceOffset));
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
    void revealEditPosition(bool explicitNavigation = false) {
        if (explicitNavigation) {
            stopGesture();
            if (w.session.transport().playing || w.session.transport().subPlay.playing) pausePlaybackFollow();
        } else if (w.session.transport().playing || w.session.transport().subPlay.playing) return;
        const double cursor = w.session.transport().editPosition * w.pixelsPerSecond;
        const double left = horizontal.getCurrentRangeStart();
        const double leftInset = std::min(14.0, cursor);
        const double rightLimit = std::max(14.0, canvas.getWidth() * (547.0 / 1003.0));
        if (cursor < left + leftInset - 0.5)
            horizontal.setCurrentRangeStart(cursor <= leftInset ? firstOffset : cursor - leftInset, sendNotificationSync);
        else if (cursor > left + rightLimit + 0.5)
            horizontal.setCurrentRangeStart(std::max(firstOffset, cursor - rightLimit), sendNotificationSync);
    }
    bool itemHeadersHidden = false;
    void setItemHeadersHidden(bool hidden) {
        hidden = hidden && ItemHeader::pinsAtScale(w.pixelsPerSecond);
        if(itemHeadersHidden==hidden)return;
        itemHeadersHidden=hidden;canvas.repaint();
    }
    void pausePlaybackFollow(bool temporary = false) {
        followPolicy.pause(w.session.presentationTransport(),temporary?5.0:std::numeric_limits<double>::infinity());
        setItemHeadersHidden(false);
    }
    // Scroll and needles must share one device-clock observation. Sampling
    // again during paint moves the needle ahead of the transform, visibly even
    // at moderate zoom (and by hundreds of pixels at the maximum zoom).
    std::optional<jaras::TransportState> playbackFrame;
    bool followFramePending = false;
    void followPlayback() {
        playbackFrame = w.session.presentationTransport();
        followFramePending = true;
        const auto& state = *playbackFrame;
        if(followPolicy.isPaused(state)){setItemHeadersHidden(false);return;}
        if (!w.appearance.continuousScroll() || !(state.playing || state.subPlay.playing)) { followPolicy.reset(); setItemHeadersHidden(false); return; }
        if (gestureMode != 0 || Component::isMouseButtonDownAnywhere() || Component::getNumCurrentlyModalComponents() != 0) {setItemHeadersHidden(false);return;}
        const double position = state.subPlay.playing ? state.subPlay.position : state.position;
        const auto *song=w.session.song();
        const String source=(song?text(song->id):String{})+(state.subPlay.playing?"-sub":"-main");
        const auto next=followPolicy.destination(position,w.pixelsPerSecond,horizontal.getMaximumRangeLimit(),
            horizontal.getCurrentRangeStart(),canvas.getWidth(),source,0,firstOffset);
        if(next) {
            setItemHeadersHidden(*next>firstOffset && *next<horizontal.getMaximumRangeLimit()-canvas.getWidth());
            horizontal.setCurrentRangeStart(*next,sendNotificationSync);
        } else if(horizontal.getCurrentRangeStart()>=horizontal.getMaximumRangeLimit()-canvas.getWidth() ||
                  std::abs(position*w.pixelsPerSecond-horizontal.getCurrentRangeStart()-canvas.getWidth()/2.)>0.500001)setItemHeadersHidden(false);
    }
    void animate() {
        if(!followFramePending) playbackFrame = w.session.presentationTransport();
        followFramePending = false;
        const auto& state = *playbackFrame;
        playbackFrames.setRunning(isShowing() && (state.playing || state.subPlay.playing));
        const auto range=visualTimeRange();
        if(range!=lastVisualTimeRange){lastVisualTimeRange=range;canvas.repaint();}
        int a = (int)std::floor(xAt(state.position)),
            b = (int)std::floor(xAt(w.session.subCursorPosition(state)));
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
        updateHorizontalRange(dontSendNotification);
    }
    void updateHorizontalRange(NotificationType notification) {
        const auto* song = w.session.song();
        const ID id = song ? song->id : ID{};
        if (scrollEndRevision != w.session.revision || scrollEndSong != id) {
            scrollEndTime = timelineGrid::scrollEnd(song);
            scrollEndRevision = w.session.revision;
            scrollEndSong = id;
        }
        horizontal.setRangeLimits(firstOffset, std::max(firstOffset + canvas.getWidth(),
            scrollEndTime * w.pixelsPerSecond), notification);
        horizontal.setCurrentRange(horizontal.getCurrentRangeStart(), canvas.getWidth(), notification);
    }
    void repaintZoom() {
        if (!ItemHeader::pinsAtScale(w.pixelsPerSecond)) setItemHeadersHidden(false);
        // Horizontal scale never changes track heights or automation row bounds.
        // Avoid rebuilding vertical ranges and walking the track tree per frame.
        for (auto *lane : lanes) if (lane->isVisible()) lane->repaint();
        canvas.repaint(); heads.repaint();
    }
    double zoomPosition() {
        const auto state = w.session.presentationTransport();
        return timelineZoomPosition(state, followPolicy.isPaused(state));
    }
    double minimumZoom() const { return timelineGrid::minimumZoom(canvas.getWidth()); }
    void syncZoomSlider() {
        if (w.zoomMemory && w.pixelsPerSecond > minimumZoom() + .000001) {
            w.zoomMemory.reset();
            w.controls.at("zoomFit")->setToggleState(false, dontSendNotification);
        }
        w.zoom.setValue(w.pixelsPerSecond, dontSendNotification);
    }
    void applyCursorZoom(double scale, std::optional<double> screenAnchor = {}) {
        const double cursor = gestureZoomPosition.value_or(zoomPosition());
        w.pixelsPerSecond = jlimit(minimumZoom(), timelineGrid::maximumZoom, scale);
        syncZoomSlider();
        updateZoomRange();
        const double anchor = screenAnchor.value_or(canvas.getWidth()/2.);
        const double offset = timelineAnchoredZoomOffset(cursor, w.pixelsPerSecond,
            horizontal.getMaximumRangeLimit() - firstOffset, canvas.getWidth(), anchor + firstOffset) + firstOffset;
        horizontal.setCurrentRangeStart(offset, dontSendNotification);
        repaintZoom();
    }
    void applyZoom(double scale, float anchor) {
        auto old = timeAt(anchor);
        w.pixelsPerSecond = jlimit(minimumZoom(), timelineGrid::maximumZoom, scale);
        syncZoomSlider();
        updateZoomRange();
        horizontal.setCurrentRangeStart(old * w.pixelsPerSecond - anchor, dontSendNotification);
        repaintZoom();
    }
    void fit() {
        stopGesture();
        if (auto *s = w.session.song()) {
            w.pixelsPerSecond = jlimit(
                minimumZoom(), timelineGrid::maximumZoom, std::max(1, canvas.getWidth() - 40) / std::max(1., s->duration));
            syncZoomSlider();
            horizontal.setCurrentRangeStart(firstOffset);
            updateRanges();
        }
    }
    void initialView() {
        zoomAt(std::max(1, canvas.getWidth() - 40) / 180.0, 0);
        const auto position = w.session.transport().editPosition;
        horizontal.setCurrentRangeStart(position <= 10. ? firstOffset : (position - 10.) * w.pixelsPerSecond);
    }
    void scroll(double x, double y) {
        if(x!=0 || y!=0)pausePlaybackFollow(true);
        if (x != 0)
            horizontal.setCurrentRangeStart(horizontal.getCurrentRangeStart() + x);
        if (y != 0)
            vertical.setCurrentRangeStart(vertical.getCurrentRangeStart() + y);
    }
    juce::Rectangle<int> regionHeaderBounds(const ID &id) const {
        if (!w.showRegionLanes) return {};
        if (const auto *song = displaySong()) for (const auto &part : song->parts) if (part.id == id) {
            const float left = std::max(0.f, xAt(part.startTime));
            const float right = std::min((float)canvas.getWidth(), xAt(part.endTime));
            return juce::Rectangle<float>(left, (float)regionLaneTop(regionLanes().lane(id)), std::max(1.f, right-left), float(headerLaneHeight)).getSmallestIntegerContainer();
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
        put(v, "scrollEndTime", scrollEndTime);
        put(v, "horizontal", horizontal.getCurrentRangeStart());
        put(v, "horizontalScrollbarVisible", horizontal.isVisible());
        put(v, "waveforms", waveforms.diagnostics());
        put(v,"gridTickBuilds",(int64)canvas.gridTicks.builds);
        put(v,"gridTickHits",(int64)canvas.gridTicks.hits);
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
        put(v, "rulerHeight", rulerHeight);
        put(v, "rulerTop", rulerTop());
        put(v, "regionLaneCount", visibleRegionRows());
        put(v, "showRegionLanes", w.showRegionLanes);
        put(v, "showTempoLane", w.showTempoLane);
        Array<var> regions;
        if (const auto *song=displaySong(); w.showRegionLanes && song) {
          const auto parents=timelineRegionLabels::parents(*song);
          for (size_t index=0;index<song->parts.size();++index) {
            const auto &part=song->parts[index];
            if (part.parentRegionID) continue;
            auto region=object(), bounds=object();
            put(region,"id",text(part.id)); put(region,"lane",regionLanes().lane(part.id));
            put(region,"identifier",timelineRegionLabels::identifier(*song,index,parents));
            put(region,"start",part.startTime); put(region,"end",part.endTime);
            put(bounds,"x",getX()+xAt(part.startTime)); put(bounds,"y",getY()+regionLaneTop(regionLanes().lane(part.id)));
            put(bounds,"width",std::max(1.f,xAt(part.endTime)-xAt(part.startTime))); put(bounds,"height",headerLaneHeight);
            put(region,"bounds",bounds); regions.add(region);
          }
        }
        put(v,"regions",regions);
        Array<var> markerHeads;
        for (const auto &flag:markerFlags) {
            if (!showsMarker(flag.tempo)) continue;
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
                const juce::Rectangle<float> r(xAt(clip.startTime),headerHeight()+w.rowTop((int)row)-w.verticalOffset+geometry.top + timelineItemVerticalInset,std::max(2.f,(float)(clip.duration*w.pixelsPerSecond)-2),geometry.height - 2 * timelineItemVerticalInset);
                if(!r.intersects(canvas.getLocalBounds().toFloat().withTrimmedTop((float)headerHeight()))) continue;
                const ItemHeader header(r,(float)canvas.getWidth(),track,clip,w.itemTitle(clip),itemHeadersHidden,w.pixelsPerSecond,w.clipSelected(clip.id));
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
        if (delta == 0 || !std::isfinite(delta)) return;
        setTrackHeight((int)std::lround(w.trackHeight * std::exp(delta * .6)));
    }
    void setTrackHeight(int height) {
        stopGesture();
        const auto minimum = w.minimumTrackHeight();
        height = jlimit(minimum, 240, height);
        if (w.trackHeightMemory && height > minimum) {
            w.trackHeightMemory.reset();
            w.controls.at("trackHeightFit")->setToggleState(false, dontSendNotification);
        }
        if (w.trackHeight == height) return;
        // Anchor the selected row, or the clipped point of the first visible
        // row. Capture before resized() lets JUCE clamp the old scroll range.
        int anchor = w.rowAt(w.verticalOffset);
        if (const auto* song = w.session.song()) {
            for (int i = 0; i < (int)song->tracks.size(); ++i)
                if (song->tracks[(size_t)i].id == w.selectedTrack && w.trackSelected(w.selectedTrack) && !w.rowHidden(i)) { anchor = i; break; }
            if (anchor < 0) for (int i = (int)song->tracks.size() - 1; i >= 0; --i)
                if (!w.rowHidden(i)) { anchor = i; break; }
        }
        const int oldTop = anchor < 0 ? 0 : w.rowTop(anchor), oldHeight = anchor < 0 ? 0 : w.rowHeight(anchor);
        const double fraction = oldHeight > 0 ? jlimit(0., 1., double(w.verticalOffset - oldTop) / oldHeight) : 0.;
        const double screenY = oldTop + fraction * oldHeight - w.verticalOffset;
        w.trackHeight = height;
        w.trackHeightSlider.setValue(height, dontSendNotification);
        w.resized();
        updateRanges();
        if (anchor >= 0 && oldHeight > 0)
            w.mixerDivider.scrollTo(roundToInt(w.rowTop(anchor) + fraction * w.rowHeight(anchor) - screenY));
    }
    void mouseWheelMove(const MouseEvent &e, const MouseWheelDetails &d) override {
        ++w.wheelCount;
        pausePlaybackFollow(true);
        if (e.mods.isCtrlDown()) {
            adjustTrackHeight(d.deltaY);
            return;
        }
        if (e.mods.isAltDown()) {
            stopGesture();
            w.tracksViewport.scrollByWheel(-d.deltaY * 300., d.isSmooth || d.isInertial);
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
            ? jlimit(firstOffset, std::max(firstOffset, horizontal.getMaximumRangeLimit() - horizontal.getCurrentRangeSize()), gestureTarget + delta)
            : jlimit(std::log(minimumZoom()), std::log(timelineGrid::maximumZoom), gestureTarget + delta);
        gestureOrigin = pan ? horizontal.getCurrentRangeStart() : std::log(w.pixelsPerSecond);
        if(!pan) gestureZoomScreenX=*gestureZoomPosition*w.pixelsPerSecond-horizontal.getCurrentRangeStart();
        lastGestureInput = now;
        if (!isTimerRunning()) { startTimerHz(60); timerCallback(); }
    }

  private:
    Workspace &w;
    uint64 scrollEndRevision = ~uint64(0);
    ID scrollEndSong;
    double scrollEndTime = 0;
    static constexpr double firstOffset = -6.;
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
        const double duration = gestureMode == 1 ? 420. : 130.;
        const double progress = jlimit(0., 1., (now - lastGestureInput) / duration);
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
    MixerScrollLook scrollLook;
    class SetlistGridScrollBar final : public ScrollBar {
      public:
        explicit SetlistGridScrollBar(Workspace &workspace) : ScrollBar(true), owner(workspace) {}
        void mouseDown(const MouseEvent &event) override {
            pending.reset();
            resizing = false;
            if (owner.setlistVisible && owner.setlistPlacement == SetlistPlacement::right && event.mods.isLeftButtonDown())
                pending.emplace(event);
            else
                ScrollBar::mouseDown(event);
        }
        void mouseDrag(const MouseEvent &event) override {
            if (pending) {
                const auto delta = event.getScreenPosition() - pending->getScreenPosition();
                if (std::max(std::abs(delta.x), std::abs(delta.y)) < 3) return;
                resizing = std::abs(delta.x) > std::abs(delta.y);
                if (resizing) {
                    origin = pending->getScreenPosition().x;
                    owner.setlistDivider.started();
                } else {
                    ScrollBar::mouseDown(*pending);
                }
                pending.reset();
            }
            if (resizing) owner.setlistDivider.moved(event.getScreenPosition().x - origin);
            else ScrollBar::mouseDrag(event);
        }
        void mouseUp(const MouseEvent &event) override {
            if (pending) { ScrollBar::mouseDown(*pending); pending.reset(); }
            if (resizing) {
                owner.setlistDivider.moved(event.getScreenPosition().x - origin);
                owner.setlistDivider.ended();
                resizing = false;
            } else ScrollBar::mouseUp(event);
        }
      private:
        Workspace &owner;
        std::optional<MouseEvent> pending;
        int origin = 0;
        bool resizing = false;
    };
    ScrollBar horizontal;
    SetlistGridScrollBar vertical;
    TimelinePlaybackFollowPolicy followPolicy;
    std::optional<ID> selectedHeaderRegion;
    bool regionTimebaseSuspended = false;
    std::set<ID> selectedHeaderRegions;
    ID headerSelectionAnchor;
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
    class Canvas final : public Component, public DragAndDropTarget, private Timer {
      public:
        int headerHeight() const { return t.headerHeight(); }
        explicit Canvas(Timeline &timeline) : t(timeline) { setOpaque(true); setComponentID("timelineCanvas"); }
        bool isInterestedInDragSource(const SourceDetails &source) override {
            return str(source.description, "type") == "catlive-library-sampler" &&
                externalMedia::supported(File(str(source.description, "file")));
        }
        void itemDragEnter(const SourceDetails &source) override {
            const auto point = t.w.getLocalPoint(this, source.localPosition);
            t.w.fileDragEnter({str(source.description, "file")}, point.x, point.y);
        }
        void itemDragMove(const SourceDetails &source) override {
            const auto point = t.w.getLocalPoint(this, source.localPosition);
            t.w.fileDragMove({}, point.x, point.y);
        }
        void itemDragExit(const SourceDetails &) override { t.w.fileDragExit({}); }
        void itemDropped(const SourceDetails &source) override {
            if (!isInterestedInDragSource(source)) return;
            const auto point = t.w.getLocalPoint(this, source.localPosition);
            t.w.filesDropped({str(source.description, "file")}, point.x, point.y);
        }
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
        TimelineGridCache<timelineGrid::Tick> gridTicks;
        TimelineGridCache<timelineGrid::Section> rulerSections;
        struct RegionDrawing { String identifier, name; float identifierWidth=0; };
        TimelineRegionDrawingCache<RegionDrawing> regionDrawings;
        void invalidateGrid() { gridTicks.invalidate(); rulerSections.invalidate(); regionDrawings.invalidate(); }
        void prepareRegionDrawings(const jaras::Song& song) {
            regionDrawings.prepare(t.w.session.project().id,song.id,t.w.session.revision,localization::english,[&] {
                using Entry=TimelineRegionDrawingCache<RegionDrawing>::Entry;
                std::vector<Entry> entries;entries.reserve(song.parts.size());
                const auto parents=timelineRegionLabels::parents(song);
                const auto font=theme::semiboldFont(9);
                for(size_t i=0;i<song.parts.size();++i) {
                    const auto& part=song.parts[i];if(part.parentRegionID)continue;
                    auto label=timelineRegionLabels::identifier(song,i,parents);
                    const auto width=std::ceil(GlyphArrangement::getStringWidth(font,label));
                    entries.push_back({part.startTime,part.endTime,i,{label,timelineRegionLabels::displayName(part),width}});
                }
                return entries;
            });
        }
        struct OverviewWaveform {
            Image image;
            std::weak_ptr<const WaveformCache::Data> source;
            uint64 used=0;
            size_t bytes=0;
        };
        std::map<WaveformRasterIdentity,OverviewWaveform> overviewWaveforms;
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
            // Detailed/very long items retain the clipped live renderer.
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
                if(WaveformDetailPeaks::needsDetail(data->sampleRate*std::max(.001,span.rate)/(t.w.pixelsPerSecond*physical)))return false;
            if(overviewRevision!=t.w.session.revision || overviewZoom!=t.w.pixelsPerSecond || overviewScale!=physical) {
                overviewWaveforms.clear();overviewBytes=0;overviewRevision=t.w.session.revision;
                overviewZoom=t.w.pixelsPerSecond;overviewScale=physical;
            }
            const auto key=WaveformRasterIdentity::make(*data,clip,timing,t.w.pixelsPerSecond,physical,
                rect.getWidth(),rect.getHeight(),0,rect.getWidth(),ink);
            if(!key)return false;
            auto found=overviewWaveforms.find(*key);
            // Do not pin the peak cache's mapped files just to retain pixels.
            // A reloaded source also cannot alias an expired object's address.
            if(found!=overviewWaveforms.end() && found->second.source.lock()!=data) {
                overviewBytes-=found->second.bytes;overviewWaveforms.erase(found);found=overviewWaveforms.end();
            }
            if(found==overviewWaveforms.end()) {
                while((overviewBytes+bytes>capacity || overviewWaveforms.size()>=4096) && !overviewWaveforms.empty()) {
                    const auto oldest=std::min_element(overviewWaveforms.begin(),overviewWaveforms.end(),
                        [](const auto &a,const auto &b){return a.second.used<b.second.used;});
                    overviewBytes-=oldest->second.bytes;overviewWaveforms.erase(oldest);
                }
                ++overviewBuilds;
                OverviewWaveform entry;
                entry.image=Image(Image::ARGB,width,height,true);entry.source=data;entry.bytes=bytes;
                Graphics thumbnail(entry.image);thumbnail.addTransform(AffineTransform::scale(physical));
                const auto local=rect.withPosition(1.f/physical,1.f/physical);
                WaveformRenderer::draw(thumbnail,t.waveforms,data,clip,local,
                    {0,0,width/physical,height/physical},t.w.pixelsPerSecond,ink,false,{},&song,&waveformTiming(clip,song));
                found=overviewWaveforms.emplace(*key,std::move(entry)).first;overviewBytes+=bytes;
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
            const bool groupMove = groupDragPreview();
            if(groupMove) {
                const int rowDelta=resizeEdge ? 0 : previewRow-sourceRow;
                candidates.reserve(dragSelectionPreviews.size());
                for(const auto &entry:dragSelectionPreviews)
                    candidates.push_back({entry.row+rowDelta,&entry.preview});
            } else if(resizedClipPreview) candidates.push_back({sourceRow,&*resizedClipPreview});
            else if(movingClipPreview) candidates.push_back({previewRow,&*movingClipPreview});
            if(sharedOriginal) {
                candidates.clear();
                for(const auto &clip:sharedChainPreview)candidates.push_back({sourceRow,&clip});
            }
            if(candidates.empty())return;

            const auto isExcluded=[&](const ID &id) {
                return groupMove ? t.w.selectedClips.count(id)>0 : id==dragClip || (sharedOriginal && std::any_of(sharedChainPreview.begin(),sharedChainPreview.end(),[&](const auto &clip){return clip.id==id;}));
            };
            std::map<int,std::vector<std::pair<double,double>>> ranges;
            for(const auto &[row,clip]:candidates)
                if(clip && row>=0 && row<(int)song.tracks.size())
                    ranges[row].push_back({clip->startTime,clip->startTime+clip->duration});
            if(groupMove) {
                for(const auto &entry:dragSelectionPreviews)
                    ranges[entry.row].push_back({entry.original.startTime,entry.original.startTime+entry.original.duration});
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
            const auto gridBackground = t.w.appearance.colour(theme::timelineBackgroundKey, theme::timelineBackgroundRGB);
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
            const auto& projectID = t.w.session.project().id;
            const auto revision = t.w.session.revision;
            const auto scale = t.w.pixelsPerSecond;
            const double rulerEnd = std::max(1., t.scrollEndTime);
            const auto &grid = gridTicks.get(projectID, song->id, revision, viewStart, viewEnd, scale, [&] {
                const auto& timing = rulerSections.get(projectID, song->id, revision, 0, rulerEnd, 1, [&] {
                    return timelineGrid::rulerSections(*song, rulerEnd);
                });
                const auto divisions = song->timeSettings ? song->timeSettings->divisions : 4;
                // Include a preceding label and the antialiased edge of a line.
                const auto labelGutter = timelineGrid::MeasureLabels(timing).spacing;
                return timelineGrid::ticks(timing, divisions, std::max(0., viewStart - labelGutter / scale),
                                           viewEnd + 1 / scale, scale, true);
            });
            const float pixel = 1.f / std::max(1.f, g.getInternalContext().getPhysicalPixelScaleFactor());
            const auto lineX = [&](double time) { return t.xAt(time); };
            const bool showGrid = t.w.appearance.gridlines() &&
                (!song->timeSettings || song->timeSettings->divisions != 0);
            const auto gridLineColour = t.w.appearance.colour(theme::timelineVerticalGridKey, theme::timelinePrimaryGridRGB);
            const auto rowLineColour = t.w.appearance.colour(theme::timelineHorizontalGridKey, theme::timelineHorizontalGridRGB);
            const auto gridColumnX = [&](double time) { return std::floor(lineX(time) / pixel) * pixel; };
            const auto drawGrid = [&](float top, float bottom) {
                if (!showGrid || bottom <= top) return;
                Graphics::ScopedSaveState gridState(g);
                // A fractional fill at 100% DPI can split the ink between
                // two columns. Use one device pixel at consistent opacity.
                g.setColour(gridLineColour.withMultipliedAlpha(0.5f));
                for (const auto &tick : grid) if (tick.drawsInGrid) {
                    const float lineTop = std::max(top, float(tick.label.isEmpty() ? t.cursorLaneTop() : t.rulerTop()));
                    if (bottom > lineTop) g.fillRect(gridColumnX(tick.time), lineTop, pixel, bottom - lineTop);
                }
            };
            const auto drawTrackSeparator = [&](int bottom) {
                g.setColour(rowLineColour);
                g.fillRect(0.f, (float)bottom - pixel, (float)getWidth(), pixel);
            };
            // Paint the ruler's lane borders under the continuous columns.
            // At 1x scale drawing the borders last cuts a pixel out of a
            // thin column at both the number lane and the grid boundary.
            g.setColour(theme::timelineHeaderLine());
            g.fillRect(0.f, 0.f, float(getWidth()), 1.f);
            for (int y = headerLaneHeight; y <= headerHeight(); y += headerLaneHeight)
                g.fillRect(0.f, float(y - 1), float(getWidth()), 1.f);
            drawGrid(float(t.rulerTop()), float(headerHeight()));
            for (const auto &tick : grid) {
                const float x = lineX(tick.time);
                if (!showGrid || !tick.drawsInGrid) {
                    g.setColour(gridLineColour.withMultipliedAlpha(0.5f));
                    g.fillRect(gridColumnX(tick.time), (float)t.cursorLaneTop(), pixel, float(headerHeight()-t.cursorLaneTop()));
                }
                if (tick.label.isNotEmpty()) {
                    g.setColour(Colours::white);
                    g.setFont(theme::semiboldFont(13.f).withPointHeight(13.f));
                    g.drawText(tick.label, juce::Rectangle<float>(x + 3 + .5f * pixel, float(t.rulerTop()), 124, float(headerLaneHeight)),
                               Justification::centredLeft);
                }
            }
            stage();
            t.refreshMarkers(*song);
            for(const auto &m:t.markerFlags) {
                if (!t.showsMarker(m.tempo)) continue;
                const float x=t.xAt(m.position);
                if(x>getWidth()) break;
                const float width=timelineRegionLabels::markerHeadWidth(m.position,m.next,m.regionEnd,m.width,t.w.pixelsPerSecond);
                if(width<18 || x+width<0) continue;
                const juce::Rectangle<float> flag(x,(float)t.markerTop(m.tempo)+1,width,float(headerLaneHeight - 2));
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
            if (t.w.showRegionLanes) prepareRegionDrawings(*song);
            auto visibleRegions = regionDrawings.visible(viewStart-6/t.w.pixelsPerSecond,viewEnd+6/t.w.pixelsPerSecond);
            if (!t.w.showRegionLanes) visibleRegions.clear();
            for (const auto* drawing:visibleRegions) {
                const auto &p=song->parts[drawing->sourceIndex];
                float a = t.xAt(p.startTime), b = t.xAt(p.endTime);
                if (b < 0 || a > getWidth())
                    continue;
                g.setColour(Colour(0xff000000 | p.color.value_or(0x665566)));
                const int laneTop = t.regionLaneTop(t.regionLanes().lane(p.id));
                const juce::Rectangle<float> band(a, float(laneTop), std::max(1.f, b - a), float(headerLaneHeight - 1));
                if (band.getWidth() >= 5.f) g.fillRoundedRectangle(band, 2.5f);
                else g.fillRect(band);
                g.setColour(Colours::black);
                const auto& identifier=drawing->data.identifier;
                const auto identifierFont=theme::semiboldFont(9);
                const auto identifierWidth=drawing->data.identifierWidth;
                if (b-a>=identifierWidth+8) {
                    Graphics::ScopedSaveState scope(g);
                    g.reduceClipRegion(juce::Rectangle<float>(a,(float)laneTop,std::max(1.f,b-a),float(headerLaneHeight)).getSmallestIntegerContainer());
                    g.setFont(identifierFont);
                    g.drawText(identifier,juce::Rectangle<float>(b-4-identifierWidth,(float)laneTop+2,identifierWidth,12),
                               Justification::centredRight,false);
                    const auto nameWidth=b-a-identifierWidth-16;
                    if (nameWidth>=10) {
                        g.setFont(theme::semiboldFont(9));
                        g.drawText(drawing->data.name,
                                   juce::Rectangle<float>(a+4,(float)laneTop+2,nameWidth,12),Justification::centredLeft,true);
                    }
                }
                if(t.selectedHeaderRegions.count(p.id) && t.selectedHeaderProject==t.w.session.project().id) {
                    g.setColour(Colours::white);
                    g.drawRect(juce::Rectangle<float>(a,(float)laneTop,std::max(1.f,b-a),float(headerLaneHeight)).reduced(.75f),1.5f);
                }
            }
            stage();
            const bool invertWaveformColors = t.w.appearance.invertWaveformColors();
            const auto paintRow = [&](size_t row, int y, int height) {
                const auto &track = song->tracks[row];
                const bool trackMuted=trackTree::silenced(*song,track);
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
                const bool groupMove = groupDragPreview();
                std::vector<const jaras::AudioClip*> movingClips;
                const double visibleStart=viewStart-9/t.w.pixelsPerSecond, visibleEnd=viewEnd+9/t.w.pixelsPerSecond;
                const auto visibleIndices=visibleClipIndices((int)row,track,visibleStart,visibleEnd);
                bool resizedPreviewIncluded=false, sharedPreviewIncluded=false;
                for(const auto clipIndex:visibleIndices) {
                    const auto &clip=track.clips[clipIndex];
                    if(sharedOriginal && std::any_of(sharedChainPreview.begin(),sharedChainPreview.end(),[&](const auto &changed){return changed.id==clip.id;}))continue;
                    if(groupMove && t.w.selectedClips.count(clip.id))continue;
                    if(!groupMove && movingClipPreview && clip.id==movingClipPreview->id)continue;
                    if(resizedClipPreview && clip.id==resizedClipPreview->id) {
                        movingClips.push_back(&*resizedClipPreview);resizedPreviewIncluded=true;
                    } else if(sharedPreview && clip.id==sharedPreview->id) {movingClips.push_back(&*sharedPreview);sharedPreviewIncluded=true;}
                    else movingClips.push_back(&clip);
                }
                if(sharedOriginal && sourceRow==(int)row)for(const auto &clip:sharedChainPreview)
                    if(clip.startTime<=visibleEnd&&clip.startTime+clip.duration>=visibleStart)movingClips.push_back(&clip);
                const bool movingHere = !groupMove && movingClipPreview && previewRow == (int)row;
                const bool resizedHere = !sharedOriginal && !groupMove && resizedClipPreview && sourceRow == (int)row && !resizedPreviewIncluded &&
                    resizedClipPreview->startTime <= visibleEnd && resizedClipPreview->startTime + resizedClipPreview->duration >= visibleStart;
                if(groupMove) {
                    const int rowDelta=resizeEdge ? 0 : previewRow-sourceRow;
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
                    const auto geometry = previewItemGeometry(row, clip);
                    const float itemHeight = geometry.height;
                    const float itemY = y + geometry.top;
                    auto colour = theme::track(track);
                    auto rect = juce::Rectangle<float>(
                        left, itemY + timelineItemVerticalInset, std::max(2.f, right - left - 2), itemHeight - 2 * timelineItemVerticalInset);
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
                    const bool inverted = invertWaveformColors && !muted && !clip.text && !clipEditing::projection(clip) &&
                        (!clip.midi || clip.frozenMIDI.value_or(false)) &&
                        (track.role.id=="generatedClick" || jaras::fixedTrackName(track.role).empty());
                    const auto waveformInk = inverted ? colour.withAlpha(muted ? .55f : 1.f) : Colour(0xff202020);
                    if (muted) colour = Colour::greyLevel(selected ? .7f : .55f);
                    if (inverted) colour = Colour(0xff202020);
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
                    const bool lyric = jaras::isTeleprompterRole(track.role) && !clip.audioFile && !clip.midi;
                    const bool mediaHeader = selected && (clip.midi || clip.audioFile ||
                        (jaras::fixedTrackName(track.role).empty() && !clip.text && !clip.timecode &&
                         (track.audioFile || !clip.waveform.empty() || !clip.waveformChannels.empty())));
                    if (mediaHeader) {
                        g.setColour(Colour(0xffd8d8d8));
                        g.fillRect(rect.withHeight(std::min(17.f, rect.getHeight())));
                    }
                    const ItemHeader header(rect,(float)getWidth(),track,clip,t.w.itemTitle(clip),t.itemHeadersHidden,t.w.pixelsPerSecond,t.w.clipSelected(clip.id));
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
                        g.setColour(waveformInk);g.fillPath(pulses);g.restoreState();
                    } else if (!clip.text && (!clip.midi || clip.frozenMIDI.value_or(false))) {
                        const auto &source = clip.audioFile ? clip.audioFile : track.audioFile;
                        const auto data = source ? t.waveforms.request(t.waveformFile(source->path)) : nullptr;
                        if (data) {
                            const auto ink=waveformInk;
                            // Panning reuses identical copies; zoom redraws directly at its exact scale.
                            const bool overview=t.gestureMode!=1 && !controlApplies && !movingClipPreview && !resizedClipPreview && !t.regionPreview;
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
                            g.setColour(waveformInk);
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
                    if(!simpleOverview) header.drawFades(g,clip);
                    g.restoreState();
                    // Text goes directly onto the opaque canvas, outside the
                    // alpha geometry layer used to clip waveform/fade corners.
                    // Rectangular clipping keeps the native ClearType renderer.
                    const auto name = header.nameRect();
                    if (!t.itemHeadersHidden && (!header.muteRect.isEmpty() || name.getWidth() >= 10)) {
                        Graphics::ScopedSaveState textClip(g);
                        g.reduceClipRegion(rect.getSmallestIntegerContainer());
                        const auto titleInk = mediaHeader ? Colours::black : theme::surfaceText(colour);
                        header.draw(g,clip,gainOverride,controlApplies && controlKind==ItemHeader::pan ? controlClip->pan : std::nullopt);
                        if(!lyric && name.getWidth() >= 10) {
                            g.setFont(theme::semiboldFont(9));g.setColour(titleInk);
                            g.drawText(t.w.itemTitle(clip),name,Justification::centredLeft,true);
                        }
                    }
                    if ((jaras::isTeleprompterRole(track.role) || track.role.id == "chords") &&
                        !clipEditing::projection(clip) && clip.text && !clip.text->empty() && rect.getWidth() > 16 && rect.getHeight() > 26) {
                        Graphics::ScopedSaveState textClip(g);
                        const auto area = rect.withTrimmedTop(lyric ? 2.f : 17.f).withTrimmedBottom(3.f).reduced(5.f, 0.f);
                        g.reduceClipRegion(area.getSmallestIntegerContainer());
                        ItemTextColors::draw(g, text(*clip.text), area, theme::semiboldFont(12), Colours::black, Justification::topLeft);
                    }
                    if(selected) {
                        g.setColour(Colours::black);g.strokePath(outline,PathStrokeType(.8f));
                        g.setColour(Colour(0xff80ff9c));g.strokePath(outline,PathStrokeType(.7f));
                    }
                    if (cutItems.count(clip.id)) {
                        g.setColour(gridBackground.withAlpha(.55f));
                        g.fillRoundedRectangle(rect, 3.f);
                    }
                }
                for (const auto &item : t.w.session.recordingItems) if (item.track == track.id) {
                    const auto &preview = *item.preview;
                    const double duration = item.clip.duration;
                    const double sourceOrigin = item.clip.startTime - item.clip.sourceOffset;
                    const float left = t.xAt(item.clip.startTime);
                    const float right = t.xAt(item.clip.startTime + duration);
                    if (right < 0 || left > getWidth()) continue;
                    const auto geometry = t.w.itemGeometry(row,item.clip.id);
                    const float height = geometry.height;
                    const float top = y + geometry.top;
                    auto rect = juce::Rectangle<float>(left, top + 3.f, std::max(2.f, right-left-2), height-6.f);
                    g.saveState();
                    Path outline; outline.addRoundedRectangle(rect, 3.f);
                    g.reduceClipRegion(outline);
                    const bool complete = item.clip.duration >= item.passLimit;
                    g.setColour(complete ? theme::track(track) : Colour(0xffd53939)); g.fillRect(rect);
                    // Compact recording lanes still need room for their waveform.
                    const float titleHeight = std::min(17.f, rect.getHeight() * .35f);
                    g.setColour(Colours::black.withAlpha(.18f)); g.fillRect(rect.withHeight(titleHeight));
                    const auto body = rect.withTrimmedTop(titleHeight + 1).withTrimmedBottom(1);
                    if (body.getHeight() > 0 && preview.midiLog) {
                        const auto &midi = preview.midi;
                        const int low = std::max(0, midi.low - 2), high = std::min(127, midi.high + 2);
                        const float rowHeight = body.getHeight() / std::max(12, high-low+1);
                        g.setColour(Colours::white.withAlpha(.85f));
                        for (const auto &note : midi.notes) {
                            const auto x = t.xAt(sourceOrigin + note.start / preview.rate);
                            const auto end = note.end < 0 ? right : t.xAt(sourceOrigin + note.end / preview.rate);
                            if (end >= 0 && x <= getWidth()) g.fillRect(x, body.getBottom()-(note.pitch-low+1)*rowHeight,
                                std::max(1.f,end-x), std::max(1.f,rowHeight*.75f));
                        }
                    } else if (body.getHeight() > 0) {
                        g.reduceClipRegion(body.getSmallestIntegerContainer());
                        const float laneHeight = body.getHeight()/preview.channels;
                        const double firstFrame = std::max(0., (t.timeAt(0)-sourceOrigin)*preview.rate);
                        auto begin = std::lower_bound(preview.history.begin(), preview.history.end(), firstFrame,
                            [](const RecordingPreview::Peak &peak, double frame) { return peak.end < frame; });
                        g.setColour(complete ? Colours::black : Colours::white.withAlpha(.9f));
                        for (int channel = 0; channel < preview.channels; ++channel) {
                            Path peaks;
                            int column = -1; float low = 0, high = 0, endColumn = 0;
                            const float middle = body.getY()+laneHeight*(channel+.5f), amplitude = WaveformRenderer::fullScale(laneHeight);
                            auto emit = [&] {
                                if (column >= 0) peaks.addRectangle((float)column, middle-high*amplitude,
                                    std::max(1.f, endColumn-column), std::max(1.f, (high-low)*amplitude));
                            };
                            for (auto peak = begin; peak != preview.history.end(); ++peak) {
                                const float x = t.xAt(sourceOrigin + peak->start/preview.rate);
                                if (x > getWidth()) break;
                                const int next = std::max(0, (int)std::floor(x));
                                if (next != column) { emit(); column=next; low=high=0; }
                                endColumn=std::min((float)getWidth(),t.xAt(sourceOrigin + peak->end/preview.rate));
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
                if (track.role.id == "chords") for (const auto &marker : track.chordMarkers) {
                    const auto head = chordHead(*song, marker, float(y + 4));
                    if (!head || head->getRight() < 0 || head->getX() > getWidth()) continue;
                    g.setColour(Colour(0xff529eff));
                    g.fillRect(head->getX(), head->getY(), 1.f, float(y + height - 4) - head->getY());
                    if (head->getWidth() < 18) continue;
                    g.fillRoundedRectangle(*head, 4);
                    g.setColour(Colours::black); g.setFont(theme::semiboldFont(10));
                    g.drawText(text(marker.name), head->reduced(5, 0), Justification::centredLeft);
                }
            };
            {
                Graphics::ScopedSaveState normal(g);
                g.reduceClipRegion(0, rowsTop(), getWidth(), std::max(0, getHeight() - rowsTop()));
                const auto dirty = g.getClipBounds();
                const int first = t.w.rowAt(std::max(0, t.w.verticalOffset + dirty.getY() - rowsTop() - 3));
                const auto visitVisibleRows = [&](auto visit) {
                    for (size_t row = first < 0 ? song->tracks.size() : size_t(first); row < song->tracks.size(); ++row) {
                        const int y = rowsTop() + t.w.rowTop(int(row)) - t.w.verticalOffset;
                        if (y > std::min(getHeight(), dirty.getBottom()) + 3) break;
                        const int rowHeight = t.w.rowHeight(int(row));
                        if (rowHeight > 0) visit(row, y, rowHeight);
                    }
                };
                const int step = gridBackground.getPerceivedBrightness() > .8f ? -7 : 7;
                const auto channel = [step](uint8 value) { return (uint8)jlimit(0, 255, (int)value + step); };
                const auto selectedBackground = Colour(channel(gridBackground.getRed()), channel(gridBackground.getGreen()),
                                                       channel(gridBackground.getBlue()));
                visitVisibleRows([&](size_t row, int y, int rowHeight) {
                    if (t.w.trackSelected(song->tracks[row].id)) {
                        g.setColour(selectedBackground);
                        g.fillRect(0, y, getWidth(), t.w.rowBodyHeight(int(row)));
                    }
                    drawTrackSeparator(y + rowHeight);
                });
                // Continue the columns across track separators, underneath the items.
                drawGrid(float(rowsTop()), float(getHeight()));
                visitVisibleRows([&](size_t row, int y, int) {
                    const int height = t.w.rowBodyHeight(int(row));
                    if (y + height >= rowsTop() && g.clipRegionIntersects({0, y - 3, getWidth(), height + 6}))
                        paintRow(row, y, height);
                });
            }
            stage();
            for (const auto* drawing:visibleRegions) {
                const auto &region=song->parts[drawing->sourceIndex];
                const auto colour = Colour(0xff000000 | region.color.value_or(0x705264));
                const float top = (float)t.regionLaneTop(t.regionLanes().lane(region.id)+1);
                g.setColour(colour);
                for (const auto time : {region.startTime, region.endTime}) {
                    const float x = gridColumnX(time);
                    if (x >= 0 && x < getWidth()) g.fillRect(x, top, pixel, getHeight()-top);
                }
            }
            if (song->markers) for (auto marker : *song->markers) {
                if (!t.showsMarker(marker.tempoBPM.has_value())) continue;
                if(t.markerPreview && t.markerPreview->first==marker.id) marker.position=t.markerPreview->second;
                const float x = gridColumnX(marker.position), top = (float)t.markerTop(marker.tempoBPM.has_value()) + headerLaneHeight;
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
            if (!t.itemHeadersHidden && itemValueTooltip.isNotEmpty()) {
                const auto bounds=valueTooltipBounds();
                drawValueTooltip(g,bounds,itemValueTooltip);
            }
            const auto &gripID=regionEdge && !dragRegion.empty()?dragRegion:hoverRegion;
            const int gripSide=regionEdge && !dragRegion.empty()?regionEdge:hoverRegionEdge;
            if(gripSide && !timelineGrid::itemsLocked(t.w.session.project()))
                if(const auto *song=t.displaySong())for(const auto &part:song->parts)
                    if(part.id==gripID && !part.parentRegionID && !regionEditing::hasChildren(*song,part.id)) {
                        const float left=t.xAt(part.startTime),right=t.xAt(part.endTime);
                        g.setColour(Colour(0xff54ff94));
                        g.fillRoundedRectangle((gripSide<0?left:right)-2,
                            (float)t.regionLaneTop(t.regionLanes().lane(part.id))+3,4,10,2);
                    }
            if (!dragClip.empty() && !timelineGrid::itemsLocked(t.w.session.project())) {
                const double from=dragPreview?previewStart:originalStart;
                const double to=dragPreview?previewEnd:originalStart+clipLength;
                g.setColour(Colours::yellow);
                g.drawVerticalLine((int)std::round(t.xAt(from)),(float)headerHeight(),(float)getHeight());
                g.drawVerticalLine((int)std::round(t.xAt(to)),(float)headerHeight(),(float)getHeight());
            }
            if (const auto range=t.visualTimeRange()) {
                const float left=t.xAt(range->first),right=t.xAt(range->second),top=float(t.rulerTop() + headerLaneHeight),bottom=(float)getHeight();
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
                g.drawVerticalLine((int)t.xAt(previewStart),(float)t.rulerTop(),(float)getHeight());
            }
        }

        void mouseMove(const MouseEvent &e) override {
            String tooltip;
            MouseCursor cursor(MouseCursor::NormalCursor);
            if(t.onRuler(e.position.y)) cursor=MouseCursor::PointingHandCursor;
            if(t.onRuler(e.position.y) && timeRangeEdge(e.position.x)) cursor=MouseCursor::LeftRightResizeCursor;
            const auto hit=regionHit(e.position,true);
            const ID nextHover=hit.first && hit.second?hit.first->id:ID{};
            if(nextHover!=hoverRegion || hit.second!=hoverRegionEdge) {
                hoverRegion=nextHover;hoverRegionEdge=hit.second;repaint(0, 0, getWidth(), t.regionRowsBottom());
            }
            if(hit.second)cursor=regionResizeCursor();
            if (const auto *song=t.w.session.song()) {
                const int row = rowAtPoint(e.y);
                if (e.y>=headerHeight() && row>=0 && row<(int)song->tracks.size()) {
                    const auto &track=song->tracks[(size_t)row];
                    for (const auto &clip:track.clips) if (itemRect(row,clip).contains(e.position)) {
                        const ItemHeader header(itemRect(row,clip),(float)getWidth(),track,clip,t.w.itemTitle(clip),t.itemHeadersHidden,t.w.pixelsPerSecond,t.w.clipSelected(clip.id));
                        if (e.y >= rowsTop() && !timelineGrid::itemsLocked(t.w.session.project()) && header.hit(e.position,clip)==ItemHeader::none && header.resizeSide(e.position)) cursor=MouseCursor::LeftRightResizeCursor;
                        const auto hit = header.hit(e.position,clip);
                        if(hit==ItemHeader::gain) tooltip="Volume: " + ItemHeader::gainText(clip.gain.value_or(1));
                        else if(hit==ItemHeader::pan) tooltip="Pan: " + ItemHeader::panText(clip.pan.value_or(0));
                        if (e.y >= rowsTop() && (hit == ItemHeader::fadeIn || hit == ItemHeader::fadeOut)) cursor=ItemHeader::fadeCursor(hit==ItemHeader::fadeIn);
                        break;
                    }
                }
            }
            if(e.y >= rowsTop() && sharedBoundaryAt(e.position))cursor=sharedBoundaryCursor();
            setItemValueTooltip(tooltip,e.position);
            setMouseCursor(cursor);
        }
        void mouseExit(const MouseEvent &) override {
            if(!controlClip)setItemValueTooltip({},controlPointer);
            hoverRegion.clear();hoverRegionEdge=0;repaint(0, 0, getWidth(), t.regionRowsBottom());
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
            regionDeleteGesture.reset();
            dragOriginalClip.reset();
            dragOriginalValid=false;
            previewPlacements.clear();
            rulerPan=false; rulerPanDragged=false;
            mainDrag=false; dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); sharedOriginal.reset(); sharedPreview.reset();
            resizeEdge = 0; clipMoveBlocked = false; sharedOriginal.reset(); sharedPreview.reset(); sharedSources = {};
            controlClip.reset(); controlKind=ItemHeader::none; controlOriginals.clear();
            t.w.grabKeyboardFocus();
            const bool editHeadHit = e.y >= t.rulerTop() + headerLaneHeight && e.y < headerHeight() &&
                std::abs(e.position.x - t.xAt(t.w.session.transport().editPosition)) <= 14.f;
            if(e.y<headerHeight() && e.mods.isLeftButtonDown())t.pausePlaybackFollow();
            if (editHeadHit && !t.w.timelineEditMode &&
                e.mods.isLeftButtonDown() && !e.mods.isAltDown()) {
                mainDrag = true;
                t.w.perform([&] { t.w.session.command(jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods)); });
                return;
            }
            if (e.y < headerHeight() && !t.inRegionRows(e.position.y)) {
                const bool onRuler = t.onRuler(e.position.y);
                if (onRuler && (e.mods.isPopupMenu() || timeRangeEdge(e.position.x))) {
                    timeRangeGesture=true;timeRangeDragged=false;
                    timeRangeResize=timeRangeEdge(e.position.x);
                    timeRangeBefore=t.visualTimeRange();
                    return;
                }
                if (const auto *song = t.w.session.song(); !onRuler && song) {
                    t.refreshMarkers(*song);
                    for (const auto &flag : t.markerFlags) {
                        if (!t.showsMarker(flag.tempo)) continue;
                        const float width = timelineRegionLabels::markerHeadWidth(flag.position,flag.next,flag.regionEnd,flag.width,t.w.pixelsPerSecond);
                        if (!juce::Rectangle<float>(t.xAt(flag.position),(float)t.markerTop(flag.tempo)+1,std::max(8.f,width),float(headerLaneHeight - 2)).contains(e.position)) continue;
                        if (e.mods.isPopupMenu()) { ++t.w.contextCount; t.w.showMarkerMenu(flag.id, e.getScreenPosition()); }
                        else if (e.mods.isAltDown()) t.w.perform([&] {
                            t.w.session.editTimeline([&](auto &p) {auto edit=t.w.session.core;edit.deleteManualMarker(flag.id);p=edit.project();}, flag.tempo);
                        });
                        else { dragMarker=flag.id; originalStart=flag.position; }
                        return;
                    }
                }
                if (!e.mods.isLeftButtonDown() || e.mods.isPopupMenu()) return;
                if (onRuler) {
                    rulerPan=true; rulerPanOffset=t.horizontal.getCurrentRangeStart(); return;
                }
                mainDrag = true;
                t.w.perform([&] { t.w.session.command(jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods)); });
                return;
            }
            if (t.inRegionRows(e.position.y)) {
                const auto hit=regionHit(e.position,!e.mods.isPopupMenu() && !e.mods.isAltDown());
                if (hit.first) {
                            const auto &p=*hit.first;
                            if(t.selectedHeaderProject != t.w.session.project().id) {
                                t.selectedHeaderRegions.clear(); t.headerSelectionAnchor.clear();
                            }
                            if (e.mods.isShiftDown()) {
                                std::vector<const jaras::Part*> parts;
                                for (const auto& part : t.w.session.song()->parts) if (!part.parentRegionID) parts.push_back(&part);
                                std::sort(parts.begin(),parts.end(),[](auto a,auto b) {
                                    if(a->startTime!=b->startTime)return a->startTime<b->startTime;
                                    if(a->endTime!=b->endTime)return a->endTime<b->endTime;
                                    return a->id<b->id;
                                });
                                std::vector<ID> order; for(auto part:parts)order.push_back(part->id);
                                auto range=timelineSelection::interval(order,t.headerSelectionAnchor,p.id);
                                if(e.mods.isCtrlDown())t.selectedHeaderRegions.insert(range.begin(),range.end());
                                else t.selectedHeaderRegions=std::move(range);
                                if(t.headerSelectionAnchor.empty())t.headerSelectionAnchor=p.id;
                            } else if (e.mods.isCtrlDown()) {
                                if(!t.selectedHeaderRegions.erase(p.id))t.selectedHeaderRegions.insert(p.id);
                                t.headerSelectionAnchor=t.selectedHeaderRegions.count(p.id)?p.id:ID{};
                            } else if(!e.mods.isPopupMenu() || !t.selectedHeaderRegions.count(p.id)) {
                                t.selectedHeaderRegions={p.id};t.headerSelectionAnchor=p.id;
                            }
                            t.selectedHeaderRegion=t.selectedHeaderRegions.count(p.id)?std::optional<ID>{p.id}:std::nullopt;
                            t.selectedHeaderProject=t.w.session.project().id;
                            repaint(0, 0, getWidth(), t.regionRowsBottom());
                            if(!e.mods.isPopupMenu() && !e.mods.isAltDown() && (e.mods.isShiftDown() || e.mods.isCtrlDown()))return;
                            if (e.mods.isPopupMenu()) {
                                ++t.w.contextCount;
                                t.w.showRegionMenu(p.id, e.getScreenPosition(), t.selectedHeaderRegions);
                            } else if (e.mods.isLeftButtonDown() && e.mods.isAltDown()) {
                                regionDeleteGesture=RegionDeleteGesture{t.w.session.project().id,t.w.session.song()->id,p.id};
                            } else {
                                dragRegion=p.id; originalStart=p.startTime; clipLength=p.endTime-p.startTime;
                                regionEdge=hit.second;
                                regionRepulsion.emplace(*t.w.session.song(),p,10./t.w.pixelsPerSecond);
                                if(regionEdge)setMouseCursor(regionResizeCursor());
                            }
                }
                return;
            }
            const int programRow = e.y < rowsTop() ? -1 : rowAtPoint(e.y);
            if (const auto *song = t.w.session.song(); e.mods.isPopupMenu() && song && programRow >= 0 &&
                programRow < (int)song->tracks.size() && song->tracks[size_t(programRow)].role.id == "chords") {
                const auto &track = song->tracks[size_t(programRow)];
                const float top = rowsTop() + t.w.rowTop(programRow) - t.w.verticalOffset + 4;
                ID markerID;
                for (const auto &marker : track.chordMarkers) {
                    const auto head = chordHead(*song, marker, top);
                    if (head && head->getWidth() >= 18 && head->contains(e.position)) { markerID = marker.id; break; }
                }
                if (!markerID.empty()) {
                    t.w.showChordMenu(track.id, markerID, e.getScreenPosition());
                    return;
                }
            }
            if(const auto *song=t.w.session.song();song && programRow>=0 && programRow<(int)song->tracks.size() && song->tracks[size_t(programRow)].role.id=="programChange") {
                const auto &track=song->tracks[size_t(programRow)];
                const float top=rowsTop()+t.w.rowTop(programRow)-t.w.verticalOffset+4;
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
            int row = rowAtPoint(e.y);
            if (auto *s = t.w.session.song())
                if (row >= 0 && row < (int)s->tracks.size()) {
                    auto &track = s->tracks[(size_t)row];
                    t.w.session.selectProgramChange({});
                    t.w.selectMixerTrack(track.id, e.mods, false);
                    t.invalidate();
                    if(e.y >= rowsTop() && e.mods.isLeftButtonDown() && !e.mods.isCtrlDown()) if(auto pair=sharedBoundaryAt(e.position)) {
                        sharedChainPreview.clear();
                        dragClip=pair->left.id;itemDragSong=s->id;dragOriginalClip=pair->left;dragOriginalValid=true;
                        sharedOriginal=pair->right;originalStart=pair->left.startTime;clipLength=pair->left.duration;
                        sharedSources = {resizeSourceDuration(track, pair->left), resizeSourceDuration(track, pair->right)};
                        sourceRow=row;resizeEdge=1;clipMoveBlocked=false;dragSelectionPreviews.clear();
                        t.pausePlaybackFollow();t.invalidate();return;
                    }
                    for (const auto &c : track.clips)
                        if (itemRect(row,c).contains(e.position)) {
                            const ItemHeader header(itemRect(row,c), (float)getWidth(), track, c, t.w.itemTitle(c),
                                t.itemHeadersHidden, t.w.pixelsPerSecond, t.w.clipSelected(c.id));
                            const auto control = header.hit(e.position, c);
                            {
                                if (e.mods.isShiftDown() && control != ItemHeader::fx) {
                                    std::vector<ID> order;
                                    for(const auto &rangeTrack:s->tracks) {
                                        std::vector<const jaras::AudioClip*> clips;
                                        for(const auto &clip:rangeTrack.clips)clips.push_back(&clip);
                                        std::sort(clips.begin(),clips.end(),[](auto a,auto b){return a->startTime==b->startTime?a->id<b->id:a->startTime<b->startTime;});
                                        for(auto clip:clips)order.push_back(clip->id);
                                    }
                                    const auto anchor=itemSelectionAnchor.empty()?t.w.selectedClip:itemSelectionAnchor;
                                    auto range=timelineSelection::interval(order,anchor,c.id);
                                    if(e.mods.isCtrlDown())t.w.selectedClips.insert(range.begin(),range.end());
                                    else t.w.selectedClips=std::move(range);
                                    if(itemSelectionAnchor.empty())itemSelectionAnchor=anchor.empty()?c.id:anchor;
                                    t.w.selectedClip=c.id;t.invalidate();return;
                                } else if (e.mods.isCtrlDown()) {
                                    if (t.w.selectedClips.empty() && !t.w.selectedClip.empty()) t.w.selectedClips.insert(t.w.selectedClip);
                                    if (!t.w.selectedClips.erase(c.id)) t.w.selectedClips.insert(c.id);
                                } else collapseSelectionOnRelease=c.id;
                                itemSelectionAnchor=c.id;
                            }
                            t.w.selectedClip = t.w.selectedClips.count(c.id) ? c.id : t.w.selectedClips.empty() ? ID{} : *t.w.selectedClips.begin();
                            if (control != ItemHeader::none) {
                                controlKind=control;
                                if (timelineGrid::itemMixLocked(t.w.session.project()) &&
                                    (controlKind==ItemHeader::gain || controlKind==ItemHeader::pan)) {
                                    controlKind=ItemHeader::none;return;
                                }
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
                                    t.w.perform([&] { t.w.session.command(jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods)); });
                                dragClip = c.id;
                                itemDragSong=s->id;
                                dragOriginalClip=c; dragOriginalValid=true;
                                dragSelectionPreviews.clear();
                                if(t.w.selectedClips.count(c.id) && t.w.selectedClips.size()>1) {
                                    for(int selectedRow=0;selectedRow<(int)s->tracks.size();++selectedRow)
                                        for(const auto &selectedClip:s->tracks[(size_t)selectedRow].clips)
                                            if(t.w.selectedClips.count(selectedClip.id)) dragSelectionPreviews.push_back({selectedRow,selectedClip,selectedClip});
                                }
                                originalStart = c.startTime;
                                clipLength = c.duration;
                                sourceRow = row;
                                resizeEdge = header.resizeSide(e.position);
                                clipMoveBlocked = clipEditing::generatedClick(track, c);
                                if (!resizeEdge && t.w.selectedClips.count(c.id))
                                    for (const auto &selectedTrack : s->tracks) for (const auto &selectedClip : selectedTrack.clips)
                                        if (t.w.selectedClips.count(selectedClip.id) && clipEditing::generatedClick(selectedTrack, selectedClip)) clipMoveBlocked = true;
                            }
                            t.invalidate();
                            return;
                        }
                }
            if (!e.mods.isPopupMenu() && !e.mods.isCtrlDown())
                t.w.perform([&] { t.w.session.command(jaras::CommandKind::editSeek, {}, pointerPosition(startTime, e.mods)); });
            clearSelectionOnRelease=true;
        }

        void mouseDrag(const MouseEvent &e) override {
            if (regionDeleteGesture) {
                if (e.getDistanceFromDragStart() >= 3) regionDeleteGesture->dragged=true;
                return;
            }
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
            if ((!dragClip.empty() && timelineGrid::itemsLocked(t.w.session.project())) ||
                ((!dragRegion.empty() || !dragMarker.empty()) && timelineGrid::regionsLocked(t.w.session.project()))) {
                t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
                dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); sharedOriginal.reset(); sharedPreview.reset();
                setMouseCursor(MouseCursor::NormalCursor); repaint(); return;
            }
            if (!dragRegion.empty() || !dragMarker.empty()) {
                if (e.getDistanceFromDragStart() >= 3) {
                    if (!dragRegion.empty() && !regionEdge) {
                        t.regionTimebaseSuspended = true;
                        t.w.timelineTimebase.setToggleState(false, dontSendNotification);
                    }
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
                    t.w.session.command(jaras::CommandKind::editSeek, {}, pointerPosition(t.timeAt(e.position.x), e.mods));
                });
            } else if (!dragClip.empty() && (!clipMoveBlocked || resizeEdge) && e.getDistanceFromDragStart() > 4) {
                if(previewRow>=0 && previewRow<(int)t.w.rows.size())
                    repaint(0,rowsTop()+t.w.rowTop(previewRow)-t.w.verticalOffset,getWidth(),t.w.rowHeight(previewRow));
                const bool began = !dragPreview;
                updateDrag(e);
                if (!resizeEdge) {
                    if (began) t.pausePlaybackFollow();
                    itemEdgeActive=true; itemEdgePointer=e.position; itemEdgeModifiers=e.mods;
                    startEdgeScroll();
                }
                setMouseCursor(sharedOriginal ? sharedBoundaryCursor() : MouseCursor(resizeEdge ? MouseCursor::LeftRightResizeCursor
                                          : MouseCursor::DraggingHandCursor));
                repaintDragPreview();
            }
        }
        void mouseUp(const MouseEvent &e) override {
            t.regionTimebaseSuspended = false;
            t.w.timelineTimebase.setToggleState(t.w.session.song() && t.w.session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase == jaras::ProjectTimebase::relative, dontSendNotification);
            stopTimer(); itemEdgeActive=false;
            if (regionDeleteGesture) {
                const auto request=*regionDeleteGesture;
                regionDeleteGesture.reset();
                const auto *song=t.w.session.song();
                const auto hit=regionHit(e.position,false);
                if (!request.dragged && e.getDistanceFromDragStart()<3 &&
                    t.w.session.project().id==request.project && song && song->id==request.song &&
                    hit.first && hit.first->id==request.region)
                    t.w.deleteRegions({request.region});
                return;
            }
            if (rulerPan) {
                rulerPan=false;
                if (!rulerPanDragged) t.w.perform([&] {
                    t.w.session.command(t.w.timelineEditMode ? jaras::CommandKind::queueBeatSeek : jaras::CommandKind::editSeek,
                                        {}, pointerPosition(startTime, e.mods));
                });
                setMouseCursor(MouseCursor::PointingHandCursor);return;
            }

            if(e.getDistanceFromDragStart() < 4) {
                if(!collapseSelectionOnRelease.empty()) { t.w.selectedClips={collapseSelectionOnRelease}; t.w.selectedClip=collapseSelectionOnRelease; }
                else if(clearSelectionOnRelease) t.w.clearItemSelection();
            }
            collapseSelectionOnRelease.clear();clearSelectionOnRelease=false;
            if (timeRangeGesture) {
                updateTimeRange(e);timeRangeGesture=false;
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
            if ((!dragClip.empty() && timelineGrid::itemsLocked(t.w.session.project())) ||
                ((!dragRegion.empty() || !dragMarker.empty()) && timelineGrid::regionsLocked(t.w.session.project()))) {
                t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
                if (e.getDistanceFromDragStart() < 3) t.w.perform([&] {
                    if (!dragRegion.empty()) {
                        t.w.session.command(t.w.session.transport().playing ? jaras::CommandKind::queueRegion : jaras::CommandKind::selectRegion, dragRegion);
                    } else if (!dragMarker.empty()) {
                        t.w.session.command(jaras::CommandKind::editSeek, {}, originalStart);
                    }
                });
                dragClip.clear(); dragRegion.clear(); dragMarker.clear();
                dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); sharedOriginal.reset(); sharedPreview.reset(); resizeEdge = 0; regionEdge = 0;
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
                    }, true, false, true);
                });
                else t.w.perform([&] {
                    if (!region.empty()) {
                        t.w.session.command(t.w.session.transport().playing ? jaras::CommandKind::queueRegion : jaras::CommandKind::selectRegion, region);
                    } else {
                        t.w.session.command(jaras::CommandKind::editSeek, {}, originalStart);
                    }
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
                        ItemHeader(itemRect(controlRow,*controlClip),(float)getWidth(),song->tracks[(size_t)controlRow],*controlClip,t.w.itemTitle(*controlClip),t.itemHeadersHidden,t.w.pixelsPerSecond,t.w.clipSelected(controlClip->id)).hit(e.position,*controlClip)==kind;
                    if(activate) {
                        if(kind==ItemHeader::fx && !e.mods.isAltDown() && !e.mods.isShiftDown()) {const auto id=controlClip->id; controlClip.reset();controlKind=ItemHeader::none;t.w.openItemFX(id);return;}
                        if(kind==ItemHeader::mute) controlClip->muted=!controlClip->muted;
                        if(kind==ItemHeader::phase) controlClip->phaseInverted=!controlClip->phaseInverted.value_or(false);
                        if(kind==ItemHeader::fx) {
                            const auto id=controlClip->id;controlClip.reset();controlKind=ItemHeader::none;
                            const auto targets = controlSelection;
                            const bool remove = e.mods.isAltDown(), bypassed = !controlOriginal.fxBypassed.value_or(false);
                            t.w.perform([&]{
                                if(remove) {
                                    std::map<ID,var> changes;
                                    for(const auto &target:targets)changes[target]=var();
                                    t.w.session.configureEffects(changes);
                                } else t.w.session.edit([&](auto &project){
                                    for(auto &song:project.songs)for(auto &track:song.tracks)for(auto &clip:track.clips)
                                        if(targets.count(clip.id))clip.fxBypassed=bypassed;
                                });
                            });repaint();return;
                        }
                        commitControl();
                    }
                } else if(e.getDistanceFromDragStart()>0) commitControl();
                controlClip.reset();controlKind=ItemHeader::none;mouseMove(e);repaint();return;
            }
            mainDrag = false;
            setMouseCursor(MouseCursor::NormalCursor);
            if (!dragClip.empty() && (!clipMoveBlocked || resizeEdge) && e.getDistanceFromDragStart() > 4) {
                updateDrag(e);
                auto id = dragClip;
                t.w.perform([&] {
                    ID destinationTrack;
                    if (auto *song = t.w.session.song();
                        song && previewRow >= 0 && previewRow < (int)song->tracks.size())
                        destinationTrack = song->tracks[(size_t)previewRow].id;
                    if (sharedOriginal && resizeEdge) {
                        if (!sharedPreview || std::abs(previewEnd - sharedOriginal->startTime) <= 1e-7) return;
                        if (sharedTeleprompterChain)
                            t.w.session.resizeTeleprompterBoundary(t.w.selectedClips, id, sharedOriginal->id, previewEnd);
                        else
                            t.w.session.resizeSharedItemBoundary(id, sharedOriginal->id, previewEnd, sharedSources.first, sharedSources.second);
                    }
                    else if (resizeEdge && groupDragPreview()) {
                        std::map<ID, std::pair<double, double>> frames;
                        for (const auto &entry : dragSelectionPreviews)
                            frames.emplace(entry.preview.id, std::pair{entry.preview.startTime, entry.preview.startTime + entry.preview.duration});
                        t.w.session.resizeItems(frames);
                    }
                    else if (resizeEdge) t.w.session.resizeItem(id, previewStart, previewEnd);
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
                t.w.perform([&] { t.w.session.command(jaras::CommandKind::editSeek,
                    {}, pointerPosition(startTime, e.mods)); });
            dragClip.clear();
            dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); sharedOriginal.reset(); sharedPreview.reset();
            dragOriginalClip.reset();dragOriginalValid=false;previewPlacements.clear();dragSelectionPreviews.clear();
            repaint();
        }
        void mouseDoubleClick(const MouseEvent &e) override {
            if (t.inRegionRows(e.position.y) && e.mods.isAltDown()) return;
            if (const auto *song=t.w.session.song()) {
                const int row = rowAtPoint(e.y);
                if (row>=0 && row<(int)song->tracks.size()) for (const auto &clip:song->tracks[(size_t)row].clips) {
                    const auto hit=ItemHeader(itemRect(row,clip),(float)getWidth(),song->tracks[(size_t)row],clip,t.w.itemTitle(clip),t.itemHeadersHidden,t.w.pixelsPerSecond,t.w.clipSelected(clip.id)).hit(e.position,clip);
                    if (timelineGrid::itemMixLocked(t.w.session.project()) && (hit==ItemHeader::gain || hit==ItemHeader::pan)) return;
                    if (hit == ItemHeader::gain || hit == ItemHeader::pan ||
                        (e.y >= rowsTop() && (hit == ItemHeader::fadeIn || hit == ItemHeader::fadeOut || ItemHeader::isShape(hit)))) {
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
            if (e.y < headerHeight()) {
                if (!t.onRuler(e.position.y) && !t.w.timelineEditMode) t.w.perform([&] {
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
            t.regionTimebaseSuspended = false;
            t.w.timelineTimebase.setToggleState(t.w.session.song() && t.w.session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase == jaras::ProjectTimebase::relative, dontSendNotification);
            regionDeleteGesture.reset();
            t.setRegionPreview(std::nullopt); t.previewMarker(std::nullopt);
            rulerPan=false;rulerPanDragged=false;
            timeRangeGesture=false;timeRangeDragged=false;timeRangeResize=0;timeRangeBefore.reset();
            stopTimer(); rightSelection = false; itemEdgeActive=false; itemDragSong.clear(); selectionBox.reset(); selectionBase.clear(); selectionPending = false; selectionIndex.clear();
            dragRegion.clear(); dragMarker.clear();
            if(controlClip) t.w.perform([&]{previewControl(controlOriginal);});
            controlClip.reset();controlKind=ItemHeader::none;
            setItemValueTooltip({},controlPointer);
            dragClip.clear();dragOriginalClip.reset();dragOriginalValid=false;previewPlacements.clear();dragSelectionPreviews.clear();
            dragPreview = false; resizedClipPreview.reset(); movingClipPreview.reset(); sharedOriginal.reset(); sharedPreview.reset(); mainDrag = false; setMouseCursor(MouseCursor::NormalCursor); repaint();
        }

      private:
        Timeline &t;
        String itemValueTooltip;
        struct ClipIntervalEntry { double start=0,end=0;size_t index=0; };
        struct TrackClipIndex { ID track;std::vector<ClipIntervalEntry> entries;std::vector<double> maximumEnds; };
        ID clipIndexSong;
        uint64 clipIndexRevision=~uint64(0);
        std::vector<TrackClipIndex> clipIndexes;
        std::map<ID,ItemLanes::Placement> previewPlacements;
        std::pair<const jaras::Part*,int> regionHit(Point<float> point,bool edges) const {
            const auto *song=t.w.session.song(); if (!song || !t.inRegionRows(point.y))return {nullptr,0};
            for(const auto &part:song->parts) {
                if(part.parentRegionID || (int)point.y/headerLaneHeight!=t.regionLanes().lane(part.id))continue;
                const float left=t.xAt(part.startTime),right=t.xAt(part.endTime);
                if(point.x<left || point.x>=right)continue;
                int edge=0;
                if(edges && !timelineGrid::regionsLocked(t.w.session.project()) && !regionEditing::hasChildren(*song,part.id)) {
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
            return song?timelineGrid::snap(at,*song,t.w.pixelsPerSecond,t.w.freeTimelinePosition(e.mods),&t.w.session.transport(),false,nullptr,nullptr,&dragMarker):at;
        }
        std::pair<double,double> regionEditBounds(const MouseEvent &e) const {
            const double delta=(e.position.x-startPosition.x)/t.w.pixelsPerSecond;
            if(!regionEdge) {
                double start=std::max(0.,originalStart+delta);
                if(const auto *song=t.w.session.song())start=timelineGrid::snap(start,*song,t.w.pixelsPerSecond,
                    t.w.freeTimelinePosition(e.mods),&t.w.session.transport(),true,nullptr,&dragRegion);
                if(regionRepulsion)start=regionRepulsion->resolve(start);
                return {start,start+clipLength};
            }
            double boundary=(regionEdge<0?originalStart:originalStart+clipLength)+delta;
            if(const auto *song=t.w.session.song())boundary=timelineGrid::snap(boundary,*song,t.w.pixelsPerSecond,
                t.w.freeTimelinePosition(e.mods),&t.w.session.transport(),true,nullptr,&dragRegion);
            return {regionEdge<0?std::max(0.,std::min(originalStart+clipLength-.01,boundary)):originalStart,
                    regionEdge>0?std::max(originalStart+.01,boundary):originalStart+clipLength};
        }
        bool rulerPan=false,rulerPanDragged=false;
        double rulerPanOffset=0;
        bool timeRangeGesture=false,timeRangeDragged=false;
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
                    const double y = top + geometry.top + timelineItemVerticalInset;
                    items.push_back({clip.id, {left, y, left + std::max(2., clip.duration * t.w.pixelsPerSecond - 2), y + geometry.height - 2 * timelineItemVerticalInset}});
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
                (itemMove && timelineGrid::itemsLocked(t.w.session.project()))) { cancelDrag(); return; }
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
            const int row=t.w.rowAt(startPosition.y-rowsTop()+t.w.verticalOffset);
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
        std::optional<jaras::AudioClip> sharedOriginal, sharedPreview;
        std::vector<jaras::AudioClip> sharedChainPreview;
        bool sharedTeleprompterChain = false;
        std::pair<std::optional<double>,std::optional<double>> sharedSources;
        struct SharedBoundaryHit { jaras::AudioClip left,right; };
        std::optional<SharedBoundaryHit> sharedBoundaryAt(Point<float> point) const {
            if(timelineGrid::itemsLocked(t.w.session.project()) || point.y<headerHeight())return {};
            const auto *song=t.w.session.song();if(!song)return {};
            const int row=t.w.rowAt(roundToInt(point.y)-rowsTop()+t.w.verticalOffset);
            if(row<0 || row>=(int)song->tracks.size())return {};
            const auto &track=song->tracks[(size_t)row];
            const auto eligible = [&](const jaras::AudioClip &clip) {
                return t.w.selectedClips.count(clip.id) && (t.w.selectedClips.size() == 2 ||
                    (jaras::isTeleprompterRole(track.role) && clip.text && !clip.audioFile && !clip.midi));
            };
            for(const auto &a:track.clips)if(eligible(a)&&std::abs(t.xAt(a.startTime+a.duration)-point.x)<=6) {
                const auto ra=itemRect(row,a);
                if(point.y<=ra.getY()+std::min(20.f,ra.getHeight()/2)||point.y>=ra.getBottom())continue;
                for(const auto &b:track.clips)if(eligible(b)&&a.id!=b.id && std::abs(a.startTime+a.duration-b.startTime)<1e-7) {
                    const auto rb=itemRect(row,b);
                    if(std::abs(ra.getY()-rb.getY())<.01f && a.recordingLane.value_or(0)==b.recordingLane.value_or(0))return SharedBoundaryHit{a,b};
                }
            }
            return {};
        }
        static MouseCursor sharedBoundaryCursor() {
            static const MouseCursor cursor=[] {
                Image image(Image::ARGB,24,24,true);Graphics g(image);Path p;
                p.startNewSubPath(12,3);p.lineTo(12,21);p.startNewSubPath(2,12);p.lineTo(22,12);
                p.startNewSubPath(6,8);p.lineTo(2,12);p.lineTo(6,16);p.startNewSubPath(18,8);p.lineTo(22,12);p.lineTo(18,16);
                g.setColour(Colours::black);g.strokePath(p,PathStrokeType(4));g.setColour(Colours::white);g.strokePath(p,PathStrokeType(2));
                return MouseCursor(image,12,12);
            }();return cursor;
        }
        jaras::AudioClip controlOriginal;
        std::optional<jaras::AudioClip> dragOriginalClip;
        bool dragOriginalValid=false;
        struct DragSelectionPreview { int row = 0; jaras::AudioClip original, preview; };
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
            const int width=valueTooltipWidth(itemValueTooltip);
            return juce::Rectangle<int>(roundToInt(controlPointer.x)+12,roundToInt(controlPointer.y)-30,width,24)
                .constrainedWithin(getLocalBounds());
        }
        void setItemValueTooltip(const String &label,Point<float> point) {
            const auto old=valueTooltipBounds();
            if(itemValueTooltip==label && (label.isEmpty() || controlPointer==point))return;
            itemValueTooltip=label;controlPointer=point;
            repaint(old.getUnion(valueTooltipBounds()).expanded(1).getIntersection(getLocalBounds()));
        }
        int rowsTop() const { return headerHeight(); }
        int rowAtPoint(int y) const {
            return y < rowsTop() ? -1 : t.w.rowAt(y - rowsTop() + t.w.verticalOffset);
        }
        std::optional<juce::Rectangle<float>> chordHead(const jaras::Song &song, const jaras::ChordMarker &marker, float y) const {
            const auto region = std::find_if(song.parts.begin(), song.parts.end(), [&](const auto &part) { return part.id == marker.regionID; });
            if (region == song.parts.end() || marker.offset >= region->endTime - region->startTime) return {};
            const auto position = region->startTime + marker.offset;
            const auto natural = std::ceil(GlyphArrangement::getStringWidth(theme::semiboldFont(10), text(marker.name))) + 10.f;
            const auto width = std::min(float(natural), float((region->endTime - position) * t.w.pixelsPerSecond));
            return juce::Rectangle<float>(t.xAt(position), y, width, 19.f);
        }
        juce::Rectangle<float> itemRect(int row, const jaras::AudioClip &clip) const {
            const int top = rowsTop() + t.w.rowTop(row) - t.w.verticalOffset;
            const auto geometry = t.w.itemGeometry(row, clip.id);
            return {t.xAt(clip.startTime), top + geometry.top + timelineItemVerticalInset,
                    std::max(2.f,(float)(clip.duration*t.w.pixelsPerSecond)-2), geometry.height - 2 * timelineItemVerticalInset};
        }
        bool groupDragPreview() const {
            return !sharedOriginal && dragSelectionPreviews.size() > 1 && (resizedClipPreview || movingClipPreview);
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
            if(groupDragPreview()) {
                const int rowDelta=resizeEdge ? 0 : previewRow-sourceRow;
                for(const auto &entry:dragSelectionPreviews) {
                    include(oldTimes,entry.row,entry.original.startTime,entry.original.startTime+entry.original.duration);
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
                    const float top=rowsTop()+t.w.rowTop(row)-t.w.verticalOffset;
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
            if (timelineGrid::itemMixLocked(t.w.session.project()) &&
                (controlKind==ItemHeader::gain || controlKind==ItemHeader::pan)) {
                if (const auto *song=t.w.session.song()) for (const auto &track:song->tracks) for (const auto &clip:track.clips)
                    if (clip.id==value.id || controlSelection.count(clip.id)) {
                        if (clip.midi) t.w.session.audio.previewMIDIItem(*song,clip);
                        else t.w.session.audio.setItemControls(clip);
                    }
                return;
            }
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
            if (timelineGrid::itemMixLocked(t.w.session.project()) &&
                (controlKind==ItemHeader::gain || controlKind==ItemHeader::pan)) {
                previewControl(value); controlClip.reset(); controlKind=ItemHeader::none; repaint(); return;
            }
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
        ID dragClip, dragRegion, dragMarker, collapseSelectionOnRelease, itemSelectionAnchor;
        struct RegionDeleteGesture { ID project,song,region; bool dragged=false; };
        std::optional<RegionDeleteGesture> regionDeleteGesture;
        bool clearSelectionOnRelease=false;
        int regionEdge=0;
        bool mainDrag = false;
        int sourceRow = 0;
        bool dragPreview = false;
        int resizeEdge = 0, previewRow = 0;
        bool clipMoveBlocked = false;
        double previewStart = 0, previewEnd = 0;
        double pointerPosition(double time, ModifierKeys modifiers) const {
            const auto *song=t.w.session.song();
            return song ? timelineGrid::snapCursor(time,*song,t.w.pixelsPerSecond,t.w.freeTimelinePosition(modifiers)) : time;
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
        std::optional<double> resizeSourceDuration(const jaras::Track &track, const jaras::AudioClip &clip) {
            const auto &file = clip.audioFile ? clip.audioFile : track.audioFile;
            if (file && !clip.midi)
                if (const auto data = t.waveforms.request(t.waveformFile(file->path))) return data->duration;
            return {};
        }
        jaras::AudioClip resizedPreview(const jaras::Song &song, const jaras::Track &track,
                                        jaras::AudioClip clip, double start, double end) {
            std::tie(start, end) = clipEditing::constrainedEdges(song, track, clip, start, end);
            if (clipEditing::generatedClick(track, clip))
                return clipEditing::resizedClick(song, track, std::move(clip), start, end);
            if (track.role.id == "timecode" && !clipEditing::projection(clip)) {
                clip.startTime = start;
                clip.duration = end - start;
                return clip;
            }
            const auto sourceDuration = resizeSourceDuration(track, clip);
            return clipEditing::resizedSource(clip, start, end, sourceDuration);
        }
        void updateDrag(Point<float> point, ModifierKeys modifiers) {
            repaintItemEdgeGuides();
            double edge = (resizeEdge > 0 ? originalStart + clipLength : originalStart) +
                          t.timeAt(point.x) - startTime;
            edge = std::max(0., edge);
            auto excluded = t.w.selectedClips; excluded.insert(dragClip); if(sharedOriginal)excluded.insert(sharedOriginal->id);
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
            previewRow = resizeEdge || point.y < rowsTop() ? sourceRow :
                t.w.rowAt(roundToInt(point.y) - rowsTop() + t.w.verticalOffset);
            if (previewRow < 0 || previewRow >= t.w.rows.size())
                previewRow = sourceRow;
            if(const auto *song=t.w.session.song(); song && dragOriginalValid && dragOriginalClip && sourceRow>=0 && sourceRow<(int)song->tracks.size()) {
                const auto &source=song->tracks[(size_t)sourceRow];
                const auto &target=song->tracks[(size_t)previewRow];
                if(sharedOriginal && resizeEdge) {
                    sharedChainPreview.clear();
                    resizedClipPreview.reset();
                    sharedPreview.reset();
                    auto chain = jaras::teleprompterBoundary(source, t.w.selectedClips, dragOriginalClip->id, sharedOriginal->id, edge);
                    sharedTeleprompterChain = chain.has_value();
                    if (chain) {
                        sharedChainPreview=std::move(*chain);
                    } else if (t.w.selectedClips.size() == 2) {
                        if (!sharedSources.first) sharedSources.first = resizeSourceDuration(source, *dragOriginalClip);
                        if (!sharedSources.second) sharedSources.second = resizeSourceDuration(source, *sharedOriginal);
                        if (auto pair = clipEditing::sharedBoundary(*song, source, *dragOriginalClip, *sharedOriginal,
                                                                   edge, sharedSources.first, sharedSources.second)) {
                            sharedChainPreview = {std::move(pair->first), std::move(pair->second)};
                        }
                    }
                    for (const auto &clip : sharedChainPreview) {
                        if (clip.id == dragOriginalClip->id) resizedClipPreview = clip;
                        if (clip.id == sharedOriginal->id) sharedPreview = clip;
                    }
                    if (resizedClipPreview && sharedPreview) {
                        previewStart=resizedClipPreview->startTime;previewEnd=sharedPreview->startTime;
                    }
                    refreshPreviewPlacements(*song);repaintDragPreview();repaintItemEdgeGuides();return;
                }
                if (resizeEdge) {
                    const double anchorEdge = resizeEdge < 0 ? originalStart : originalStart + clipLength;
                    const double adjustment = edge - anchorEdge;
                    const auto resize = [&](const jaras::AudioClip &clip, const jaras::Track &track) {
                        const double from = clip.startTime, to = from + clip.duration;
                        const double minimum = std::min(clip.duration, std::max(.01, 16. / t.w.pixelsPerSecond));
                        const double start = resizeEdge < 0 ? std::clamp(from + adjustment, 0., std::max(0., to - minimum)) : from;
                        const double end = resizeEdge > 0 ? std::max(from + minimum, to + adjustment) : to;
                        return resizedPreview(*song, track, clip, start, end);
                    };
                    resizedClipPreview = resize(*dragOriginalClip, source);
                    previewStart = resizedClipPreview->startTime;
                    previewEnd = previewStart + resizedClipPreview->duration;
                    for (auto &entry : dragSelectionPreviews) {
                        if (entry.row >= 0 && entry.row < (int)song->tracks.size())
                            entry.preview = resize(entry.original, song->tracks[(size_t)entry.row]);
                    }
                    repaintDragPreview();
                } else {
                    previewStart = clipEditing::constrainedStart(target, *dragOriginalClip, previewStart);
                    previewEnd = previewStart + clipLength;
                    if(!movingClipPreview) movingClipPreview=*dragOriginalClip;
                    movingClipPreview->startTime=previewStart;
                    movingClipPreview->duration=previewEnd-previewStart;
                    if(t.w.selectedClips.count(dragClip) && t.w.selectedClips.size()>1) {
                        double earliest=originalStart;
                        for(const auto &entry:dragSelectionPreviews) earliest=std::min(earliest,entry.original.startTime);
                        const double delta=std::max(previewStart-originalStart,-earliest);
                        for(auto &entry:dragSelectionPreviews) entry.preview.startTime=entry.original.startTime+delta;
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
            auto head = [&](double position, Colour colour) {
                float x = t.xAt(position);
                if (x < 0 || x > getWidth())
                    return;
                const float tip = float(headerHeight());
                const float top = float(t.cursorLaneTop());
                drawTimelineNeedle(g,x,top,tip,float(getHeight()),colour);
            };
            head(state.editPosition, t.w.appearance.colour("jaras.timeline.editCursor", theme::timelineEditCursorRGB));
            if (state.playing || state.paused)
                head(state.position, t.w.appearance.colour("jaras.timeline.playCursor", theme::timelinePlayCursorRGB));
            if (t.w.session.subCursorVisible()) {
                head(t.w.session.subCursorPosition(state),
                     Colour(0xff000000u | theme::setlistQueuedYellowRGB).withMultipliedAlpha(
                         Session::subCursorOpacity(Time::getMillisecondCounterHiRes() / 1000)));
            }
        }

      private:
        Timeline &t;
    } heads;
    void scrollBarMoved(ScrollBar *bar, double position) override {
        if(bar->isMouseButtonDown() || bar->isMouseOverOrDragging() && Component::isMouseButtonDownAnywhere())pausePlaybackFollow(true);
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
    if (!StringArray{"play", "pause", "loop", "record", "metronome"}.contains(id))
        addAndMakeVisible(b);
    controls[id] = b;
    b->setComponentID(id);
    b->getProperties().set("fontSize", 10);
    b->getProperties().set("cornerRadius", 6.f);
    b->setWantsKeyboardFocus(false);
    if (!colour.isTransparent()) b->setColour(TextButton::buttonColourId, colour);
    b->onClick = [this, action] { perform(action); };
    return *b;
}
class Workspace::TrackHeightHandle final : public Component, private Timer {
    Workspace &w;
    ID trackID, songID; int startY=0, count=1; double startHeight=0, denominator=1, initialScale=1;
    double pendingScale=1;
    bool compactControls=false;
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
            compactControls=allowsCompactTrackHeight(track); startHeight=w.rowBodyHeight(i);denominator=w.trackHeight*(count>1?.7:1.);initialScale=track.heightScale.value_or(1.);
            pendingScale=initialScale;pendingHeight=false;
            w.trackHeightPreview=std::pair<ID,double>{trackID,initialScale};grabKeyboardFocus();
        }
    }
    void mouseDrag(const MouseEvent &e) override {
        if(trackID.empty())return;
        if(!w.session.song() || w.session.song()->id!=songID){cancel();return;}
        const double scale=std::max(.01,(double)getApproximateScaleFactorForComponent(this));
        double lane=jlimit(desktopLaneMinimum(count,compactControls),count>1?168.:240.,std::round((startHeight+(e.getScreenY()-startY)/scale)/count));
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
    if (!browserVisible && !loginPanel && controls["masterMute"]->isVisible() && session.project().masterMute) {
        const bool bright = (int64(Time::getMillisecondCounterHiRes() / 500.0) % 2) == 0;
        const juce::Rectangle<float> bounds(4, (float)transportBounds.getY() + 8, 266, 70);
        g.setColour(Colour(0xffff3b30).withAlpha(bright ? .28f : .04f));
        g.fillRoundedRectangle(bounds, 5);
        g.setColour(Colour(0xffff3b30).withAlpha(bright ? 1.f : .25f));
        g.drawRoundedRectangle(bounds.reduced(1), 5, 2);
    }
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
    if(!trackDropBlocked.empty()){auto r=boundsFor(trackDropBlocked);g.setColour(Colours::red);g.drawRect(r.reduced(2),2);g.setFont(theme::font(11));g.drawText(String::fromUTF8("Destino indisponível"),r,Justification::centred);}
}

namespace {
class ToolbarTooltipWindow final : public TooltipWindow {
public:
    explicit ToolbarTooltipWindow(Component &workspace) : TooltipWindow(&workspace), owner(workspace) {}
    String getTipFor(Component &component) override {
        if (owner.isParentOf(&component) && (bool)component.getProperties()["toolbarLabel"])
            return TooltipWindow::getTipFor(component);
        return {};
    }
private:
    Component &owner;
};
}

Workspace::Workspace(Session &s, Auth &a, Lighting &l, bool homePreview, File appearanceFile, std::shared_ptr<remote::Host> host)
    : session(s), auth(a), lighting(l), appearance(std::move(appearanceFile)),
      actions(appearance, s.audio.devices), stage(appearance) {
    theme::setInterfaceTheme(appearance.value(theme::interfaceThemeKey, theme::defaultInterfaceTheme).toString() == "lightDark");
    timelineEditMode = (bool)appearance.value("jaras.timeline.editMode", false);
    showRegionLanes = (bool)appearance.value("jaras.timeline.showRegionLanes", true);
    showTempoLane = (bool)appearance.value("jaras.timeline.showTempoLane", true);
    look.refreshThemeColours();
    LookAndFeel::setDefaultLookAndFeel(&look);
    setLookAndFeel(&look);
    toolbarTooltips = std::make_unique<ToolbarTooltipWindow>(*this);
    remotePresentation = std::make_unique<remote::Presentation>(session, stage);
    remoteHost = host ? std::move(host) : std::make_shared<remote::Host>(appearance);
    remoteHost->setHostName(auth.deviceName);
    const auto transportFont = auth.dataDirectory().getChildFile("Fonts/Inter-SemiBold.ttf");
    transportFont.getParentDirectory().createDirectory();
    if (!transportFont.existsAsFile() && !transportFont.replaceWithData(BinaryData::InterSemiBold_ttf, BinaryData::InterSemiBold_ttfSize))
        throw std::runtime_error("Não foi possível preparar a fonte do transporte.");
    masterPeakReadout=std::make_unique<meterDisplay::PeakReadout>([this]{return session.audio.heldPeak();},[this]{session.audio.clearPeak();},[]{return theme::surfaceText(theme::mixerStripeSurface);});addAndMakeVisible(*masterPeakReadout);
    nativeTransport = std::make_unique<native::TransportButtons>(transportFont.getFullPathName().toWideCharPointer());
    remotePresentation->save = [this] { chooseSave(); };
    remotePresentation->fadeout = [this](bool active) {
        if (!active) { session.cancelTransportFadeout(); return; }
        if (session.transportFadeoutActive()) return;
        const auto config = TransportFadeoutPanel::read(appearance, session.project());
        session.toggleTransportFadeout(true, config.tracks, config.duration);
    };
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
    stageTimer = std::make_unique<StageTimerReadout>(stage);
    addChildComponent(*stageTimer);
    tempoControl =
        std::make_unique<TempoControl>(session, [this](String error) { showError(error); },
            [this] { perform([&] { performAction("tapTempo", 1, 0); }); },
            [this](String action) {
                auto page = std::make_unique<ActionsPage>(actions);
                page->showAction(action);
                ModalSheet::open(*this, "Mapear controle", std::move(page), 430, 280);
            }, [this] { tempoTaps = {}; });
    addAndMakeVisible(*tempoControl);
    const auto makeMixer = [this](std::function<ID()> focusedTrack) {
        const bool focused = bool(focusedTrack);
        auto panel = std::make_unique<MixerPanel>(
            session, [this](ID id, String effect) { openFX(id, effect); },
            [this,focused](ID id, ModifierKeys mods) { selectMixerTrack(id, mods, true, !focused); },
            [this](String error) { showError(error); },
            [this](ID id, bool remove) { changeMixerFX(id, remove); },
            [this](ID id) { return trackSelected(id); },
            [this,focused](ID id,Point<int> point) {
                if (focused && id.empty()) showMasterMenu(point);
                else showTrackMenu(id,point,false);
            }, [this](ID id,String action) { specialTrackAction(id,action); },
            [this](ID id) { return !session.song() || trackVisibility.visible(*session.song(),TrackVisibility::Panel::barMixer,id); },
            std::move(focusedTrack));
        panel->mapControl = [this](const ID &id, jaras::CommandKind kind) { mapMixerControl(id, kind); };
        return panel;
    };
    footerMixer = makeMixer({});
    focusMixer = makeMixer([this] { return selectedTrack; });
    focusMixer->setComponentID("focusMixer");
    addChildComponent(*focusMixer);
    workspaceLibrary = std::make_unique<WorkspaceLibrary>(session);
    workspaceLibrary->folderWidthChanged = [this] { if (workspaceLibrary->getWidth() != std::min({libraryWidth, workspaceLibrary->maximumPanelWidth(),
                                                     std::max(0, workspaceBounds.getWidth() - 240)}))
            layoutWorkspaceColumns(true); };
    workspaceLibrary->selectTimelineEntry = [this](const ID &id, bool region, double position) {
        if (region) setlist->selectLibraryRegion(id);
        else session.command(jaras::CommandKind::editSeek, {}, position);
        timeline->revealEditPosition(true);
    };
    addChildComponent(*workspaceLibrary);
    addChildComponent(libraryDivider);
    libraryDivider.setThinRail(true);
    libraryDivider.setScrollRailVisible(false);
    libraryDivider.started = [this] { libraryResizeStart = workspaceLibrary->getWidth(); };
    libraryDivider.moved = [this](int delta) {
        const int maximum = std::max(190, std::min(workspaceLibrary->maximumPanelWidth(), workspaceBounds.getWidth() - 240));
        const int next = jlimit(190, maximum, libraryResizeStart + delta);
        if (next == libraryWidth) return;
        libraryWidth = next;
        layoutWorkspaceColumns(true);
    };
    libraryDivider.ended = [this] { saveWorkspaceLayout(); };
    footerMixer->addTrackInEmptyArea = [this] { addStandardTrackAtEnd(); };
    syncBarMixerMasterSide();
    syncHozMixerTrackStyle();
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
    partsLeft->horizontalHeightChanged = [this](int value, bool commit) {
        if (horizontalPartsHeight != value) {
            horizontalPartsHeight = value;
            resized();
        }
        if (commit) {
            const auto result = appearance.set("catlive.horizontalPartsHeight", value);
            if (result.failed()) showError(result.getErrorMessage());
        }
    };
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
    midiPreviewPanel = std::make_unique<RecordingPianoPreview>(session, appearance, selectedTrack,
        [this](String message) { showError(message); },
        [this](double position, double scale, bool ruler, ModifierKeys modifiers) {
            const auto *song = session.song();
            if (!song || !projectReady || browserVisible) return false;
            bool moved = false;
            perform([&] {
                const auto target = timelineGrid::snapCursor(position, *song, scale, freeTimelinePosition(modifiers));
                session.command(ruler && timelineEditMode ? jaras::CommandKind::queueBeatSeek : jaras::CommandKind::editSeek,
                                {}, target);
                if (!session.transport().playing) timeline->revealEditPosition(true);
                moved = true;
            });
            return moved;
        });
    dockContent.addChildComponent(*midiPreviewPanel);
    keyboard = std::make_unique<FooterKeyboard>(session.audio.keyboardState, appearance);
    dockContent.addAndMakeVisible(*keyboard);
    keyboard->setVisible(false);
    vinhetasPanel = std::make_unique<VinhetasPanel>(session.audio.vinhetas, appearance);
    smk37=std::make_unique<SMK37Connection>(session.audio.devices,appearance);
    actions.claimedMIDI=[this](MidiInput *source,const MidiMessage &m){return smk37->claims(source,m);};
    smk37->action=[this](int pad){perform([&]{performSMK37(pad);});};
    smk37->previewStep=[this](int delta){if(!projectReady||loginPanel||browserVisible)return;stage.previewPage=jlimit(0,5,stage.previewPage+delta);const int first=stage.previewPage*4+1;smk37->feedback("BLOCO "+String(first)+"-"+String(first+3),0x55cfff);};
    smk37->playlistStep=[this](int delta){if(!projectReady||loginPanel||browserVisible||!actions.learning.isEmpty()||session.busy)return;perform([&]{
        if(!setlist->stepPlaylist(delta))return;
        if(session.project().regionSetlist)for(const auto &p:session.project().regionSetlist->playlists)if(session.project().regionSetlist->selectedId==p.id)smk37->feedback(text(p.name),0x409cff);
    });};
    smk37->fadeout=[this](bool active){if(!projectReady||loginPanel||browserVisible||!actions.learning.isEmpty()||session.busy)return;perform([&]{
        if(!session.transport().playing)return;
        const bool was=session.transportFadeoutActive();
        if(active==was)return;
        if(remotePresentation->fadeout)remotePresentation->fadeout(active);
        if(was&&!session.transportFadeoutActive())smk37->feedback("FADE OUT CANCELADO",0xffb347);
    });};
    smk37->padBusVolume=[this](int value){
        if(!projectReady||loginPanel||browserVisible||!actions.learning.isEmpty()||session.busy)return;
        if(const auto *song=session.song())for(const auto &track:song->tracks)if(track.role.id=="vinhetas"){
            const double gain=value==0?0:std::pow(10.0,(-60.0+jlimit(0,127,value)/127.0*60.0)/20.0);
            session.command(jaras::CommandKind::volume,track.id,gain);
            smk37->feedback("VINHETAS FX "+(gain<=0?String("-INF"):String(std::min(0.,20.*std::log10(gain)),1))+" dB");break;
        }
    };
    smk37->choosePreset=[this](int p){vinhetasPanel->select(p);};
    smk37->padDown=[this](const ID &token,int p,int n){if(projectReady&&!loginPanel&&!browserVisible&&actions.learning.isEmpty())vinhetasPanel->remoteDown(token,p,n);};
    smk37->padUp=[this](const ID &token){vinhetasPanel->remoteUp(token);};
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
    tracksViewport.doubleClicked=[this](const MouseEvent &event){mouseDoubleClick(event);};
    tracksViewport.wheel=[this](const MouseEvent &event,const MouseWheelDetails &details){mouseWheelMove(event,details);};
    tracksViewport.moved=[this] {
        const auto y=tracksViewport.getViewPositionY();
        if(y==verticalOffset)return;
        verticalOffset=y;timeline->scrollVerticallyTo(y);mixerDivider.refreshScroll();
    };
    for (auto *slider : std::initializer_list<Slider *>{&masterVolume, &masterPan, &zoom, &trackHeightSlider}) {
        addAndMakeVisible(*slider);
        slider->setSliderStyle(Slider::LinearHorizontal);
        slider->setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
    }
    masterVolume.setComponentID("masterVolume");
    masterVolume.setDoubleClickReturnValue(true, 1);
    masterVolume.setTooltip(String::fromUTF8("Main · volume"));
    masterVolume.onValueChange = [this] {
        perform([&] { session.command(jaras::CommandKind::volume, {}, masterVolume.getValue()); });
    };
    masterPan.setSliderStyle(Slider::RotaryVerticalDrag);
    masterPan.setRange(-1, 1, .01);
    masterPan.setDoubleClickReturnValue(true, 0);
    masterPan.setTooltip(String::fromUTF8("Master · pan"));
    masterPan.setColour(Slider::trackColourId, theme::secondary);
    masterPan.onValueChange = [this] {
        perform([&] { session.command(jaras::CommandKind::pan, {}, masterPan.getValue()); });
    };
    masterPan.setComponentID("masterPan");
    masterVolume.mapControl = [this] { mapMixerControl({}, jaras::CommandKind::volume); };
    zoom.setRange(timeline->minimumZoom(), timelineGrid::maximumZoom);
    zoom.setSkewFactorFromMidPoint(5);
    zoom.setValue(pixelsPerSecond, dontSendNotification);
    zoom.setComponentID("timeline-zoom-slider");
    zoom.setTitle(localization::translate("Timeline zoom"));
    zoom.setTooltip(String::fromUTF8("Zoom: rolagem · Altura das pistas: Ctrl+rolagem · Deslocar: Shift+rolagem"));
    zoom.onValueChange = [this] { timeline->zoomOnCursor(zoom.getValue()); };
    button("zoomOut", String::fromUTF8("−"), [this] { timeline->zoomOnCursor(pixelsPerSecond / 1.3); })
        .setTooltip("Diminuir zoom (-)");
    button("zoomIn", "+", [this] { timeline->zoomOnCursor(pixelsPerSecond * 1.3); })
        .setTooltip("Aumentar zoom (+)");
    auto &heightFit = button("trackHeightFit", {}, [this] {
        if (trackHeightMemory) {
            const int previous = *trackHeightMemory;
            trackHeightMemory.reset();
            controls.at("trackHeightFit")->setToggleState(false, dontSendNotification);
            timeline->setTrackHeight(previous);
        } else if (trackHeight > minimumTrackHeight()) {
            trackHeightMemory = trackHeight;
            controls.at("trackHeightFit")->setToggleState(true, dontSendNotification);
            timeline->setTrackHeight(minimumTrackHeight());
        }
    });
    heightFit.getProperties().set("icon", "fitTracks");
    heightFit.getProperties().set("iconSize", 15.f);
    heightFit.getProperties().set("zoomSegment", true);
    heightFit.setTitle(localization::translate("Toggle track height"));
    heightFit.setTooltip(heightFit.getTitle());
    auto &zoomFit = button("zoomFit", {}, [this] {
        if (zoomMemory) {
            const double previous = *zoomMemory;
            zoomMemory.reset();
            controls.at("zoomFit")->setToggleState(false, dontSendNotification);
            timeline->zoomOnCursor(previous);
        } else if (const auto minimum = timeline->minimumZoom(); pixelsPerSecond > minimum + .000001) {
            zoomMemory = pixelsPerSecond;
            controls.at("zoomFit")->setToggleState(true, dontSendNotification);
            timeline->zoomOnCursor(minimum);
        }
    });
    zoomFit.getProperties().set("icon", "fitTime");
    zoomFit.getProperties().set("iconSize", 15.f);
    zoomFit.getProperties().set("zoomSegment", true);
    zoom.getProperties().set("zoomAxis", "timelineZoomAxis");
    trackHeightSlider.getProperties().set("zoomAxis", "trackHeightAxis");
    zoomFit.setTitle(localization::translate("Toggle timeline zoom"));
    zoomFit.setTooltip(zoomFit.getTitle());
    trackHeightSlider.setComponentID("track-height-slider");
    trackHeightSlider.setTitle(localization::translate("Track height"));
    trackHeightSlider.setTooltip(trackHeightSlider.getTitle());
    trackHeightSlider.setRange(theme::trackMixerMinHeight, 240, 1);
    trackHeightSlider.setValue(trackHeight, dontSendNotification);
    trackHeightSlider.onValueChange = [this] { timeline->setTrackHeight((int)trackHeightSlider.getValue()); };
    for (auto *label : std::initializer_list<Label *>{&songDisplay, &transportTime, &transportInfo, &footer, &tempo}) {
        addAndMakeVisible(*label);
        label->setFont(theme::font(11));
    }
    transportInfo.setJustificationType(Justification::centredRight);
    transportInfo.setFont(theme::semiboldFont(13));
    transportInfo.setColour(Label::textColourId, theme::yellow);
    transportInfo.setColour(Label::backgroundColourId, Colours::transparentBlack);
    constexpr float readoutFontSize = 18;
    songDisplay.setFont(theme::semiboldFont(readoutFontSize));
    songDisplay.setJustificationType(Justification::centred);
    songDisplay.setColour(Label::textColourId, Colours::white);
    transportTime.setFont(songDisplay.getFont());
    transportTime.setColour(Label::textColourId, Colour(0xff54ff93));
    transportTime.setJustificationType(Justification::centredLeft);
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
    auto &fadeout = button("fadeout", "Fadeout", [this] { triggerTransportFadeout(); }, theme::yellow);
    fadeout.getProperties().set("flat", true);
    fadeout.getProperties().set("leadingIcon", "fadeout");
    fadeout.getProperties().set("centredIconLabel", true);
    fadeout.setColour(TextButton::textColourOffId, Colours::black);
    static_cast<QuietButton &>(fadeout).context = [this](Point<int>) { openTransportFadeout(); };
    button("pause", String::fromUTF8("Ⅱ"), [this] {
        session.command(jaras::CommandKind::pause);
    }).setTooltip(String::fromUTF8("Pause · P"));
    auto &editModeButton = button("editMode", {}, [this] {
        const bool enabled = !timelineEditMode;
        const auto result = appearance.set("jaras.timeline.editMode", enabled, false);
        if (result.failed()) throw std::runtime_error(utf8(result.getErrorMessage()));
        timelineEditMode = enabled;
        controls["editMode"]->setToggleState(enabled, dontSendNotification);
        if (!enabled && session.transport().beatSeek) session.command(jaras::CommandKind::cancelBeatSeek);
    }, Colour(0xff454545));
    editModeButton.setTitle("Edit");
    editModeButton.getProperties().set("icon", "editCursor");
    editModeButton.getProperties().set("iconSize", 17.f);
    editModeButton.getProperties().set("flat", true);
    editModeButton.getProperties().set("cornerRadius", 6.f);
    editModeButton.setColour(TextButton::buttonOnColourId, theme::green);
    editModeButton.setColour(TextButton::textColourOffId, Colours::white);
    editModeButton.setColour(TextButton::textColourOnId, Colours::black);
    editModeButton.setToggleState(timelineEditMode, dontSendNotification);
    auto &trackEnvelopes = button("track-envelopes", {}, [this] {
        const auto *song = session.song();
        if (!song) return;
        const auto songID = song->id;
        const bool showLanes = !automation::allTrackLanesVisible(*song);
        session.edit([&](jaras::Project &project) {
            for (auto &entry : project.songs) if (entry.id == songID)
                for (auto &track : entry.tracks)
                    if (automation::trackSupportsLanes(track) && automation::visible(track).isEmpty() == showLanes)
                        automation::toggle(track);
        });
    }, Colour(0xff454545));
    trackEnvelopes.setTitle(localization::translate("Track envelopes"));
    trackEnvelopes.setTooltip(trackEnvelopes.getTitle());
    trackEnvelopes.getProperties().set("icon", "automationLanes");
    trackEnvelopes.getProperties().set("iconSize", 17.f);
    trackEnvelopes.getProperties().set("flat", true);
    trackEnvelopes.setColour(TextButton::buttonOnColourId, theme::green);
    trackEnvelopes.setColour(TextButton::textColourOnId, Colours::black);
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
    for (const auto &entry : std::initializer_list<std::pair<const char *, const char *>>{
             {"projectStart", "Go to project start"}, {"previousTimelinePoint", "Previous marker or region boundary"},
             {"nextTimelinePoint", "Next marker or region boundary"}, {"projectEnd", "Go to project end"}}) {
        const String action(entry.first);
        auto &control = button(action, {}, [this, action] { performAction(action, 1, 0); }, Colour(0xff454545));
        const auto description = localization::translate(entry.second);
        control.setTitle(description);
        control.setTooltip(description);
        control.getProperties().set("icon", action);
        control.getProperties().set("iconSize", 15.f);
        control.getProperties().set("flat", true);
    }
    button("grandma2", "grandMA2", [this] { openGrandMA2(); });
    button("advanced", "Advanced", [this] { openAdvanced(); });
    auto &metronomeButton = button(
        "metronome", "",
        [this] {
            const bool active = !session.audio.metronomeEnabled.load();
            session.audio.metronomeEnabled = active;
            const SafePointer<Workspace> safe(this);
            appearance.setMetronome("jaras.metronome.enabled", active, [safe](String error) {
                if(safe&&error.isNotEmpty())safe->session.message=error;
            });
        },
        Colour(0xffc44848));
    button("metronomeMode", "A-B", [this] {
        const int mode = jlimit(0, 2, (int)appearance.value("jaras.metronome.mode", 0));
        const SafePointer<Workspace> safe(this);
        perform([this, mode, safe] {
            applyMetronomePreference(appearance, session.audio, "mode", (mode + 1) % 3,
                [safe](String error) {
                    if (safe && error.isNotEmpty()) safe->session.message = error;
                });
        });
    }, Colour(0xff454545)).setTitle(localization::translate("Click mode"));
    controls["metronomeMode"]->getProperties().set("fontSize", 10.f);
    controls["metronomeMode"]->getProperties().set("flat", true);
    metronomeButton.getProperties().set("icon", "metronome");
    metronomeButton.setTooltip(String::fromUTF8("Metrônomo · clique direito para configurar"));
    static_cast<QuietButton &>(metronomeButton).context = [this](Point<int>) {
        showPanel(String::fromUTF8("Metrônomo"),
                  std::make_unique<MetronomePanel>(appearance, session.audio), 400, 356);
    };
    button("resolume", "Resolume", [this] { openResolume(); });
    button("settings", String::fromUTF8("⚙"), [this] {
        openSettings();
    }).setTooltip(String::fromUTF8("Configurações · Ctrl+, "));
    button("audio", localization::translate(String::fromUTF8("Áudio")), [this] {
        openAudioSettings();
    }).setTooltip("Dispositivo, taxa de amostragem, buffer e roteamento ASIO / WASAPI");
    auto &audioStatus = button("audioStatus", "", [this] { openAudioSettings(); });
    static_cast<FooterAudioStatusButton &>(audioStatus).status = [this] {
        return audioFormatText(session.audio.devices);
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
            if (safe) safe->shareProject();
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
    static_cast<QuietButton &>(*controls["masterMute"]).context = [this](Point<int>) { mapMixerControl({}, jaras::CommandKind::mute); };
    static_cast<QuietButton &>(*controls["masterSolo"]).context = [this](Point<int>) { mapMixerControl({}, jaras::CommandKind::solo); };
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
    button("menu", "File", [this] { showFileMenu(); });
    button("library", "Library", [this] {
        libraryVisible = !libraryVisible;
        resized(); repaint(); saveWorkspaceLayout();
    });
    button("focus", "Track - I", [this] { toggleFocus(); });
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
            refreshToolbarPanelIndicators();
            return;
        }
        footerMixerVisible = !footerMixerVisible;
        resized();
        repaint();
    }).setTooltip("Hoz-Mixer");
    button("matrixPatch", "Matrix Patch", [this] {
        const auto* display = Desktop::getInstance().getDisplays().getDisplayForRect(getScreenBounds());
        const auto area = display ? display->userArea : juce::Rectangle<int>(0, 0, 1024, 768);
        openFloating("Matrix Patch", std::make_unique<MatrixPatchPanel>(session),
                     std::min(1000, std::max(480, area.getWidth() - 24)),
                     std::min(650, std::max(360, area.getHeight() - 64)));
    }).setTooltip("Matrix Patch");
    static_cast<QuietButton *>(controls["railMixer"])->context = [this](Point<int> point) { mixerMenu(point); };
    button("railParts", "Parts", [this] { toggleLeftParts(); }).setTooltip("Parts");
    static_cast<QuietButton *>(controls["railParts"])->context = [this](Point<int> point) { leftPartsMenu(point); };
    button("railVinhetas", "▦", [this] {
        const auto at = floatingWindows.find("Vinhetas");
        const bool opening = vinhetasDetached ? at != floatingWindows.end() && !at->second->isVisible() : !vinhetasVisible;
        if (opening) closePanelsForPads();
        if (vinhetasDetached) { if (at != floatingWindows.end()) at->second->setVisible(opening); }
        else vinhetasVisible = opening;
        resized();
    });
    static_cast<QuietButton &>(*controls["railVinhetas"]).context=[this](Point<int>){
        PopupMenu menu;menu.addItem(1,vinhetasDetached?localization::translate("Indexar"):localization::translate("Desindexar"));
        auto safe=Component::SafePointer<Workspace>(this);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(controls["railVinhetas"]),[safe](int result){if(safe&&result==1)safe->toggleVinhetasDock();});
    };
    button("midiPreview","MIDI Preview",[this] {
        const auto at = floatingWindows.find("MIDI Preview");
        const bool opening = midiPreviewDetached ? at != floatingWindows.end() && !at->second->isVisible() : !midiPreviewVisible;
        if (opening) closePads();
        if (midiPreviewDetached) { if (at != floatingWindows.end()) at->second->setVisible(opening); }
        else midiPreviewVisible = opening;
        resized();
    });
    static_cast<QuietButton &>(*controls["midiPreview"]).context=[this](Point<int>){
        PopupMenu menu; menu.addItem(1,localization::translate(midiPreviewDetached?"Indexar":"Desindexar"));
        auto safe = Component::SafePointer<Workspace>(this);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(controls["midiPreview"]),
            [safe](int choice){if(safe && choice==1)safe->toggleMIDIPreviewDock();});
    };
    button("railKeyboard", String::fromUTF8("♮"), [this] {
        if (!keyboardVisible) closePads();
        keyboardVisible = !keyboardVisible;
        resized();
        repaint();
    }).setTooltip("Keyboard");
    static_cast<QuietButton &>(*controls["railKeyboard"]).context = [this](Point<int>) {
        auto panel = std::make_unique<AdvancedPanel>(appearance, session,
            [this](const String &message) { showError(message, "Keyboard"); }, AdvancedPanel::Presentation::keyboard);
        ModalSheet::open(*this, "Keyboard", std::move(panel), 340, 186);
    };
    button("soundfont", "SF2", [this] { chooseSoundFont(); });
    button("video", localization::translate("Video"), [this] { openVideo(); }).setTitle(localization::translate("Video"));
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
    button("tp1", "TP1", [this] { showTeleprompter(1); }, Colour(0xffc44848));
    button("tp2", "TP2", [this] { showTeleprompter(2); }, Colour(0xffc44848));
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
    static_cast<QuietButton &>(remoteButton).context = [this](Point<int>) { openRemote(); };
    button("railNotice", "", [this] { openNotices(); });
    button("railClock", "", [this] { openTimer(true); });
    controls["railNotice"]->setTooltip("Recados");
    controls["railClock"]->setTooltip(String::fromUTF8("Cronômetro"));
    controls["railNotice"]->getProperties().set("plain", true);
    controls["railClock"]->getProperties().set("plain", true);
    button("railTeleprompt2", "TP2", [this] { showTeleprompter(2); }).setTooltip("TP 2 - Teleprompter 2");
    controls["railTeleprompt"]->setButtonText("TP1");
    button("railSettings", String::fromUTF8("⚙"), [this] {
        openSettings();
    }).setTooltip(String::fromUTF8("Configurações"));
    button("railHelp", "?", [this] { showShortcuts(); }).setTooltip(localization::translate("Atalhos"));
    for (auto id : {"loop", "pause"})
        controls[id]->getProperties().set("icon", id);
    controls["play"]->setTitle("Play");
    for (auto id : {"menu", "mixer", "railMixer", "matrixPatch", "railKeyboard", "railParts", "railVinhetas", "settings",
                    "railTeleprompt", "railTeleprompt2", "advanced", "grandma2", "resolume",
                    "tp1", "tp2", "preview", "video", "remote"})
        controls[id]->getProperties().set("plain", true);
    for (auto id : {"play", "pause", "loop", "record", "metronome",
                    "save", "setlist",
                    "masterMute", "masterSolo", "masterMono", "masterPatch", "masterFX"})
        controls[id]->getProperties().set("flat", true);
    for (auto id : {"railTeleprompt", "railTeleprompt2"})
        controls[id]->setColour(TextButton::textColourOffId, Colour(0xffff5555));
    controls["menu"]->getProperties().set("toolbarLabel", true);
    for(const auto &entry:std::initializer_list<std::pair<const char*,const char*>>{
            {"library","Library"},{"focus","Track - I"},{"mixer","Track Mixer"},{"railMixer","Hoz Mixer"},{"matrixPatch","Matrix Patch"},{"railParts","Parts"},
            {"railNotice","Recados"},{"railKeyboard","Keyboard"},{"railVinhetas","Pads"},{"railClock","Timer"},{"settings","Configurações"},
            {"advanced","Advanced"},{"grandma2","grandMA2"},{"resolume","Resolume"},
            {"tp1","TP1"},{"tp2","TP2"},{"preview","Preview"},{"remote","Remote"}}) {
        auto *control = controls[entry.first];
        const auto label = String::fromUTF8(entry.second);
        const auto translated = label == "Keyboard" || label == "Timer" || label == "Track" ? label : localization::translate(label);
        control->setTooltip({});
        control->setButtonText(translated);
        control->setTitle(translated);
        control->getProperties().set("fontSize", 11.f);
        control->getProperties().set("toolbarLabel", true);
        control->setColour(TextButton::textColourOffId, Colours::white);
        control->setColour(TextButton::textColourOnId, Colours::white);
    }
    controls["settings"]->setButtonText({});
    controls["settings"]->getProperties().set("icon", "gearshape");
    controls["settings"]->getProperties().set("iconSize", 15.f);
    controls["video"]->getProperties().set("toolbarLabel", true);
    controls["video"]->setColour(TextButton::textColourOffId, Colours::white);
    controls["setlist"]->setColour(TextButton::buttonColourId, theme::green);
    controls["setlist"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["loop"]->setColour(TextButton::buttonColourId, Colour(0xff454545));
    controls["loop"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["loop"]->setColour(TextButton::textColourOffId, Colours::black);
    controls["loop"]->setColour(TextButton::textColourOnId, Colours::black);
    controls["play"]->getProperties().set("transportColour", (int64)theme::transportPlay.getARGB());
    controls["pause"]->setColour(TextButton::buttonColourId, theme::yellow);
    controls["pause"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["pause"]->setColour(TextButton::textColourOnId, Colours::black);
    for (auto id : {"masterMono", "masterPatch", "masterFX", "masterMute", "masterSolo"}) {
        auto &control = *controls[id];
        const bool compact = String(id) == "masterMute" || String(id) == "masterSolo";
        control.getProperties().set("macMasterControl", true);
        control.setColour(TextButton::buttonColourId, theme::trackControl);
        control.setColour(TextButton::textColourOffId, Colours::white);
        control.setColour(TextButton::textColourOnId, compact ? Colours::black : theme::green);
    }
    controls["masterMono"]->setColour(TextButton::buttonOnColourId, theme::trackControl);
    controls["masterMute"]->setColour(TextButton::buttonOnColourId, Colour(0xffff4245));
    controls["masterSolo"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["metronome"]->setColour(TextButton::buttonOnColourId, theme::yellow);
    controls["metronome"]->setColour(TextButton::textColourOffId, Colours::white);
    controls["metronome"]->setColour(TextButton::textColourOnId, Colours::black);
    controls["metronome"]->setColour(TextButton::buttonColourId, Colour(0xff454545));
    for (auto id : {"tp1", "tp2", "preview", "video", "remote"})
        controls[id]->setColour(TextButton::buttonColourId, Colours::transparentBlack);
    controls["record"]->setColour(TextButton::textColourOffId, Colours::white);
    controls["record"]->setColour(TextButton::textColourOnId, Colours::black);
    controls["record"]->setColour(TextButton::buttonColourId, Colour(0xff454545));
    controls["record"]->setTitle(localization::translate("Record"));
    controls["record"]->setButtonText("REC");
    for (auto spec : std::initializer_list<std::pair<const char *, const char *>>{
             {"play", "play"}, {"record", "record"},
             {"save", "save"},
             {"video", "video"}, {"remote", "dot.radiowaves.left.and.right"}}) {
        controls[spec.first]->getProperties().set("leadingIcon", spec.second);
        controls[spec.first]->getProperties().set("centredIconLabel", true);
    }
    for (const auto &[id, symbol] : std::initializer_list<std::pair<const char*,const char*>>{
            {"menu","line.3.horizontal"},{"library","books.vertical"},{"focus","sidebar.left"},
            {"mixer","slider.horizontal.3"},{"railMixer","slider.vertical.3"},{"matrixPatch","square.grid.3x3"},
            {"railParts","list.bullet.indent"},{"railNotice","text.bubble"},{"railClock","stopwatch"},
            {"railKeyboard","pianokeys"},{"railVinhetas","square.grid.3x2.fill"},{"midiPreview","midiPreview"},
            {"advanced","info.circle"},{"grandma2","stageLights"},{"resolume","projection"},
            {"tp1","teleprompter1"},{"tp2","teleprompter2"},{"preview","eye"},{"video","video"},
            {"remote","dot.radiowaves.left.and.right"},{"settings","gearshape"}}) {
        auto &control = *controls[id];
        control.getProperties().set("toolbarLabel", true);
        control.getProperties().set("icon", symbol);
        if (&control != controls["menu"])
            control.setTooltip(control.getButtonText().isNotEmpty() ? control.getButtonText() : control.getTitle());
    }
    controls["menu"]->setTooltip({});
    addTrack.setButtonText("Add");
    addTrack.getProperties().set("iconSize", 14.f);
    addTrack.getProperties().set("icon", "addTrack");
    addTrack.setTitle(localization::translate("Add Track"));
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
    timelineTimebase.getProperties().set("borderAlpha", .23f);
    timelineTimebase.setWantsKeyboardFocus(false);
    timelineTimebase.setColour(TextButton::buttonColourId, Colour(0xff454545));
    timelineTimebase.setColour(TextButton::buttonOnColourId, Colour(0xff454545));
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
    timelineSnap.getProperties().set("borderAlpha", .23f);
    timelineSnap.setColour(TextButton::buttonColourId, Colour(0xff454545));
    timelineSnap.setColour(TextButton::buttonOnColourId, Colour(0xff454545));
    timelineSnap.setWantsKeyboardFocus(false);
    timelineSnap.setColour(TextButton::textColourOnId, theme::green);
    timelineSnap.setColour(TextButton::textColourOffId, Colours::grey);
    timelineSnap.onClick = [this] {
        const auto result=appearance.set("jaras.timeline.snapEnabled", !(bool)appearance.value("jaras.timeline.snapEnabled",true));
        if (result.failed()) showError(result.getErrorMessage());
        updateState();
    };
    addAndMakeVisible(timelineBands);
    timelineBands.setComponentID("timeline-lanes");
    timelineBands.getProperties().set("icon", "timelineLanes");
    timelineBands.getProperties().set("iconSize", 22.f);
    timelineBands.setTooltip("Hide/View - Region/Markers");
    timelineBands.getProperties().set("cornerRadius", 4.f);
    timelineBands.getProperties().set("flat", true);
    timelineBands.setColour(TextButton::buttonColourId, Colours::white.withAlpha(.12f));
    timelineBands.setTitle(localization::translate("Timeline lanes"));
    timelineBands.setWantsKeyboardFocus(false);
    timelineBands.onClick = [this] {
        PopupMenu menu;
        menu.addItem(1, "Region", true, showRegionLanes);
        menu.addItem(2, "Tempo", true, showTempoLane);
        const SafePointer<Workspace> safe(this);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&timelineBands),
            [safe](int choice) {
                if (!safe || (choice != 1 && choice != 2)) return;
                auto &visible = choice == 1 ? safe->showRegionLanes : safe->showTempoLane;
                const auto key = choice == 1 ? "jaras.timeline.showRegionLanes" : "jaras.timeline.showTempoLane";
                const auto result = safe->appearance.set(key, !visible);
                if (result.failed()) { safe->showError(result.getErrorMessage()); return; }
                safe->timeline->cancelInteraction();
                visible = !visible;
                safe->timelineBands.setToggleState(safe->showRegionLanes || safe->showTempoLane, dontSendNotification);
                safe->resized();
                safe->timeline->updateRanges();
                safe->timeline->invalidate();
                safe->repaint();
            });
    };
    addAndMakeVisible(trackVisibilityButton);
    trackVisibilityButton.setComponentID("trackVisibilityManager");
    trackVisibilityButton.getProperties().set("icon","visibility");
    trackVisibilityButton.getProperties().set("flat",true);
    trackVisibilityButton.setWantsKeyboardFocus(false);
    trackVisibilityButton.setTooltip("Hide/View-Tracks");
    trackVisibilityButton.onClick=[this]{openTrackVisibility();};
    timelineLock.onClick = [this] { perform([&] { session.edit([](jaras::Project &p) {
        p.timelineMovementLocked = !p.timelineMovementLocked.value_or(false);
    }, false); }); };
    timelineLock.context = [this](Point<int>) {
        if (!projectReady || session.busy || session.audio.isRecording()) return;
        auto safe=SafePointer<Workspace>(this);
        auto panel=std::make_unique<TimelineLockPanel>([safe] { return safe ? safe->session.project().configuredTimelineLocks() : 7; }, [safe](int options) {
            if(!safe || safe->session.busy || safe->session.audio.isRecording())return;
            safe->perform([&] { safe->session.edit([=](jaras::Project &p) {
                p.timelineLockOptions=options&7;
            },false); });
        });
        CallOutBox::launchAsynchronously(std::move(panel),timelineLock.getScreenBounds(),nullptr);
    };
    projectBrowser = std::make_unique<ProjectBrowser>();
    addChildComponent(*projectBrowser);
    projectBrowser->createEmpty = [this] { createProject(false); };
    projectBrowser->createTemporary = [this] { createTemporaryProject(); };
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
    projectBrowser->openMultiple = [this](std::vector<File> files) { if(openMultipleProjectTabs)openMultipleProjectTabs(std::move(files)); };
    projectBrowser->openInNewTab = [this](File file) { if (projectReady && openInNewProjectTab) openInNewProjectTab(file); };
    projectBrowser->deleteProject = [this](File file) { deleteRecentProject(file); };
    projectBrowser->resume = [this] { returnToWorkspace(); };
    projectReady = session.inspection && !homePreview;
    browserVisible = !projectReady;
    session.changed = [this] {
        rebuild();
        updateState();
    };
    session.timingChanged = [this](bool geometry) {
        if (geometry) {
            timeline->refreshTimingGeometry(); setlist->refresh();
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
        if(rowGeometryRevision+1==session.revision)rowGeometryRevision=session.revision;
        tempoControl->retainTempoAfterMixerChange();
        for(auto* row:rows)row->refreshMixer();
        if(footerMixerVisible)footerMixer->refreshVisible();
        if(focusVisible)focusMixer->refreshVisible();
        for(const auto& entry:floatingWindows)
            if(auto* mixer=dynamic_cast<MixerPanel*>(entry.second->getContentComponent()))mixer->refreshVisible();
        timeline->refreshMixer();caption->repaint();updateState();
    };
    session.setlistChanged = [this] { refreshPlaybackState(); };
    session.transportChanged = [this] { refreshPlaybackState(); };
    session.selectionChanged = [this] {
        setlist->refresh();
        repaint(footerBounds);
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
    mixerWidth = jlimit(theme::trackMixerMinWidth, 900, (int)appearance.value("jaras.trackColumnWidth", 281));
    setlistWidth = jlimit(minimumSetlistWidth, 900, (int)appearance.value("jaras.setlistWidth", 336));
    horizontalPartsHeight = jlimit(PartsPanel::defaultHorizontalHeight, PartsPanel::maximumHorizontalHeight,
        (int)appearance.value("catlive.horizontalPartsHeight", PartsPanel::defaultHorizontalHeight));
    partsLeftWidth = jlimit(160,900,(int)appearance.value("catlive.partsLeftWidth",260));
    partsRightWidth = (int)appearance.value("catlive.partsRightWidth",0);
    if (partsRightWidth>0) partsRightWidth=jlimit(160,900,partsRightWidth);
    footerHeightSetting = jlimit(27, 161, (int)appearance.value("catlive.footerDisplayHeight", 27));
    mixerHeightSetting = jlimit(273, 724, (int)appearance.value("jaras.footerMixerHeight", 300));
    auto bindDivider = [this](DragDivider &divider, const String &id, int &value, int minimum, int maximum, int sign, const String &key) {
        addAndMakeVisible(divider); divider.setComponentID(id);
        divider.started = [this, &value] { resizeStart = value; };
        divider.moved = [this, &value, minimum, maximum, sign](int delta) {
            const int next=jlimit(minimum,maximum,resizeStart+sign*delta);
            if(value==next)return;
            value=next;resized();repaint();
        };
        divider.ended = [this, &value, key] { if (key.isNotEmpty()) appearance.set(key, value); };
    };
    bindDivider(mixerDivider, "trackMixerDivider", mixerWidth, theme::trackMixerMinWidth, 900, 1, "jaras.trackColumnWidth");
    bindDivider(setlistDivider, "setlistDivider", setlistWidth, minimumSetlistWidth, 900, -1, "jaras.setlistWidth");
    mixerDivider.setScrollRailVisible(false);
    setlistDivider.setScrollRailVisible(false);
    mixerDivider.setRailVisible(false);
    setlistDivider.setRailVisible(false);
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
    mixerHeightDivider.started = [this] { resizeStart = footerMixer->getHeight(); };
    mixerHeightDivider.moved = [this](int delta) {
        const int next = jlimit(std::min(273, mixerHeightLimit), mixerHeightLimit, resizeStart - delta);
        if (next == footerMixer->getHeight()) return;
        mixerHeightSetting = next;
        resized(); repaint();
    };
    mixerHeightDivider.setCoalescedResize(true);
    midiPreviewHeight = jlimit(273,724,(int)appearance.value("catlive.midiPreview.height",273));
    bindDivider(midiPreviewDivider,"midiPreviewHeightDivider",midiPreviewHeight,273,724,-1,"catlive.midiPreview.height");
    midiPreviewDivider.started = [this] { resizeStart = midiPreviewPanel->getHeight() + midiPreviewDivider.getHeight(); };
    midiPreviewDivider.moved = [this](int delta) {
        const int next = jlimit(std::min(273, midiPreviewHeightLimit), midiPreviewHeightLimit, resizeStart - delta);
        if (next == midiPreviewHeight) return;
        midiPreviewHeight = next;
        resized();
    };
    midiPreviewDivider.setCoalescedResize(true);
    dockContent.addChildComponent(midiPreviewDivider);
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
    put(state,"partsHorizontal",partsLeftHorizontal); put(state,"partsDetached",partsLeftDetached); put(state,"partsOpen",partsLeftVisible);
    put(state,"partsRightOpen",partsRightVisible); put(state,"focusOpen",focusVisible);
    put(state,"libraryOpen",libraryVisible); put(state,"libraryWidth",libraryWidth);
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
    refreshInterfaceTheme();
    syncHozMixerTrackStyle();
    const auto state=appearance.value("jaras.workspace.layout");
    if (!state.isObject()) return;
    mixerVisible=flag(state,"tracksVisible",true); setlistVisible=flag(state,"setlistVisible",true);
    footerMixerVisible=flag(state,"mixerOpen"); mixerDetached=flag(state,"mixerDetached");
    partsLeftVisible=flag(state,"partsOpen"); partsRightVisible=flag(state,"partsRightOpen");
    partsLeftHorizontal=flag(state,"partsHorizontal");
    focusVisible=flag(state,"focusOpen") && (!partsLeftVisible || partsLeftHorizontal);
    libraryVisible=flag(state,"libraryOpen");
    libraryWidth=std::max(190, int(num(state,"libraryWidth",344)));
    if (partsLeftHorizontal && partsLeftVisible) partsRightVisible = false;
    partsLeftDetached=!partsLeftHorizontal && flag(state,"partsDetached");
    mixerWidth=jlimit(theme::trackMixerMinWidth,900,(int)appearance.value("jaras.trackColumnWidth",num(state,"trackWidth",mixerWidth)));
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
        if (vinhetasVisible || (wantedVinhetasDetached && flag(state,"VinhetasVisible",true))) closePanelsForPads();
        const bool showSetlist=setlistVisible, showParts=partsLeftVisible;
        setSetlistPlacement(placement);
        setlistDockSide=(SetlistPlacement)jlimit(0,1,(int)num(state,"setlistDockSide",0));
        setlistVisible=showSetlist; partsLeftVisible=showParts;
        if (setlistWindow && str(state,"SetlistFrame").isNotEmpty())
            setlistWindow->restoreWindowStateFromString(str(state,"SetlistFrame"));
        if (mixerDetached && flag(state,"MixerVisible",true)) showDetachedMixer();
        else if (auto at=floatingWindows.find("Mixer");at!=floatingWindows.end()) at->second->setVisible(false);
        if (!focusVisible && partsLeftDetached && flag(state,"PartsVisible",true)) detachLeftParts();
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
    lighting.setIntegrationForeground(false);
    saveWorkspaceLayout();
    layoutActive = false;
    workspaceLibrary->setVisible(false);
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
    lighting.setIntegrationForeground(true);
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
    toolbarTooltips.reset();
    dockViewport.scrolled = {};
    if(smk37)smk37->shutdown();
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
    const bool resizablePanel=dynamic_cast<EffectsPanel *>(panel.get()) || dynamic_cast<Projection *>(panel.get()) || name=="Mixer" || name=="Parts" || name=="MIDI Preview" || name=="Vinhetas";
    DialogWindow::LaunchOptions options;
    options.content.setOwned(panel.release());
    options.dialogTitle = name;
    options.dialogBackgroundColour = theme::background;
    options.useNativeTitleBar = false;
    options.resizable = resizablePanel;
    options.useBottomRightCornerResizer = false;
    auto *window = options.launchAsync();
    if(resizablePanel)window->setResizeLimits(width, height, 2560, 1440);
    else window->setResizeLimits(window->getWidth(),window->getHeight(),window->getWidth(),window->getHeight());
    window->setAlwaysOnTop(false);
}
void Workspace::openFloating(const String &name, std::unique_ptr<Component> panel, int width,
                             int height, const String &key) {
    const auto storageKey = key.isEmpty() ? name : key;
    if (auto it = floatingWindows.find(storageKey);
        it != floatingWindows.end() && it->second->isVisible()) {
        // A Patch request may target another track while the previous window
        // stays open. Replace the editor, preserving its placement.
        if (name == "Patch" || name == "Timecode") {
            panel->setSize(width, height);
            const auto border=it->second->getContentComponentBorder();
            it->second->setResizeLimits(width+border.getLeftAndRight(),height+border.getTopAndBottom(),width+border.getLeftAndRight(),height+border.getTopAndBottom());
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
        PanelWindow(const String &title, bool frameless, bool resizable)
            : DocumentWindow(title, theme::background, frameless ? 0 : resizable ? DocumentWindow::allButtons : DocumentWindow::closeButton | DocumentWindow::minimiseButton, false) {
            setUsingNativeTitleBar(false);
            setTitleBarButtonsRequired(frameless ? 0 : resizable ? DocumentWindow::allButtons : DocumentWindow::closeButton | DocumentWindow::minimiseButton, false);
            setTitleBarHeight(frameless ? 0 : 32);
            setResizable(resizable && !frameless, false);
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
    const bool resizablePanel = effectsPanel || dynamic_cast<Projection *>(panel.get()) ||
        name=="Mixer" || name=="Parts" || name=="MIDI Preview" || name=="Vinhetas" || name=="Matrix Patch";
    auto window = std::make_unique<PanelWindow>(patchPanel ? static_cast<PatchPanel*>(panel.get())->windowTitle() : localization::translate(name == "Mixer" ? "Hoz-Mixer" : name), patchPanel, resizablePanel);
    auto *settings = dynamic_cast<SettingsPanel *>(panel.get());
    const bool preferencesPanel = settings || dynamic_cast<AdvancedPanel *>(panel.get());
    window->escapeCloses = preferencesPanel || name == "Editor de texto" || name == "Patch" || name == "Timecode" || name == "Matrix Patch" || name == "Exportar";
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
    } else if (preferencesPanel || name == "Parts" || name == "Patch" || name == "Timecode" || name == "Matrix Patch") {
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
    if (resizablePanel) {
        if (name == "Matrix Patch") {
            window->setResizeLimits(640 + contentBorder.getLeftAndRight(), 420 + contentBorder.getTopAndBottom(), 32768, 32768);
        } else window->setResizeLimits(effectsPanel ? EffectsPanel::minimumContentWidth + contentBorder.getLeftAndRight() : preferencesPanel ? width : name.startsWith("Piano Roll") ? 760 : 360,
                                effectsPanel ? EffectsPanel::minimumContentHeight + contentBorder.getTopAndBottom() : preferencesPanel ? height + 32 : name.startsWith("Piano Roll") ? 440 : name == "Mixer" ? 305 : 240, 3840, 2160);
        window->centreAroundComponent(this, effectsPanel ? width + contentBorder.getLeftAndRight() : width,
                                      effectsPanel ? height + contentBorder.getTopAndBottom() : height + (patchPanel ? 0 : 32));
    } else {
        const int frameWidth=width+contentBorder.getLeftAndRight(), frameHeight=height+contentBorder.getTopAndBottom();
        window->setResizeLimits(frameWidth,frameHeight,frameWidth,frameHeight);
        window->centreAroundComponent(this,frameWidth,frameHeight);
    }
    if (savedPlacement.isNotEmpty()) window->restoreWindowStateFromString(savedPlacement);
    window->onClose = [safe = SafePointer<Workspace>(this), name, preferencesPanel,
                       closed = SafePointer<DocumentWindow>(window.get()),
                       settings = SafePointer<SettingsPanel>(settings)] {
        if (safe && closed && (name == "Mixer" || name == "Parts"))
            safe->appearance.set("jaras.detached." + name, closed->getWindowStateAsString());
        if (settings) settings->cancelLearning();
        if (closed)
            if (auto *exportPanel = dynamic_cast<ExportPanel *>(closed->getContentComponent()))
                exportPanel->savePreferences();
        if (safe && name == "Recados" && !safe->stage.stoppedNoticeActive) safe->stage.clearNotice();
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
    // Owned windows stay above this workspace without becoming globally topmost.
    // Set ownership before showing, including Advanced, Patch and text editors.
    if (!independentWorkspaceWindow(name, window->getContentComponent()))
        if (auto *mainPeer = getPeer())
            if (auto *toolPeer = window->getPeer())
                SetWindowLongPtrW(static_cast<HWND>(toolPeer->getNativeHandle()), GWLP_HWNDPARENT,
                                  reinterpret_cast<LONG_PTR>(mainPeer->getNativeHandle()));
    window->setVisible(true);
    window->toFront(true);
    floatingWindows[storageKey] = std::move(window);
    refreshToolbarPanelIndicators();
}
void Workspace::syncNativeTransport() {
    if (!nativeTransport) return;
    auto *peer = getPeer();
    const bool visible = isShowing() && peer && projectReady && !loginPanel && !audioPreparationOverlay;
    if (!visible) { nativeTransport->hide(); return; }
    // Match ComponentPeer::handlePaint: the peer size includes the application
    // scale, while getLocalArea is still in component coordinates. Monitor DPI
    // alone is insufficient when General is set to 60–120%.
    const auto peerBounds = peer->getBounds();
    const auto componentBounds = peer->getComponent().getLocalBounds();
    const float scaleX = (float)peer->getPlatformScaleFactor() * peerBounds.getWidth() / std::max(1, componentBounds.getWidth());
    const float scaleY = (float)peer->getPlatformScaleFactor() * peerBounds.getHeight() / std::max(1, componentBounds.getHeight());
    size_t index = 0;
    for (auto id : {"play", "fadeout", "pause", "loop", "record", "metronome", "save", "setlist"}) {
        const auto control = controls.find(id);
        if (control == controls.end() || control->second == nullptr) continue;
        auto *model = control->second;
        const auto area = peer->getComponent().getLocalArea(this, model->getBounds()).toFloat()
            .transformedBy(AffineTransform::scale(scaleX, scaleY)).getSmallestIntegerContainer();
        native::TransportButtons::State state;
        state.surface = theme::panel.getARGB();
        const bool onTempoPanel = tempoDisplayBounds.contains(model->getBounds());
        const auto surfaceBounds = onTempoPanel ? tempoDisplayBounds : transportDisplayBounds;
        if (surfaceBounds.contains(model->getBounds())) {
            const auto panelColourAt = [&](int y) {
                const auto proportion = (float)(y - surfaceBounds.getY()) / surfaceBounds.getHeight();
                const bool dark = theme::background == theme::darkBackground;
                const auto top = onTempoPanel ? theme::transportDetailTop : dark ? theme::background : theme::transportPanelTop;
                const auto bottom = onTempoPanel ? theme::transportDetailBottom : dark ? theme::background : theme::transportPanelBottom;
                return top.interpolatedWith(bottom, proportion).getARGB();
            };
            state.surface = panelColourAt(model->getY());
            state.surfaceBottom = panelColourAt(model->getBottom());
        }
        state.rect = {area.getX(), area.getY(), area.getRight(), area.getBottom()};
        state.scale = scaleY;
        state.dimming=1.f-model->getAlpha();
        state.savePulse=String(id)=="save" && session.dirty;
        state.fontSize = theme::semiboldFont((float)model->getProperties().getWithDefault("fontSize", 10.f)).getHeightInPoints();
        state.active = model->getToggleState() || (bool)model->getProperties()["solidTransportColour"]; state.enabled = model->isEnabled();
        state.blocked = Component::getCurrentlyModalComponent() != nullptr;
        if (browserVisible && projectBrowser->getBounds().intersects(model->getBounds())) state.visible = false;
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
        if (String(id) == "record" && !state.active) state.iconForeground = theme::liveOffRed.getARGB();
        state.accent = (uint32)(int64)model->getProperties()["transportColour"];
        auto icon = model->getProperties()["leadingIcon"].toString();
        if (icon.isEmpty() && StringArray{"play", "pause", "loop", "record", "metronome"}.contains(id)) icon = id;
        state.icon = icon.toWideCharPointer();
        static const StringArray pngIcons{"play","stopall","fadeout","pause","loop","record"};
        if (pngIcons.contains(icon)) {
            // Native transport HWNDs own their render targets. Share immutable PNG pixels between them.
            static const auto bitmaps = [] {
                std::map<std::pair<String,bool>, std::vector<unsigned>> result;
                for (const auto& key : pngIcons) for (const bool on : {false,true}) {
                    const auto image = controlArtwork(key,on);
                    auto& pixels = result[{key,on}];
                    if (!image.isValid()) continue;
                    Image::BitmapData data(image, Image::BitmapData::readOnly);
                    pixels.reserve(data.width * data.height);
                    for (int y=0; y<data.height; ++y) for (int x=0; x<data.width; ++x)
                        pixels.push_back(data.getPixelColour(x,y).getPixelARGB().getNativeARGB());
                }
                return result;
            }();
            const auto& pixels = bitmaps.at({icon,state.active});
            state.iconWidth = (unsigned)std::sqrt(pixels.size());
            state.iconPixels = pixels.empty() ? nullptr : pixels.data();
        }
        if (!StringArray{"pause", "loop", "metronome"}.contains(id)) state.text = model->getButtonText().toWideCharPointer();
        state.tooltip = localization::translate(model->getTooltip()).toWideCharPointer();
        nativeTransport->update(index++, (HWND)peer->getNativeHandle(), state,
            [safe = SafePointer<Workspace>(this), button = SafePointer<QuietButton>(static_cast<QuietButton *>(model))](bool right) {
            if (!safe || !button || Component::getCurrentlyModalComponent()) return;
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
    if (!projectReady || loginPanel)
        return;
    g.setColour(theme::panel);
    g.fillRect(transportBounds);
    const auto toolTop = caption->getBottom();
    g.setColour(workspaceToolbarColour());
    g.fillRect(0, toolTop, getWidth(), transportBounds.getY() - toolTop);
    g.setColour(theme::panel);
    g.fillRect(footerBounds);
    g.fillRect(tracksViewport.getX(), workspaceBounds.getY(), tracksViewport.getWidth(), workspaceBounds.getHeight());
    if (g.clipRegionIntersects(footerBounds)) {
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
            if (const auto *internalNext = nextUnifiedSong(*song,state))
                nextName = regionCaption(*song,internalNext);
            for (const auto &part : song->parts) {
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
    if (theme::background == theme::darkBackground) g.setColour(theme::background);
    else g.setGradientFill(ColourGradient(theme::transportPanelTop, 0, (float)transportDisplayBounds.getY(),
                                         theme::transportPanelBottom, 0, (float)transportDisplayBounds.getBottom(), false));
    g.fillRoundedRectangle(transportDisplayBounds.toFloat(), 7);
    g.setColour(theme::transportPanelBorder);
    g.drawRoundedRectangle(transportDisplayBounds.toFloat().reduced(.5f), 7, 1);
    if (transportProgressPixels >= 0) {
        const auto lane = transportProgressBounds();
        g.setColour(Colours::white.withAlpha(.12f));
        g.fillRect(lane);
        g.setColour(theme::green);
        g.fillRect(lane.withWidth(std::min(lane.getWidth(), transportProgressPixels)));
    }
    for (auto bounds : {tempoDisplayBounds, tuner->getBounds()}) {
        if (bounds.isEmpty() || !g.clipRegionIntersects(bounds)) continue;
        g.setGradientFill(ColourGradient(theme::transportDetailTop, 0, (float)bounds.getY(),
                                        theme::transportDetailBottom, 0, (float)bounds.getBottom(), false));
        g.fillRoundedRectangle(bounds.toFloat(), 4);
        g.setColour(theme::transportDetailBorder);
        g.drawRoundedRectangle(bounds.toFloat().reduced(.5f), 4, 1);
    }
    const auto fits = controls.at("trackHeightFit")->getBounds().getUnion(controls.at("zoomFit")->getBounds());
    const auto sliders = trackHeightSlider.getBounds().getUnion(zoom.getBounds());
    g.setColour(Colour(0xff4c4c4c)); g.fillRoundedRectangle(fits.toFloat(), 4.f);
    g.setColour(Colour(0xff343434)); g.fillRoundedRectangle(sliders.toFloat(), 4.f);
    g.setColour(Colour(0xff393939)); g.drawVerticalLine(fits.getCentreX(), float(fits.getY() + 1), float(fits.getBottom() - 1));
    g.setColour(Colour(0xff242424)); g.drawVerticalLine(zoom.getX(), float(sliders.getY() + 1), float(sliders.getBottom() - 1));
    g.setColour(theme::line);
    g.drawHorizontalLine(transportBounds.getY() - 1, 0, (float)getWidth());
    g.drawHorizontalLine(transportBounds.getBottom(), 0, (float)getWidth());
    {
    Graphics::ScopedSaveState masterState(g);
    g.addTransform(AffineTransform::translation((float)transportBounds.getX(),
                                                (float)transportBounds.getY()));
    const auto masterColour = theme::mixerStripeSurface;
    g.setColour(masterColour);
    g.fillRoundedRectangle(4, 8, mainStripWidth, 70, 5);
    g.setColour(theme::surfaceText(masterColour));
    g.setFont(theme::semiboldFont(11));
    g.drawText("Main", 4, 37, mainStripWidth, 18, Justification::centred);
    }
    if (mixerVisible) {
        g.setColour(theme::panel);
        g.fillRect(tracksViewport.getX(), workspaceBounds.getY(), tracksViewport.getWidth(), timeline->headerHeight());
        const int x = tracksViewport.getX(), y = workspaceBounds.getY();
        const int right = tracksViewport.getRight();
        g.setFont(theme::semiboldFont(12).withPointHeight(12.f));
        g.setColour(theme::secondary);
        g.drawText("Track Mixer", x + 5, y + timeline->rulerTop(), std::max(0, trackVisibilityButton.getX() - x - 9),
                   timeline->rulerHeight, Justification::centredLeft);
        if (showRegionLanes)
            g.drawText("Regions - Markers", x + 5, y, right - x - 5, timeline->tempoTop(), Justification::centredLeft);
        if (showTempoLane)
            g.drawText("Tempo", x + 5, y + timeline->tempoTop(), right - x - 5, timeline->headerLaneHeight,
                       Justification::centredLeft);
        g.setColour(theme::timelineHeaderLine());
        if (showRegionLanes) g.drawHorizontalLine(y + timeline->tempoTop() - 1, float(x), float(right));
        if (showTempoLane) g.drawHorizontalLine(y + timeline->rulerTop() - 1, float(x), float(right));
        g.drawHorizontalLine(y + timeline->headerHeight() - 1, float(x), float(right));
    }
}
void Workspace::resized() {
    invalidateRowGeometry();
    if(audioPreparationOverlay)audioPreparationOverlay->setBounds(getLocalBounds());
    if (fadeoutOverlay) fadeoutOverlay->setBounds(getLocalBounds());
    constexpr int statusX = mainStripWidth + 8, playbackInset = 8, automationWidth = 28;
    constexpr int playbackHeight = 24, playbackGap = 4, editGroupSpacing = 8, navigationWidth = 29;
    constexpr int detailHeight = 35;
    constexpr int bpmWidth = 179, metroStripWidth = 88, tempoGap = 8, timelineToolsWidth = 244;
    const auto navigation = {"projectStart", "previousTimelinePoint", "nextTimelinePoint", "projectEnd"};
    const auto playback = {"play", "fadeout", "pause", "loop", "record"};
    const bool multipleProjects = canNavigateProjectTab && (canNavigateProjectTab(-1) || canNavigateProjectTab(1));
    const int buttonWidth = jlimit(52, 96, 52 + (getWidth() - 1296) / 13);
    const int actionWidth = buttonWidth * 2 + 6;
    const int masterX = 0;
    const int statusWidth = std::max(1, getWidth() - statusX - 8);
    const int tempoWidth = metroStripWidth + bpmWidth;
    const int tunerWidth = jlimit(125, 134, statusWidth - tempoWidth - tempoGap - 16);
    const int tuningSpan = tempoWidth + tempoGap + tunerWidth;
    const int detailWidth = tuningSpan + timelineToolsWidth;
    const int playbackWidth = getWidth() < 1600 ? 54 : 60;
    const int editSpan = playbackWidth + playbackGap + automationWidth;
    const int playbackSpan = (int)playback.size() * (playbackWidth + playbackGap) + editGroupSpacing + editSpan;
    const int rightControlSpan = actionWidth + (multipleProjects ? 62 : 0);
    const bool narrowTransport = statusWidth < playbackSpan + detailWidth + rightControlSpan + 2 * playbackInset + 24;
    const int rail = 0, title = workspaceFullscreen ? 0 : 32;
    constexpr int toolbarInset = 4, toolbarButtonHeight = 21, toolBarHeight = 24;
    constexpr int settingsWidth = 28, timerWidth = 92;
    toolbarAudioFormat = audioFormatText(session.audio.devices);
    const int audioTextWidth = FooterAudioStatusButton::widthForStatus(toolbarAudioFormat);
    const auto toolbarWidth = [](const char *, int padding, float) { return 23 + padding; };
    const auto primaryTools = {"menu", "library", "focus", "mixer", "railMixer", "matrixPatch", "railParts", "railNotice", "railClock", "railKeyboard", "railVinhetas", "midiPreview"};
    const auto integrations = {"advanced", "grandma2", "resolume"};
    const auto liveTools = {"tp1", "tp2", "preview", "video", "remote"};
    constexpr int toolbarPadding = 6, toolbarGap = 4;
    constexpr float toolbarFontSize = 14.f;
    const int liveToolsWidth = (int)liveTools.size() * (29 + toolbarGap);
    const int minimumToolbarWidth = toolbarInset*2 + settingsWidth + audioTextWidth + 6 +
        ((int)primaryTools.size() + (int)integrations.size() + (int)liveTools.size())*(29 + toolbarGap);
    const int settingsX = getWidth() - settingsWidth - toolbarInset;
    const int transport = toolBarHeight + (narrowTransport ? 126 : 86);
    const int footerHeight = jlimit(27, 161, footerHeightSetting);
    const bool previewDocked = midiPreviewVisible && !midiPreviewDetached;
    const bool partsDockedFlat = partsLeftVisible && partsLeftHorizontal && !partsLeftDetached;
    const int partsHeight = partsDockedFlat ? horizontalPartsHeight : 0;
    const int fixedDockHeight = partsHeight + (keyboardVisible ? 108 : 0) + (vinhetasVisible && !vinhetasDetached ? 240 : 0);
    const int availableDock = std::max(0, getHeight() - title - transport - footerHeight - 128);
    const int availableFlexibleDock = std::max(0, availableDock - fixedDockHeight);
    const int mixerReserve = footerMixerVisible ? std::min(160, availableFlexibleDock / 2) : 0;
    midiPreviewHeightLimit = std::min(724, availableFlexibleDock - mixerReserve);
    const int previewHeight = previewDocked ? std::min(midiPreviewHeight, midiPreviewHeightLimit) : 0;
    mixerHeightLimit = std::min(724, availableFlexibleDock - previewHeight);
    const int mixerHeight = footerMixerVisible ? std::min(std::max(273, mixerHeightSetting), mixerHeightLimit) : 0;
    const int dockHeight = fixedDockHeight + mixerHeight + previewHeight;
    const int visibleDockHeight = std::min(dockHeight, availableDock);
    const int bottom = footerHeight + visibleDockHeight;
    caption->setBounds(0, 0, getWidth(), title);
    caption->setVisible(!workspaceFullscreen);
    const bool editorVisible = projectReady && !loginPanel;
    caption->setMaximiseEnabled(projectReady || loginPanel != nullptr);
    const bool visibilityChanged = !lastEditorVisible || *lastEditorVisible != editorVisible;
    lastEditorVisible = editorVisible;
    for (auto *child : getChildren()) {
        if (dynamic_cast<ModalSheet *>(child))
            child->setBounds(getLocalBounds());
        else if (visibilityChanged && child != caption.get() && child != projectBrowser.get() &&
                 child != loginPanel.get())
            child->setVisible(editorVisible);
    }
    if (projectBrowser) {
        projectBrowser->setVisible(browserVisible && !loginPanel);
        const auto editor = getLocalBounds().withTrimmedTop(title);
        projectBrowser->setBounds(editor.withSizeKeepingCentre(std::min(600, editor.getWidth()), std::min(460, editor.getHeight())));
        projectBrowser->setProjectOpen(projectReady);
        if (browserVisible) projectBrowser->toFront(false);
    }
    if (loginPanel) {
        loginPanel->setBounds(0, title, getWidth(), getHeight() - title);
        loginPanel->toFront(false);
    }

    caption->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child) || dynamic_cast<CloseProjectSheet *>(child))
            child->toFront(false);
    if (setlistWindow) setlistWindow->setVisible(layoutActive && editorVisible && setlistVisible && setlistPlacement==SetlistPlacement::detached);
    if (!editorVisible) { if (nativeTransport) nativeTransport->hide(); return; }
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        const int minimumWidth = std::max(1060,minimumToolbarWidth) + window->getContentComponentBorder().getLeftAndRight();
        if (auto *constrainer = window->getConstrainer(); constrainer && constrainer->getMinimumWidth() != minimumWidth) {
            constrainer->setMinimumWidth(minimumWidth);
            const auto *display = Desktop::getInstance().getDisplays().getDisplayForRect(window->getBounds());
            if (window->getPeer() && window->getWidth() < minimumWidth && display && display->userArea.getWidth() >= minimumWidth)
                window->setBoundsConstrained(window->getBounds().withWidth(minimumWidth));
        }
    }
    transportBounds = {rail, title + toolBarHeight, getWidth() - rail, transport - toolBarHeight};
    footerBounds = {rail, getHeight() - footerHeight, getWidth() - rail, footerHeight};
    workspaceBounds = {rail, title + transport, getWidth() - rail,
                       std::max(1, getHeight() - title - transport - bottom)};
    // The master is independent of track mixer visibility, as in the Mac transport.
    masterVolume.setBounds(10, 54, mainStripWidth - 12, 20);
    if (masterPeakReadout) masterPeakReadout->setBounds(mainStripWidth - 47, 41, 43, 12);
    controls["masterMono"]->setBounds(10, 14, 49, 20);
    controls["masterPatch"]->setBounds(63, 14, 40, 20);
    controls["masterFX"]->setBounds(107, 14, 26, 20);
    masterPan.setBounds(135, 13, 22, 22);
    controls["masterMute"]->setBounds(161, 14, 26, 20);
    controls["masterSolo"]->setBounds(191, 14, 26, 20);
    for (auto id : {"previousProjectTab", "nextProjectTab"}) controls[id]->setVisible(multipleProjects);

    const int panelY = transportBounds.getY();
    transportDisplayBounds = {statusX, panelY + 6, statusWidth, transportBounds.getHeight() - 12};
    const auto status = transportDisplayBounds;
    const int midpoint = status.getCentreY();
    const int titleY = status.getY() + std::max(0, (midpoint - status.getY() - 27) / 2);
    const int actionX = status.getRight() - 8 - actionWidth;
    const int playbackX = status.getX() + playbackInset;
    const int detailY = narrowTransport ? status.getBottom() - playbackHeight - detailHeight - 7
        : midpoint + std::max(0, (status.getBottom() - midpoint - detailHeight) / 2) - 4;
    const int controlBottom = narrowTransport ? status.getBottom() - 2 : detailY + detailHeight;
    const int playbackY = controlBottom - playbackHeight;
    const int actionY = controlBottom - 26;
    controls["save"]->setBounds(actionX, actionY, buttonWidth, 26);
    controls["setlist"]->setBounds(actionX + buttonWidth + 6, actionY, buttonWidth, 26);
    int keyX = playbackX;
    for (auto id : playback) {
        controls[id]->setBounds(keyX, playbackY, playbackWidth, playbackHeight);
        keyX += playbackWidth + playbackGap;
    }
    const int recordRight = controls["record"]->getRight();
    keyX += editGroupSpacing + editSpan + playbackGap;
    const int tabsX = actionX - 62, tabsY = actionY + 3;
    controls["previousProjectTab"]->setBounds(tabsX, tabsY, 25, 20);
    auto *nextProjectTab = controls["nextProjectTab"];
    nextProjectTab->setBounds(controls["previousProjectTab"]->getBounds().translated(31, 0));
    const int titleInset = std::min((status.getWidth() - 1) / 2, 282);
    const int rightToolsX = actionX - (multipleProjects ? 62 : 0) - timelineToolsWidth;
    const bool toolsShareDetailRow = !narrowTransport || rightToolsX < keyX;
    const int detailRight = toolsShareDetailRow ? (narrowTransport ? status.getRight() - timelineToolsWidth : rightToolsX) : rightToolsX;
    const int firstTempoX = narrowTransport ? playbackX : keyX + 10;
    const int centeredTempoX = status.getX() + (status.getWidth() - tuningSpan) / 2;
    const int lastTempoX = std::max(firstTempoX, detailRight - tuningSpan - 10);
    const int tempoX = jlimit(firstTempoX, lastTempoX, centeredTempoX);
    const int editLimit = narrowTransport ? (toolsShareDetailRow ? (multipleProjects ? tabsX : actionX) : rightToolsX) : tempoX;
    const int editX = std::max(recordRight + playbackGap, (recordRight + editLimit - editSpan) / 2);
    controls["editMode"]->setBounds(editX, playbackY, playbackWidth, playbackHeight);
    controls["track-envelopes"]->setBounds(editX + playbackWidth + playbackGap, playbackY, automationWidth, playbackHeight);
    songDisplay.setBounds(status.getX() + titleInset, titleY, std::max(1, status.getWidth() - 2 * titleInset), 27);
    tempoDisplayBounds = {tempoX, detailY, tempoWidth, detailHeight};
    constexpr int metronomeButtonHeight = 24;
    const int metronomeY = tempoDisplayBounds.getY() + (tempoDisplayBounds.getHeight() - metronomeButtonHeight) / 2;
    controls["metronomeMode"]->setBounds(tempoX + 4, metronomeY, 32, metronomeButtonHeight);
    controls["metronome"]->setBounds(tempoX + 42, metronomeY, 30, metronomeButtonHeight);
    tempoControl->setBounds(tempoX + metroStripWidth, detailY, bpmWidth, detailHeight);
    tuner->setBounds(tempoDisplayBounds.getRight() + tempoGap, tempoDisplayBounds.getY(), tunerWidth, tempoDisplayBounds.getHeight());
    const int toolsY = (toolsShareDetailRow ? tuner->getBottom() : controlBottom) - 24;
    constexpr int switchWidth = 24, switchGap = 3;
    constexpr int switchesWidth = 2 * switchWidth + switchGap;
    const int toolsX = (toolsShareDetailRow && narrowTransport ? tuner->getRight() + 10 : rightToolsX) + 46;
    const int switchesLeft = toolsShareDetailRow ? tuner->getRight() : std::max(tuner->getRight(), controls["track-envelopes"]->getRight());
    const int switchesX = std::min(toolsX - switchesWidth, (switchesLeft + toolsX - switchesWidth) / 2);
    timelineSnap.setBounds(switchesX, toolsY, switchWidth, 24);
    timelineTimebase.setBounds(switchesX + switchWidth + switchGap, toolsY, switchWidth, 24);
    controls["trackHeightFit"]->setBounds(toolsX, toolsY, 24, 24);
    controls["zoomFit"]->setBounds(toolsX + 24, toolsY, 24, 24);
    trackHeightSlider.setBounds(toolsX + 54, toolsY, 68, 24);
    zoom.setBounds(trackHeightSlider.getRight(), toolsY, 68, 24);
    int navX = status.getX() + 8;
    for (auto id : navigation) {
        controls[id]->setBounds(navX, titleY + 2, navigationWidth, 23);
        navX += navigationWidth + playbackGap;
    }
    transportTime.setBounds(navX + 4, titleY, std::max(1, songDisplay.getX() - navX - 10), 27);
    const int noticeWidth = std::max(0, titleInset - 8);
    transportInfo.setBounds(status.getRight() - noticeWidth - 8, titleY + 1, noticeWidth, 25);

    for (auto id : {"masterMono", "masterPatch", "masterFX", "masterMute", "masterSolo"})
        controls[id]->setTopLeftPosition(masterX + controls[id]->getX(), panelY + controls[id]->getY());
    for (Component *component : std::initializer_list<Component *>{&masterVolume, &masterPan, masterPeakReadout.get()})
        if (component) component->setTopLeftPosition(masterX + component->getX(), panelY + component->getY());
    stageTimer->refresh();
    tempo.setVisible(false);
    // Commands not present in the Mac transport remain available through menus/shortcuts.
    for (auto id : {"stopall", "previous", "next", "audio", "soundfont", "railProjects",
                    "railImport", "railUndo", "railRedo", "railSettings", "railHelp"})
        controls[id]->setVisible(false);
    controls["railTeleprompt"]->setVisible(false);
    controls["railTeleprompt2"]->setVisible(false);
    int toolX = toolbarInset;
    const auto layoutTools = [&](std::initializer_list<const char *> ids, int y) {
        for (auto id : ids) {
            const int width = toolbarWidth(id, toolbarPadding, toolbarFontSize);
            controls[id]->getProperties().set("fontSize", toolbarFontSize);
            controls[id]->setBounds(toolX, y, width, toolbarButtonHeight);
            toolX += width + toolbarGap;
        }
    };
    const int toolbarY = title + 1;
    layoutTools(primaryTools, toolbarY);
    layoutTools(integrations, toolbarY);
    const int audioBudget = settingsX - liveToolsWidth - toolX - 6;
    const int audioWidth = jlimit(0, audioTextWidth, audioBudget);
    const int audioX = settingsX - 6 - audioWidth;
    const int liveX = audioX - liveToolsWidth;
    const int lastTimerX = liveX - timerWidth - 6;
    if (lastTimerX >= toolX) {
        const int timerX = jlimit(toolX, lastTimerX, (getWidth() - timerWidth) / 2);
        stageTimer->setBounds(timerX, toolbarY, timerWidth, toolbarButtonHeight);
    } else {
        // The countdown can share the existing notices row when the toolbar is full.
        transportInfo.setSize(std::max(0, noticeWidth - timerWidth - 6), transportInfo.getHeight());
        stageTimer->setBounds(status.getRight() - timerWidth - 8, titleY, timerWidth, 25);
    }
    toolX = liveX;
    layoutTools(liveTools, toolbarY);
    controls["audioStatus"]->setBounds(audioX, toolbarY, audioWidth, toolbarButtonHeight);
    controls["settings"]->getProperties().set("fontSize", toolbarFontSize);
    controls["settings"]->setBounds(settingsX, toolbarY, settingsWidth, toolbarButtonHeight);
    for (auto id : {"zoomOut", "zoomIn"}) controls[id]->setVisible(false);
    dockHeights = {mixerHeight, partsHeight, dockHeight, visibleDockHeight, previewHeight};
    layoutWorkspaceColumns(false);
    syncNativeTransport();
}

void Workspace::layoutWorkspaceColumns(bool widthOnly) {
    const int rail = workspaceBounds.getX();
    const auto [mixerHeight, partsHeight, dockHeight, visibleDockHeight, previewHeight] = dockHeights;
    const bool previewDocked = previewHeight > 0;
    const int availableWidth = workspaceBounds.getWidth();
    const bool detachedSetlist = setlistPlacement == SetlistPlacement::detached;
    const int mixerGap=mixerVisible?6:0;
    const int setlistGap=setlistVisible && setlistPlacement == SetlistPlacement::left ? 6 : 0;
    const int libraryExtent = libraryVisible ? std::min({libraryWidth, workspaceLibrary->maximumPanelWidth(),
                                                         std::max(0, availableWidth - 240)}) : 0;
    const int focusWidth = focusVisible ? std::min(MixerPanel::focusWidth(), std::max(0, availableWidth - libraryExtent - 100)) : 0;
    const int columnsBudget = std::max(0, availableWidth - libraryExtent - focusWidth - 100 - timelineGrid::verticalScrollbarWidth
                                           - mixerGap - setlistGap);
    const int mixerMinimum=mixerVisible?std::min(theme::trackMixerMinWidth,columnsBudget):0;
    const int setlistMinimum=setlistVisible&&!detachedSetlist?std::min(minimumSetlistWidth,std::max(0,columnsBudget-mixerMinimum)):0;
    const bool rightPartsDocked=partsRightVisible&&setlistVisible&&!detachedSetlist;
    const bool partsDockedVertically = partsLeftVisible && !partsLeftHorizontal;
    const int partsCount=(partsDockedVertically?1:0)+(rightPartsDocked?1:0);
    const int partsBudget=std::max(0,columnsBudget-mixerMinimum-setlistMinimum);
    const int partsMinimum=partsCount?std::min(160,partsBudget/partsCount):0;
    const int sectionsWidth=rightPartsDocked?jlimit(partsMinimum,
        std::max(partsMinimum,partsBudget-(partsDockedVertically?partsMinimum:0)),
        partsRightWidth>0?partsRightWidth:std::min(360,(int)(availableWidth*.22))):0;
    const int leftPartsWidth=partsDockedVertically?jlimit(partsMinimum,std::max(partsMinimum,partsBudget-sectionsWidth),partsLeftWidth):0;
    const int right=setlistVisible&&!detachedSetlist?jlimit(setlistMinimum,
        std::max(setlistMinimum,columnsBudget-sectionsWidth-mixerMinimum-leftPartsWidth),setlistWidth):0;
    const int mixerBodyWidth=mixerVisible?jlimit(mixerMinimum,
        std::max(mixerMinimum,columnsBudget-right-sectionsWidth-leftPartsWidth),mixerWidth):0;
    const int left = mixerBodyWidth;
    const int leadingSetlist = setlistPlacement == SetlistPlacement::left ? right+setlistGap : 0;
    const int partsX = rail + leadingSetlist + libraryExtent;
    const int mixerX = partsX + leftPartsWidth + focusWidth;
    const int trackTop = workspaceBounds.getY() + timeline->headerHeight();
    const bool resizeRows = !widthOnly || tracksViewport.getWidth() != left;
    tracksViewport.setVisible(mixerVisible);
    tracksViewport.setBounds(mixerX, trackTop, left, std::max(1, workspaceBounds.getHeight() - timeline->headerHeight()));
    tracksContent.setSize(std::max(1, left), std::max(tracksViewport.getHeight(), rowTop(rows.size()) + trackHeight * 2));
    if (resizeRows) for (int i = 0; i < rows.size(); ++i) {
        rows[i]->setVisible(!rowHidden(i));
        rows[i]->setBounds(0, rowTop(i), std::max(1, left), rowHeight(i));
    }
    const int bandsX = mixerX + mixerBodyWidth - 37;
    const int rulerY = workspaceBounds.getY() + timeline->rulerTop();
    addTrack.setBounds(bandsX - 36, rulerY + (timeline->rulerHeight - 24) / 2, 32, 24);
    addTrack.setVisible(mixerVisible);
    timelineLock.setBounds(addTrack.getX() - 30, addTrack.getY(), 24, 24);
    timelineLock.setVisible(mixerVisible);
    trackVisibilityButton.setBounds(timelineLock.getX()-30,timelineLock.getY(),24,24);
    trackVisibilityButton.setVisible(mixerVisible);
    timelineBands.setBounds(addTrack.getBounds().translated(36, 0));
    timelineBands.setVisible(mixerVisible);
    timeline->setBounds(mixerX + left + mixerGap, workspaceBounds.getY(),
                        std::max(1, workspaceBounds.getWidth() - libraryExtent - focusWidth - left - right - sectionsWidth - leftPartsWidth - mixerGap - setlistGap),
                        workspaceBounds.getHeight());
    if (!detachedSetlist) {
        const int sidebarHeight = workspaceBounds.getHeight() + visibleDockHeight;
        setlist->setVisible(setlistVisible);
        setlist->setBounds(leadingSetlist ? rail : getWidth()-right-sectionsWidth,workspaceBounds.getY(),right,sidebarHeight);
        setlist->setPartsVisible(partsRightVisible);
        partsSidebar->setVisible(partsRightVisible && setlistVisible);
        partsSidebar->setBounds(getWidth()-sectionsWidth,workspaceBounds.getY(),sectionsWidth,sidebarHeight);
        partsRightDivider.setVisible(partsRightVisible&&setlistVisible);
        partsRightDivider.setBounds(partsSidebar->getX()-3,workspaceBounds.getY(),6,sidebarHeight);
    } else if (setlistWindow && !widthOnly) {
        setlistWindow->setVisible(layoutActive && setlistVisible && projectReady && !loginPanel);
        layoutDetachedSetlist();
    }
    footer.setBounds(rail + 10, footerBounds.getY(), getWidth() - rail - 20, 27);
    footer.setVisible(false);
    keyboard->setVisible(keyboardVisible);
    footerMixer->setVisible(footerMixerVisible && mixerHeight > 0);
    dockViewport.setVisible(dockHeight > 0);
    const bool performanceDock = previewDocked || keyboardVisible || (vinhetasVisible && !vinhetasDetached);
    const auto inspectorExtent = [this, mixerHeight, partsHeight, visibleDockHeight](int offset) {
        return workspaceBounds.getHeight() + jlimit(0,visibleDockHeight,mixerHeight+partsHeight-offset);
    };
    const int inspectorHeight = inspectorExtent(dockViewport.getViewPositionY());
    focusMixer->setBounds(partsX, workspaceBounds.getY(), focusWidth, inspectorHeight);
    focusMixer->setVisible(focusVisible);
    workspaceLibrary->setBounds(rail + leadingSetlist, workspaceBounds.getY(), libraryExtent, inspectorHeight);
    workspaceLibrary->setVisible(layoutActive && libraryExtent > 0);
    libraryDivider.setBounds(partsX - 3, workspaceBounds.getY(), 6, inspectorHeight);
    libraryDivider.setVisible(layoutActive && libraryExtent > 0);
    const int dockX = performanceDock ? rail + leadingSetlist : partsX + focusWidth;
    const int dockRight = getWidth() - sectionsWidth - (leadingSetlist ? 0 : right + setlistGap);
    dockViewport.setBounds(dockX, footerBounds.getY() - visibleDockHeight, std::max(0, dockRight - dockX), visibleDockHeight);
    const int dockWidth = std::max(0, dockViewport.getWidth() - (dockHeight > visibleDockHeight ? 10 : 0));
    dockContent.setSize(dockWidth, dockHeight);
    const int mixerInset = partsX + focusWidth - dockX;
    const int mixerDockWidth = std::max(0, dockWidth-mixerInset);
    footerMixer->setBounds(mixerInset, 0, mixerDockWidth, mixerHeight);
    dockViewport.scrolled = [this,inspectorExtent](int y) {
        const int h = inspectorExtent(y);
        for (Component *c : std::initializer_list<Component *>{focusMixer.get(),workspaceLibrary.get(),&libraryDivider})
            c->setSize(c->getWidth(), h);
    };
    dockViewport.scrolled(dockViewport.getViewPositionY());
    dockViewport.toBack();
    const int previewY = mixerHeight + partsHeight + (keyboardVisible ? 108 : 0) + (vinhetasVisible && !vinhetasDetached ? 240 : 0);
    if (!midiPreviewDetached) {
        midiPreviewPanel->setVisible(previewDocked);
        midiPreviewPanel->setBounds(0,previewY+7,dockWidth,std::max(0,previewHeight-7));
    }
    midiPreviewDivider.setVisible(previewDocked);
    midiPreviewDivider.setBounds(0,previewY,dockWidth,7);
    if (!vinhetasDetached) {
        vinhetasPanel->setVisible(vinhetasVisible);
        vinhetasPanel->setBounds(0, mixerHeight + partsHeight + (keyboardVisible ? 108 : 0), dockWidth, 240);
    }
    if (!widthOnly) {
        refreshToolbarPanelIndicators();
        controls["setlist"]->setColour(TextButton::buttonColourId, setlistVisible ? theme::green : Colour(0xff454545));
        controls["setlist"]->setColour(TextButton::textColourOffId, setlistVisible ? Colours::black : Colours::white);
    }
    if (!partsLeftDetached) {
        partsLeft->setVisible(partsLeftVisible);
        partsLeft->setHorizontal(partsLeftHorizontal);
        Component &host = partsLeftHorizontal ? dockContent : static_cast<Component &>(*this);
        if (partsLeft->getParentComponent() != &host) host.addChildComponent(*partsLeft);
        if (partsLeftHorizontal) partsLeft->setBounds(mixerInset, mixerHeight, mixerDockWidth, partsHeight);
        else partsLeft->setBounds(partsX, workspaceBounds.getY(), leftPartsWidth, workspaceBounds.getHeight());
    }
    partsLeftDivider.setVisible(partsDockedVertically);
    partsLeftDivider.setBounds(partsLeft->getRight()-3,workspaceBounds.getY(),6,workspaceBounds.getHeight());
    if (keyboardVisible)
        keyboard->setBounds(0, mixerHeight + partsHeight, dockWidth, 108);
    mixerDivider.setVisible(mixerVisible); setlistDivider.setVisible(setlistGap > 0);
    mixerDivider.setBounds(mixerX + left, workspaceBounds.getY(), mixerGap, workspaceBounds.getHeight());
    setlistDivider.setBounds(leadingSetlist?setlist->getRight():setlist->getX()-setlistGap,
        workspaceBounds.getY(), setlistGap, workspaceBounds.getHeight() + visibleDockHeight);
    footerHeightDivider.setBounds(rail, footerBounds.getY() - 3, getWidth() - rail, 6);
    mixerHeightDivider.setVisible(footerMixerVisible && mixerHeight > 0);
    mixerHeightDivider.setBounds(dockX + mixerInset, dockViewport.getY() - 3, mixerDockWidth, 6);
    mixerDivider.refreshScroll();setlistDivider.refreshScroll();partsRightDivider.refreshScroll();
    footerSongBounds = footerBounds.withTrimmedLeft(std::min(footerLeftWidth, footerBounds.getWidth() / 3));
    trackHeightHandle->setBounds(tracksViewport.getBounds());
    trackHeightHandle->setVisible(projectReady && !browserVisible && mixerVisible);
    if (widthOnly) return;
    trackHeightHandle->toFront(false);
    for (auto *divider : {&mixerDivider, &setlistDivider, &partsLeftDivider, &partsRightDivider, &footerHeightDivider, &mixerHeightDivider}) divider->toFront(false);
    for (auto *child : getChildren())
        if (dynamic_cast<ModalSheet *>(child)) child->toFront(false);
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
    auto title=ClipTempo(clip,song,itemTitleTempo.get()).itemTitle(clip);
    std::string path=clip.audioFile?clip.audioFile->path:std::string{};
    if(path.empty() && song)for(const auto &track:song->tracks)
        if(track.audioFile && std::any_of(track.clips.begin(),track.clips.end(),[&](const auto &item){return item.id==clip.id;})) {path=track.audioFile->path;break;}
    if(!clip.midi && !path.empty()) {
        const auto extension=File::getCurrentWorkingDirectory().getChildFile(text(path)).getFileExtension().trimCharactersAtStart(".").toLowerCase();
        if(extension.isNotEmpty() && !title.endsWithIgnoreCase(" - "+extension)) {
            if(title.endsWithIgnoreCase("."+extension))title=title.dropLastCharacters(extension.length()+1);
            title+=" - "+extension;
        }
    }
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
int Workspace::minimumTrackHeight() const {
    int minimum = theme::trackMixerMinHeight;
    if (const auto *song = session.song()) {
        for (const auto &t : song->tracks) if (allowsCompactTrackHeight(t))
            minimum = std::min(minimum, std::max(1, int(std::floor(compactTrackHeight / t.heightScale.value_or(1.)))));
    }
    return minimum;
}
int Workspace::itemLaneHeight(int index) const {
    if (const auto *song=session.song(); song && index>=0 && index<(int)song->tracks.size())
        return jlimit((int)std::ceil(desktopLaneMinimum(itemLanes(index).count, allowsCompactTrackHeight(song->tracks[size_t(index)]))),itemLanes(index).count>1?168:240,
            roundToInt(trackHeight * (itemLanes(index).count>1 ? .7 : 1.) *
                (trackHeightPreview && trackHeightPreview->first==song->tracks[(size_t)index].id ? trackHeightPreview->second : song->tracks[(size_t)index].heightScale.value_or(1.))));
    return trackHeight;
}
int Workspace::measureRowBodyHeight(int index) const {
    const int base=itemLaneHeight(index) * itemLanes(index).count;
    const auto *song=session.song();
    if(song && index>=0 && index<(int)song->tracks.size() && song->tracks[size_t(index)].role.id=="programChange")
        return std::max(base,ProgramChangeLanes(song->tracks[size_t(index)]).count*24+8);
    return base;
}
void Workspace::prepareRowGeometry() const {
    const auto *song = session.song();
    const ID songID = song ? song->id : ID{};
    const int count = song ? int(song->tracks.size()) : 0;
    if (rowGeometryRevision == session.revision && rowGeometrySong == songID && rowGeometry.size() == count) return;
    rowGeometry.rebuild(count, [&](int index) {
        const int body = measureRowBodyHeight(index);
        return TrackRowGeometry::Row{body, rowHidden(index) ? 0 : body + 32 * int(automation::visible(song->tracks[size_t(index)]).size())};
    });
    rowGeometrySong = songID;
    rowGeometryRevision = session.revision;
}
int Workspace::rowBodyHeight(int index) const {
    prepareRowGeometry();
    return rowGeometry.body(index);
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
    invalidateRowGeometry();
    resized();
    timeline->updateRanges();
    for (auto *row : rows)
        row->refresh();
    syncNativeTransport();
    repaint();
}
int Workspace::rowHeight(int index) const {
    prepareRowGeometry();
    return rowGeometry.height(index);
}
int Workspace::rowTop(int index) const {
    prepareRowGeometry();
    return rowGeometry.top(index);
}
int Workspace::rowAt(int y) const {
    prepareRowGeometry();
    return rowGeometry.rowAt(y);
}
void Workspace::refreshPlaybackState() {
    // Queue, playlist and Stop policy edits keep the same media and geometry.
    // Retain their caches before a repaint can interpret revision as a new grid.
    if(itemLayoutRevision+1==session.revision)itemLayoutRevision=session.revision;
    if(itemTitleRevision+1==session.revision)itemTitleRevision=session.revision;
    tempoControl->retainTempoAfterMixerChange();
    timeline->refreshMixer();
    setlist->refresh();caption->repaint();repaint(footerBounds);updateState();
}
void Workspace::rebuild() {
    workspaceLibrary->refreshTimelineEntries();
    if(!session.preparingLiveAudio()){audioPreparationOverlay.reset();audioPreparationStarted.reset();}
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
        std::map<ID, std::unique_ptr<TrackRow>> retained;
        if (builtSong == songID) {
            for (int index = rows.size(); --index >= 0;)
                retained.emplace(builtTracks[size_t(index)], std::unique_ptr<TrackRow>(rows.removeAndReturn(index)));
        } else rows.clear();
        for (const auto &id : current) {
            const auto found = retained.find(id);
            if (found != retained.end()) rows.add(found->second.release());
            else {
                auto *row = rows.add(new TrackRow(*this, id));
                tracksContent.addAndMakeVisible(row);
            }
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
    const auto *song = session.song();
    auto *envelopes = controls.at("track-envelopes");
    envelopes->setEnabled(song && std::any_of(song->tracks.begin(), song->tracks.end(), automation::trackSupportsLanes));
    envelopes->setToggleState(song && automation::allTrackLanesVisible(*song), dontSendNotification);
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
        const auto content=StageContent::make(session,stage,i+1,true);
        teleprompterHTTP[(size_t)i]->publish(content.payload,content.media,content.noticeImage);
    }
    // Hidden project tabs still advance transport, lighting and projections.
    // Their controls and timeline need one refresh on activation, not 60 per
    // second competing with the visible tab during an Auto transition.
    if (!layoutActive) return;
    if (const auto it = floatingWindows.find("Exportar"); it != floatingWindows.end() && it->second->isVisible())
        if (auto *exportPanel = dynamic_cast<ExportPanel *>(it->second->getContentComponent())) {
            if (selectedTracks.empty() && !selectedTrack.empty()) exportPanel->setMixerTracks({selectedTrack});
            else exportPanel->setMixerTracks(selectedTracks);
        }
    stageTimer->refresh();
    if (fadeoutOverlay) fadeoutOverlay->update();
    const bool loopMixerActive = session.transport().multiLoop.has_value();
    if (session.transportFadeoutActive() || lastFadeoutActive || loopMixerActive || lastLoopMixerActive)
        for (auto *row : rows) if (row->isShowing()) row->refreshMixer();
    lastFadeoutActive = session.transportFadeoutActive(); lastLoopMixerActive = loopMixerActive;
    const bool movementLocked = session.project().timelineMovementLocked.value_or(false);
    timelineLock.setToggleState(movementLocked, dontSendNotification);
    const bool relativeTimebase=session.song() && session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase==jaras::ProjectTimebase::relative && (!timeline || !timeline->suspendsTimebase());
    timelineTimebase.setToggleState(relativeTimebase,dontSendNotification);
    timelineTimebase.setEnabled(session.song() && !session.busy && !session.audio.isRecording());
    timelineLock.getProperties().set("icon", movementLocked ? "lock" : "unlock");
    timelineLock.setTooltip("Lock- Timeline");
    timelineLock.setEnabled(!session.busy && !session.audio.isRecording());
    trackVisibilityButton.setEnabled(!session.busy);
    const auto heightMinimum = minimumTrackHeight();
    if (trackHeightSlider.getMinimum() != heightMinimum) {
        trackHeightSlider.setRange(heightMinimum, 240, 1);
        trackHeightSlider.setValue(jmax(heightMinimum,trackHeight), dontSendNotification);
    }
    timelineSnap.setEnabled(!session.busy);
    timelineBands.setEnabled(!session.busy);
    timelineBands.setToggleState(showRegionLanes || showTempoLane, dontSendNotification);
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
    refreshToolbarPanelIndicators();
    if(masterFXColourSource!=session.project().masterFXJSON) {
        masterFXColourSource=session.project().masterFXJSON;
        masterFXColour=fxchain::colour(masterFXColourSource ? JSON::parse(text(*masterFXColourSource)) : var(),true);
    }
    controls["masterFX"]->setColour(TextButton::textColourOffId, masterFXColour);
    controls["play"]->setButtonText(t.playing ? "Stop" : "Play");
    controls["play"]->setTitle(controls["play"]->getButtonText());
    controls["play"]->getProperties().set("leadingIcon", t.playing ? "stopall" : "play");
    controls["play"]->setToggleState(t.playing, dontSendNotification);
    controls["pause"]->setEnabled(t.playing);
    controls["pause"]->setToggleState(t.paused, dontSendNotification);
    controls["loop"]->setToggleState(t.loop.enabled, dontSendNotification);
    controls["record"]->setToggleState(session.audio.isRecording() || session.recordingCountInActive(), dontSendNotification);
    controls["metronome"]->setToggleState(session.audio.metronomeEnabled.load(),
                                          dontSendNotification);
    static const char *modeNames[]{"A-B", "A", "B"};
    controls["metronomeMode"]->setButtonText(modeNames[jlimit(0, 2, (int)appearance.value("jaras.metronome.mode", 0))]);
    controls["record"]->setColour(TextButton::buttonOnColourId, theme::liveOffRed);
    controls["save"]->setEnabled(!session.isSaving());
    controls["save"]->getProperties().set("leadingIcon", session.dirty ? "save" : "check");
    controls["save"]->setColour(TextButton::buttonColourId,
                                session.dirty ? theme::green : Colour(0xff454545));
    controls["save"]->setColour(TextButton::textColourOffId,
                                session.dirty ? Colours::black : Colours::white);
    controls["railUndo"]->setEnabled(session.canUndo());
    controls["railRedo"]->setEnabled(session.canRedo());
    masterPan.setValue(session.project().masterPan, dontSendNotification);
    masterVolume.setValue(session.trackDisplayVolume({},session.project().masterVolume), dontSendNotification);
    controls["masterMute"]->setToggleState(session.trackDisplayMute({},session.project().masterMute), dontSendNotification);
    controls["masterSolo"]->setToggleState(session.trackDisplaySolo({},session.project().masterSolo), dontSendNotification);
    controls["masterMono"]->setToggleState(session.project().masterMono, dontSendNotification);
    controls["masterMono"]->setButtonText(session.project().masterMono ? "" : String::fromUTF8("Estéreo"));
    controls["masterMono"]->getProperties().set("icon", session.project().masterMono ? "mono" : "");
    controls["masterMono"]->setColour(TextButton::textColourOnId, theme::green);
    controls["masterMono"]->setColour(TextButton::buttonOnColourId, theme::trackControl);
    transportProgressRange.reset();
    String selectedName = String::fromUTF8("—");
    if (auto *s = session.song()) {
        if ((audible.playing || audible.paused) && audible.regionId) {
            for (const auto &part : s->parts) {
                if (part.id != *audible.regionId) continue;
                transportProgressRange = std::make_pair(part.startTime, part.endTime);
                selectedName = timelineRegionLabels::displayName(part);
                break;
            }
        }
        if (!audible.playing && !audible.paused && session.focusedRegion) {
            auto source = *session.focusedRegion;
            if (const auto &setlist = session.project().regionSetlist) {
                for (const auto &playlist : setlist->playlists)
                    if (setlist->selectedId == playlist.id && playlist.songId == s->id) {
                        source = playlist.resolvedRegionId(source);
                        break;
                    }
            }
            const auto selected = std::find_if(s->parts.begin(), s->parts.end(),
                [&](const auto &part) { return part.id == source; });
            if (selected != s->parts.end()) selectedName = timelineRegionLabels::displayName(*selected);
        }
        tempo.setText(String(s->bpm, 1) + " BPM   " + String(s->beatsPerBar) + "/" +
                          String(s->beatUnit),
                      dontSendNotification);
        tempoControl->refresh();
    }
    songDisplay.setColour(Label::textColourId, t.playing ? theme::green : Colours::white);
    songDisplay.setText(selectedName, dontSendNotification);
    const auto needle = audible.playing || audible.paused ? audible.position : audible.editPosition;
    const auto position = std::isfinite(needle) ? std::max(0., needle) : 0.;
    transportTime.setText(clockText(position, position >= 3600.), dontSendNotification);
    const auto information = session.recordingCountInActive() ? localization::translate("Count-in")
        : session.liveCapacityWarning().isNotEmpty() ? session.liveCapacityWarning()
        : t.automaticSectionNotice ? text(*t.automaticSectionNotice)
        : t.loop.enabled ? String("Loop Ativo") : t.ignoreNextAfter ? String("Ignore Next") : String();
    transportInfo.setText(information, dontSendNotification);
    const auto audioInfo = audioFormatText(session.audio.devices);
    if (audioInfo != toolbarAudioFormat && getWidth() > 0) resized();
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
    // CPU/RAM has its own sampling clock; stopped transport notifications do
    // not change the custom footer. Selection/queue edits explicitly refresh it.
    if (audible.playing || audible.subPlay.playing || lastSetlistPlaying)
        repaint(footerBounds);
    timeline->followPlayback();
    timeline->animate();
    for (const auto &entry : controls) {
        const auto &id = entry.first;
        auto *button = entry.second;
        if (id != "menu" && id != "railClock" && id != "railKeyboard" && id != "play" && id != "editMode" && id != "save" && id != "focus")
            button->setButtonText(localization::translate(button->getButtonText()));
        button->setTooltip(localization::translate(button->getTooltip()));
    }
    if (audible.playing || lastSetlistPlaying) setlist->repaint();
    lastSetlistPlaying = audible.playing;
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
        if (projectReady)
            if (auto *window = findParentComponentOfClass<DocumentWindow>()) showEditorWindow(*window, editorWindowBounds);
        if (browserVisible) showProjectBrowser();
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
    if (layoutActive) {
        if (auto *peer = getPeer()) {
            const auto main = static_cast<HWND>(peer->getNativeHandle());
            DWORD foregroundProcess = 0;
            if (const auto foreground = GetForegroundWindow()) GetWindowThreadProcessId(foreground, &foregroundProcess);
            const auto *sheet = dynamic_cast<ModalSheet *>(Component::getCurrentlyModalComponent());
            const unsigned suppression = (foregroundProcess != GetCurrentProcessId() ? 1u : 0u)
                | (IsIconic(main) ? 2u : 0u) | (sheet && sheet->getPeer() == peer ? 4u : 0u);
            if (auxiliaryWindowSuppression != suppression) {
                auxiliaryWindowSuppression = suppression;
                ShowOwnedPopups(main, suppression == 0);
            }
        }
    }
    updateSMK37();
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
    if (midiPreviewPanel->isShowing()) static_cast<RecordingPianoPreview &>(*midiPreviewPanel).refresh();
    if (resourceUsage.sample()) repaint(footerBounds);
    const int mutePhase = session.project().masterMute ? int(int64(now * 2) % 2) : -1;
    if (masterMuteBlinkPhase != mutePhase) {
        masterMuteBlinkPhase = mutePhase;
        repaint(4, transportBounds.getY() + 8, 266, 70);
    }
    if (masterPeakReadout) masterPeakReadout->refresh();
    masterVolume.setMeterLevels(session.audio.meterLevels());
    const auto visibleTracks = tracksViewport.getViewArea();
    if (tracksViewport.isShowing())
        for (auto *row : rows)
            if (row->isVisible() && row->getBounds().intersects(visibleTracks)) row->refreshMeters();
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
    const auto lane = transportProgressBounds();
    int pixels = -1;
    if ((presentation.playing || presentation.paused) && transportProgressRange && std::isfinite(presentation.position)) {
        const auto [start, end] = *transportProgressRange;
        if (std::isfinite(start) && std::isfinite(end) && end > start)
            pixels = roundToInt(lane.getWidth() * jlimit(0., 1., (presentation.position - start) / (end - start)));
    }
    if (transportProgressPixels != pixels) {
        transportProgressPixels = pixels;
        repaint(lane);
    }
    // The timeline's separate 60 Hz clock moves the grid and needles together.
    // This slower timer only animates the temporary stopped Subplay preview.
    if (!presentation.playing && !presentation.subPlay.playing && (subVisible || subVisible != lastSubCursorVisible))
        timeline->animate();
    lastSubCursorVisible = subVisible;
}
void Workspace::refreshInterfaceTheme() {
    const bool changed = theme::setInterfaceTheme(appearance.value(theme::interfaceThemeKey, theme::defaultInterfaceTheme).toString() == "lightDark");
    if (!changed && look.findColour(ResizableWindow::backgroundColourId) == theme::background) return;
    look.refreshThemeColours();
    const auto repaintWindow = [](DocumentWindow &window) {
        window.setBackgroundColour(theme::background);
        invalidateThemeImages(window);
        window.sendLookAndFeelChange();
        window.repaint();
    };
    if (auto *window = findParentComponentOfClass<DocumentWindow>())
        repaintWindow(*window);
    else {
        invalidateThemeImages(*this);
        sendLookAndFeelChange();
        repaint();
    }
    if (setlistWindow) repaintWindow(*setlistWindow);
    for (auto &entry : floatingWindows) repaintWindow(*entry.second);
    timeline->refreshTheme();
    syncNativeTransport();
    if (nativeTransport) nativeTransport->repaintVisible();
}
void Workspace::changeListenerCallback(ChangeBroadcaster *) {
    refreshInterfaceTheme();
    session.audio.keyboardChannel = jlimit(0, 16, (int)appearance.value("jaras.keyboard.channel", 0));
    syncBarMixerMasterSide();
    syncHozMixerTrackStyle();
    if(trackVisibility.load(appearance,session.project().id)) {pruneTrackVisibilitySelection(trackSelectionFromFooter);refreshTrackVisibility();}
    localization::english = appearance.value("jaras.language", "pt-BR").toString() == "en";
    for (auto *child : getChildren())
        if (auto *sheet = dynamic_cast<ModalSheet *>(child)) {
            localization::panel(*sheet);
            sheet->repaint();
        }
    for (const auto &entry : floatingWindows) {
        auto *panel = entry.second->getContentComponent();
        if (panel) {
            entry.second->setName(localization::translate(entry.first));
            localization::panel(*panel); panel->repaint();
        }
    }
    for (auto *row : rows) { row->resized(); row->repaint(); }
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
    if (!layoutActive) return false;
    if(audioPreparationOverlay)return true;
    if (session.inspection && logger)
        logger->logMessage("QA key=" + String(key.getKeyCode()) +
                           " mods=" + String(key.getModifiers().getRawFlags()));
    if ((session.inspection || SystemStats::getEnvironmentVariable("CATLIVE_AUDIO_DIAGNOSTICS", {}) == "1") && key.getKeyCode() == KeyPress::F12Key) {
        capture(File::getSpecialLocation(File::userApplicationDataDirectory)
                    .getChildFile("Hook Developer/CatLive/qa/current.png"));
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
    if (!ctrl && !alt && !shift && projectReady && mixerVisible && !setlistVisible &&
        (code == KeyPress::upKey || code == KeyPress::downKey))
        return stepMixerTrack(code == KeyPress::downKey ? 1 : -1);
    if (shift && !ctrl && !alt && (code == KeyPress::upKey || code == KeyPress::downKey ||
                                  code == KeyPress::leftKey || code == KeyPress::rightKey)) {
        if (!projectReady) return false;
        if (code == KeyPress::upKey || code == KeyPress::downKey)
            timeline->scroll(0, code == KeyPress::downKey ? 72 : -72);
        else timeline->scroll(code == KeyPress::rightKey ? 72 : -72, 0);
        return true;
    }
    if (!ctrl && !alt && !shift && selectionAreas.activeScope()=="grid" &&
        (code==KeyPress::leftKey || code==KeyPress::rightKey)) {
        timeline->pausePlaybackFollow();
        perform([&]{session.command(jaras::CommandKind::editSeek,{},std::max(0.,session.transport().editPosition+
            (code==KeyPress::leftKey ? -10. : 10.)/std::max(1.,pixelsPerSecond)));});
        return true;
    }
    if (ctrl && !alt && !shift && (code == 'C' || code == 'X' || code == 'V' || code == 'D')) {
        if (isRepeat && code != 'V') return true;
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
    for(auto &path:files)if(File(path).hasFileExtension("jl;bkjl;ziplive;zip;jllyrics")||externalMedia::supported(File(path)))return true;
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
    if (std::any_of(files.begin(), files.end(), [](const auto &path) { return File(path).hasFileExtension("jllyrics"); })) {
        if (!std::all_of(files.begin(), files.end(), [](const auto &path) { return File(path).hasFileExtension("jllyrics"); })) {
            showError("Drop lyrics separately from audio and video.");
            return;
        }
        const auto songID = session.song()->id;
        perform([&] {
            std::vector<jlLyrics::Document> lyrics;
            for (const auto &path : files) lyrics.push_back(jlLyrics::read(File(path)));
            session.edit([&](auto &project) {
                for (auto &song : project.songs) if (song.id == songID)
                    for (const auto &document : lyrics) jlLyrics::insert(song, document, at, jaras::regionOwnerAt(song, at));
            });
        });
        return;
    }
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
            track.instrumentIcon = "png:Other/waveform";
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
    auto safe = SafePointer<Workspace>(this);
    if (projectReady && session.isSaving()) {
        session.waitForSave([safe, name, action, cancelled, confirmedRemotely](String error) {
            if (!safe) return;
            if (error.isEmpty()) safe->confirmProjectReplacement(name, action, cancelled, confirmedRemotely);
            else { if (cancelled) cancelled(); safe->showError(error); }
        });
        return;
    }
    if (projectReady && session.dirty) {
        CloseProjectSheet::open(*this, [safe, action, cancelled](int choice) {
            if (!safe) return;
            if (choice == 1) safe->chooseSave(false, action, cancelled);
            else if (choice == 2) action();
            else if (cancelled) cancelled();
        }, false, false, false, text(session.project().name));
        return;
    }
    if (!projectReady || confirmedRemotely) { action(); return; }
    ModalSheet::open(*this, localization::translate("Open another project?"),
        std::make_unique<ProjectOpenConfirmationPanel>(name, action, cancelled), confirmationStyle::width, 180);
}
std::function<void(String)> Workspace::beginProjectLoading(const File &file, const String &status) {
    if (!browserVisible) showProjectBrowser();
    const SafePointer<ProjectBrowser> browser(projectBrowser.get());
    browser->beginLoading(file);
    browser->updateLoading(status);
    return [browser](String error) {
        if (browser) browser->finishLoading(error);
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
            if(deletingCurrent)w.showProjectBrowser();w.resized();w.repaint();
        });
        ModalSheet::open(*this,localization::translate("Delete project"),std::move(panel),460,298);
    });
}
void Workspace::newProject() { showProjectBrowser(); }
void Workspace::showFileMenu() {
    const auto document = session.document;
    const SafePointer<Workspace> safe(this);
    Thread::launch([safe, document] {
        std::vector<File> files;
        try { if (document != File{}) files = projectBackups::files(document); } catch (const std::exception &) {}
        std::reverse(files.begin(), files.end());
        if (files.size() > 10) files.resize(10);
        const auto recent = RecentProjects::read();
        MessageManager::callAsync([safe, document, recent, files = std::move(files)] {
            if (!safe || safe->session.document != document || safe->browserVisible || !safe->isShowing()) return;
            const bool ready = safe->projectReady && !safe->session.busy && !safe->session.audio.isRecording();
            PopupMenu menu, recents, backups, imports;
            menu.addItem(1, String::fromUTF8("Início")); menu.addItem(2, "Open", ready);
            if (recent.isEmpty()) recents.addItem(92, (localization::english ? "No recent projects found." : "Nenhum projeto recente encontrado."), false);
            for (int i = 0; i < recent.size(); ++i)
                recents.addItem(200 + i, File(recent[i]).getFileNameWithoutExtension());
            menu.addSubMenu("Project Recents", recents, ready);
            menu.addItem(13, "Temporary Session", ready);
            menu.addItem(14, "Add Stems", ready && document != File{});
            menu.addSeparator();
            menu.addItem(4, "Save", ready); menu.addItem(5, "Save As", ready);
            if (document.existsAsFile())
                backups.addItem(90, "Saved     " + document.getLastModificationTime().formatted("%d/%m/%y, %H:%M:%S"), false);
            if (files.empty()) backups.addItem(91, localization::translate("No backups found"), false);
            else {
                if (document.existsAsFile()) backups.addSeparator();
                for (size_t i = 0; i < files.size(); ++i)
                    backups.addItem(100 + (int)i, "Backup " + String((int)i + 1) + "     " +
                        projectBackups::date(files[i]).formatted("%d/%m/%y, %H:%M:%S"), ready);
            }
            menu.addSubMenu("Backups", backups);
            menu.addSeparator();
            imports.addItem(10, "Audio to File"); imports.addItem(11, "Movie to File"); imports.addItem(12, "MIDI to File");
            menu.addSubMenu("Import", imports, ready);
            menu.addItem(6, "Export", ready);
            menu.addItem(8, "Share", ready);
            menu.addSeparator();
            menu.addItem(7, "Quit");
            menu.showMenuAsync(PopupMenu::Options().withTargetComponent(safe->controls["menu"]),
                [safe, document, files, recent](int choice) {
                    if (!safe || safe->session.document != document) return;
                    switch (choice) {
                        case 1: safe->showProjectBrowser(); safe->projectBrowser->showHome(); break;
                        case 2: safe->chooseOpen(true); break;
                        case 4: safe->chooseSave(); break;
                        case 5:
                            safe->confirm("Save As",
                                localization::english
                                    ? "The .jl file and all project media will be copied to a different folder."
                                    : String::fromUTF8("O arquivo .jl e todas as mídias do projeto serão copiados para outra pasta."),
                                [safe] { if (safe) safe->chooseSave(true, {}, {}, true); }, {}, localization::translate("Continue"));
                            break;
                        case 6: safe->chooseExport(); break;
                        case 7: JUCEApplication::getInstance()->systemRequestedQuit(); break;
                        case 8: safe->shareProject(); break;
                        case 10: case 11: case 12: safe->chooseTimelineFile(choice - 10); break;
                        case 13: safe->createTemporaryProject(); break;
                        case 14: safe->chooseImport(true); break;
                        default:
                            if (choice >= 200 && choice - 200 < recent.size()) {
                                safe->openProject(File(recent[choice - 200]), {}, false, false, {}, true);
                            } else if (choice >= 100 && (size_t)(choice - 100) < files.size()) {
                                const auto file = files[(size_t)(choice - 100)];
                                safe->confirm("Open backup?",
                                    localization::translate("Open this backup as a recovered project?") + "\n\n" + file.getFileName(),
                                    [safe, file] { if (safe) safe->openProject(file, {}, true); }, {}, localization::translate("Open"));
                            }
                    }
                });
        });
    });
}
void Workspace::shareProject() {
    if (!projectReady || session.busy || session.audio.isRecording()) return;
    const SafePointer<Workspace> owner(this);
    ModalSheet::open(*this, "Share", std::make_unique<PortableExportPanel>(session,
        [owner](std::function<void()> saved) {
            if (owner) owner->chooseSave(false, std::move(saved));
        }), 540, 376);
}
void Workspace::showProjectBrowser() {
    saveWorkspaceLayout();
    timeline->cancelInteraction();
    if (session.busy || session.audio.isRecording()) {
        showError("Wait for recording and imports before opening Projects.");
        return;
    }
    browserVisible = true;
    projectBrowser->setPlaybackRunning(session.transport().playing || session.transport().subPlay.playing);
    projectBrowser->refresh();
    if (!projectReady && !loginPanel) {
        if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
            if ((bool)window->getProperties().getWithDefault(editorWindowLayoutKey, false))
                editorWindowBounds = window->getBounds();
            fitProjectBrowserWindow(*window);
        }
    }
    resized();
    if (projectReady && !projectBrowser->isCurrentlyModal(false))
        projectBrowser->enterModalState(true);
    syncNativeTransport();
    repaint();
}
void Workspace::returnToWorkspace() {
    if (!browserVisible || !projectReady) return;
    if (projectBrowser->isCurrentlyModal(false)) projectBrowser->exitModalState(0);
    browserVisible = false;
    resized();
    repaint();
    grabKeyboardFocus();
}
void Workspace::projectOpened(bool fitTimeline) {
    tempoTaps = {};
    clearItemSelection();
    itemClipboard.reset();
    itemClipboardSequence.reset();
    const bool alreadyInEditor = projectReady;
    if (projectBrowser->isCurrentlyModal(false)) projectBrowser->exitModalState(0);
    projectReady = true;
    browserVisible = false;
    restoreWorkspaceLayout();
    if (session.document.existsAsFile())
        RecentProjects::remember(session.document);
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        if(loginPanel)fitLoginWindow(*window);
        else if (!alreadyInEditor) showEditorWindow(*window, editorWindowBounds);
    }
    resized();
    if (fitTimeline)
        timeline->initialView();
    repaint();
    grabKeyboardFocus();
    if (jaras::playbackCapacity::peak(session.project()) > jaras::playbackCapacity::limit)
        showPanel("Information", std::make_unique<ImportNoticePanel>(StringArray{localization::translate(String::fromUTF8(jaras::playbackCapacity::openingNotice))}), 560, 260);
}
namespace {
class ProjectOpeningProgressPanel final : public Component {
  public:
    explicit ProjectOpeningProgressPanel(String name) : fileName(std::move(name)) {
        getProperties().set("selfContainedSheet", true);
        setComponentID("project-opening-progress");
    }
    void update(const String &message, double amount) {
        status = localization::translate(message);
        if (amount >= 0) fraction = jlimit(0.0, 1.0, amount);
        repaint();
    }
    void paint(Graphics &g) override {
        auto bounds = getLocalBounds().reduced(22);
        g.setColour(Colours::white);
        g.setFont(theme::font(15, true));
        g.drawText(localization::translate("Opening project…"), bounds.removeFromTop(21), Justification::centredLeft);
        bounds.removeFromTop(10);
        theme::progressBar(g, bounds.removeFromTop(8).toFloat(), fraction);
        bounds.removeFromTop(8);
        g.setFont(theme::font(12));
        g.drawText(status, bounds.removeFromTop(17), Justification::centredLeft, true);
        g.setColour(theme::secondary);
        g.drawText(fileName, bounds.removeFromTop(17), Justification::centredLeft, true);
    }
  private:
    String fileName, status;
    double fraction = 0;
};
}

void Workspace::openProject(const File &file, std::function<void()> loaded, bool confirmed, bool allowMissing, ID remoteRequest, bool fromFileRecents) {
    const auto host = remoteHost;
    saveWorkspaceLayout();
    if (session.busy) {
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, "Wait for the current operation on the PC.");
        return;
    }
    if (browserVisible && projectReady && file == session.document) {
        returnToWorkspace();
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::completed);
        if (loaded) loaded();
        return;
    }
    if (activateExistingProjectTab && activateExistingProjectTab(file)) {
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::completed);
        return;
    }
    if (fromFileRecents && projectReady && file == session.document) return;
    timeline->cancelInteraction();
    if (file.hasFileExtension("ziplive;zip")) {
        if (!remoteRequest.empty()) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, "Import this package on the PC before opening it from Recent projects.");
        } else choosePackageDestination(file);
        return;
    }
    auto action = [safe = Component::SafePointer<Workspace>(this), host, remoteRequest, file, loaded, allowMissing, fromFileRecents] {
        if (!safe || safe->session.busy) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled);
            return;
        }
        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::opening, "Opening project…");
        try {
            if (safe->session.audio.isRecording())
                throw std::runtime_error("Conclua a gravação antes de abrir outro projeto.");
            std::function<void(String)> finish;
            SafePointer<ProjectOpeningProgressPanel> progressPanel;
            SafePointer<ProjectBrowser> browser;
            if (fromFileRecents && safe->projectReady) {
                auto panel = std::make_unique<ProjectOpeningProgressPanel>(file.getFileName());
                progressPanel = panel.get();
                ModalSheet::open(*safe, localization::translate("Opening project…"), std::move(panel), 400, 132);
                ModalSheet::blockDismiss(*progressPanel, true);
                finish = [safe, progressPanel](String error) {
                    if (progressPanel) {
                        ModalSheet::blockDismiss(*progressPanel, false);
                        ModalSheet::dismiss(*progressPanel);
                    }
                    if (safe && error.isNotEmpty()) safe->showError(error);
                };
            } else {
                finish = safe->beginProjectLoading(file, "Opening project…");
                browser = safe->projectBrowser.get();
            }
            try { safe->session.loadAsync(file,
                [browser, progressPanel, host, remoteRequest, backup = file.hasFileExtension("bkjl")](String status, double amount) {
                    host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::opening, utf8(status));
                    if (browser) browser->updateLoading(status, backup ? amount : -1);
                    if (progressPanel) progressPanel->update(status, amount);
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
                    [safe, host, remoteRequest, finish, file, loaded, fromFileRecents](StringArray paths) {
                        finish({});
                        if (!safe) {
                            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::cancelled);
                            return;
                        }
                        host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::waiting, "Resolve the missing audio files on the PC to continue opening the project.");
                        ModalSheet::open(*safe, localization::translate("Missing audio files"),
                            std::make_unique<MissingMediaPanel>(file, paths, [safe, host, remoteRequest, file, loaded, fromFileRecents](bool proceed) {
                                if (safe && proceed) safe->openProject(file, loaded, true, true, remoteRequest, fromFileRecents);
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
void Workspace::createTemporaryProject() {
    if (session.busy || session.isSaving() || session.audio.isRecording()) return;
    if (session.isTemporary()) { projectOpened(false); return; }
    confirmProjectReplacement(localization::translate("Temporary"), [safe = SafePointer<Workspace>(this)] {
        if (!safe) return;
        try {
            auto lease = std::make_unique<TemporaryProjectSession>();
            auto file = lease->directory.getChildFile("Temporary.jl");
            auto project = Session::makeEmptyProject(localization::translate("Temporary"));
            project.projectSyncID = uuid();
            ProjectCodec::write(file, ProjectCodec::encode(project));
            safe->session.temporarySession = std::move(lease);
            safe->openProject(file, {}, true);
        } catch (const std::exception &e) { safe->showError(String::fromUTF8(e.what())); }
    });
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
void Workspace::chooseOpen(bool projectOnly) {
    timeline->cancelInteraction();
    auto launch = [safe = Component::SafePointer<Workspace>(this), projectOnly] {
        if (!safe)
            return;
        safe->chooser = std::make_unique<FileChooser>(localization::translate("Open Project"),
                                                      safe->session.document, projectOnly ? "*.jl" : "*.jl;*.bkjl;*.ziplive;*.zip", true);
        safe->chooser->launchAsync(FileBrowserComponent::openMode |
                                       FileBrowserComponent::canSelectFiles,
                                   [safe, projectOnly](const FileChooser &fc) {
                                       if (!safe || fc.getResult() == File())
                                           return;
                                       const auto file=fc.getResult();
                                       if (projectOnly && !file.hasFileExtension("jl")) {
                                           safe->showError("Select a .jl project.");
                                           return;
                                       }
                                       MessageManager::callAsync([safe,file]{if(safe)safe->openProject(file);});
                                   });
    };
    launch();
}
void Workspace::chooseTimelineFile(int type) {
    const auto *song = session.song();
    if (!song || session.busy || session.audio.isRecording()) return;
    const auto checkTrack = [type](const jaras::Track &track) {
        if (type == 1) return track.role.id == "video" || jaras::isTeleprompterRole(track.role);
        return jaras::fixedTrackName(track.role).empty() && track.role.id != "vinhetas";
    };
    const ID track = selectedTrack;
    const auto index = trackTree::index(*song, track);
    const auto warning = localization::english ? "Select another track."
                                               : String::fromUTF8("Selecione outra pista.");
    if (index >= song->tracks.size() || !checkTrack(song->tracks[index])) { showError(warning); return; }
    const auto cursor = session.transport().editPosition;
    const auto project = session.project().id;
    const auto songID = song->id;
    const char *filters[] = {"*.wav;*.wave;*.aif;*.aiff;*.mp3;*.flac;*.ogg;*.m4a;*.aac",
                             "*.mp4;*.mov;*.m4v;*.avi;*.mkv;*.webm;*.wmv", "*.mid;*.midi"};
    chooser = std::make_unique<FileChooser>(localization::translate("Import"), File{}, filters[type], true);
    chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
        [safe = SafePointer<Workspace>(this), project, songID, track, cursor, checkTrack, warning, type](const FileChooser &picker) {
            const auto file = picker.getResult();
            if (!safe || file == File{} || safe->session.project().id != project ||
                !safe->session.song() || safe->session.song()->id != songID) return;
            const auto *song = safe->session.song();
            const auto index = trackTree::index(*song, track);
            if (index >= song->tracks.size() || !checkTrack(song->tracks[index])) { safe->showError(warning); return; }
            if (type != 2) {
                safe->importMediaAt({file}, cursor, track);
                return;
            }
            safe->perform([&] {
                FileInputStream stream(file);
                MidiFile source;
                if (!stream.openedOk() || !source.readFrom(stream))
                    throw std::runtime_error("Could not read the MIDI file.");
                source.convertTimestampTicksToSeconds();
                jaras::AudioClip clip;
                clip.id = uuid(); clip.name = utf8(file.getFileNameWithoutExtension()); clip.startTime = cursor;
                clip.midi.emplace();
                for (int i = 0; i < source.getNumTracks(); ++i) {
                    auto sequence = *source.getTrack(i);
                    sequence.updateMatchedPairs();
                    for (int j = 0; j < sequence.getNumEvents(); ++j) {
                        const auto *event = sequence.getEventPointer(j);
                        if (!event->message.isNoteOn() || !event->noteOffObject) continue;
                        const auto start = event->message.getTimeStamp();
                        const auto end = event->noteOffObject->message.getTimeStamp();
                        if (!std::isfinite(start) || !std::isfinite(end) || start < 0 || end <= start) continue;
                        clip.midi->notes.push_back({uuid(), start * 2, (end - start) * 2,
                            event->message.getNoteNumber(), event->message.getVelocity(), event->message.getChannel()});
                        clip.duration = std::max(clip.duration, end);
                    }
                }
                if (clip.midi->notes.empty()) throw std::runtime_error("The MIDI file contains no notes.");
                clip.regionOwnerID = jaras::regionOwnerAt(*song, cursor);
                safe->session.edit([&](auto &value) {
                    for (auto &arrangement : value.songs) if (arrangement.id == songID)
                        for (auto &row : arrangement.tracks) if (row.id == track) {
                            row.clips.push_back(clip);
                            arrangement.duration = std::max(arrangement.duration, cursor + clip.duration);
                        }
                });
            });
        });
}
void Workspace::chooseSave(bool saveAs, std::function<void()> saved, std::function<void()> cancelled, bool separateFolder) {
    auto finish = [safe = SafePointer<Workspace>(this), saved, cancelled](String error) {
        if (!safe) return;
        if (error.isNotEmpty()) { if (cancelled) cancelled(); safe->showError(error); return; }
        RecentProjects::remember(safe->session.document);
        if (saved) {
            // Close/export callbacks need the latest edit, not just the first
            // snapshot when the user kept editing during a regular Save.
            if (safe->session.dirty) safe->chooseSave(false, saved, cancelled);
            else saved();
        }
    };
    const bool promoting = session.isTemporary();
    if (!saveAs && !promoting && session.document != File()) {
        try { session.saveAsync(session.document, finish); }
        catch (const std::exception &error) { finish(String::fromUTF8(error.what())); }
        return;
    }
    if (session.isSaving()) {
        if (saveAs || promoting) {
            session.waitForSave([safe = SafePointer<Workspace>(this), project = session.project().id, saved, cancelled, separateFolder](String error) {
                if (!safe || safe->session.project().id != project) { if (cancelled) cancelled(); return; }
                if (error.isNotEmpty()) { if (cancelled) cancelled(); safe->showError(error); return; }
                safe->chooseSave(true, saved, cancelled, separateFolder);
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
            (separateFolder ? 0 : FileBrowserComponent::warnAboutOverwriting),
        [safe = Component::SafePointer<Workspace>(this), finish, cancelled, promoting, separateFolder](const FileChooser &fc) {
            if (!safe || fc.getResult() == File()) { if (cancelled) cancelled(); return; }
            try {
                auto target = fc.getResult().withFileExtension("jl");
                if (separateFolder && (target.getParentDirectory() == safe->session.mediaDirectory || target.exists()))
                    throw std::runtime_error("Escolha outra pasta e um nome de arquivo .jl que ainda não exista.");
                if (promoting) {
                    if (!safe->session.isTemporary()) { if (cancelled) cancelled(); return; }
                    auto folder = target.getParentDirectory().getNonexistentChildFile(target.getFileNameWithoutExtension(), "", false);
                    if (safe->session.temporarySession->insideTemporaryRoot(folder))
                        throw std::runtime_error("Choose a new folder outside catlive-temp.");
                    target = folder.getChildFile(target.getFileName());
                    safe->session.saveAsync(target, [safe, finish, target, folder](String error) {
                        if (!safe) return;
                        if (error.isNotEmpty()) { folder.deleteRecursively(); finish(error); return; }
                        // Reload the committed copy before deleting the scratch audio.
                        try { safe->session.loadAsync(target, {}, [safe] {
                            if (safe) safe->floatingWindows.clear();
                        }, [safe, finish](String result) {
                            if (safe && result.isEmpty()) safe->projectOpened();
                            finish(result);
                        }); } catch (const std::exception &e) { finish(String::fromUTF8(e.what())); }
                    });
                } else safe->session.saveAsync(target, finish);
            }
            catch (const std::exception &error) { finish(String::fromUTF8(error.what())); }
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
                                if(adding){if(safe->session.dirty){if(safe->session.isTemporary())safe->session.saveAsync(safe->session.document,[safe,launch](String error){if(!safe)return;if(error.isEmpty())launch();else safe->showError(error);});else safe->chooseSave(false,launch);}else launch();}
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
                                        if (!safe) return;
                                        auto report = warnings;
                                        for (const auto &issue : safe->session.projectReadWarnings) report.addIfNotAlreadyThere(issue);
                                        if (!report.isEmpty())
                                            safe->showPanel(String::fromUTF8("Migração de projeto"),
                                                std::make_unique<ImportNoticePanel>(report), 520, 316);
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
                                  }, [safe = Component::SafePointer<Workspace>(this)] {
                                      MessageManager::callAsync([safe] { if(safe)safe->openResolume(); });
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
              680, 600);
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
    auto panel=std::make_unique<AdvancedPanel>(appearance,session,[self=SafePointer<Workspace>(this)](String message){if(self)self->showError(message);});
    panel->transferPads=[self=SafePointer<Workspace>(this), owner=SafePointer<AdvancedPanel>(panel.get())](bool importing){if(self&&owner&&self->vinhetasPanel)self->vinhetasPanel->transferPackage(importing,owner.getComponent());};
    openFloating(name,std::move(panel),760,420);
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
void Workspace::exportMultitrack(std::set<ID> ids) {
    if (!session.song() || session.busy) return;
    const auto tabs = multitrackTabs ? multitrackTabs() : std::vector<std::pair<ID,Session *>>{{remoteProjectTabID, &session}};
    std::vector<MultitrackExportProject> configs;
    for (const auto &[tab, owner] : tabs) {
        if (!owner || !owner->song() || !owner->mediaDirectory.isDirectory()) continue;
        MultitrackExportProject config{tab, owner->project(), *owner->song(), owner->mediaDirectory};
        if (owner == &session)
            for (const auto &part : config.song.parts)
                if (ids.count(part.id) && multitrackExport::rootRegion(part)) config.selection.insert(part.id);
        configs.push_back(std::move(config));
    }
    const auto active = std::find_if(configs.begin(), configs.end(), [&](const auto &config) {
        return config.tab == remoteProjectTabID && !config.selection.empty();
    });
    if (active == configs.end()) return;
    ModalSheet::open(*this, localization::translate("Export Multitrack"),
        std::make_unique<MultitrackExportPanel>(session, std::move(configs), remoteProjectTabID), 620, 550);
}
void Workspace::exportRegions(std::set<ID> ids) {
    if (!session.song()) return;
    auto panel = std::make_unique<ExportPanel>(session, ID{}, ID{}, [safe=SafePointer<Workspace>(this)](String message) { if (safe) safe->showError(message); });
    panel->selectRegions(std::move(ids));
    ModalSheet::open(*this, String::fromUTF8("Exportar áudio"), std::move(panel), 760, 620);
}
namespace {
class BPMDetectionProgress final : public Component, private Timer {
    Session &session;
    double fraction = -1;
    ProgressBar progress{fraction};

    void timerCallback() override {
        if (!session.isDetectingBPM()) {
            stopTimer();
            ModalSheet::blockDismiss(*this, false);
            ModalSheet::dismiss(*this);
        }
    }

public:
    explicit BPMDetectionProgress(Session &value) : session(value) {
        getProperties().set("selfContainedSheet", true);
        progress.setPercentageDisplay(false);
        progress.setTitle(localization::translate("Detecting BPM…"));
        addAndMakeVisible(progress);
        startTimerHz(20);
    }

    void paint(Graphics &g) override {
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(13));
        g.drawText(localization::translate("Detecting BPM…"), 22, 17, getWidth() - 44, 26, Justification::centredLeft);
    }

    void resized() override {
        progress.setBounds(22, 46, getWidth() - 44, 22);
    }
};
}
void Workspace::detectRegions(std::set<ID> ids) {
    confirm("Detectar BPM", "Detectar BPM a partir da pista Click?", [safe = SafePointer<Workspace>(this), ids] {
        if (!safe || safe->session.isDetectingBPM()) return;
        safe->perform([&] {
            safe->session.detectRegionBPM(ids);
            if (!safe->session.isDetectingBPM()) return;
            auto progress = std::make_unique<BPMDetectionProgress>(safe->session);
            auto panel = SafePointer<BPMDetectionProgress>(progress.get());
            ModalSheet::open(*safe, "Detecting BPM…", std::move(progress), 340, 88);
            if (panel) ModalSheet::blockDismiss(*panel, true);
            safe->syncNativeTransport();
        });
    });
}
void Workspace::editMultiLoops(ID id) {
    ModalSheet::open(*this, "Multiloop Manager", std::make_unique<MultiLoopsPanel>(session,id,[safe=SafePointer<Workspace>(this)](String message){if(safe)safe->showError(message);}),760,540);
}
void Workspace::showRegionMenu(ID id, Point<int> point, std::set<ID> selection) {
    if (!session.song()) return;
    const bool unified = regionEditing::hasChildren(*session.song(),id);
    PopupMenu menu;
    menu.addItem(1, localization::translate(String::fromUTF8("Editar região"))); menu.addItem(2, localization::translate(String::fromUTF8("Detectar BPM…")));
    if (regionEditing::overlapping(*session.song(),id).size()>1) menu.addItem(3,localization::translate("Unificar"));
    if (unified) menu.addItem(4,localization::translate("Desunificar"));
    menu.addItem(5,localization::translate(String::fromUTF8("Exportar áudio"))); menu.addItem(6,localization::translate(String::fromUTF8("Excluir região")));
    const auto &song = *session.song();
    const auto part = std::find_if(song.parts.begin(), song.parts.end(), [&](const auto &candidate) { return candidate.id == id; });
    if (part != song.parts.end() && multitrackExport::rootRegion(*part))
        menu.addItem(7, localization::translate("Export Multitrack"));
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),[safe=SafePointer<Workspace>(this),id,selection=std::move(selection)](int action){
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
        if(action==7) safe->exportMultitrack(selection.count(id) ? selection : std::set<ID>{id});
    });
}
void Workspace::deleteRegions(std::set<ID> ids, bool withContents) {
    if (!session.song()) return;
    const auto projectID=session.project().id, songID=session.song()->id;
    confirm(String::fromUTF8("Excluir região"), withContents ? String::fromUTF8("Excluir as músicas selecionadas, seus itens e marcadores? Os arquivos de mídia permanecem na pasta do projeto.") : String::fromUTF8("Excluir esta região?"),
        [safe=SafePointer<Workspace>(this),ids,withContents,projectID,songID] {
        if (!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID) return;
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
    ModalSheet::open(*this,String::fromUTF8("Marcador de tempo"),std::make_unique<TempoMarkerPanel>(marker,save),420,164);
}
PopupMenu Workspace::masterMenu(bool barMixer) const {
    PopupMenu menu;
    menu.addItem(1,"Patch"); menu.addItem(2,"FX"); menu.addItem(3,"Env");
    if(barMixer) {
        menu.addSeparator();
        menu.addItem(5,String::fromUTF8((bool)appearance.value("catlive.barMixer.masterRight",false)
            ?"Mostrar Main à esquerda":"Mostrar Main à direita"));
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
void Workspace::syncHozMixerTrackStyle() {
    const bool stripeOnly = appearance.mixerStripeOnly(theme::hozMixerStyleKey);
    if (footerMixer) footerMixer->setStripeOnly(stripeOnly);
    if (focusMixer) focusMixer->setStripeOnly(stripeOnly);
    for (const auto &entry : floatingWindows)
        if (auto *panel = dynamic_cast<MixerPanel *>(entry.second->getContentComponent())) panel->setStripeOnly(stripeOnly);
}
void Workspace::editTrack(ID id, std::set<ID> targets) {
    const auto *song = session.song();
    if (!song)
        return;
    const auto at = trackTree::index(*song, id);
    if (at == song->tracks.size())
        return;
    const auto track = song->tracks[at];
    if (targets.empty()) targets.insert(id);
    for (auto i = targets.begin(); i != targets.end();)
        if (trackTree::index(*song, *i) == song->tracks.size()) i = targets.erase(i); else ++i;
    const bool multiple = targets.size() > 1;
    const auto projectID = session.project().id, songID = song->id;
    const String title = multiple ? "Editar pistas" : "Editar pista";
    const auto safe = SafePointer<Workspace>(this);
    auto close = [safe, title] {
        if (safe)
            for (auto *child : safe->getChildren())
                if (auto *sheet = dynamic_cast<ModalSheet *>(child);
                    sheet && sheet->getName() == title) {
                    sheet->exitModalState(0);
                    break;
                }
    };
    auto save = [safe, targets, projectID, songID, close](String, unsigned colour, bool) {
        if (!safe || safe->session.project().id != projectID || !safe->session.song() || safe->session.song()->id != songID)
            return;
        safe->perform([&] {
            safe->session.edit(
                [&](jaras::Project &p) {
                    for (auto &s : p.songs) if (s.id == songID)
                        for (auto &t : s.tracks)
                            if (targets.count(t.id)) t.color = colour;
                },
                false);
            close();
        });
    };
    ModalSheet::open(*this, title,
                     std::make_unique<RegionEditor>(text(track.name),
                                                    theme::track(track).getARGB() & 0xffffff, false,
                                                    save, close, false, false),
                     300, 320);
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
    if(action=="clickPatch" || action=="patch"){showPanel("Patch",std::make_unique<PatchPanel>(session,id,[safe=SafePointer<Workspace>(this)](String error){if(safe)safe->showError(error);}),360,250);return;}
    if(action=="pcPatch"){showPanel("Patch",std::make_unique<PatchPanel>(session,id,[safe=SafePointer<Workspace>(this)](String error){if(safe)safe->showError(error);}),360,270);return;}
    if(action=="settings") {showPanel("Timecode",std::make_unique<PatchPanel>(session,id,[safe=SafePointer<Workspace>(this)](String error){if(safe)safe->showError(error);}),360,400);return;}
    if(action=="text"){addTextItem(id,session.transport().editPosition);return;}
    if(action=="fullLyrics") {
        const Component::SafePointer<Workspace> owner(this);
        perform([this,id,owner] {
            const auto *song=session.song(); if(!song)return;
            const auto range=jaras::fullLyrics::range(*song,session.transport().editPosition);
            const auto projectID=session.project().id, songID=song->id;
            auto save=[safe=owner,id,projectID,songID,range](String draft)->String {
                if(!safe)return {};
                try {
                    if(safe->session.busy)throw std::runtime_error("Aguarde a operação atual terminar.");
                    if(safe->session.project().id!=projectID||!safe->session.song()||safe->session.song()->id!=songID)
                        throw std::runtime_error("O projeto mudou. Abra Letra Completa novamente.");
                    const auto current=jaras::fullLyrics::range(*safe->session.song(),(range.start+range.end)/2);
                    if(current.region!=range.region||current.start!=range.start||current.end!=range.end)
                        throw std::runtime_error("A música mudou. Abra Letra Completa novamente.");
                    auto items = jaras::fullLyrics::items(range, utf8(ItemTextColors::plain(draft)), [] { return uuid(); });
                    const auto formatted = ItemTextColors::stanzas(draft);
                    if (formatted.size() == items.size())
                        for (size_t i = 0; i < items.size(); ++i) items[i].text = utf8(formatted[i]);
                    safe->session.edit([&](jaras::Project &project) {
                        for(auto &s:project.songs)if(s.id==songID)for(auto &track:s.tracks)if(track.id==id&&jaras::isTeleprompterRole(track.role)) {
                            track.clips.insert(track.clips.end(),items.begin(),items.end());
                            std::stable_sort(track.clips.begin(),track.clips.end(),[](const auto &a,const auto &b){return a.startTime<b.startTime;});
                            return;
                        }
                        throw std::runtime_error("A pista de texto não existe mais.");
                    },false);
                    safe->selectedClips.clear();for(const auto &item:items)safe->selectedClips.insert(item.id);
                    safe->selectedClip=items.front().id;safe->selectedTrack=id;safe->updateState();
                    return {};
                } catch(const std::exception &error) {return String::fromUTF8(error.what());}
            };
            ModalSheet::open(*this,localization::translate("Full lyrics"),std::make_unique<FullLyricsPanel>(text(range.name),save),620,460);
        });
        return;
    }
    if(action=="mtc"||action=="ltc"||action=="click") {
        perform([&]{session.edit([&](jaras::Project &p){for(auto &song:p.songs)for(auto &track:song.tracks)if(track.id==id){
            if(action=="click"&&track.role.id=="generatedClick") {
                for(const auto &part:song.parts)if(!part.parentRegionID&&part.endTime>part.startTime) {
                    if(std::any_of(track.clips.begin(),track.clips.end(),[&](const auto &c){return c.regionOwnerID==part.id || clipEditing::generatedClickRegion(song,c)==&part;}))continue;
                    jaras::AudioClip clip;clip.id=part.id;if(!clip.id.empty()){const int digit=CharacterFunctions::getHexDigitValue(clip.id[0]);if(digit>=0)clip.id[0]="0123456789abcdef"[digit^4];}
                    clip.name="Click · "+part.name;clip.startTime=part.startTime;clip.duration=part.endTime-part.startTime;clip.regionOwnerID=part.id;track.clips.push_back(clip);
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

void Workspace::showChordMenu(const ID &track, const ID &marker, Point<int> point) {
    if (marker.empty()) return;
    PopupMenu menu;
    const auto project = session.project().id;
    const auto song = session.song() ? session.song()->id : ID{};
    menu.addItem(1, localization::translate("Delete"), !jaras::projectSync::readOnly());
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
        [safe=SafePointer<Workspace>(this), project, song, track, marker](int choice) {
            if (!safe || choice != 1 || safe->session.project().id != project || !safe->session.song() ||
                safe->session.song()->id != song || jaras::projectSync::readOnly()) return;
            safe->perform([&] {
                safe->session.edit([&](jaras::Project &value) {
                    for (auto &source : value.songs) if (source.id == song)
                        for (auto &row : source.tracks) if (row.id == track) {
                            auto &markers = row.chordMarkers;
                            markers.erase(std::remove_if(markers.begin(), markers.end(), [&](const auto &cue) { return cue.id == marker; }), markers.end());
                        }
                }, false);
            });
        });
}

void Workspace::toggleTrackMixerComponents(const std::set<ID>& ids, int mask) {
    const auto *song = session.song();
    if (!song || ids.empty()) return;
    const auto songID = song->id;
    const bool restore = std::all_of(song->tracks.begin(), song->tracks.end(), [&](const auto &t) {
        return !t.supportsMixerComponents() || !ids.count(t.id) || (t.hiddenMixerComponents.value_or(0) & mask) == mask;
    });
    perform([&] {
        session.edit([&](jaras::Project &p) {
            for (auto &s : p.songs) if (s.id == songID) for (auto &t : s.tracks) if (t.supportsMixerComponents() && ids.count(t.id)) {
                const int old = t.hiddenMixerComponents.value_or(0);
                const int next = restore ? old & ~mask : old | mask;
                t.hiddenMixerComponents = next ? std::optional<int>(next) : std::nullopt;
            }
        }, false);
        for (auto *row : rows) row->resized();
        resized();
        timeline->updateRanges();
        repaint();
    });
}
void Workspace::showTrackMenu(ID id, Point<int> point, bool trackMixerMenu) {
    if(id.empty()){showMasterMenu(point,true);return;}
    const auto *song = session.song(); if (!song) return;
    const auto at = trackTree::index(*song,id); if (at == song->tracks.size()) return;
    const auto &track = song->tracks[at];
    auto targets = trackSelected(id) ? selectedTracks : std::set<ID>{id};
    targets.insert(id);
    const bool standard = jaras::fixedTrackName(track.role).empty();
    const bool groupable = trackEditing::canCreateGroup(*song,id,targets);
    PopupMenu menu;
    if (standard || track.role.id=="timecode" || track.role.id=="video" || track.role.id=="generatedClick" || track.role.id=="programChange") menu.addItem(1,"Patch");
    if (track.role.id=="generatedClick") menu.addItem(2,"Sound Designer");
    if (standard) { menu.addItem(3,"FX"); if(track.role.id!="vinhetas") { menu.addItem(4,"Criar item MIDI"); if(trackMixerMenu)menu.addSeparator(); } if(groupable)menu.addItem(5,localization::translate(String::fromUTF8("Criar grupo"))); }
    if (trackTree::end(*song,at)>at+1) menu.addItem(6,localization::translate("Ungroup"));
    if (track.parentTrackID) menu.addItem(7,localization::translate("Remover do grupo"));
    if (standard && trackEditing::linkable(*song,targets)) menu.addItem(8,localization::translate("Link tracks"));
    if (track.stereoLinkPartner) menu.addItem(9,localization::translate("Unlink tracks"));
    menu.addItem(10,localization::translate("Set Track Color"));
    menu.addItem(13,localization::translate("Set Track Icon"));
    if (standard && track.role.id!="vinhetas") menu.addItem(12, targets.size() > 1 ? localization::translate("Duplicar pistas") : localization::translate("Duplicar pista"));
    if (track.supportsMixerComponents() && trackMixerMenu) {
        menu.addSeparator();
        PopupMenu components;
        const char *titles[]{"Patch","FX","Envelope","Rec","Input Monitor","Pan","M","S","Phase"};
        for (int i=0;i<9;++i) if (titles[i]) components.addItem(100+i,titles[i],true,track.showsComponent(1<<i));
        menu.addSubMenu("Componentes View",components);
    }
    menu.addSeparator(); menu.addItem(11,targets.size()>1 ? localization::translate("Delete tracks") : localization::translate("Delete track"));
    const auto project = session.project().id, songID = song->id;
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x,point.y,1,1}),
        [safe=SafePointer<Workspace>(this),id,targets,project,songID](int choice) {
            if(!safe || !choice || safe->session.project().id!=project || !safe->session.song() || safe->session.song()->id!=songID)return;
            auto &w=*safe;
            if(choice>=100 && choice<109) { w.toggleTrackMixerComponents({id},1<<(choice-100)); return; }
            if(choice==1)showPanel("Patch",std::make_unique<PatchPanel>(w.session,id,[safe](String error){if(safe)safe->showError(error);},targets),360,400);
            if(choice==2)ModalSheet::open(w,"Sound Designer",std::make_unique<ClickSoundDesigner>(w.session,id),390,280);
            if(choice==3)w.openFX(id);
            if(choice==4)w.addMIDIItem(id,w.session.transport().editPosition);
            if(choice==10)w.editTrack(id,targets);
            if(choice==13)w.editTrackIcon(id);
            if(choice==12)w.perform([&] {
                const auto copies=w.session.duplicateTracks(targets);
                w.selectAndRevealTrackCopies(copies);
            });
            if(choice>=5 && choice<=7)w.perform([&]{w.session.editTrackHierarchy(songID,[&](jaras::Song &s){
                if(choice==5)trackEditing::createGroup(s,id,targets);
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
    bool projection = false, hasFX = false, generatedClick = false, doubledClick = false;
    ID ownerID;
    bool fileItem = false, separable = false, durationItem = false, rateItem = false;
    if (const auto *song = session.song())
        for (const auto &track : song->tracks)
            for (const auto &clip : track.clips)
                if (clip.id == id) {
                    ownerID = track.id;
                    rateItem = jaras::itemSupportsRate(track,clip);
                    generatedClick = track.role.id == "generatedClick" && !clip.audioFile;
                    doubledClick = clip.clickDouble.value_or(false);
                    separable = audioSeparation::eligible(track,clip);
                    fileItem = clip.audioFile.has_value() && !clip.midi;
                    if(const auto source=clip.audioFile ? clip.audioFile : track.audioFile; source && !clip.midi)
                        durationItem=!File::getCurrentWorkingDirectory().getChildFile(text(source->path)).hasFileExtension("png;jpg;jpeg;gif;heic;heif;tif;tiff;bmp;webp;avif");
                    textItem = clip.text && !clip.audioFile;
                    audioItem = jaras::fixedTrackName(track.role).empty();
                    midiItem = clip.midi.has_value();
                    muted = clip.muted;
                    projection = track.role.id == "video" && clip.audioFile.has_value();
                    hasFX = clip.fxJSON && !list(get(JSON::parse(text(*clip.fxJSON)), "inserted")).isEmpty();
                }
    if(generatedClick)menu.addItem(43,doubledClick?"1x":"2x");
    if ((fileItem || midiItem) && (!clipSelected(id) || selectedClips.size() <= 1)) {
        menu.addItem(41, "Editar nome"); menu.addSeparator();
    }
    if (fileItem && (!clipSelected(id) || selectedClips.size() <= 1)) {
        menu.addItem(40, localization::translate("Open file location")); menu.addSeparator();
    }
    if(rateItem)menu.addItem(46,localization::translate("Config rate"));
    if (midiItem) {
        menu.addItem(2,muted?localization::translate("Desmutar itens"):localization::translate("Mutar itens"));menu.addItem(31,localization::translate("Convert To Audio Mono"));menu.addItem(32,localization::translate("Convert To Audio Stereo"));menu.addItem(14,localization::translate("Unificar itens"));if(hasFX)menu.addItem(15,"FX");
        menu.addSeparator();menu.addItem(42, "Exportar MIDI", !clipSelected(id) || selectedClips.size() <= 1);
    } else {
        if(audioItem || projection) {
            menu.addItem(9,localization::translate(String::fromUTF8("Criar região do item")));menu.addItem(13,"Re-render");menu.addItem(14,localization::translate("Unificar itens"));menu.addItem(10,"Tuner");
            if(separable&&(!clipSelected(id)||selectedClips.size()<=1))menu.addItem(16,"Separation audio");
            menu.addItem(11,localization::translate(String::fromUTF8("Normalizar…")));
            menu.addItem(44,localization::translate("Reset rate"));
            if(durationItem)menu.addItem(45,localization::translate("Reset duration"));
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
                if(action==46) {
                    if(w.session.project().id!=projectID || !w.session.song() || w.session.song()->id!=songID)return;
                    double initial=1,base=w.session.song()->bpm;
                    for(const auto& track:w.session.song()->tracks)for(const auto& clip:track.clips)if(clip.id==id) {
                        initial=track.role.id=="generatedClick" && !clip.audioFile ? clip.tempoBasePlaybackRate.value_or(clip.playbackRate) : clip.playbackRate;
                        double latest=-std::numeric_limits<double>::infinity();
                        if(w.session.song()->markers)for(const auto& marker:*w.session.song()->markers)
                            if(marker.tempoBPM && marker.position<=clip.startTime && marker.position>=latest){base=*marker.tempoBPM;latest=marker.position;}
                    }
                    auto close=[safe]{if(safe)ModalSheet::dismiss(*safe);};
                    ModalSheet::open(w,localization::translate("Config rate"),std::make_unique<ItemRatePanel>(initial,base,
                        [safe,targets,projectID,songID,close](double rate,bool resetTempo) {
                            if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID){close();return;}
                            if(timelineGrid::regionsLocked(safe->session.project()))return;
                            safe->perform([&]{safe->session.edit([&](jaras::Project& project){
                                for(auto& song:project.songs)if(song.id==songID)for(auto& track:song.tracks)for(auto& clip:track.clips)
                                    if(targets.count(clip.id) && jaras::itemSupportsRate(track,clip)) {
                                        const double previous=track.role.id=="generatedClick" && !clip.audioFile?clip.tempoBasePlaybackRate.value_or(clip.playbackRate):clip.playbackRate;
                                        if(previous==rate && !resetTempo)continue;
                                        if(resetTempo)clip=jaras::resettingItemRate(song,clip);
                                        clip=jaras::itemWithRate(song,clip,rate,&track);
                                        if(track.role.id=="timecode" && !clip.audioFile && !track.importedTimecodeItems)
                                            for(const auto& region:song.parts)if(regionEditDetail::timecodeItemID(region.id)==clip.id) {
                                                clip.timecodeStartOffset=clip.startTime-region.startTime;
                                                clip.timecodeEndOffset=clip.startTime+clip.duration-region.endTime;break;
                                            }
                                        song.duration=std::max(song.duration,clip.startTime+clip.duration);
                                    }
                            });close();});
                        },close),360,225);
                    return;
                }
                if(action==45) {
                    w.confirm(localization::translate("Reset duration"),localization::translate("Restore the full original file duration for the selected items?"),[safe,targets,projectID,songID] {
                        if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID ||
                           timelineGrid::regionsLocked(safe->session.project()))return;
                        const auto original=*safe->session.song();
                        const auto directory=safe->session.mediaDirectory;
                        Thread::launch([safe,targets,projectID,songID,original,directory] {
                            std::map<ID,double> durations;
                            String error;
                            try {
                                AudioFormatManager formats;registerAudioFormats(formats);
                                for(const auto& track:original.tracks)for(const auto& clip:track.clips)if(targets.count(clip.id) && !clip.midi) {
                                    const auto file=clip.audioFile ? clip.audioFile : track.audioFile;
                                    if(!file)continue;
                                    const auto source=ProjectCodec::resolveMedia(directory,file->path);
                                    if(source.hasFileExtension("png;jpg;jpeg;gif;heic;heif;tif;tiff;bmp;webp;avif"))continue;
                                    double duration=0;
                                    if(auto reader=std::unique_ptr<AudioFormatReader>(formats.createReaderFor(source)))
                                        duration=double(reader->lengthInSamples)/reader->sampleRate;
                                    else duration=inspectMediaSource(source).duration;
                                    if(!std::isfinite(duration) || duration<=0)throw std::runtime_error("Could not read imported audio");
                                    durations[clip.id]=duration;
                                }
                            } catch(const std::exception& e) {error=text(e.what());}
                            MessageManager::callAsync([safe,projectID,songID,original,durations,error] {
                                if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID ||
                                   timelineGrid::itemsLocked(safe->session.project()))return;
                                if(error.isNotEmpty()){safe->session.message=error;safe->updateState();return;}
                                safe->perform([&]{safe->session.edit([&](jaras::Project& project){
                                    for(auto& song:project.songs)if(song.id==songID)for(auto& track:song.tracks)for(auto& clip:track.clips) {
                                        const auto value=durations.find(clip.id);if(value==durations.end())continue;
                                        // Resolve against current geometry/tempo; metadata belongs to this source.
                                        const auto oldTrack=std::find_if(original.tracks.begin(),original.tracks.end(),[&](const auto& t){return t.id==track.id;});
                                        if(oldTrack==original.tracks.end())continue;
                                        const auto oldClip=std::find_if(oldTrack->clips.begin(),oldTrack->clips.end(),[&](const auto& c){return c.id==clip.id;});
                                        if(oldClip==oldTrack->clips.end())continue;
                                        const auto oldFile=oldClip->audioFile?oldClip->audioFile:oldTrack->audioFile;
                                        const auto currentFile=clip.audioFile?clip.audioFile:track.audioFile;
                                        if(oldClip->startTime!=clip.startTime || oldClip->duration!=clip.duration || oldClip->sourceOffset!=clip.sourceOffset ||
                                           oldFile.has_value()!=currentFile.has_value() || (oldFile && oldFile->path!=currentFile->path))continue;
                                        clip=jaras::restoringItemDuration(song,clip,value->second);
                                        song.duration=std::max(song.duration,clip.startTime+clip.duration);
                                    }
                                });});
                            });
                        });
                    });
                    return;
                }
                if(action==44) {
                    w.confirm("Redefinir rate", "Redefinir os itens selecionados para 1x sem alterar os marcadores de tempo?", [safe,targets,projectID,songID] {
                        if(!safe || safe->session.project().id!=projectID || !safe->session.song() || safe->session.song()->id!=songID)return;
                        safe->perform([&]{safe->session.edit([&](jaras::Project &p){
                            for(auto &song:p.songs)if(song.id==songID)for(auto &track:song.tracks)for(auto &clip:track.clips)if(targets.count(clip.id)) {
                                clip=jaras::resettingItemRate(song,clip);
                            }
                        });});
                    });
                    return;
                }
                if(action==43) {
                    if(w.session.project().id!=projectID || !w.session.song() || w.session.song()->id!=songID)return;
                    w.session.edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==songID)for(auto &t:s.tracks)if(t.id==ownerID && t.role.id=="generatedClick")for(auto &c:t.clips)if(c.id==id && !c.audioFile)c.clickDouble=!c.clickDouble.value_or(false);});
                    return;
                }
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
                    auto *dialog = new AlertWindow("Separation audio", "", MessageBoxIconType::NoIcon, &w);
                    auto choices = std::make_shared<std::vector<std::unique_ptr<ToggleButton>>>();
                    for (const auto &name : audioSeparation::instruments()) {
                        auto button = std::make_unique<ToggleButton>(localization::translate(name));
                        button->setSize(220, 26);
                        button->setToggleState(true, dontSendNotification);
                        dialog->addCustomComponent(button.get());
                        choices->push_back(std::move(button));
                    }
                    dialog->addButton(localization::translate("Separate"), 1);
                    dialog->addButton(localization::translate("Cancelar"), 0, KeyPress(KeyPress::escapeKey));
                    for (const auto &choice : *choices) choice->onClick = [dialog, controls = std::weak_ptr(choices)] {
                        if (auto list = controls.lock())
                            if (auto *button = dialog->getButton(0))
                                button->setEnabled(std::any_of(list->begin(), list->end(), [](const auto &c) { return c->getToggleState(); }));
                    };
                    dialog->enterModalState(true, ModalCallbackFunction::create([safe,projectID,songID,id,dialog,choices](int answer) {
                        std::set<int> instruments;
                        for (size_t i = 0; i < choices->size(); ++i)
                            if ((*choices)[i]->getToggleState()) instruments.insert(static_cast<int>(i));
                        while (dialog->getNumCustomComponents() > 0) dialog->removeCustomComponent(0);
                        if (answer != 1 || instruments.empty() || !safe || safe->session.project().id != projectID ||
                            !safe->session.song() || safe->session.song()->id != songID) return;
                        try {
                            safe->session.separateAudioItem(id,[safe,projectID,songID](std::set<ID> ids){
                                if(!safe||safe->session.project().id!=projectID||!safe->session.song()||safe->session.song()->id!=songID)return;
                                safe->selectedClips=std::move(ids);safe->selectedClip=safe->selectedClips.empty()?ID{}:*safe->selectedClips.begin();safe->updateState();
                            },std::move(instruments));
                            if(safe->session.busy)ModalSheet::open(*safe,"Separation audio",std::make_unique<AudioSeparationPanel>(safe->session),440,204);
                        } catch (const std::exception &error) { safe->showError(String::fromUTF8(error.what())); }
                    }),true);
                    return;
                }
                if(action==15){w.openItemFX(id);return;}
                if (action == 10) {
                    auto panel = std::make_unique<ItemTunerPanel>(w.session, id,
                        [safe](String message) { if (safe) safe->showError(message); }, targets);
                    const int height = panel->preferredHeight();
                    ModalSheet::open(w, "Tuner", std::move(panel), 440, height);
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
    if (selectionAreas.activeScope() == "tracks") {
        if (moving || !session.song() || session.busy) return;
        const auto targets = selectedTracks.empty() ? std::set<ID>{selectedTrack} : selectedTracks;
        perform([&] {
            const auto captured = session.snapshot();
            bool eligible = false;
            for (const auto &song : list(get(captured, "songs"))) if (utf8(str(song, "id")) == session.song()->id)
                for (const auto &track : list(get(song, "tracks")))
                    if (targets.count(utf8(str(track, "id"))) && trackEditing::duplication::standard(track)) eligible = true;
            if (!eligible) return;
            if (!gridMediaClipboard::claimItems(getPeer() ? static_cast<HWND>(getPeer()->getNativeHandle()) : nullptr))
                throw std::runtime_error("Could not access the clipboard. Try copying again.");
            trackClipboard = CopiedTracks{captured, session.song()->id, targets, GetClipboardSequenceNumber()};
            itemClipboard.reset(); gridMediaClipboard::sharedItems.reset();
            session.programChangeClipboard.reset(); session.programChangePasteReady = false;
            timeline->invalidate();
        });
        return;
    }
    if(session.selectedProgramMarker()) {
        if(!moving && session.copyProgramChange()){
            gridMediaClipboard::sharedItems.reset();
            gridMediaClipboard::claimItems(getPeer() ? static_cast<HWND>(getPeer()->getNativeHandle()) : nullptr);
            itemClipboard.reset();itemClipboardSequence=GetClipboardSequenceNumber();
        }
        return;
    }
    if (!session.song() || session.busy || (moving && timelineGrid::itemsLocked(session.project()))) return;
    const auto selection = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
    if (auto copied = GridItemClipboard::copy(session.project(), session.song()->id, selection, moving)) {
        if (!gridMediaClipboard::claimItems(getPeer() ? static_cast<HWND>(getPeer()->getNativeHandle()) : nullptr)) {
            session.message = localization::translate("Could not access the clipboard. Try copying again."); updateState(); return;
        }
        session.programChangeClipboard.reset();session.programChangePasteReady=false;
        itemClipboard = std::move(copied);
        itemClipboardSequence = GetClipboardSequenceNumber();
        gridMediaClipboard::sharedItems = moving ? std::nullopt : itemClipboard;
        gridMediaClipboard::sharedSequence = itemClipboardSequence;
        gridMediaClipboard::sharedDirectory = session.mediaDirectory;
        timeline->invalidate();
    }
}
void Workspace::pasteGridItems(bool duplicate) {
    if (!session.song() || session.busy) return;
    const bool pastedTracks = !duplicate && trackClipboard && trackClipboard->sequence == GetClipboardSequenceNumber();
    if (pastedTracks || (duplicate && selectionAreas.activeScope() == "tracks")) {
        if (pastedTracks && (trackClipboard->song != session.song()->id ||
            utf8(str(trackClipboard->document, "id")) != session.project().id)) return;
        perform([&] {
            const auto targets = pastedTracks ? trackClipboard->targets : selectedTracks.empty() ? std::set<ID>{selectedTrack} : selectedTracks;
            const bool followsPrevious = pastedTracks && !trackClipboard->lastSelected.empty() &&
                selectedTrack == trackClipboard->lastSelected && selectedTracks == std::set<ID>{selectedTrack};
            const auto after = followsPrevious ? trackClipboard->previousCopies : std::map<ID, ID>{};
            std::map<ID, ID> mapping;
            const auto copies = session.duplicateTracks(targets, pastedTracks ? &trackClipboard->document : nullptr, after, &mapping);
            selectAndRevealTrackCopies(copies);
            if (pastedTracks && !copies.empty()) {
                trackClipboard->previousCopies = std::move(mapping);
                trackClipboard->lastSelected = selectedTrack;
            }
        });
        return;
    }
    const bool sharedCopy = !duplicate && gridMediaClipboard::ownsItems(gridMediaClipboard::sharedItems.has_value(),
        gridMediaClipboard::sharedSequence, GetClipboardSequenceNumber());
    if (sharedCopy) {
        itemClipboard = gridMediaClipboard::sharedItems;
        itemClipboardSequence = gridMediaClipboard::sharedSequence;
        session.programChangeClipboard.reset(); session.programChangePasteReady = false;
        if (itemClipboard->project != session.project().id || itemClipboard->song != session.song()->id ||
            gridMediaClipboard::sharedDirectory != session.mediaDirectory) {
            const SafePointer<Workspace> destinationWorkspace(this);
            perform([&] {
                auto plan = itemClipboard->copyPlan(*session.song(), session.transport().editPosition,
                    selectedTracks.empty() ? std::set<ID>{selectedTrack} : selectedTracks);
                auto prepared = session.project();
                for (auto &song : prepared.songs) if (song.id == session.song()->id)
                    song.tracks.insert(song.tracks.end(), plan.newTracks.begin(), plan.newTracks.end());
                auto validation = session.core; validation.applyProjectEdit(std::move(prepared));
                validation.pasteItems(session.song()->id, plan.entries, false);
                const auto projectID = session.project().id, songID = session.song()->id;
                const auto source = gridMediaClipboard::sharedDirectory, destination = session.mediaDirectory;
                session.busy = true; updateState();
                Thread::launch([safe = destinationWorkspace, entries = std::move(plan.entries), newTracks = std::move(plan.newTracks), source, destination, projectID, songID]() mutable {
                    gridMediaClipboard::Transfer transfer;
                    String error;
                    try { transfer = gridMediaClipboard::stage(std::move(entries), source, destination); }
                    catch (const std::exception &e) { error = String::fromUTF8(e.what()); }
                    MessageManager::callAsync([safe, transfer = std::move(transfer), newTracks = std::move(newTracks), error, destination, projectID, songID]() mutable {
                        if (!safe) { transfer.discard(); return; }
                        safe->session.busy = false;
                        try {
                            if (error.isNotEmpty()) throw std::runtime_error(utf8(error));
                            if (safe->session.project().id != projectID || !safe->session.song() ||
                                safe->session.song()->id != songID || safe->session.mediaDirectory != destination)
                                throw std::runtime_error("The destination project is no longer active.");
                            safe->session.edit([&](auto &project) {
                                for (auto &song : project.songs) if (song.id == songID)
                                    song.tracks.insert(song.tracks.end(), newTracks.begin(), newTracks.end());
                                auto edit = safe->session.core; edit.applyProjectEdit(project);
                                edit.pasteItems(songID, transfer.tracks, false); project = edit.project();
                            });
                            safe->selectedClips.clear();
                            for (const auto &track : transfer.tracks) for (const auto &clip : track.clips) safe->selectedClips.insert(clip.id);
                            safe->selectedClip = safe->selectedClips.empty() ? ID{} : *safe->selectedClips.begin();
                            safe->session.message.clear();
                        } catch (const std::exception &e) { transfer.discard(); safe->session.message = localization::translate(String::fromUTF8(e.what())); }
                        safe->timeline->invalidate(); safe->updateState(); safe->repaint();
                    });
                });
            });
            return;
        }
    }
    if(!duplicate && session.programChangeClipboard) {perform([&]{pasteProgramMarker();});return;}
    if (!duplicate && !gridMediaClipboard::ownsItems(itemClipboard.has_value(), itemClipboardSequence,
                                                    GetClipboardSequenceNumber())) {
        perform([&] {
            const auto paths = gridMediaClipboard::files();
            if (paths.isEmpty()) return;
            Array<File> media;
            for (const auto &path : paths) media.add(File(path));
            ID target;
            for (const auto &track : session.song()->tracks)
                if (trackSelected(track.id)) { target = track.id; break; }
            importMediaAt(media, session.transport().editPosition, target);
        });
        return;
    }
    const auto selection = selectedClips.empty() ? std::set<ID>{selectedClip} : selectedClips;
    const auto clipboard = duplicate ? GridItemClipboard::copy(session.project(), session.song()->id, selection) : itemClipboard;
    if (!clipboard || clipboard->song != session.song()->id ||
        (clipboard->moving && timelineGrid::itemsLocked(session.project()))) return;
    perform([&] {
        const auto entries = clipboard->items(session.project(), duplicate ? clipboard->endPosition() : session.transport().editPosition,
                                              duplicate ? std::set<ID>{} : selectedTracks.empty() ? std::set<ID>{selectedTrack} : selectedTracks);
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
void Workspace::selectAndRevealTrackCopies(const std::vector<ID> &copies) {
    const auto *song = session.song();
    if (!song || copies.empty()) return;
    const std::set<ID> created(copies.begin(), copies.end());
    const auto last = std::find_if(song->tracks.rbegin(), song->tracks.rend(), [&](const auto &track) { return created.count(track.id); });
    if (last == song->tracks.rend()) return;
    const ID id = last->id;
    auto parent = last->parentTrackID;
    for (size_t guard = 0; parent && guard < song->tracks.size(); ++guard) {
        collapsedGroups.erase(*parent);
        const auto index = trackTree::index(*song, *parent);
        parent = index < song->tracks.size() ? song->tracks[index].parentTrackID : std::optional<ID>{};
    }
    rebuild();
    footerMixer->refresh();
    for (const auto &entry : floatingWindows)
        if (auto *mixer = dynamic_cast<MixerPanel *>(entry.second->getContentComponent())) mixer->refresh();
    selectMixerTrack(id, {}, true, trackSelectionFromFooter);
}
bool Workspace::stepMixerTrack(int direction, bool rename) {
    const auto *song = session.song();
    if (!song || song->tracks.empty()) return false;
    const int count = (int)song->tracks.size();
    const auto current = trackTree::index(*song, selectedTrack);
    const int start = current < song->tracks.size() ? (int)current : (direction > 0 ? -1 : count);
    for (int row = start + direction; row >= 0 && row < count; row += direction) {
        const auto &track = song->tracks[(size_t)row];
        if (rowHidden(row) || (rename && !canRenameMixerTrack(track))) continue;
        if (rename && start >= 0 && start < rows.size()) rows[start]->confirmRename();
        selectMixerTrack(track.id, {});
        if (rename && row < rows.size()) rows[row]->beginRename();
        break;
    }
    return true;
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
    if (clearItems && selectedTracks.count(id)) {
        const auto row = std::find(builtTracks.begin(), builtTracks.end(), id);
        if (row != builtTracks.end()) {
            const int index = int(row - builtTracks.begin());
            const auto visible = tracksViewport.getViewArea();
            if (visible.getHeight() > 0 && !rowHidden(index)) {
                const int top = rowTop(index), bottom = top + rowHeight(index);
                if (top < visible.getY() || bottom - top > visible.getHeight()) tracksViewport.scrollTo(top);
                else if (bottom > visible.getBottom()) tracksViewport.scrollTo(bottom - visible.getHeight());
            }
        }
        if (footerMixerVisible) footerMixer->revealTrack(id);
        for (const auto &entry : floatingWindows)
            if (auto *mixer = dynamic_cast<MixerPanel *>(entry.second->getContentComponent())) mixer->revealTrack(id);
    }
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
void Workspace::refreshToolbarPanelIndicators() {
    const auto floatingVisible = [this](const String &name) {
        const auto window = floatingWindows.find(name);
        return window != floatingWindows.end() && window->second->isVisible();
    };
    const auto update = [this](const char *id, int signal) {
        auto *button = controls.at(id);
        if ((int)button->getProperties()["toolbarSignal"] == signal) return;
        button->getProperties().set("toolbarSignal", signal);
        button->repaint();
    };
    update("menu", browserVisible ? 1 : 0);
    update("library", libraryVisible ? 1 : 0);
    update("focus", focusVisible ? 1 : 0);
    update("mixer", mixerVisible ? 1 : 0);
    update("railMixer", (footerMixerVisible || (mixerDetached && floatingVisible("Mixer"))) ? 1 : 0);
    update("matrixPatch", floatingVisible("Matrix Patch") ? 1 : 0);
    update("railParts", (partsLeftVisible || (partsLeftDetached && floatingVisible("Parts"))) ? 1 : 0);
    update("railNotice", floatingVisible("Recados") ? 1 : 0);
    update("railClock", (floatingVisible(String::fromUTF8("Cronômetro")) || stageTimer->isVisible()) ? 1 : 0);
    update("midiPreview", midiPreviewVisible || (midiPreviewDetached && floatingVisible("MIDI Preview")));
    update("railKeyboard", keyboardVisible ? 1 : 0);
    update("railVinhetas", (vinhetasVisible || (vinhetasDetached && floatingVisible("Vinhetas"))) ? 1 : 0);
    update("advanced", floatingVisible(String::fromUTF8("Avançado")) ? 1 : 0);
    update("grandma2", floatingVisible("grandMA2") ? 1 : 0);
    update("resolume", floatingVisible("Resolume") ? 1 : 0);
    update("settings", floatingVisible(String::fromUTF8("Configurações")) ? 1 : 0);
    update("tp1", floatingVisible("Teleprompter 1") ? 1 : 0);
    update("tp2", floatingVisible("Teleprompter 2") ? 1 : 0);
    update("preview", stage.preview ? 1 : 0);
    update("video", floatingVisible("Video") ? 1 : 0);
    update("remote", remoteHost->enabled() ? 1 : 0);
}
void Workspace::mapMixerControl(const ID &track, jaras::CommandKind kind) {
    if (!session.song()) return;
    int number = 0;
    if (!track.empty()) {
        const auto &song = *session.song();
        const auto index = trackTree::index(song, track);
        if (index >= song.tracks.size() || !actionTrack(song, {}, int(index) + 1)) return;
        number = int(index) + 1;
    }
    String action;
    switch (kind) {
        case jaras::CommandKind::volume: action = track.empty() ? "volumeMaster" : "volumeTrack"; break;
        case jaras::CommandKind::mute: action = track.empty() ? "muteMaster" : "muteTrack"; break;
        case jaras::CommandKind::solo: action = track.empty() ? "soloMaster" : "soloTrack"; break;
        default: return;
    }
    auto page = std::make_unique<ActionsPage>(actions);
    page->showAction(ActionBindings::targetID(action, number), "midi");
    ModalSheet::open(*this, localization::translate("Map control"), std::move(page), 430, 280);
}
void Workspace::showDetachedMixer() {
    mixerDetached = true; footerMixerVisible = false;
    auto panel = std::make_unique<MixerPanel>(session, [this](ID id, String key) { openFX(id, key); },
        [this](ID id, ModifierKeys mods) { selectMixerTrack(id, mods, true, true); }, [this](String message) { showError(message); },
        [this](ID id, bool remove) { changeMixerFX(id, remove); },
        [this](ID id) { return trackSelected(id); }, [this](ID id,Point<int> point){showTrackMenu(id,point,false);},[this](ID id,String action){specialTrackAction(id,action);},
        [this](ID id){return !session.song()||trackVisibility.visible(*session.song(),TrackVisibility::Panel::barMixer,id);});
    panel->addTrackInEmptyArea = [this] { addStandardTrackAtEnd(); };
    panel->mapControl = [this](const ID &id, jaras::CommandKind kind) { mapMixerControl(id, kind); };
    panel->setMasterRight((bool)appearance.value("catlive.barMixer.masterRight",false));
    panel->setStripeOnly(appearance.mixerStripeOnly(theme::hozMixerStyleKey));
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
    openFloating("Recados", std::make_unique<NoticePanel>(stage), 720, 430);
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
    String name = "Main";
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
                 std::make_unique<StageConfigPanel>(stage, index),
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
                                         controls["railClock"]->getBounds(), this);
        return;
    }
    showPanel(String::fromUTF8("Cronômetro"),
              std::make_unique<StageTimerSettings>(stage), 380, 388);
}
void Workspace::requestClose(std::function<void()> done, bool application, std::optional<bool> saveAll,
                             std::function<void()> cancelled) {
    if(jaras::projectSync::readOnly()) { if (cancelled) cancelled(); return; }
    if (session.isSaving()) {
        session.waitForSave([safe = SafePointer<Workspace>(this), done, application, saveAll, cancelled](String error) {
            if (!safe) return;
            if (error.isNotEmpty()) { if (cancelled) cancelled(); safe->showError(error); }
            else safe->requestClose(done, application, saveAll, cancelled);
        });
        return;
    }
    if (isCurrentlyBlockedByAnotherModalComponent()) {
        if (cancelled) cancelled();
        ModalComponentManager::getInstance()->bringModalComponentsToFront();
        return;
    }
    if (session.busy) {
        if (cancelled) cancelled();
        showError(String::fromUTF8("Aguarde a importação terminar antes de fechar."));
        return;
    }
    if (session.transport().playing || session.transport().subPlay.playing) {
        if (saveAll.has_value()) {
            // The application-wide decision already approved closing all tabs.
            session.command(jaras::CommandKind::stopAll);
            requestClose(done, application, saveAll, cancelled);
            return;
        }
        CloseProjectSheet::open(*this,
                [safe = Component::SafePointer<Workspace>(this), done, application, cancelled](int action) {
                    if (safe && action == 2) {
                        safe->session.command(jaras::CommandKind::stopAll);
                        safe->requestClose(done, application, {}, cancelled);
                    } else if (cancelled) cancelled();
                }, true, application);
        return;
    }
    if (session.dirty && !session.isTemporary()) {
        if (saveAll.has_value()) {
            if (*saveAll) chooseSave(false, done, cancelled);
            else done();
            return;
        }
        CloseProjectSheet::open(*this,
                [safe = Component::SafePointer<Workspace>(this), done, cancelled](int action) {
                    if (!safe)
                        return;
                    if (action == 2)
                        done();
                    if (action == 1) safe->chooseSave(false, done, cancelled);
                    if (action == 0 && cancelled) cancelled();
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
    const StringArray nativeButtons{"play", "pause", "loop", "record", "metronome"};
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
        if (StringArray{"play", "record"}.contains(entry.first)) {
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
        maximum=workspaceBounds.getWidth()-100-other-focusMixer->getWidth()-workspaceLibrary->getWidth()-(mixerVisible?180:0)-(dockedSetlist?minimumSetlistWidth:0);
    }
    auto &width=left?partsLeftWidth:partsRightWidth;
    width=jlimit(160,std::max(160,std::min(900,maximum)),resizeStart+(left?delta:-delta));
    resized();repaint();
}
void Workspace::detachLeftParts() {
    if (partsLeftHorizontal) return;
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
    menu.addItem(1, localization::translate(partsLeftDetached ? "Dock Parts" : "Undock Parts"), !partsLeftHorizontal);
    menu.addItem(2, partsLeftHorizontal ? "Vert-Parts" : "Hoz-Parts", !partsLeftDetached);
    menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({point.x, point.y, 1, 1}),
        [safe = SafePointer<Workspace>(this)](int choice) {
            if (!safe || choice == 0) return;
            if (choice == 2) {
                if (safe->partsLeftDetached) return;
                safe->partsLeftHorizontal = !safe->partsLeftHorizontal;
                safe->partsLeftVisible = true;
                if (safe->partsLeftHorizontal) safe->partsRightVisible = false;
                else safe->focusVisible = false;
                safe->resized(); safe->repaint();
                return;
            }
            if (!safe->partsLeftDetached) { safe->detachLeftParts(); return; }
            safe->addAndMakeVisible(*safe->partsLeft);
            if (auto it = safe->floatingWindows.find("Parts"); it != safe->floatingWindows.end()) it->second->setVisible(false);
            safe->partsLeftDetached = false; safe->partsLeftVisible = true; safe->focusVisible = false;
            safe->resized(); safe->repaint();
        });
}
void Workspace::toggleFocus() {
    focusVisible = !focusVisible;
    if (focusVisible && !partsLeftHorizontal) {
        partsLeftVisible = false;
        if (auto at = floatingWindows.find("Parts"); at != floatingWindows.end()) at->second->setVisible(false);
    }
    if (focusVisible) focusMixer->refresh();
    resized();
    repaint();
}
void Workspace::toggleLeftParts() {
    if (partsLeftDetached) {
        if (auto it = floatingWindows.find("Parts"); it != floatingWindows.end()) {
            it->second->setVisible(!it->second->isVisible());
            if (it->second->isVisible()) {
                focusVisible = false;
                it->second->toFront(true);
            }
        } else {
            focusVisible = false;
            detachLeftParts();
        }
        resized(); repaint(); return;
    }
    partsLeftVisible = !partsLeftVisible;
    if (partsLeftVisible) {
        if (partsLeftHorizontal) partsRightVisible = false;
        else focusVisible = false;
    }
    resized();
    repaint();
}
void Workspace::toggleRightParts() {
    partsRightVisible = !partsRightVisible;
    if (partsRightVisible && partsLeftHorizontal) partsLeftVisible = false;
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
    if (const auto it = floatingWindows.find("Exportar"); it != floatingWindows.end()) {
        if (it->second->isVisible()) {
            it->second->setMinimised(false);
            it->second->toFront(true);
            return;
        }
        floatingWindows.erase(it);
    }
    auto panel = std::make_unique<ExportPanel>(session, selectedTrack, selectedClip,
                                      [safe = SafePointer<Workspace>(this)](String error) {
                                          if (safe)
                                              safe->showError(error);
                                      }, false, false, appearance.storageFile());
    if (selectedTracks.empty() && !selectedTrack.empty()) panel->setMixerTracks({selectedTrack});
    else panel->setMixerTracks(selectedTracks);
    openFloating("Exportar", std::move(panel), 860, 600);
}
void Workspace::openFX(ID track, String preferredEffect) {
    if (jaras::projectSync::readOnly()) return;
    if (preferredEffect.isEmpty()) {
        if (!track.empty()) selectMixerTrack(track, {});
        if (!focusVisible) toggleFocus();
        return;
    }
    if (preferredEffect == "Library") {
        if (!libraryVisible) { libraryVisible = true; resized(); repaint(); }
        return;
    }
    const auto settings = fxchain::settings(session, track);
    if (!list(get(settings, "inserted")).contains(var(preferredEffect))) return;
    String name = "Main";
    for (const auto &song : session.project().songs)
        for (const auto &t : song.tracks)
            if (t.id == track)
                name = text(t.name);
    String title = preferredEffect;
    for (const auto &effect : list(get(settings, "instances")))
        if (preferredEffect == "Native:" + str(effect, "id") || preferredEffect == "Instance:" + str(effect, "id"))
            title = str(effect, "kind");
    for (const auto &plugin : list(get(settings, "externalPlugins")))
        if (preferredEffect == "External:" + str(plugin, "id")) title = str(plugin, "name");
    const String windowName = title + " - " + name;
    const String windowKey = "plugin:" + text(track) + ":" + preferredEffect;
    if (const auto it = floatingWindows.find(windowKey); it != floatingWindows.end() && it->second->isVisible()) {
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
                     }, false, preferredEffect);
    const auto editor = SafePointer<EffectsPanel>(panel.get());
    openFloating(windowName, std::move(panel), 740, 560, windowKey);
    if (editor && preferredEffect.isNotEmpty()) editor->selectEffect(preferredEffect);
}
void Workspace::openItemFX(ID id) {
    if(jaras::projectSync::readOnly()) return;
    String name;
    if (const auto *song=session.song()) for(const auto &track:song->tracks) for(const auto &clip:track.clips)
        if(clip.id==id) name=text(clip.name);
    auto panel = std::make_unique<EffectsPanel>(session, id,
        [safe=SafePointer<Workspace>(this)](String error){if(safe) safe->showError(error);}, true);
    panel->openLibrary = [safe=SafePointer<Workspace>(this)] { if (safe) safe->openFX({}, "Library"); };
    openFloating("FX - " + name, std::move(panel), 920, 560);
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
#include "WorkspaceSMK37.h"
#include "WorkspaceMediaImportRegression.h"

namespace catlive {
void Workspace::closePads() {
    vinhetasVisible = false;
    if (auto at = floatingWindows.find("Vinhetas"); at != floatingWindows.end()) at->second->setVisible(false);
}
void Workspace::closePanelsForPads() {
    keyboardVisible = false;
    midiPreviewVisible = false;
    if (auto at = floatingWindows.find("MIDI Preview"); at != floatingWindows.end()) at->second->setVisible(false);
}
void Workspace::toggleMIDIPreviewDock() {
    closePads();
    if (midiPreviewDetached) {
        floatingWindows.erase("MIDI Preview"); dockContent.addAndMakeVisible(*midiPreviewPanel);
        midiPreviewDetached=false; midiPreviewVisible=true;
    } else {
        class Holder final : public Component {
          public:
            explicit Holder(Component &content):panel(content){addAndMakeVisible(panel);}
            void resized() override { panel.setBounds(getLocalBounds()); }
          private: Component &panel;
        };
        midiPreviewDetached=true; midiPreviewVisible=false;
        openFloating("MIDI Preview",std::make_unique<Holder>(*midiPreviewPanel),900,midiPreviewHeight);
    }
    resized();
}
void Workspace::toggleVinhetasDock() {
    closePanelsForPads();
    if(vinhetasDetached){floatingWindows.erase("Vinhetas");dockContent.addAndMakeVisible(*vinhetasPanel);vinhetasDetached=false;vinhetasVisible=true;}
    else {
        class Holder final : public Component { public: VinhetasPanel &panel; explicit Holder(VinhetasPanel &p):panel(p){addAndMakeVisible(panel);} void resized() override {panel.setBounds(getLocalBounds());} };
        vinhetasDetached=true;vinhetasVisible=false;openFloating("Vinhetas",std::make_unique<Holder>(*vinhetasPanel),1100,260);
    }
    resized();
}
}
