#pragma once
#include "InterfaceIcons.h"
#include "Localization.h"
#include "EditorShortcuts.h"
namespace catlive {
class ModalSheet final : public Component {
  public:
    ModalSheet(String title, std::unique_ptr<Component> contents, int width, int height)
        : heading(std::move(title)), content(std::move(contents)), preferredWidth(width),
          preferredHeight(height) {
        setName(heading);
        const bool selfContained = (bool)content->getProperties()["selfContainedSheet"];
        if (selfContained) content->setName(heading);
        headerHeight = selfContained ? 0 : heading == String::fromUTF8("Configurações") || heading == "Projetos" ? 76
                       : heading == "Resolume"                                               ? 66
                                                                                             : 44;
        close.getProperties().set("textClose", heading == "Resolume");
        setComponentID("modalSheet");
        addAndMakeVisible(*content);
        content->setCachedComponentImage(new RoundedContentRenderer(*content));
        addAndMakeVisible(close);
        close.setVisible(!selfContained);
        close.onClick = [this] {
            if (!blocked)
                exitModalState(0);
        };
        setWantsKeyboardFocus(true);
        setFocusContainerType(FocusContainerType::focusContainer);
    }
    void paint(Graphics &g) override {
        g.fillAll(Colours::black.withAlpha(.48f));
        DropShadow(Colours::black.withAlpha(.3f), 20, {0, 8}).drawForRectangle(g, frame);
        g.setColour(theme::background);
        g.fillRoundedRectangle(frame.toFloat(), 16);
        if (headerHeight == 0) return;
        g.setColour(theme::line);
        g.drawHorizontalLine(frame.getY() + headerHeight - 1,
                             (float)frame.getX() + (heading == "Resolume" ? 24 : 0),
                             (float)frame.getRight() - (heading == "Resolume" ? 24 : 0));
        g.setColour(Colours::white);
        g.setFont(theme::font(heading == "Resolume" ? 17 : 13, true));
        g.drawText(localization::translate(heading),
                   frame.getX() + (heading == "Resolume" ? 24 : 16), frame.getY(),
                   frame.getWidth() - 70, headerHeight - 1, Justification::centredLeft);
    }
    void resized() override {
        int width = std::min(preferredWidth, std::max(100, getWidth() - 40));
        int height = std::min(preferredHeight + headerHeight, std::max(100, getHeight() - 48));
        frame = {std::max(0, (getWidth() - width) / 2), std::max(0, (getHeight() - height) / 2),
                 width, height};
        content->setBounds(frame.withTrimmedTop(headerHeight));
        close.setBounds(frame.getRight() - 46, frame.getY() + (headerHeight - 32) / 2, 32, 32);
        if (heading == "Resolume")
            close.setBounds(frame.getRight() - 90, frame.getY() + 24, 66, 24);
    }
    bool keyPressed(const KeyPress &key) override {
        if (retryEditorShortcut(key))
            return true;
        if (key == KeyPress::escapeKey) {
            if (!blocked)
                exitModalState(0);
            return true;
        }
        if (key == KeyPress::returnKey && content->keyPressed(key))
            return true;
        return false;
    }
    static void open(Component &parent, String name, std::unique_ptr<Component> panel, int width,
                     int height) {
        const SafePointer<Component> previousFocus(Component::getCurrentlyFocusedComponent());
        auto *sheet = new ModalSheet(std::move(name), std::move(panel), width, height);
        parent.addAndMakeVisible(sheet);
        sheet->setBounds(parent.getLocalBounds());
        sheet->toFront(true);
        sheet->enterModalState(
            true, ModalCallbackFunction::create([safe = SafePointer<Component>(&parent), previousFocus](int) {
                if (previousFocus && previousFocus->isShowing() && !previousFocus->isCurrentlyBlockedByAnotherModalComponent()) {
                    previousFocus->grabKeyboardFocus(); return;
                }
                if (safe && safe->isShowing() && !safe->isCurrentlyBlockedByAnotherModalComponent())
                    safe->grabKeyboardFocus();
            }),
            true);
        if (sheet->content->getWantsKeyboardFocus()) sheet->content->grabKeyboardFocus();
    }
    static void resizeContent(Component &child, int height) {
        if (auto *sheet = child.findParentComponentOfClass<ModalSheet>()) {
            sheet->preferredHeight = height;
            sheet->resized();
            sheet->repaint();
        }
    }
    static void dismiss(Component &child) {
        if (auto *sheet = child.findParentComponentOfClass<ModalSheet>()) {
            if (!sheet->blocked)
                sheet->exitModalState(0);
        } else if (auto *sheet =
                       dynamic_cast<ModalSheet *>(Component::getCurrentlyModalComponent());
                   sheet && child.isParentOf(sheet)) {
            if (!sheet->blocked)
                sheet->exitModalState(0);
        } else if (auto *dialog = child.findParentComponentOfClass<DialogWindow>())
            dialog->exitModalState(0);
    }
    static void blockDismiss(Component &child, bool value) {
        if (auto *sheet = child.findParentComponentOfClass<ModalSheet>()) {
            sheet->blocked = value;
            sheet->close.setEnabled(!value);
        }
    }

  private:
    // Use the component painting hook solely to clip its children. An image
    // effect rendered the entire panel to a bitmap first, then sampled that
    // bitmap again at fractional desktop origins (notably at 90% UI scale).
    // Draw text and controls directly at the destination's physical scale.
    class RoundedContentRenderer final : public CachedComponentImage {
      public:
        explicit RoundedContentRenderer(Component &component) : owner(component) {}
        void paint(Graphics &g) override {
            Path clip;
            clip.addRoundedRectangle(0, 0, (float)owner.getWidth(), (float)owner.getHeight(),
                                     16, 16, false, false, true, true);
            Graphics::ScopedSaveState saved(g);
            g.reduceClipRegion(clip);
            // paintEntireComponent bypasses this painting hook, as it does
            // for JUCE's normal CachedComponentImage implementation.
            owner.paintEntireComponent(g, false);
        }
        bool invalidateAll() override { return true; }
        bool invalidate(const juce::Rectangle<int> &) override { return true; }
        void releaseResources() override {}
      private:
        Component &owner;
    };
    class Close final : public Button {
      public:
        Close() : Button("Fechar") {}
        void paintButton(Graphics &g, bool over, bool) override {
            if ((bool)getProperties()["textClose"]) {
                g.setColour(over ? Colour(0xff606060) : Colour(0xff484848));
                g.fillRoundedRectangle(getLocalBounds().toFloat(), 5);
                g.setColour(Colours::white);
                g.setFont(theme::font(12));
                g.drawText("Fechar", getLocalBounds(), Justification::centred);
                return;
            }
            g.setColour(over ? Colours::white : theme::secondary);
            drawInterfaceIcon(g, "close", getLocalBounds().toFloat().reduced(8));
        }
    } close;
    String heading;
    std::unique_ptr<Component> content;
    int preferredWidth, preferredHeight, headerHeight = 44;
    bool blocked = false;
    juce::Rectangle<int> frame;
};
} // namespace catlive
