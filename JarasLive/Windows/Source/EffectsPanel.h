#include "NativePluginShortcuts.h"
#pragma once
#include "Session.h"
#include "ExternalEffectEditor.h"
#include "Localization.h"
#include "EffectInsertPanel.h"
#include "FXDefaults.h"
#include "FXChain.h"
#include "CatStemEditor.h"
#include "CatDynamicsEditor.h"
#include "InstrumentParameterEditor.h"
#include "DrummerPadEditor.h"
#include "CatSynthEditor.h"
namespace catlive {
namespace fxui {
class EQGraph final : public Component {
  public:
    var settings;
    std::function<void()> changed, commit;
    EQGraph() {
        setWantsKeyboardFocus(true);
        setComponentID("eqGraph");
        for(auto *box:{&bandChoice,&typeChoice,&slopeChoice})addAndMakeVisible(box);
        bandChoice.setComponentID("eqBand");typeChoice.setComponentID("eqType");slopeChoice.setComponentID("eqSlope");
        bandChoice.onChange=[this]{selected=bandChoice.getSelectedId()-1;refreshControls();repaint();};
        typeChoice.onChange=[this]{
            const int index=typeChoice.getSelectedId()-1;
            if(index>=0&&index<types.size())editSelected("type",types[index],true);
        };
        for(int slope:{6,12,24,36,48,72,96,192})slopeChoice.addItem(slope==192?"Brickwall":String(slope)+" dB/oct",slope);
        slopeChoice.onChange=[this]{editSelected("slope",slopeChoice.getSelectedId(),true);};
        removeBand.setButtonText(localization::translate("Remove band"));
        removeBand.setComponentID("eqRemoveBand");removeBand.onClick=[this]{remove();};addAndMakeVisible(removeBand);
        const std::array<String,3> names{"Frequency","Gain","Q"};
        const std::array<String,3> suffixes{" Hz"," dB",""};
        for(int i=0;i<3;++i){
            auto &slider=bandSliders[(size_t)i];auto &label=bandLabels[(size_t)i];
            label.setText(names[(size_t)i],dontSendNotification);
            label.setFont(theme::font(11));label.setColour(Label::textColourId,theme::secondary);addAndMakeVisible(label);
            slider.setComponentID("eq"+names[(size_t)i]);slider.setSliderStyle(Slider::LinearHorizontal);
            slider.setTextBoxStyle(Slider::TextBoxRight,false,80,22);slider.setTextValueSuffix(suffixes[(size_t)i]);
            slider.setColour(Slider::trackColourId,theme::green);slider.setColour(Slider::thumbColourId,theme::green);
            slider.setRange(i==0?20:i==1?-24:.1,i==0?20000:i==1?24:18,i==0?1:.01);
            slider.onValueChange=[this,i]{editSelected(i==0?"frequency":i==1?"gain":"q",bandSliders[(size_t)i].getValue(),!bandSliders[(size_t)i].isMouseButtonDown());};
            slider.onDragEnd=[this]{if(commit)commit();};addAndMakeVisible(slider);
        }
    }
    ~EQGraph() override { clearAnalysis(); }
    void updateAnalysis(const std::array<std::shared_ptr<analysis::Capture>, 2> &next) {
        for (std::size_t i = 0; i < sources.size(); ++i) if (sources[i] != next[i]) {
            if (sources[i]) sources[i]->removeReader();
            sources[i] = next[i];
            lastSerial[i] = sources[i] ? sources[i]->serial() : 0;
            if (sources[i]) sources[i]->addReader();
        }
        std::size_t count = 0;
        for (std::size_t i = 0; i < sources.size(); ++i) if (sources[i]) {
            analysisRate = sources[i]->sampleRate();
            if (sources[i]->read(frames[count]) && frames[count].serial != lastSerial[i]) {
                lastSerial[i] = frames[count].serial; ++count;
            }
        }
        const double now = Time::getMillisecondCounterHiRes() * .001;
        spectrum = analyzer.analyze(frames.data(), count, lastAnalysis > 0 ? now - lastAnalysis : .05);
        lastAnalysis = now; repaint();
    }
    void clearAnalysis() {
        for (auto &source : sources) { if (source) source->removeReader(); source.reset(); }
        lastSerial.fill(0); lastAnalysis = 0; analyzer.reset(); spectrum = {};
    }
    void paint(Graphics &g) override {
        auto area = plot();
        g.setGradientFill(ColourGradient(Colour(0xff170f21), area.getTopLeft(),
                                         Colour(0xff2e1f3b), area.getTopRight(), false));
        g.fillRoundedRectangle(area, 5);
        const auto bands = list(get(settings, "bands"));
        g.saveState();
        g.reduceClipRegion(area.toNearestInt());
        g.setColour(Colour(0xff463751));
        for (auto f : {20., 50., 100., 200., 500., 1000., 2000., 5000., 10000., 20000.})
            g.drawVerticalLine((int)xAt(f), area.getY(), area.getBottom());
        for (int db = -24; db <= 24; db += 6)
            g.drawHorizontalLine((int)yAt(db), area.getX(), area.getRight());
        g.setColour(theme::secondary.withAlpha(.7f));
        g.drawHorizontalLine((int)yAt(0), area.getX(), area.getRight());
        paintAnalysis(g, area);
        std::vector<dsp::IIR::Coefficients<float>::Ptr> filters;
        for (const auto &band : bands)
            if (flag(band, "enabled", true)) {
                const auto f = (float)jlimit(20., std::min(20000., analysisRate * .45), num(band, "frequency", 1000)),
                           q = (float)jlimit(.1, 18., num(band, "q", .707));
                const auto gain = Decibels::decibelsToGain((float)num(band, "gain"));
                const auto type = str(band, "type", "bell");
                using C = dsp::IIR::Coefficients<float>;
                if (type == "lowCut" || type == "highCut") {
                    const int order = jlimit(1, 32, (int)num(band, "slope", 12) / 6);
                    for (int stage = 0; stage < std::max(1, order / 2); ++stage) {
                        if (order == 1) {
                            double k = std::tan(MathConstants<double>::pi * f / analysisRate),
                                   b0 = (type == "lowCut" ? 1 : k) / (1 + k);
                            filters.push_back(new C((float)b0, (float)(type == "lowCut" ? -b0 : b0),
                                                    0, 1, (float)((k - 1) / (k + 1)), 0));
                        } else {
                            const auto sq =
                                (float)(1 / (2 * std::sin(MathConstants<double>::pi *
                                                          (2 * stage + 1) / (2 * order))));
                            filters.push_back(type == "lowCut" ? C::makeHighPass(analysisRate, f, sq)
                                                               : C::makeLowPass(analysisRate, f, sq));
                        }
                    }
                } else
                    filters.push_back(type == "lowShelf"    ? C::makeLowShelf(analysisRate, f, q, gain)
                                      : type == "highShelf" ? C::makeHighShelf(analysisRate, f, q, gain)
                                                            : C::makePeakFilter(analysisRate, f, q, gain));
            }
        Path response;
        for (int x = (int)area.getX(); x < area.getRight(); ++x) {
            double magnitude = 1;
            for (const auto &f : filters)
                magnitude *= f->getMagnitudeForFrequency(std::min(frequencyAt((float)x), analysisRate * .49), analysisRate);
            const auto y = yAt(Decibels::gainToDecibels(magnitude, -120.));
            if (x == (int)area.getX())
                response.startNewSubPath((float)x, y);
            else
                response.lineTo((float)x, y);
        }
        const auto curveColour = flag(settings, "eqEnabled", true) ? fxui::dialAccent("EQ") : theme::secondary;
        auto fill = response;
        fill.lineTo(area.getBottomRight());
        fill.lineTo(area.getBottomLeft());
        fill.closeSubPath();
        g.setGradientFill(ColourGradient(curveColour.withAlpha(.2f), area.getTopLeft(),
                                         curveColour.withAlpha(.02f), area.getBottomLeft(), false));
        g.fillPath(fill);
        g.setColour(curveColour);
        g.strokePath(response, PathStrokeType(1.8f));
        for (int i = 0; i < bands.size(); ++i) {
            const auto band = bands[i];
            const auto p = point(band);
            g.setColour(flag(band, "enabled", true) ? fxui::dialAccent("EQ") : theme::secondary);
            g.fillEllipse(p.x - 5, p.y - 5, 10, 10);
            g.setColour(i == selected ? Colours::white : theme::display);
            g.drawEllipse(p.x - 5.5f, p.y - 5.5f, 11, 11, 1);
        }
        g.restoreState();
        g.setColour(theme::secondary);
        g.setFont(theme::font(9));
        for (auto f : {20., 50., 100., 200., 500., 1000., 2000., 5000., 10000., 20000.}) {
            String label = f >= 1000 ? String(f / 1000, 0) + "k" : String(f, 0);
            g.drawText(label, (int)xAt(f) - 18, (int)plot().getBottom() + 2, 36, 16, Justification::centred);
        }
        if (selected >= 0 && selected < bands.size()) {
            auto band = bands[selected];
            g.setFont(theme::font(11));
            g.drawText(String(num(band, "frequency"), 0) + " Hz    " +
                           String(num(band, "gain"), 1) + " dB    Q " + String(num(band, "q"), 2),
                       12, 6, getWidth() - 24, 20, Justification::centredLeft);
        }
    }
    void mouseDown(const MouseEvent &e) override {
        grabKeyboardFocus();
        if(!plot().expanded(0,8).contains(e.position))return;
        selected = -1;
        auto bands = list(get(settings, "bands"));
        for (int i = 0; i < bands.size(); ++i)
            if (point(bands[i]).getDistanceFrom(e.position) < 12) {
                selected = i;
                break;
            }
        dragging = false;
        wheelBandHeld = selected >= 0 && e.mods.isLeftButtonDown();
        wheelRemainder = 0;
        if (e.mods.isPopupMenu() && std::abs(e.position.y-plot().getCentreY())<18) add({e.position.x,plot().getCentreY()});
        refreshControls();repaint();
    }
    void mouseDoubleClick(const MouseEvent &e) override {
        if (e.mods.isPopupMenu()) return;
        auto bands = list(get(settings, "bands"));
        if (selected >= 0 && selected < bands.size()) {
            put(bands.getReference(selected), "gain", 0.);
            put(settings, "bands", bands);
            if (changed) changed();
            refreshControls();
            if (commit) commit();
            repaint();
        } else add(e.position);
    }
    void mouseDrag(const MouseEvent &e) override {
        if (selected < 0 || e.mods.isPopupMenu())
            return;
        auto bands = list(get(settings, "bands"));
        if (selected >= bands.size())
            return;
        auto &band = bands.getReference(selected);
        put(band, "frequency", std::round(frequencyAt(e.position.x)));
        const auto type = str(band, "type");
        if (type != "lowCut" && type != "highCut")
            put(band, "gain", std::round(gainAt(e.position.y) * 10) / 10);
        put(settings, "bands", bands);
        dragging = true;
        if (changed)
            changed();
        refreshControls();repaint();
    }
    void mouseUp(const MouseEvent &) override {
        wheelBandHeld = false;
        wheelRemainder = 0;
        if (dragging && commit)
            commit();
        dragging = false;
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        if (!wheelBandHeld || !event.mods.isLeftButtonDown()) {
            Component::mouseWheelMove(event, wheel);
            return;
        }
        if (wheel.isInertial || !std::isfinite(wheel.deltaY)) return;
        wheelRemainder += wheel.isSmooth ? wheel.deltaY * 10. : (wheel.deltaY > 0 ? 1 : wheel.deltaY < 0 ? -1 : 0);
        const int steps = (int)wheelRemainder;
        if (!steps) return;
        wheelRemainder -= steps;
        auto bands = list(get(settings, "bands"));
        if (selected < 0 || selected >= bands.size()) return;
        auto &band = bands.getReference(selected);
        const auto type = str(band, "type");
        if (type == "lowCut" || type == "highCut") {
            const std::array<int, 8> slopes{6,12,24,36,48,72,96,192};
            const auto found = std::find(slopes.begin(), slopes.end(), (int)num(band, "slope", 12));
            const int current = found == slopes.end() ? 1 : (int)(found - slopes.begin());
            put(band, "slope", slopes[(size_t)jlimit(0, 7, current + steps)]);
        } else {
            put(band, "q", jlimit(.1, 18., num(band, "q", .707) * std::pow(1.12, steps)));
        }
        put(settings, "bands", bands);
        if (changed) changed();
        if (commit) commit();
        refreshControls();
        repaint();
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::deleteKey || key == KeyPress::backspaceKey) {
            remove();
            return true;
        }
        return false;
    }

