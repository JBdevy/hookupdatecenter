#pragma once
#include "CatDynamicsAssets.h"
#include "Localization.h"
#include "NativeFXControls.h"
namespace catlive {
class CatDynamicsEditor final : public Component, private Timer {
    struct Control { String key, title, suffix; double low, high, step, multiplier, reset; };
    String effect;
    File directory;
    std::function<var()> read;
    std::function<void()> save, preview;
    std::function<void(String)> report;
    std::vector<Control> controls;
    OwnedArray<fxui::Knob> knobs;
    std::function<std::pair<float, float>()> levels;
    fxui::EnableButton enabled;
    juce::Rectangle<float> rack;
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
                      std::function<void()> changed, std::function<void(String)> error, std::function<void()> livePreview = {}, std::function<std::pair<float, float>()> meterLevels = {})
        : effect(std::move(name)), directory(std::move(projectDirectory)), read(std::move(values)),
          save(std::move(changed)), preview(std::move(livePreview)), report(std::move(error)), levels(std::move(meterLevels)) {
        setComponentID(trigger() ? "catLiveTriggerEditor" : "catGateEditor");
        enabled.setButtonText(localization::translate("Ativado"));
        enabled.setToggleState(flag(read(), trigger() ? Identifier("triggerEnabled") : Identifier("gateEnabled")), dontSendNotification);
        enabled.setComponentID("dynamicsEnabled"); addAndMakeVisible(enabled);
        enabled.onClick = [this] { auto settings = read(); put(settings, trigger() ? Identifier("triggerEnabled") : Identifier("gateEnabled"), enabled.getToggleState()); save(); };
        description.setFont(theme::font(12)); description.setColour(Label::textColourId, theme::secondary);
        description.setText(localization::translate(trigger() ? String::fromUTF8("WAV / MP3 · Mono / Stereo · 60 s max") : String("High Pass and Low Pass filter only the detector.")), dontSendNotification);
        addAndMakeVisible(description);
        if (trigger()) {
            loadSample.setButtonText(localization::translate("Load sample")); loadSample.setComponentID("triggerLoadSample");
            loadSample.onClick = [this] { chooseSample(); }; addAndMakeVisible(loadSample);
            addAndMakeVisible(sampleName); sampleName.setFont(theme::font(12)); updateSample();
            controls = {{"threshold","Threshold"," dB",-80,0,.1,1,-30}, {"retrigger","Retrigger"," ms",5,2000,1,1000,80},
                        {"gain","Gain"," dB",-24,24,.1,1,0},
                        {"attack","Attack"," ms",0,10000,1,1000,0}, {"decay","Decay"," ms",0,10000,1,1000,100},
                        {"sustain","Sustain"," %",0,100,.1,100,100}, {"release","Release"," ms",0,20000,1,1000,20}};
        } else {
            controls = {{"threshold","Threshold"," dB",-80,0,.1,1,-40}, {"attack","Attack"," ms",0,2000,.1,1000,1},
                        {"decay","Decay"," ms",0,2000,1,1000,20}, {"hold","Hold"," ms",0,2000,1,1000,50},
                        {"release","Release"," ms",0,5000,1,1000,100}, {"highPass","High-pass"," Hz",20,20000,1,1,20},
                        {"lowPass","Low-pass"," Hz",20,20000,1,1,20000}};
        }
        for (const auto &control : controls) {
            auto *knob = knobs.add(new fxui::Knob(localization::translate(control.title), control.low, control.high, control.step,
                num(parameters(), Identifier(control.key)) * control.multiplier, control.suffix,
                [this, control](double amount) {
                    auto p = parameters(); double value = amount / control.multiplier;
                    if (control.key == "highPass") value = std::min(value, num(p, "lowPass", 20000));
                    if (control.key == "lowPass") value = std::max(value, num(p, "highPass", 20));
                    put(p, Identifier(control.key), value);
                    for (auto *knob : knobs) if (knob->slider.getComponentID() == (trigger() ? "trigger_" : "gate_") + control.key)
                        knob->slider.setValue(value * control.multiplier, dontSendNotification);
                    if (preview) preview();
                }, [this] { save(); }));
            knob->slider.setComponentID((trigger() ? "trigger_" : "gate_") + control.key);
            knob->slider.setDoubleClickReturnValue(true, control.reset);
            if (control.suffix == " ms" || control.suffix == " Hz") knob->slider.setSkewFactor(.4);
            addAndMakeVisible(knob);
        }
        startTimerHz(30);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(16));
        g.drawText(effect, 0, 10, getWidth(), 26, Justification::centredLeft);
        if (trigger()) {
            g.setColour(theme::display);
            g.fillRoundedRectangle(0, 86, (float)getWidth(), 38, 8);
        }
        g.setColour(theme::display); g.fillRoundedRectangle(rack, 10);
        const auto value = levels ? levels() : std::pair<float,float>{};
        const int x = (int)rack.getX() + 18, top = (int)rack.getCentreY() - 55, height = 110;
        g.setFont(theme::font(9));g.setColour(theme::secondary);
        g.drawText("IN",x-5,top-22,28,18,Justification::centred);
        g.drawText("OUT",x+47,top-22,30,18,Justification::centred);
        for (int i=0;i<4;++i) {
            const int bx=x+(i/2)*54+(i%2)*12;
            const float amplitude=i<2?value.first:value.second;
            const float fraction=jlimit(0.f,1.f,(Decibels::gainToDecibels(amplitude,-60.f)+60)/60);
            g.setColour(Colours::black);g.fillRoundedRectangle((float)bx,(float)top,9.f,(float)height,2);
            ColourGradient gradient(Colours::red,(float)bx,(float)top,theme::green,(float)bx,(float)(top+height),false);
            gradient.addColour(.3,theme::yellow);g.setGradientFill(gradient);
            g.fillRect((float)bx,top+height*(1-fraction),9.f,height*fraction);
        }
        g.setColour(theme::secondary);g.setFont(theme::font(8));
        for(int db:{0,-24,-60})g.drawText(String(db),x+23,top+(int)(-db/60.f*height)-5,28,12,Justification::centred);
        g.drawText("L  R",x-3,top+height+4,28,14,Justification::centred);
        g.drawText("L  R",x+51,top+height+4,28,14,Justification::centred);
    }
    void resized() override {
        enabled.setBounds(0, 48, 114, 24);
        loadSample.setBounds(getWidth()-140, 46, 140, 28);
        sampleName.setBounds(8, 90, getWidth()-16, 30);
        description.setBounds(0, trigger()?130:84, getWidth(), 28);
        const int top=trigger()?170:120;
        rack=juce::Rectangle<float>(0,(float)top,(float)getWidth(),std::max(290.f,(float)getHeight()-top-16));
        const int left=120, width=std::max(1,(getWidth()-left-14)/4);
        for(int i=0;i<knobs.size();++i) {
            const int slot=trigger()&&i>=3?i+1:i;
            knobs[i]->setBounds(left+(slot%4)*width,top+14+(slot/4)*146,width,132);
        }
    }
  private:
    void timerCallback() override { if(isShowing())repaint(rack.toNearestInt()); }
};
} // namespace catlive
