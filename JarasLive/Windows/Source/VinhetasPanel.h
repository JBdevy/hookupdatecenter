#pragma once
#include "Appearance.h"
#include "VinhetasAudio.h"
namespace catlive {
class VinhetasPanel final : public Component, private Timer {
    friend struct VinhetasPanelProbe;
  public:
    struct PadData { String name; unsigned colour=0x626262; float volume=1; bool gate=false; File file; const VinhetasAudio::Sample *sample=nullptr; };
    struct Preset { String name; unsigned colour=0x626262; std::array<PadData,16> pads; };
    std::function<void()> createTrack;
    std::function<void(String,unsigned,std::function<void(String,unsigned)>)> edit;

    VinhetasPanel(VinhetasAudio &audio, Appearance &appearance) : audio(audio), appearance(appearance) {
        if(globalState.isVoid())globalState=appearance.value("jaras.vinhetas",var{}).clone();
        loadState(globalState);instances.insert(this);
        for(int p=0;p<6;++p) {
            auto &preset=presets[(size_t)p];
            for(int n=0;n<16;++n)if(preset.pads[(size_t)n].name.isEmpty())preset.pads[(size_t)n].name="Pad "+String(n+1);
            auto &button=presetButtons[(size_t)p];button.setButtonText(preset.name);button.getProperties().set("flat",true);button.getProperties().set("cornerRadius",5);button.onClick=[this,p]{select(p);};button.context=[this,p](Point<int>){menu(p,-1);};addAndMakeVisible(button);
        }
        for(int n=0;n<16;++n) {
            auto &pad=pads[(size_t)n];pad.owner=this;pad.index=n;addAndMakeVisible(pad);
            auto &gate=gates[(size_t)n];gate.onClick=[this,n]{current(n).gate=!current(n).gate;if(current(n).gate)this->audio.enqueue({VinhetasAudio::Kind::stopPad,0,selected,n});save();refresh();};addAndMakeVisible(gate);
            auto &slider=sliders[(size_t)n];slider.setSliderStyle(Slider::LinearHorizontal);slider.setTextBoxStyle(Slider::NoTextBox,false,0,0);slider.setRange(0,2,.001);
            slider.onValueChange=[this,n]{current(n).volume=(float)sliders[(size_t)n].getValue();this->audio.enqueue({VinhetasAudio::Kind::volume,0,selected,n,current(n).volume});updateDB(n);};slider.onDragEnd=[this]{save();};addAndMakeVisible(slider);
            dbLabels[(size_t)n].setFont(theme::semiboldFont(10));dbLabels[(size_t)n].setBorderSize(BorderSize<int>(0));addAndMakeVisible(dbLabels[(size_t)n]);
        }
        previous.setButtonText("<");next.setButtonText(">");create.setButtonText("Create Track");create.setColour(TextButton::buttonColourId,theme::green);create.setColour(TextButton::textColourOffId,Colours::black);
        panic.setButtonText("Panic");panic.setColour(TextButton::buttonColourId,Colour(0xff8d2845));
        panic.onClick=[] {for(auto *panel:instances){panel->audio.enqueue({VinhetasAudio::Kind::panic});panel->heldNotes.clear();panel->repaint();}};
        for(auto *arrow:{&previous,&next}){arrow->setColour(TextButton::buttonColourId,Colour(0xff454545));arrow->getProperties().set("fontSize",18);}
        previous.onClick=[this]{select(selected-1);};next.onClick=[this]{select(selected+1);};create.onClick=[this]{if(createTrack)createTrack();};
        for(auto *button:{&previous,&next,&create,&panic}){button->getProperties().set("flat",true);button->getProperties().set("cornerRadius",5);addAndMakeVisible(button);}
        midiLabel.setText("MIDI",dontSendNotification);midiLabel.setJustificationType(Justification::centredRight);addAndMakeVisible(midiLabel);
        midiChannel.addItem("Omni",1);for(int ch=1;ch<=16;ch++)midiChannel.addItem(String(ch),ch+1);
        midiChannel.setSelectedId(channel+1,dontSendNotification);
        midiChannel.onChange=[this]{channel=midiChannel.getSelectedId()-1;save();};addAndMakeVisible(midiChannel);
        select(selected);startTimerHz(20);
    }
    ~VinhetasPanel() override { instances.erase(this);audio.learningMIDI=false; }
    void select(int preset) { selected=jlimit(0,5,preset);refresh();save();preload(); }
    bool midi(int status,int number,int value,int channel) {
        const int normalized=status==0x80?0x90:status;
        const bool down=status!=0x80&&value>0;
        const int key=(normalized<<16)|(channel<<8)|number;
        if(learning>=0&&down&&(channelFilter()==0||channelFilter()==channel)) {
            var mapping(new DynamicObject());put(mapping,"status",normalized);put(mapping,"number",number);put(mapping,"channel",channel);
            if(learningPreset)presetMappings[(size_t)learning]=mapping;else padMappings[(size_t)learning]=mapping;
            learning=-1;audio.learningMIDI=false;save();repaint();return true;
        }
        if(!down) {
            pressedCC.erase(key);
            auto held=heldNotes.find(key);
            if(held!=heldNotes.end()){for(auto voice:held->second)audio.enqueue({VinhetasAudio::Kind::stop,voice});heldNotes.erase(held);return true;}
            return mapped(normalized,number,channel);
        }
        if(channelFilter()!=0&&channelFilter()!=channel)return false;
        if(normalized==0xb0&&!pressedCC.insert(key).second)return mapped(normalized,number,channel);
        auto matches=[&](const var &v){return v.isObject()&&(int)get(v,"status")==normalized&&(int)get(v,"number")==number;};
        for(int p=0;p<6;++p)if(matches(presetMappings[(size_t)p])){select(p);return true;}
        for(int n=0;n<16;++n)if(matches(padMappings[(size_t)n])){
            auto voice=start(n);if(voice&&normalized==0x90)heldNotes[key].push_back(voice);return true;
        }
        return false;
    }
    void resized() override {
        auto area=getLocalBounds().reduced(10);auto top=area.removeFromTop(30);
        panic.setBounds(top.removeFromRight(60));top.removeFromRight(6);
        create.setBounds(top.removeFromRight(100));top.removeFromRight(6);
        midiChannel.setBounds(top.removeFromRight(78));midiLabel.setBounds(top.removeFromRight(34));top.removeFromRight(6);
        next.setBounds(top.removeFromRight(28));top.removeFromRight(6);previous.setBounds(top.removeFromRight(28));top.removeFromRight(6);
        const int presetWidth=(top.getWidth()-5*6)/6;
        for(auto &button:presetButtons){button.setBounds(top.removeFromLeft(presetWidth));top.removeFromLeft(6);}
        area.removeFromTop(8);
        const int cellWidth=(area.getWidth()-7*8)/8,cellHeight=(area.getHeight()-8)/2;
        for(int n=0;n<16;++n) {
            juce::Rectangle<int> cell(area.getX()+n%8*(cellWidth+8),area.getY()+n/8*(cellHeight+8),cellWidth,cellHeight);
            auto fader=cell.removeFromBottom(20);dbLabels[(size_t)n].setBounds(fader.removeFromLeft(34));fader.removeFromLeft(6);sliders[(size_t)n].setBounds(fader);
            cell.removeFromBottom(4);auto gate=cell.removeFromLeft(34);gates[(size_t)n].setBounds(gate.withSizeKeepingCentre(34,40));cell.removeFromLeft(4);pads[(size_t)n].setBounds(cell);
        }
    }
    void paint(Graphics &g) override {g.fillAll(theme::panel);if(learning>=0){g.setColour(theme::yellow);g.drawText("Learn MIDI: "+String(learningPreset?"Preset ":"Pad ")+String(learning+1),getLocalBounds().removeFromBottom(16),Justification::centred);}}
  private:
    struct Gate : Button {
        Gate():Button("Gate"){}
        void paintButton(Graphics &g,bool,bool) override {
            if(getToggleState()){g.setColour(theme::yellow);g.fillRoundedRectangle(getLocalBounds().toFloat(),4);}
            g.setColour(getToggleState()?Colours::black:Colour(0xffbbbbbb));g.setFont(theme::semiboldFont(10));
            auto label=getLocalBounds().withSizeKeepingCentre(getWidth(),26);
            g.drawText("Gate",label.removeFromTop(13),Justification::centred,false);
            g.drawText(getToggleState()?"On":"Off",label,Justification::centred,false);
        }
    };
    struct Fader : Slider {
        void paint(Graphics &g) override {
            const float width=(float)getWidth(),height=(float)getHeight();
            g.setColour(Colour(0xff808080));g.fillRoundedRectangle(7,(height-4)/2,std::max(0.f,width-14),4,2);
            g.setColour(Colour(0xffd9d9d9));g.fillEllipse(std::max(0.f,width-14)*(float)getValue()/2,(height-14)/2,14,14);
        }
    };
    struct Pad : Component {
        VinhetasPanel *owner=nullptr;int index=0;uint64_t held=0;bool pressed=false;
        bool isLit() const { return pressed || owner->audio.active(owner->selected,index); }
        void paint(Graphics &g) override {
            const auto &data=owner->current(index);const Colour base(0xff000000|data.colour);const bool lit=isLit();
            g.setColour(lit?base.interpolatedWith(Colours::white,.18f):base.withAlpha(.45f));g.fillRoundedRectangle(getLocalBounds().toFloat(),5);
            if(lit){g.setColour(base.interpolatedWith(Colours::white,.6f));g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(1),5,2);}
            g.setColour(Colours::white);g.setFont(theme::font(11,true));g.drawFittedText(data.name,getLocalBounds().reduced(3),Justification::centred,2);
        }
        void mouseDown(const MouseEvent &event) override {
            if(event.mods.isPopupMenu()){owner->menu(owner->selected,index);return;}
            pressed=true;repaint();
            const auto token=owner->start(index);
            if(token&&owner->current(index).gate)held=token;
        }
        void mouseUp(const MouseEvent &) override { if(held)owner->audio.enqueue({VinhetasAudio::Kind::stop,held});held=0;pressed=false;repaint(); }
    };
    VinhetasAudio &audio;Appearance &appearance;
    std::array<Preset,6> presets;
    std::array<QuietButton,6> presetButtons;
    std::array<Pad,16> pads;
    std::array<Gate,16> gates;
    std::array<Fader,16> sliders;
    std::array<Label,16> dbLabels;
    TextButton previous,next,create,panic;
    inline static std::set<VinhetasPanel*> instances;
    ComboBox midiChannel;Label midiLabel;int channel=0;
    int channelFilter() const {return channel;}
    int selected=0;uint64_t token=0;
    std::unique_ptr<FileChooser> chooser;
    inline static ThreadPool loaders{2};
    inline static var globalState;
    inline static uint64_t globalRevision=0;
    uint64_t revision=0;
    std::array<var,16> padMappings;
    std::array<var,6> presetMappings;
    std::map<String,const VinhetasAudio::Sample *> cache;
    std::set<String> loading;
    std::set<int> pressedCC;
    std::map<int,std::vector<uint64_t>> heldNotes;
    int learning=-1;bool learningPreset=false;
    File mediaFolder() const {return File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/Vinhetas");}
    void loadState(const var &stored) {
        selected=jlimit(0,5,(int)get(stored,"selectedPreset",0));
        channel=jlimit(0,16,(int)get(stored,"midiChannel",0));
        midiChannel.setSelectedId(channel+1,dontSendNotification);
        const bool upgradeColors=(int)get(stored,"colorDefaultsVersion",0)<1;
        auto shuffledColors=[] {std::array<unsigned,16> colors{0xE74C3C,0xE67E22,0xF1C40F,0x91C83E,0x2ECC71,0x1ABC9C,0x18A9BB,0x3498DB,0x5275EB,0x7861D9,0x9B59B6,0xC750B7,0xE86298,0xDC7770,0xC6A356,0x56A48E};for(int i=15;i>0;i--)std::swap(colors[(size_t)i],colors[(size_t)Random::getSystemRandom().nextInt(i+1)]);return colors;};
        const auto presetColors=shuffledColors();
        const auto values=get(stored,"presets");const auto pm=get(stored,"padMappings");const auto pre=get(stored,"presetMappings");
        for(int i=0;i<16;i++)padMappings[(size_t)i]=pm.isArray()&&i<pm.size()?pm[i]:var{};
        for(int p=0;p<6;p++) {
            presetMappings[(size_t)p]=pre.isArray()&&p<pre.size()?pre[p]:var{};
            auto &preset=presets[(size_t)p];const auto entry=values.isArray()&&p<values.size()?values[p]:var{};
            preset.name=get(entry,"name","Preset "+String(p+1)).toString();preset.colour=(unsigned)(int)get(entry,"color",0x626262);
            if(upgradeColors&&preset.colour==0x626262)preset.colour=presetColors[(size_t)p];
            const auto padColors=shuffledColors();
            const auto list=get(entry,"pads");
            for(int n=0;n<16;n++) {
                auto &pad=preset.pads[(size_t)n];const auto v=list.isArray()&&n<list.size()?list[n]:var{};
                pad.name=get(v,"name","Pad "+String(n+1)).toString();pad.colour=(unsigned)(int)get(v,"color",0x626262);
                if(upgradeColors&&pad.colour==0x626262)pad.colour=padColors[(size_t)n];
                pad.volume=jlimit(0.f,2.f,(float)get(v,"volume",1.));pad.gate=(bool)get(v,"gate",false);
                const auto name=get(v,"audioFile").toString();pad.file=name.isEmpty()?File{}:File::isAbsolutePath(name)?File(name):mediaFolder().getChildFile(name);
                auto found=cache.find(pad.file.getFullPathName());pad.sample=found==cache.end()?nullptr:found->second;
            }
        }
        revision=globalRevision;syncMIDIMappings();
    }
    void syncMIDIMappings() {
        audio.midiChannel=channel;
        for(int i=0;i<22;i++) {
            const auto &v=i<16?padMappings[(size_t)i]:presetMappings[(size_t)(i-16)];
            audio.setMIDIMapping(i,(int)get(v,"status"),(int)get(v,"channel"),(int)get(v,"number"));
        }
    }
    bool mapped(int status,int number,int incomingChannel) const {
        if(channel!=0&&channel!=incomingChannel)return false;
        auto matches=[&](const var &v){return v.isObject()&&(int)get(v,"status")==status&&(int)get(v,"number")==number;};
        return std::any_of(padMappings.begin(),padMappings.end(),matches)||std::any_of(presetMappings.begin(),presetMappings.end(),matches);
    }
    uint64_t start(int n) {
        auto &data=current(n);if(!data.sample)return 0;
        auto voice=++token;
        return audio.enqueue({VinhetasAudio::Kind::start,voice,selected,n,data.volume,data.sample})?voice:0;
    }
    void preload() {
        for(auto &preset:presets)for(auto &pad:preset.pads) {
            const auto file=pad.file;const auto key=file.getFullPathName();
            if(pad.sample||key.isEmpty()||!loading.insert(key).second)continue;
            loaders.addJob([safe=SafePointer<VinhetasPanel>(this),file,key] {
                auto decoded=VinhetasAudio::decode(file);
                MessageManager::callAsync([safe,decoded,key] {
                    if(!safe)return;safe->loading.erase(key);if(!decoded)return;
                    const auto *sample=safe->audio.retain(decoded);safe->cache[key]=sample;
                    for(auto &preset:safe->presets)for(auto &pad:preset.pads)if(pad.file.getFullPathName()==key)pad.sample=sample;
                    safe->repaint();
                });
            });
        }
    }
    PadData &current(int pad){return presets[(size_t)selected].pads[(size_t)pad];}
    void timerCallback() override {if(revision!=globalRevision){loadState(globalState);refresh();preload();}for(auto &pad:pads)pad.repaint();}
    void updateDB(int n) {const float gain=current(n).volume;dbLabels[(size_t)n].setText(gain<=0?String::fromUTF8("−∞"):(gain>=1?"+":"")+String(Decibels::gainToDecibels(gain),1),dontSendNotification);}
    void refresh() {
        for(int n=0;n<16;++n){gates[(size_t)n].setToggleState(current(n).gate,dontSendNotification);sliders[(size_t)n].setValue(current(n).volume,dontSendNotification);updateDB(n);}
        for(int p=0;p<6;++p){presetButtons[(size_t)p].setButtonText(presets[(size_t)p].name);presetButtons[(size_t)p].setColour(TextButton::buttonColourId,Colour(0xff000000|presets[(size_t)p].colour).withAlpha(p==selected?1.f:.45f));}
        previous.setEnabled(selected>0);next.setEnabled(selected<5);repaint();
    }
    void save() {
        var root(new DynamicObject());put(root,"selectedPreset",selected);put(root,"midiChannel",channel);put(root,"colorDefaultsVersion",1);Array<var> list;
        for(auto &preset:presets){var entry(new DynamicObject());put(entry,"name",preset.name);put(entry,"color",(int)preset.colour);Array<var> values;
            for(auto &pad:preset.pads){var value(new DynamicObject());put(value,"name",pad.name);put(value,"color",(int)pad.colour);put(value,"volume",pad.volume);put(value,"gate",pad.gate);put(value,"audioFile",pad.file==File{}?String{}:pad.file.isAChildOf(mediaFolder())?pad.file.getFileName():pad.file.getFullPathName());values.add(value);}put(entry,"pads",values);list.add(entry);}
        put(root,"presets",list);Array<var> mappings;for(auto &v:padMappings)mappings.add(v);put(root,"padMappings",mappings);
        Array<var> presetMap;for(auto &v:presetMappings)presetMap.add(v);put(root,"presetMappings",presetMap);
        syncMIDIMappings();globalState=root.clone();revision=++globalRevision;appearance.set("jaras.vinhetas",root);
    }
    void menu(int preset,int pad) {
        PopupMenu menu;menu.addItem(1,"Editar");if(pad>=0)menu.addItem(2,"Inserir audio");menu.addItem(3,"Learn MIDI");
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(pad>=0?static_cast<Component*>(&pads[(size_t)pad]):&presetButtons[(size_t)preset]),[safe=SafePointer<VinhetasPanel>(this),preset,pad](int action){
            if(!safe)return;
            if(action==3){safe->learning=pad>=0?pad:preset;safe->learningPreset=pad<0;safe->audio.learningMIDI=true;safe->repaint();return;}
            if(action==1&&safe->edit){auto &p=safe->presets[(size_t)preset];safe->edit(pad>=0?p.pads[(size_t)pad].name:p.name,pad>=0?p.pads[(size_t)pad].colour:p.colour,[safe,preset,pad](String name,unsigned colour){if(!safe)return;auto &p=safe->presets[(size_t)preset];if(pad>=0){p.pads[(size_t)pad].name=name;p.pads[(size_t)pad].colour=colour;}else{p.name=name;p.colour=colour;}safe->save();safe->refresh();});}
            if(action==2&&pad>=0){safe->chooser=std::make_unique<FileChooser>("Inserir audio",File{},"*.wav;*.wave;*.aif;*.aiff;*.mp3");safe->chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectFiles,[safe,preset,pad](const FileChooser &chooser){if(!safe)return;const auto file=chooser.getResult();if(!file.existsAsFile())return;auto &data=safe->presets[(size_t)preset].pads[(size_t)pad];const auto folder=safe->mediaFolder();folder.createDirectory();const auto destination=folder.getChildFile(Uuid().toString()+file.getFileExtension());if(!file.hasFileExtension("wav;wave;aiff;aif;mp3")||!file.copyFileTo(destination))return;data.file=destination;data.sample=nullptr;safe->save();safe->refresh();safe->preload();});}
        });
    }
};
}
