#pragma once
#include "CatDynamicsAssets.h"
#include "Localization.h"
namespace catlive {
class CatDynamicsEditor final : public Component {
    struct Control { String key, title, suffix; double low, high, step, multiplier; };
    String effect;
    File directory;
    std::function<var()> read;
    std::function<void()> save, preview;
    std::function<void(String)> report;
    std::vector<Control> controls;
    OwnedArray<ParameterSlider> sliders;
    OwnedArray<Label> labels;
    ToggleButton enabled;
    TextButton loadSample;
    Label sampleName, description;
    std::unique_ptr<FileChooser> chooser;
    bool trigger() const { return effect == "CatLive Trigger"; }
    const char *group() const { return trigger() ? "trigger" : "gate"; }
    var parameters() const { return get(read(), group()); }
    void updateSample() {
        const auto path = str(parameters(), "samplePath");
        const auto name = path.fromLastOccurrenceOf("/", false, false);
        sampleName.setText(path.isEmpty() ? localization::translate("No sample loaded") : name, dontSendNotification);
        sampleName.setColour(Label::textColourId, path.isNotEmpty() && !directory.getChildFile(path).existsAsFile() ? theme::yellow : theme::secondary);
    }
    void chooseSample() {
        chooser = std::make_unique<FileChooser>(localization::translate("Load sample"), directory, "*.wav;*.mp3");
        chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
            [safe = SafePointer<CatDynamicsEditor>(this)](const FileChooser &browser) {
                if (!safe || browser.getResult() == File()) return;
                try {
                    auto path = dynamicsAssets::importSample(browser.getResult(), safe->directory);
                    auto parameters = safe->parameters(); put(parameters, "samplePath", path); safe->save();
                    if (safe) safe->updateSample();
                } catch (const std::exception &error) { if (safe) safe->report(localization::translate(String::fromUTF8(error.what()))); }
            });
    }
  public:
    CatDynamicsEditor(String name, File projectDirectory, std::function<var()> values,
                      std::function<void()> changed, std::function<void(String)> error, std::function<void()> livePreview = {})
        : effect(std::move(name)), directory(std::move(projectDirectory)), read(std::move(values)),
          save(std::move(changed)), preview(std::move(livePreview)), report(std::move(error)) {
        setComponentID(trigger() ? "catLiveTriggerEditor" : "catGateEditor");
        enabled.setButtonText(localization::translate("Ativado"));
        enabled.setToggleState(flag(read(), trigger() ? Identifier("triggerEnabled") : Identifier("gateEnabled")), dontSendNotification);
        enabled.setComponentID("dynamicsEnabled"); addAndMakeVisible(enabled);
        enabled.onClick = [this] { auto settings = read(); put(settings, trigger() ? Identifier("triggerEnabled") : Identifier("gateEnabled"), enabled.getToggleState()); save(); };
        description.setFont(theme::font(12)); description.setColour(Label::textColourId, theme::secondary);
        description.setText(localization::translate(trigger() ? "Input attacks trigger the loaded sample." : "High Pass and Low Pass filter only the detector."), dontSendNotification);
        addAndMakeVisible(description);
        if (trigger()) {
            loadSample.setButtonText(localization::translate("Load sample")); loadSample.setComponentID("triggerLoadSample");
            loadSample.onClick = [this] { chooseSample(); }; addAndMakeVisible(loadSample);
            addAndMakeVisible(sampleName); sampleName.setFont(theme::font(12)); updateSample();
            controls = {{"threshold","Threshold"," dB",-80,0,.1,1}, {"retrigger","Retrigger"," ms",5,2000,1,1000},
                        {"gain","Gain"," dB",-24,24,.1,1}, {"mix","Mix"," %",0,100,.1,1},
                        {"attack","Attack"," ms",0,10000,1,1000}, {"decay","Decay"," ms",0,10000,1,1000},
                        {"sustain","Sustain"," %",0,100,.1,100}, {"release","Release"," ms",0,20000,1,1000}};
        } else {
            controls = {{"threshold","Threshold"," dB",-80,0,.1,1}, {"attack","Attack"," ms",0,2000,.1,1000},
                        {"decay","Decay"," ms",0,2000,1,1000}, {"hold","Hold"," ms",0,2000,1,1000},
                        {"release","Release"," ms",0,5000,1,1000}, {"highPass","High Pass"," Hz",20,20000,1,1},
                        {"lowPass","Low Pass"," Hz",20,20000,1,1}};
        }
        for (size_t index = 0; index < controls.size(); ++index) {
            const auto control = controls[index];
            auto *label = labels.add(new Label()); label->setText(control.title, dontSendNotification); label->setFont(theme::semiboldFont(12)); addAndMakeVisible(label);
            auto *slider = sliders.add(new ParameterSlider()); slider->setSliderStyle(Slider::LinearHorizontal); slider->setTextBoxStyle(Slider::TextBoxRight, false, 90, 24);
            slider->setRange(control.low, control.high, control.step); slider->setTextValueSuffix(control.suffix);
            slider->setComponentID((trigger() ? "trigger_" : "gate_") + control.key);
            slider->setValue(num(parameters(), Identifier(control.key)) * control.multiplier, dontSendNotification);
            if (control.suffix == " ms" || control.suffix == " Hz") slider->setSkewFactor(.4);
            slider->setColour(Slider::thumbColourId, theme::green); slider->setColour(Slider::trackColourId, theme::green.withAlpha(.65f));
            slider->onValueChange = [this, slider, control] {
                auto p = parameters(); double value = slider->getValue() / control.multiplier;
                if (control.key == "highPass") value = std::min(value, num(p, "lowPass", 20000));
                if (control.key == "lowPass") value = std::max(value, num(p, "highPass", 20));
                put(p, Identifier(control.key), value);
                slider->setValue(value * control.multiplier, dontSendNotification);
                if (preview) preview();
                if (!slider->isMouseButtonDown()) save();
            };
            slider->onDragEnd = [this] { save(); };
            addAndMakeVisible(slider);
        }
    }
    void paint(Graphics &g) override {
        g.fillAll(Colour(0xff242424));
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(22));
        g.drawText(effect, 20, 14, getWidth() - 150, 30, Justification::centredLeft);
    }
    void resized() override {
        enabled.setBounds(getWidth() - 120, 18, 100, 24);
        description.setBounds(16, 52, getWidth() - 32, 40);
        loadSample.setBounds(20, 100, 130, 28); sampleName.setBounds(160, 100, getWidth() - 180, 28);
        const int width = (getWidth() - 60) / 2;
        const int rowHeight = std::max(58, std::min(78, (getHeight() - 160) / 4));
        for (int index = 0; index < sliders.size(); ++index) {
            const int x = 20 + (index % 2) * (width + 20), y = 150 + (index / 2) * rowHeight;
            labels[index]->setBounds(x, y, width, 22);
            sliders[index]->setBounds(x, y + 22, width, 28);
        }
    }
};
} // namespace catlive
