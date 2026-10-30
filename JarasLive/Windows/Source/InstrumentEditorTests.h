#pragma once
#include "InstrumentParameterEditor.h"
#include "FXSchema.h"

namespace catlive::instrumentEditorTests {
inline Component *find(Component &parent, const String &id) {
    if (parent.getComponentID() == id) return &parent;
    for (auto *child : parent.getChildren()) if (auto *match = find(*child, id)) return match;
    return nullptr;
}
template<class Test, class Require>
void run(Test test, Require require, const File &directory) {
    test("Instrument category artwork is bundled for all fifteen families", [&] {
        StringArray categories;
        for (auto entry : instrumentAssets::catalog()) categories.addIfNotAlreadyThere(str(entry, "category"));
        require(categories.size() == 15, "Unexpected instrument family count");
        const auto folder = File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("InstrumentInterfaces");
        for (const auto &category : categories) {
            const auto image = ImageFileFormat::loadFrom(folder.getChildFile(category + ".png"));
            require(image.isValid() && image.getWidth() >= 1000, "Missing or invalid instrument artwork: " + category);
        }
    });
    test("Instrument editor fits every tab in the default FX manager and scrolls short windows", [&] {
        auto settings = object();
        InstrumentParameterEditor editor("astoria-grand", [&] { return settings; }, [] {}, [] {});
        editor.setSize(690, 416);
        auto *viewport = dynamic_cast<Viewport *>(find(editor, "instrumentParametersViewport"));
        require(viewport != nullptr, "Instrument parameter viewport missing");
        for (int page = 0; page < 4; ++page) {
            editor.selectPage(page);
            require(!viewport->getVerticalScrollBar().isVisible(), "Default FX window hides instrument controls below its bottom");
            for (auto *child : viewport->getViewedComponent()->getChildren()) {
                if (child->isVisible()) require(viewport->getViewArea().contains(child->getBounds()), "Instrument control is clipped in the default FX window");
            }
            auto stream = directory.getChildFile("instrument-default-" + String(page) + ".png").createOutputStream();
            require(stream && PNGImageFormat().writeImageToStream(editor.createComponentSnapshot(editor.getLocalBounds()), *stream), "Cannot capture default instrument layout");
        }
        editor.setSize(690, 290); editor.selectPage(0);
        require(viewport->getVerticalScrollBar().isVisible(), "Short FX window must keep controls reachable by scrolling");
        viewport->setViewPosition(0, viewport->getViewedComponent()->getHeight());
        auto *gain = find(editor, "instrumentKnob__gain");
        require(gain && viewport->getViewArea().contains(gain->getBounds()), "Last instrument control cannot be reached in a short window");
    });
    test("Instrument editor four tabs preview and persist the Mac parameter document", [&] {
        auto settings = object(); int previews = 0, commits = 0;
        InstrumentParameterEditor editor("astoria-grand", [&] { return settings; }, [&] { ++previews; }, [&] {
            ++commits; settings = fxschema::complete(settings); // Commit replaces the document, as Session does.
        });
        editor.setSize(730, 540);
        require(get(settings, "instrumentParameters").isVoid() && commits == 0, "Opening an instrument modified its settings");
        const auto choose = [&](const char *tab) {
            auto *button = dynamic_cast<Button *>(find(editor, "instrumentTab" + String(tab)));
            require(button != nullptr, "Missing instrument tab"); button->onClick();
            auto stream = directory.getChildFile("instrument-" + String(tab) + ".png").createOutputStream();
            require(stream && PNGImageFormat().writeImageToStream(editor.createComponentSnapshot(editor.getLocalBounds()), *stream), "Cannot capture instrument tab");
        };
        const auto value = [&](const char *group, const char *key, double amount, double stored) {
            auto *slider = dynamic_cast<Slider *>(find(editor, "instrumentValue_" + String(group) + "_" + key));
            require(slider != nullptr && slider->getWidth() > 50, "Instrument knob missing or clipped");
            const auto before = previews; slider->setValue(amount, sendNotificationSync);
            auto p = get(settings, "instrumentParameters"); if (*group) p = get(p, Identifier(group));
            require(std::abs(num(p, Identifier(key)) - stored) < .00001 && previews > before, "Instrument parameter did not preview/persist in its correct group");
        };
        choose("Envelope"); value("", "attack", 250, .25); value("", "hold", 500, .5);
        value("", "decay", 1000, 1); value("", "sustain", 40, .4); value("", "release", 1500, 1.5); value("", "gain", -6, -6);
        choose("Velocity"); value("velocity", "cutoffMinimum", 900, 900);
        auto *curve = dynamic_cast<Button *>(find(editor, "instrumentCurve0")); require(curve, "Missing velocity curve"); curve->onClick();
        require(str(get(get(settings, "instrumentParameters"), "velocity"), "curve") == "soft", "Velocity curve was not saved");
        choose("Cutoff"); value("cutoff", "frequency", 1800, 1800); value("cutoff", "depth", 3, 3);
        value("cutoff", "attack", 120, .12); value("cutoff", "hold", 200, .2); value("cutoff", "decay", 800, .8);
        value("cutoff", "sustain", 60, .6); value("cutoff", "release", 400, .4);
        choose("Controller"); value("controllers", "volume", -12, -12);
        auto *mono = dynamic_cast<Button *>(find(editor, "instrumentMonophonic")); require(mono, "Missing voice mode"); mono->onClick();
        for (const char *id : {"instrumentModulation", "instrumentPitchBend"}) {
            auto *button = dynamic_cast<ToggleButton *>(find(editor, id)); require(button, "Missing MIDI controller option");
            button->setToggleState(true, dontSendNotification); button->onClick();
        }
        const auto controllers = get(get(settings, "instrumentParameters"), "controllers");
        require(flag(controllers, "monophonic") && flag(controllers, "modulation") && flag(controllers, "pitchBend"), "Controller options did not persist");
        choose("Envelope");
        auto *attack = dynamic_cast<Slider *>(find(editor, "instrumentValue__attack"));
        require(attack && attack->getValue() == 250 && commits == previews, "Tab changes lost edits or slider commits");
        require(num(get(get(settings, "instrumentParameters"), "cutoff"), "frequency") == 1800, "Envelope tab overwrote cutoff settings");
    });
}
} // namespace catlive::instrumentEditorTests