    void refreshControls() {
        const auto bands=list(get(settings,"bands"));
        if(selected>=bands.size())selected=bands.isEmpty()?-1:0;
        // Initial selection matches Mac's first-band selection.
        if(!initializedSelection&&selected<0&&!bands.isEmpty())selected=0;
        initializedSelection=true;
        controlsVisible=selected>=0&&selected<bands.size();
        for(auto *box:{&bandChoice,&typeChoice,&slopeChoice})box->setVisible(controlsVisible);
        removeBand.setVisible(controlsVisible);
        for(size_t i=0;i<3;++i){bandSliders[i].setVisible(controlsVisible);bandLabels[i].setVisible(controlsVisible);}
        if(controlsVisible){
            bandChoice.clear(dontSendNotification);
            for(int i=0;i<bands.size();++i)bandChoice.addItem("Band "+String(i+1),i+1);
            bandChoice.setSelectedId(selected+1,dontSendNotification);
            const auto band=bands[selected]; const auto currentType=str(band,"type","bell");
            int first=0,last=0;
            for(int i=1;i<bands.size();++i){
                if(num(bands[i],"frequency")<num(bands[first],"frequency"))first=i;
                if(num(bands[i],"frequency")>num(bands[last],"frequency"))last=i;
            }
            types={"bell"};StringArray titles{"Bell"};
            if(selected==first){types.add("lowCut");types.add("lowShelf");titles.add("Low Cut");titles.add("Low Shelf");}
            if(selected==last){types.add("highCut");types.add("highShelf");titles.add("High Cut");titles.add("High Shelf");}
            if(!types.contains(currentType)){types.add(currentType);titles.add(currentType);}
            typeChoice.clear(dontSendNotification);typeChoice.addItemList(titles,1);
            typeChoice.setSelectedId(types.indexOf(currentType)+1,dontSendNotification);
            const bool cut=currentType.endsWith("Cut");slopeChoice.setVisible(cut);
            slopeChoice.setSelectedId((int)num(band,"slope",12),dontSendNotification);
            bandSliders[0].setValue(num(band,"frequency",1000),dontSendNotification);
            bandSliders[1].setValue(num(band,"gain"),dontSendNotification);
            bandSliders[2].setValue(num(band,"q",.707),dontSendNotification);
            bandSliders[1].setEnabled(!cut);bandSliders[2].setEnabled(!cut);
        }
        resized();
    }
    void resized() override {
        const int y=getHeight()-90, gap=8, third=(getWidth()-16)/3;
        bandChoice.setBounds(0,y,90,24);typeChoice.setBounds(98,y,150,24);
        slopeChoice.setBounds(256,y,120,24);removeBand.setBounds(getWidth()-110,y,110,24);
        for(int i=0;i<3;++i){bandLabels[(size_t)i].setBounds(i*(third+gap),y+32,third,18);bandSliders[(size_t)i].setBounds(i*(third+gap),y+52,third,26);}
    }
  private:
    ComboBox bandChoice,typeChoice,slopeChoice;
    QuietButton removeBand;
    std::array<ParameterSlider,3> bandSliders;
    std::array<Label,3> bandLabels;
    StringArray types;
    bool controlsVisible=false, initializedSelection=false;
    void editSelected(const Identifier &property,const var &value,bool finish) {
        auto bands=list(get(settings,"bands"));if(selected<0||selected>=bands.size())return;
        put(bands.getReference(selected),property,value);put(settings,"bands",bands);
        if(changed)changed();
        if(finish&&commit)commit();
        refreshControls();repaint();
    }
    std::array<std::shared_ptr<analysis::Capture>, 2> sources;
    std::array<std::uint64_t, 2> lastSerial{};
    std::array<analysis::Frame, 2> frames;
    analysis::Analyzer analyzer;
    analysis::Spectrum spectrum;
    double lastAnalysis = 0, analysisRate = 48000;
    void paintAnalysis(Graphics &g, juce::Rectangle<float> area) {
        auto path = [&](const std::array<float, analysis::binCount> &levels) {
            Path result;
            if (std::none_of(levels.begin(), levels.end(), [](float db) { return db > -95.9f; })) return result;
            const float step = area.getWidth() / float(levels.size() - 1);
            auto y = [&](int index) { return area.getY() + area.getHeight() * (6.f - jlimit(-96.f, 6.f, levels[std::size_t(index)])) / 102.f; };
            auto tangent = [&](int index) {
                if (index == 0) return y(1) - y(0);
                if (index == int(levels.size() - 1)) return y(index) - y(index - 1);
                const auto left = y(index) - y(index - 1), right = y(index + 1) - y(index);
                return left * right > 0 ? 2 * left * right / (left + right) : 0.f;
            };
            float previous = y(0), previousTangent = tangent(0);
            result.startNewSubPath(area.getX(), previous);
            for (int index = 1; index < int(levels.size()); ++index) {
                const auto x = area.getX() + float(index) * step, next = y(index), nextTangent = tangent(index);
                result.cubicTo(x - step * 2 / 3, previous + previousTangent / 3,
                               x - step / 3, next - nextTangent / 3, x, next);
                previous = next; previousTangent = nextTangent;
            }
            return result;
        };
        auto output = path(spectrum.output), input = path(spectrum.input);
        if (!output.isEmpty()) {
            auto fill = output; fill.lineTo(area.getRight(), area.getBottom()); fill.lineTo(area.getX(), area.getBottom()); fill.closeSubPath();
            g.setColour(theme::green.withAlpha(.12f)); g.fillPath(fill);
            g.setColour(theme::green.withAlpha(.75f)); g.strokePath(output, PathStrokeType(1, PathStrokeType::curved, PathStrokeType::rounded));
        }
        if (!input.isEmpty()) { g.setColour(Colours::white.withAlpha(.38f)); g.strokePath(input, PathStrokeType(1, PathStrokeType::curved, PathStrokeType::rounded)); }
        g.setColour(Colours::white.withAlpha(.5f)); g.setFont(theme::font(9));
        g.drawText("RTA  INPUT / OUTPUT", area.reduced(8).removeFromTop(15), Justification::centredRight);
    }
    int selected = -1;
    bool dragging = false, wheelBandHeld = false;
    double wheelRemainder = 0;
    juce::Rectangle<float> plot() const {
        return getLocalBounds().toFloat().withTrimmedBottom(controlsVisible ? 116.f : 20.f).reduced(8, 0);
    }
    float xAt(double f) const {
        return plot().getX() +
               (float)(std::log(jlimit(20., 20000., f) / 20) / std::log(1000.)) * plot().getWidth();
    }
    float yAt(double gain) const {
        return plot().getCentreY() - (float)(gain / 48) * plot().getHeight();
    }
    double frequencyAt(float x) const {
        return 20 *
               std::pow(1000., jlimit(0., 1., (double)(x - plot().getX()) / plot().getWidth()));
    }
    double gainAt(float y) const {
        return jlimit(-24., 24., (double)(plot().getCentreY() - y) * 48 / plot().getHeight());
    }
    Point<float> point(const var &b) const {
        const auto type = str(b, "type");
        return {xAt(num(b, "frequency", 1000)),
                yAt(type == "lowCut" || type == "highCut" ? 0 : num(b, "gain"))};
    }
    void update() {
        refreshControls();
        if (changed)
            changed();
        if (commit)
            commit();
        repaint();
    }
    void add(Point<float> p) {
        auto bands = list(get(settings, "bands"));
        if (bands.size() >= 10)
            return;
        auto b = object();
        put(b, "id", text(uuid()));
        put(b, "frequency", frequencyAt(p.x));
        put(b, "gain", gainAt(p.y));
        put(b, "q", .707);
        put(b, "type", "bell");
        put(b, "slope", 12);
        put(b, "enabled", true);
        bands.add(b);
        put(settings, "bands", bands);
        selected = bands.size() - 1;
        update();
    }
    void remove() {
        auto bands = list(get(settings, "bands"));
        if (selected < 0 || selected >= bands.size())
            return;
        bands.remove(selected);
        put(settings, "bands", bands);
        selected = bands.isEmpty() ? -1 : 0;
        update();
    }

};
} // namespace fxui
class EffectsPanel final : public Component, public DragAndDropContainer, public DragAndDropTarget, private ListBoxModel, private Timer {
  public:
    static constexpr int minimumContentWidth = 840, minimumContentHeight = 600;
    std::function<bool(const KeyPress &)> globalKey;
    std::function<void(bool)> globalKeyState;
    std::function<void()> openLibrary;
    EffectsPanel(Session &s, ID target, std::function<void(String)> report, bool itemTarget = false,
                 String plugin = {})
        : session(s), track(std::move(target)), item(itemTarget),
          singleEffect(std::move(plugin)), error(std::move(report)), chain("FX", this) {
        setComponentID("effectsPanel");
        load();
        fxui::defaults(settings);
        chain.setRowHeight(30);
        chain.setColour(ListBox::backgroundColourId, Colour(0xff181818));
        chain.setOutlineThickness(0);
        addChildComponent(chain);
        chain.setVisible(singleEffect.isEmpty());
        for (auto *b : {&add, &remove, &removeEffect}) {
            addAndMakeVisible(b);
            b->getProperties().set("fontSize", 12);
            b->getProperties().set("flat", true);
            b->setColour(TextButton::buttonColourId, Colour(0xff4d4d4d));
        }
        add.setButtonText("Add");
        remove.setButtonText(localization::translate("Excluir"));
        removeEffect.setButtonText(localization::translate("Remover efeito"));
        add.setComponentID("addEffect");
        remove.setComponentID("removeEffect");
        add.onClick = [this] { if (openLibrary) openLibrary(); };
        remove.onClick = [this] { erase(); };
        removeEffect.onClick = [this] { erase(); };
        add.setVisible(singleEffect.isEmpty());
        remove.setVisible(singleEffect.isEmpty());
        enabled.setButtonText("Enabled");
        addAndMakeVisible(enabled);
        channelLabel.setJustificationType(Justification::centredRight);
        channelLabel.setColour(Label::textColourId, theme::secondary);
        channelLabel.setFont(theme::font(12));
        addChildComponent(channelLabel);
        for (auto &button : channelButtons) addChildComponent(button);
        for (int division : {2, 4, 8, 12, 16, 24, 32}) gateDivision.addItem("1/" + String(division), division);
        gateDivision.setTitle("Division");
        gateDivision.onChange = [this] {
            auto group = get(current(), "divisionGate");
            put(group, "division", gateDivision.getSelectedId());
            session.audio.previewNativeParameters(track, key(), kind(), current(), settings);
            commit();
        };
        addChildComponent(gateDivision);
        for (int division : ArpeggioParameters::divisions)
            arpeggioSelectors[0].addItem(division % 3 == 0 ? "1/" + String(division * 2 / 3) + "T"
                                                               : "1/" + String(division), division);
        for (int index = 0; index < int(ArpeggioParameters::directions.size()); ++index)
            arpeggioSelectors[1].addItem(ArpeggioParameters::directions[size_t(index)], index + 1);
        for (int octaves = 1; octaves <= 4; ++octaves)
            arpeggioSelectors[2].addItem(String(octaves), octaves);
        for (size_t index = 0; index < arpeggioSelectors.size(); ++index) {
            auto &selector = arpeggioSelectors[index];
            selector.setTitle(arpeggioTitles[index]);
            selector.onChange = [this, index] {
                const int adjustment = index == 1 ? 1 : 0;
                setArpeggioParameter(arpeggioKeys[index], arpeggioSelectors[index].getSelectedId() - adjustment);
            };
            addChildComponent(selector);
        }
        arpeggioSync.setButtonText("Sync");
        arpeggioSync.setClickingTogglesState(true);
        arpeggioSync.onClick = [this] {
            setArpeggioParameter("sync", arpeggioSync.getToggleState());
            arpeggioBPM.setEnabled(!arpeggioSync.getToggleState());
        };
        addChildComponent(arpeggioSync);
        arpeggioGate.setTitle("Gate");
        arpeggioGate.setSliderStyle(Slider::LinearHorizontal);
        arpeggioGate.setTextBoxStyle(Slider::TextBoxRight, false, 45, 24);
        arpeggioGate.setTextValueSuffix("%");
        arpeggioGate.setRange(5, 100, 1);
        arpeggioGate.setChangeNotificationOnlyOnRelease(true);
        arpeggioGate.onValueChange = [this] { setArpeggioParameter("gate", int(arpeggioGate.getValue())); };
        addChildComponent(arpeggioGate);
        arpeggioBPM.setTitle("BPM");
        arpeggioBPM.setSliderStyle(Slider::LinearHorizontal);
        arpeggioBPM.setTextBoxStyle(Slider::TextBoxRight, false, 45, 24);
        arpeggioBPM.setRange(20, 400, 1);
        arpeggioBPM.setChangeNotificationOnlyOnRelease(true);
        arpeggioBPM.onValueChange = [this] { setArpeggioParameter("bpm", int(arpeggioBPM.getValue())); };
        addChildComponent(arpeggioBPM);
        for (auto &button : gateSteps) {
            button.setColour(TextButton::buttonColourId, theme::panel);
            button.setColour(TextButton::buttonOnColourId, theme::green);
            button.setColour(TextButton::textColourOnId, Colours::black);
            addChildComponent(button);
        }
        enabled.onClick = [this] {
            auto s = current();
            fxui::enable(kind(), s, enabled.getToggleState());
            commit();
            chain.repaint();
            graph.repaint();
        };
        for (int i = 0; i < 3; ++i) {
            auto *b = rooms.add(new TextButton(i == 0 ? "Room" : i == 1 ? "Hall" : "Plate"));
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
            b->onClick = [this, i] {
                auto s = current();
                put(s, "reverbRoom", i);
                commit();
                show();
            };
        }
        addAndMakeVisible(graph);
        graph.changed = [this] {
            auto s = current();
            put(s, "bands", get(graph.settings, "bands"));
            session.audio.previewNativeParameters(track,key(),kind(),current(),settings);
            repaint();
        };
        graph.commit = [this] { commit(); };
        chain.updateContent();
        if (getNumRows())
            chain.selectRow(singleEffect.isEmpty() ? 0 : list(get(settings, "inserted")).indexOf(var(singleEffect)));
        else
            show();
        addAndMakeVisible(presets); addAndMakeVisible(savePreset); addAndMakeVisible(defaultPreset);
        for (auto *button : {&undoParameters, &redoParameters}) addChildComponent(button);
        undoParameters.setButtonText("Undo"); redoParameters.setButtonText("Redo");
        undoParameters.onClick = [this] { restoreParameters(false); };
        redoParameters.onClick = [this] { restoreParameters(true); };
        presets.setComponentID("fxPreset"); savePreset.setComponentID("saveFXPreset"); defaultPreset.setComponentID("defaultFXPreset");
        savePreset.setButtonText(String::fromUTF8("Salvar preset…"));
        defaultPreset.setButtonText(String::fromUTF8("Usar como padrão"));
        presets.onChange = [this] { loadPreset(); };
        savePreset.onClick = [this] { saveCurrentPreset(); };
        defaultPreset.onClick = [this] { makePresetDefault(); };
        refreshPresets(); resized();
        startTimerHz(20);
    }
    void selectEffect(const String &preferred) {
        const int index = list(get(settings, "inserted")).indexOf(var(preferred));
        if (index < 0) return;
        if (chain.getSelectedRow() == index) selectedRowsChanged(index);
        else chain.selectRow(index);
    }
    void paint(Graphics &g) override {
        const auto body = getLocalBounds().toFloat();
        g.setGradientFill(ColourGradient(Colour(0xff24262b), body.getTopLeft(),
                                         Colour(0xff171a1f), body.getBottomRight(), false));
        g.fillAll();
        if (singleEffect.isEmpty()) {
            g.setColour(Colour(0xff181818));
            g.fillRect(0, 0, sidebarWidth(), getHeight());
            g.setColour(Colour(0xff202020));
            g.fillRect(0, getHeight() - 40, sidebarWidth(), 40);
        }
        auto r = content();
        if(kind()=="CatStemSeparation 5"||kind()=="External"||dynamicsEditor||synthEditor)return;
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(22));
        if (kind().isEmpty()) {
            g.drawText("Adicionar efeito", r, Justification::centred);
            return;
        }
        g.drawText(kind(), r.getX(), headerY, r.getWidth() - 36,
                   24, Justification::centredLeft);
        g.setFont(theme::semiboldFont(9));
        g.setColour(theme::secondary);
        g.drawText(unicodeCase(trackName), r.getX(), headerY + 43, r.getWidth() - 120, 20,
                   Justification::centredLeft);
        if (kind() == "EQ") {
            g.setFont(theme::font(10));
            const auto enabledBounds = enabled.getBounds();
            const auto bandCount = enabledBounds.withX(enabledBounds.getRight() + 12).withWidth(46);
            g.drawText(String(list(get(current(), "bands")).size()) + "/10", bandCount,
                       Justification::centredLeft);
            g.drawText(String::fromUTF8(
                           "Clique com o botão direito na linha central para adicionar uma banda."),
                       r.getX(), getHeight() - 31, r.getWidth(), 20, Justification::centred);
        } else if (!instrumentEditor) {
            fxui::paintRack(g, juce::Rectangle<int>(r.getX(), rackY, r.getWidth(), rackHeight).toFloat());
            if (kind() == "Arpeggiator") {
                paintArpeggio(g, {r.getX() + 16, rackY + 8, r.getWidth() - 32, rackHeight - 16});
            } else if (!thresholdMeter) {
                paintMeters(g);
            }
        }
    }
    void resized() override {
        chain.setBounds(0, 0, 190, std::max(1, getHeight() - 40));
        add.setBounds(6, getHeight() - 32, 84, 24);
        remove.setBounds(96, getHeight() - 32, 88, 24);
        auto r = content();
        const bool eq = kind() == "EQ",
                   compressor = kind() == "Compressor";
        rackHeight = compressor ? 308 : 180;
        auto presetRow = r.withY(8).withHeight(24);
        redoParameters.setBounds(presetRow.removeFromRight(52));
        presetRow.removeFromRight(4);
        undoParameters.setBounds(presetRow.removeFromRight(52));
        presetRow.removeFromRight(4);
        defaultPreset.setBounds(presetRow.removeFromRight(140));
        presetRow.removeFromRight(4);
        savePreset.setBounds(presetRow.removeFromRight(114));
        presetRow.removeFromRight(4);
        presets.setBounds(presetRow);
        headerY = (eq || instrumentEditor) ? 52 : std::max(60, (getHeight() - (rackHeight + 124)) / 2);
        rackY = headerY + 118;
        removeEffect.setBounds(r.getRight() - 100, headerY + 42, 100, 22);
        enabled.setBounds(eq ? r.getX() : r.getCentreX() - 55, headerY + 76, 110, 24);
        channelLabel.setBounds(r.getRight() - 151, headerY + 76, 68, 24);
        for (int ch = 0; ch < 2; ++ch)
            channelButtons[ch].setBounds(r.getRight() - 80 + ch * 40, headerY + 76, 38, 24);
        const int arpeggioColumn = (r.getWidth() - 32) / int(arpeggioTitles.size());
        for (int i = 0; i < int(arpeggioSelectors.size()); ++i)
            arpeggioSelectors[size_t(i)].setBounds(r.getX() + 16 + i * arpeggioColumn,
                                                 rackY + rackHeight - 42, arpeggioColumn - 10, 26);
        arpeggioGate.setBounds(r.getX() + 16 + 3 * arpeggioColumn, rackY + rackHeight - 42, arpeggioColumn - 10, 26);
        arpeggioBPM.setBounds(r.getX() + 16 + 4 * arpeggioColumn, rackY + rackHeight - 42, arpeggioColumn - 10, 26);
        arpeggioSync.setBounds(r.getRight() - 91, rackY + 8, 75, 23);
        gateDivision.setBounds(r.getX() + 16, rackY + 70, 96, 26);
        const int stepWidth = std::max(15, (r.getWidth() - 8) / 16);
        for (int step = 0; step < 16; ++step)
            gateSteps[step].setBounds(r.getX() + 4 + step * stepWidth, headerY + 104, stepWidth - 3, 24);

        if(externalEditor)externalEditor->setBounds(sidebarWidth(),40,std::max(1,getWidth()-sidebarWidth()),std::max(1,getHeight()-40));
        if(stemEditor)stemEditor->setBounds(r.getX(),40,r.getWidth(),getHeight()-40);
        if(dynamicsEditor)dynamicsEditor->setBounds(r.getX(),40,r.getWidth(),getHeight()-40);
        if(drummerEditor)drummerEditor->setBounds(r.getX(),6,r.getWidth(),std::max(1,getHeight()-12));
        if(synthEditor)synthEditor->setBounds(r.getX(),40,r.getWidth(),std::max(1,getHeight()-50));
        if(instrumentEditor)instrumentEditor->setBounds(r.getX(),headerY+88,r.getWidth(),std::max(1,getHeight()-headerY-104));
        graph.setBounds(r.getX(), headerY + 102, r.getWidth(),
                        std::max(40, getHeight() - headerY - 141));
        for (int i = 0; i < rooms.size(); ++i)
            rooms[i]->setBounds(r.getX() + r.getWidth() / 2 - 105 + i * 70, headerY + 43, 70, 24);
        if (thresholdMeter) thresholdMeter->setBounds(r.getX() + 10, rackY + (rackHeight-200)/2, 123, 200);
        const int count = knobs.size(), columns = compressor ? 2 : std::max(1, count),
                  left = r.getX() + (compressor ? 145 : 128), usable = r.getRight() - left - 12;
        for (int i = 0; i < count; ++i) {
            int row = compressor ? i / columns : 0, col = compressor ? i % columns : i;
            knobs[i]->setBounds(left + col * usable / columns, rackY + (kind() == "Gate Divisor" ? 23 : 16) + row * 146,
                                usable / columns, 130);
        }
    }

  private:
    Session &session;
    ID track;
    bool item = false;
    String singleEffect;
    String trackName = "Main";
    std::function<void(String)> error;
    var settings;
    uint64 loadedRevision = ~uint64(0);
    ListBox chain;
    TextButton add, remove, removeEffect, savePreset, defaultPreset, undoParameters, redoParameters;
    struct ParameterHistory {
        std::vector<var> undo, redo;
        var last;
    };
    std::map<String, ParameterHistory> parameterHistory;
    var persistedSettings;
    std::unique_ptr<CatDynamicsEditor> dynamicsEditor;
    std::unique_ptr<InstrumentParameterEditor> instrumentEditor;
    std::unique_ptr<DrummerPadEditor> drummerEditor;
    std::unique_ptr<CatSynthEditor> synthEditor;
    std::unique_ptr<ExternalEffectEditor> externalEditor;
    String externalEditorKey;
    void openExternalEditor() {
        if(kind()!="External")return;
        auto plugin=session.audio.externalEffect(track,key());
        if(!plugin)return;
        if(externalEditor && externalEditorKey==key() && externalEditor->uses(plugin))return;
        externalEditor.reset();externalEditorKey=key();
        externalEditor=std::make_unique<ExternalEffectEditor>(std::move(plugin),
            [this](const KeyPress &press){return globalKey && globalKey(press);},
            [this](bool down){if(globalKeyState)globalKeyState(down);},
            [this](int width,int height){fitExternalEditor(width,height);});
        addAndMakeVisible(*externalEditor);resized();
    }
    void fitExternalEditor(int width,int height) {
        auto *window=findParentComponentOfClass<DocumentWindow>();
        if(!window)return;
        const int borderWidth=window->getWidth()-getWidth(),borderHeight=window->getHeight()-getHeight();
        auto area=window->getBounds().withSize(std::max(360,width+sidebarWidth()+borderWidth),std::max(240,height+40+borderHeight));
        if(const auto *display=Desktop::getInstance().getDisplays().getDisplayForRect(window->getBounds())) {
            const auto visible=display->userArea;
            area.setSize(std::min(area.getWidth(),visible.getWidth()),std::min(area.getHeight(),visible.getHeight()));
            area.setPosition(jlimit(visible.getX(),visible.getRight()-area.getWidth(),area.getX()),
                             jlimit(visible.getY(),visible.getBottom()-area.getHeight(),area.getY()));
        }
        window->setBounds(area);
    }
    ComboBox presets;
    Array<var> presetEntries;
    var presetLibrary;
    bool presetsLoaded = false;
    int64 presetRevision = -1;
    int presetPoll = 0;
    fxui::EnableButton enabled;
    Label channelLabel{"channelLabel", "Channel -"};
    std::array<ToggleButton, 2> channelButtons;
    std::array<TextButton, 16> gateSteps;
    ComboBox gateDivision;
    std::array<ComboBox, 3> arpeggioSelectors;
    Slider arpeggioGate, arpeggioBPM;
    TextButton arpeggioSync;
    static constexpr std::array<const char *, 5> arpeggioTitles{"Rate", "Direction", "Octaves", "Gate", "BPM"};
    static constexpr std::array<const char *, 3> arpeggioKeys{"division", "direction", "octaves"};
    OwnedArray<TextButton> rooms;
    OwnedArray<fxui::Knob> knobs;
    std::unique_ptr<fxui::DynamicsThresholdMeter> thresholdMeter;
    fxui::EQGraph graph;
    std::unique_ptr<CatStemEditor> stemEditor;
    int selected = -1, headerY = 24, rackY = 140, rackHeight = 180;
    int sidebarWidth() const { return singleEffect.isEmpty() ? 190 : 0; }
    juce::Rectangle<int> content() const { return {sidebarWidth() + 20, 0, std::max(200, getWidth() - sidebarWidth() - 40), getHeight()}; }
    void load() {
        loadedRevision = session.revision;
        settings = var();
        if (item) {
            for(const auto &song:session.project().songs) for(const auto &t:song.tracks) for(const auto &clip:t.clips)
                if(clip.id==track) { trackName=text(clip.name); if(clip.fxJSON) settings=JSON::parse(text(*clip.fxJSON)); }
        } else if (track.empty()) {
            if (session.project().masterFXJSON)
                settings = JSON::parse(text(*session.project().masterFXJSON));
        } else
            for (const auto &song : session.project().songs)
                for (const auto &t : song.tracks)
                    if (t.id == track) {
                        trackName = text(t.name);
                        if (t.fxJSON)
                            settings = JSON::parse(text(*t.fxJSON));
                    }
        // Hide the removed processor in legacy projects without mutating the
        // project while merely opening its effects manager.
        auto visible = list(get(settings, "inserted"));
        for(int i=visible.size();--i>=0;)if(visible[i].toString()=="CatStemSeparation 5")visible.remove(i);
        if(settings.isObject())put(settings,"inserted",visible);
        persistedSettings = settings.clone();
    }
    String key() const {
        auto values = list(get(settings, "inserted"));
        return selected >= 0 && selected < values.size() ? values[selected].toString() : String();
    }
    String kind() const {
        auto k = key();
        if(k.startsWith("External:"))return "External";
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == k || "Instance:" + str(instance, "id") == k)
                return str(instance, "kind");
        return k;
    }
    static var effectSettings(const var &chain, const String &key) {
        for (auto plugin : list(get(chain, "externalPlugins")))
            if (key == "External:" + str(plugin, "id")) return plugin;
        for (auto instance : list(get(chain, "instances")))
            if ("Native:" + str(instance, "id") == key || "Instance:" + str(instance, "id") == key)
                return get(instance, "settings");
        return chain;
    }
    var current() const { return effectSettings(settings, key()); }
    static var parameterSnapshot(const String &kind, const var &effect) {
        auto snapshot = object();
        for (const auto &field : fxpresets::fields(kind)) {
            const auto value = get(effect, Identifier(field));
            if (!value.isVoid()) put(snapshot, Identifier(field), value.clone());
        }
        return snapshot;
    }
    static bool sameParameters(const var &a, const var &b) {
        return JSON::toString(a, true, 17) == JSON::toString(b, true, 17);
    }
    void restoreParameters(bool redo) {
        const auto selectedKey = key(), selectedKind = kind();
        auto found = parameterHistory.find(selectedKey);
        if (found == parameterHistory.end()) return;
        auto &history = found->second;
        auto &source = redo ? history.redo : history.undo;
        auto &target = redo ? history.undo : history.redo;
        auto effect = current();
        const auto before = parameterSnapshot(selectedKind, effect);
        if (source.empty() || !sameParameters(history.last, before)) return;
        for (const auto &key : fxpresets::fields(selectedKind)) {
            const Identifier field(key);
            const auto value = get(source.back(), field);
            if (value.isVoid()) fxpresets::erase(effect, field);
            else put(effect, field, value.clone());
        }
        if (!commit(false, false)) return;
        target.push_back(before);
        source.pop_back();
        history.last = parameterSnapshot(selectedKind, current());
        show();
    }
    int getNumRows() override { return list(get(settings, "inserted")).size(); }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool isSelected) override {
        auto keys = list(get(settings, "inserted"));
        if (row >= keys.size())
            return;
        auto k = keys[row].toString(), name = k;
        var s = settings;
        if(k.startsWith("External:"))for(auto plugin:list(get(settings,"externalPlugins")))if(k=="External:"+str(plugin,"id")){name=str(plugin,"name");s=plugin;break;}
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == k || "Instance:" + str(instance, "id") == k) {
                name = str(instance, "kind");
                s = get(instance, "settings");
                break;
            }
        if (isSelected) {
            g.setColour(Colour(0xff458e22));
            g.fillAll();
        }
        const bool active=fxui::isEnabled(k.startsWith("External:")?"External":name,s);
        g.setColour(Colours::white.withAlpha(active ? .18f : .05f));
        g.fillRect(0, 0, 30, height);
        g.setColour(active ? Colours::white : theme::secondary);
        g.setFont(theme::semiboldFont(10));
        g.drawText("By", 0, 0, 30, height, Justification::centred);
        g.setFont(theme::semiboldFont(12));
        g.drawText(name, 35, 0, width - 40, height, Justification::centredLeft);
    }
    var getDragSourceDescription(const SparseSet<int> &rows) override {
        auto keys=list(get(settings,"inserted"));
        return rows.size()==1 && rows[0]>=0 && rows[0]<keys.size() ? keys[rows[0]] : var();
    }
    bool isInterestedInDragSource(const SourceDetails &details) override {
        return (item && str(details.description, "type") == "catlive-library-effect"
                && str(details.description, "project") == text(session.project().id)) ||
               (details.sourceComponent.get()==&chain && list(get(settings,"inserted")).contains(details.description));
    }
    void itemDropped(const SourceDetails &details) override {
        if(!isInterestedInDragSource(details)||session.busy)return;
        if (str(details.description, "type") == "catlive-library-effect") {
            try {
                const auto key = session.insertLibraryEffect(track, str(details.description, "identity"),
                                                             str(details.description, "preset"), {}, true);
                if (key.isNotEmpty()) {
                    load(); fxui::defaults(settings); chain.updateContent(); selectEffect(key);
                }
            } catch (const std::exception &failure) { error(String::fromUTF8(failure.what())); }
            return;
        }
        auto keys=list(get(settings,"inserted"));
        const auto effect=details.description;
        const int source=keys.indexOf(effect);
        const auto point=chain.getLocalPoint(this,details.localPosition);
        int destination=chain.getRowContainingPosition(point.x,point.y);
        if(destination<0)destination=point.y<0?0:keys.size();
        else if(point.y>=chain.getRowPosition(destination,true).getCentreY())++destination;
        if(source<0)return;
        keys.remove(source);if(destination>source)--destination;
        destination=jlimit(0,keys.size(),destination);
        if(destination==source)return;
        const auto selectedEffect = key();
        keys.insert(destination,effect);put(settings,"inserted",keys);
        if(commit(false)){
            const ScopedValueSetter<bool> reordering(reorderingChain, true);
            chain.updateContent();
            selected = list(get(settings, "inserted")).indexOf(var(selectedEffect));
            if (selected >= 0) chain.selectRow(selected);
            else chain.deselectAllRows();
            refreshPresets();
            chain.repaint();
        }
    }
    bool reorderingChain = false;
    void selectedRowsChanged(int row) override {
        if (reorderingChain) return;
        selected = row;
        show();
    }
    void listBoxItemDoubleClicked(int row,const MouseEvent &) override {chain.selectRow(row);if(kind()=="External")openExternalEditor();}
    void listBoxItemClicked(int row, const MouseEvent &e) override {
        chain.selectRow(row);
        if ((e.position.x < 30 || e.mods.isAltDown()) && !e.mods.isPopupMenu()) {
            auto s = current();
            auto k = fxui::enabledKey(kind());
            if (k.isNotEmpty()) {
                fxui::enable(kind(), s, !fxui::isEnabled(kind(), s));
                commit();
                show();
            }
        }
        if(e.mods.isPopupMenu()) {
            if(e.mods.isAltDown()){erase();return;}
            PopupMenu menu;menu.addItem(1,localization::translate("Remover"));
            menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&chain),[safe=SafePointer<EffectsPanel>(this)](int choice){if(safe && choice==1)safe->erase();});
        }
    }

    void show() {
        stemEditor.reset();
        thresholdMeter.reset();
        dynamicsEditor.reset();
        instrumentEditor.reset();
        drummerEditor.reset();
        synthEditor.reset();
        knobs.clear();
        refreshPresets();
        const auto k = kind();
        channelLabel.setVisible(false);
        for (auto &button : channelButtons) button.setVisible(false);
        for (auto &button : gateSteps) button.setVisible(false);
        gateDivision.setVisible(false);
        if(k=="External")openExternalEditor();else externalEditor.reset();
        const bool available = k.isNotEmpty() && fxui::enabledKey(k).isNotEmpty();
        enabled.setVisible(available&&k!="Instruments"&&k!="CatStemSeparation 5"&&k!="External"&&k!="CatLive Trigger"&&k!="Cat Gate");
        removeEffect.setVisible(k.isNotEmpty()&&k!="External"&&k!="CatLive Trigger"&&k!="Cat Gate");
        remove.setEnabled(k.isNotEmpty());
        for (int i = 0; i < rooms.size(); ++i) {
            rooms[i]->setVisible(k == "Reverb");
            rooms[i]->setToggleState((int)num(current(), "reverbRoom", 1) == i,
                                     dontSendNotification);
        }
        const auto arp = ArpeggioParameters::read(current());
        const std::array<int, 3> arpeggioValues{arp.division, arp.direction + 1, arp.octaves};
        const bool showArpeggio = k == "Arpeggiator" && available;
        arpeggioGate.setVisible(showArpeggio);
        arpeggioBPM.setVisible(showArpeggio);
        arpeggioSync.setVisible(showArpeggio);
        arpeggioSync.setToggleState(arp.sync, dontSendNotification);
        arpeggioGate.setValue(arp.gate, dontSendNotification);
        arpeggioBPM.setValue(arp.bpm, dontSendNotification);
        arpeggioBPM.setEnabled(!arp.sync);
        for (size_t i = 0; i < arpeggioSelectors.size(); ++i) {
            arpeggioSelectors[i].setVisible(k == "Arpeggiator" && available);
            arpeggioSelectors[i].setSelectedId(arpeggioValues[i], dontSendNotification);
        }
        graph.setVisible(k == "EQ");
        if (k != "EQ") graph.clearAnalysis();
        enabled.checkbox = k == "EQ";
        if (!available) {
            resized();
            repaint();
            return;
        }
        auto s = current();
        if(k!="External")fxui::defaults(s);
        const auto channelProperty = fxpresets::channelsField(k);
        channelLabel.setVisible(channelProperty.isNotEmpty());
        const unsigned mask = fxpresets::channels(s, k);
        for (unsigned ch = 0; ch < channelButtons.size(); ++ch) {
            auto &button = channelButtons[ch];
            const auto bit = 1u << ch;
            button.setVisible(channelProperty.isNotEmpty());
            button.setButtonText(String(ch + 1));
            button.setToggleState((mask & bit) != 0, dontSendNotification);
            button.onClick = [this, channelProperty, bit, ch] {
                auto value = current();
                const auto before = fxpresets::channels(value, kind());
                const auto after = channelButtons[ch].getToggleState() ? (before | bit) : (before & ~bit);
                if (after == 3) fxpresets::erase(value, Identifier(channelProperty));
                else put(value, Identifier(channelProperty), int(after));
                commit();
            };
        }
        const auto *creative = jaras::audio::creativeEffect(utf8(k));
        const bool rhythmic = creative && creative->kind == jaras::audio::CreativeEffect::divisionGate;
        for (auto &step : gateSteps) step.setVisible(rhythmic);
        gateDivision.setVisible(rhythmic);
        if (creative) {
            auto actual = current();
            auto group = get(actual, Identifier(creative->field));
            if (!group.isObject()) { group = object(); put(actual, Identifier(creative->field), group); }
            for (const auto &parameter : creative->parameters) {
                if (!parameter.key) continue;
                const Identifier name(parameter.key);
                if (get(group, name).isVoid()) put(group, name, parameter.initial);
                const std::string_view key(parameter.key);
                if (key == "steps" || key == "division") continue;
                knob(parameter.name, parameter.key, parameter.minimum, parameter.maximum,
                     parameter.increment, parameter.suffix, 1, creative->field);
            }
            if (rhythmic) {
                gateDivision.setSelectedId(int(num(group, "division", 16)), dontSendNotification);
                const int steps = int(num(group, "steps", 0x5b5b));
                for (unsigned step = 0; step < gateSteps.size(); ++step) {
                    auto &button = gateSteps[step];
                    const int bit = 1 << step;
                    button.setButtonText(String(step + 1));
                    button.setClickingTogglesState(true);
                    button.setToggleState((steps & bit) != 0, dontSendNotification);
                    button.onClick = [this, bit] {
                        auto value = get(current(), "divisionGate");
                        put(value, "steps", int(num(value, "steps", 0x5b5b)) ^ bit);
                        session.audio.previewNativeParameters(track, key(), kind(), current(), settings);
                        commit();
                    };
                }
            }
        }
        enabled.setToggleState(fxui::isEnabled(k, s), dontSendNotification);
        graph.settings = s;
        graph.refreshControls();
        if (k == "CatLive Trigger" || k == "Cat Gate") {
            const auto dynamicsKey = key();
            dynamicsEditor = std::make_unique<CatDynamicsEditor>(k, session.mediaDirectory, [this] { return current(); }, [this] { commit(); chain.repaint(); }, error,
                [this, dynamicsKey] { session.audio.previewDynamics(track, dynamicsKey, current()); }, [this] { return session.audio.fxLevels(track); },
                [this, dynamicsKey] { return session.audio.takeDynamicsLevels(track, dynamicsKey); });
            addAndMakeVisible(*dynamicsEditor);
        }
        if(k=="CatStemSeparation 5") {
            auto stemKey=key();
            stemEditor=std::make_unique<CatStemEditor>(trackName,[this]{return current();},[this,stemKey](var value,bool save){
                session.audio.previewStemMix(track,stemKey,stemMix::decode(value));
                if(save){commit();chain.repaint();}
            },[this,stemKey]{return session.audio.stemStatus(track,stemKey);});
            addAndMakeVisible(*stemEditor);
        }
        if (k == "Compressor") {
            thresholdMeter = std::make_unique<fxui::DynamicsThresholdMeter>(true, num(current(), "threshold", -20),
                [this](double db) {
                    auto value = current(); put(value, "threshold", db);
                    session.audio.previewNativeParameters(track, key(), kind(), value, settings);
                }, [this] { commit(); }, [this] { return session.audio.takeDynamicsLevels(track, key()); });
            addAndMakeVisible(*thresholdMeter);
            knob("Ratio", "ratio", 1, 20, .1, " :1");
            knob("Gain", "makeup", -12, 24, .1, " dB");
            knob("Attack", "attack", .1, 200, .1, " ms", 1000);
            knob("Release", "release", 10, 3000, 1, " ms", 1000);
        }
        if (k == "Delay") {
            knob("Time", "delayTime", 10, 2000, 1, " ms", 1000);
            knob("Feedback", "feedback", 0, 90, .1, " %");
            knob("Mix", "delayMix", 0, 100, .1, " %");
        }
        if (k == "Reverb") {
            knob("Mix", "reverbMix", 0, 100, .1, " %");
            knob("Decay", "reverbDecay", .1, 20, .1, " s");
            knob("Low Cut", "reverbLowCut", 20, 2000, 1, " Hz");
            knob("High Cut", "reverbHighCut", 2000, 20000, 1, " Hz");
        }
        if (k == "Limiter") {
            knob("Gain", "inputGain", -24, 24, .1, " dB", 1, "limiter");
            knob("Ceiling", "ceiling", -24, 0, .1, " dB", 1, "limiter");
            knob("Release", "release", 10, 3000, 1, " ms", 1000, "limiter");
        }
        if (k == "Pitch") {
            knob("Semitones", "pitchSemitones", -12, 12, 1, " st");
            knob("Formant", "pitchFormant", -12, 12, .1, " st");
        }
        if (k == "CatSynth") {
            synthEditor = std::make_unique<CatSynthEditor>(session.audio, track, key(), get(current(), "catSynth"),
                fxui::isEnabled(k, current()),
                [this](var bank) { auto value = current(); put(value, "catSynth", std::move(bank)); commit(false); },
                [this](bool on) { auto value = current(); fxui::enable("CatSynth", value, on); commit(false); chain.repaint(); });
            addAndMakeVisible(*synthEditor);
            removeEffect.setVisible(false); enabled.setVisible(false);
        }
        if (const auto n = drummer::count(k)) {
            drummerEditor = std::make_unique<DrummerPadEditor>(session.audio, track, key(), k,
                [this]{return current();}, [this,n](var kit){auto value=current();put(value,drummer::field(n),std::move(kit));commit(false);},error);
            addAndMakeVisible(*drummerEditor);
            removeEffect.setVisible(false); enabled.setVisible(false);
        }
        if (k == "Instruments") {
            instrumentEditor = std::make_unique<InstrumentParameterEditor>(str(current(), "instrumentID"),
                [this] { return current(); },
                [this] { session.audio.previewNativeParameters(track, key(), kind(), current(), settings); },
                [this] { commit(); });
            addAndMakeVisible(*instrumentEditor);
        }
        resized();
        repaint();
        chain.repaint();
    }
    void knob(String title, String property, double low, double high, double step, String suffix,
              double multiplier = 1, String group = {}) {
        auto s = group.isNotEmpty() ? get(current(), Identifier(group)) : current();
        auto *k = knobs.add(new fxui::Knob(
            title, low, high, step, num(s, Identifier(property)) * multiplier, suffix,
            [this, property, multiplier, group](double value) {
                auto s = group.isNotEmpty() ? get(current(), Identifier(group)) : current();
                put(s, Identifier(property), value / multiplier);
                session.audio.previewNativeParameters(track,key(),kind(),current(),settings);
            },
            [this] { commit(); }));
        k->setAccent(fxui::dialAccent(kind()));
        addAndMakeVisible(k);
        if (property == "attack" || property == "release" || property == "delayTime")
            k->slider.setSkewFactor(.4);
    }
    void erase() {
        if (selected < 0)
            return;
        auto inserted = list(get(settings, "inserted"));
        const auto removed = key();
        inserted.remove(selected);
        put(settings, "inserted", inserted);
        fxui::reset(removed, settings);
        auto plugins=list(get(settings,"externalPlugins"));
        for(int i=plugins.size();--i>=0;)if("External:"+str(plugins[i],"id")==removed)plugins.remove(i);
        put(settings,"externalPlugins",plugins);
        if(removed==externalEditorKey)externalEditor.reset();
        auto instances = list(get(settings, "instances"));
        for (int i = instances.size(); --i >= 0;)
            if ("Native:" + str(instances[i], "id") == removed ||
                "Instance:" + str(instances[i], "id") == removed)
                instances.remove(i);
        put(settings, "instances", instances);
        commit();
        chain.updateContent();
        if (inserted.isEmpty()) {
            selected = -1;
            chain.deselectAllRows();
            show();
        } else {
            selected = inserted.size() - 1;
            chain.selectRow(selected);
            show();
        }
    }
    bool commit(bool updatePresets = true, bool recordParameters = true) {
        try {
            if (session.busy)
                return false;
            const auto effect = key(), type = kind();
            const bool trackHistory = recordParameters && !fxpresets::fields(type).isEmpty() &&
                list(get(persistedSettings, "inserted")).contains(var(effect));
            const auto before = trackHistory ? parameterSnapshot(type, effectSettings(persistedSettings, effect)) : var();
            session.configureEffects(track, settings);
            load();fxui::defaults(settings);
            if (trackHistory) {
                const auto after = parameterSnapshot(type, effectSettings(settings, effect));
                if (!sameParameters(before, after)) {
                    auto &history = parameterHistory[effect];
                    if (!sameParameters(history.last, before)) history = {};
                    if (history.undo.size() >= 40) history.undo.erase(history.undo.begin());
                    history.undo.push_back(before);
                    history.redo.clear();
                    history.last = after;
                }
            }
            if (updatePresets) refreshPresets();
            return true;
        } catch (const std::exception &e) {
            load();
            fxui::defaults(settings);
            MessageManager::callAsync(
                [safe = SafePointer<EffectsPanel>(this), message = String::fromUTF8(e.what())] {
                    if (safe) {
                        safe->show();
                        safe->error(message);
                    }
                });
            return false;
        }
    }
    var factoryPreset() const {
        auto value = object(); fxui::defaults(value);
        if (kind() == "Instruments") {
            put(value, "instrumentID", str(current(), "instrumentID"));
            put(value, "instrumentParameters", fxui::instrumentParameters(str(current(), "instrumentID")));
        }
        return fxpresets::capture(kind(), value, "Factory");
    }
    void refreshPresets(bool reload = false) {
        const bool available = !drummer::count(kind()) && fxpresets::fields(kind()).size() > 0;
        presets.setVisible(available); savePreset.setVisible(available); defaultPreset.setVisible(available);
        undoParameters.setVisible(available); redoParameters.setVisible(available);
        if (!available) return;
        const auto history = parameterHistory.find(key());
        const bool valid = history != parameterHistory.end() &&
            sameParameters(history->second.last, parameterSnapshot(kind(), current()));
        undoParameters.setEnabled(valid && !history->second.undo.empty());
        redoParameters.setEnabled(valid && !history->second.redo.empty());
        try {
            if (reload || !presetsLoaded) { presetLibrary = fxpresets::Store().read(); presetRevision = fxpresets::Store().revision(); presetsLoaded = true; }
            const auto identity = fxpresets::identity(kind(), current());
            presetEntries = fxpresets::Store::entries(presetLibrary, identity);
            const auto defaultID = str(get(presetLibrary, "defaults"), Identifier(identity));
            presets.clear(dontSendNotification);
            const auto star = String::fromUTF8(" ★");
            presets.addItem("Default" + (defaultID.isEmpty() ? star : ""), 1);
            int selection = fxpresets::matches(kind(), current(), factoryPreset()) ? 1 : 0;
            for (int i = 0; i < presetEntries.size(); ++i) {
                const auto &preset = presetEntries[i];
                presets.addItem(str(preset,"name") + (str(preset,"id") == defaultID ? star : ""), i + 2);
                if (fxpresets::matches(kind(), current(), preset)) selection = i + 2;
            }
            presets.setTextWhenNothingSelected("Personalizado"); presets.setSelectedId(selection, dontSendNotification);
            defaultPreset.setEnabled(selection != 0);
        } catch (const std::exception &e) { presets.setText(String::fromUTF8(e.what()), dontSendNotification); defaultPreset.setEnabled(false); }
    }
    void loadPreset() {
        const int index = presets.getSelectedId(); if (index < 1) return;
        try {
            const auto preset = index == 1 ? factoryPreset() : presetEntries[index - 2];
            auto value = current(); fxpresets::apply(kind(), value, preset);
            commit(); show();
        } catch (const std::exception &e) { error(String::fromUTF8(e.what())); }
    }
    void saveCurrentPreset() {
        const auto effect = key();
        auto *dialog = new AlertWindow("Salvar preset", String::fromUTF8("Nome da configuração deste plugin"), MessageBoxIconType::NoIcon);
        dialog->addTextEditor("name", ""); dialog->addButton("Salvar", 1, KeyPress(KeyPress::returnKey)); dialog->addButton("Cancelar", 0, KeyPress(KeyPress::escapeKey));
        dialog->enterModalState(true, ModalCallbackFunction::create([safe = SafePointer<EffectsPanel>(this), dialog, effect](int result) {
            if (!safe || result != 1 || safe->key() != effect) return;
            try {
                fxpresets::Store store; auto library = store.read();
                fxpresets::Store::save(library, fxpresets::capture(safe->kind(), safe->current(), dialog->getTextEditorContents("name")));
                store.write(library); safe->refreshPresets(true);
            } catch (const std::exception &e) { safe->error(String::fromUTF8(e.what())); }
        }), true);
    }
    void makePresetDefault() {
        const int index = presets.getSelectedId(); if (index < 1) return;
        try {
            fxpresets::Store store; auto library = store.read();
            fxpresets::Store::setDefault(library, fxpresets::identity(kind(), current()), index == 1 ? String() : str(presetEntries[index - 2], "id"));
            store.write(library); refreshPresets(true);
        } catch (const std::exception &e) { error(String::fromUTF8(e.what())); }
    }
    void timerCallback() override {
        if(externalEditor)externalEditor->syncVisibility();
        if (isShowing() && graph.isVisible()) graph.updateAnalysis(session.audio.eqAnalysis(track, key()));
        else graph.clearAnalysis();
        if(externalEditor&&!externalEditor->uses(session.audio.externalEffect(track,externalEditorKey))) {externalEditor.reset();openExternalEditor();}
        for(auto plugin:list(get(settings,"externalPlugins")))if(auto processor=session.audio.externalEffect(track,"External:"+str(plugin,"id")))
            if(processor->consumeEdited())session.dirty=true;
        if (loadedRevision != session.revision) {
            const auto previous = JSON::toString(settings, true), selectedKey = key();
            load(); fxui::defaults(settings);
            if (JSON::toString(settings, true) != previous) {
                const auto keys = list(get(settings, "inserted"));
                selected = keys.indexOf(var(singleEffect.isEmpty() ? selectedKey : singleEffect));
                if (singleEffect.isEmpty() && selected < 0 && !keys.isEmpty()) selected = 0;
                chain.updateContent();
                if (selected < 0) chain.deselectAllRows(); else chain.selectRow(selected);
                show();
            }
        }
        if (++presetPoll % 10 == 0 && isShowing() && fxpresets::Store().revision() != presetRevision) refreshPresets(true);
        // The native editor owns its paint cadence; do not repaint its parent
        // twenty times per second over an independently animated child HWND.
        if (isShowing() && !externalEditor)
            repaint();
    }
    void setArpeggioParameter(const Identifier &key, const var &parameter) {
        auto value = current();
        auto parameters = get(value, "arpeggiator");
        if (!parameters.isObject()) parameters = object();
        put(parameters, key, parameter);
        put(value, "arpeggiator", parameters);
        commit();
        repaint();
    }
    void paintArpeggio(Graphics &g, juce::Rectangle<int> area) {
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(15));
        g.drawText("Pattern preview", area.removeFromTop(26), Justification::centredLeft);
        auto footer = area.removeFromBottom(52);
        const int column = area.getWidth() / int(arpeggioTitles.size());
        g.setFont(theme::mediumFont(12));
        for (auto title : arpeggioTitles)
            g.drawText(title, footer.removeFromLeft(column).removeFromTop(20), Justification::centredLeft);
        const auto parameters = ArpeggioParameters::read(current());
        constexpr std::array<int, 3> pitches{60, 64, 67};
        const auto accent = fxui::dialAccent("Arpeggiator");
        const float width = float(area.getWidth()) / float(parameters.division);
        const int lanes = parameters.octaves * int(pitches.size());
        const float laneHeight = float(area.getHeight()) / float(lanes);
        for (int step = 0; step < parameters.division; ++step) {
            const float x = float(area.getX()) + step * width;
            g.setColour(Colours::white.withAlpha(step % std::max(1, parameters.division / 4) == 0 ? .23f : .08f));
            g.drawVerticalLine(roundToInt(x), float(area.getY()), float(area.getBottom()));
            const auto [note, transpose] = parameters.step(size_t(step), pitches.size(),
                [&](size_t i) { return pitches[i]; });
            const auto lane = lanes - 1 - (transpose / 12 * int(pitches.size()) + int(note));
            const float y = float(area.getY()) + float(lane) * laneHeight;
            g.setColour(accent);
            g.fillRoundedRectangle(x, y + 1, std::max(1.f, width * float(parameters.length())),
                                   std::max(1.f, laneHeight - 2), 2);
        }
    }
    void paintMeters(Graphics &g) {
        const auto r = content();
        const int top = rackY + std::max(38, (rackHeight - 116) / 2), height = 110,
                  x = r.getX() + 28;
        g.setColour(theme::secondary);
        g.setFont(theme::font(8));
        g.drawText("IN", x - 5, top - 20, 26, 18, Justification::centred);
        g.drawText("OUT", x + 45, top - 20, 30, 18, Justification::centred);
        const auto levels = session.audio.fxLevels(track);
        for (int i = 0; i < 4; ++i) {
            const int bx = x + (i / 2) * 50 + (i % 2) * 10;
            g.setColour(Colours::black);
            g.fillRect(bx, top, 7, height);
            const float level = i < 2 ? levels.first : levels.second;
            const auto amount =
                jlimit(0.f, 1.f, (Decibels::gainToDecibels(level, -60.f) + 60) / 60);
            g.setColour(level >= 1 ? Colours::red : theme::green);
            g.fillRect(bx, top + height - (int)(amount * height), 7, (int)(amount * height));
        }
        g.setColour(theme::secondary);
        for (int db : {0, -24, -60})
            g.drawText(String(db), x + 20, top + (int)(-db / 60.f * height) - 5, 24, 12,
                       Justification::centred);
    }
};
} // namespace catlive
